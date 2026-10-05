import ArgumentParser
import Foundation
import MQNCMCore

struct Common: ParsableArguments {
    @Option(help: "adb serial of the Quest (default: the USB-attached one).") var serial: String?
    @Option(help: "First three octets of the link subnet (/24). Mac gets .1, Quest gets .2.") var subnet = "192.168.42"

    func options() -> LinkOptions {
        var o = LinkOptions()
        o.serial = serial
        o.plan.subnetPrefix = subnet
        return o
    }
}

func runOrExit(_ body: () throws -> Void) throws {
    do { try body() } catch {
        FileHandle.standardError.write(Data("mqncm: \(error)\n".utf8))
        throw ExitCode.failure
    }
}

func printJSON<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: (try? enc.encode(value)) ?? Data("{}".utf8), as: UTF8.self))
}

struct MQNCMCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mqncm",
        abstract: "Mac-Quest-NCM: a direct USB CDC-NCM network link between a Meta Quest and this Mac.",
        version: MQNCMVersion.string,
        subcommands: [Up.self, Down.self, Status.self, Monitor.self, Share.self, Test.self, RestoreUSB.self])
}

struct Up: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Switch the Quest to NCM and bring the link up.")
    @OptionGroup var common: Common
    @Flag(help: "Also share this Mac's internet with the Quest (needs sudo).") var share = false
    @Option(help: "DNS server handed to the Quest when sharing.") var dns = "1.1.1.1"
    @Flag(help: "Force-stop apps holding Meta's USB network (e.g. Virtual Desktop) instead of refusing.") var forceStopHolders = false

    func run() throws {
        var o = common.options()
        o.share = share
        o.dns = [dns]
        o.forceStopModeA = forceStopHolders
        if share && !Shell.isRoot { throw ValidationError("--share needs root: sudo mqncm up --share") }
        try runOrExit { try Link().up(o) }
    }
}

struct Down: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop sharing and return the Quest's usb0 to DHCP.")
    @OptionGroup var common: Common
    @Flag(help: "Leave the Quest's static address in place.") var keepQuestConfig = false
    func run() throws { try runOrExit { try Link().down(common.options(), keepQuestConfig: keepQuestConfig) } }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show link state on both ends.")
    @OptionGroup var common: Common
    @Flag(help: "Print JSON.") var json = false
    func run() throws {
        let s = LinkStatus.collect(serial: common.serial)
        if json { print(s.json()) } else { s.lines.forEach { print($0) } }
    }
}

struct Monitor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Live USB link speed and traffic rates on the link interface.")
    @Option(help: "Seconds between samples.") var interval = 1.0
    @Option(help: "Stop after this many samples (0 = run until Ctrl-C).") var count = 0
    @Flag(help: "Print one JSON object per sample.") var json = false

    struct Line: Encodable { let time: Date; let interface: String; let usbLinkSpeedBps: Int?; let rxMbps: Double; let txMbps: Double }

    func run() throws {
        try runOrExit {
            guard let dev = USB.questDevices().first, let ifn = dev.ncmBSDName else {
                throw LinkError.stage("monitor", "link is not up (run mqncm up)")
            }
            let speed = dev.linkSpeedBps
            let meter = TrafficMeter(interface: ifn)
            meter.sample()
            if !json { print("\(ifn), USB \(speed.map { USB.describe(bitsPerSecond: $0) } ?? "unknown")") }
            var n = 0
            while count == 0 || n < count {
                Thread.sleep(forTimeInterval: interval)
                guard let s = meter.sample() else { throw LinkError.stage("monitor", "\(ifn) disappeared") }
                n += 1
                if json {
                    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
                    print(String(decoding: try enc.encode(Line(time: s.time, interface: ifn, usbLinkSpeedBps: speed, rxMbps: s.rxMbps, txMbps: s.txMbps)), as: UTF8.self))
                } else {
                    print(String(format: "%@  Quest→Mac %7.1f Mbit/s   Mac→Quest %7.1f Mbit/s",
                                 DateFormatter.localizedString(from: s.time, dateStyle: .none, timeStyle: .medium), s.rxMbps, s.txMbps))
                }
                fflush(stdout)
            }
        }
    }
}

struct Share: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Mac → Quest internet sharing: on, off (need sudo) or status.")
    enum State: String, ExpressibleByArgument { case on, off, status }
    @Argument var state: State
    @OptionGroup var common: Common
    @Option var dns = "1.1.1.1"
    func run() throws {
        var o = common.options()
        o.dns = [dns]
        switch state {
        case .status:
            let s = LinkStatus.collect(serial: common.serial)
            print("share: \(s.sharing ? "on" : "off")")
            if let v = s.questCableValidated, let d = s.questCableDefault {
                print("quest: cable \(v ? "validated" : "not validated"), \(d ? "default network" : "not default")")
            }
        case .on, .off:
            guard Shell.isRoot else { throw ValidationError("needs root: sudo mqncm share \(state.rawValue)") }
            try runOrExit { try Privileged.share(on: state == .on, options: o, log: { print($0) }) }
        }
    }
}

struct Test: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Measure latency and throughput over the cable.")
    @OptionGroup var common: Common
    @Option(help: "Seconds per throughput direction.") var seconds = 8.0
    @Flag(help: "Print JSON.") var json = false

    func run() throws {
        try runOrExit {
            let r = try LinkTest.run(options: common.options(), seconds: seconds)
            if json { printJSON(r) } else { r.lines.forEach { print($0) } }
        }
    }
}

struct RestoreUSB: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restore-usb",
        abstract: "Return the Quest to its default USB mode (needed for Quest Link / Virtual Display USB).")
    @OptionGroup var common: Common
    func run() throws { try runOrExit { try Link().restoreUSB(common.options()) } }
}

MQNCMCLI.main()
