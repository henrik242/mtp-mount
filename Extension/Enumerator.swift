import FileProvider
import os

/// Enumerates the children of one container by asking the agent to list the
/// matching MTP folder on demand.
///
/// Change tracking: MTP can't report changes, and object handles are only
/// valid within one USB session. So the sync anchor names the device session
/// (`SyncAnchor`); while it's unchanged there is nothing to report, and when the
/// device was replugged, swapped or lost, `enumerateChanges` answers
/// `.syncAnchorExpired` and the system re-enumerates from scratch. The agent
/// signals the working set whenever its session changes.
final class Enumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let agent = AgentClient.shared

    init(container: NSFileProviderItemIdentifier) {
        self.container = container
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        // Nothing is pinned offline, so the working set itself is empty; the
        // system still asks it for changes to materialized items.
        if container == .workingSet {
            observer.finishEnumerating(upTo: nil)
            return
        }
        guard let parent = MtpID.listParent(for: container) else {
            observer.finishEnumeratingWithError(fpError(.noSuchItem))
            return
        }
        agent.list(parent: parent) { result in
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
        agent.status { result in
            let current = SyncAnchor.make(try? result.get())
            if current == anchor.rawValue {
                observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            } else {
                extLog.info("sync anchor changed; asking the system to re-enumerate")
                observer.finishEnumeratingWithError(fpError(.syncAnchorExpired))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        agent.status { result in
            completionHandler(NSFileProviderSyncAnchor(SyncAnchor.make(try? result.get())))
        }
    }
}
