// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import FileProvider

/// Maps between File Provider item identifiers (strings) and MTP object ids (UInt32).
///
/// - `.rootContainer` ⇄ the top of the device storage (`rootParent`).
/// - every other item ⇄ its decimal MTP object id, e.g. "16".
enum MtpID {
    /// MTP's storage-root sentinel (0xFFFFFFFF); such a parent means top level.
    static let storageRootSentinel: UInt32 = 0xFFFF_FFFF

    /// The MTP parent to list for a given container identifier, or nil if the
    /// identifier isn't a browsable MTP container.
    static func listParent(for id: NSFileProviderItemIdentifier) -> UInt32? {
        if id == .rootContainer { return MtpAgentConfig.rootParent }
        return objectID(for: id)
    }

    /// The MTP object id an item identifier names (nil for the root and for
    /// system containers such as the Trash or the working set).
    static func objectID(for id: NSFileProviderItemIdentifier) -> UInt32? {
        guard id != .rootContainer, let value = UInt32(id.rawValue),
              value != MtpAgentConfig.rootParent, value != storageRootSentinel else { return nil }
        return value
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
