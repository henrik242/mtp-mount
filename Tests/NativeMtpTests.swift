// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest

final class PTPCodecTests: XCTestCase {
    func testStringsRoundTrip() throws {
        for s in ["", "a", "DCIM", "Løype 🚴‍♀️.gpx", String(repeating: "x", count: 300)] {
            var w = PTPWriter()
            w.string(s)
            var r = PTPReader(w.data)
            XCTAssertEqual(try r.string(), String(s.utf16.prefix(254))!, s)
            XCTAssertEqual(r.remaining, 0)
        }
        var w = PTPWriter()
        w.string("")
        XCTAssertEqual(w.data, Data([0]), "the empty string is a single zero byte")
    }

    func testContainerRoundTrip() throws {
        let c = PTPContainer(type: .command, code: PTP.Op.getObjectHandles, transactionID: 7, params: [1, 0, PTP.all])
        let data = c.encoded()
        XCTAssertEqual(data.count, 24)
        let (parsed, length) = try PTPContainer.parse(data)
        XCTAssertEqual(parsed, c)
        XCTAssertEqual(length, 24)
    }

    func testHugeDataHeaderUsesUnknownLength() throws {
        let header = PTPContainer.dataHeader(code: PTP.Op.sendObject, transactionID: 1, payloadLength: 5_000_000_000)
        XCTAssertEqual(try PTPContainer.parse(header).length, PTP.all)
    }

    func testDatasetsRoundTrip() throws {
        let object = PTPObjectInfo(storageID: 0x10001, format: PTP.Format.association, compressedSize: 0,
                                   parent: 42, associationType: 1, filename: "Camera", modified: "20250102T030405")
        XCTAssertEqual(try PTPObjectInfo(decoding: object.encoded()), object)
        let info = PTPDeviceInfo(vendorExtensionDesc: "microsoft.com: 1.0", operations: [0x1001, 0x1002],
                                 deviceProperties: [0xD402], manufacturer: "M", model: "X", serialNumber: "S")
        XCTAssertEqual(try PTPDeviceInfo(decoding: info.encoded()), info)
        let storage = PTPStorageInfo(filesystemType: PTP.filesystemDCF, maxCapacity: 1 << 40, freeSpace: 5)
        XCTAssertEqual(try PTPStorageInfo(decoding: storage.encoded()), storage)
    }

    func testTruncatedDataThrows() {
        var r = PTPReader(Data([1, 2]))
        XCTAssertThrowsError(try r.u32())
    }

    func testDates() {
        XCTAssertEqual(PTPDate.parse("20250102T030405Z"), 1_735_787_045)
        XCTAssertEqual(PTPDate.parse("20250102T050405+0200"), 1_735_787_045)
        XCTAssertEqual(PTPDate.parse("20250102T030405.0Z"), 1_735_787_045)
        XCTAssertEqual(PTPDate.parse(""), 0)
        XCTAssertEqual(PTPDate.parse("garbage"), 0)
        let local = PTPDate.parse(PTPDate.format(Date(timeIntervalSince1970: 1_735_787_045)))
        XCTAssertEqual(local, 1_735_787_045)
    }
}

final class NativeMtpDeviceTests: XCTestCase {
    private var sim: SimulatedMTPDevice!

    override func setUp() {
        sim = SimulatedMTPDevice()
    }

    private func open() throws -> NativeMtpDevice {
        try NativeMtpDevice(transport: sim)
    }

