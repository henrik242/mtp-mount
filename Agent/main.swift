import FileProvider
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
log.info("mtpmount-agent starting; vending \(MtpAgentConfig.machServiceName, privacy: .public)")

let service = AgentService(device: MtpSession())

// When the device session changes (opened, replugged, lost), the sync anchor
// changes; tell the system to ask the extension for changes so Finder catches
// up without waiting for the user to touch the folder.
service.onSessionChange = { status in
    log.info("session changed: connected=\(status.connected) \(status.deviceName ?? "", privacy: .public)")
    guard let manager = NSFileProviderManager(for: FP.domain) else {
        log.error("no File Provider manager for the domain; is it registered?")
        return
    }
    manager.signalEnumerator(for: .workingSet) { error in
        if let error { log.error("signalEnumerator failed: \(error.localizedDescription, privacy: .public)") }
    }
}

// Notice plug/unplug as it happens instead of on the next failing request.
let usbMonitor = UsbMonitor { service.usbDevicesChanged() }
usbMonitor.start()
service.usbDevicesChanged()   // open a device that's already attached
let delegate = ListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: MtpAgentConfig.machServiceName)
// Reject any peer that isn't our team-signed extension or app before the
// delegate ever sees it.
listener.setConnectionCodeSigningRequirement(MtpAgentConfig.clientRequirement)
listener.delegate = delegate
listener.resume()

dispatchMain()
