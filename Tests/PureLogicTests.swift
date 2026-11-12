import FileProvider
import UniformTypeIdentifiers
import XCTest

final class MtpIDTests: XCTestCase {
    func testRootMapsToRootParent() {
        XCTAssertEqual(MtpID.listParent(for: .rootContainer), MtpAgentConfig.rootParent)
        XCTAssertNil(MtpID.objectID(for: .rootContainer))
    }

    func testObjectIdentifiersRoundTrip() {
        let id = MtpID.identifier(forObject: 16)
        XCTAssertEqual(id.rawValue, "16")
        XCTAssertEqual(MtpID.objectID(for: id), 16)
        XCTAssertEqual(MtpID.listParent(for: id), 16)
    }

    func testSystemContainersAndSentinelsAreNotObjects() {
        for raw in [NSFileProviderItemIdentifier.trashContainer, .workingSet,
                    NSFileProviderItemIdentifier("0"), NSFileProviderItemIdentifier("4294967295"),
                    NSFileProviderItemIdentifier("4294967296"), NSFileProviderItemIdentifier("abc")] {
            XCTAssertNil(MtpID.objectID(for: raw), raw.rawValue)
            XCTAssertNil(MtpID.listParent(for: raw), raw.rawValue)
        }
    }

    func testTopLevelParentsFoldToRoot() {
        XCTAssertEqual(MtpID.parentIdentifier(forParent: 0), .rootContainer)
        XCTAssertEqual(MtpID.parentIdentifier(forParent: 0xFFFF_FFFF), .rootContainer)
        XCTAssertEqual(MtpID.parentIdentifier(forParent: 7).rawValue, "7")
    }
}

final class FileProviderItemTests: XCTestCase {
    private func entry(_ name: String = "a.fit", folder: Bool = false, size: UInt64 = 10,
                       parent: UInt32 = 0, modified: Double = 1_700_000_000) -> MtpEntry {
        MtpEntry(id: 5, parentID: parent, storageID: 1, name: name, size: size,
                 isFolder: folder, modified: modified)
    }

    func testRootCannotBeDeletedRenamedOrMoved() {
        let caps = FileProviderItem(root: "Garmin Edge").capabilities
        XCTAssertTrue(caps.contains(.allowsAddingSubItems))
        XCTAssertFalse(caps.contains(.allowsDeleting))
        XCTAssertFalse(caps.contains(.allowsRenaming))
        XCTAssertFalse(caps.contains(.allowsReparenting))
    }

    func testCapabilitiesNeverOfferInPlaceWritesOrTrash() {
        for item in [FileProviderItem(entry: entry()), FileProviderItem(entry: entry(folder: true))] {
            XCTAssertFalse(item.capabilities.contains(.allowsWriting))
            XCTAssertFalse(item.capabilities.contains(.allowsTrashing))
            XCTAssertTrue(item.capabilities.contains(.allowsDeleting))
        }
    }

    func testFolderAndFileAttributes() {
        let folder = FileProviderItem(entry: entry("Activity", folder: true))
        XCTAssertNil(folder.documentSize)
        XCTAssertEqual(folder.contentType, .folder)
        let file = FileProviderItem(entry: entry("notes.txt", size: 42))
        XCTAssertEqual(file.documentSize, 42)
        XCTAssertTrue(file.contentType.conforms(to: .plainText))
        XCTAssertNil(FileProviderItem(entry: entry(modified: 0)).contentModificationDate)
    }

    func testVersionTracksContentAndMetadata() {
        let base = FileProviderItem(entry: entry()).itemVersion
        XCTAssertTrue(base.isSame(as: FileProviderItem(entry: entry()).itemVersion))
        XCTAssertFalse(base.isSame(as: FileProviderItem(entry: entry(size: 11)).itemVersion))
        XCTAssertFalse(base.isSame(as: FileProviderItem(entry: entry(modified: 1)).itemVersion))
        XCTAssertFalse(base.isSame(as: FileProviderItem(entry: entry("b.fit")).itemVersion))
        XCTAssertFalse(base.isSame(as: FileProviderItem(entry: entry(parent: 9)).itemVersion))
        // Both top-level parent encodings are the same location.
        XCTAssertTrue(base.isSame(as: FileProviderItem(entry: entry(parent: 0xFFFF_FFFF)).itemVersion))
    }

