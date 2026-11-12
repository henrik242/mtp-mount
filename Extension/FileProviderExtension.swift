import FileProvider
import UniformTypeIdentifiers
import os

let extLog = Logger(subsystem: MtpAgentConfig.logSubsystem, category: "ext")

/// The replicated File Provider extension. Delegates all device I/O to the
/// non-sandboxed libmtp agent over XPC (see `AgentClient`).
///
/// Supported: browse, download, upload, create folder, rename, move, delete.
/// Not supported (MTP has no partial writes and a re-upload changes the object
/// id): editing a file's contents in place.
///
/// Object ids are only meaningful within one USB session, so every operation
/// that changes an existing object first re-reads it and compares its version
/// with the one the system based the change on; on a mismatch the device's
/// state wins and nothing is touched.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    private let agent = AgentClient.shared

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        extLog.info("FileProviderExtension init domain=\(domain.identifier.rawValue, privacy: .public)")
    }

    func invalidate() {}

    /// Where downloads are staged: the domain's own temporary directory (on the
    /// same volume as the replicated files, so the system can move rather than
    /// copy), falling back to the sandbox temp dir.
    var temporaryDirectory: URL {
        (try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL())
            ?? FileManager.default.temporaryDirectory
    }

    // MARK: - Metadata

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        extLog.debug("item(for: \(identifier.rawValue, privacy: .public))")
        if identifier == .rootContainer {
            completionHandler(FileProviderItem(root: FP.domainDisplayName), nil)
            return Progress()
        }
        guard let objectID = MtpID.objectID(for: identifier) else {
            completionHandler(nil, fpError(.noSuchItem))
            return Progress()
        }
        agent.item(objectID: objectID) { result in
            switch result {
            case .success(let entry): completionHandler(FileProviderItem(entry: entry), nil)
            case .failure(let error): completionHandler(nil, error)
            }
        }
        return Progress()
    }

    // MARK: - Content download

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        guard let objectID = MtpID.objectID(for: itemIdentifier) else {
            completionHandler(nil, nil, fpError(.noSuchItem))
            return progress
        }
        // The system needs both the file and the matching item metadata.
        agent.item(objectID: objectID) { itemResult in
            switch itemResult {
            case .failure(let error):
                completionHandler(nil, nil, error)
            case .success(let entry):
                self.agent.fetch(objectID: objectID, into: self.temporaryDirectory, progress: progress) {
                    switch $0 {
                    case .success(let url): completionHandler(url, FileProviderItem(entry: entry), nil)
                    case .failure(let error): completionHandler(nil, nil, error)
                    }
                }
            }
        }
        return progress
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        extLog.debug("enumerator(for: \(containerItemIdentifier.rawValue, privacy: .public))")
        return Enumerator(container: containerItemIdentifier)
    }

    // MARK: - Writes

    /// Read `objectID` and check it's still the item the system knows as
    /// `baseVersion`; replies with the current entry, or an error.
    private func verify(_ objectID: UInt32, against baseVersion: NSFileProviderItemVersion,
                        completion: @escaping (Result<(entry: MtpEntry, matches: Bool), Error>) -> Void) {
        agent.item(objectID: objectID) { result in
            completion(result.map { entry -> (entry: MtpEntry, matches: Bool) in
                (entry: entry, matches: FileProviderItem(entry: entry).itemVersion.isSame(as: baseVersion))
            })
        }
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let fail: (Error) -> Void = { completionHandler(nil, [], false, $0) }

        guard let parent = MtpID.listParent(for: itemTemplate.parentItemIdentifier) else {
            fail(fpError(.noSuchItem))
            return progress
        }
        let name = itemTemplate.filename
        let type = itemTemplate.contentType ?? .data
        if type.conforms(to: .symbolicLink) || (type.conforms(to: .directory) && !type.conforms(to: .folder)) {
            fail(cocoaError(NSFeatureUnsupportedError,
                            "Packages and symbolic links can't be stored on an MTP device."))
            return progress
        }
        let isFolder = type.conforms(to: .folder)
        extLog.info("createItem name=\(name, privacy: .public) folder=\(isFolder) parent=\(parent)")

        // Report the object as the device stored it (its real name, date and
        // size), so its version matches what later enumerations return.
        let created: (Result<UInt32, Error>) -> Void = { result in
            switch result {
            case .failure(let error):
                fail(error)
            case .success(let newID):
                self.agent.item(objectID: newID) { read in
                    switch read {
                    case .success(let entry):
                        completionHandler(FileProviderItem(entry: entry), [], false, nil)
                    case .failure(let error):
                        extLog.error("created \(newID) but re-reading it failed: \(error.localizedDescription, privacy: .public)")
                        fail(error)
                    }
                }
            }
        }

        let create: () -> Void = {
            if isFolder {
                self.agent.createFolder(parent: parent, name: name, completion: created)
            } else if let url {
                self.agent.upload(parent: parent, name: name, source: url, progress: progress, completion: created)
            } else {
                fail(cocoaError(NSFileReadNoSuchFileError, "No contents to upload for “\(name)”."))
            }
        }

        // When the system re-imports (e.g. after a reset) the item may already
        // be on the device: adopt it instead of uploading a duplicate.
        guard options.contains(.mayAlreadyExist) else {
            create()
            return progress
        }
        agent.list(parent: parent) { result in
            switch result {
            case .failure(let error):
                fail(error)
            case .success(let siblings):
                if let match = siblings.first(where: {
                    $0.isFolder == isFolder && $0.name.caseInsensitiveCompare(name) == .orderedSame
                }) {
                    completionHandler(FileProviderItem(entry: match), [], false, nil)
                } else {
                    create()
                }
            }
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let fail: (Error) -> Void = { completionHandler(nil, [], false, $0) }
        guard let objectID = MtpID.objectID(for: item.itemIdentifier) else {
            fail(item.itemIdentifier == .rootContainer
                 ? cocoaError(NSFeatureUnsupportedError, "The device itself can't be changed.")
                 : fpError(.noSuchItem))
            return Progress()
        }
        if changedFields.contains(.contents) {
            fail(cocoaError(NSFeatureUnsupportedError,
                            "Files on an MTP device can't be edited in place. Copy the file to your Mac, edit it there and copy it back."))
            return Progress()
        }
        var newParent: UInt32?
        if changedFields.contains(.parentItemIdentifier) {
            guard let p = MtpID.listParent(for: item.parentItemIdentifier) else {
                // e.g. the Trash: we don't offer trashing, so this can only be refused.
                fail(cocoaError(NSFeatureUnsupportedError, "Items on the device can only be moved within the device."))
                return Progress()
            }
            newParent = p
        }
        let newName = changedFields.contains(.filename) ? item.filename : nil
        // Other fields (dates, tags, xattrs, …) have no MTP equivalent; they're
        // accepted and dropped.

        let finish: () -> Void = {
            self.agent.item(objectID: objectID) { result in
                switch result {
                case .success(let entry): completionHandler(FileProviderItem(entry: entry), [], false, nil)
                case .failure(let error): fail(error)
                }
            }
        }
        let applyMove: () -> Void = {
            guard let newParent else { finish(); return }
            self.agent.move(objectID: objectID, toParent: newParent) { error in
                if let error { fail(error) } else { finish() }
            }
        }
        let applyRename: () -> Void = {
            guard let newName else { applyMove(); return }
            self.agent.rename(objectID: objectID, to: newName) { error in
                // A failed rename stops before the move, so nothing is half-applied.
                if let error { fail(error) } else { applyMove() }
            }
        }

        verify(objectID, against: version) { result in
            switch result {
            case .failure(let error):
                fail(error)
            case .success(let (entry, matches)):
                if matches {
                    applyRename()
                } else {
                    // Changed on the device (or the id now names another object):
                    // the device wins; report its state and apply nothing.
                    extLog.notice("modifyItem \(objectID): version mismatch, keeping device state")
                    completionHandler(FileProviderItem(entry: entry), [], false, nil)
                }
            }
        }
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        guard let objectID = MtpID.objectID(for: identifier) else {
            completionHandler(identifier == .rootContainer
                              ? cocoaError(NSFeatureUnsupportedError, "The device itself can't be deleted.")
                              : fpError(.noSuchItem))
            return Progress()
        }
        verify(objectID, against: version) { result in
            switch result {
            case .failure(let error as NSError) where error.domain == NSFileProviderErrorDomain
                && error.code == NSFileProviderError.Code.noSuchItem.rawValue:
                completionHandler(nil)   // already gone
            case .failure(let error):
                completionHandler(error)
            case .success(let (_, matches)):
                guard matches else {
                    // Don't delete something that changed since the user saw it
                    // (or a different object behind a reused id); the system
                    // re-creates the item locally instead.
                    completionHandler(fpError(.deletionRejected,
                                              "The item changed on the device and wasn't deleted."))
                    return
                }
                self.agent.delete(objectID: objectID, recursive: options.contains(.recursive)) {
                    completionHandler($0)
                }
            }
        }
        return Progress()
    }
}

extension NSFileProviderItemVersion {
    func isSame(as other: NSFileProviderItemVersion) -> Bool {
        contentVersion == other.contentVersion && metadataVersion == other.metadataVersion
    }
}
