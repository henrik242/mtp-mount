// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// PTP (ISO 15740) / MTP 1.1 wire format: containers, datasets and codes.
/// Pure Foundation, no USB: unit-tested directly.
enum PTP {
    enum ContainerType: UInt16 {
        case command = 1, data = 2, response = 3, event = 4
    }

    enum Op {
        static let getDeviceInfo: UInt16 = 0x1001
        static let openSession: UInt16 = 0x1002
        static let closeSession: UInt16 = 0x1003
        static let getStorageIDs: UInt16 = 0x1004
        static let getStorageInfo: UInt16 = 0x1005
        static let getObjectHandles: UInt16 = 0x1007
        static let getObjectInfo: UInt16 = 0x1008
        static let getObject: UInt16 = 0x1009
        static let deleteObject: UInt16 = 0x100B
        static let sendObjectInfo: UInt16 = 0x100C
        static let sendObject: UInt16 = 0x100D
        static let getDevicePropValue: UInt16 = 0x1015
        static let moveObject: UInt16 = 0x1019
        static let getObjectPropValue: UInt16 = 0x9803
        static let setObjectPropValue: UInt16 = 0x9804
        static let sendObjectPropList: UInt16 = 0x9808
    }

    enum Response {
        static let ok: UInt16 = 0x2001
        static let generalError: UInt16 = 0x2002
        static let operationNotSupported: UInt16 = 0x2005
        static let invalidStorageID: UInt16 = 0x2008
        static let invalidObjectHandle: UInt16 = 0x2009
        static let storeFull: UInt16 = 0x200C
        static let objectWriteProtected: UInt16 = 0x200D
        static let storeReadOnly: UInt16 = 0x200E
        static let accessDenied: UInt16 = 0x200F
        static let partialDeletion: UInt16 = 0x2012
        static let storeNotAvailable: UInt16 = 0x2013
        static let deviceBusy: UInt16 = 0x2019
        static let invalidParentObject: UInt16 = 0x201A
        static let sessionAlreadyOpen: UInt16 = 0x201E
        static let transactionCancelled: UInt16 = 0x201F
        static let objectTooLarge: UInt16 = 0xA809
    }

    enum Event {
        static let objectAdded: UInt16 = 0x4002
        static let objectRemoved: UInt16 = 0x4003
        static let storeAdded: UInt16 = 0x4004
        static let storeRemoved: UInt16 = 0x4005
        static let objectInfoChanged: UInt16 = 0x4007
    }

    enum Format {
        static let undefined: UInt16 = 0x3000
        static let association: UInt16 = 0x3001
    }

    enum ObjectProp {
        static let objectSize: UInt16 = 0xDC04
        static let objectFileName: UInt16 = 0xDC07
    }

    enum DeviceProp {
        static let friendlyName: UInt16 = 0xD402
    }

    enum DataType {
        static let uint64: UInt16 = 0x0008
        static let string: UInt16 = 0xFFFF
    }

    /// Filesystem type of camera storage ("Design rule for Camera File system").
    static let filesystemDCF: UInt16 = 0x0003
    static let associationGenericFolder: UInt16 = 0x0001
    /// "All storages" / "root of storage" as a handle, and "size unknown".
    static let all: UInt32 = 0xFFFF_FFFF
    static let headerSize = 12
}

/// A failure response from the device.
struct PTPResponseError: Error, Equatable {
    let code: UInt16
    let operation: UInt16
}

// MARK: - Containers

struct PTPContainer: Equatable {
    var type: PTP.ContainerType
    var code: UInt16
    var transactionID: UInt32
    var params: [UInt32]

    /// A command or event container (header + parameters).
    func encoded() -> Data {
        var w = PTPWriter()
        w.u32(UInt32(PTP.headerSize + 4 * params.count))
        w.u16(type.rawValue)
        w.u16(code)
        w.u32(transactionID)
        params.forEach { w.u32($0) }
        return w.data
    }

    /// The 12-byte header of a data container carrying `payloadLength` bytes
    /// (lengths that don't fit in 32 bits are sent as 0xFFFFFFFF).
    static func dataHeader(code: UInt16, transactionID: UInt32, payloadLength: UInt64) -> Data {
        var w = PTPWriter()
        let total = UInt64(PTP.headerSize) + payloadLength
        w.u32(total > UInt64(PTP.all - 1) ? PTP.all : UInt32(total))
        w.u16(PTP.ContainerType.data.rawValue)
        w.u16(code)
        w.u32(transactionID)
        return w.data
    }

