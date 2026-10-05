import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct ByteCounters: Equatable {
    public var rx: UInt64
    public var tx: UInt64
    public init(rx: UInt64, tx: UInt64) { self.rx = rx; self.tx = tx }
}

public struct RateSample: Equatable, Identifiable {
    public let time: Date
    /// Mac receive (Quest → Mac), Mbit/s.
    public let rxMbps: Double
    /// Mac transmit (Mac → Quest), Mbit/s.
    public let txMbps: Double
    public var id: Date { time }
}

/// Per-interface traffic rates from the kernel's if_data counters.
public final class TrafficMeter {
    public let interface: String
    public private(set) var history: [RateSample] = []
    public let capacity: Int
    private var last: (time: Date, counters: ByteCounters)?

    public init(interface: String, capacity: Int = 60) {
        self.interface = interface
        self.capacity = capacity
    }

    public static func counters(of interface: String) -> ByteCounters? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cur {
            defer { cur = ifa.pointee.ifa_next }
            guard String(cString: ifa.pointee.ifa_name) == interface,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            return ByteCounters(rx: UInt64(d.ifi_ibytes), tx: UInt64(d.ifi_obytes))
        }
        return nil
    }

    /// Rate between two counter readings, in Mbit/s. Handles 32-bit counter wrap.
    public static func rate(from a: ByteCounters, to b: ByteCounters, seconds: Double) -> (rx: Double, tx: Double) {
        guard seconds > 0 else { return (0, 0) }
        func delta(_ x: UInt64, _ y: UInt64) -> Double {
            y >= x ? Double(y - x) : Double(y &+ (UInt64(UInt32.max) + 1) &- x)
        }
        return (delta(a.rx, b.rx) * 8 / seconds / 1e6, delta(a.tx, b.tx) * 8 / seconds / 1e6)
    }

    /// Reads counters and appends a sample (no sample on the first call). Returns the new sample.
    @discardableResult
    public func sample(now: Date = Date()) -> RateSample? {
        guard let c = Self.counters(of: interface) else { return nil }
        defer { last = (now, c) }
        guard let prev = last else { return nil }
        let r = Self.rate(from: prev.counters, to: c, seconds: now.timeIntervalSince(prev.time))
        let s = RateSample(time: now, rxMbps: r.rx, txMbps: r.tx)
        history.append(s)
        if history.count > capacity { history.removeFirst(history.count - capacity) }
        return s
    }
}
