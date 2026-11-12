// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI

@main
struct MtpMountApp: App {
    @StateObject private var controller = DomainController()

    var body: some Scene {
        WindowGroup("MtpMount") {
            ContentView()
                .environmentObject(controller)
                .frame(minWidth: 480, minHeight: 280)
                .task {
                    await controller.register()
                    // Launched by the helper just to add a Finder location for a
                    // newly attached device: done, quit again.
                    if CommandLine.arguments.contains(MtpAgentConfig.syncDomainsArgument) {
                        NSApplication.shared.terminate(nil)
                    }
                }
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

            if controller.rows.contains(where: \.needsEnabling) {
                Notice(symbol: "puzzlepiece.extension.fill", tint: .orange,
                       title: "Turn on the MtpMount extension",
                       detail: "In System Settings → General → Login Items & Extensions, enable MtpMount under File Providers.") {
                    Button("Open System Settings") { controller.openExtensionSettings() }
                }
            }

            problemRow

            if !controller.ignoredDevices.isEmpty {
                Notice(symbol: "camera", tint: .secondary,
                       title: "Left to Image Capture: " + controller.ignoredDevices.joined(separator: ", "),
                       detail: "Cameras are for Photos and Image Capture, so MtpMount doesn't open them.")
            }

            if controller.rows.isEmpty {
                if controller.checked && controller.problem == .none {
                    Notice(symbol: "cable.connector", tint: .secondary, title: "No device connected",
                           detail: "Connect an MTP device (phone, camera, GPS, music player…) with a USB data cable and unlock it. On a phone, choose “File transfer” in the USB notification.")
                } else if !controller.checked {
                    Notice(symbol: "ellipsis.circle", tint: .secondary, title: "Checking for devices…", detail: nil)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.rows) { row in
                        DeviceRowView(row: row)
                    }
                }
            }

            DisclosureGroup("Troubleshooting", isExpanded: $showTroubleshooting) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(controller.agentLoaded ? "Helper is installed" : "Helper is not installed",
                          systemImage: controller.agentLoaded ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("Refresh Finder") { Task { await controller.signalAll() } }
                        Button("Reinstall helper") { Task { await controller.registerAgent(force: true) } }
                        Button("Reset") { Task { await controller.reset() } }
                            .help("Removes and re-adds the Finder locations. Downloaded copies are discarded.")
                    }
                    Toggle("Use the built-in MTP driver (instead of libmtp)", isOn: Binding(
                        get: { controller.backend == .native },
                        set: { controller.backend = $0 ? .native : .libmtp }))
                        .help("MtpMount's own MTP implementation. The helper restarts when you change this.")
                    Button("Uninstall…", role: .destructive) { Task { await controller.uninstall() } }
                        .help("Removes the helper and the Finder locations so the app can be deleted.")
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
            // Keep the device list current while the window is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await controller.refresh()
            }
        }
    }

    @ViewBuilder private var problemRow: some View {
        switch controller.problem {
        case .none:
            EmptyView()
        case .busy(let message):
            Notice(symbol: "hand.raised.fill", tint: .orange, title: "A device is in use by another app",
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

/// One device: its state and what can be done with it.
private struct DeviceRowView: View {
    @EnvironmentObject var controller: DomainController
    let row: DeviceRow

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Notice(symbol: row.connected ? "checkmark.circle.fill" : "powerplug",
                   tint: row.connected ? .green : .secondary,
                   title: row.name,
                   detail: row.connected ? "Connected" : "Not connected — its folder shows again when you reconnect it.")
            Spacer()
            Button("Show in Finder") { Task { await controller.showInFinder(row) } }
                .disabled(!row.connected)
            if !row.connected {
                Button("Forget") { Task { await controller.forget(row) } }
                    .help("Removes this device's location from Finder.")
            }
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
