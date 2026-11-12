import AppKit
import FileProvider
import os

private let log = Logger(subsystem: MtpAgentConfig.logSubsystem, category: "app")

/// What the user should know about the device right now.
enum DeviceState: Equatable {
    case checking
    case connected(name: String)
    case noDevice
    case busy(message: String)
    case agentUnavailable
    case error(message: String)
}

/// Registers the File Provider domain and the helper agent, and tracks the
/// state the window shows.
@MainActor
final class DomainController: ObservableObject {
    @Published private(set) var device: DeviceState = .checking
    @Published private(set) var domainRegistered = false
    /// nil until known; false means the user hasn't enabled the extension yet.
    @Published private(set) var extensionEnabled: Bool?
    @Published private(set) var agentLoaded = false
    /// Last result of a troubleshooting action.
    @Published var message: String?

    private let statusClient = AgentStatusClient()
    private var lastSessionID: String?

    /// Where the app runs from. Outside /Applications (e.g. straight from the
    /// DMG, or translocated by Gatekeeper) the helper path would go stale.
    var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundlePath
        return (path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/"))
            && !path.contains("/AppTranslocation/")
    }

    // MARK: - Helper agent (launchd)

    /// Path to the embedded libmtp helper executable.
    private var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(MtpAgentConfig.agentExecutable)")
    }

    /// The per-user LaunchAgent plist we install for the helper.
    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(MtpAgentConfig.agentLabel).plist")
    }

    private var launchdTarget: String { "gui/\(getuid())/\(MtpAgentConfig.agentLabel)" }

    /// The LaunchAgent plist for the helper at its current location.
    private func launchAgentPlist() throws -> Data {
        let plist: [String: Any] = [
            "Label": MtpAgentConfig.agentLabel,
            "ProgramArguments": [helperURL.path],
            "MachServices": [MtpAgentConfig.machServiceName: true],
            "RunAtLoad": false,
            "ProcessType": "Adaptive",
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Install the helper as a launchd agent the classic way: write a per-user
    /// LaunchAgent plist and bootstrap it. launchd starts it on demand via its
    /// mach service. (SMAppService's BTM path refuses a non-sandboxed helper
    /// here, so we drive launchd directly — the app is non-sandboxed.)
    ///
    /// Idempotent: if the installed plist already points at this app's helper
    /// and the job is loaded, nothing happens — so a running agent (and any
    /// transfer in flight) is left alone. `force` reinstalls unconditionally.
    func registerAgent(force: Bool = false) async {
        let data: Data
        do {
            data = try launchAgentPlist()
        } catch {
            log.error("encoding LaunchAgent plist failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let upToDate = (try? Data(contentsOf: launchAgentURL)) == data
        let loaded = await Self.launchctl(["print", launchdTarget]).0 == 0
        if upToDate && loaded && !force {
            agentLoaded = true
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: launchAgentURL)
        } catch {
            log.error("writing LaunchAgent plist failed: \(error.localizedDescription, privacy: .public)")
            message = "Couldn't install the helper: \(error.localizedDescription)"
            await refreshAgentStatus()
            return
        }
        // Only now (plist changed, e.g. the app moved, or forced) restart the job.
        if loaded { _ = await Self.launchctl(["bootout", launchdTarget]) }
        let (code, out) = await Self.launchctl(["bootstrap", "gui/\(getuid())", launchAgentURL.path])
        log.info("agent bootstrap exit=\(code) \(out, privacy: .public)")
        await refreshAgentStatus()
    }

    func unregisterAgent() async {
        _ = await Self.launchctl(["bootout", launchdTarget])
        try? FileManager.default.removeItem(at: launchAgentURL)
        await refreshAgentStatus()
    }

    func refreshAgentStatus() async {
        agentLoaded = await Self.launchctl(["print", launchdTarget]).0 == 0
    }

    /// Run /bin/launchctl off the main actor and return (exitCode, combinedOutput).
    private nonisolated static func launchctl(_ args: [String]) async -> (Int32, String) {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do {
                try p.run()
                // Drain before waiting: a full pipe would block launchctl forever.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
            } catch {
                return (-1, "launchctl failed: \(error.localizedDescription)")
            }
        }.value
    }

    // MARK: - Domain

    /// Make sure the helper and the domain exist. Safe to call on every launch:
    /// an existing domain (and its downloaded files / pending uploads) is kept.
    func register() async {
        await registerAgent()
        do {
            // Drop domains from older versions (e.g. the former device-specific
            // "GarminEdge" domain) so only the current one shows in Finder.
            for stale in try await NSFileProviderManager.domains() where stale.identifier != FP.domainIdentifier {
                log.info("register: removing old domain \(stale.identifier.rawValue, privacy: .public)")
                try await NSFileProviderManager.remove(stale)
            }
            if try await currentDomain() == nil {
                log.info("register: adding domain")
                try await NSFileProviderManager.add(FP.domain)
            }
        } catch {
            log.error("register failed: \(error.localizedDescription, privacy: .public)")
            message = "Couldn't register the File Provider: \(error.localizedDescription)"
        }
        await refreshDomain()
    }

    private func currentDomain() async throws -> NSFileProviderDomain? {
        try await NSFileProviderManager.domains().first { $0.identifier == FP.domainIdentifier }
    }

    func refreshDomain() async {
        let domain = try? await currentDomain()
        domainRegistered = domain != nil
        extensionEnabled = domain.map(\.userEnabled)
    }

    /// Troubleshooting: purge every domain of this provider (including stale
    /// state from older registrations), reinstall the helper and re-add.
    func reset() async {
        do {
            try await NSFileProviderManager.removeAllDomains()
        } catch {
            log.error("removeAllDomains failed: \(error.localizedDescription, privacy: .public)")
        }
        await registerAgent(force: true)
        await register()
        message = "Reset done."
    }

    /// Ask the system to re-enumerate so device changes show up.
    func signalChange() async {
        guard let manager = NSFileProviderManager(for: FP.domain) else { return }
        do {
            try await manager.signalEnumerator(for: .workingSet)
        } catch {
            log.error("signalEnumerator failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Remove everything the app installed outside its bundle, so it can be
    /// dragged to the Trash cleanly.
    func uninstall() async {
        do {
            try await NSFileProviderManager.removeAllDomains()
        } catch {
            log.error("removeAllDomains failed: \(error.localizedDescription, privacy: .public)")
        }
        await unregisterAgent()
        await refreshDomain()
        message = "Uninstalled the helper and the Finder location. You can now move MtpMount to the Trash."
    }

    // MARK: - Device

    /// Poll the agent for the device state; signal the system when the device
    /// session changed (replug, another device) so Finder catches up.
    func refreshDevice() async {
        switch await statusClient.status() {
        case .failure:
            device = .agentUnavailable
        case .success(let status):
            if status.connected {
                device = .connected(name: status.deviceName ?? "MTP device")
            } else {
                switch status.failure {
                case .deviceBusy?: device = .busy(message: status.message ?? "")
                case .noDevice?, nil: device = .noDevice
                default: device = .error(message: status.message ?? "Unknown error")
                }
            }
            if status.sessionID != lastSessionID {
                if lastSessionID != nil { await signalChange() }
                lastSessionID = status.sessionID
            }
        }
    }

    // MARK: - Shortcuts

    /// Open the device's folder in Finder.
    func showInFinder() async {
        guard let manager = NSFileProviderManager(for: FP.domain),
              let url = try? await manager.getUserVisibleURL(for: .rootContainer) else {
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/CloudStorage"))
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openExtensionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
