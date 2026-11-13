// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI

private let repoURL = URL(string: "https://github.com/henrik242/mtp-mount")!

/// Owns the controller and the launch lifecycle. The helper relaunches the app
/// with `--sync-domains` just to register a Finder location and quit; that must
/// show no UI at all (no menu bar icon, no Dock, no window).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DomainController()
    let isSyncLaunch = CommandLine.arguments.contains(MtpAgentConfig.syncDomainsArgument)

    func applicationWillFinishLaunching(_ notification: Notification) {
        // LSUIElement already makes this an accessory (menu-bar) app; for the
        // headless sync-launch go further so nothing is drawn at all.
        if isSyncLaunch { NSApp.setActivationPolicy(.prohibited) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await controller.register()
            if isSyncLaunch { NSApp.terminate(nil) }
        }
    }
}

@main
struct MtpMountApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar item is the primary surface. Hidden for the headless
        // sync-launch (the helper relaunching us just to register a location),
        // which also runs at .prohibited so nothing else is drawn.
        MenuBarExtra(isInserted: .constant(!appDelegate.isSyncLaunch)) {
            MenuContent().environmentObject(appDelegate.controller)
        } label: {
            MenuBarLabel(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)

        Window("MtpMount", id: "status") {
            StatusWindow().environmentObject(appDelegate.controller)
                .frame(minWidth: 460, minHeight: 320)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 480, height: 400)
        .commands { AppCommands(controller: appDelegate.controller) }

        Settings {
            TroubleshootingView().environmentObject(appDelegate.controller)
        }
    }
}

// MARK: - Menu bar

/// The menu bar icon: a template SF Symbol that flips to a warning variant when
/// something needs attention. Also the one place the status is polled for the
/// app's lifetime, so the icon stays current while everything is closed.
private struct MenuBarLabel: View {
    @ObservedObject var controller: DomainController

    var body: some View {
        let connected = controller.rows.filter(\.connected).count
        Image(systemName: controller.needsAttention ? "cable.connector.slash" : "cable.connector")
            .accessibilityLabel(controller.needsAttention
                ? "MtpMount — attention needed"
                : "MtpMount — \(connected) device\(connected == 1 ? "" : "s") connected")
            .task {
                while !Task.isCancelled {
                    await controller.refresh()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
    }
}

/// The popover shown from the menu bar: warnings, the device list, and a footer.
private struct MenuContent: View {
    @EnvironmentObject var controller: DomainController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MtpMount").font(.headline)

            WarningsView()

            if controller.rows.isEmpty {
                Label(controller.checked ? "No device connected" : "Checking for devices…",
                      systemImage: controller.checked ? "cable.connector" : "ellipsis.circle")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.rows) { DeviceRowView(row: $0, compact: true) }
                }
            }

            Divider()

            HStack {
                Button("Open Window") { openWindow(id: "status"); activate() }
                Spacer()
                Menu {
                    Button("About MtpMount") { showAboutPanel() }
                    Button("Troubleshooting…") { openSettings(); activate() }
                    Divider()
                    Button("Quit MtpMount") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(14)
        .frame(width: 320)
        .task { await controller.refresh() }
    }

    private func activate() { NSApp.activate(ignoringOtherApps: true) }
}

// MARK: - Status window

private struct StatusWindow: View {
    @EnvironmentObject var controller: DomainController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WarningsView()

            if controller.rows.isEmpty {
                if !controller.checked {
                    ContentUnavailableView { Label("Checking for devices…", systemImage: "ellipsis.circle") }
                } else if controller.problem == .none {
                    ContentUnavailableView {
                        Label("No Device Connected", systemImage: "cable.connector")
                    } description: {
                        Text("Connect an MTP device (phone, camera, GPS, music player…) with a USB data cable and unlock it. On a phone, choose “File transfer” in the USB notification.")
                    }
                }
            } else {
                List(controller.rows) { row in
                    DeviceRowView(row: row, compact: false)
                        .listRowSeparator(.visible)
                }
                .listStyle(.inset)
            }

            if let message = controller.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .task {
            while !Task.isCancelled {
                await controller.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

// MARK: - Shared pieces

/// The actionable warnings, shared by the popover and the window.
private struct WarningsView: View {
    @EnvironmentObject var controller: DomainController

    var body: some View {
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
                    .buttonStyle(.borderedProminent)
            }
        }
        ProblemNotice(problem: controller.problem)
        if !controller.ignoredDevices.isEmpty {
            Notice(symbol: "camera", tint: .secondary,
                   title: "Left to Image Capture: " + controller.ignoredDevices.joined(separator: ", "),
                   detail: "Cameras are for Photos and Image Capture, so MtpMount doesn't open them.")
        }
    }
}

private struct ProblemNotice: View {
    let problem: AgentProblem

