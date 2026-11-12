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
                .task { controller.register() }
        }
        .windowResizability(.contentSize)
    }
}

/// Registers / removes the File Provider domain with the system.
@MainActor
final class DomainController: ObservableObject {
    @Published var status: String = "Not registered"
    @Published var agentStatus: String = "Agent: unknown"
    @Published var cloudStoragePath: String = ""

    init() {
        refreshStatus()
        refreshAgentStatus()
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

    /// Install the helper as a launchd agent the classic way: write a per-user
    /// LaunchAgent plist and (re)bootstrap it. Run on-demand via its mach service.
    /// (SMAppService's BTM path refuses a non-sandboxed helper here, so we drive
    /// launchd directly — the app is non-sandboxed, so this is permitted.)
    func registerAgent() {
        let plist: [String: Any] = [
            "Label": MtpAgentConfig.agentLabel,
            "ProgramArguments": [helperURL.path],
            "MachServices": [MtpAgentConfig.machServiceName: true],
            "RunAtLoad": false,
            "ProcessType": "Adaptive",
        ]
        do {
            try FileManager.default.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: launchAgentURL)
        } catch {
            log.error("writing LaunchAgent plist failed: \(error.localizedDescription, privacy: .public)")
            refreshAgentStatus()
            return
        }
        let domain = "gui/\(getuid())"
        _ = Self.launchctl(["bootout", "\(domain)/\(MtpAgentConfig.agentLabel)"])
        let (code, out) = Self.launchctl(["bootstrap", domain, launchAgentURL.path])
        log.info("agent bootstrap exit=\(code) \(out, privacy: .public)")
        refreshAgentStatus()
    }

    func unregisterAgent() {
        _ = Self.launchctl(["bootout", "gui/\(getuid())/\(MtpAgentConfig.agentLabel)"])
        try? FileManager.default.removeItem(at: launchAgentURL)
        refreshAgentStatus()
    }

    func refreshAgentStatus() {
        let (code, _) = Self.launchctl(["print", "gui/\(getuid())/\(MtpAgentConfig.agentLabel)"])
        let installed = FileManager.default.fileExists(atPath: launchAgentURL.path)
        let text = code == 0 ? "Agent: registered ✓"
            : (installed ? "Agent: installed (not loaded)" : "Agent: not registered")
        Task { @MainActor in self.agentStatus = text }
    }

    /// Run /bin/launchctl and return (exitCode, combinedOutput).
    @discardableResult
    private static func launchctl(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "launchctl failed: \(error.localizedDescription)")
        }
    }

    func register() {
        // Make sure the helper is registered before we add the domain.
        registerAgent()

        let domain = NSFileProviderDomain(
            identifier: FP.domainIdentifier,
            displayName: FP.domainDisplayName
        )
        // Purge ALL domains for this provider first (clears any stale V2/non-replicated
        // state left over from earlier registrations), then add the replicated domain.
        log.info("register: removeAllDomains")
        NSFileProviderManager.removeAllDomains { removeErr in
            log.info("register: removeAllDomains err=\(String(describing: removeErr), privacy: .public)")
            NSFileProviderManager.add(domain) { [weak self] error in
                log.info("register: add result err=\(String(describing: error), privacy: .public)")
                Task { @MainActor in
                    if let error {
                        self?.status = "Register failed: \(error.localizedDescription)"
                    } else {
                        self?.status = "Registered ✓"
                        self?.refreshStatus()
                    }
                }
            }
        }
    }

    func remove() {
        let domain = NSFileProviderDomain(
            identifier: FP.domainIdentifier,
            displayName: FP.domainDisplayName
        )
        NSFileProviderManager.remove(domain) { [weak self] error in
            Task { @MainActor in
                self?.status = error == nil
                    ? "Removed"
                    : "Remove failed: \(error!.localizedDescription)"
            }
        }
    }

    /// Ask the system to re-enumerate so content changes show up.
    func signalChange() {
        guard let mgr = NSFileProviderManager(for: NSFileProviderDomain(
            identifier: FP.domainIdentifier,
            displayName: FP.domainDisplayName
        )) else {
            status = "No manager for domain"
            return
        }
        mgr.signalEnumerator(for: .workingSet) { _ in }
        mgr.signalEnumerator(for: .rootContainer) { [weak self] error in
            Task { @MainActor in
                self?.status = error == nil ? "Signalled re-enumeration" : "Signal failed: \(error!.localizedDescription)"
            }
        }
    }

    func refreshStatus() {
        NSFileProviderManager.getDomainsWithCompletionHandler { [weak self] domains, _ in
            let found = domains.contains { $0.identifier == FP.domainIdentifier }
            Task { @MainActor in
                if found { self?.status = "Registered ✓" }
                let base = ("~/Library/CloudStorage" as NSString).expandingTildeInPath
                self?.cloudStoragePath = base
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
            Text("Phase 1 — live device over libmtp + XPC (read-only)")
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
                Button("Register") { controller.register() }
                Button("Remove domain") { controller.remove() }
                Button("Signal re-enumerate") { controller.signalChange() }
            }
            HStack(spacing: 12) {
                Button("Register agent") { controller.registerAgent() }
                Button("Unregister agent") { controller.unregisterAgent() }
                Button("Refresh") { controller.refreshStatus(); controller.refreshAgentStatus() }
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
