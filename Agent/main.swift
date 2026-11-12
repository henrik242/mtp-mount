import Foundation
import os

private let log = Logger(subsystem: MtpAgentConfig.logSubsystem, category: "agent")

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: AgentService

    init(service: AgentService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        conn.exportedInterface = NSXPCInterface(with: MtpAgentXPC.self)
        conn.exportedObject = service
        conn.resume()
        log.info("accepted XPC connection from pid \(conn.processIdentifier)")
        return true
    }
}

// MARK: - Entry point

MtpSession.initializeLibrary()
log.info("garmin-mtp-agent starting; vending \(MtpAgentConfig.machServiceName, privacy: .public)")

let service = AgentService(device: MtpSession())
let delegate = ListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: MtpAgentConfig.machServiceName)
// Reject any peer that isn't our team-signed extension or app before the
// delegate ever sees it.
listener.setConnectionCodeSigningRequirement(MtpAgentConfig.clientRequirement)
listener.delegate = delegate
listener.resume()

dispatchMain()
