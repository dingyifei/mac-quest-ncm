import AppKit
import Foundation
import MQNCMCore

/// UI state. All link work runs off the main thread through the same MQNCMCore calls the CLI uses.
@MainActor
final class AppModel: ObservableObject {
    @Published var status = LinkStatus()
    @Published var samples: [RateSample] = []
    @Published var log: [String] = []
    @Published var busy: String?
    @Published var lastError: String?
    @Published var lastTest: LinkTestResult?

    @Published var adbPath: String = UserDefaults.standard.string(forKey: "adbPath") ?? "" {
        didSet {
            UserDefaults.standard.set(adbPath, forKey: "adbPath")
            applyADBPath()
        }
    }
    @Published var shareDNS: String = UserDefaults.standard.string(forKey: "shareDNS") ?? "1.1.1.1" {
        didSet { UserDefaults.standard.set(shareDNS, forKey: "shareDNS") }
    }

    private var meter: TrafficMeter?
    private var sawFirstStatus = false
    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private var timer: Timer?
    private var tick = 0

    var latestRate: RateSample? { samples.last }
    /// Most recent step of the running operation, shown next to the spinner.
    var currentStep: String? { busy == nil ? nil : log.last }

    init() {
        applyADBPath()
        refresh(full: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    private func applyADBPath() {
        if adbPath.isEmpty { unsetenv("ADB") } else { setenv("ADB", adbPath, 1) }
    }

    private func onTick() {
        tick += 1
        sampleTraffic()
        // USB/interface state is cheap (IOKit); the Quest side goes through adb, so poll it less often.
        if tick % 2 == 0 { refresh(full: tick % 6 == 0 || (busy != nil && tick % 2 == 0)) }
    }

    private func sampleTraffic() {
        guard let ifn = status.interface else { meter = nil; samples = []; return }
        if meter?.interface != ifn { meter = TrafficMeter(interface: ifn) }
        meter?.sample()
        samples = meter?.history ?? []
    }

    func refresh(full: Bool) {
        let previous = status
        Task.detached {
            var s = LinkStatus.collect(includeQuest: full)
            if !full {
                s.adbAvailable = previous.adbAvailable
                s.adbState = previous.adbState
                s.questIPv4 = previous.questIPv4
                s.questCableValidated = previous.questCableValidated
                s.questCableDefault = previous.questCableDefault
                s.modeAHolders = previous.modeAHolders
            }
            let result = s
            await MainActor.run {
                self.noteChanges(from: previous, to: result, first: !self.sawFirstStatus)
                self.sawFirstStatus = true
                self.status = result
            }
        }
    }

    var options: LinkOptions {
        var o = LinkOptions()
        o.dns = [shareDNS]
        return o
    }

    /// Logs what the app observes (not only what it does), so the log is meaningful right after launch.
    private func noteChanges(from old: LinkStatus, to new: LinkStatus, first: Bool) {
        if first {
            append("Mac-Quest-NCM \(MQNCMVersion.string) started — \(new.summary)")
            if let a = new.addressLine { append(a) }
            return
        }
        if old.usbPresent != new.usbPresent {
            append(new.usbPresent ? "\(new.productName ?? "Quest") attached (\(new.composition ?? "?"))" : "Quest detached")
        } else if new.usbPresent, old.productID != new.productID {
            append("Quest USB mode changed: \(new.composition ?? "?")")
        }
        if old.usbLinkSpeedBps != new.usbLinkSpeedBps, let b = new.usbLinkSpeedBps {
            append("USB link speed \(USB.describe(bitsPerSecond: b))")
        }
        if old.state != new.state { append(new.summary) }
        if old.addressLine != new.addressLine, let a = new.addressLine { append(a) }
        if old.adbState != new.adbState, let a = new.adbState, new.adbState != nil {
            switch a {
            case "unauthorized": append("adb: waiting for USB debugging approval in the headset")
            case "device": if old.adbState == "unauthorized" { append("adb: authorized") }
            case "missing": append("adb not found")
            default: break
            }
        }
        if old.questCableValidated != new.questCableValidated, let v = new.questCableValidated, old.questCableValidated != nil {
            append(v ? "Quest validated the cable (internet via Mac)" : "Quest: cable not validated")
        }
        if old.modeAHolders != new.modeAHolders, !new.modeAHolders.isEmpty {
            append("USB network held by \(new.modeAHolders.joined(separator: ", "))")
        }
    }

    private func append(_ line: String) {
        log.append("\(Self.clock.string(from: Date()))  \(line)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    /// Runs a blocking core operation in the background, streaming its log lines into the UI.
    private func perform(_ title: String, _ work: @escaping (@escaping (String) -> Void) throws -> Void) {
        guard busy == nil else { return }
        busy = title
        lastError = nil
        append("— \(title)")
        let sink: (String) -> Void = { line in Task { @MainActor in self.append(line) } }
        Task.detached {
            let failure: String?
            do { try work(sink); failure = nil } catch { failure = "\(error)" }
            await MainActor.run {
                if let failure { self.lastError = failure; self.append("error: \(failure)") }
                self.busy = nil
                self.refresh(full: true)
            }
        }
    }

    func start() { let o = options; perform("Start NCM") { log in try Link(log: log).up(o) } }

    func stop() {
        let o = options
        let sharing = status.sharing
        perform("Stop NCM") { log in
            if sharing { try Privileged.share(on: false, options: o, log: log) }
            try Link(log: log).down(o, keepQuestConfig: false)
        }
    }

    func setSharing(_ on: Bool) {
        let o = options
        perform(on ? "Share internet" : "Stop sharing") { log in try Privileged.share(on: on, options: o, log: log) }
    }

    func restoreUSB() { let o = options; perform("Restore USB mode") { log in try Link(log: log).restoreUSB(o) } }

    func speedTest() {
        let o = options
        perform("Speed test") { log in
            let r = try LinkTest.run(options: o, seconds: 6)
            r.lines.forEach(log)
            Task { @MainActor in self.lastTest = r }
        }
    }

    func copyQuestIP() {
        guard let ip = status.questHost else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)
    }

    var cliPath: String? { Privileged.cliPath() }
}
