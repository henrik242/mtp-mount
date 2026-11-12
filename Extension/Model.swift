import Foundation
import FileProvider

/// Maps between File Provider item identifiers (strings) and MTP object ids (UInt32).
///
/// - `.rootContainer` ⇄ the top of the device storage (`rootParent`).
/// - every other item ⇄ its decimal MTP object id, e.g. "16".
enum MtpID {
    /// libmtp's storage-root sentinel (0xFFFFFFFF); such a parent means top level.
    static let storageRootSentinel: UInt32 = 0xFFFF_FFFF

    /// The MTP parent to list for a given container identifier, or nil if the
    /// identifier isn't a browsable MTP container.
    static func listParent(for id: NSFileProviderItemIdentifier) -> UInt32? {
        if id == .rootContainer { return MtpAgentConfig.rootParent }
        return UInt32(id.rawValue)
    }

    /// Identifier for an MTP object id.
    static func identifier(forObject objectID: UInt32) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(rawValue: "\(objectID)")
    }

    /// Identifier for an entry's parent, folding top-level parents to the root.
    static func parentIdentifier(forParent parentID: UInt32) -> NSFileProviderItemIdentifier {
        if parentID == MtpAgentConfig.rootParent || parentID == storageRootSentinel {
            return .rootContainer
        }
        return identifier(forObject: parentID)
    }
}
