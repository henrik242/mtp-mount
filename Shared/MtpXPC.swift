import Foundation

/// One entry (file or folder) in the MTP object tree. Shared wire type: the agent
/// encodes `[MtpEntry]` as JSON, the extension decodes it. Foundation-only so the
/// sandboxed extension never links libmtp.
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

    /// Whether the USB session is unusable afterwards and must be reopened.
    var isTransport: Bool { self == .disconnected }
}

/// Snapshot of the agent's device session, JSON-encoded over XPC.
struct AgentStatus: Codable, Equatable {
    var connected: Bool
    var deviceName: String?
    var serial: String?
    /// Identifies one continuous USB session of one agent process. Changes
    /// whenever the device is (re)opened, so object handles cached under an
    /// older value may no longer refer to the same objects.
    var sessionID: String?
    var failure: MtpFailure?
    var message: String?
}

/// Shared configuration + XPC contract between the non-sandboxed libmtp agent
/// and the sandboxed File Provider extension. Foundation-only on purpose so the
/// command-line agent target doesn't have to link FileProvider.
enum MtpAgentConfig {
    /// Apple Developer team that signs every component.
    static let teamID = "358L7UXVJ4"
    /// Logging subsystem shared by all components.
    static let logSubsystem = "no.synth.mtpmount"
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
/// failures arrive as an `NSError` in `MtpAgentConfig.errorDomain`.
@objc protocol MtpAgentXPC {
    /// JSON-encoded `AgentStatus`. Opens the device if needed and checks that an
    /// open session is still alive.
    func status(reply: @escaping (_ json: Data?) -> Void)
    /// JSON-encoded `[MtpEntry]` for the children of `parent` (`rootParent` = top).
    func list(parent: UInt32, reply: @escaping (_ json: Data?, _ error: NSError?) -> Void)
    /// JSON-encoded `MtpEntry` for a single object; fails with `.noSuchObject`
    /// if it no longer exists.
    func item(objectID: UInt32, reply: @escaping (_ json: Data?, _ error: NSError?) -> Void)
    /// Stream object `objectID` into the open file `destination` (the caller owns
    /// and created it, e.g. in its own sandbox). Passing a FileHandle sends the
    /// underlying fd over XPC. Reports byte progress through the caller's
    /// current `Progress`, and stops if it is cancelled.
    func fetch(objectID: UInt32,
               into destination: FileHandle,
               reply: @escaping (_ error: NSError?) -> Void)

    // MARK: Writes

    /// Upload `size` bytes read from `source` as a new file `name` under `parent`.
    /// Replies with the new object id. Progress/cancellation as for `fetch`.
    func upload(parent: UInt32, name: String, size: UInt64, from source: FileHandle,
                reply: @escaping (_ newObjectID: UInt32, _ error: NSError?) -> Void)
    /// Create a folder `name` under `parent`. Replies with the new folder id.
    func createFolder(parent: UInt32, name: String,
                      reply: @escaping (_ newObjectID: UInt32, _ error: NSError?) -> Void)
    /// Delete an object. A non-empty folder fails with `.directoryNotEmpty`
    /// unless `recursive` is set.
    func delete(objectID: UInt32, recursive: Bool, reply: @escaping (_ error: NSError?) -> Void)
    /// Rename an object by id.
    func rename(objectID: UInt32, to newName: String,
                reply: @escaping (_ error: NSError?) -> Void)
    /// Move an object to a new parent folder.
    func move(objectID: UInt32, toParent newParent: UInt32,
              reply: @escaping (_ error: NSError?) -> Void)
}

/// File Provider sync anchors derived from the agent's device session: the
/// device's serial plus the session id, so a replug, a different device or an
/// agent restart all yield a new anchor (and a full re-enumeration).
enum SyncAnchor {
    static func make(_ status: AgentStatus?) -> Data {
        guard let status, status.connected, let session = status.sessionID else {
            return Data("offline".utf8)
        }
        return Data("\(status.serial ?? "unknown")|\(session)".utf8)
    }
}
