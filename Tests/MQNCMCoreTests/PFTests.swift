import XCTest
@testable import MQNCMCore

final class PFTests: XCTestCase {
    func testNatRuleIsConfinedToLinkSubnet() {
        XCTAssertEqual(PF.rule(egress: "en0", plan: LinkPlan()),
                       "nat on en0 inet from 192.168.42.0/24 to ! 192.168.42.0/24 -> (en0)\n")
        XCTAssertEqual(PF.anchor, "com.apple/mqncm")
    }

    func testPlanAddresses() {
        var p = LinkPlan(); p.subnetPrefix = "172.29.42"
        XCTAssertEqual(p.macHost, "172.29.42.1")
        XCTAssertEqual(p.questCIDR, "172.29.42.2/24")
    }
}

final class StatsTests: XCTestCase {
    func testRateInMbps() {
        let r = TrafficMeter.rate(from: ByteCounters(rx: 0, tx: 1_000_000),
                                  to: ByteCounters(rx: 12_500_000, tx: 1_000_000), seconds: 1)
        XCTAssertEqual(r.rx, 100, accuracy: 0.001)   // 12.5 MB/s = 100 Mbit/s
        XCTAssertEqual(r.tx, 0)
    }

    func test32BitCounterWrap() {
        let r = TrafficMeter.rate(from: ByteCounters(rx: UInt64(UInt32.max) - 999, tx: 0),
                                  to: ByteCounters(rx: 1000, tx: 0), seconds: 1)
        XCTAssertEqual(r.rx, 2000 * 8 / 1e6, accuracy: 1e-9)
    }

    func testZeroInterval() {
        let r = TrafficMeter.rate(from: ByteCounters(rx: 0, tx: 0), to: ByteCounters(rx: 5, tx: 5), seconds: 0)
        XCTAssertEqual(r.rx, 0); XCTAssertEqual(r.tx, 0)
    }
}

final class StatusTests: XCTestCase {
    func testJSONRoundTrip() throws {
        var s = LinkStatus()
        s.state = .up; s.usbPresent = true; s.interface = "en16"; s.usbLinkSpeedBps = 480_000_000
        s.questIPv4 = "192.168.42.2/24"
        let back = try JSONDecoder().decode(LinkStatus.self, from: Data(s.json().utf8))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.questHost, "192.168.42.2")
        XCTAssertTrue(s.json().contains("\"192.168.42.2/24\""))   // slashes not escaped
    }

    func testUSBSpeedDescriptions() {
        XCTAssertEqual(USB.describe(bitsPerSecond: 480_000_000), "480 Mb/s")
        XCTAssertEqual(USB.describe(bitsPerSecond: USB.bitsPerSecond(usbSpeed: 4)!), "5 Gb/s")
    }
}
