import XCTest

final class AgentServiceTests: XCTestCase {
    private var device: FakeDevice!
    private var clock: Date!
    private var service: AgentService!
    private var sessionChanges: [AgentStatus] = []

    override func setUp() {
        device = FakeDevice()
        clock = Date(timeIntervalSince1970: 1_000)
        service = AgentService(device: device, now: { [unowned self] in self.clock })
        sessionChanges = []
        service.onSessionChange = { [unowned self] in self.sessionChanges.append($0) }
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

    private func list(_ parent: UInt32 = 0) -> (entries: [MtpEntry]?, error: NSError?) {
        let (data, error): (Data?, NSError?) = call { reply in
            service.list(parent: parent) { reply(($0, $1)) }
        }
        return (data.flatMap { try? JSONDecoder().decode([MtpEntry].self, from: $0) }, error)
    }

    private func status() -> AgentStatus {
        let data: Data? = call { reply in service.status { reply($0) } }
        return try! JSONDecoder().decode(AgentStatus.self, from: data!)
    }

    private func delete(_ id: UInt32, recursive: Bool) -> NSError? {
        call { reply in service.delete(objectID: id, recursive: recursive) { reply($0) } }
    }

    // MARK: - Session handling

    func testOpensLazilyAndLists() {
        device.add("DCIM", folder: true)
        XCTAssertFalse(device.isOpen)
        let result = list()
        XCTAssertNil(result.error)
        XCTAssertEqual(result.entries?.map(\.name), ["DCIM"])
        XCTAssertTrue(device.isOpen)
        XCTAssertEqual(sessionChanges.count, 1)
    }

    func testTransportErrorDropsSessionAndNextCallReopensWithNewSessionID() {
        let first = status().sessionID
        XCTAssertNotNil(first)

        device.alive = false
        let failed = list()
        XCTAssertEqual(failed.error?.mtpFailure, .disconnected)
        XCTAssertFalse(device.isOpen, "a dead transport must close the session")

        let recovered = list()
        XCTAssertNil(recovered.error)
        let second = status().sessionID
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second, "a reopened session must get a new id")
    }

    func testLogicalErrorKeepsSession() {
        _ = list()
        let opens = device.openCount
        device.failNext = MtpError(.accessDenied, "read-only")
        XCTAssertEqual(list().error?.mtpFailure, .accessDenied)
        XCTAssertTrue(device.isOpen)
        _ = list()
        XCTAssertEqual(device.openCount, opens, "no reopen after a refusal")
    }

    func testAbsentDeviceIsNotReprobedWithinRetryInterval() {
        device.present = false
        XCTAssertEqual(list().error?.mtpFailure, .noDevice)
        XCTAssertEqual(list().error?.mtpFailure, .noDevice)
        XCTAssertEqual(device.openCount, 1)

        clock += AgentService.absentRetryInterval + 0.1
        device.present = true
        XCTAssertNil(list().error)
        XCTAssertEqual(device.openCount, 2)
    }

    func testBusyDeviceReportedInStatus() {
        device.busy = true
        let s = status()
        XCTAssertFalse(s.connected)
        XCTAssertEqual(s.failure, .deviceBusy)
        XCTAssertNil(s.sessionID)
    }

    func testStatusNoticesDeadLink() {
        XCTAssertTrue(status().connected)
        device.alive = false
        device.present = false
        let s = status()
        XCTAssertFalse(s.connected)
        XCTAssertEqual(s.failure, .noDevice)
        XCTAssertEqual(sessionChanges.last?.connected, false)
    }

    // MARK: - Objects

    func testItemForMissingObjectIsNoSuchObject() {
        let (_, error): (Data?, NSError?) = call { reply in
            service.item(objectID: 999) { reply(($0, $1)) }
        }
        XCTAssertEqual(error?.mtpFailure, .noSuchObject)
        XCTAssertTrue(device.isOpen, "a missing object is not a transport failure")
    }

    func testNonRecursiveDeleteOfNonEmptyFolderIsRefused() {
        let folder = device.add("Camera", folder: true)
        device.add("a.jpg", parent: folder)
        XCTAssertEqual(delete(folder, recursive: false)?.mtpFailure, .directoryNotEmpty)
        XCTAssertNotNil(device.objects[folder])
    }

    func testRecursiveDeleteRemovesTree() {
        let folder = device.add("Camera", folder: true)
        let sub = device.add("Old", parent: folder, folder: true)
        device.add("a.jpg", parent: folder)
        device.add("b.jpg", parent: sub)
        let keep = device.add("keep.jpg")
        XCTAssertNil(delete(folder, recursive: true))
        XCTAssertEqual(Array(device.objects.keys), [keep])
    }

    func testCreateFolderRefusesCaseInsensitiveDuplicate() {
        device.add("NewFiles", folder: true)
        let (id, error): (UInt32, NSError?) = call { reply in
            service.createFolder(parent: 0, name: "newfiles") { reply(($0, $1)) }
        }
        XCTAssertEqual(id, 0)
        XCTAssertEqual(error?.mtpFailure, .nameCollision)
    }

    func testRenameToOwnNameWithDifferentCaseIsAllowed() {
        let id = device.add("course.jpg")
        let error: NSError? = call { reply in service.rename(objectID: id, to: "Course.jpg") { reply($0) } }
        XCTAssertNil(error)
        XCTAssertEqual(device.objects[id]?.name, "Course.jpg")
    }

    func testMoveUnsupportedKeepsSession() {
        let folder = device.add("Dst", folder: true)
        let id = device.add("a.jpg")
        device.supportsMove = false
        let error: NSError? = call { reply in service.move(objectID: id, toParent: folder) { reply($0) } }
        XCTAssertEqual(error?.mtpFailure, .unsupported)
        XCTAssertTrue(device.isOpen)
    }

    func testUploadAddsObjectAndClosesHandle() throws {
        let handle = try XCTUnwrap(FileHandle(forReadingAtPath: "/dev/null"))
        let (id, error): (UInt32, NSError?) = call { reply in
            service.upload(parent: 0, name: "w.jpg", size: 10, from: handle) { reply(($0, $1)) }
        }
        XCTAssertNil(error)
        XCTAssertEqual(device.objects[id]?.name, "w.jpg")
    }
}
