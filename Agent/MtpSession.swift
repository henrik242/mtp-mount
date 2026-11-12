import Foundation
import CLibmtp

enum MtpError: Error, CustomStringConvertible {
    case noDevice
    case openFailed
    case notConnected
    case downloadFailed(Int32)

    var description: String {
        switch self {
        case .noDevice:            return "No MTP device detected on USB."
        case .openFailed:          return "Found a raw device but failed to open an MTP session."
        case .notConnected:        return "No open MTP session."
        case .downloadFailed(let c): return "File download failed (libmtp code \(c))."
        }
    }
}

/// Thin Swift wrapper over libmtp for a single, long-lived device session.
///
/// NOT thread-safe: libmtp holds one stateful USB session, so every call must be
/// serialized onto a single queue by the owner (the agent does this).
/// Uses `LIBMTP_Open_Raw_Device_Uncached` so the whole object tree is *not*
/// pre-walked on connect — folders are listed on demand with
/// `LIBMTP_Get_Files_And_Folders`, which is exactly what File Provider wants.
final class MtpSession {
    /// Pass this as `parent` to list the top of the storage (maps to libmtp's ROOT).
    static let rootParent: UInt32 = 0

    private var device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
    /// Storage we browse (the Edge has a single internal storage).
    private(set) var storageID: UInt32 = 0

    /// Call once per process before any session work.
    static func initializeLibrary() {
        LIBMTP_Init()
    }

    var isOpen: Bool { device != nil }

    /// Detect and open the first connected MTP device, uncached, and pick its
    /// first storage. Throws if none is present or the open fails.
    func open() throws {
        guard device == nil else { return }

        var rawList: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        let err = LIBMTP_Detect_Raw_Devices(&rawList, &count)
        guard err == LIBMTP_ERROR_NONE, let raws = rawList, count > 0 else {
            if let r = rawList { free(r) }
            throw MtpError.noDevice
        }
        defer { free(raws) }

        guard let dev = LIBMTP_Open_Raw_Device_Uncached(&raws[0]) else {
            throw MtpError.openFailed
        }

        // Populate dev.pointee.storage.
        _ = LIBMTP_Get_Storage(dev, Int32(LIBMTP_STORAGE_SORTBY_NOTSORTED))
        guard let storage = dev.pointee.storage else {
            LIBMTP_Release_Device(dev)
            throw MtpError.openFailed
        }
        storageID = storage.pointee.id
        device = dev
    }

    func close() {
        if let dev = device {
            LIBMTP_Release_Device(dev)
            device = nil
        }
        storageID = 0
    }

    /// Friendly / model name of the open device, if any.
    func deviceName() -> String? {
        guard let dev = device else { return nil }
        if let f = LIBMTP_Get_Friendlyname(dev) {
            defer { free(f) }
            let s = String(cString: f)
            if !s.isEmpty { return s }
        }
        if let m = LIBMTP_Get_Modelname(dev) {
            defer { free(m) }
            return String(cString: m)
        }
        return nil
    }

    /// List the children of `parent` (`rootParent` for the top of storage).
    func list(parent: UInt32) throws -> [MtpEntry] {
        guard let dev = device else { throw MtpError.notConnected }
        let parentArg = (parent == Self.rootParent) ? UInt32(bitPattern: -1) : parent

        var out: [MtpEntry] = []
        var node = LIBMTP_Get_Files_And_Folders(dev, storageID, parentArg)
        while let cur = node {
            let f = cur.pointee
            let name = f.filename.map { String(cString: $0) } ?? ""
            out.append(MtpEntry(
                id: f.item_id,
                parentID: f.parent_id,
                storageID: f.storage_id,
                name: name,
                size: f.filesize,
                isFolder: f.filetype == LIBMTP_FILETYPE_FOLDER,
                modified: Double(f.modificationdate)
            ))
            node = f.next
            LIBMTP_destroy_file_t(cur)
        }
        return out
    }

    /// Metadata for a single object id (used to answer item(for:)).
    func metadata(id: UInt32) throws -> MtpEntry? {
        guard let dev = device else { throw MtpError.notConnected }
        guard let p = LIBMTP_Get_Filemetadata(dev, id) else { return nil }
        defer { LIBMTP_destroy_file_t(p) }
        let f = p.pointee
        let name = f.filename.map { String(cString: $0) } ?? ""
        return MtpEntry(
            id: f.item_id,
            parentID: f.parent_id,
            storageID: f.storage_id,
            name: name,
            size: f.filesize,
            isFolder: f.filetype == LIBMTP_FILETYPE_FOLDER,
            modified: Double(f.modificationdate)
        )
    }

    /// Download object `id` to a local path. Overwrites.
    func download(id: UInt32, to path: String) throws {
        guard let dev = device else { throw MtpError.notConnected }
        let rc = path.withCString { cpath in
            LIBMTP_Get_File_To_File(dev, id, cpath, nil, nil)
        }
        if rc != 0 { throw MtpError.downloadFailed(rc) }
    }

    /// Stream object `id` into an already-open file descriptor (owned by the
    /// caller). Lets the sandboxed extension own the destination file.
    func download(id: UInt32, toFileDescriptor fd: Int32) throws {
        guard let dev = device else { throw MtpError.notConnected }
        let rc = LIBMTP_Get_File_To_File_Descriptor(dev, id, fd, nil, nil)
        if rc != 0 { throw MtpError.downloadFailed(rc) }
    }
}
