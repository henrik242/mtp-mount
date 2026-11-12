// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import os

private let log = Logger(subsystem: MtpAgentConfig.logSubsystem, category: "ptp")

/// The USB side of a PTP device: one bulk-in, one bulk-out and one interrupt
/// endpoint. `USBTransport` implements it over IOUSBHost; tests use a
/// simulated device. Transport failures throw `MtpError(.disconnected)`.
protocol PTPTransport: AnyObject {
    /// Bulk endpoint packet size; transfers are planned around it.
    var maxPacketSize: Int { get }
    /// One bulk-out transfer (any length; an empty `data` sends a zero-length packet).
    func write(_ data: Data) throws
    /// One bulk-in transfer of up to `capacity` bytes (a multiple of the packet
    /// size); returns early on a short or zero-length packet.
    func read(capacity: Int) throws -> Data
    /// Interrupt packets received since the last call, without blocking; nil
    /// once the event channel has failed.
    func takeEvents() -> [Data]?
    /// Abort the transaction in progress (PTP class "Cancel" request) and
    /// wait until the device is ready again.
    func cancelTransaction(_ transactionID: UInt32) throws
    /// Stop all I/O and release the interface. Safe to call more than once.
    func close()
}

/// PTP/MTP transactions over a `PTPTransport`. Not thread-safe: the owner
/// serializes calls.
final class PTPSession {
    let transport: PTPTransport
    private var nextTransactionID: UInt32 = 1
    /// Size of the bulk transfers used for data phases.
    static let chunkSize = 1 << 20

    init(transport: PTPTransport) {
        self.transport = transport
    }

    /// Where a data-in phase goes: called with each chunk of payload; return
    /// false to cancel the transfer.
    typealias Sink = (_ chunk: Data, _ received: UInt64, _ total: UInt64?) throws -> Bool
    /// Where a data-out phase comes from: return up to `max` bytes (empty at
    /// the end), or nil to cancel.
    typealias Source = (_ max: Int) throws -> Data?

    enum DataPhase {
        case none
        case dataIn(Sink)
        case dataOut(length: UInt64, Source)
    }

    /// Run one transaction and return the response parameters. A device
    /// refusal throws `PTPResponseError`; a dead link `MtpError(.disconnected)`;
    /// a cancelled data phase `MtpError(.cancelled)`.
    @discardableResult
    func transact(_ code: UInt16, _ params: [UInt32] = [], data: DataPhase = .none) throws -> [UInt32] {
        let tid = nextTransactionID
        nextTransactionID = nextTransactionID == PTP.all - 1 ? 1 : nextTransactionID + 1
        try transport.write(PTPContainer(type: .command, code: code, transactionID: tid, params: params).encoded())

        var pending: Data?   // bytes already read past the data phase
        switch data {
        case .none:
            break
        case .dataOut(let length, let source):
            try sendData(code: code, tid: tid, length: length, source: source)
        case .dataIn(let sink):
            pending = try receiveData(tid: tid, sink: sink)
        }
        return try readResponse(tid: tid, code: code, alreadyRead: pending)
    }

    /// Convenience: a transaction whose data-in phase is collected in memory.
    func transactIn(_ code: UInt16, _ params: [UInt32] = []) throws -> (data: Data, params: [UInt32]) {
        var collected = Data()
        let out = try transact(code, params, data: .dataIn({ chunk, _, _ in
            collected.append(chunk)
            return true
        }))
        return (collected, out)
    }

    // MARK: - Phases

