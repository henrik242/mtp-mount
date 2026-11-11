import FileProvider
import UniformTypeIdentifiers

/// Adapts a `Node` to the `NSFileProviderItem` protocol the system consumes.
final class FileProviderItem: NSObject, NSFileProviderItem {
    private let node: Node

    init(_ node: Node) {
        self.node = node
    }

    var itemIdentifier: NSFileProviderItemIdentifier { node.id }
    var parentItemIdentifier: NSFileProviderItemIdentifier { node.parent }
    var filename: String { node.name }

    var contentType: UTType {
        node.isFolder ? .folder : (UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data)
    }

    var capabilities: NSFileProviderItemCapabilities {
        // Read-only for now (Phase 1 stays read-only; writes are a later phase).
        node.isFolder ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
    }

    var documentSize: NSNumber? {
        node.isFolder ? nil : NSNumber(value: node.size)
    }

    var childItemCount: NSNumber? {
        node.isFolder ? NSNumber(value: FakeTree.children(of: node.id).count) : nil
    }

    /// Stable version so the system knows when content/metadata changed.
    /// Phase 1 derives these from MTP modification time / object id.
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: Data("c1-\(node.size)".utf8),
            metadataVersion: Data("m1-\(node.name)".utf8)
        )
    }
}
