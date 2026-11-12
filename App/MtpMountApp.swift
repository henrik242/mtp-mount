import SwiftUI
import FileProvider
import os

private let log = Logger(subsystem: "no.synth.mtpmount", category: "app")

@main
struct MtpMountApp: App {
    @StateObject private var controller = DomainController()

    var body: some Scene {
        WindowGroup("Garmin MTP Mount") {
            ContentView()
                .environmentObject(controller)
                .frame(minWidth: 420, minHeight: 240)
                .task { await controller.register() }
        }
        .windowResizability(.contentSize)
    }
}

/// Registers / removes the File Provider domain with the system.
@MainActor
final class DomainController: ObservableObject {
    @Published var status: String = "Not registered"
    @Published var agentStatus: String = "Agent: unknown"

    init() {
        Task { await refreshAgentStatus() }
        refreshStatus()
    }

    /// Path to the embedded libmtp helper executable.
    private var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/garmin-mtp-agent")
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
            await refreshAgentStatus()
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: launchAgentURL)
        } catch {
            log.error("writing LaunchAgent plist failed: \(error.localizedDescription, privacy: .public)")
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
        let (code, _) = await Self.launchctl(["print", launchdTarget])
        let installed = FileManager.default.fileExists(atPath: launchAgentURL.path)
        agentStatus = code == 0 ? "Agent: registered ✓"
            : (installed ? "Agent: installed (not loaded)" : "Agent: not registered")
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

    /// Make sure the helper and the domain exist. Safe to call on every launch:
    /// an existing domain (and its downloaded files / pending uploads) is kept.
    func register() async {
        await registerAgent()
        do {
            let domains = try await NSFileProviderManager.domains()
            if domains.contains(where: { $0.identifier == FP.domainIdentifier }) {
                status = "Registered ✓"
                return
            }
            log.info("register: adding domain")
            try await NSFileProviderManager.add(FP.domain)
            status = "Registered ✓"
        } catch {
            log.error("register failed: \(error.localizedDescription, privacy: .public)")
            status = "Register failed: \(error.localizedDescription)"
        }
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
    }

    func remove() async {
        do {
            try await NSFileProviderManager.remove(FP.domain)
            status = "Removed"
        } catch {
            status = "Remove failed: \(error.localizedDescription)"
        }
    }

    /// Ask the system to re-enumerate so content changes show up.
    func signalChange() async {
        guard let mgr = NSFileProviderManager(for: FP.domain) else {
            status = "No manager for domain"
            return
        }
        do {
            try await mgr.signalEnumerator(for: .workingSet)
            status = "Signalled re-enumeration"
        } catch {
            status = "Signal failed: \(error.localizedDescription)"
        }
    }

    func refreshStatus() {
        Task {
            let domains = (try? await NSFileProviderManager.domains()) ?? []
            if domains.contains(where: { $0.identifier == FP.domainIdentifier }) {
                status = "Registered ✓"
            }
        }
    }

    func openCloudStorage() {
        let base = ("~/Library/CloudStorage" as NSString).expandingTildeInPath
        NSWorkspace.shared.open(URL(fileURLWithPath: base))
    }
}

struct ContentView: View {
    @EnvironmentObject var controller: DomainController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Garmin MTP Mount")
                .font(.title2).bold()
            Text("Live device over libmtp + XPC (read/write)")
                .foregroundStyle(.secondary)

            HStack {
                Text("Status:")
                Text(controller.status)
                    .bold()
            }
            Text(controller.agentStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Register") { Task { await controller.register() } }
                Button("Reset domain") { Task { await controller.reset() } }
                Button("Remove domain") { Task { await controller.remove() } }
                Button("Signal re-enumerate") { Task { await controller.signalChange() } }
            }
            HStack(spacing: 12) {
                Button("Reinstall agent") { Task { await controller.registerAgent(force: true) } }
                Button("Unregister agent") { Task { await controller.unregisterAgent() } }
                Button("Refresh") {
                    controller.refreshStatus()
                    Task { await controller.refreshAgentStatus() }
                }
            }

            Divider()

            Button("Open ~/Library/CloudStorage in Finder") {
                controller.openCloudStorage()
            }
            Text("Look for a “Garmin” entry there and in Finder's sidebar.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(20)
    }
}