    private func sendData(code: UInt16, tid: UInt32, length: UInt64, source: Source) throws {
        let header = PTPContainer.dataHeader(code: code, transactionID: tid, payloadLength: length)
        // Header and the first payload bytes go in one transfer: some devices
        // require the header not to arrive on its own.
        var sent: UInt64 = 0
        var first = header
        if length > 0 {
            guard let chunk = try source(Self.chunkSize - header.count) else {
                throw MtpError(.cancelled, "Cancelled.")
            }
            first.append(chunk)
            sent += UInt64(chunk.count)
        }
        try transport.write(first)
        while sent < length {
            guard let chunk = try source(Self.chunkSize) else {
                try cancel(tid)
                throw MtpError(.cancelled, "Cancelled.")
            }
            if chunk.isEmpty { break }
            try transport.write(chunk)
            sent += UInt64(chunk.count)
        }
        if sent != length {
            try cancel(tid)
            throw MtpError(.failed, "The file changed size while it was being sent.")
        }
        // A transfer that ends exactly on a packet boundary needs a
        // zero-length packet to be seen as complete.
        if (UInt64(header.count) + length) % UInt64(transport.maxPacketSize) == 0 {
            try transport.write(Data())
        }
    }

    /// Receive a data phase into `sink`. Returns any bytes read beyond it (a
    /// response container that arrived instead of data).
    private func receiveData(tid: UInt32, sink: Sink) throws -> Data? {
        let packet = transport.maxPacketSize
        // Read one packet first: until we know the length, a bigger request
        // could wait forever for a device that sends no zero-length packet.
        var buffer = try readNonEmpty(capacity: packet)
        let (container, declared) = try PTPContainer.parse(buffer)
        guard container.type == .data else { return buffer }   // refused: response instead of data
        guard container.transactionID == tid else {
            throw MtpError(.disconnected, "Out-of-sequence data from the device.")
        }
        let total: UInt64? = declared == PTP.all ? nil : UInt64(declared) - UInt64(PTP.headerSize)
        buffer.removeFirst(min(PTP.headerSize, buffer.count))
        var received: UInt64 = 0
        var lastReadWasShort = buffer.count + PTP.headerSize < packet

        func deliver(_ chunk: Data) throws {
            guard !chunk.isEmpty else { return }
            received += UInt64(chunk.count)
            if try !sink(chunk, received, total) {
                try cancel(tid)
                throw MtpError(.cancelled, "Cancelled.")
            }
        }
        try deliver(buffer)

        while true {
            if let total {
                if received >= total { break }
                let remaining = Int(min(total - received, UInt64(Self.chunkSize)))
                let request = (remaining + packet - 1) / packet * packet
                let chunk = try transport.read(capacity: request)
                if chunk.isEmpty { continue }
                try deliver(chunk.prefix(Int(total - received)))
            } else {
                // Unknown length (≥ 4 GiB): read until a short packet.
                if lastReadWasShort { break }
                let chunk = try transport.read(capacity: Self.chunkSize)
                lastReadWasShort = chunk.count < Self.chunkSize
                try deliver(chunk)
            }
        }
        return nil
    }

    private func readResponse(tid: UInt32, code: UInt16, alreadyRead: Data?) throws -> [UInt32] {
        let data = try alreadyRead ?? readNonEmpty(capacity: transport.maxPacketSize)
        let (container, _) = try PTPContainer.parse(data)
        guard container.type == .response, container.transactionID == tid else {
            throw MtpError(.disconnected, "Unexpected reply from the device.")
        }
        guard container.code == PTP.Response.ok else {
            throw PTPResponseError(code: container.code, operation: code)
        }
        return container.params
    }

    /// Bulk reads can return a zero-length packet left over from a previous
    /// phase; skip those.
    private func readNonEmpty(capacity: Int) throws -> Data {
        for _ in 0..<3 {
            let data = try transport.read(capacity: capacity)
            if !data.isEmpty { return data }
        }
        throw MtpError(.disconnected, "The device stopped answering.")
    }

    private func cancel(_ tid: UInt32) throws {
        do {
            try transport.cancelTransaction(tid)
        } catch {
            // The device can't be brought back in step: treat the link as dead
            // so the session is reopened.
            throw MtpError(.disconnected, "Couldn't cancel the transfer cleanly.")
        }
    }
}

// MARK: - The device

/// An MTP device driven by our own PTP implementation (no libmtp).
final class NativeMtpDevice: MtpDevice {
    private let session: PTPSession
    private let info: PTPDeviceInfo
    private let name: String?
    private let storageID: UInt32
    private var closed = false

