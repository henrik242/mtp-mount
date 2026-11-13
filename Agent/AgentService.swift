// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import os

private let log = Logger(subsystem: MtpAgentConfig.logSubsystem, category: "agent")

/// Owns every attached MTP device and vends them over XPC.
///
/// All device work runs on one serial queue: the USB transport is not
/// thread-safe, and device events for all devices are delivered while
/// pumping it. Devices are opened when they're attached (USB
/// hotplug) or when a request finds them; a device's session is dropped only
/// when its transport fails, so unplug/replug recovers without restarting the
/// agent while ordinary refusals (name collision, unsupported operation, …)
/// keep the session.
final class AgentService: NSObject, MtpAgentXPC {
    /// How long a failed scan for devices is reused before probing USB again,
    /// so a burst of Finder requests for a detached device doesn't hammer USB.
    static let rescanInterval: TimeInterval = 2
    static let journalLimit = 5_000

    private let queue: DispatchQueue
    private let bus: MtpBus
    private let now: () -> Date
    /// Names an attached device that's a PTP still-image camera (no MTP
    /// interface) from its USB descriptors, or nil. Injectable for tests.
    private let ptpCameraName: (_ vendor: UInt16, _ product: UInt16) -> String?
    /// Distinguishes this agent process, so session ids never repeat across restarts.
    private let instance = UUID().uuidString.prefix(8)
    private var epoch = 0
    private var lastScan: Date?
    /// Why the last scan couldn't open an attached device, if it couldn't.
    private var problem: MtpError?
    /// Attached cameras (not file devices), by location, with their names.
    /// They aren't opened again until they're detached.
    private var ignored: [UInt64: String] = [:]
    /// Which `ignored` entries are there because the device's USB descriptors
    /// say "PTP camera" (vs. a DCF-only storage found by opening it). These are
    /// re-checked each scan, so a phone leaving PTP mode is noticed without a
    /// replug; DCF cameras stay put until detached (opening them is expensive).
    private var ptpCameras: Set<UInt64> = []
    private var devices: [String: OpenDevice] = [:]
    private var eventTimer: DispatchSourceTimer?

    /// Called on the device queue when a device's session opens, is lost, or
    /// the device reported changes: that device's File Provider domain should
    /// be signalled (and created, if it's new).
    var onChange: ((DeviceChange) -> Void)?
    /// Called when a device couldn't be released safely; the process should
    /// exit so launchd can start a fresh agent that can open it again.
    var onUnsafeClose: (() -> Void)?

    enum DeviceChange: Equatable {
        case opened(DeviceStatus)
        case changed(DeviceStatus)
        case lost(key: String, error: MtpFailure)
    }

    init(bus: MtpBus,
         queue: DispatchQueue = DispatchQueue(label: "no.synth.mtpmount.agent.mtp"),
         now: @escaping () -> Date = Date.init,
         ptpCameraName: @escaping (UInt16, UInt16) -> String? = UsbClass.ptpCameraName) {
        self.bus = bus
        self.queue = queue
        self.now = now
        self.ptpCameraName = ptpCameraName
    }

    // MARK: - Devices

    /// One open device and its change journal.
    private final class OpenDevice {
        enum Change { case updated(UInt32), deleted(UInt32), rescan }

        let key: String
        let raw: RawDeviceInfo
        let device: MtpDevice
        let sessionID: String
        var journal: [(seq: UInt64, change: Change)] = []
        var changeSeq: UInt64 = 0
        /// Positions at or below this are no longer covered by the journal.
        var journalFloor: UInt64 = 0

        init(key: String, raw: RawDeviceInfo, device: MtpDevice, sessionID: String) {
            self.key = key
            self.raw = raw
            self.device = device
            self.sessionID = sessionID
        }

        var status: DeviceStatus {
            DeviceStatus(key: key, name: device.deviceName() ?? "MTP Device", serial: device.serialNumber(),
                         sessionID: sessionID, changeSeq: changeSeq)
        }

        func record(_ change: Change) {
            changeSeq += 1
            journal.append((changeSeq, change))
            if journal.count > AgentService.journalLimit {
                let dropped = journal.count - AgentService.journalLimit
                journalFloor = journal[dropped - 1].seq
                journal.removeFirst(dropped)
            }
        }
    }

