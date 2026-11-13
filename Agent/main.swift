// SPDX-License-Identifier: GPL-2.0-or-later
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

// MARK: - File Provider domains

/// Keeps each device's File Provider domain in step with the agent: creates
/// the domain of a newly seen device and signals it when its contents may
/// have changed. Creating a domain from this helper may be refused by the
/// system; then the app is launched in the background to do it.
enum Domains {
    private static var appLaunchPending = false

    static func handle(_ change: AgentService.DeviceChange) {
        switch change {
        case .opened(let status):
            log.info("device opened: \(status.name, privacy: .public) (\(status.key, privacy: .public))")
            ensureDomain(status)
        case .changed(let status):
            signal(status.key)
        case .lost(let key, let error):
            log.info("device lost: \(key, privacy: .public) (\(error.rawValue))")
            signal(key)
        }
    }

    private static func ensureDomain(_ status: DeviceStatus) {
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
            if domains.contains(where: { $0.identifier.rawValue == status.key }) {
                signal(status.key)
                return
            }
            NSFileProviderManager.add(FP.domain(forDevice: status.key, name: status.name)) { error in
                if let error {
                    log.notice("adding domain from the helper failed (\(error.localizedDescription, privacy: .public)); asking the app")
                    launchAppToSyncDomains()
                } else {
                    log.info("added domain \(status.key, privacy: .public)")
                }
            }
        }
    }

    private static func signal(_ key: String) {
        FP.manager(forDevice: key)?.signalEnumerator(for: .workingSet) { error in
            if let error {
                log.debug("signalEnumerator(\(key, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Open the containing app hidden and in the background; it adds domains
    /// for all attached devices and quits.
    private static func launchAppToSyncDomains() {
        DispatchQueue.main.async {
            guard !appLaunchPending, let app = containingApp() else { return }
            appLaunchPending = true
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", "-j", "-a", app.path, "--args", MtpAgentConfig.syncDomainsArgument]
            do { try open.run() } catch {
                log.error("launching the app failed: \(error.localizedDescription, privacy: .public)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { appLaunchPending = false }
        }
    }

    /// The .app bundle this helper lives in (…/MtpMount.app/Contents/MacOS/agent).
    private static func containingApp() -> URL? {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }
}

// MARK: - Entry point

// Our own PTP/MTP implementation over IOUSBHost.
log.info("mtpmount-agent starting; vending \(MtpAgentConfig.machServiceName, privacy: .public)")

let bus: MtpBus = NativeMtpBus()
let service = AgentService(bus: bus)

// Device opened / changed on the device / lost: keep its domain and Finder in step.
service.onChange = { Domains.handle($0) }

// A device handle that couldn't be released safely is abandoned; only a fresh
// process can open the device again. launchd restarts us on the next request.
service.onUnsafeClose = {
    log.error("exiting so launchd can restart the agent with a clean USB state")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
}

// Pick up changes devices report while connected (e.g. a new photo).
service.startEventPolling()

// Notice plug/unplug as it happens instead of on the next failing request.
let usbMonitor = UsbMonitor { service.usbDevicesChanged() }
usbMonitor.start()
service.usbDevicesChanged()   // open devices that are already attached

let delegate = ListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: MtpAgentConfig.machServiceName)
// Reject any peer that isn't our team-signed extension or app before the
// delegate ever sees it.
listener.setConnectionCodeSigningRequirement(MtpAgentConfig.clientRequirement)
listener.delegate = delegate
listener.resume()

dispatchMain()
