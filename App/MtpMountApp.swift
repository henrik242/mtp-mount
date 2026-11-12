import SwiftUI

@main
struct MtpMountApp: App {
    @StateObject private var controller = DomainController()

    var body: some Scene {
        WindowGroup("MtpMount") {
            ContentView()
                .environmentObject(controller)
                .frame(minWidth: 460, minHeight: 260)
                .task { await controller.register() }
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @EnvironmentObject var controller: DomainController
    @State private var showTroubleshooting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MtpMount")
                .font(.title2).bold()

            if !controller.isInApplicationsFolder {
                Notice(symbol: "exclamationmark.triangle.fill", tint: .orange,
                       title: "Move MtpMount to Applications",
                       detail: "MtpMount must run from the Applications folder. Quit it, drag it to Applications, and open it from there.")
            }

            if controller.domainRegistered && controller.extensionEnabled == false {
                Notice(symbol: "puzzlepiece.extension.fill", tint: .orange,
                       title: "Turn on the MtpMount extension",
                       detail: "In System Settings → General → Login Items & Extensions, enable MtpMount under File Providers.") {
                    Button("Open System Settings") { controller.openExtensionSettings() }
                }
            }

            deviceRow

            HStack {
                Button("Show in Finder") { Task { await controller.showInFinder() } }
                    .disabled(!controller.domainRegistered)
                Spacer()
            }

            DisclosureGroup("Troubleshooting", isExpanded: $showTroubleshooting) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(controller.agentLoaded ? "Helper is installed" : "Helper is not installed",
                          systemImage: controller.agentLoaded ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("Refresh Finder") { Task { await controller.signalChange() } }
                        Button("Reinstall helper") { Task { await controller.registerAgent(force: true) } }
                        Button("Reset") { Task { await controller.reset() } }
                            .help("Removes and re-adds the Finder location. Downloaded copies are discarded.")
                    }
                    Button("Uninstall…", role: .destructive) { Task { await controller.uninstall() } }
                        .help("Removes the helper and the Finder location so the app can be deleted.")
                }
                .padding(.top, 6)
            }

            if let message = controller.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .task {
            // Keep the device state current while the window is open.
            while !Task.isCancelled {
                await controller.refreshDevice()
                await controller.refreshDomain()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    @ViewBuilder private var deviceRow: some View {
        switch controller.device {
        case .checking:
            Notice(symbol: "ellipsis.circle", tint: .secondary, title: "Checking for a device…", detail: nil)
        case .connected(let name):
            Notice(symbol: "checkmark.circle.fill", tint: .green, title: "Connected: \(name)",
                   detail: "Browse it in Finder's sidebar under Locations, or with “Show in Finder”.")
        case .noDevice:
            Notice(symbol: "cable.connector", tint: .secondary, title: "No device connected",
                   detail: "Connect an MTP device (phone, camera, GPS, music player…) with a USB data cable and unlock it. On a phone, choose “File transfer” in the USB notification.")
        case .busy(let message):
            Notice(symbol: "hand.raised.fill", tint: .orange, title: "Device is in use by another app",
                   detail: message.isEmpty
                       ? "Quit Image Capture, Android File Transfer, OpenMTP or the device maker's sync app, then reconnect."
                       : message)
        case .agentUnavailable:
            Notice(symbol: "exclamationmark.octagon.fill", tint: .red, title: "The MtpMount helper isn't running",
                   detail: "Open Troubleshooting and choose “Reinstall helper”.")
        case .error(let message):
            Notice(symbol: "exclamationmark.triangle.fill", tint: .red, title: "Device error", detail: message)
        }
    }
}

/// A status line: icon, title and an optional explanation/next step, read by
/// VoiceOver as one element.
private struct Notice<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String?
    @ViewBuilder var actions: () -> Actions

    init(symbol: String, tint: Color, title: String, detail: String?,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.detail = detail
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).bold()
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private extension Notice where Actions == EmptyView {
    init(symbol: String, tint: Color, title: String, detail: String?) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail) { EmptyView() }
    }
}
