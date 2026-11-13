// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import FileProvider
import os

private let log = Logger(subsystem: MtpAgentConfig.logSubsystem, category: "app")

/// A device as the window shows it. A location exists only while its device is
/// attached, so a row is normally connected.
struct DeviceRow: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let name: String
    let connected: Bool
    /// The user hasn't enabled this location in System Settings yet.
    let needsEnabling: Bool
}

/// What's wrong when no device can be shown, if anything.
enum AgentProblem: Equatable {
    case none
    case agentUnavailable
    case busy(message: String)
    case error(message: String)
}

/// Installs the helper agent, keeps one File Provider domain per device, and
/// tracks the state the window shows.
@MainActor
final class DomainController: ObservableObject {
    @Published private(set) var rows: [DeviceRow] = []
    @Published private(set) var problem: AgentProblem = .none
    /// Attached cameras MtpMount leaves to Image Capture / Photos.
    @Published private(set) var ignoredDevices: [String] = []
    @Published private(set) var checked = false
    @Published private(set) var agentLoaded = false

    /// Last result of a troubleshooting action.
    @Published var message: String?

    /// Something the menu bar icon should badge: setup needed or a device error.
    var needsAttention: Bool {
        problem != .none || rows.contains(where: \.needsEnabling) || !isInApplicationsFolder
    }

    private let statusClient = AgentStatusClient()
    /// Session per device last time we looked, to signal domains on changes.
    private var lastSessions: [String: String] = [:]
    /// When each domain first reported itself not-enabled. A freshly (re-)added
    /// domain can say so for a second before the system settles, so we only act
    /// on it once it has stayed that way past `enableGrace` -- otherwise a
    /// replug would flash the "turn on the extension" notice.
    private var notEnabledSince: [String: Date] = [:]
    private let enableGrace: TimeInterval = 6

    /// Where the app runs from. Outside /Applications (e.g. straight from the
    /// DMG, or translocated by Gatekeeper) the helper path would go stale.
    var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundlePath
        return (path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/"))
            && !path.contains("/AppTranslocation/")
    }

    // MARK: - Helper agent (launchd)