    /// Open a PTP session, read the device and pick its first storage. Throws
    /// `.notFileDevice` for cameras (every storage in the camera file system)
    /// and `.deviceBusy` for a device that reports no storage (locked phone).
    init(transport: PTPTransport) throws {
        let session = PTPSession(transport: transport)
        do {
            do {
                try session.transact(PTP.Op.openSession, [1])
            } catch let e as PTPResponseError where e.code == PTP.Response.sessionAlreadyOpen {
                // A previous owner left it open: start over.
                try? session.transact(PTP.Op.closeSession)
                try session.transact(PTP.Op.openSession, [1])
            }
            let info = try PTPDeviceInfo(decoding: session.transactIn(PTP.Op.getDeviceInfo).data)
            var name: String?
            if info.deviceProperties.contains(PTP.DeviceProp.friendlyName),
               let value = try? session.transactIn(PTP.Op.getDevicePropValue, [UInt32(PTP.DeviceProp.friendlyName)]).data {
                var r = PTPReader(value)
                name = (try? r.string()).flatMap { $0.isEmpty ? nil : $0 }
            }
            let deviceName = name ?? (info.model.isEmpty ? nil : info.model)

            var reader = PTPReader(try session.transactIn(PTP.Op.getStorageIDs).data)
            // A storage id with a zero low half is a slot without media.
            let ids = try reader.u32Array().filter { $0 & 0xFFFF != 0 }
            let storages = try ids.map { id in
                (id, try PTPStorageInfo(decoding: session.transactIn(PTP.Op.getStorageInfo, [id]).data))
            }
            guard let first = storages.first else {
                throw MtpError(.deviceBusy,
                    "The device didn't report any storage. Unlock it, and on a phone choose “File transfer” "
                    + "in the USB notification.")
            }
            guard storages.contains(where: { $0.1.filesystemType != PTP.filesystemDCF }) else {
                log.info("\(deviceName ?? "device", privacy: .public) is a camera (DCF storage only); leaving it alone")
                throw MtpError(.notFileDevice, deviceName ?? "Camera")
            }
            if storages.count > 1 {
                log.warning("device has several storages; only the first is shown")
            }
            self.session = session
            self.info = info
            self.name = deviceName
            self.storageID = first.0
        } catch {
            try? session.transact(PTP.Op.closeSession)
            transport.close()
            throw Self.map(error, "Opening the device")
        }
    }

    @discardableResult
    func close() -> Bool {
        guard !closed else { return true }
        closed = true
        try? session.transact(PTP.Op.closeSession)
        session.transport.close()
        return true   // IOUSBHost aborts pending I/O; nothing can dangle
    }

    func deviceName() -> String? { name }
    func serialNumber() -> String? { info.serialNumber.isEmpty ? nil : info.serialNumber }

    func ping() throws {
        _ = try run("Checking the device") { try session.transactIn(PTP.Op.getStorageIDs) }
    }

    func pollEvents() -> [DeviceEvent] {
        guard let packets = session.transport.takeEvents() else { return [.linkLost] }
        return packets.compactMap { packet in
            guard let event = (try? PTPContainer.parse(packet))?.container, event.type == .event else { return nil }
            let handle = event.params.first ?? 0
            switch event.code {
            case PTP.Event.objectAdded, PTP.Event.objectInfoChanged: return .objectAdded(handle)
            case PTP.Event.objectRemoved: return .objectRemoved(handle)
            case PTP.Event.storeAdded, PTP.Event.storeRemoved: return .storageChanged
            default: return nil
            }
        }
    }

    // MARK: - Reads

    func list(parent: UInt32) throws -> [MtpEntry] {
        try run("Listing folder \(parent)") {
            let atRoot = parent == MtpAgentConfig.rootParent
            var reader = PTPReader(try session.transactIn(PTP.Op.getObjectHandles,
                                                          [storageID, 0, atRoot ? PTP.all : parent]).data)
            var entries: [MtpEntry] = []
            for handle in try reader.u32Array() {
                // An object can vanish between the two calls; skip it.
                guard let entry = try entry(handle) else { continue }
                let isChild = atRoot ? (entry.parentID == 0 || entry.parentID == PTP.all) : entry.parentID == parent
                if isChild && entry.storageID == storageID { entries.append(entry) }
            }
            return entries
        }
    }

