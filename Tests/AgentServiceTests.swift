import XCTest

final class AgentServiceTests: XCTestCase {
    private var bus: FakeBus!
    private var phone: FakeDevice!
    private var clock: Date!
    private var service: AgentService!
    private var changes: [AgentService.DeviceChange] = []

    override func setUp() {
        bus = FakeBus()
        phone = bus.attach(FakeDevice())
        clock = Date(timeIntervalSince1970: 1_000)
        service = AgentService(bus: bus, now: { [unowned self] in self.clock })
        changes = []
        service.onChange = { [unowned self] in self.changes.append($0) }
    }

    // MARK: - Helpers

    /// Call an XPC-style method and wait for its reply.
    private func call<T>(_ invoke: (@escaping (T) -> Void) -> Void) -> T {
        let done = expectation(description: "reply")
        var result: T?
        invoke { result = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return result!
    }

    private func list(_ parent: UInt32 = 0, on device: FakeDevice? = nil) -> (entries: [MtpEntry]?, error: NSError?) {
        let key = (device ?? phone).key
        let (data, error): (Data?, NSError?) = call { reply in
            service.list(device: key, parent: parent) { reply(($0, $1)) }
        }
        return (data.flatMap { try? JSONDecoder().decode([MtpEntry].self, from: $0) }, error)
    }

    private func overview() -> AgentOverview {
        let data: Data? = call { reply in service.overview { reply($0) } }
        return try! JSONDecoder().decode(AgentOverview.self, from: data!)
    }

    private func status(_ device: FakeDevice? = nil) -> DeviceStatus? {
        overview().device((device ?? phone).key)
    }

    private func delete(_ id: UInt32, recursive: Bool) -> NSError? {
        call { reply in service.delete(device: phone.key, objectID: id, recursive: recursive) { reply($0) } }
    }

    private func hotplug() {
        let done = expectation(description: "hotplug")
        service.usbDevicesChanged { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    private func poll() {
        let done = expectation(description: "poll")
        service.pollDeviceEvents { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    private func changeSet(since seq: UInt64, on device: FakeDevice? = nil) -> (set: ChangeSet?, error: NSError?) {
        let key = (device ?? phone).key
        let (data, error): (Data?, NSError?) = call { reply in
            service.changes(device: key, since: seq) { reply(($0, $1)) }
        }
        return (data.flatMap { try? JSONDecoder().decode(ChangeSet.self, from: $0) }, error)
    }

    // MARK: - Devices and sessions

    func testOpensLazilyAndLists() {
        phone.add("DCIM", folder: true)
        XCTAssertFalse(phone.isOpen)
        let result = list()
        XCTAssertNil(result.error)
        XCTAssertEqual(result.entries?.map(\.name), ["DCIM"])
        XCTAssertTrue(phone.isOpen)
        XCTAssertEqual(changes, [.opened(status()!)])
    }

    func testKeysComeFromSerialOrVendorProduct() {
        XCTAssertEqual(phone.key, "mtp-SER123")
        XCTAssertEqual(DeviceKey.make(serial: nil, vendor: 0x091E, product: 0x4F00), "mtp-091e-4f00")
        XCTAssertEqual(DeviceKey.make(serial: " a/b:c ", vendor: 1, product: 2), "mtp-abc")
        XCTAssertEqual(DeviceKey.make(serial: "///", vendor: 1, product: 2), "mtp-0001-0002")
    }

    func testSeveralDevicesAreServedSideBySide() {
        let gps = bus.attach(FakeDevice(name: "GPS", serial: "GPS9", location: 2))
        phone.add("DCIM", folder: true)
        gps.add("Activities", folder: true)
        hotplug()
        let o = overview()
        XCTAssertEqual(Set(o.devices.map(\.key)), [phone.key, gps.key])
        XCTAssertNotEqual(o.device(phone.key)?.sessionID, o.device(gps.key)?.sessionID)
        XCTAssertEqual(list(on: phone).entries?.map(\.name), ["DCIM"])
        XCTAssertEqual(list(on: gps).entries?.map(\.name), ["Activities"])
    }

    func testDetachingOneDeviceKeepsTheOther() {
        let gps = bus.attach(FakeDevice(name: "GPS", serial: "GPS9", location: 2))
        hotplug()
        bus.detach(phone)
        hotplug()
        XCTAssertEqual(overview().devices.map(\.key), [gps.key])
        XCTAssertTrue(changes.contains(.lost(key: phone.key, error: .disconnected)))
        XCTAssertEqual(list(on: phone).error?.mtpFailure, .noDevice)
        XCTAssertNil(list(on: gps).error)
    }

    func testTransportErrorDropsSessionAndNextCallReopensWithNewSessionID() {
        let first = status()?.sessionID
        XCTAssertNotNil(first)

        phone.alive = false
        XCTAssertEqual(list().error?.mtpFailure, .disconnected)
        XCTAssertFalse(phone.isOpen, "a dead transport must close the session")

        clock += AgentService.rescanInterval + 0.1
        XCTAssertNil(list().error)
        let second = status()?.sessionID
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second, "a reopened session must get a new id")
    }

    func testLogicalErrorKeepsSession() {
        _ = list()
        let opens = bus.openCount
        phone.failNext = MtpError(.accessDenied, "read-only")
        XCTAssertEqual(list().error?.mtpFailure, .accessDenied)
        XCTAssertTrue(phone.isOpen)
        _ = list()
        XCTAssertEqual(bus.openCount, opens, "no reopen after a refusal")
    }

    func testUnknownDeviceIsNotRescannedWithinInterval() {
        bus.detach(phone)
        XCTAssertEqual(list().error?.mtpFailure, .noDevice)
        XCTAssertEqual(list().error?.mtpFailure, .noDevice)
        XCTAssertEqual(bus.detectCount, 1)

        clock += AgentService.rescanInterval + 0.1
        bus.attach(phone)
        XCTAssertNil(list().error)
        XCTAssertEqual(bus.detectCount, 2)
    }

    func testBusyDeviceIsReported() {
        bus.busy = [phone.info.location]
        let o = overview()
        XCTAssertEqual(o.devices, [])
        XCTAssertEqual(o.problem, .deviceBusy)
        XCTAssertEqual(list().error?.mtpFailure, .deviceBusy)
    }

    func testCamerasAreLeftAloneUntilDetached() {
        let camera = bus.attach(FakeDevice(name: "Camera X", serial: "CAM1", location: 3))
        bus.cameras = [camera.info.location]
        hotplug()
        var o = overview()
        XCTAssertEqual(o.devices.map(\.key), [phone.key], "the phone next to it still opens")
        XCTAssertEqual(o.ignoredDevices, ["Camera X"])
        XCTAssertNil(o.problem, "a camera isn't a problem")
        XCTAssertFalse(changes.contains { if case .opened(let s) = $0 { return s.key == camera.key } else { return false } })

        let opens = bus.openCount
        hotplug()
        XCTAssertEqual(bus.openCount, opens, "not opened again while it stays attached")

        bus.detach(camera)
        hotplug()
        o = overview()
        XCTAssertEqual(o.ignoredDevices, [])
        bus.attach(camera)
        hotplug()
        XCTAssertEqual(bus.openCount, opens + 1, "re-checked after being re-attached")
        XCTAssertEqual(overview().ignoredDevices, ["Camera X"])
    }

    func testOverviewNoticesDeadLink() {
        XCTAssertNotNil(status())
        bus.detach(phone)
        XCTAssertNil(status())
        XCTAssertTrue(changes.contains(.lost(key: phone.key, error: .disconnected)))
    }

    func testUnsafeCloseAsksForRestart() {
        var restartRequested = false
        service.onUnsafeClose = { restartRequested = true }
        _ = status()
        phone.releasable = false
        phone.alive = false
        _ = list()
        XCTAssertTrue(restartRequested)
    }

    // MARK: - Device events / change journal

    func testObjectAddedOnDeviceIsReportedAsUpdate() {
        let start = status()!
        let id = phone.addOnDevice("IMG_0001.jpg")
        poll()
        guard case .changed(let s)? = changes.last else { return XCTFail("no change signalled") }
        XCTAssertEqual(s.changeSeq, 1)
        let result = changeSet(since: start.changeSeq)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.set?.expired, false)
        XCTAssertEqual(result.set?.updated.map(\.id), [id])
        XCTAssertEqual(result.set?.deleted, [])
        XCTAssertEqual(result.set?.latestSeq, 1)
        XCTAssertEqual(result.set?.sessionID, start.sessionID)
        XCTAssertEqual(changeSet(since: 1).set?.updated, [], "nothing new after the latest position")
    }

    func testEventsAreKeptPerDevice() {
        let gps = bus.attach(FakeDevice(name: "GPS", serial: "GPS9", location: 2))
        hotplug()
        phone.addOnDevice("IMG.jpg")
        poll()
        XCTAssertEqual(changeSet(since: 0, on: phone).set?.latestSeq, 1)
        XCTAssertEqual(changeSet(since: 0, on: gps).set?.latestSeq, 0)
    }

    func testObjectRemovedOnDeviceIsReportedAsDeletion() {
        let id = phone.add("old.jpg")
        _ = status()
        phone.removeOnDevice(id)
        poll()
        XCTAssertEqual(changeSet(since: 0).set?.deleted, [id])
    }

    func testAddedThenRemovedCollapsesToDeletion() {
        _ = status()
        let id = phone.addOnDevice("tmp.jpg")
        phone.removeOnDevice(id)
        poll()
        let set = changeSet(since: 0).set
        XCTAssertEqual(set?.updated, [])
        XCTAssertEqual(set?.deleted, [id])
        XCTAssertEqual(set?.latestSeq, 2)
    }

    func testStorageChangeExpiresTheAnchor() {
        _ = status()
        phone.pendingEvents = [.storageChanged]
        poll()
        XCTAssertEqual(changeSet(since: 0).set?.expired, true)
    }

    func testJournalOverflowExpiresOldAnchors() {
        _ = status()
        phone.pendingEvents = (0..<(AgentService.journalLimit + 1)).map { .objectRemoved(UInt32(10_000 + $0)) }
        poll()
        XCTAssertEqual(changeSet(since: 0).set?.expired, true)
        XCTAssertEqual(changeSet(since: 1).set?.expired, false)
    }

    func testChangesWithoutOpenDeviceFailInsteadOfOpening() {
        XCTAssertEqual(changeSet(since: 0).error?.mtpFailure, .noDevice)
        XCTAssertFalse(phone.isOpen)
    }

    func testReopenedSessionStartsANewJournal() {
        let first = status()!
        phone.addOnDevice("a.jpg")
        poll()
        bus.detach(phone)
        hotplug()
        bus.attach(phone)
        hotplug()
        let second = status()!
        XCTAssertNotEqual(first.sessionID, second.sessionID)
        XCTAssertEqual(second.changeSeq, 0)
    }

    func testLostEventChannelWithDeadLinkDropsSession() {
        _ = status()
        phone.alive = false
        phone.pendingEvents = [.linkLost]
        poll()
        XCTAssertFalse(phone.isOpen)
    }

    // MARK: - Objects

    func testItemForMissingObjectIsNoSuchObject() {
        let key = phone.key
        let (_, error): (Data?, NSError?) = call { reply in
            service.item(device: key, objectID: 999) { reply(($0, $1)) }
        }
        XCTAssertEqual(error?.mtpFailure, .noSuchObject)
        XCTAssertTrue(phone.isOpen, "a missing object is not a transport failure")
    }

    func testNonRecursiveDeleteOfNonEmptyFolderIsRefused() {
        let folder = phone.add("Camera", folder: true)
        phone.add("a.jpg", parent: folder)
        XCTAssertEqual(delete(folder, recursive: false)?.mtpFailure, .directoryNotEmpty)
        XCTAssertNotNil(phone.objects[folder])
    }

    func testRecursiveDeleteRemovesTree() {
        let folder = phone.add("Camera", folder: true)
        let sub = phone.add("Old", parent: folder, folder: true)
        phone.add("a.jpg", parent: folder)
        phone.add("b.jpg", parent: sub)
        let keep = phone.add("keep.jpg")
        XCTAssertNil(delete(folder, recursive: true))
        XCTAssertEqual(Array(phone.objects.keys), [keep])
    }

    func testCreateFolderRefusesCaseInsensitiveDuplicate() {
        phone.add("Download", folder: true)
        let key = phone.key
        let (id, error): (UInt32, NSError?) = call { reply in
            service.createFolder(device: key, parent: 0, name: "download") { reply(($0, $1)) }
        }
        XCTAssertEqual(id, 0)
        XCTAssertEqual(error?.mtpFailure, .nameCollision)
    }

    func testRenameToOwnNameWithDifferentCaseIsAllowed() {
        let id = phone.add("photo.jpg")
        let key = phone.key
        let error: NSError? = call { reply in
            service.rename(device: key, objectID: id, to: "Photo.jpg") { reply($0) }
        }
        XCTAssertNil(error)
        XCTAssertEqual(phone.objects[id]?.name, "Photo.jpg")
    }

    func testMoveUnsupportedKeepsSession() {
        let folder = phone.add("Dst", folder: true)
        let id = phone.add("a.jpg")
        phone.supportsMove = false
        let key = phone.key
        let error: NSError? = call { reply in
            service.move(device: key, objectID: id, toParent: folder) { reply($0) }
        }
        XCTAssertEqual(error?.mtpFailure, .unsupported)
        XCTAssertTrue(phone.isOpen)
    }

    func testUploadAddsObject() throws {
        let handle = try XCTUnwrap(FileHandle(forReadingAtPath: "/dev/null"))
        let key = phone.key
        let (id, error): (UInt32, NSError?) = call { reply in
            service.upload(device: key, parent: 0, name: "w.jpg", size: 10, from: handle) { reply(($0, $1)) }
        }
        XCTAssertNil(error)
        XCTAssertEqual(phone.objects[id]?.name, "w.jpg")
    }
}