    /// Parse a container header (and, for non-data containers, its parameters).
    /// Returns the container and its declared total length.
    static func parse(_ data: Data) throws -> (container: PTPContainer, length: UInt32) {
        var r = PTPReader(data)
        let length = try r.u32()
        let rawType = try r.u16()
        let code = try r.u16()
        let transactionID = try r.u32()
        guard let type = PTP.ContainerType(rawValue: rawType) else {
            throw MtpError(.disconnected, "Malformed PTP container (type \(rawType)).")
        }
        var params: [UInt32] = []
        if type != .data {
            let end = min(Int(length), data.count)
            while r.offset + 4 <= end && params.count < 5 { params.append(try r.u32()) }
        }
        return (PTPContainer(type: type, code: code, transactionID: transactionID, params: params), length)
    }
}

// MARK: - Little-endian reader / writer

struct PTPWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

    /// PTP string: UInt8 character count including the terminating NUL, then
    /// UCS-2LE code units. The empty string is a single 0 byte.
    mutating func string(_ s: String) {
        let units = Array(s.utf16.prefix(254))
        guard !units.isEmpty else { u8(0); return }
        u8(UInt8(units.count + 1))
        units.forEach { u16($0) }
        u16(0)
    }
}

struct PTPReader {
    private let data: Data
    private(set) var offset = 0

    init(_ data: Data) { self.data = data }

    var remaining: Int { data.count - offset }

    private mutating func take<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw MtpError(.failed, "Truncated reply from the device.") }
        var value: T = 0
        let start = data.startIndex + offset
        withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: data[start..<start + size]) }
        offset += size
        return T(littleEndian: value)
    }

    mutating func u8() throws -> UInt8 { try take(UInt8.self) }
    mutating func u16() throws -> UInt16 { try take(UInt16.self) }
    mutating func u32() throws -> UInt32 { try take(UInt32.self) }
    mutating func u64() throws -> UInt64 { try take(UInt64.self) }

    mutating func string() throws -> String {
        let count = Int(try u8())
        guard count > 0 else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0..<count { units.append(try u16()) }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    mutating func u16Array() throws -> [UInt16] {
        let count = Int(try u32())
        guard count <= remaining / 2 else { throw MtpError(.failed, "Truncated reply from the device.") }
        return try (0..<count).map { _ in try u16() }
    }

    mutating func u32Array() throws -> [UInt32] {
        let count = Int(try u32())
        guard count <= remaining / 4 else { throw MtpError(.failed, "Truncated reply from the device.") }
        return try (0..<count).map { _ in try u32() }
    }
}

// MARK: - Datasets

struct PTPDeviceInfo: Equatable {
    var vendorExtensionDesc: String
    var operations: Set<UInt16>
    var events: Set<UInt16>
    var deviceProperties: Set<UInt16>
    var manufacturer: String
    var model: String
    var serialNumber: String

    init(vendorExtensionDesc: String = "", operations: Set<UInt16>, events: Set<UInt16> = [],
         deviceProperties: Set<UInt16> = [], manufacturer: String = "", model: String = "",
         serialNumber: String = "") {
        self.vendorExtensionDesc = vendorExtensionDesc
        self.operations = operations
        self.events = events
        self.deviceProperties = deviceProperties
        self.manufacturer = manufacturer
        self.model = model
        self.serialNumber = serialNumber
    }

    init(decoding data: Data) throws {
        var r = PTPReader(data)
        _ = try r.u16()                 // StandardVersion
        _ = try r.u32()                 // VendorExtensionID
        _ = try r.u16()                 // VendorExtensionVersion
        vendorExtensionDesc = try r.string()
        _ = try r.u16()                 // FunctionalMode
        operations = Set(try r.u16Array())
        events = Set(try r.u16Array())
        deviceProperties = Set(try r.u16Array())
        _ = try r.u16Array()            // CaptureFormats
        _ = try r.u16Array()            // PlaybackFormats
        manufacturer = try r.string()
        model = try r.string()
        _ = try r.string()              // DeviceVersion
        serialNumber = (try? r.string()) ?? ""
    }

    func encoded() -> Data {
        var w = PTPWriter()
        w.u16(100); w.u32(6); w.u16(100)
        w.string(vendorExtensionDesc)
        w.u16(0)
        for set in [operations, events, deviceProperties] {
            w.u32(UInt32(set.count)); set.sorted().forEach { w.u16($0) }
        }
        w.u32(0); w.u32(0)
        w.string(manufacturer); w.string(model); w.string("1.0"); w.string(serialNumber)
        return w.data
    }
}

