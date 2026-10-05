import Foundation

public enum LinkError: Error, CustomStringConvertible {
    case stage(String, String)
    public var description: String {
        if case let .stage(stage, msg) = self { return "[\(stage)] \(msg)" }
        return ""
    }
}

public struct LinkOptions {
    public var plan = LinkPlan()
    public var share = false
    public var dns = ["1.1.1.1"]
    public var serial: String?
    public var forceStopModeA = false
    public init() {}
}

public struct Link {
    public var log: (String) -> Void
    public init(log: @escaping (String) -> Void = { print($0) }) { self.log = log }

    func poll<T>(_ seconds: Double, interval: Double = 0.5, _ body: () throws -> T?) rethrows -> T? {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if let v = try body() { return v }
            Thread.sleep(forTimeInterval: interval)
        } while Date() < end
        return nil
    }

    func questDevice() -> QuestUSBDevice? { USB.questDevices().first }

    /// Waits while macOS blocks a new composition behind the "Allow accessory to connect?" prompt.
    func awaitAccessoryApproval() throws -> QuestUSBDevice {
        guard var dev = questDevice() else { throw LinkError.stage("usb", "no Quest (VID 0x2833) attached") }
        if dev.looksAccessoryBlocked {
            log("[usb ] macOS is blocking this USB mode: unlock the Mac and click Allow on the accessory prompt (waiting 120 s)")
            guard let d = poll(120, interval: 1, { () -> QuestUSBDevice? in
                guard let d = questDevice(), !d.looksAccessoryBlocked else { return nil }
                return d
            }) else { throw LinkError.stage("usb", "still blocked; replug the cable while the Mac is unlocked") }
            dev = d
        }
        return dev
    }

    public func up(_ o: LinkOptions) throws {
        let plan = o.plan
        var dev = try awaitAccessoryApproval()
        log("[usb ] \(dev.productName) serial \(dev.serial), pid \(String(format: "0x%04x", dev.productID)) (\(dev.compositionName))")

        var adb = try ADB(serial: o.serial)
        try adb.resolve(usbSerial: dev.serial, waitForAuthorization: 120, onWait: log)
        let quest = Quest(adb: adb)

        let holders = try quest.modeAHolders()
        if !holders.isEmpty {
            guard o.forceStopModeA else {
                throw LinkError.stage("quest", "apps hold Meta's USB network (pre-empts this mode): \(holders.joined(separator: ", ")). Close them or pass --force-stop-holders")
            }
            for p in holders where p != "android" { try adb.shell("am force-stop \(p)") }
        }

        if !dev.hasNCMFunction {
            log("[usb ] switching Quest to NCM (svc usb setFunctions ncm)")
            try quest.setFunctionsNCM()
            Thread.sleep(forTimeInterval: 1.5)
            guard poll(20, { questDevice().flatMap { $0.hasNCMFunction || $0.looksAccessoryBlocked ? $0 : nil } }) != nil else {
                throw LinkError.stage("usb", "Quest did not re-enumerate with an NCM function")
            }
            dev = try awaitAccessoryApproval()
            log("[usb ] re-enumerated: pid \(String(format: "0x%04x", dev.productID)) (\(dev.compositionName))")
        }

        guard let ifname = poll(10, { questDevice()?.ncmBSDName }) else {
            throw LinkError.stage("name", "AppleUSBNCM bound but no network interface was named. If the Mac was locked when the Quest attached, unlock and replug.")
        }
        dev = questDevice() ?? dev
        log("[if  ] \(ifname) via \(dev.ncmDriverClass ?? "AppleUSBNCM")")

        try MacNet.checkSubnetFree(plan, except: ifname)
        let before = MacNet.primary()
        let svc = try MacNet.ensureService(device: ifname, plan: plan)
        log("[svc ] '\(svc)': manual \(plan.macHost)/\(plan.prefixLength), no router")

        guard poll(10, { MacNet.isUpRunning(ifname) && MacNet.ipv4(of: ifname) == plan.macHost ? true : nil }) != nil else {
            throw LinkError.stage("mac", "\(ifname) did not come up with \(plan.macHost)")
        }

        let current = try quest.ipv4()
        if o.share || current != plan.questCIDR {
            try quest.setStatic(cidr: plan.questCIDR,
                                gateway: o.share ? plan.macHost : nil,
                                dns: o.share ? o.dns : [])
            log("[addr] Quest usb0 static \(plan.questCIDR)\(o.share ? " gw \(plan.macHost) dns \(o.dns.joined(separator: ","))" : "")")
        } else {
            log("[addr] Quest usb0 already \(plan.questCIDR)")
        }

        guard poll(15, interval: 1, { ping(ifname, plan.questHost, count: 1) ? true : nil }) != nil else {
            throw LinkError.stage("reach", "\(plan.questHost) does not answer on \(ifname)")
        }
        let after = MacNet.primary()
        guard after.interface == before.interface, after.router == before.router else {
            throw LinkError.stage("route", "Mac primary changed (\(before.interface ?? "-") -> \(after.interface ?? "-")); check the '\(svc)' service has no router")
        }
        log("[safe] Mac default route unchanged (\(after.interface ?? "none"))")

        if o.share {
            guard let egress = after.interface, egress != ifname else {
                throw LinkError.stage("share", "no usable egress interface for NAT")
            }
            let token = try PF.enable(egress: egress, plan: plan)
            log("[nat ] \(PF.anchor): \(plan.subnetCIDR) -> \(egress) (pf token \(token))")
            let ok = poll(45, interval: 3) { () -> Bool? in
                guard let s = try? quest.ethernetState() else { return nil }
                return s.validated && s.isDefault ? true : nil
            }
            log(ok != nil ? "[nat ] Quest validated the cable and made it its default network"
                          : "[nat ] warning: Quest has not validated the cable yet (VPN/filter on the Mac?)")
        }
        log("LINK UP if=\(ifname) mac=\(plan.macHost) quest=\(plan.questHost) share=\(o.share ? "on" : "off")")
    }

    public func shareOff(_ o: LinkOptions) throws {
        try PF.disable()
        log("[nat ] anchor flushed, pf token released")
        if var adb = try? ADB(serial: o.serial), (try? adb.resolve(usbSerial: questDevice()?.serial)) != nil {
            try Quest(adb: adb).setStatic(cidr: o.plan.questCIDR)
            log("[addr] Quest usb0 static \(o.plan.questCIDR) (gateway and DNS removed)")
        }
    }

    public func down(_ o: LinkOptions, keepQuestConfig: Bool) throws {
        if Shell.isRoot { try PF.disable(); log("[nat ] released") }
        else { log("[nat ] skipped (not root); run `sudo mqncm share off` if sharing was on") }
        guard !keepQuestConfig else { return }
        var adb = try ADB(serial: o.serial)
        try adb.resolve(usbSerial: questDevice()?.serial)
        try Quest(adb: adb).setDHCP()
        log("[addr] Quest usb0 back to dhcp. Replug the cable to return the Quest to its default USB mode.")
    }

    public func status(serial: String?) {
        LinkStatus.collect(serial: serial).lines.forEach(log)
    }

    /// Returns the Quest to its default USB mode (Link, MTP, Meta vendor interfaces). Android restores the
    /// screen-unlocked default when setFunctions is called with no argument; if the Quest does not
    /// re-enumerate without NCM, the reliable fallback is a replug.
    public func restoreUSB(_ o: LinkOptions) throws {
        guard let dev = questDevice() else { throw LinkError.stage("usb", "no Quest attached") }
        guard dev.hasNCMFunction else { log("[usb ] already in default USB mode"); return }
        var adb = try ADB(serial: o.serial)
        try adb.resolve(usbSerial: dev.serial)
        let r = try adb.shell("svc usb setFunctions")
        guard r.ok || r.combined.contains("setCurrentFunctions") else { throw ADBError.command("svc usb setFunctions", r.combined) }
        Thread.sleep(forTimeInterval: 1.5)
        if let d = poll(15, { questDevice().flatMap { !$0.hasNCMFunction && !$0.looksAccessoryBlocked ? $0 : nil } }) {
            log("[usb ] restored: pid \(String(format: "0x%04x", d.productID)) (\(d.compositionName))")
        } else {
            throw LinkError.stage("usb", "Quest did not leave NCM mode; replug the cable to restore its default USB mode")
        }
    }
}

/// One ICMP probe bound to `iface` (so it can't silently go over Wi-Fi or a VPN).
public func ping(_ iface: String, _ host: String, count: Int, interval: Double = 1) -> Bool {
    (try? Shell.run("/sbin/ping", ["-b", iface, "-c", "\(count)", "-t", "\(max(2, count))", "-q", host]))?.ok ?? false
}
