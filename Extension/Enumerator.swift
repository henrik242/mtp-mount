import FileProvider
import os

/// Enumerates the children of one container by asking the agent to list the
/// matching MTP folder on demand.
final class Enumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier

    init(container: NSFileProviderItemIdentifier) {
        self.container = container
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        // Working set (offline/spotlight) stays empty for a read-only, on-demand mount.
        if container == .workingSet {
            observer.finishEnumerating(upTo: nil)
            return
        }
        guard let parent = MtpID.listParent(for: container) else {
            observer.finishEnumerating(upTo: nil)
            return
        }
        AgentClient.shared.list(parent: parent) { result in
            switch result {
            case .success(let entries):
                observer.didEnumerate(entries.map { FileProviderItem(entry: $0) })
                observer.finishEnumerating(upTo: nil)
            case .failure(let error):
                extLog.error("enumerate \(self.container.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        // No push from the device; re-enumeration is driven by signalEnumerator.
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("v1".utf8)))
    }
}