    /// Open every attached device that isn't open yet. Rate-limited unless forced.
    private func scan(force: Bool = false) {
        if !force, let last = lastScan, now().timeIntervalSince(last) < Self.rescanInterval { return }
        lastScan = now()
        problem = nil
        let attached: [RawDeviceInfo]
        do {
            attached = try bus.detect()
        } catch {
            problem = MtpError(error)
            return
        }
        let attachedLocations = Set(attached.map(\.location))
        // Re-read the descriptors of devices we left to Image Capture as PTP
        // cameras (cheap, no open). One that no longer looks like a camera --
        // a phone switched from "Photos"/PTP to "File transfer" -- drops out of
        // the ignore set and is opened below, without waiting for a replug.
        for raw in attached where ptpCameras.contains(raw.location) {
            if ptpCameraName(raw.vendor, raw.product) == nil {
                ignored[raw.location] = nil
                ptpCameras.remove(raw.location)
            }
        }
        ignored = ignored.filter { attachedLocations.contains($0.key) }
        ptpCameras = ptpCameras.intersection(attachedLocations)
        let openLocations = Set(devices.values.map(\.raw.location))
        for raw in attached where !openLocations.contains(raw.location) && ignored[raw.location] == nil {
            // A PTP still-image camera (or a phone in "Photos"/PTP mode) can't
            // be opened as an MTP file device, and claiming it only keeps Image
            // Capture and Photos from it. Recognise it from its USB descriptors
            // and leave it alone, before any backend opens (and claims) it.
            if let camera = ptpCameraName(raw.vendor, raw.product) {
                log.info("leaving PTP camera alone (no MTP interface): \(camera, privacy: .public)")
                ignored[raw.location] = camera
                ptpCameras.insert(raw.location)
                continue
            }
            let device: MtpDevice
            do {
                device = try bus.open(raw)
            } catch {
                let e = MtpError(error)
                if e.kind == .notFileDevice {
                    ignored[raw.location] = e.message
                    continue
                }
                problem = e
                log.error("opening device at \(raw.location) failed: \(e.message, privacy: .public)")
                continue
            }
            let key = DeviceKey.make(serial: device.serialNumber(), vendor: raw.vendor, product: raw.product)
            guard devices[key] == nil else {
                // The same device seen twice (e.g. at a new location before the
                // old one was noticed as gone): keep the existing session.
                device.close()
                continue
            }
            epoch += 1
            let open = OpenDevice(key: key, raw: raw, device: device, sessionID: "\(instance)-\(epoch)")
            devices[key] = open
            log.info("opened \(open.status.name, privacy: .public) as \(key, privacy: .public)")
            onChange?(.opened(open.status))
        }
    }

    /// The open device for `key`, scanning for it if needed.
    private func openDevice(_ key: String) throws -> OpenDevice {
        if let open = devices[key] { return open }
        scan()
        if let open = devices[key] { return open }
        if let problem, problem.kind == .deviceBusy { throw problem }
        throw MtpError(.noDevice, "The device isn't connected.")
    }

    /// Close a device's session after a transport failure; a later request or
    /// hotplug event reopens it.
    private func drop(_ open: OpenDevice, after error: MtpError) {
        guard devices[open.key] === open else { return }
        log.error("dropping \(open.key, privacy: .public): \(error.message, privacy: .public)")
        devices[open.key] = nil
        let released = open.device.close()
        onChange?(.lost(key: open.key, error: error.kind))
        if !released { onUnsafeClose?() }
    }

    /// Check every open session; drop the dead ones.
    private func pingAll() {
        for open in Array(devices.values) {
            do { try open.device.ping() } catch { drop(open, after: MtpError(error)) }
        }
    }

    /// USB devices came or went (from the hotplug monitor): check the open
    /// sessions and open newly attached devices.
    func usbDevicesChanged(completion: (() -> Void)? = nil) {
        queue.async {
            self.pingAll()
            self.scan(force: true)
            completion?()
        }
    }

    // MARK: - Device events

