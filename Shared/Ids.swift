import Foundation
import FileProvider

/// Shared identifiers used by both the container app and the extension.
enum FP {
    /// Domain identifier — stable string, not shown to the user.
    static let domainIdentifier = NSFileProviderDomainIdentifier(rawValue: "GarminEdge")
    /// Display name — becomes the label in Finder's sidebar and the
    /// ~/Library/CloudStorage folder name.
    static let domainDisplayName = "Garmin Edge"

    /// The one domain this provider serves.
    static var domain: NSFileProviderDomain {
        NSFileProviderDomain(identifier: domainIdentifier, displayName: domainDisplayName)
    }
}
