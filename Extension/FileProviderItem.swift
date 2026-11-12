import FileProvider
import UniformTypeIdentifiers

/// Adapts an `MtpEntry` (or the synthetic root) to `NSFileProviderItem`.
final class FileProviderItem: NSObject, NSFileProviderItem {
    private let id: NSFileProviderItemIdentifier
    private let parent: NSFileProviderItemIdentifier
    private let name: String
    private let isFolder: Bool
    private let size: UInt64
    private let modified: Double

    /// Wrap a real MTP entry.
    init(entry: MtpEntry) {
        self.id = MtpID.identifier(forObject: entry.id)
        self.parent = MtpID.parentIdentifier(forParent: entry.parentID)
        self.name = entry.name
        self.isFolder = entry.isFolder
        self.size = entry.size
        self.modified = entry.modified
    }

    /// The synthetic root container (the device itself).
    init(root displayName: String) {
        self.id = .rootContainer
        self.parent = .rootContainer
        self.name = displayName
        self.isFolder = true
        self.size = 0
        self.modified = 0
    }

    var itemIdentifier: NSFileProviderItemIdentifier { id }
    var parentItemIdentifier: NSFileProviderItemIdentifier { parent }
    var filename: String { name }

    var contentType: UTType {
        if isFolder { return .folder }
        let ext = (name as NSString).pathExtension
        return UTType(filenameExtension: ext) ?? .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        // Read-only (Phase 1). Writes are a later phase.
        isFolder ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
    }

    var documentSize: NSNumber? {
        isFolder ? nil : NSNumber(value: size)
    }

    var contentModificationDate: Date? {
        modified > 0 ? Date(timeIntervalSince1970: modified) : nil
    }

    /// Versions the system uses to detect content/metadata changes. Derived from
    /// MTP size + modification time, so a changed file re-materializes.
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: Data("\(size)-\(modified)".utf8),
            metadataVersion: Data("\(name)-\(parent.rawValue)".utf8)
        )
    }
}