    /// Poll the devices for events every `interval` seconds on the device queue.
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
        for open in Array(devices.values) {
            let events = open.device.pollEvents()
            guard !events.isEmpty else { continue }
            var changed = false
            for event in events {
                switch event {
                case .objectAdded(let id): open.record(.updated(id)); changed = true
                case .objectRemoved(let id): open.record(.deleted(id)); changed = true
                case .storageChanged: open.record(.rescan); changed = true
                case .linkLost:
                    do { try open.device.ping() } catch { drop(open, after: MtpError(error)) }
                }
            }
            if changed, devices[open.key] === open {
                log.info("\(open.key, privacy: .public) reported changes; journal at \(open.changeSeq)")
                onChange?(.changed(open.status))
            }
        }
    }

    /// Describe a device's journal after `seq` as updated entries and deleted ids.
    private func changeSet(_ open: OpenDevice, since seq: UInt64) throws -> ChangeSet {
        let entries = open.journal.filter { $0.seq > seq }
        var result = ChangeSet(serial: open.device.serialNumber(), sessionID: open.sessionID,
                               latestSeq: open.changeSeq, expired: false, updated: [], deleted: [])
        let needsRescan = entries.contains {
            if case .rescan = $0.change { return true } else { return false }
        }
        if seq < open.journalFloor || seq > open.changeSeq || needsRescan {
            result.expired = true
            return result
        }
        // Last word per object wins; re-read added objects (they may be gone again).
        var exists: [UInt32: Bool] = [:]
        var order: [UInt32] = []
        for (_, change) in entries {
            switch change {
            case .updated(let id): if exists[id] == nil { order.append(id) }; exists[id] = true
            case .deleted(let id): if exists[id] == nil { order.append(id) }; exists[id] = false
            case .rescan: break
            }
        }
        for id in order {
            if exists[id] == true, let entry = try open.device.metadata(id: id) {
                result.updated.append(entry)
            } else {
                result.deleted.append(id)
            }
        }
        return result
    }

    // MARK: - Request plumbing

    /// Run `body` on the device queue against the open device `key` and reply
    /// with its result or a mapped error.
    private func perform<T>(_ key: String, _ what: @autoclosure @escaping () -> String,
                            _ body: @escaping (OpenDevice) throws -> T,
                            reply: @escaping (Result<T, MtpError>) -> Void) {
        queue.async {
            var target: OpenDevice?
            do {
                let open = try self.openDevice(key)
                target = open
                reply(.success(try body(open)))
            } catch {
                let e = MtpError(error)
                if e.kind.isTransport, let target { self.drop(target, after: e) }
                log.error("\(what(), privacy: .public) on \(key, privacy: .public) failed: \(e.message, privacy: .public)")
                reply(.failure(e))
            }
        }
    }

    /// Fail with `.nameCollision` if `parent` already has a child called `name`
    /// (other than `excluding`). Compared case-insensitively: device storage is
    /// usually FAT/exFAT or a case-folding Android filesystem.
    private static func checkNameFree(_ name: String, in parent: UInt32, on device: MtpDevice,
                                      excluding: UInt32? = nil) throws {
        let clash = try device.list(parent: parent).contains {
            $0.id != excluding && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
        if clash { throw MtpError(.nameCollision, "“\(name)” already exists in that folder.") }
    }

    private static func existing(_ id: UInt32, on device: MtpDevice) throws -> MtpEntry {
        guard let entry = try device.metadata(id: id) else {
            throw MtpError(.noSuchObject, "No such object on the device.")
        }
        return entry
    }

    private static func deleteTree(_ id: UInt32, recursive: Bool, on device: MtpDevice) throws {
        let entry = try existing(id, on: device)
        if entry.isFolder {
            let children = try device.list(parent: id)
            if !children.isEmpty {
                guard recursive else {
                    throw MtpError(.directoryNotEmpty, "The folder “\(entry.name)” is not empty.")
                }
                for child in children { try deleteTree(child.id, recursive: true, on: device) }
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

    private static func dataReply(_ reply: @escaping (Data?, NSError?) -> Void)
        -> (Result<Data, MtpError>) -> Void {
        { result in
            switch result {
            case .success(let data): reply(data, nil)
            case .failure(let e): reply(nil, e.nsError)
            }
        }
    }

    private static func idReply(_ reply: @escaping (UInt32, NSError?) -> Void)
        -> (Result<UInt32, MtpError>) -> Void {
        { result in
            switch result {
            case .success(let id): reply(id, nil)
            case .failure(let e): reply(0, e.nsError)
            }
        }
    }

    private static func voidReply(_ reply: @escaping (NSError?) -> Void) -> (Result<Void, MtpError>) -> Void {
        { result in
            if case .failure(let e) = result { reply(e.nsError) } else { reply(nil) }
        }
    }

    // MARK: - MtpAgentXPC

    func overview(reply: @escaping (Data?) -> Void) {
        queue.async {
            self.pingAll()
            self.scan()
            let overview = AgentOverview(
                devices: self.devices.values.map(\.status).sorted { $0.name < $1.name },
                problem: self.problem?.kind,
                message: self.problem?.message,
                ignoredDevices: self.ignored.values.sorted(),
                agentVersion: MtpAgentConfig.bundleVersion)
            reply(try? Self.encode(overview))
        }
    }

    func changes(device key: String, since seq: UInt64, reply: @escaping (Data?, NSError?) -> Void) {
        queue.async {
            // Don't open a device just to answer this: if it isn't open, the
            // anchor's session is over anyway.
            self.pollDeviceEventsOnQueue()
            guard let open = self.devices[key] else {
                reply(nil, MtpError(.noDevice, "The device isn't connected.").nsError)
                return
            }
            do {
                reply(try Self.encode(try self.changeSet(open, since: seq)), nil)
            } catch {
                let e = MtpError(error)
                if e.kind.isTransport { self.drop(open, after: e) }
                reply(nil, e.nsError)
            }
        }
    }

    func list(device key: String, parent: UInt32, reply: @escaping (Data?, NSError?) -> Void) {
        perform(key, "list(parent: \(parent))", { try Self.encode(try $0.device.list(parent: parent)) },
                reply: Self.dataReply(reply))
    }

    func item(device key: String, objectID: UInt32, reply: @escaping (Data?, NSError?) -> Void) {
        perform(key, "item(\(objectID))", { try Self.encode(try Self.existing(objectID, on: $0.device)) },
                reply: Self.dataReply(reply))
    }

    func fetch(device key: String, objectID: UInt32, into destination: FileHandle,
               reply: @escaping (NSError?) -> Void) {
        let progress = Self.callerProgress(size: 0)
        perform(key, "fetch(\(objectID))", { (open: OpenDevice) -> Void in
            defer { try? destination.close() }
            try open.device.download(id: objectID, toFileDescriptor: destination.fileDescriptor,
                                     progress: Self.transferProgress(progress))
        }) { result in
            if case .failure = result { try? destination.close() }
            Self.voidReply(reply)(result)
        }
    }

    func upload(device key: String, parent: UInt32, name: String, size: UInt64, from source: FileHandle,
                reply: @escaping (UInt32, NSError?) -> Void) {
        let progress = Self.callerProgress(size: size)
        perform(key, "upload to \(parent)", { (open: OpenDevice) -> UInt32 in
            defer { try? source.close() }
            try Self.checkNameFree(name, in: parent, on: open.device)
            return try open.device.upload(fromFileDescriptor: source.fileDescriptor, parent: parent,
                                          name: name, size: size, progress: Self.transferProgress(progress))
        }) { result in
            if case .failure = result { try? source.close() }
            Self.idReply(reply)(result)
        }
    }

    func createFolder(device key: String, parent: UInt32, name: String,
                      reply: @escaping (UInt32, NSError?) -> Void) {
        perform(key, "createFolder in \(parent)", { (open: OpenDevice) -> UInt32 in
            try Self.checkNameFree(name, in: parent, on: open.device)
            return try open.device.createFolder(name: name, parent: parent)
        }, reply: Self.idReply(reply))
    }

    func delete(device key: String, objectID: UInt32, recursive: Bool, reply: @escaping (NSError?) -> Void) {
        perform(key, "delete(\(objectID))", { (open: OpenDevice) -> Void in
            try Self.deleteTree(objectID, recursive: recursive, on: open.device)
        }, reply: Self.voidReply(reply))
    }

    func rename(device key: String, objectID: UInt32, to newName: String, reply: @escaping (NSError?) -> Void) {
        perform(key, "rename(\(objectID))", { (open: OpenDevice) -> Void in
            let entry = try Self.existing(objectID, on: open.device)
            try Self.checkNameFree(newName, in: entry.parentID, on: open.device, excluding: objectID)
            try open.device.rename(id: objectID, to: newName)
        }, reply: Self.voidReply(reply))
    }

    func move(device key: String, objectID: UInt32, toParent newParent: UInt32,
              reply: @escaping (NSError?) -> Void) {
        perform(key, "move(\(objectID) → \(newParent))", { (open: OpenDevice) -> Void in
            let entry = try Self.existing(objectID, on: open.device)
            try Self.checkNameFree(entry.name, in: newParent, on: open.device, excluding: objectID)
            try open.device.move(id: objectID, toParent: newParent)
        }, reply: Self.voidReply(reply))
    }
}
