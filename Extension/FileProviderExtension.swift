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
            case .success(let entry?):
                completionHandler(FileProviderItem(entry: entry), nil)
            case .success(nil):
                completionHandler(nil, fpError(.noSuchItem))
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
            case .success(nil):
                completionHandler(nil, nil, fpError(.noSuchItem))
            case .success(let entry?):
                AgentClient.shared.fetch(objectID: objectID) { fetchResult in
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
        completionHandler(nil, [], false, fpError(.notAuthenticated))
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, fpError(.notAuthenticated))
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(fpError(.notAuthenticated))
        return Progress()
    }
}

/// Build an NSFileProvider error without relying on the throwing bridged initializer.
func fpError(_ code: NSFileProviderError.Code) -> NSError {
    NSError(domain: NSFileProviderErrorDomain, code: code.rawValue)
}
