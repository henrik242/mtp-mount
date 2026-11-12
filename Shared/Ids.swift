import Foundation
import FileProvider

/// Shared identifiers used by both the container app and the extension.
enum FP {
    /// Domain identifier — stable string, not shown to the user.
    static let domainIdentifier = NSFileProviderDomainIdentifier(rawValue: "MtpDevice")
    /// Display name — becomes the label in Finder's sidebar and the
    /// ~/Library/CloudStorage folder name. Fixed for the domain's lifetime,
    /// so it names no particular device.
    static let domainDisplayName = "MTP Device"

    /// The one domain this provider serves.
    static var domain: NSFileProviderDomain {
        NSFileProviderDomain(identifier: domainIdentifier, displayName: domainDisplayName)
    }
}
