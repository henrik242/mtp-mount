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

/// Shared configuration + XPC contract between the non-sandboxed libmtp agent
/// and the sandboxed File Provider extension. Foundation-only on purpose so the
/// command-line agent target doesn't have to link FileProvider.
enum MtpAgentConfig {
    /// launchd job label for the helper agent.
    static let agentLabel = "no.synth.mtpmount.helper"
    /// launchd-registered mach service the agent vends and the extension looks up.
    /// The extension needs the matching `temporary-exception.mach-lookup.global-name`.
    static let machServiceName = "358L7UXVJ4.no.synth.mtpmount.helper"
    /// App group both sides share; the agent drops fetched files here for the
    /// sandboxed extension to read.
    static let appGroup = "358L7UXVJ4.no.synth.mtpmount"
    /// Sentinel parent id meaning "top of storage".
    static let rootParent: UInt32 = 0
}

/// XPC interface the agent exports. All methods are async with reply blocks.
/// `list`/`fetch` return an optional error *message* (nil on success) instead of
/// NSError, to keep the wire contract trivial.
@objc protocol MtpAgentXPC {
    /// Whether a device session is currently open, and its name if so.
    func status(reply: @escaping (_ connected: Bool, _ deviceName: String?) -> Void)
    /// JSON-encoded `[MtpEntry]` for the children of `parent` (`rootParent` = top).
    func list(parent: UInt32, reply: @escaping (_ json: Data?, _ errorMessage: String?) -> Void)
    /// JSON-encoded `MtpEntry` for a single object, or nil data if it no longer exists.
    func item(objectID: UInt32, reply: @escaping (_ json: Data?, _ errorMessage: String?) -> Void)
    /// Stream object `objectID` into the open file `destination` (the caller owns
    /// and created it, e.g. in its own sandbox). Replies nil on success or an
    /// error message. Passing a FileHandle sends the underlying fd over XPC.
    func fetch(objectID: UInt32,
               into destination: FileHandle,
               reply: @escaping (_ errorMessage: String?) -> Void)
}
