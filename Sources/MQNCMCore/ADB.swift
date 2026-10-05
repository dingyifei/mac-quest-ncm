import Foundation

public enum ADBError: Error, CustomStringConvertible {
    case notFound
    case noDevice(String)
    case command(String, String)
    public var description: String {
        switch self {
        case .notFound: return "adb not found (set $ADB, or install Android platform-tools)"
        case .noDevice(let s): return s
        case .command(let cmd, let out): return "adb \(cmd) failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Thin wrapper over the adb client. When mqncm runs under sudo, adb runs as the invoking user so it
/// talks to the user's adb server and RSA key (a root adb server would trigger a new authorization prompt).
public struct ADB {
    public let path: String
    public var serial: String?

    public init(serial: String? = nil) throws {
        let env = ProcessInfo.processInfo.environment
        let home = Shell.sudoUser.map { "/Users/\($0)" } ?? NSHomeDirectory()
        let candidates = [env["ADB"], "\(home)/Library/Android/sdk/platform-tools/adb",
                          "/run/current-system/sw/bin/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"].compactMap { $0 }
        guard let p = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw ADBError.notFound }
        path = p
        self.serial = serial
    }

    private func invoke(_ args: [String], timeout: TimeInterval) throws -> ShellResult {
        if let user = Shell.sudoUser {
            return try Shell.run("/usr/bin/sudo", ["-u", user, "-H", path] + args, timeout: timeout)
        }
        return try Shell.run(path, args, timeout: timeout)
    }

    public struct Device { public let serial: String; public let state: String; public let isUSB: Bool }

    public func devices() throws -> [Device] {
        let r = try invoke(["devices", "-l"], timeout: 15)
        return r.stdout.split(separator: "\n").dropFirst().compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 2 else { return nil }
            return Device(serial: String(f[0]), state: String(f[1]), isUSB: line.contains("usb:"))
        }
    }

    /// Picks the USB-attached Quest whose adb serial equals its USB serial number.
    public mutating func resolve(usbSerial: String?) throws {
        if serial != nil { return }
        let devs = try devices()
        if let s = usbSerial, let d = devs.first(where: { $0.serial == s }) {
            guard d.state == "device" else { throw ADBError.noDevice("adb sees \(s) as '\(d.state)': accept the USB debugging prompt in the headset") }
            serial = s; return
        }
        let ready = devs.filter { $0.state == "device" }
        guard ready.count == 1 else {
            throw ADBError.noDevice(ready.isEmpty ? "no authorized adb device (is developer mode on and the cable plugged in?)"
                                                  : "several adb devices; pass --serial")
        }
        serial = ready[0].serial
    }

    @discardableResult
    public func shell(_ command: String, timeout: TimeInterval = 20, check: Bool = false) throws -> ShellResult {
        var args: [String] = []
        if let serial { args += ["-s", serial] }
        let r = try invoke(args + ["shell", command], timeout: timeout)
        if check && !r.ok { throw ADBError.command(command, r.combined) }
        return r
    }
}

/// Quest-side operations used by mqncm.
public struct Quest {
    public var adb: ADB
    public init(adb: ADB) { self.adb = adb }

    public func usbFunctions() throws -> String {
        try adb.shell("svc usb getFunctions").combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Switches the gadget to NCM. Never pass "ncm,adb": Android rejects it and re-adds adb itself.
    /// The USB adb transport is torn down by the switch itself, so adb often exits non-zero
    /// after the command has already been applied; "setCurrentFunctions" in the output means it was.
    public func setFunctionsNCM() throws {
        let r = try adb.shell("svc usb setFunctions ncm")
        guard r.ok || r.combined.contains("setCurrentFunctions") else {
            throw ADBError.command("svc usb setFunctions ncm", r.combined)
        }
    }

    public func ipv4(of iface: String = "usb0") throws -> String? {
        let out = try adb.shell("ip -4 addr show \(iface)").stdout
        return out.split(separator: "\n").compactMap { line -> String? in
            let f = line.split(separator: " ")
            guard let i = f.firstIndex(of: "inet"), i + 1 < f.count else { return nil }
            return String(f[i + 1])
        }.first
    }

    public func setStatic(iface: String = "usb0", cidr: String, gateway: String? = nil, dns: [String] = []) throws {
        var cmd = "cmd ethernet set-ip-configuration \(iface) static \(cidr)"
        if let gateway { cmd += " --gateway \(gateway)" }
        for d in dns { cmd += " --dns \(d)" }
        let r = try adb.shell(cmd, check: true)
        guard r.stdout.contains("STATIC") else { throw ADBError.command(cmd, r.combined) }
    }

    public func setDHCP(iface: String = "usb0") throws {
        try adb.shell("cmd ethernet set-ip-configuration \(iface) dhcp", check: true)
    }

    /// Packages holding an app-requested TRANSPORT_USB network (Meta's official "Mode A"), which pre-empts Mode B.
    public func modeAHolders() throws -> [String] {
        let dump = try adb.shell("dumpsys connectivity", timeout: 30).stdout
        return dump.split(separator: "\n")
            .filter { $0.contains("REQUEST id=") && $0.contains("Transports: USB") }
            .compactMap { line -> String? in
                guard let r = line.range(of: "RequestorPkg: ") else { return nil }
                return String(line[r.upperBound...].prefix { $0 != " " })
            }
    }

    public struct EthernetState { public let isDefault: Bool; public let validated: Bool }

    public func ethernetState() throws -> EthernetState {
        let dump = try adb.shell("dumpsys connectivity", timeout: 30).stdout
        let lines = dump.split(separator: "\n")
        guard let def = lines.first(where: { $0.hasPrefix("Active default network:") })?
                .split(separator: " ").last.map(String.init),
              let eth = lines.first(where: { $0.contains("NetworkAgentInfo{network{") && $0.contains("ni{Ethernet") })
        else { return EthernetState(isDefault: false, validated: false) }
        return EthernetState(isDefault: eth.contains("network{\(def)}"), validated: eth.contains("IS_VALIDATED"))
    }
}