    func metadata(id: UInt32) throws -> MtpEntry? {
        try run("Reading object \(id)") { try entry(id) }
    }

    /// The entry for `handle`, or nil if the device says it doesn't exist.
    private func entry(_ handle: UInt32) throws -> MtpEntry? {
        let info: PTPObjectInfo
        do {
            info = try PTPObjectInfo(decoding: session.transactIn(PTP.Op.getObjectInfo, [handle]).data)
        } catch let e as PTPResponseError where e.code == PTP.Response.invalidObjectHandle {
            return nil
        }
        var size = UInt64(info.compressedSize)
        if info.compressedSize == PTP.all, self.info.operations.contains(PTP.Op.getObjectPropValue) {
            var r = PTPReader(try session.transactIn(PTP.Op.getObjectPropValue,
                                                     [handle, UInt32(PTP.ObjectProp.objectSize)]).data)
            size = try r.u64()
        }
        return MtpEntry(id: handle, parentID: info.parent, storageID: info.storageID, name: info.filename,
                        size: info.isFolder ? 0 : size, isFolder: info.isFolder,
                        modified: PTPDate.parse(info.modified))
    }

    func download(id: UInt32, toFileDescriptor fd: Int32, progress: TransferProgress?) throws {
        let expected = try metadata(id: id)?.size
        try run("Downloading object \(id)") {
            try session.transact(PTP.Op.getObject, [id], data: .dataIn({ chunk, received, total in
                try chunk.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                        if n < 0 {
                            if errno == EINTR { continue }
                            throw MtpError(.failed, "Couldn't write the downloaded file (errno \(errno)).")
                        }
                        offset += n
                    }
                }
                return progress?(received, total ?? expected ?? 0) ?? true
            }))
        }
    }

    // MARK: - Writes

    /// Parent handle for creating objects: MTP's "root" is 0xFFFFFFFF here
    /// (Android rejects 0).
    private static func createParent(_ parent: UInt32) -> UInt32 {
        parent == MtpAgentConfig.rootParent ? PTP.all : parent
    }

    func upload(fromFileDescriptor fd: Int32, parent: UInt32, name: String, size: UInt64,
                progress: TransferProgress?) throws -> UInt32 {
        try run("Uploading “\(name)”") {
            let parentArg = Self.createParent(parent)
            let handle: UInt32
            if size >= UInt64(PTP.all) {
                guard info.operations.contains(PTP.Op.sendObjectPropList) else {
                    throw MtpError(.unsupported, "This device can't receive files of 4 GB or more.")
                }
                var w = PTPWriter()
                w.u32(1)                                        // one property
                w.u32(0); w.u16(PTP.ObjectProp.objectFileName); w.u16(PTP.DataType.string); w.string(name)
                let out = try session.transact(PTP.Op.sendObjectPropList,
                    [storageID, parentArg, UInt32(PTP.Format.undefined), UInt32(size >> 32), UInt32(size & 0xFFFF_FFFF)],
                    data: .dataOut(length: UInt64(w.data.count), Self.source(w.data)))
                handle = out.count > 2 ? out[2] : 0
            } else {
                let objectInfo = PTPObjectInfo(storageID: storageID, format: PTP.Format.undefined,
                                               compressedSize: UInt32(size), parent: parentArg,
                                               filename: name, modified: PTPDate.format(Date()))
                let payload = objectInfo.encoded()
                let out = try session.transact(PTP.Op.sendObjectInfo, [storageID, parentArg],
                                               data: .dataOut(length: UInt64(payload.count), Self.source(payload)))
                handle = out.count > 2 ? out[2] : 0
            }
            var sent: UInt64 = 0
            do {
                try session.transact(PTP.Op.sendObject, data: .dataOut(length: size, { max in
                    if let progress, !progress(sent, size) { return nil }
                    var buffer = Data(count: max)
                    let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, max) }
                    if n < 0 { throw MtpError(.failed, "Couldn't read the file to upload (errno \(errno)).") }
                    buffer.count = n
                    sent += UInt64(n)
                    _ = progress?(sent, size)
                    return buffer
                }))
            } catch {
                // Don't leave a truncated object behind (unless the link is gone).
                if handle != 0, (error as? MtpError)?.kind != .disconnected {
                    try? session.transact(PTP.Op.deleteObject, [handle, 0])
                }
                throw error
            }
            return handle
        }
    }

    func createFolder(name: String, parent: UInt32) throws -> UInt32 {
        try run("Creating folder “\(name)”") {
            let parentArg = Self.createParent(parent)
            let objectInfo = PTPObjectInfo(storageID: storageID, format: PTP.Format.association,
                                           compressedSize: 0, parent: parentArg,
                                           associationType: PTP.associationGenericFolder, filename: name,
                                           modified: PTPDate.format(Date()))
            let payload = objectInfo.encoded()
            let out = try session.transact(PTP.Op.sendObjectInfo, [storageID, parentArg],
                                           data: .dataOut(length: UInt64(payload.count), Self.source(payload)))
            guard out.count > 2, out[2] != 0 else { throw MtpError(.failed, "The device didn't create the folder.") }
            return out[2]
        }
    }

    func delete(id: UInt32) throws {
        try run("Deleting object \(id)") { try session.transact(PTP.Op.deleteObject, [id, 0]) }
    }

    func rename(id: UInt32, to newName: String) throws {
        try run("Renaming object \(id)") {
            var w = PTPWriter()
            w.string(newName)
            try session.transact(PTP.Op.setObjectPropValue, [id, UInt32(PTP.ObjectProp.objectFileName)],
                                 data: .dataOut(length: UInt64(w.data.count), Self.source(w.data)))
        }
    }

    func move(id: UInt32, toParent parent: UInt32) throws {
        guard info.operations.contains(PTP.Op.moveObject) else {
            throw MtpError(.unsupported, "This device can't move files between folders.")
        }
        // For MoveObject the root is 0.
        try run("Moving object \(id)") { try session.transact(PTP.Op.moveObject, [id, storageID, parent]) }
    }

    // MARK: - Helpers

    /// A data source that sends `data` once.
    private static func source(_ data: Data) -> PTPSession.Source {
        var offset = 0
        return { max in
            let end = min(offset + max, data.count)
            defer { offset = end }
            return data.subdata(in: offset..<end)
        }
    }

    @discardableResult
    private func run<T>(_ what: String, _ body: () throws -> T) throws -> T {
        guard !closed else { throw MtpError(.disconnected, "No open MTP session.") }
        do {
            return try body()
        } catch {
            throw Self.map(error, what)
        }
    }

    /// Map PTP responses to the agent's failure categories.
    static func map(_ error: Error, _ what: String) -> MtpError {
        if let e = error as? MtpError { return e }
        guard let e = error as? PTPResponseError else { return MtpError(.failed, "\(what): \(error)") }
        let detail = String(format: "%@ (device answered 0x%04X)", what, e.code)
        switch e.code {
        case PTP.Response.invalidObjectHandle, PTP.Response.invalidParentObject:
            return MtpError(.noSuchObject, detail)
        case PTP.Response.operationNotSupported:
            return MtpError(.unsupported, detail)
        case PTP.Response.storeFull, PTP.Response.objectTooLarge:
            return MtpError(.storageFull, detail)
        case PTP.Response.objectWriteProtected, PTP.Response.storeReadOnly, PTP.Response.accessDenied:
            return MtpError(.accessDenied, detail)
        case PTP.Response.transactionCancelled:
            return MtpError(.cancelled, detail)
        case PTP.Response.deviceBusy, PTP.Response.storeNotAvailable:
            return MtpError(.deviceBusy, detail)
        default:
            return MtpError(.failed, detail)
        }
    }
}
