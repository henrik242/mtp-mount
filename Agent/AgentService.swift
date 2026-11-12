import Foundation
import os

private let log = Logger(subsystem: MtpAgentConfig.logSubsystem, category: "agent")

/// Serializes all device work onto one queue (libmtp holds a single stateful USB
/// session) and vends it over XPC. Opens the device lazily, and drops the
/// session only when the transport fails, so unplug/replug recovers without
/// restarting the agent while ordinary refusals (name collision, unsupported
/// operation, …) keep the session.
final class AgentService: NSObject, MtpAgentXPC {
    /// How long a "no device" / "busy" result is reused before probing USB again,
    /// so a burst of Finder requests doesn't hammer USB enumeration.
    static let absentRetryInterval: TimeInterval = 2

    private let queue: DispatchQueue
    private let device: MtpDevice
    private let now: () -> Date
    /// Distinguishes this agent process, so session ids never repeat across restarts.
    private let instance = UUID().uuidString.prefix(8)
    private var epoch = 0
    private var lastAbsent: (at: Date, error: MtpError)?

    /// Journal of device-reported changes in the current session.
    private enum Change { case updated(UInt32), deleted(UInt32), rescan }
    static let journalLimit = 5_000
    private var journal: [(seq: UInt64, change: Change)] = []
    private var changeSeq: UInt64 = 0
    /// Positions at or below this are no longer covered by the journal.
    private var journalFloor: UInt64 = 0
    private var eventTimer: DispatchSourceTimer?

    /// Called on the device queue whenever a session opens or is lost, or the
    /// device reported changes: the File Provider should be signalled.
    var onChange: ((AgentStatus) -> Void)?
    /// Called when the device couldn't be released safely; the process should
    /// exit so launchd can start a fresh agent that can open it again.
    var onUnsafeClose: (() -> Void)?

    init(device: MtpDevice,
         queue: DispatchQueue = DispatchQueue(label: "no.synth.mtpmount.agent.mtp"),
         now: @escaping () -> Date = Date.init) {
        self.device = device
        self.queue = queue
        self.now = now
    }

    // MARK: - Session

    private var sessionID: String? { device.isOpen ? "\(instance)-\(epoch)" : nil }

    private func currentStatus(failure: MtpError? = nil) -> AgentStatus {
        AgentStatus(connected: device.isOpen,
                    deviceName: device.isOpen ? device.deviceName() : nil,
                    serial: device.isOpen ? device.serialNumber() : nil,
                    sessionID: sessionID,
                    changeSeq: changeSeq,
                    failure: failure?.kind,
                    message: failure?.message)
    }

    private func ensureOpen() throws {
        if device.isOpen { return }
        if let absent = lastAbsent, now().timeIntervalSince(absent.at) < Self.absentRetryInterval {
            throw absent.error
        }
        do {
            try device.open()
        } catch {
            let e = MtpError(error)
            lastAbsent = (now(), e)
            throw e
        }
        lastAbsent = nil
        epoch += 1
        journal = []
        changeSeq = 0
        journalFloor = 0
        log.info("opened device: \(self.device.deviceName() ?? "?", privacy: .public) session \(self.sessionID ?? "", privacy: .public)")
        onChange?(currentStatus())
    }

    /// Close the session after a transport failure; the next call reopens.
    private func dropSession(after error: MtpError) {
        guard device.isOpen else { return }
        log.error("dropping USB session: \(error.message, privacy: .public)")
        let released = device.close()
        onChange?(currentStatus(failure: error))
        if !released { onUnsafeClose?() }
    }

    // MARK: - Device events

