import Foundation
import SystemConfiguration

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

    /// IPv4 address of `device` via getifaddrs (no subprocess; safe to call often).
    public static func ipv4(of device: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var cur = head
        while let ifa = cur {
            defer { cur = ifa.pointee.ifa_next }
            guard String(cString: ifa.pointee.ifa_name) == device, let sa = ifa.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    public static func isUpRunning(_ device: String) -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return false }
        defer { freeifaddrs(head) }
        var cur = head
        while let ifa = cur {
            defer { cur = ifa.pointee.ifa_next }
            if String(cString: ifa.pointee.ifa_name) == device {
                let f = Int32(ifa.pointee.ifa_flags)
                return f & IFF_UP != 0 && f & IFF_RUNNING != 0
            }
        }
        return false
    }

    /// PrimaryInterface/Router of the Mac's global IPv4 state, read from the SystemConfiguration store.
    public static func primary() -> (interface: String?, router: String?) {
        guard let dict = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return (nil, nil) }
        return (dict["PrimaryInterface"] as? String, dict["Router"] as? String)
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
