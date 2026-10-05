import AppKit
import Charts
import MQNCMCore
import SwiftUI

@main
struct MacQuestNCMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        // First scene + .presented: the window opens at launch even though the app is LSUIElement.
        Window("Mac-Quest-NCM", id: "main") {
            MainWindow().environmentObject(model)
        }
        .defaultSize(width: 640, height: 820)
        .defaultLaunchBehavior(.presented)

        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: model.status.menuIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Menu-bar (LSUIElement) apps don't come to the front on launch; bring the window forward.
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Clicking the app in Finder/Launchpad again re-opens the window if it was closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true }?.makeKeyAndOrderFront(nil) }
        return true
    }
}

extension LinkStatus {
    var menuIcon: String {
        switch state {
        case .noDevice, .defaultMode: return "cable.connector.slash"
        case .blocked, .unnamed: return "exclamationmark.triangle"
        case .up: return "cable.connector"
        case .sharing: return "globe"
        }
    }

    var isUp: Bool { state == .up || state == .sharing }

    var stateColor: Color {
        switch state {
        case .up, .sharing: return .green
        case .blocked, .unnamed: return .orange
        default: return .secondary
        }
    }
}

func mbps(_ v: Double) -> String { v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v) }

// MARK: - Shared pieces

struct StatusHeader: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { header }
    }

    @ViewBuilder var header: some View {
        HStack(spacing: 8) {
            Circle().fill(model.status.stateColor).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status.summary).font(.headline)
                if let speed = model.status.usbLinkSpeedBps {
                    Text("USB \(USB.describe(bitsPerSecond: speed))\(model.status.interface.map { " · \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.busy != nil { ProgressView().controlSize(.small) }
        }
        if let step = model.currentStep {
            Text(step).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
        }
        if let line = model.status.addressLine {
            HStack {
                Text(line).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                Button { model.copyQuestIP() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy Quest IP")
            }
        }
    }
}

struct RateView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 16) {
            Label("\(mbps(model.latestRate?.rxMbps ?? 0)) Mbit/s", systemImage: "arrow.down")
                .help("Quest → Mac")
            Label("\(mbps(model.latestRate?.txMbps ?? 0)) Mbit/s", systemImage: "arrow.up")
                .help("Mac → Quest")
        }
        .font(.system(.body, design: .monospaced))
    }
}

struct Banners: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if model.status.needsADBAuthorization {
            Banner(text: "Put on the headset and allow USB debugging for this Mac (tick \"Always allow\").",
                   icon: "visionpro")
        }
        if model.status.usbPresent && model.status.adbState == "missing" {
            Banner(text: "adb not found. Install it (brew install --cask android-platform-tools) or set its path in Settings.",
                   icon: "wrench.and.screwdriver")
        }
        if model.status.accessoryBlocked {
            Banner(text: "macOS is blocking the Quest's new USB mode. Unlock the Mac and click Allow on the accessory prompt.",
                   icon: "lock.trianglebadge.exclamationmark")
        }
        if model.status.state == .unnamed {
            Banner(text: "The NCM interface was not created (the Mac was probably locked). Replug the cable.", icon: "cable.connector.slash")
        }
        if !model.status.modeAHolders.isEmpty {
            Banner(text: "Held by \(model.status.modeAHolders.joined(separator: ", ")) (Meta's app USB mode). Close it to use this link.",
                   icon: "exclamationmark.triangle")
        }
        if let err = model.lastError {
            Banner(text: err, icon: "xmark.octagon")
        }
    }
}