    /// Poll the device for events every `interval` seconds on the device queue.
    func startEventPolling(interval: TimeInterval = 1) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.pollDeviceEventsOnQueue() }
        timer.resume()
        eventTimer = timer
    }

    /// One polling step (tests call this directly). Runs on the device queue.
    func pollDeviceEvents(completion: (() -> Void)? = nil) {
        queue.async {
            self.pollDeviceEventsOnQueue()
            completion?()
        }
    }

    private func pollDeviceEventsOnQueue() {
        guard device.isOpen else { return }
        let events = device.pollEvents()
        guard !events.isEmpty else { return }
        var changed = false
        for event in events {
            switch event {
            case .objectAdded(let id): record(.updated(id)); changed = true
            case .objectRemoved(let id): record(.deleted(id)); changed = true
            case .storageChanged: record(.rescan); changed = true
            case .linkLost:
                do { try device.ping() } catch { dropSession(after: MtpError(error)); return }
            }
        }
        if changed {
            log.info("device reported changes; journal at \(self.changeSeq)")
            onChange?(currentStatus())
        }
    }

    private func record(_ change: Change) {
        changeSeq += 1
        journal.append((changeSeq, change))
        if journal.count > Self.journalLimit {
            let dropped = journal.count - Self.journalLimit
            journalFloor = journal[dropped - 1].seq
            journal.removeFirst(dropped)
        }
    }

    /// Describe the journal after `seq` as updated entries and deleted ids.
    private func changeSet(since seq: UInt64) throws -> ChangeSet {
        guard let session = sessionID else { throw MtpError(.noDevice, "No MTP device connected.") }
        let entries = journal.filter { $0.seq > seq }
        var result = ChangeSet(serial: device.serialNumber(), sessionID: session, latestSeq: changeSeq,
                               expired: false, updated: [], deleted: [])
        if seq < journalFloor || seq > changeSeq || entries.contains(where: {
            if case .rescan = $0.change { return true } else { return false }
        }) {
            result.expired = true
            return result
        }
        // Last word per object wins; re-read added objects (they may be gone again).
        var latest: [UInt32: Bool] = [:]   // id → exists
        var order: [UInt32] = []
        for (_, change) in entries {
            switch change {
            case .updated(let id): if latest[id] == nil { order.append(id) }; latest[id] = true
            case .deleted(let id): if latest[id] == nil { order.append(id) }; latest[id] = false
            case .rescan: break
            }
        }
        for id in order {
            if latest[id] == true, let entry = try device.metadata(id: id) {
                result.updated.append(entry)
            } else {
                result.deleted.append(id)
            }
        }
        return result
    }

    /// Notification that USB devices came or went (from the hotplug monitor).
    /// Verifies a live session, or tries to open one, and reports changes.
    func usbDevicesChanged() {
        queue.async {
            self.lastAbsent = nil
            if self.device.isOpen {
                do { try self.device.ping() } catch { self.dropSession(after: MtpError(error)) }
            } else {
                try? self.ensureOpen()
            }
        }
    }

    /// Run `body` on the device queue with an open session and reply with its
    /// result or a mapped error.
    private func perform<T>(_ what: @autoclosure @escaping () -> String,
                            _ body: @escaping () throws -> T,
                            reply: @escaping (Result<T, MtpError>) -> Void) {
        queue.async {
            do {
                try self.ensureOpen()
                reply(.success(try body()))
            } catch {
                let e = MtpError(error)
                if e.kind.isTransport { self.dropSession(after: e) }
                log.error("\(what(), privacy: .public) failed: \(e.message, privacy: .public)")
                reply(.failure(e))
            }
        }
    }

    // MARK: - Helpers

    /// Fail with `.nameCollision` if `parent` already has a child called `name`
    /// (other than `excluding`). Compared case-insensitively: device storage is usually FAT/exFAT or a
    /// case-folding Android filesystem.
    private func checkNameFree(_ name: String, in parent: UInt32, excluding: UInt32? = nil) throws {
        let clash = try device.list(parent: parent).contains {
            $0.id != excluding && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
        if clash { throw MtpError(.nameCollision, "“\(name)” already exists in that folder.") }
    }

    private func existing(_ id: UInt32) throws -> MtpEntry {
        guard let entry = try device.metadata(id: id) else {
            throw MtpError(.noSuchObject, "No such object on the device.")
        }
        return entry
    }

    private func deleteTree(_ id: UInt32, recursive: Bool) throws {
        let entry = try existing(id)
        if entry.isFolder {
            let children = try device.list(parent: id)
            if !children.isEmpty {
                guard recursive else {
                    throw MtpError(.directoryNotEmpty, "The folder “\(entry.name)” is not empty.")
                }
                for child in children { try deleteTree(child.id, recursive: true) }
            }
        }
        try device.delete(id: id)
    }

    /// A transfer progress callback driving `progress` (the caller's progress
    /// propagated over XPC, if any) and honouring its cancellation.
    private static func transferProgress(_ progress: Progress?) -> TransferProgress? {
        guard let progress else { return nil }
        return { done, total in
            if total > 0, progress.totalUnitCount != Int64(total) {
                progress.totalUnitCount = Int64(total)
            }
            progress.completedUnitCount = Int64(done)
            return !progress.isCancelled
        }
    }

    /// The progress the XPC caller made current for this call, if any. Must be
    /// read synchronously in the exported method, before hopping queues.
    private static func callerProgress(size: UInt64) -> Progress? {
        guard Progress.current() != nil else { return nil }
        return Progress(totalUnitCount: Int64(max(size, 1)))
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    // MARK: - MtpAgentXPC

    func status(reply: @escaping (Data?) -> Void) {
        queue.async {
            var failure: MtpError?
            if self.device.isOpen {
                do { try self.device.ping() } catch {
                    let e = MtpError(error)
                    self.dropSession(after: e)
                    failure = e
                }
            }
            if !self.device.isOpen {
                do { try self.ensureOpen() } catch { failure = MtpError(error) }
            }
            reply(try? Self.encode(self.currentStatus(failure: self.device.isOpen ? nil : failure)))
        }
    }

    func changes(since seq: UInt64, reply: @escaping (Data?, NSError?) -> Void) {
        queue.async {
            // Don't open a device just to answer this: a closed session means
            // the anchor's session is over anyway.
            do {
                self.pollDeviceEventsOnQueue()
                reply(try Self.encode(try self.changeSet(since: seq)), nil)
            } catch {
                let e = MtpError(error)
                if e.kind.isTransport { self.dropSession(after: e) }
                reply(nil, e.nsError)
            }
        }
    }

    func list(parent: UInt32, reply: @escaping (Data?, NSError?) -> Void) {
        perform("list(parent: \(parent))", { try Self.encode(try self.device.list(parent: parent)) }) {
            switch $0 {
            case .success(let data): reply(data, nil)
            case .failure(let e): reply(nil, e.nsError)
            }
        }
    }

    func item(objectID: UInt32, reply: @escaping (Data?, NSError?) -> Void) {
        perform("item(\(objectID))", { try Self.encode(try self.existing(objectID)) }) {
            switch $0 {
            case .success(let data): reply(data, nil)
            case .failure(let e): reply(nil, e.nsError)
            }
        }
    }

    func fetch(objectID: UInt32, into destination: FileHandle, reply: @escaping (NSError?) -> Void) {
        let progress = Self.callerProgress(size: 0)
        perform("fetch(\(objectID))", {
            defer { try? destination.close() }
            try self.device.download(id: objectID, toFileDescriptor: destination.fileDescriptor,
                                     progress: Self.transferProgress(progress))
        }) {
            if case .failure(let e) = $0 { try? destination.close(); reply(e.nsError) } else { reply(nil) }
        }
    }

    func upload(parent: UInt32, name: String, size: UInt64, from source: FileHandle,
                reply: @escaping (UInt32, NSError?) -> Void) {
        let progress = Self.callerProgress(size: size)
        perform("upload to \(parent)", {
            defer { try? source.close() }
            try self.checkNameFree(name, in: parent)
            return try self.device.upload(fromFileDescriptor: source.fileDescriptor, parent: parent,
                                          name: name, size: size,
                                          progress: Self.transferProgress(progress))
        }) {
            switch $0 {
            case .success(let id): reply(id, nil)
            case .failure(let e): try? source.close(); reply(0, e.nsError)
            }
        }
    }

    func createFolder(parent: UInt32, name: String, reply: @escaping (UInt32, NSError?) -> Void) {
        perform("createFolder in \(parent)", {
            try self.checkNameFree(name, in: parent)
            return try self.device.createFolder(name: name, parent: parent)
        }) {
            switch $0 {
            case .success(let id): reply(id, nil)
            case .failure(let e): reply(0, e.nsError)
            }
        }
    }

    func delete(objectID: UInt32, recursive: Bool, reply: @escaping (NSError?) -> Void) {
        perform("delete(\(objectID))", { try self.deleteTree(objectID, recursive: recursive) }) {
            if case .failure(let e) = $0 { reply(e.nsError) } else { reply(nil) }
        }
    }

    func rename(objectID: UInt32, to newName: String, reply: @escaping (NSError?) -> Void) {
        perform("rename(\(objectID))", {
            let entry = try self.existing(objectID)
            try self.checkNameFree(newName, in: entry.parentID, excluding: objectID)
            try self.device.rename(id: objectID, to: newName)
        }) {
            if case .failure(let e) = $0 { reply(e.nsError) } else { reply(nil) }
        }
    }

    func move(objectID: UInt32, toParent newParent: UInt32, reply: @escaping (NSError?) -> Void) {
        perform("move(\(objectID) → \(newParent))", {
            let entry = try self.existing(objectID)
            try self.checkNameFree(entry.name, in: newParent, excluding: objectID)
            try self.device.move(id: objectID, toParent: newParent)
        }) {
            if case .failure(let e) = $0 { reply(e.nsError) } else { reply(nil) }
        }
    }
}
