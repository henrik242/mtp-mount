import Foundation
import os

/// Thin XPC client the extension uses to reach the non-sandboxed libmtp agent.
/// The connection is lazy and self-healing: launchd starts the agent on demand
/// when we look up its mach service, and we rebuild the connection if it drops.
final class AgentClient {
    static let shared = AgentClient()

    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private func proxy(_ onError: @escaping (Error) -> Void) -> MtpAgentXPC? {
        lock.lock()
        if connection == nil {
            let c = NSXPCConnection(machServiceName: MtpAgentConfig.machServiceName, options: [])
            c.remoteObjectInterface = NSXPCInterface(with: MtpAgentXPC.self)
            // Only talk to an agent signed by our team (the mach name alone
            // could be squatted by another process in the user's session).
            c.setCodeSigningRequirement(MtpAgentConfig.agentRequirement)
            c.invalidationHandler = { [weak self] in self?.clear() }
            c.interruptionHandler = { [weak self] in self?.clear() }
            c.resume()
            connection = c
        }
        let conn = connection
        lock.unlock()
        return conn?.remoteObjectProxyWithErrorHandler(onError) as? MtpAgentXPC
    }

    private func clear() {
        lock.lock()
        connection = nil
        lock.unlock()
    }

    // MARK: - Calls

    func list(parent: UInt32, completion: @escaping (Result<[MtpEntry], Error>) -> Void) {
        guard let p = proxy({ completion(.failure($0)) }) else {
            completion(.failure(Self.err("no connection"))); return
        }
        p.list(parent: parent) { data, errMsg in
            if let errMsg { completion(.failure(Self.err(errMsg))); return }
            do {
                completion(.success(try JSONDecoder().decode([MtpEntry].self, from: data ?? Data())))
            } catch { completion(.failure(error)) }
        }
    }

    /// nil entry means the object no longer exists on the device.
    func item(objectID: UInt32, completion: @escaping (Result<MtpEntry?, Error>) -> Void) {
        guard let p = proxy({ completion(.failure($0)) }) else {
            completion(.failure(Self.err("no connection"))); return
        }
        p.item(objectID: objectID) { data, errMsg in
            if let errMsg { completion(.failure(Self.err(errMsg))); return }
            guard let data else { completion(.success(nil)); return }
            do {
                completion(.success(try JSONDecoder().decode(MtpEntry.self, from: data)))
            } catch { completion(.failure(error)) }
        }
    }

    /// Download `objectID` into a fresh temp file (owned by the extension) and
    /// return its URL. The extension passes the open fd to the agent over XPC.
    func fetch(objectID: UInt32, completion: @escaping (Result<URL, Error>) -> Void) {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtp-\(objectID)-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: dest.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: dest) else {
            completion(.failure(Self.err("could not create temp file"))); return
        }
        guard let p = proxy({ try? handle.close(); completion(.failure($0)) }) else {
            try? handle.close(); completion(.failure(Self.err("no connection"))); return
        }
        p.fetch(objectID: objectID, into: handle) { errMsg in
            try? handle.close()
            if let errMsg {
                try? FileManager.default.removeItem(at: dest)
                completion(.failure(Self.err(errMsg)))
            } else {
                completion(.success(dest))
            }
        }
    }

    // MARK: - Writes

    /// Upload a local file as a new object under `parent`. Returns the new MTP id.
    func upload(parent: UInt32, name: String, source: URL,
                completion: @escaping (Result<UInt32, Error>) -> Void) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs?[.size] as? UInt64) ?? 0
        guard let handle = try? FileHandle(forReadingFrom: source) else {
            completion(.failure(Self.err("cannot open source file"))); return
        }
        guard let p = proxy({ try? handle.close(); completion(.failure($0)) }) else {
            try? handle.close(); completion(.failure(Self.err("no connection"))); return
        }
        p.upload(parent: parent, name: name, size: size, from: handle) { newID, errMsg in
            try? handle.close()
            if let errMsg { completion(.failure(Self.err(errMsg))) }
            else { completion(.success(newID)) }
        }
    }

    func createFolder(parent: UInt32, name: String,
                      completion: @escaping (Result<UInt32, Error>) -> Void) {
        guard let p = proxy({ completion(.failure($0)) }) else {
            completion(.failure(Self.err("no connection"))); return
        }
        p.createFolder(parent: parent, name: name) { newID, errMsg in
            if let errMsg { completion(.failure(Self.err(errMsg))) }
            else { completion(.success(newID)) }
        }
    }

    func delete(objectID: UInt32, completion: @escaping (Error?) -> Void) {
        guard let p = proxy({ completion($0) }) else { completion(Self.err("no connection")); return }
        p.delete(objectID: objectID) { errMsg in
            completion(errMsg.map { Self.err($0) })
        }
    }

    func rename(objectID: UInt32, to newName: String, completion: @escaping (Error?) -> Void) {
        guard let p = proxy({ completion($0) }) else { completion(Self.err("no connection")); return }
        p.rename(objectID: objectID, to: newName) { errMsg in
            completion(errMsg.map { Self.err($0) })
        }
    }

    func move(objectID: UInt32, toParent newParent: UInt32, completion: @escaping (Error?) -> Void) {
        guard let p = proxy({ completion($0) }) else { completion(Self.err("no connection")); return }
        p.move(objectID: objectID, toParent: newParent) { errMsg in
            completion(errMsg.map { Self.err($0) })
        }
    }

    private static func err(_ message: String) -> NSError {
        NSError(domain: "no.synth.mtpmount.agent", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
