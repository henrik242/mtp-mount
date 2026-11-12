import Foundation

/// A failure from the device layer, carrying the category sent over XPC.
struct MtpError: Error, CustomStringConvertible, Equatable {
    var kind: MtpFailure
    var message: String

    init(_ kind: MtpFailure, _ message: String) {
        self.kind = kind
        self.message = message
    }

    /// Normalize any error into an `MtpError`.
    init(_ error: Error) {
        if let e = error as? MtpError { self = e } else { self.init(.failed, "\(error)") }
    }

    var description: String { message }
    var nsError: NSError { .mtp(kind, message) }
}

/// Something the device reported on its own (MTP events), e.g. a photo taken
/// on a phone while it's connected.
enum DeviceEvent: Equatable {
    case objectAdded(UInt32)
    case objectRemoved(UInt32)
    /// A storage appeared/disappeared (e.g. an SD card): too coarse to patch up.
    case storageChanged
    /// The event channel failed; the session is probably dead.
    case linkLost
}

/// Byte progress for a transfer: called with (done, total); return false to cancel.
typealias TransferProgress = (_ done: UInt64, _ total: UInt64) -> Bool

/// An MTP device seen on USB but not necessarily opened.
struct RawDeviceInfo: Equatable, Hashable {
    /// USB bus location + device number: identifies the attachment.
    var location: UInt64
    var vendor: UInt16
    var product: UInt16
}

/// Finds and opens devices. `LibmtpBus` implements it over libmtp; tests use a
/// fake. Not thread-safe: callers serialize.
protocol MtpBus: AnyObject {
    func detect() throws -> [RawDeviceInfo]
    /// Open a detected device. Throws `.noDevice` or `.deviceBusy`.
    func open(_ device: RawDeviceInfo) throws -> MtpDevice
}

/// The operations on one open device. `MtpSession` implements it over libmtp;
/// tests use an in-memory fake. Not thread-safe: callers serialize.
protocol MtpDevice: AnyObject {
    /// Release the device. Returns false if it couldn't be released safely
    /// (libmtp would be left with a pending USB transfer pointing at freed
    /// memory); the handle is then abandoned and the owner should restart the
    /// process to get the device back.
    @discardableResult func close() -> Bool
    func deviceName() -> String?
    func serialNumber() -> String?
    /// Cheap round-trip that throws `.disconnected` if the session is dead.
    func ping() throws
    /// Collect device events received since the last call, without blocking,
    /// and keep listening for more.
    func pollEvents() -> [DeviceEvent]

    func list(parent: UInt32) throws -> [MtpEntry]
    /// Metadata for one object, or nil if it doesn't exist.
    func metadata(id: UInt32) throws -> MtpEntry?
    func download(id: UInt32, toFileDescriptor fd: Int32, progress: TransferProgress?) throws
    func upload(fromFileDescriptor fd: Int32, parent: UInt32, name: String, size: UInt64,
                progress: TransferProgress?) throws -> UInt32
    func createFolder(name: String, parent: UInt32) throws -> UInt32
    /// Delete one object (a folder is expected to be empty).
    func delete(id: UInt32) throws
    func rename(id: UInt32, to newName: String) throws
    func move(id: UInt32, toParent parent: UInt32) throws
}

/// libmtp's error-stack categories (mirrors `LIBMTP_error_number_t`), kept free
/// of the C module so the classification logic is unit-testable.
enum LibmtpErrorKind: Equatable {
    case general, ptpLayer, usbLayer, memory, noDeviceAttached, storageFull, connecting, cancelled
}

enum MtpErrorClassifier {
    /// PTP response codes that libmtp formats as "PTP Layer error %04x: …".
    /// 0x02Fx are libgphoto2's internal transport errors (I/O, timeout, …);
    /// 0x20xx are responses from the device itself.
    private static let ptpCodes: [(String, MtpFailure)] = [
        ("02f", .disconnected),     // PTP_ERROR_IO / TIMEOUT / CANCEL / …
        ("2009", .noSuchObject),    // Invalid_ObjectHandle
        ("2005", .unsupported),     // Operation_Not_Supported
        ("200c", .storageFull),     // Store_Full
        ("200d", .accessDenied),    // Store_Read_Only
        ("200e", .accessDenied),    // Access_Denied
        ("201f", .cancelled),       // Transaction_Cancelled
    ]

    /// Pick the most significant failure from a drained libmtp error stack.
    static func classify(_ stack: [(kind: LibmtpErrorKind, text: String)]) -> MtpFailure? {
        guard !stack.isEmpty else { return nil }
        var found: [MtpFailure] = []
        for (kind, text) in stack {
            switch kind {
            case .usbLayer, .noDeviceAttached, .connecting:
                found.append(.disconnected)
            case .storageFull:
                found.append(.storageFull)
            case .cancelled:
                found.append(.cancelled)
            case .ptpLayer:
                let lower = text.lowercased()
                if let hit = ptpCodes.first(where: { lower.contains("error \($0.0)") }) {
                    found.append(hit.1)
                } else {
                    found.append(.failed)
                }
            case .general, .memory:
                found.append(.failed)
            }
        }
        // A dead transport trumps everything: the session must be reopened.
        for preferred in [MtpFailure.disconnected, .storageFull, .noSuchObject,
                          .unsupported, .accessDenied, .cancelled] where found.contains(preferred) {
            return preferred
        }
        return .failed
    }
}
