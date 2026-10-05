import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct PingStats { public let sent: Int; public let received: Int; public let min: Double; public let avg: Double; public let max: Double }

public enum LinkTest {
    /// ICMP latency over `iface` (bound with `ping -b`, so the test can't silently use another route).
    public static func latency(iface: String, host: String, count: Int = 500) throws -> PingStats? {
        let r = try Shell.run("/sbin/ping", ["-b", iface, "-i", "0.01", "-c", "\(count)", "-q", host], timeout: Double(count) * 0.05 + 10)
        let lines = r.stdout.split(separator: "\n")
        guard let pk = lines.first(where: { $0.contains("packets transmitted") }),
              let rt = lines.first(where: { $0.contains("round-trip") }) else { return nil }
        let nums = pk.split(separator: " ").compactMap { Int($0) }
        let v = rt.split(separator: "=").last?.split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "ms")))) } ?? []
        guard nums.count >= 2, v.count >= 3 else { return nil }
        return PingStats(sent: nums[0], received: nums[1], min: v[0], avg: v[1], max: v[2])
    }

    /// TCP bulk throughput in Mbit/s. The Quest side is `toybox nc` started over adb; the Mac socket is
    /// pinned to `iface` with IP_BOUND_IF. `upload` = Mac -> Quest.
    public static func throughput(adb: ADB, iface: String, host: String, port: Int, upload: Bool, seconds: Double) throws -> Double {
        let listener = upload ? "toybox nc -l -p \(port) > /dev/null" : "toybox nc -l -p \(port) < /dev/zero"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Shell.sudoUser != nil ? "/usr/bin/sudo" : adb.path)
        var args = (adb.serial.map { ["-s", $0] } ?? []) + ["shell", "-n", listener]
        if let u = Shell.sudoUser { args = ["-u", u, "-H", adb.path] + args }
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        defer {
            p.terminate()
            _ = try? adb.shell("pkill -f 'nc -l -p \(port)'")
        }
        Thread.sleep(forTimeInterval: 1.5)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NetError.command("socket() failed") }
        defer { close(fd) }
        var idx = if_nametoindex(iface)
        setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, host, &addr.sin_addr)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { throw NetError.command("connect to \(host):\(port) via \(iface) failed (errno \(errno))") }

        var buf = [UInt8](repeating: 0, count: 1 << 20)
        var total = 0
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            let n = buf.withUnsafeMutableBytes { upload ? write(fd, $0.baseAddress, $0.count) : read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            total += n
        }
        return Double(total) * 8 / Date().timeIntervalSince(start) / 1e6
    }
}

public struct LinkTestResult: Codable {
    public let interface: String
    public let usbLinkSpeedBps: Int?
    public let pingSent: Int?
    public let pingReceived: Int?
    public let rttMinMs: Double?
    public let rttAvgMs: Double?
    public let rttMaxMs: Double?
    public let macToQuestMbps: Double
    public let questToMacMbps: Double

    public var lines: [String] {
        var out: [String] = []
        if let s = pingSent, let r = pingReceived, let mn = rttMinMs, let a = rttAvgMs, let mx = rttMaxMs {
            out.append(String(format: "latency  : %d/%d replies, min %.2f / avg %.2f / max %.2f ms (%@)", r, s, mn, a, mx, interface))
        }
        if let b = usbLinkSpeedBps { out.append("usb link : \(USB.describe(bitsPerSecond: b))") }
        out.append(String(format: "Mac→Quest: %.0f Mbit/s", macToQuestMbps))
        out.append(String(format: "Quest→Mac: %.0f Mbit/s", questToMacMbps))
        return out
    }
}

extension LinkTest {
    /// Latency (ICMP bound to the link interface) plus TCP throughput in both directions.
    public static func run(options o: LinkOptions, seconds: Double) throws -> LinkTestResult {
        guard let dev = USB.questDevices().first, let ifn = dev.ncmBSDName else {
            throw LinkError.stage("test", "link is not up (run mqncm up)")
        }
        let ping = try latency(iface: ifn, host: o.plan.questHost)
        var adb = try ADB(serial: o.serial)
        try adb.resolve(usbSerial: dev.serial)
        let up = try throughput(adb: adb, iface: ifn, host: o.plan.questHost, port: 5301, upload: true, seconds: seconds)
        let down = try throughput(adb: adb, iface: ifn, host: o.plan.questHost, port: 5302, upload: false, seconds: seconds)
        return LinkTestResult(interface: ifn, usbLinkSpeedBps: dev.linkSpeedBps,
                              pingSent: ping?.sent, pingReceived: ping?.received,
                              rttMinMs: ping?.min, rttAvgMs: ping?.avg, rttMaxMs: ping?.max,
                              macToQuestMbps: up, questToMacMbps: down)
    }
}