    func testEntryRoundTripsLargeSizesAndUnicode() throws {
        let original = entry("Løype 🚴‍♀️.fit", size: 5_000_000_000)
        let decoded = try JSONDecoder().decode(MtpEntry.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}

final class ErrorMappingTests: XCTestCase {
    private func mapped(_ failure: MtpFailure) -> NSError {
        FileProviderErrors.map(NSError.mtp(failure, "msg")) as NSError
    }

    func testDeviceAbsenceIsServerUnreachable() {
        for failure in [MtpFailure.noDevice, .deviceBusy, .disconnected] {
            let e = mapped(failure)
            XCTAssertEqual(e.domain, NSFileProviderErrorDomain)
            XCTAssertEqual(e.code, NSFileProviderError.Code.serverUnreachable.rawValue)
            XCTAssertEqual(e.localizedDescription, "msg")
        }
    }

    func testObjectFailuresMapToFileProviderCodes() {
        let expected: [MtpFailure: NSFileProviderError.Code] = [
            .noSuchObject: .noSuchItem,
            .storageFull: .insufficientQuota,
            .directoryNotEmpty: .directoryNotEmpty,
            .nameCollision: .filenameCollision,
            .failed: .cannotSynchronize,
        ]
        for (failure, code) in expected {
            let e = mapped(failure)
            XCTAssertEqual(e.domain, NSFileProviderErrorDomain, "\(failure)")
            XCTAssertEqual(e.code, code.rawValue, "\(failure)")
        }
    }

    func testCocoaConventions() {
        XCTAssertEqual(mapped(.unsupported).code, NSFeatureUnsupportedError)
        XCTAssertEqual(mapped(.accessDenied).code, NSFileWriteNoPermissionError)
        XCTAssertEqual(mapped(.cancelled).code, NSUserCancelledError)
    }

    func testEveryFailureIsMappedAwayFromTheAgentDomain() {
        for failure in MtpFailure.allCases {
            XCTAssertNotEqual(mapped(failure).domain, MtpAgentConfig.errorDomain, "\(failure)")
        }
    }

    func testXPCFailuresAreServerUnreachable() {
        let e = FileProviderErrors.map(NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted)) as NSError
        XCTAssertEqual(e.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(e.code, NSFileProviderError.Code.serverUnreachable.rawValue)
    }
}

final class ClassifierTests: XCTestCase {
    func testEmptyStackIsInconclusive() {
        XCTAssertNil(MtpErrorClassifier.classify([]))
    }

    func testTransportErrors() {
        XCTAssertEqual(MtpErrorClassifier.classify([(.usbLayer, "x")]), .disconnected)
        XCTAssertEqual(MtpErrorClassifier.classify([(.ptpLayer, "PTP Layer error 02ff: PTP I/O Error")]), .disconnected)
        XCTAssertEqual(MtpErrorClassifier.classify([(.ptpLayer, "PTP Layer error 02fa: Timeout")]), .disconnected)
    }

    func testDeviceResponses() {
        XCTAssertEqual(MtpErrorClassifier.classify([(.ptpLayer, "PTP Layer error 2009: Invalid ObjectHandle")]), .noSuchObject)
        XCTAssertEqual(MtpErrorClassifier.classify([(.ptpLayer, "PTP Layer error 200C: Store Full")]), .storageFull)
        XCTAssertEqual(MtpErrorClassifier.classify([(.ptpLayer, "PTP Layer error 2005: Operation Not Supported")]), .unsupported)
        XCTAssertEqual(MtpErrorClassifier.classify([(.ptpLayer, "PTP Layer error 2002: General Error")]), .failed)
        XCTAssertEqual(MtpErrorClassifier.classify([(.storageFull, "")]), .storageFull)
    }

    func testTransportWinsOverOtherErrors() {
        let stack: [(kind: LibmtpErrorKind, text: String)] = [
            (.ptpLayer, "PTP Layer error 2009: Invalid ObjectHandle"),
            (.ptpLayer, "PTP Layer error 02ff: PTP I/O Error"),
        ]
        XCTAssertEqual(MtpErrorClassifier.classify(stack), .disconnected)
    }
}

final class SyncAnchorTests: XCTestCase {
    private func status(_ session: String?, serial: String? = "S1", connected: Bool = true) -> AgentStatus {
        AgentStatus(connected: connected, deviceName: "Edge", serial: serial, sessionID: session,
                    failure: nil, message: nil)
    }

    func testOfflineAnchor() {
        XCTAssertEqual(SyncAnchor.make(nil), Data("offline".utf8))
        XCTAssertEqual(SyncAnchor.make(status(nil, connected: false)), Data("offline".utf8))
    }

    func testAnchorChangesWithSessionOrDevice() {
        let a = SyncAnchor.make(status("x-1"))
        XCTAssertEqual(a, SyncAnchor.make(status("x-1")))
        XCTAssertNotEqual(a, SyncAnchor.make(status("x-2")))
        XCTAssertNotEqual(a, SyncAnchor.make(status("x-1", serial: "S2")))
    }
}