    var body: some View {
        switch problem {
        case .none:
            EmptyView()
        case .busy(let message):
            Notice(symbol: "hand.raised.fill", tint: .orange, title: "A device is in use by another app",
                   detail: message.isEmpty
                       ? "Quit Image Capture, Android File Transfer, OpenMTP or the device maker's sync app, then reconnect."
                       : message)
        case .agentUnavailable:
            Notice(symbol: "exclamationmark.octagon.fill", tint: .red, title: "The MtpMount helper isn't running",
                   detail: "Open Settings (⌘,) and choose “Reinstall Helper”.")
        case .error(let message):
            Notice(symbol: "exclamationmark.triangle.fill", tint: .red, title: "Device error", detail: message)
        }
    }
}

/// One device: a device-class icon, its name/state, and Show in Finder.
private struct DeviceRowView: View {
    @EnvironmentObject var controller: DomainController
    let row: DeviceRow
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.connected ? "externaldrive.fill" : "externaldrive")
                .foregroundStyle(row.connected ? Color.accentColor : Color.secondary)
                .font(compact ? .body : .title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).fontWeight(.medium)
                if !compact {
                    Text(row.connected ? "Connected" : "Not connected")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Show in Finder") { Task { await controller.showInFinder(row) } }
                .controlSize(compact ? .small : .regular)
                .disabled(!row.connected)
                .accessibilityLabel("Show \(row.name) in Finder")
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Settings (Troubleshooting)

private struct TroubleshootingView: View {
    @EnvironmentObject var controller: DomainController
    @State private var confirmReset = false
    @State private var confirmUninstall = false

    var body: some View {
        Form {
            Section("Helper") {
                LabeledContent("Status") {
                    Label(controller.agentLoaded ? "Installed" : "Not installed",
                          systemImage: controller.agentLoaded ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(controller.agentLoaded ? Color.green : Color.secondary)
                }
                Button("Reinstall Helper") { Task { await controller.registerAgent(force: true) } }
            }
            Section("Finder") {
                Button("Refresh Finder") { Task { await controller.signalAll() } }
                Button("Reset Locations…") { confirmReset = true }
                    .help("Removes and re-adds the Finder locations. Downloaded copies are discarded.")
            }
            Section {
                Button("Uninstall…", role: .destructive) { confirmUninstall = true }
                    .help("Removes the helper and the Finder locations so the app can be deleted.")
            }
            if let message = controller.message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .confirmationDialog("Reset the Finder locations? Downloaded copies are discarded.",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { Task { await controller.reset() } }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Uninstall MtpMount's helper and remove its Finder locations?",
                            isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { Task { await controller.uninstall() } }
            Button("Cancel", role: .cancel) { }
        }
    }
}

// MARK: - Menus

private struct AppCommands: Commands {
    @ObservedObject var controller: DomainController
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About MtpMount") { showAboutPanel() }
        }
        CommandGroup(replacing: .newItem) { }   // no documents: drop New/Open
        CommandGroup(replacing: .help) {
            Link("MtpMount on GitHub", destination: repoURL)
        }
        CommandMenu("Device") {
            Button("Status Window") { openWindow(id: "status") }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Refresh Finder") { Task { await controller.signalAll() } }
                .keyboardShortcut("r", modifiers: .command)
            Button("Open Extension Settings…") { controller.openExtensionSettings() }
        }
    }
}

private func showAboutPanel() {
    let credits = NSMutableAttributedString(
        string: "Mounts MTP-over-USB devices as Finder locations.\n",
        attributes: [.font: NSFont.systemFont(ofSize: 11),
                     .foregroundColor: NSColor.secondaryLabelColor])
    credits.append(NSAttributedString(
        string: repoURL.absoluteString,
        attributes: [.font: NSFont.systemFont(ofSize: 11),
                     .link: repoURL,
                     .foregroundColor: NSColor.linkColor]))
    NSApp.orderFrontStandardAboutPanel(options: [
        .applicationName: "MtpMount",
        .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
        .version: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
        .credits: credits,
    ])
    NSApp.activate(ignoringOtherApps: true)
}

// MARK: - Notice

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
