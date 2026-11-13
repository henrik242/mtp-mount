// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// One entry (file or folder) in the MTP object tree. Shared wire type: the agent
/// encodes `[MtpEntry]` as JSON, the extension decodes it. Foundation-only so the
/// sandboxed extension never touches USB.
struct MtpEntry: Codable, Equatable {
    var id: UInt32
    var parentID: UInt32
    var storageID: UInt32
    var name: String
    var size: UInt64
    var isFolder: Bool
    /// Seconds since 1970 (0 if the device reported none).
    var modified: Double
}

/// Why an agent call failed. Sent over XPC as the `code` of an NSError in
/// `MtpAgentConfig.errorDomain`; the extension maps it to a File Provider error.
enum MtpFailure: Int, Codable, CaseIterable {
    /// No MTP device on USB.
    case noDevice = 1
    /// A device is there but couldn't be opened — usually another app
    /// (Image Capture, Android File Transfer, a vendor sync app) holds it, or
    /// a phone is locked / not in file-transfer mode.
    case deviceBusy
    /// The USB/PTP transport failed (unplugged, timed out, I/O error).
    case disconnected
    case noSuchObject
    /// The device doesn't implement the operation (e.g. MoveObject).
    case unsupported
    case storageFull
    case accessDenied
    case directoryNotEmpty
    case nameCollision
    case cancelled
    /// Anything else the device refused.
    case failed
    /// A camera (all storage in the camera file system, DCF): not a file
    /// device, so it's released and left to Image Capture / Photos.
    case notFileDevice

    /// Whether the USB session is unusable afterwards and must be reopened.
    var isTransport: Bool { self == .disconnected }
}

/// One open device, as the agent reports it (JSON over XPC).
struct DeviceStatus: Codable, Equatable {
    /// Stable identifier of the device (see `DeviceKey`); also the identifier
    /// of its File Provider domain.
    var key: String
    var name: String
    var serial: String?
    /// Identifies one continuous USB session of one agent process. Changes
    /// whenever the device is (re)opened, so object handles cached under an
    /// older value may no longer refer to the same objects.
    var sessionID: String
    /// Position in the session's change journal (see `ChangeSet`).
    var changeSeq: UInt64 = 0
}

/// Everything the agent knows about attached devices (JSON over XPC).
struct AgentOverview: Codable, Equatable {
    var devices: [DeviceStatus]
    /// Why a device that's attached isn't listed (e.g. `.deviceBusy`), if any.
    var problem: MtpFailure?
    var message: String?
    /// Names of attached cameras that were left alone (see `.notFileDevice`).
    var ignoredDevices: [String] = []

    func device(_ key: String) -> DeviceStatus? { devices.first { $0.key == key } }
}

/// Stable per-device identifiers: the USB serial number when the device has
/// one, otherwise vendor/product id (so two identical serial-less devices
/// would share a location — rare for MTP devices).
enum DeviceKey {
    static let prefix = "mtp-"

    static func make(serial: String?, vendor: UInt16, product: UInt16) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        if let serial {
            let cleaned = String(serial.filter { allowed.contains($0) })
            if !cleaned.isEmpty { return prefix + cleaned }
        }
        return prefix + String(format: "%04x-%04x", vendor, product)
    }

    static func isDeviceKey(_ value: String) -> Bool { value.hasPrefix(prefix) }
}

/// Changes the device reported (MTP events) since a journal position, JSON
/// over XPC. `expired` means they can't be described item by item (journal
/// overflowed, a storage came or went, or the session changed): the caller
/// must re-enumerate.
struct ChangeSet: Codable, Equatable {
    var serial: String?
    var sessionID: String
    var latestSeq: UInt64
    var expired: Bool
    var updated: [MtpEntry]
    var deleted: [UInt32]
}

/// Shared configuration + XPC contract between the non-sandboxed agent
/// and the sandboxed File Provider extension. Foundation-only on purpose so the
/// command-line agent target doesn't have to link FileProvider.
enum MtpAgentConfig {
    /// Apple Developer team that signs every component.
    static let teamID = "358L7UXVJ4"
    /// Logging subsystem shared by all components.
    static let logSubsystem = "no.synth.mtpmount"
    /// Launch argument that makes the app add domains for attached devices
    /// and quit (used by the agent when it may not add domains itself).
    static let syncDomainsArgument = "--sync-domains"

    /// File name of the helper executable in Contents/MacOS.
    static let agentExecutable = "mtpmount-agent"
    /// launchd job label for the helper agent.
    static let agentLabel = "no.synth.mtpmount.helper"
    /// launchd-registered mach service the agent vends and the extension looks up.
    /// The extension needs the matching `temporary-exception.mach-lookup.global-name`.
    static let machServiceName = "\(teamID).no.synth.mtpmount.helper"
    /// Sentinel parent id meaning "top of storage".
    static let rootParent: UInt32 = 0
    /// NSError domain of agent failures; the code is an `MtpFailure` raw value.
    static let errorDomain = "no.synth.mtpmount.agent"

