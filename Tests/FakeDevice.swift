import Foundation

/// In-memory MTP device for agent tests. Objects live in a flat id → entry map
/// (parent 0 = top of storage); `failNext` injects one failure.
final class FakeDevice: MtpDevice {
    var present = true
    var busy = false
    /// When false, the "USB link" is dead: ping and every call fail as transport errors.
    var alive = true
    var supportsMove = true
    var failNext: MtpError?

    private(set) var isOpen = false
    private(set) var openCount = 0
    private(set) var objects: [UInt32: MtpEntry] = [:]
    private var nextID: UInt32 = 100

    @discardableResult
    func add(_ name: String, parent: UInt32 = 0, folder: Bool = false, size: UInt64 = 0) -> UInt32 {
        let id = nextID
        nextID += 1
        objects[id] = MtpEntry(id: id, parentID: parent, storageID: 1, name: name,
                               size: size, isFolder: folder, modified: 1_700_000_000)
        return id
    }

    private func check() throws {
        guard isOpen else { throw MtpError(.disconnected, "not open") }
        guard alive else { throw MtpError(.disconnected, "link down") }
        if let e = failNext { failNext = nil; throw e }
    }

    func open() throws {
        openCount += 1
        guard present else { throw MtpError(.noDevice, "No MTP device detected on USB.") }
        guard !busy else { throw MtpError(.deviceBusy, "in use") }
        isOpen = true
        alive = true
    }

    func close() { isOpen = false }
    func deviceName() -> String? { "Fake Phone" }
    func serialNumber() -> String? { "SER123" }
    func ping() throws { try check() }

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
