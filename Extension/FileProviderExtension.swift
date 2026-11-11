import FileProvider
import os

let extLog = Logger(subsystem: "no.synth.mtpmount", category: "ext")

/// The replicated File Provider extension. Phase 0 serves a static tree;
/// Phase 1 delegates to a libmtp background agent over XPC.
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
        if let node = FakeTree.node(identifier) {
            completionHandler(FileProviderItem(node), nil)
        } else {
            completionHandler(nil, fpError(.noSuchItem))
        }
        return Progress()
    }

    // MARK: - Content download

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        guard let node = FakeTree.node(itemIdentifier), !node.isFolder else {
            completionHandler(nil, nil, fpError(.noSuchItem))
            return Progress()
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FakeTree.contents(of: node).write(to: tmp)
            completionHandler(tmp, FileProviderItem(node), nil)
        } catch {
            completionHandler(nil, nil, error)
        }
        return Progress()
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
