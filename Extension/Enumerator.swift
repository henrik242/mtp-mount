// SPDX-License-Identifier: GPL-2.0-or-later
import FileProvider
import os

/// Enumerates the children of one container by asking the agent to list the
/// matching MTP folder on demand.
///
/// Change tracking: object handles are only valid within one USB session, so
/// the sync anchor (`SyncAnchor`) names the device session plus a position in
/// the agent's journal of MTP events (objects added/removed on the device).
/// Within a session, `enumerateChanges` reports those changes item by item;
/// when the device was replugged or swapped, or the journal can't describe
/// the changes, it answers `.syncAnchorExpired` and the system re-enumerates
/// from scratch. The agent signals the working set whenever either happens.
final class Enumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let agent: AgentClient

    init(container: NSFileProviderItemIdentifier, agent: AgentClient) {
        self.container = container
        self.agent = agent
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
        guard let from = SyncAnchor(anchor.rawValue) else {
            // We were offline (or the anchor is from an older version): if a
            // device is back, start over; otherwise there's nothing to report.
            agent.overview { result in
                if SyncAnchor.make((try? result.get())?.device(self.agent.device)) == anchor.rawValue {
                    observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                } else {
                    observer.finishEnumeratingWithError(fpError(.syncAnchorExpired))
                }
            }
            return
        }
        agent.changes(since: from.seq) { result in
            switch result {
            case .failure(let error):
                // No device: keep what the system has and try again later.
                observer.finishEnumeratingWithError(error)
            case .success(let changes):
                guard from.continues(changes) else {
                    extLog.info("device session changed; asking the system to re-enumerate")
                    observer.finishEnumeratingWithError(fpError(.syncAnchorExpired))
                    return
                }
                if !changes.updated.isEmpty {
                    observer.didUpdate(changes.updated.map { FileProviderItem(entry: $0) })
                }
                if !changes.deleted.isEmpty {
                    observer.didDeleteItems(withIdentifiers: changes.deleted.map { MtpID.identifier(forObject: $0) })
                }
                let next = SyncAnchor(serial: changes.serial, sessionID: changes.sessionID, seq: changes.latestSeq)
                observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(next.data), moreComing: false)
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        agent.overview { result in
            completionHandler(NSFileProviderSyncAnchor(SyncAnchor.make((try? result.get())?.device(self.agent.device))))
        }
    }
}
