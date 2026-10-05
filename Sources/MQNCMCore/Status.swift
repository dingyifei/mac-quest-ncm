import Foundation

/// Snapshot of both ends of the link. Shared by `mqncm status [--json]` and the app.
public struct LinkStatus: Codable, Equatable {
    public enum State: String, Codable { case noDevice, blocked, defaultMode, unnamed, up, sharing }

    public var state: State = .noDevice
    public var usbPresent = false
    public var productName: String?
    public var serial: String?
    public var productID: Int?
    public var composition: String?
    public var accessoryBlocked = false
    public var usbLinkSpeedBps: Int?
    public var interface: String?
    public var interfaceUp = false
    public var linkActive = false
    public var macIPv4: String?
    public var macPrimaryInterface: String?
    public var macRouter: String?
    public var adbAvailable = false
    /// adb's state for this Quest: "device", "unauthorized", "offline", "absent", or "missing" (no adb binary).
    public var adbState: String?
    public var needsADBAuthorization: Bool { adbState == "unauthorized" }
    /// "192.168.42.1 ⇄ 192.168.42.2" once both ends are addressed.
    public var addressLine: String? {
        guard let m = macIPv4, let q = questHost else { return nil }
        return "Mac \(m) ⇄ Quest \(q)"
    }
    public var questIPv4: String?
    public var questCableValidated: Bool?
    public var questCableDefault: Bool?
    public var modeAHolders: [String] = []
    public var sharing = false

    public init() {}

    /// The Quest address without prefix length, e.g. "192.168.42.2".
    public var questHost: String? { questIPv4?.split(separator: "/").first.map(String.init) }

    public var summary: String {
        switch state {
        case .noDevice: return "No Quest attached"
        case .blocked: return "Blocked: unlock the Mac and click Allow"
        case .defaultMode: return "Quest in default USB mode"
        case .unnamed: return "NCM present but no interface (unlock and replug)"
        case .up: return "Link up"
        case .sharing: return "Link up, sharing internet"
        }
    }

    public var lines: [String] {
        var out: [String] = []
        guard usbPresent else { return ["usb    : no Quest attached"] }
        let pid = productID.map { String(format: "0x%04x", $0) } ?? "?"
        let speed = usbLinkSpeedBps.map { USB.describe(bitsPerSecond: $0) } ?? "unknown speed"
        out.append("usb    : \(productName ?? "Quest") \(serial ?? "") pid \(pid) (\(composition ?? "?")), \(speed)")
        if accessoryBlocked { out.append("gate   : macOS is blocking this USB mode — unlock and click Allow") }
        if needsADBAuthorization { out.append("adb    : not authorized — put on the headset and allow USB debugging") }
        if let i = interface {
            out.append("if     : \(i) \(interfaceUp ? "UP,RUNNING" : "down") link=\(linkActive ? "active" : "inactive") ipv4=\(macIPv4 ?? "none")")
        } else if state == .unnamed {
            out.append("if     : NCM present but not named (unlock + replug)")
        } else if !accessoryBlocked {
            out.append("if     : Quest is in its default USB mode (run `mqncm up`)")
        }
        out.append("mac    : primary \(macPrimaryInterface ?? "none") via \(macRouter ?? "-")")
        out.append("share  : \(sharing ? "on" : "off")")
        if adbAvailable {
            out.append("quest  : usb0 \(questIPv4 ?? "no ipv4")")
            if let v = questCableValidated, let d = questCableDefault {
                out.append("quest  : cable network \(v ? "validated" : "not validated"), \(d ? "default" : "not default")")
            }
            if !modeAHolders.isEmpty { out.append("quest  : USB network held by \(modeAHolders.joined(separator: ", ")) (Meta app mode)") }
        } else {
            out.append("quest  : adb \(adbState ?? "unavailable")")
        }
        return out
    }

    public func json() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: enc.encode(self), as: UTF8.self)) ?? "{}"
    }

    /// Reads both ends. `includeQuest` = false skips adb (fast path for frequent UI refreshes).
    public static func collect(serial: String? = nil, includeQuest: Bool = true) -> LinkStatus {
        var s = LinkStatus()
        let p = MacNet.primary()
        s.macPrimaryInterface = p.interface
        s.macRouter = p.router
        s.sharing = PF.isSharing
        guard let dev = USB.questDevices().first else { return s }
        s.usbPresent = true
        s.productName = dev.productName
        s.serial = dev.serial
        s.productID = dev.productID
        s.composition = dev.compositionName
        s.accessoryBlocked = dev.looksAccessoryBlocked
        s.usbLinkSpeedBps = dev.linkSpeedBps
        if let ifn = dev.ncmBSDName {
            s.interface = ifn
            s.interfaceUp = MacNet.isUpRunning(ifn)
            let props = USB.ncmControllerProperties(bsdName: ifn)
            s.linkActive = (props["IOLinkStatus"] as? NSNumber)?.intValue == 3
            s.macIPv4 = MacNet.ipv4(of: ifn)
        }
        if s.accessoryBlocked { s.state = .blocked }
        else if s.interface != nil { s.state = s.sharing ? .sharing : .up }
        else if dev.hasNCMFunction { s.state = .unnamed }
        else { s.state = .defaultMode }

        guard includeQuest else { return s }
        guard var adb = try? ADB(serial: serial) else { s.adbState = "missing"; return s }
        s.adbState = adb.state(of: dev.serial) ?? "absent"
        guard (try? adb.resolve(usbSerial: dev.serial)) != nil else { return s }
        s.adbAvailable = true
        let q = Quest(adb: adb)
        s.questIPv4 = (try? q.ipv4()) ?? nil
        if let e = try? q.ethernetState() { s.questCableValidated = e.validated; s.questCableDefault = e.isDefault }
        s.modeAHolders = (try? q.modeAHolders()) ?? []
        return s
    }
}
