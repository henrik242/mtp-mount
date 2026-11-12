import Foundation

/// In-memory USB bus for agent tests: devices can be attached, detached,
/// busy, or have a dead link.
final class FakeBus: MtpBus {
    private(set) var attached: [FakeDevice] = []
    private(set) var detectCount = 0
    private(set) var openCount = 0
    /// Locations whose open fails as "in use by another app".
    var busy: Set<UInt64> = []
    /// Locations holding a camera (released at once as "not a file device").
    var cameras: Set<UInt64> = []

    @discardableResult
    func attach(_ device: FakeDevice) -> FakeDevice {
        attached.append(device)
        return device
    }

    func detach(_ device: FakeDevice) {
        attached.removeAll { $0 === device }
        device.alive = false
    }

    func detect() throws -> [RawDeviceInfo] {
        detectCount += 1
        return attached.map(\.info)
    }

    func open(_ info: RawDeviceInfo) throws -> MtpDevice {
        openCount += 1
        guard let device = attached.first(where: { $0.info == info }) else {
            throw MtpError(.noDevice, "gone")
        }
        guard !busy.contains(info.location) else { throw MtpError(.deviceBusy, "in use") }
        guard !cameras.contains(info.location) else { throw MtpError(.notFileDevice, device.name) }
        device.isOpen = true
        device.alive = true
        return device
    }
}

/// In-memory MTP device. Objects live in a flat id → entry map (parent 0 =
/// top of storage); `failNext` injects one failure.
final class FakeDevice: MtpDevice {
    let info: RawDeviceInfo
    let name: String
    let serial: String?

    /// When false, the "USB link" is dead: ping and every call fail as transport errors.
    var alive = true
    var isOpen = false
    var supportsMove = true
    var failNext: MtpError?
    /// Events the next `pollEvents` returns.
    var pendingEvents: [DeviceEvent] = []
    /// When false, `close` reports that the handle couldn't be released safely.
    var releasable = true

    private(set) var objects: [UInt32: MtpEntry] = [:]
    private var nextID: UInt32 = 100

    init(name: String = "Fake Phone", serial: String? = "SER123", location: UInt64 = 1,
         vendor: UInt16 = 0x04E8, product: UInt16 = 0x6860) {
        self.name = name
        self.serial = serial
        self.info = RawDeviceInfo(location: location, vendor: vendor, product: product)
    }

    var key: String { DeviceKey.make(serial: serial, vendor: info.vendor, product: info.product) }

    @discardableResult
    func add(_ name: String, parent: UInt32 = 0, folder: Bool = false, size: UInt64 = 0) -> UInt32 {
        let id = nextID
        nextID += 1
        objects[id] = MtpEntry(id: id, parentID: parent, storageID: 1, name: name,
                               size: size, isFolder: folder, modified: 1_700_000_000)
        return id
    }

    /// Simulate a change made on the device itself.
    @discardableResult
    func addOnDevice(_ name: String, parent: UInt32 = 0) -> UInt32 {
        let id = add(name, parent: parent)
        pendingEvents.append(.objectAdded(id))
        return id
    }

    func removeOnDevice(_ id: UInt32) {
        objects[id] = nil
        pendingEvents.append(.objectRemoved(id))
    }

    private func check() throws {
        guard isOpen else { throw MtpError(.disconnected, "not open") }
        guard alive else { throw MtpError(.disconnected, "link down") }
        if let e = failNext { failNext = nil; throw e }
    }

    @discardableResult
    func close() -> Bool {
        isOpen = false
        return releasable
    }

    func deviceName() -> String? { name }
    func serialNumber() -> String? { serial }
    func ping() throws { try check() }

    func pollEvents() -> [DeviceEvent] {
        defer { pendingEvents = [] }
        return pendingEvents
    }

    func list(parent: UInt32) throws -> [MtpEntry] {
        try check()
        return objects.values.filter { $0.parentID == parent }.sorted { $0.id < $1.id }
    }

    func metadata(id: UInt32) throws -> MtpEntry? {
        try check()
        return objects[id]
    }

    func download(id: UInt32, toFileDescriptor fd: Int32, progress: TransferProgress?) throws {
        try check()
        guard let entry = objects[id] else { throw MtpError(.noSuchObject, "missing") }
        _ = progress?(entry.size, entry.size)
    }

    func upload(fromFileDescriptor fd: Int32, parent: UInt32, name: String, size: UInt64,
                progress: TransferProgress?) throws -> UInt32 {
        try check()
        if let progress, !progress(size / 2, size) { throw MtpError(.cancelled, "cancelled") }
        return add(name, parent: parent, size: size)
    }

    func createFolder(name: String, parent: UInt32) throws -> UInt32 {
        try check()
        return add(name, parent: parent, folder: true)
    }

    func delete(id: UInt32) throws {
        try check()
        guard objects[id] != nil else { throw MtpError(.noSuchObject, "missing") }
        if objects.values.contains(where: { $0.parentID == id }) {
            throw MtpError(.failed, "device refuses to delete a non-empty folder")
        }
        objects[id] = nil
    }

    func rename(id: UInt32, to newName: String) throws {
        try check()
        guard objects[id] != nil else { throw MtpError(.noSuchObject, "missing") }
        objects[id]?.name = newName
    }

    func move(id: UInt32, toParent parent: UInt32) throws {
        try check()
        guard supportsMove else { throw MtpError(.unsupported, "no MoveObject") }
        guard objects[id] != nil else { throw MtpError(.noSuchObject, "missing") }
        objects[id]?.parentID = parent
    }
}
