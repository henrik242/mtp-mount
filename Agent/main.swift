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
service.onChange = { status in
    log.info("device changed: connected=\(status.connected) \(status.deviceName ?? "", privacy: .public) seq \(status.changeSeq)")
    guard let manager = NSFileProviderManager(for: FP.domain) else {
        log.error("no File Provider manager for the domain; is it registered?")
        return
    }
    manager.signalEnumerator(for: .workingSet) { error in
        if let error { log.error("signalEnumerator failed: \(error.localizedDescription, privacy: .public)") }
    }
}

// A device handle that couldn't be released safely is abandoned; only a fresh
// process can open the device again. launchd restarts us on the next request.
service.onUnsafeClose = {
    log.error("exiting so launchd can restart the agent with a clean USB state")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
}

// Pick up changes the device reports while connected (e.g. a new photo).
service.startEventPolling()

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
