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

    private static func err(_ message: String) -> NSError {
        NSError(domain: "no.synth.mtpmount.agent", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