    /// Bundle identifiers allowed to talk to the agent: the File Provider
    /// extension and the container app (for device status).
    static let clientIdentifiers = ["no.synth.mtpmount.fileprovider", "no.synth.mtpmount"]

    /// Code-signing requirement the agent enforces on incoming XPC connections.
    /// The agent is unsandboxed and owns the USB device, so only our own
    /// team-signed extension/app may drive it.
    static var clientRequirement: String {
        let ids = clientIdentifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and (\(ids))"
    }

    /// Requirement the client enforces on the agent it connects to.
    static var agentRequirement: String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}

extension NSError {
    /// An agent failure as sent over XPC.
    static func mtp(_ failure: MtpFailure, _ message: String) -> NSError {
        NSError(domain: MtpAgentConfig.errorDomain, code: failure.rawValue,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// The agent failure this error carries, if it is one.
    var mtpFailure: MtpFailure? {
        domain == MtpAgentConfig.errorDomain ? MtpFailure(rawValue: code) : nil
    }
}

/// XPC interface the agent exports. All methods are async with reply blocks;
/// failures arrive as an `NSError` in `MtpAgentConfig.errorDomain`. Every
/// device operation names its device by `DeviceKey`; an unknown or detached
/// device fails with `.noDevice`.
@objc protocol MtpAgentXPC {
    /// JSON-encoded `AgentOverview`: the open devices (after checking that
    /// they're alive and opening newly attached ones).
    func overview(reply: @escaping (_ json: Data?) -> Void)
    /// JSON-encoded `[MtpEntry]` for the children of `parent` (`rootParent` = top).
    func list(device: String, parent: UInt32, reply: @escaping (_ json: Data?, _ error: NSError?) -> Void)
    /// JSON-encoded `ChangeSet`: what the device reported since journal
    /// position `seq` of its current session.
    func changes(device: String, since seq: UInt64, reply: @escaping (_ json: Data?, _ error: NSError?) -> Void)
    /// JSON-encoded `MtpEntry` for a single object; fails with `.noSuchObject`
    /// if it no longer exists.
    func item(device: String, objectID: UInt32, reply: @escaping (_ json: Data?, _ error: NSError?) -> Void)
    /// Stream object `objectID` into the open file `destination` (the caller owns
    /// and created it, e.g. in its own sandbox). Passing a FileHandle sends the
    /// underlying fd over XPC. Reports byte progress through the caller's
    /// current `Progress`, and stops if it is cancelled.
    func fetch(device: String, objectID: UInt32, into destination: FileHandle,
               reply: @escaping (_ error: NSError?) -> Void)

    // MARK: Writes

    /// Upload `size` bytes read from `source` as a new file `name` under `parent`.
    /// Replies with the new object id. Progress/cancellation as for `fetch`.
    func upload(device: String, parent: UInt32, name: String, size: UInt64, from source: FileHandle,
                reply: @escaping (_ newObjectID: UInt32, _ error: NSError?) -> Void)
    /// Create a folder `name` under `parent`. Replies with the new folder id.
    func createFolder(device: String, parent: UInt32, name: String,
                      reply: @escaping (_ newObjectID: UInt32, _ error: NSError?) -> Void)
    /// Delete an object. A non-empty folder fails with `.directoryNotEmpty`
    /// unless `recursive` is set.
    func delete(device: String, objectID: UInt32, recursive: Bool, reply: @escaping (_ error: NSError?) -> Void)
    /// Rename an object by id.
    func rename(device: String, objectID: UInt32, to newName: String,
                reply: @escaping (_ error: NSError?) -> Void)
    /// Move an object to a new parent folder.
    func move(device: String, objectID: UInt32, toParent newParent: UInt32,
              reply: @escaping (_ error: NSError?) -> Void)
}

/// File Provider sync anchor: the device serial and session id (a replug, a
/// different device or an agent restart means a full re-enumeration) plus the
/// position in that session's change journal (changes since then are reported
/// item by item).
struct SyncAnchor: Codable, Equatable {
    var serial: String?
    var sessionID: String
    var seq: UInt64

    static let offline = Data("offline".utf8)

    /// The anchor for a device's current state (`offline` when not attached).
    static func make(_ status: DeviceStatus?) -> Data {
        guard let status else { return offline }
        return SyncAnchor(serial: status.serial, sessionID: status.sessionID, seq: status.changeSeq).data
    }

    var data: Data {
        // Deterministic key order: the anchor is persisted by Finder and
        // compared as raw bytes (see Enumerator), so the same state must
        // always encode to the same bytes.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)) ?? SyncAnchor.offline
    }

    /// Decode an anchor; nil for `offline` or anything unrecognised.
    init?(_ data: Data) {
        guard let anchor = try? JSONDecoder().decode(SyncAnchor.self, from: data) else { return nil }
        self = anchor
    }

    init(serial: String?, sessionID: String, seq: UInt64) {
        self.serial = serial
        self.sessionID = sessionID
        self.seq = seq
    }

    /// Whether a change set continues this anchor's session.
    func continues(_ changes: ChangeSet) -> Bool {
        !changes.expired && changes.sessionID == sessionID && changes.serial == serial && changes.latestSeq >= seq
    }
}
