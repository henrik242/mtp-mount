import Foundation
import os

private let log = Logger(subsystem: "no.synth.mtpmount", category: "agent")

/// Serializes all libmtp work onto one queue (libmtp holds a single stateful USB
/// session) and vends it over XPC. Opens the device lazily and re-opens after any
/// failure so unplug/replug recovers without restarting the agent.
final class AgentService: NSObject, MtpAgentXPC {
    private let queue = DispatchQueue(label: "no.synth.mtpmount.agent.mtp")
    private let session = MtpSession()

    /// Ensure a session is open; on any libmtp failure, drop it so the next call retries.
    private func ensureOpen() throws {
        if session.isOpen { return }
        try session.open()
        log.info("opened device: \(self.session.deviceName() ?? "?", privacy: .public)")
    }

    private func dropSession() {
        session.close()
    }

    func status(reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            do {
                try self.ensureOpen()
                reply(true, self.session.deviceName())
            } catch {
                self.dropSession()
                reply(false, nil)
            }
        }
    }

    func list(parent: UInt32, reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            do {
                try self.ensureOpen()
                let entries = try self.session.list(parent: parent)
                let data = try JSONEncoder().encode(entries)
                reply(data, nil)
            } catch {
                self.dropSession()
                log.error("list(parent: \(parent)) failed: \(String(describing: error), privacy: .public)")
                reply(nil, "\(error)")
            }
        }
    }

    func item(objectID: UInt32, reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            do {
                try self.ensureOpen()
                guard let entry = try self.session.metadata(id: objectID) else {
                    reply(nil, nil)   // no such object
                    return
                }
                reply(try JSONEncoder().encode(entry), nil)
            } catch {
                self.dropSession()
                log.error("item(\(objectID)) failed: \(String(describing: error), privacy: .public)")
                reply(nil, "\(error)")
            }
        }
    }

    func fetch(objectID: UInt32, into destination: FileHandle,
               reply: @escaping (String?) -> Void) {
        queue.async {
            do {
                try self.ensureOpen()
                try self.session.download(id: objectID, toFileDescriptor: destination.fileDescriptor)
                try? destination.close()
                reply(nil)
            } catch {
                try? destination.close()
                self.dropSession()
                log.error("fetch(\(objectID)) failed: \(String(describing: error), privacy: .public)")
                reply("\(error)")
            }
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = AgentService()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        conn.exportedInterface = NSXPCInterface(with: MtpAgentXPC.self)
        conn.exportedObject = service
        conn.resume()
        log.info("accepted XPC connection")
        return true
    }
}

// MARK: - Entry point

MtpSession.initializeLibrary()
log.info("garmin-mtp-agent starting; vending \(MtpAgentConfig.machServiceName, privacy: .public)")

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: MtpAgentConfig.machServiceName)
listener.delegate = delegate
listener.resume()

dispatchMain()