    /// Path to the embedded helper executable.
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
            // Link the helper to the app so System Settings' "Allow in the
            // Background" lists it under the app's name and icon, not a bare
            // developer entry.
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "no.synth.mtpmount"],
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

    // MARK: - Domains

    /// Install the helper and bring the domains up to date: a location for each
    /// attached device, and none for devices that are gone. Downloaded files and
    /// pending uploads of a still-attached device are kept.
    func register() async {
        await registerAgent()
        await refresh()
    }

    /// Ask the agent which devices are attached, add a domain for each new
    /// one, remove domains of older versions, and update the window's rows.
    /// Guards against overlapping refreshes: several surfaces (menu bar label,
    /// popover, window) drive this on their own schedules.
    private var refreshing = false
    /// Set once we've reinstalled a stale helper, so we don't loop if the
    /// on-disk helper somehow stays out of date.
    private var staleHelperHandled = false

    func refresh() async {
        if refreshing { return }
        refreshing = true
        defer { refreshing = false }
        let overview = await statusClient.overview()
        var domains = (try? await NSFileProviderManager.domains()) ?? []

        for stale in domains where FP.legacyDomainIdentifiers.contains(stale.identifier.rawValue) {
            log.info("removing old domain \(stale.identifier.rawValue, privacy: .public)")
            try? await NSFileProviderManager.remove(stale)
        }
        domains.removeAll { FP.legacyDomainIdentifiers.contains($0.identifier.rawValue) }

        let attached: [DeviceStatus]
        let agentResponsive: Bool
        var runningAgentVersion = ""
        switch overview {
        case .failure:
            attached = []
            agentResponsive = false
            ignoredDevices = []
            problem = .agentUnavailable
        case .success(let o):
            attached = o.devices
            agentResponsive = true
            runningAgentVersion = o.agentVersion
            ignoredDevices = o.ignoredDevices
            switch o.problem {
            case .deviceBusy?: problem = .busy(message: o.message ?? "")
            case nil, .noDevice?: problem = .none
            default: problem = .error(message: o.message ?? "Unknown error")
            }
        }

        // A stale helper (an old binary still bootstrapped after an app update)
        // reports a different version than the app. Reinstall it once to load
        // the new binary; the next refresh then sees a matching version.
        if agentResponsive, !staleHelperHandled,
           !runningAgentVersion.isEmpty, runningAgentVersion != MtpAgentConfig.bundleVersion {
            staleHelperHandled = true
            log.info("helper is version \(runningAgentVersion, privacy: .public) but app is \(MtpAgentConfig.bundleVersion, privacy: .public); reinstalling the helper")
            await registerAgent(force: true)
            return
        }

        for device in attached where !domains.contains(where: { $0.identifier.rawValue == device.key }) {
            do {
                log.info("adding domain for \(device.name, privacy: .public)")
                let domain = FP.domain(forDevice: device.key, name: device.name)
                try await NSFileProviderManager.add(domain)
                domains.append(domain)
            } catch {
                message = "Couldn't add “\(device.name)” to Finder: \(error.localizedDescription)"
            }
        }

        // A disconnected device's location is removed (the agent does this in
        // real time; this reconciles the case where it was unplugged while the
        // app was closed, or the helper's own removal was refused). Only when
        // the helper answered -- an unavailable helper doesn't mean every
        // device is gone.
        if agentResponsive {
            let attachedKeys = Set(attached.map(\.key))
            for domain in domains where FP.deviceKey(of: domain) != nil && !attachedKeys.contains(domain.identifier.rawValue) {
                log.info("removing location for detached device \(domain.identifier.rawValue, privacy: .public)")
                try? await NSFileProviderManager.remove(domain)
            }
            domains.removeAll { FP.deviceKey(of: $0) != nil && !attachedKeys.contains($0.identifier.rawValue) }
        }

        // Signal domains whose device session changed (attached, replugged,
        // lost) so Finder catches up, as a backup to the agent's own signal.
        let sessions = Dictionary(attached.map { ($0.key, $0.sessionID) }, uniquingKeysWith: { a, _ in a })
        if checked {
            for key in Set(sessions.keys).union(lastSessions.keys) where sessions[key] != lastSessions[key] {
                try? await FP.manager(forDevice: key)?.signalEnumerator(for: .workingSet)
            }
        }
        lastSessions = sessions

        let now = Date()
        var stillNotEnabled: [String: Date] = [:]
        rows = domains.compactMap { domain -> DeviceRow? in
            guard let key = FP.deviceKey(of: domain) else { return nil }
            // Hold off on "needs enabling" until a not-enabled domain has stayed
            // that way past the grace period, so a just-added one doesn't flash.
            var needsEnabling = false
            if !domain.userEnabled {
                let since = notEnabledSince[key] ?? now
                stillNotEnabled[key] = since
                needsEnabling = now.timeIntervalSince(since) >= enableGrace
            }
            return DeviceRow(key: key,
                             name: attached.first { $0.key == key }?.name ?? domain.displayName,
                             connected: sessions[key] != nil,
                             needsEnabling: needsEnabling)
        }.sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
        notEnabledSince = stillNotEnabled
        checked = true
    }

    /// Troubleshooting: purge every domain of this provider, reinstall the
    /// helper and re-add domains for the attached devices.
    func reset() async {
        do {
            try await NSFileProviderManager.removeAllDomains()
        } catch {
            log.error("removeAllDomains failed: \(error.localizedDescription, privacy: .public)")
        }
        lastSessions = [:]
        await registerAgent(force: true)
        await refresh()
        message = "Reset done."
    }

    /// Ask the system to re-enumerate every device so changes show up.
    func signalAll() async {
        for row in rows {
            try? await FP.manager(forDevice: row.key)?.signalEnumerator(for: .workingSet)
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
        rows = []
        message = "Uninstalled the helper and the Finder locations. You can now move MtpMount to the Trash."
    }

    // MARK: - Shortcuts

    /// Open a device's folder in Finder.
    func showInFinder(_ row: DeviceRow) async {
        guard let manager = FP.manager(forDevice: row.key),
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
