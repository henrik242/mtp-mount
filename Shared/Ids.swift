import Foundation
import FileProvider

/// Shared identifiers used by both the container app and the extension.
enum FP {
    /// Domain identifier — stable string, not shown to the user.
    static let domainIdentifier = NSFileProviderDomainIdentifier(rawValue: "GarminEdge")
    /// Display name — becomes the label in Finder's sidebar and the
    /// ~/Library/CloudStorage folder name.
    static let domainDisplayName = "Garmin Edge"
    /// App Group shared between app + extension (team-prefixed on macOS).
    static let appGroup = "358L7UXVJ4.no.synth.mtpmount"
}