struct Banner: View {
    let text: String
    let icon: String
    var body: some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct ActionButtons: View {
    @EnvironmentObject var model: AppModel
    var compact = false
    var body: some View {
        let busy = model.busy != nil
        let s = model.status
        HStack {
            if s.isUp {
                Button("Stop NCM", systemImage: "stop.circle") { model.stop() }
            } else {
                Button("Start NCM", systemImage: "play.circle") { model.start() }
                    .disabled(!s.usbPresent)
            }
            Toggle("Share internet", isOn: Binding(get: { s.sharing }, set: { model.setSharing($0) }))
                .toggleStyle(.switch)
                .disabled(!s.isUp)
            Button("Speed test", systemImage: "speedometer") { model.speedTest() }
                .disabled(!s.isUp)
            if !compact {
                Button("Restore USB mode", systemImage: "arrow.uturn.backward") { model.restoreUSB() }
                    .disabled(!s.isUp)
            }
        }
        .disabled(busy)
    }
}

// MARK: - Menu bar

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusHeader()
            if model.status.isUp { RateView() }
            Banners()
            ActionButtons(compact: true)
            Divider()
            HStack {
                Button("Copy Quest IP") { model.copyQuestIP() }.disabled(model.status.questHost == nil)
                Button("Open window") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 400)
    }
}

// MARK: - Window

struct MainWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content.padding(16)
            }
            Divider()
            footer.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusHeader()
            Banners()
            ActionButtons()

            GroupBox("Traffic (last 60 s)") {
                VStack(alignment: .leading) {
                    RateView()
                    Chart {
                        ForEach(model.samples) { s in
                            LineMark(x: .value("Time", s.time), y: .value("Mbit/s", s.rxMbps), series: .value("Dir", "Quest → Mac"))
                                .foregroundStyle(by: .value("Dir", "Quest → Mac"))
                            LineMark(x: .value("Time", s.time), y: .value("Mbit/s", s.txMbps), series: .value("Dir", "Mac → Quest"))
                                .foregroundStyle(by: .value("Dir", "Mac → Quest"))
                        }
                    }
                    .chartYAxisLabel("Mbit/s")
                    .frame(height: 140)
                }
            }

            GroupBox("Link") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    row("Quest", model.status.productName.map { "\($0) (\(model.status.composition ?? "?"))" } ?? "not attached")
                    row("USB link", model.status.usbLinkSpeedBps.map { USB.describe(bitsPerSecond: $0) } ?? "–")
                    row("Mac interface", model.status.interface.map { "\($0) \(model.status.interfaceUp ? "up" : "down"), \(model.status.macIPv4 ?? "no IPv4")" } ?? "–")
                    row("Quest address", model.status.questIPv4 ?? "–")
                    row("Quest network", model.status.questCableValidated.map { v in
                        "\(v ? "validated" : "not validated"), \(model.status.questCableDefault == true ? "default" : "not default")" } ?? "–")
                    row("Mac default route", "\(model.status.macPrimaryInterface ?? "–") via \(model.status.macRouter ?? "–")")
                    row("Internet sharing", model.status.sharing ? "on" : "off")
                    if let t = model.lastTest {
                        row("Last speed test", String(format: "%.2f ms avg · ↑ %.0f · ↓ %.0f Mbit/s", t.rttAvgMs ?? 0, t.macToQuestMbps, t.questToMacMbps))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Log") {
                ScrollView {
                    Text(model.log.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 80, maxHeight: 160)
            }
        }
    }

    var footer: some View {
            HStack {
                Button("Copy Quest IP") { model.copyQuestIP() }.disabled(model.status.questHost == nil)
                if let cli = model.cliPath {
                    Button("Reveal CLI") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cli)]) }
                        .help(cli)
                }
                Button("README") { NSWorkspace.shared.open(URL(string: "https://github.com/dingyifei/mac-quest-ncm#readme")!) }
                Spacer()
                SettingsLink { Text("Settings…") }
            }
    }

    @ViewBuilder func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            TextField("adb path (empty = auto)", text: $model.adbPath)
            TextField("DNS for the Quest when sharing", text: $model.shareDNS)
            Text("The link uses 192.168.42.1 (Mac) and 192.168.42.2 (Quest). Use the CLI's --subnet for another range.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 460)
    }
}
