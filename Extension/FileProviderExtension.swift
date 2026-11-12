import FileProvider
import os

let extLog = Logger(subsystem: "no.synth.mtpmount", category: "ext")

/// The replicated File Provider extension. Delegates all device I/O to the
/// non-sandboxed libmtp agent over XPC (see `AgentClient`). Read-only.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain

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
        extLog.info("item(for: \(identifier.rawValue, privacy: .public))")
        if identifier == .rootContainer {
            completionHandler(FileProviderItem(root: "Garmin Edge"), nil)
            return Progress()
        }
        guard let objectID = UInt32(identifier.rawValue) else {
            completionHandler(nil, fpError(.noSuchItem))
            return Progress()
        }
        AgentClient.shared.item(objectID: objectID) { result in
            switch result {
            case .success(let entry):
                completionHandler(FileProviderItem(entry: entry), nil)
            case .failure(let error):
                completionHandler(nil, error)
            }
        }
        return Progress()
    }

    // MARK: - Content download

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        guard let objectID = UInt32(itemIdentifier.rawValue) else {
            completionHandler(nil, nil, fpError(.noSuchItem))
            return Progress()
        }
        let progress = Progress(totalUnitCount: 1)
        // Fetch metadata and contents; the system needs both the file URL and the item.
        AgentClient.shared.item(objectID: objectID) { itemResult in
            switch itemResult {
            case .failure(let error):
                completionHandler(nil, nil, error)
            case .success(let entry):
                AgentClient.shared.fetch(objectID: objectID, into: self.temporaryDirectory) { fetchResult in
                    switch fetchResult {
                    case .success(let url):
                        completionHandler(url, FileProviderItem(entry: entry), nil)
                    case .failure(let error):
                        completionHandler(nil, nil, error)
                    }
                    progress.completedUnitCount = 1
                }
            }
        }
        return progress
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        extLog.info("enumerator(for: \(containerItemIdentifier.rawValue, privacy: .public))")
        return Enumerator(container: containerItemIdentifier)
    }

    // MARK: - Writes (unsupported in read-only phase)

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        guard let parent = MtpID.listParent(for: itemTemplate.parentItemIdentifier) else {
            completionHandler(nil, [], false, fpError(.noSuchItem))
            return Progress()
        }
        let name = itemTemplate.filename
        let isFolder = (itemTemplate.contentType?.conforms(to: .folder)) ?? false
        extLog.info("createItem name=\(name, privacy: .public) folder=\(isFolder) parent=\(parent)")

        let made: (UInt32, UInt64) -> Void = { newID, size in
            let entry = MtpEntry(id: newID, parentID: parent, storageID: 0,
                                 name: name, size: size, isFolder: isFolder,
                                 modified: Date().timeIntervalSince1970)
            completionHandler(FileProviderItem(entry: entry), [], false, nil)
        }

        if isFolder {
            AgentClient.shared.createFolder(parent: parent, name: name) { result in
                switch result {
                case .success(let id): made(id, 0)
                case .failure(let e):  completionHandler(nil, [], false, e)
                }
            }
        } else {
            guard let url else {
                completionHandler(nil, [], false, fpError(.noSuchItem))
                return Progress()
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64) ?? 0
            AgentClient.shared.upload(parent: parent, name: name, source: url) { result in
                switch result {
                case .success(let id): made(id, size)
                case .failure(let e):  completionHandler(nil, [], false, e)
                }
            }
        }
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        guard let objectID = UInt32(item.itemIdentifier.rawValue) else {
            completionHandler(nil, [], false, fpError(.noSuchItem))
            return Progress()
        }
        // We advertise rename + move (reparent). Apply whichever changed, then
        // return the freshly-read item.
        let finish: () -> Void = {
            AgentClient.shared.item(objectID: objectID) { result in
                switch result {
                case .success(let entry): completionHandler(FileProviderItem(entry: entry), [], false, nil)
                case .failure(let e):     completionHandler(nil, [], false, e)
                }
            }
        }

        let applyMove: () -> Void = {
            if changedFields.contains(.parentItemIdentifier),
               let newParent = MtpID.listParent(for: item.parentItemIdentifier) {
                AgentClient.shared.move(objectID: objectID, toParent: newParent) { err in
                    if let err { completionHandler(nil, [], false, err) } else { finish() }
                }
            } else {
                finish()
            }
        }

        if changedFields.contains(.filename) {
            AgentClient.shared.rename(objectID: objectID, to: item.filename) { err in
                if let err { completionHandler(nil, [], false, err) } else { applyMove() }
            }
        } else {
            applyMove()
        }
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        guard let objectID = UInt32(identifier.rawValue) else {
            completionHandler(fpError(.noSuchItem))
            return Progress()
        }
        AgentClient.shared.delete(objectID: objectID, recursive: options.contains(.recursive)) { err in
            completionHandler(err)
        }
        return Progress()
    }
}