    private func tempFile(_ contents: Data = Data()) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try contents.write(to: url)
        return url
    }

    func testOpenReadsNameSerialAndStorage() throws {
        let device = try open()
        XCTAssertTrue(sim.sessionOpen)
        XCTAssertEqual(device.deviceName(), "Sim Phone")
        XCTAssertEqual(device.serialNumber(), "SIM1")
        XCTAssertNoThrow(try device.ping())
    }

    func testFallsBackToModelWithoutFriendlyName() throws {
        sim.info.deviceProperties = []
        XCTAssertEqual(try open().deviceName(), "SimPhone")
    }

    func testReopensASessionLeftOpen() throws {
        _ = try open()
        _ = try open()   // the simulator still has the session open
        XCTAssertTrue(sim.operations.contains(PTP.Op.closeSession))
    }

    func testCameraIsRejected() {
        sim.storages = [0x0001_0001: PTPStorageInfo(filesystemType: PTP.filesystemDCF)]
        XCTAssertThrowsError(try open()) { XCTAssertEqual(($0 as? MtpError)?.kind, .notFileDevice) }
        XCTAssertTrue(sim.closed)
    }

    func testLockedPhoneWithoutStorageIsBusy() {
        sim.storages = [0x0001_0000: PTPStorageInfo()]   // slot without media
        XCTAssertThrowsError(try open()) { XCTAssertEqual(($0 as? MtpError)?.kind, .deviceBusy) }
    }

    func testListsRootAndFolders() throws {
        let dcim = sim.add("DCIM", folder: true)
        let camera = sim.add("Camera", parent: dcim, folder: true)
        sim.add("IMG_0001.jpg", parent: camera, data: Data(repeating: 7, count: 1000))
        let device = try open()

        let root = try device.list(parent: MtpAgentConfig.rootParent)
        XCTAssertEqual(root.map(\.name), ["DCIM"])
        XCTAssertTrue(root[0].isFolder)
        let photos = try device.list(parent: camera)
        XCTAssertEqual(photos.map(\.name), ["IMG_0001.jpg"])
        XCTAssertEqual(photos[0].size, 1000)
        XCTAssertEqual(photos[0].modified, 1_735_787_045)
        XCTAssertEqual(MtpID.parentIdentifier(forParent: root[0].parentID), .rootContainer)
    }

    func testMetadataForMissingObjectIsNil() throws {
        XCTAssertNil(try open().metadata(id: 999))
    }

    func testHugeObjectSizeComesFromObjectSizeProperty() throws {
        let id = sim.add("movie.mp4")
        sim.hugeObjects[id] = 6_000_000_000
        XCTAssertEqual(try open().metadata(id: id)?.size, 6_000_000_000)
    }

    func testDownloadStreamsAcrossManyPacketsWithProgress() throws {
        // 64-byte packets: header + payload span many reads; a payload that
        // ends on a packet boundary exercises the zero-length packet.
        for count in [0, 52, 1000, 64 * 10 - 12, 3 * PTPSession.chunkSize + 17] {
            for zlp in [true, false] {
                sim = SimulatedMTPDevice()
                sim.sendsZeroLengthPackets = zlp
                let bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) })
                let id = sim.add("f.bin", data: bytes)
                let device = try open()
                let url = try tempFile()
                let handle = try FileHandle(forWritingTo: url)
                var last: (UInt64, UInt64)?
                try device.download(id: id, toFileDescriptor: handle.fileDescriptor) { done, total in
                    last = (done, total)
                    return true
                }
                try handle.close()
                XCTAssertEqual(try Data(contentsOf: url), bytes, "count \(count) zlp \(zlp)")
                if count > 0 {
                    XCTAssertEqual(last?.0, UInt64(count))
                    XCTAssertEqual(last?.1, UInt64(count))
                }
                XCTAssertNoThrow(try device.ping(), "still in step after the transfer")
            }
        }
    }

    func testCancelledDownloadResetsTheSession() throws {
        let id = sim.add("f.bin", data: Data(count: 10_000))
        let device = try open()
        let url = try tempFile()
        let handle = try FileHandle(forWritingTo: url)
        XCTAssertThrowsError(try device.download(id: id, toFileDescriptor: handle.fileDescriptor) { _, _ in false }) {
            XCTAssertEqual(($0 as? MtpError)?.kind, .disconnected, "a cancel reopens the session")
        }
    }

    func testUploadCreatesTheObjectWithItsBytes() throws {
        let folder = sim.add("Download", folder: true)
        let bytes = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0) })
        let url = try tempFile(bytes)
        let handle = try FileHandle(forReadingFrom: url)
        let device = try open()
        var progressCalls = 0
        let id = try device.upload(fromFileDescriptor: handle.fileDescriptor, parent: folder, name: "doc.pdf",
                                   size: UInt64(bytes.count)) { _, _ in progressCalls += 1; return true }
        XCTAssertEqual(sim.objects[id]?.name, "doc.pdf")
        XCTAssertEqual(sim.objects[id]?.parent, folder)
        XCTAssertEqual(sim.objects[id]?.data, bytes)
        XCTAssertGreaterThan(progressCalls, 0)
    }

    func testUploadToRootUsesTheMTPRootHandle() throws {
        let file = try FileHandle(forReadingFrom: tempFile(Data("hi".utf8)))   // keep it open
        let id = try open().upload(fromFileDescriptor: file.fileDescriptor,
                                   parent: MtpAgentConfig.rootParent, name: "a.txt", size: 2, progress: nil)
        XCTAssertEqual(sim.objects[id]?.parent, PTP.all)
        XCTAssertEqual(sim.objects[id]?.data, Data("hi".utf8))
        try file.close()
    }

    func testEmptyFileUpload() throws {
        let file = try FileHandle(forReadingFrom: tempFile())
        let id = try open().upload(fromFileDescriptor: file.fileDescriptor,
                                   parent: MtpAgentConfig.rootParent, name: "empty", size: 0, progress: nil)
        XCTAssertEqual(sim.objects[id]?.data, Data())
        try file.close()
    }

    func testCreateFolderRenameMoveDelete() throws {
        let device = try open()
        let folder = try device.createFolder(name: "Music", parent: MtpAgentConfig.rootParent)
        XCTAssertEqual(sim.objects[folder]?.format, PTP.Format.association)
        let file = sim.add("song.mp3")
        try device.rename(id: file, to: "Song 🎵.mp3")
        XCTAssertEqual(sim.objects[file]?.name, "Song 🎵.mp3")
        try device.move(id: file, toParent: folder)
        XCTAssertEqual(sim.objects[file]?.parent, folder)
        try device.move(id: file, toParent: MtpAgentConfig.rootParent)
        XCTAssertEqual(sim.objects[file]?.parent, PTP.all)
        try device.delete(id: file)
        XCTAssertNil(sim.objects[file])
    }

    func testDeviceRefusalsMapToFailures() throws {
        let device = try open()
        XCTAssertThrowsError(try device.delete(id: 999)) { XCTAssertEqual(($0 as? MtpError)?.kind, .noSuchObject) }
        XCTAssertThrowsError(try device.createFolder(name: "x", parent: 4242)) {
            XCTAssertEqual(($0 as? MtpError)?.kind, .noSuchObject)
        }
        XCTAssertNoThrow(try device.ping(), "refusals keep the session in step")
    }

    func testMoveWithoutMoveObjectIsUnsupported() throws {
        sim.info.operations.remove(PTP.Op.moveObject)
        let file = sim.add("a")
        XCTAssertThrowsError(try open().move(id: file, toParent: MtpAgentConfig.rootParent)) {
            XCTAssertEqual(($0 as? MtpError)?.kind, .unsupported)
        }
    }

    func testEventsBecomeDeviceEvents() throws {
        let device = try open()
        sim.event(PTP.Event.objectAdded, 7)
        sim.event(PTP.Event.objectRemoved, 8)
        sim.event(PTP.Event.objectInfoChanged, 9)
        sim.event(PTP.Event.storeAdded, 0x20001)
        sim.event(0x4006, 0xD401)   // DevicePropChanged: ignored
        XCTAssertEqual(device.pollEvents(), [.objectAdded(7), .objectRemoved(8), .objectAdded(9), .storageChanged])
        XCTAssertEqual(device.pollEvents(), [])
        sim.eventsBroken = true
        XCTAssertEqual(device.pollEvents(), [.linkLost])
    }

    func testDeadLinkIsATransportFailure() throws {
        let device = try open()
        sim.close()
        XCTAssertThrowsError(try device.ping()) { XCTAssertEqual(($0 as? MtpError)?.kind, .disconnected) }
    }

    func testCloseEndsTheSession() throws {
        let device = try open()
        XCTAssertTrue(device.close())
        XCTAssertFalse(sim.sessionOpen)
        XCTAssertTrue(sim.closed)
        XCTAssertThrowsError(try device.list(parent: 0))
    }

}
