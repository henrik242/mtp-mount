// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// An MTP responder that speaks the PTP wire protocol over a fake transport,
/// so `PTPSession` and `NativeMtpDevice` can be tested end to end. Bulk-in
/// replies are queued as USB "transfers" and handed out in reads of the
/// requested capacity, like a real bulk endpoint with a small packet size.
final class SimulatedMTPDevice: PTPTransport {
    struct Object {
        var storage: UInt32
        var parent: UInt32
        var name: String
        var format: UInt16
        var data: Data
        var modified = "20250102T030405Z"
    }

    let maxPacketSize: Int
    var info = PTPDeviceInfo(
        operations: [PTP.Op.getDeviceInfo, PTP.Op.openSession, PTP.Op.closeSession, PTP.Op.getStorageIDs,
                     PTP.Op.getStorageInfo, PTP.Op.getObjectHandles, PTP.Op.getObjectInfo, PTP.Op.getObject,
                     PTP.Op.deleteObject, PTP.Op.sendObjectInfo, PTP.Op.sendObject, PTP.Op.getDevicePropValue,
                     PTP.Op.moveObject, PTP.Op.getObjectPropValue, PTP.Op.setObjectPropValue,
                     PTP.Op.sendObjectPropList],
        deviceProperties: [PTP.DeviceProp.friendlyName],
        manufacturer: "Sim", model: "SimPhone", serialNumber: "SIM1")
    var friendlyName = "Sim Phone"
    var storages: [UInt32: PTPStorageInfo] = [0x0001_0001: PTPStorageInfo(description: "Internal")]
    /// Send a zero-length packet after transfers that end on a packet boundary.
    var sendsZeroLengthPackets = true
    /// Report this object's 32-bit size as 0xFFFFFFFF (a ≥ 4 GiB file).
    var hugeObjects: [UInt32: UInt64] = [:]
    var pendingEvents: [Data] = []
    var eventsBroken = false

    private(set) var objects: [UInt32: Object] = [:]
    private(set) var closed = false
    private(set) var sessionOpen = false
    private(set) var operations: [UInt16] = []
    private var nextHandle: UInt32 = 100
    private var outbox: [Data] = []
    /// A command waiting for its data-out phase, and what has arrived of it.
    private var awaiting: (command: PTPContainer, expected: UInt64?, received: Data)?
    /// The object announced by SendObjectInfo / SendObjectPropList.
    private var announced: (handle: UInt32, size: UInt64)?

    init(maxPacketSize: Int = 64) {
        self.maxPacketSize = maxPacketSize
    }

    @discardableResult
    func add(_ name: String, parent: UInt32 = PTP.all, folder: Bool = false, data: Data = Data()) -> UInt32 {
        let handle = nextHandle
        nextHandle += 1
        objects[handle] = Object(storage: 0x0001_0001, parent: parent, name: name,
                                 format: folder ? PTP.Format.association : PTP.Format.undefined, data: data)
        return handle
    }

    func event(_ code: UInt16, _ param: UInt32) {
        pendingEvents.append(PTPContainer(type: .event, code: code, transactionID: 0, params: [param]).encoded())
    }

    // MARK: - PTPTransport

    func write(_ data: Data) throws {
        guard !closed else { throw MtpError(.disconnected, "closed") }
        if var pending = awaiting {
            if data.isEmpty { return }   // zero-length packet
            var bytes = data
            if pending.expected == nil {
                let (_, length) = try PTPContainer.parse(bytes)
                pending.expected = UInt64(length) - UInt64(PTP.headerSize)
                bytes.removeFirst(PTP.headerSize)
            }
            pending.received.append(bytes)
            awaiting = pending
            if UInt64(pending.received.count) >= pending.expected! {
                awaiting = nil
                handle(pending.command, dataOut: pending.received)
            }
            return
        }
        if data.isEmpty { return }
        let (command, _) = try PTPContainer.parse(data)
        operations.append(command.code)
        switch command.code {
        case PTP.Op.sendObjectInfo, PTP.Op.sendObject, PTP.Op.setObjectPropValue, PTP.Op.sendObjectPropList:
            awaiting = (command, nil, Data())
        default:
            handle(command, dataOut: nil)
        }
    }

    func read(capacity: Int) throws -> Data {
        guard !closed else { throw MtpError(.disconnected, "closed") }
        guard !outbox.isEmpty else { throw MtpError(.disconnected, "read with nothing to send (would hang)") }
        precondition(capacity % maxPacketSize == 0, "reads must be whole packets")
        let transfer = outbox[0]
        if transfer.count <= capacity {
            outbox.removeFirst()
            return transfer
        }
        outbox[0] = transfer.subdata(in: capacity..<transfer.count)
        return transfer.prefix(capacity)
    }

    func takeEvents() -> [Data]? {
        if eventsBroken { return nil }
        defer { pendingEvents = [] }
        return pendingEvents
    }

    func cancelTransaction(_ transactionID: UInt32) throws {
        throw MtpError(.disconnected, "cancel resets the session")
    }

    func close() { closed = true }

    // MARK: - Responder

    private func send(data payload: Data, for command: PTPContainer) {
        var transfer = PTPContainer.dataHeader(code: command.code, transactionID: command.transactionID,
                                               payloadLength: UInt64(payload.count))
        transfer.append(payload)
        outbox.append(transfer)
        if sendsZeroLengthPackets && transfer.count % maxPacketSize == 0 { outbox.append(Data()) }
    }

