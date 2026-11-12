// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Asks the helper agent which devices are attached, over XPC (the app is not
/// sandboxed, so it can look up the agent's mach service directly).
final class AgentStatusClient {
    private var connection: NSXPCConnection?

    private func currentConnection() -> NSXPCConnection {
        if let connection { return connection }
        let c = NSXPCConnection(machServiceName: MtpAgentConfig.machServiceName, options: [])
        c.remoteObjectInterface = NSXPCInterface(with: MtpAgentXPC.self)
        c.setCodeSigningRequirement(MtpAgentConfig.agentRequirement)
        c.invalidationHandler = { [weak self, weak c] in
            DispatchQueue.main.async { if self?.connection === c { self?.connection = nil } }
        }
        c.resume()
        connection = c
        return c
    }

    /// The agent's view of attached devices, or the XPC error if it can't be reached.
    @MainActor
    func overview() async -> Result<AgentOverview, Error> {
        let connection = currentConnection()
        return await withCheckedContinuation { continuation in
            // NSXPC calls exactly one of the error handler or the reply.
            let proxy = connection.remoteObjectProxyWithErrorHandler {
                continuation.resume(returning: .failure($0))
            }
            guard let agent = proxy as? MtpAgentXPC else {
                continuation.resume(returning: .failure(CocoaError(.xpcConnectionInvalid)))
                return
            }
            agent.overview { data in
                do {
                    continuation.resume(returning: .success(
                        try JSONDecoder().decode(AgentOverview.self, from: data ?? Data())))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }
}
