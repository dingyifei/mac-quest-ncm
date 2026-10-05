import Foundation

public struct LinkPlan {
    public var subnetPrefix = "192.168.42"
    public var prefixLength = 24
    public var macHost: String { "\(subnetPrefix).1" }
    public var questHost: String { "\(subnetPrefix).2" }
    public var netmask: String { "255.255.255.0" }
    public var questCIDR: String { "\(questHost)/\(prefixLength)" }
    public var subnetCIDR: String { "\(subnetPrefix).0/\(prefixLength)" }
    public init() {}
}

public enum NetError: Error, CustomStringConvertible {
    case refuse(String)
    case command(String)
    public var description: String {
        switch self { case .refuse(let s): return "refusing: \(s)"; case .command(let s): return s }
    }
}

/// Mac-side network configuration through `networksetup`, `ifconfig` and `scutil`.
public enum MacNet {
    static let networksetup = "/usr/sbin/networksetup"

    public struct Service { public let name: String; public let device: String }

    /// Services in order, with their device names, from `networksetup -listnetworkserviceorder`.
    public static func services() throws -> [Service] {
        let out = try Shell.run(networksetup, ["-listnetworkserviceorder"]).stdout
        var result: [Service] = []
        var pendingName: String?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("("), let close = line.firstIndex(of: ")"), !line.hasPrefix("(Hardware Port") {
                pendingName = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("(Hardware Port"), let name = pendingName,
                      let r = line.range(of: "Device: ") {
                let dev = line[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
                result.append(Service(name: name.hasPrefix("*") ? String(name.dropFirst()) : name, device: dev))
                pendingName = nil
            }
        }
        return result
    }

    public static func hardwarePort(for device: String) throws -> String? {
        let out = try Shell.run(networksetup, ["-listallhardwareports"]).stdout
        var port: String?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("Hardware Port: ") { port = String(line.dropFirst("Hardware Port: ".count)) }
            if line == "Device: \(device)" { return port }
        }
        return nil
    }

    /// Ensures a service for `device` exists and is Manual (no router) with IPv6 link-local.
    /// Returns the service name. Refuses to touch any service whose device is not `device`.
    @discardableResult
    public static func ensureService(device: String, plan: LinkPlan) throws -> String {
        guard device.hasPrefix("en"), device != "en0" else { throw NetError.refuse("unexpected device '\(device)'") }
        var svc = try services().first { $0.device == device }
        if svc == nil {
            guard let port = try hardwarePort(for: device) else { throw NetError.command("no hardware port for \(device); try `networksetup -detectnewhardware`") }
            let name = "Quest NCM (mqncm)"
            let r = try Shell.run(networksetup, ["-createnetworkservice", name, port])
            guard r.ok else { throw NetError.command("createnetworkservice failed: \(r.combined)") }
            svc = try services().first { $0.device == device }
        }
        guard let s = svc, s.device == device else { throw NetError.refuse("service lookup for \(device) did not match") }

        let info = try Shell.run(networksetup, ["-getinfo", s.name]).stdout
        let alreadyManual = info.contains("Manual Configuration") && info.contains("IP address: \(plan.macHost)")
            && info.contains("Router: (null)")
        if !alreadyManual {
            // No router argument: the service must never be able to become the Mac's primary.
            let r = try Shell.run(networksetup, ["-setmanual", s.name, plan.macHost, plan.netmask])
            guard r.ok else { throw NetError.command("setmanual failed: \(r.combined)") }
            let after = try Shell.run(networksetup, ["-getinfo", s.name]).stdout
            guard after.contains("Router: (null)") || !after.contains("Router:") else {
                throw NetError.refuse("service '\(s.name)' ended up with a router; fix it in System Settings")
            }
        }
        return s.name
    }

    public static func ipv4(of device: String) -> String? {
        guard let out = try? Shell.run("/sbin/ifconfig", [device]).stdout else { return nil }
        return out.split(separator: "\n").compactMap { line -> String? in
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.first == "inet", f.count > 1 else { return nil }
            return String(f[1])
        }.first
    }

    public static func isUpRunning(_ device: String) -> Bool {
        guard let out = try? Shell.run("/sbin/ifconfig", [device]).stdout,
              let flags = out.split(separator: "\n").first else { return false }
        return flags.contains("UP") && flags.contains("RUNNING")
    }

    /// PrimaryInterface/Router of the Mac's global IPv4 state.
    public static func primary() -> (interface: String?, router: String?) {
        guard let out = try? Shell.run("/usr/sbin/scutil", [], input: "show State:/Network/Global/IPv4\n").stdout else { return (nil, nil) }
        func value(_ key: String) -> String? {
            out.split(separator: "\n").first { $0.contains("\(key) :") }?
                .split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
        }
        return (value("PrimaryInterface"), value("Router"))
    }

    /// Fails if any local interface (other than `except`) already sits in the planned subnet.
    public static func checkSubnetFree(_ plan: LinkPlan, except: String) throws {
        let out = try Shell.run("/sbin/ifconfig", []).stdout
        var current = ""
        for line in out.split(separator: "\n") {
            if !line.hasPrefix("\t"), let c = line.firstIndex(of: ":") { current = String(line[..<c]); continue }
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if f.first == "inet", f.count > 1, f[1].hasPrefix(plan.subnetPrefix + "."), current != except {
                throw NetError.refuse("\(plan.subnetCIDR) is already used on \(current) (\(f[1])); pass --subnet")
            }
        }
    }
}