    private func respond(_ code: UInt16, to command: PTPContainer, _ params: [UInt32] = []) {
        outbox.append(PTPContainer(type: .response, code: code, transactionID: command.transactionID,
                                   params: params).encoded())
    }

    private func objectInfo(_ handle: UInt32, _ object: Object) -> PTPObjectInfo {
        let size = hugeObjects[handle] ?? UInt64(object.data.count)
        return PTPObjectInfo(storageID: object.storage, format: object.format,
                             compressedSize: size >= UInt64(PTP.all) ? PTP.all : UInt32(size),
                             parent: object.parent, filename: object.name, modified: object.modified)
    }

    private func handle(_ c: PTPContainer, dataOut: Data?) {
        let p = c.params + [0, 0, 0, 0, 0]
        switch c.code {
        case PTP.Op.openSession:
            if sessionOpen { return respond(PTP.Response.sessionAlreadyOpen, to: c) }
            sessionOpen = true
            respond(PTP.Response.ok, to: c)
        case PTP.Op.closeSession:
            sessionOpen = false
            respond(PTP.Response.ok, to: c)
        case PTP.Op.getDeviceInfo:
            send(data: info.encoded(), for: c)
            respond(PTP.Response.ok, to: c)
        case PTP.Op.getDevicePropValue:
            var w = PTPWriter()
            w.string(friendlyName)
            send(data: w.data, for: c)
            respond(PTP.Response.ok, to: c)
        case PTP.Op.getStorageIDs:
            var w = PTPWriter()
            w.u32(UInt32(storages.count))
            storages.keys.sorted().forEach { w.u32($0) }
            send(data: w.data, for: c)
            respond(PTP.Response.ok, to: c)
        case PTP.Op.getStorageInfo:
            guard let storage = storages[p[0]] else { return respond(PTP.Response.invalidStorageID, to: c) }
            send(data: storage.encoded(), for: c)
            respond(PTP.Response.ok, to: c)
        case PTP.Op.getObjectHandles:
            let parent = p[2] == PTP.all ? PTP.all : p[2]
            let handles = objects.filter { $0.value.parent == parent }.keys.sorted()
            var w = PTPWriter()
            w.u32(UInt32(handles.count))
            handles.forEach { w.u32($0) }
            send(data: w.data, for: c)
            respond(PTP.Response.ok, to: c)
        case PTP.Op.getObjectInfo:
            guard let object = objects[p[0]] else { return respond(PTP.Response.invalidObjectHandle, to: c) }
            send(data: objectInfo(p[0], object).encoded(), for: c)
            respond(PTP.Response.ok, to: c)
        case PTP.Op.getObjectPropValue:
            guard objects[p[0]] != nil else { return respond(PTP.Response.invalidObjectHandle, to: c) }
            var w = PTPWriter()
            w.u64(hugeObjects[p[0]] ?? UInt64(objects[p[0]]!.data.count))
            send(data: w.data, for: c)
            respond(PTP.Response.ok, to: c)
        case PTP.Op.getObject:
            guard let object = objects[p[0]] else { return respond(PTP.Response.invalidObjectHandle, to: c) }
            send(data: object.data, for: c)
            respond(PTP.Response.ok, to: c)
        case PTP.Op.deleteObject:
            guard objects[p[0]] != nil else { return respond(PTP.Response.invalidObjectHandle, to: c) }
            objects[p[0]] = nil
            respond(PTP.Response.ok, to: c)
        case PTP.Op.moveObject:
            guard objects[p[0]] != nil else { return respond(PTP.Response.invalidObjectHandle, to: c) }
            objects[p[0]]?.parent = p[2] == 0 ? PTP.all : p[2]
            respond(PTP.Response.ok, to: c)
        case PTP.Op.setObjectPropValue:
            guard objects[p[0]] != nil, let dataOut else { return respond(PTP.Response.invalidObjectHandle, to: c) }
            var r = PTPReader(dataOut)
            objects[p[0]]?.name = (try? r.string()) ?? ""
            respond(PTP.Response.ok, to: c)
        case PTP.Op.sendObjectInfo:
            guard let dataOut, let info = try? PTPObjectInfo(decoding: dataOut) else {
                return respond(PTP.Response.generalError, to: c)
            }
            guard p[1] == PTP.all || objects[p[1]]?.format == PTP.Format.association else {
                return respond(PTP.Response.invalidParentObject, to: c)
            }
            let handle = add(info.filename, parent: p[1], folder: info.isFolder)
            if !info.isFolder { announced = (handle, UInt64(info.compressedSize)) }
            respond(PTP.Response.ok, to: c, [p[0], p[1], handle])
        case PTP.Op.sendObjectPropList:
            guard let dataOut else { return respond(PTP.Response.generalError, to: c) }
            var r = PTPReader(dataOut)
            _ = try? r.u32(); _ = try? r.u32(); _ = try? r.u16(); _ = try? r.u16()
            let name = (try? r.string()) ?? ""
            let handle = add(name, parent: p[1])
            let size = UInt64(p[3]) << 32 | UInt64(p[4])
            announced = (handle, size)
            hugeObjects[handle] = size
            respond(PTP.Response.ok, to: c, [p[0], p[1], handle])
        case PTP.Op.sendObject:
            guard let announced, let dataOut else { return respond(PTP.Response.generalError, to: c) }
            objects[announced.handle]?.data = dataOut
            self.announced = nil
            respond(PTP.Response.ok, to: c)
        default:
            respond(PTP.Response.operationNotSupported, to: c)
        }
    }
}
