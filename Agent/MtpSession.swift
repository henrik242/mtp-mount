import Foundation
import CLibmtp
import os

private let log = Logger(subsystem: MtpAgentConfig.logSubsystem, category: "libmtp")

/// Garmin's USB vendor id; preferred when several MTP devices are attached.
private let garminVendorID: UInt16 = 0x091E

/// libmtp's "top of storage" parent for listing (`LIBMTP_FILES_AND_FOLDERS_ROOT`).
private let listRootParent: UInt32 = 0xFFFF_FFFF

/// Thin Swift wrapper over libmtp for a single, long-lived device session.
///
/// NOT thread-safe: libmtp holds one stateful USB session, so every call must be
/// serialized onto a single queue by the owner (the agent does this).
/// Uses `LIBMTP_Open_Raw_Device_Uncached` so the whole object tree is *not*
/// pre-walked on connect — folders are listed on demand with
/// `LIBMTP_Get_Files_And_Folders`, which is exactly what File Provider wants.
///
/// Every failing libmtp call is turned into an `MtpError` by draining (and
/// clearing) libmtp's error stack; when that's inconclusive a cheap round-trip
/// tells "device refused" apart from "transport is dead".
final class MtpSession: MtpDevice {
    private var device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
    /// Storage we browse (the Edge has a single internal storage).
    private(set) var storageID: UInt32 = 0
    private var name: String?
    private var serial: String?

    /// Call once per process before any session work.
    static func initializeLibrary() {
        LIBMTP_Init()
    }

    var isOpen: Bool { device != nil }

    /// Detect and open a connected MTP device (a Garmin one if there are
    /// several), uncached, and pick its first storage.
    func open() throws {
        guard device == nil else { return }

        var rawList: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        let err = LIBMTP_Detect_Raw_Devices(&rawList, &count)
        defer { if let r = rawList { free(r) } }
        guard err == LIBMTP_ERROR_NONE || err == LIBMTP_ERROR_NO_DEVICE_ATTACHED else {
            throw MtpError(.failed, "USB enumeration failed (libmtp error \(err.rawValue)).")
        }
        guard let raws = rawList, count > 0 else {
            throw MtpError(.noDevice, "No MTP device detected on USB.")
        }
        let candidates = (0..<Int(count)).map { raws + $0 }
        if count > 1 {
            log.warning("\(count) MTP devices attached; preferring a Garmin one")
        }
        let raw = candidates.first { $0.pointee.device_entry.vendor_id == garminVendorID } ?? candidates[0]

        guard let dev = LIBMTP_Open_Raw_Device_Uncached(raw) else {
            throw MtpError(.deviceBusy,
                "Found the device but couldn't open it. Another app (Image Capture, Garmin Express, "
                + "Android File Transfer, OpenMTP) is probably using it — quit that app and try again.")
        }

        // Populate dev.pointee.storage.
        let rc = LIBMTP_Get_Storage(dev, Int32(LIBMTP_STORAGE_SORTBY_NOTSORTED))
        guard rc != -1, let storage = dev.pointee.storage else {
            LIBMTP_Clear_Errorstack(dev)
            LIBMTP_Release_Device(dev)
            throw MtpError(.deviceBusy, "The device didn't report any storage. Unlock it or check its USB mode.")
        }
        if storage.pointee.next != nil {
            log.warning("device has several storages; only the first is shown")
        }
        storageID = storage.pointee.id
        device = dev
        name = Self.takeString(LIBMTP_Get_Friendlyname(dev)).flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.takeString(LIBMTP_Get_Modelname(dev))
        serial = Self.takeString(LIBMTP_Get_Serialnumber(dev))
        LIBMTP_Clear_Errorstack(dev)
    }

    func close() {
        if let dev = device {
            LIBMTP_Release_Device(dev)
            device = nil
        }
        storageID = 0
        name = nil
        serial = nil
    }

    func deviceName() -> String? { name }
    func serialNumber() -> String? { serial }

    func ping() throws {
        let dev = try openDevice()
        if !isAlive(dev) {
            throw MtpError(.disconnected, "Lost the USB connection to the device.")
        }
    }

    // MARK: - Error handling