struct PTPStorageInfo: Equatable {
    var storageType: UInt16
    var filesystemType: UInt16
    var accessCapability: UInt16
    var maxCapacity: UInt64
    var freeSpace: UInt64
    var description: String

    init(storageType: UInt16 = 3, filesystemType: UInt16 = 2, accessCapability: UInt16 = 0,
         maxCapacity: UInt64 = 0, freeSpace: UInt64 = 0, description: String = "") {
        self.storageType = storageType
        self.filesystemType = filesystemType
        self.accessCapability = accessCapability
        self.maxCapacity = maxCapacity
        self.freeSpace = freeSpace
        self.description = description
    }

    init(decoding data: Data) throws {
        var r = PTPReader(data)
        storageType = try r.u16()
        filesystemType = try r.u16()
        accessCapability = try r.u16()
        maxCapacity = try r.u64()
        freeSpace = try r.u64()
        _ = try r.u32()                 // FreeSpaceInObjects
        description = (try? r.string()) ?? ""
    }

    func encoded() -> Data {
        var w = PTPWriter()
        w.u16(storageType); w.u16(filesystemType); w.u16(accessCapability)
        w.u64(maxCapacity); w.u64(freeSpace); w.u32(PTP.all)
        w.string(description); w.string("")
        return w.data
    }
}

struct PTPObjectInfo: Equatable {
    var storageID: UInt32
    var format: UInt16
    /// 32-bit size; 0xFFFFFFFF means "4 GiB or more, ask ObjectSize".
    var compressedSize: UInt32
    var parent: UInt32
    var associationType: UInt16
    var filename: String
    var modified: String

    init(storageID: UInt32, format: UInt16, compressedSize: UInt32, parent: UInt32,
         associationType: UInt16 = 0, filename: String, modified: String = "") {
        self.storageID = storageID
        self.format = format
        self.compressedSize = compressedSize
        self.parent = parent
        self.associationType = associationType
        self.filename = filename
        self.modified = modified
    }

    var isFolder: Bool { format == PTP.Format.association }

    init(decoding data: Data) throws {
        var r = PTPReader(data)
        storageID = try r.u32()
        format = try r.u16()
        _ = try r.u16()                 // ProtectionStatus
        compressedSize = try r.u32()
        _ = try r.u16()                 // ThumbFormat
        for _ in 0..<6 { _ = try r.u32() } // Thumb size/w/h, image w/h/depth
        parent = try r.u32()
        associationType = try r.u16()
        _ = try r.u32()                 // AssociationDesc
        _ = try r.u32()                 // SequenceNumber
        filename = try r.string()
        _ = try? r.string()             // CaptureDate
        modified = (try? r.string()) ?? ""
    }

    func encoded() -> Data {
        var w = PTPWriter()
        w.u32(storageID); w.u16(format); w.u16(0); w.u32(compressedSize)
        w.u16(0); for _ in 0..<6 { w.u32(0) }
        w.u32(parent); w.u16(associationType); w.u32(0); w.u32(0)
        w.string(filename); w.string(""); w.string(modified); w.string("")
        return w.data
    }
}

/// PTP date strings: "YYYYMMDDThhmmss[.s][Z|±hhmm]". Without a zone the
/// device's local time is meant; we read it as the Mac's local time.
enum PTPDate {
    static func parse(_ s: String) -> Double {
        let chars = Array(s)
        guard chars.count >= 15, chars[8] == "T",
              let year = Int(String(chars[0..<4])), let month = Int(String(chars[4..<6])),
              let day = Int(String(chars[6..<8])), let hour = Int(String(chars[9..<11])),
              let minute = Int(String(chars[11..<13])), let second = Int(String(chars[13..<15]))
        else { return 0 }
        var rest = chars[15...].drop { $0 == "." || $0.isNumber }
        var zone = TimeZone.current
        if rest.first == "Z" {
            zone = TimeZone(identifier: "UTC")!
        } else if let sign = rest.first, sign == "+" || sign == "-" {
            rest = rest.dropFirst()
            let digits = String(rest.prefix(4))
            if digits.count == 4, let hh = Int(digits.prefix(2)), let mm = Int(digits.suffix(2)),
               let tz = TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (hh * 3600 + mm * 60)) {
                zone = tz
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                      hour: hour, minute: minute, second: second))
        return date?.timeIntervalSince1970 ?? 0
    }

    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.string(from: date)
    }
}
