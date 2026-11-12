import Foundation

/// Thin XPC client the extension uses to reach the non-sandboxed libmtp agent.
/// The connection is lazy and self-healing: launchd starts the agent on demand
/// when we look up its mach service. An *interrupted* connection stays usable
/// (launchd relaunches the agent on the next message); only an *invalidated*
/// one is replaced. Every failure is mapped with `FileProviderErrors.map`.
final class AgentClient {
    static let shared = AgentClient()

    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let c = NSXPCConnection(machServiceName: MtpAgentConfig.machServiceName, options: [])
        c.remoteObjectInterface = NSXPCInterface(with: MtpAgentXPC.self)
        // Only talk to an agent signed by our team (the mach name alone
        // could be squatted by another process in the user's session).
        c.setCodeSigningRequirement(MtpAgentConfig.agentRequirement)
        c.invalidationHandler = { [weak self, weak c] in self?.forget(c) }
        c.resume()
        connection = c
        return c
    }

    /// Drop `c` if it's still the current connection (a late invalidation of an
    /// old connection must not discard a newer one).
    private func forget(_ c: NSXPCConnection?) {
        lock.lock()
        defer { lock.unlock() }
        if let c, connection === c { connection = nil }
    }

    private func proxy(_ onError: @escaping (Error) -> Void) -> MtpAgentXPC? {
        let p = currentConnection().remoteObjectProxyWithErrorHandler { onError(FileProviderErrors.map($0)) }
        guard let agent = p as? MtpAgentXPC else {
            onError(fpError(.serverUnreachable, "Couldn't reach the MtpMount helper."))
            return nil
        }
        return agent
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?, _ error: NSError?) -> Result<T, Error> {
        if let error { return .failure(FileProviderErrors.map(error)) }
        do {
            return .success(try JSONDecoder().decode(T.self, from: data ?? Data()))
        } catch {
            return .failure(fpError(.cannotSynchronize, "Malformed reply from the helper.", underlying: error))
        }
    }

    // MARK: - Calls

    func status(completion: @escaping (Result<AgentStatus, Error>) -> Void) {
        proxy { completion(.failure($0)) }?.status { data in
            completion(Self.decode(AgentStatus.self, data, nil))
        }
    }

    func list(parent: UInt32, completion: @escaping (Result<[MtpEntry], Error>) -> Void) {
        proxy { completion(.failure($0)) }?.list(parent: parent) { data, error in
            completion(Self.decode([MtpEntry].self, data, error))
        }
    }

    /// Fails with `.noSuchItem` if the object no longer exists on the device.
    func item(objectID: UInt32, completion: @escaping (Result<MtpEntry, Error>) -> Void) {
        proxy { completion(.failure($0)) }?.item(objectID: objectID) { data, error in
            completion(Self.decode(MtpEntry.self, data, error))
        }
    }

    /// Download `objectID` into a fresh file in `directory` (owned by the
    /// extension) and return its URL. The extension passes the open fd to the
    /// agent over XPC. The file is removed on any failure.
    func fetch(objectID: UInt32, into directory: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let dest = directory.appendingPathComponent("mtp-\(objectID)-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: dest.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: dest) else {
            completion(.failure(fpError(.cannotSynchronize, "Couldn't create a temporary file.")))
            return
        }
        let fail: (Error) -> Void = { error in
            try? handle.close()
            try? FileManager.default.removeItem(at: dest)
            completion(.failure(error))
        }
        proxy(fail)?.fetch(objectID: objectID, into: handle) { error in
            if let error { fail(FileProviderErrors.map(error)); return }
            try? handle.close()
            completion(.success(dest))
        }
    }

    // MARK: - Writes

    /// Upload a local file as a new object under `parent`. Returns the new MTP id.
    func upload(parent: UInt32, name: String, source: URL,
                completion: @escaping (Result<UInt32, Error>) -> Void) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: source.path))?[.size] as? UInt64) ?? 0
        guard let handle = try? FileHandle(forReadingFrom: source) else {
            completion(.failure(fpError(.cannotSynchronize, "Couldn't read the file to upload.")))
            return
        }
        let fail: (Error) -> Void = { error in
            try? handle.close()
            completion(.failure(error))
        }
        proxy(fail)?.upload(parent: parent, name: name, size: size, from: handle) { newID, error in
            if let error { fail(FileProviderErrors.map(error)); return }
            try? handle.close()
            completion(.success(newID))
        }
    }

    func createFolder(parent: UInt32, name: String,
                      completion: @escaping (Result<UInt32, Error>) -> Void) {
        proxy { completion(.failure($0)) }?.createFolder(parent: parent, name: name) { newID, error in
            if let error { completion(.failure(FileProviderErrors.map(error))) } else { completion(.success(newID)) }
        }
    }

    func delete(objectID: UInt32, recursive: Bool, completion: @escaping (Error?) -> Void) {
        proxy { completion($0) }?.delete(objectID: objectID, recursive: recursive) { error in
            completion(error.map { FileProviderErrors.map($0) })
        }
    }

    func rename(objectID: UInt32, to newName: String, completion: @escaping (Error?) -> Void) {
        proxy { completion($0) }?.rename(objectID: objectID, to: newName) { error in
            completion(error.map { FileProviderErrors.map($0) })
        }
    }

    func move(objectID: UInt32, toParent newParent: UInt32, completion: @escaping (Error?) -> Void) {
        proxy { completion($0) }?.move(objectID: objectID, toParent: newParent) { error in
            completion(error.map { FileProviderErrors.map($0) })
        }
    }
}