    private func openDevice() throws -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
        guard let dev = device else { throw MtpError(.disconnected, "No open MTP session.") }
        LIBMTP_Clear_Errorstack(dev)   // so a failure below is attributed correctly
        return dev
    }

    /// Cheap round-trip (re-reads storage info) that fails if the transport is dead.
    private func isAlive(_ dev: UnsafeMutablePointer<LIBMTP_mtpdevice_t>) -> Bool {
        let rc = LIBMTP_Get_Storage(dev, Int32(LIBMTP_STORAGE_SORTBY_NOTSORTED))
        LIBMTP_Clear_Errorstack(dev)
        return rc != -1
    }

    /// Drain and clear libmtp's error stack.
    private func drainErrors(_ dev: UnsafeMutablePointer<LIBMTP_mtpdevice_t>) -> [(kind: LibmtpErrorKind, text: String)] {
        var out: [(kind: LibmtpErrorKind, text: String)] = []
        var node = LIBMTP_Get_Errorstack(dev)
        while let cur = node {
            let text = cur.pointee.error_text.map { String(cString: $0) } ?? ""
            out.append((Self.kind(cur.pointee.errornumber), text))
            node = cur.pointee.next
        }
        LIBMTP_Clear_Errorstack(dev)
        return out
    }

    private static func kind(_ n: LIBMTP_error_number_t) -> LibmtpErrorKind {
        switch n {
        case LIBMTP_ERROR_PTP_LAYER: return .ptpLayer
        case LIBMTP_ERROR_USB_LAYER: return .usbLayer
        case LIBMTP_ERROR_MEMORY_ALLOCATION: return .memory
        case LIBMTP_ERROR_NO_DEVICE_ATTACHED: return .noDeviceAttached
        case LIBMTP_ERROR_STORAGE_FULL: return .storageFull
        case LIBMTP_ERROR_CONNECTING: return .connecting
        case LIBMTP_ERROR_CANCELLED: return .cancelled
        default: return .general
        }
    }

    /// Build the error for a failed call: classify the error stack, and if
    /// that's empty or generic, probe the transport to catch a dead session.
    private func failure(_ dev: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, _ what: String,
                         fallback: MtpFailure = .failed) -> MtpError {
        let stack = drainErrors(dev)
        var kind = MtpErrorClassifier.classify(stack) ?? fallback
        if (stack.isEmpty || kind == .failed) && !isAlive(dev) {
            kind = .disconnected
        }
        let detail = stack.map(\.text).filter { !$0.isEmpty }.joined(separator: "; ")
        log.debug("\(what, privacy: .public): \(kind.rawValue) \(detail, privacy: .public)")
        return MtpError(kind, detail.isEmpty ? what : "\(what): \(detail)")
    }

    // MARK: - Reads

    /// List the children of `parent` (`MtpAgentConfig.rootParent` for the top of storage).
    func list(parent: UInt32) throws -> [MtpEntry] {
        let dev = try openDevice()
        let atRoot = parent == MtpAgentConfig.rootParent
        let parentArg = atRoot ? listRootParent : parent

        var out: [MtpEntry] = []
        let head = LIBMTP_Get_Files_And_Folders(dev, storageID, parentArg)
        var node = head
        while let cur = node {
            let entry = Self.entry(cur.pointee)
            // Some devices ignore the parent filter (notably at the root) and
            // return more; keep only true children of this folder and storage.
            let isChild = atRoot
                ? (entry.parentID == MtpAgentConfig.rootParent || entry.parentID == listRootParent)
                : entry.parentID == parent
            if isChild && entry.storageID == storageID { out.append(entry) }
            node = cur.pointee.next
            LIBMTP_destroy_file_t(cur)
        }
        // NULL means "empty folder" *or* "failed"; the error stack (or a probe)
        // tells them apart, so an unplugged device isn't shown as empty.
        let stack = drainErrors(dev)
        if head == nil {
            let detail = stack.map(\.text).joined(separator: "; ")
            switch MtpErrorClassifier.classify(stack) {
            case nil:
                if !isAlive(dev) { throw MtpError(.disconnected, "Lost the USB connection to the device.") }
            case .failed?:
                throw MtpError(isAlive(dev) ? .failed : .disconnected, "Listing folder \(parent) failed: \(detail)")
            case let kind?:
                throw MtpError(kind, "Listing folder \(parent) failed: \(detail)")
            }
        }
        return out
    }

    /// Metadata for a single object id, or nil if it doesn't exist.
    func metadata(id: UInt32) throws -> MtpEntry? {
        let dev = try openDevice()
        guard let p = LIBMTP_Get_Filemetadata(dev, id) else {
            let e = failure(dev, "Reading object \(id)", fallback: .noSuchObject)
            if e.kind == .noSuchObject { return nil }
            throw e
        }
        defer { LIBMTP_destroy_file_t(p) }
        return Self.entry(p.pointee)
    }

    private static func entry(_ f: LIBMTP_file_t) -> MtpEntry {
        MtpEntry(
            id: f.item_id,
            parentID: f.parent_id,
            storageID: f.storage_id,
            name: f.filename.map { String(cString: $0) } ?? "",
            size: f.filesize,
            isFolder: f.filetype == LIBMTP_FILETYPE_FOLDER,
            modified: Double(f.modificationdate)
        )
    }

    /// Stream object `id` into an already-open file descriptor (owned by the
    /// caller). Lets the sandboxed extension own the destination file.
    func download(id: UInt32, toFileDescriptor fd: Int32, progress: TransferProgress?) throws {
        let dev = try openDevice()
        let rc = Self.withCallback(progress) { cb, data in
            LIBMTP_Get_File_To_File_Descriptor(dev, id, fd, cb, data)
        }
        if rc != 0 { throw failure(dev, "Downloading object \(id)") }
    }

    // MARK: - Writes

    /// The parent to pass to libmtp's write calls for the top of storage.
    private static func writeParent(_ parent: UInt32) -> UInt32 {
        parent == MtpAgentConfig.rootParent ? 0 : parent
    }

    /// Upload the bytes of an open (read) file descriptor as a new file named
    /// `name` under `parent`, with `size` bytes. Returns the new object id.
    /// A failed transfer's partial object is deleted.
    func upload(fromFileDescriptor fd: Int32, parent: UInt32, name: String, size: UInt64,
                progress: TransferProgress?) throws -> UInt32 {
        let dev = try openDevice()
        guard let meta = LIBMTP_new_file_t() else { throw MtpError(.failed, "Out of memory.") }
        defer { LIBMTP_destroy_file_t(meta) }   // frees filename too
        meta.pointee.parent_id = Self.writeParent(parent)
        meta.pointee.storage_id = storageID
        meta.pointee.filesize = size
        meta.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
        meta.pointee.filename = strdup(name)
        let rc = Self.withCallback(progress) { cb, data in
            LIBMTP_Send_File_From_File_Descriptor(dev, fd, meta, cb, data)
        }
        if rc != 0 {
            let e = failure(dev, "Uploading “\(name)”")
            // SendObjectInfo may already have created the object; don't leave
            // a truncated file behind.
            let partial = meta.pointee.item_id
            if partial != 0 && !e.kind.isTransport {
                _ = LIBMTP_Delete_Object(dev, partial)
                LIBMTP_Clear_Errorstack(dev)
            }
            throw e
        }
        return meta.pointee.item_id
    }

    /// Create a folder named `name` under `parent`. Returns the new folder id.
    func createFolder(name: String, parent: UInt32) throws -> UInt32 {
        let dev = try openDevice()
        // libmtp may rewrite the name in place (7-bit-only devices), so give it
        // a buffer it's allowed to mutate.
        guard let cname = strdup(name) else { throw MtpError(.failed, "Out of memory.") }
        defer { free(cname) }
        let id = LIBMTP_Create_Folder(dev, cname, Self.writeParent(parent), storageID)
        if id == 0 { throw failure(dev, "Creating folder “\(name)”") }
        return id
    }

    /// Delete an object (file or empty folder) by id.
    func delete(id: UInt32) throws {
        let dev = try openDevice()
        if LIBMTP_Delete_Object(dev, id) != 0 { throw failure(dev, "Deleting object \(id)") }
    }

    /// Rename an object (file or folder) by id.
    func rename(id: UInt32, to newName: String) throws {
        let dev = try openDevice()
        guard let f = LIBMTP_Get_Filemetadata(dev, id) else {
            throw failure(dev, "Reading object \(id)", fallback: .noSuchObject)
        }
        defer { LIBMTP_destroy_file_t(f) }
        let rc = newName.withCString { LIBMTP_Set_File_Name(dev, f, $0) }
        if rc != 0 { throw failure(dev, "Renaming object \(id)") }
    }

    /// Move an object to a new parent folder.
    func move(id: UInt32, toParent parent: UInt32) throws {
        let dev = try openDevice()
        guard LIBMTP_Check_Capability(dev, LIBMTP_DEVICECAP_MoveObject) != 0 else {
            throw MtpError(.unsupported, "This device can't move files between folders.")
        }
        let rc = LIBMTP_Move_Object(dev, id, storageID, Self.writeParent(parent))
        if rc != 0 { throw failure(dev, "Moving object \(id)") }
    }

    // MARK: - Utilities

    /// Take ownership of a malloc'd C string.
    private static func takeString(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// Bridges a Swift progress closure to libmtp's C callback for the duration of `body`.
    private static func withCallback<R>(
        _ progress: TransferProgress?,
        _ body: (LIBMTP_progressfunc_t?, UnsafeRawPointer?) -> R
    ) -> R {
        guard let progress else { return body(nil, nil) }
        let box = ProgressBox(progress)
        return withExtendedLifetime(box) {
            body(progressTrampoline, UnsafeRawPointer(Unmanaged.passUnretained(box).toOpaque()))
        }
    }
}

private final class ProgressBox {
    let report: TransferProgress
    init(_ report: @escaping TransferProgress) { self.report = report }
}

/// libmtp progress callback: non-zero return cancels the transfer.
private let progressTrampoline: LIBMTP_progressfunc_t = { sent, total, data in
    guard let data else { return 0 }
    let box = Unmanaged<ProgressBox>.fromOpaque(data).takeUnretainedValue()
    return box.report(sent, total) ? 0 : 1
}
