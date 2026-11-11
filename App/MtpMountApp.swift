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
    @Published var cloudStoragePath: String = ""

    init() {
        refreshStatus()
    }

    func register() {
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
            Text("Phase 0 — static test tree (no device yet)")
                .foregroundStyle(.secondary)

            HStack {
                Text("Status:")
                Text(controller.status)
                    .bold()
            }

            HStack(spacing: 12) {
                Button("Register domain") { controller.register() }
                Button("Remove domain") { controller.remove() }
                Button("Signal re-enumerate") { controller.signalChange() }
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
