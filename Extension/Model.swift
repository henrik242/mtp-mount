import Foundation
import FileProvider

/// A single node in the (currently static) tree the extension serves.
struct Node {
    let id: NSFileProviderItemIdentifier
    let parent: NSFileProviderItemIdentifier
    let name: String
    let isFolder: Bool
    let size: Int
}

/// Phase 0: a fixed, in-memory tree so we can prove the File Provider pipeline
/// (domain registration, enumeration, content fetch) before wiring up MTP.
/// Phase 1 replaces this with data from the libmtp agent.
enum FakeTree {
    static let activities = NSFileProviderItemIdentifier("Activities")
    static let ride1 = NSFileProviderItemIdentifier("Activities/2026-11-10-073000.fit")
    static let ride2 = NSFileProviderItemIdentifier("Activities/2026-11-11-181500.fit")
    static let readme = NSFileProviderItemIdentifier("README.txt")

    static let nodes: [NSFileProviderItemIdentifier: Node] = [
        .rootContainer: Node(id: .rootContainer, parent: .rootContainer,
                             name: "Garmin", isFolder: true, size: 0),
        activities: Node(id: activities, parent: .rootContainer,
                         name: "Activities", isFolder: true, size: 0),
        ride1: Node(id: ride1, parent: activities,
                    name: "2026-11-10-073000.fit", isFolder: false, size: 4096),
        ride2: Node(id: ride2, parent: activities,
                    name: "2026-11-11-181500.fit", isFolder: false, size: 8192),
        readme: Node(id: readme, parent: .rootContainer,
                     name: "README.txt", isFolder: false, size: 128),
    ]

    static func node(_ id: NSFileProviderItemIdentifier) -> Node? {
        nodes[id]
    }

    static func children(of parent: NSFileProviderItemIdentifier) -> [Node] {
        nodes.values
            .filter { $0.parent == parent && $0.id != parent }
            .sorted { $0.name < $1.name }
    }

    /// Deterministic placeholder bytes so a copied file has real content.
    static func contents(of node: Node) -> Data {
        if node.id == readme {
            let text = "Garmin MTP Mount — Phase 0 test tree.\nNo device is connected yet.\n"
            return Data(text.utf8)
        }
        var data = Data(capacity: node.size)
        for i in 0..<node.size { data.append(UInt8(i & 0xFF)) }
        return data
    }
}
