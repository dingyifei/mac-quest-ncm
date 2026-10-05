import Foundation
import IOKit

/// Meta / Oculus USB vendor ID.
public let questVendorID = 0x2833

public struct QuestUSBDevice {
    public let productID: Int
    public let serial: String
    public let productName: String
    /// (class, subclass, protocol) of every interface the Mac has published for this device.
    public let interfaces: [(Int, Int, Int)]
    /// BSD name of the network interface AppleUSBNCM created for this device, if any.
    public let ncmBSDName: String?
    public let ncmDriverClass: String?
    /// Negotiated USB signalling rate in bit/s (480_000_000 = USB 2 high speed, 5_000_000_000 = USB 3 Gen 1).
    public let linkSpeedBps: Int?

    public var hasNCMFunction: Bool { interfaces.contains { $0.0 == 2 && $0.1 == 13 } }
    /// Device enumerated but macOS published no interfaces: the accessory-approval (TRM) gate.
    public var looksAccessoryBlocked: Bool { interfaces.isEmpty }

    public var compositionName: String {
        switch productID {
        case 0x5009: return "ncm"
        case 0x500A: return "ncm+adb"
        case 0x5017: return "xrsp+ncm"
        case 0x5018: return "xrsp+ncm+adb"
        default: return hasNCMFunction ? "ncm (pid \(String(format: "0x%04x", productID)))" : "default (no ncm)"
        }
    }
}

enum Registry {
    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func intProperty(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        (property(entry, key) as? NSNumber)?.intValue
    }

    static func className(_ entry: io_registry_entry_t) -> String {
        var name = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(entry, &name)
        return String(cString: name)
    }

    /// Calls `body` for every registry entry below `entry` in the service plane.
    static func walk(_ entry: io_registry_entry_t, _ body: (io_registry_entry_t) -> Void) {
        var it: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(entry, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while case let child = IOIteratorNext(it), child != 0 {
            body(child)
            IOObjectRelease(child)
        }
    }
}

public enum USB {
    /// IOUSBHostDevice "USBSpeed" enum → bit/s (fallback when "UsbLinkSpeed" is absent).
    public static func bitsPerSecond(usbSpeed: Int) -> Int? {
        switch usbSpeed {
        case 1: return 1_500_000
        case 2: return 12_000_000
        case 3: return 480_000_000
        case 4: return 5_000_000_000
        case 5: return 10_000_000_000
        case 6: return 20_000_000_000
        default: return nil
        }
    }

    public static func describe(bitsPerSecond bps: Int) -> String {
        bps >= 1_000_000_000 ? "\(bps / 1_000_000_000) Gb/s" : "\(bps / 1_000_000) Mb/s"
    }

    /// All attached Quest devices (VID 0x2833), with interfaces and NCM binding read from the IORegistry.
    public static func questDevices() -> [QuestUSBDevice] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }

        var result: [QuestUSBDevice] = []
        while case let dev = IOIteratorNext(it), dev != 0 {
            defer { IOObjectRelease(dev) }
            guard Registry.intProperty(dev, "idVendor") == questVendorID else { continue }
            let pid = Registry.intProperty(dev, "idProduct") ?? 0
            let serial = (Registry.property(dev, "kUSBSerialNumberString") ?? Registry.property(dev, "USB Serial Number")) as? String ?? ""
            let name = (Registry.property(dev, "kUSBProductString") ?? Registry.property(dev, "USB Product Name")) as? String ?? "Quest"
            let speed = Registry.intProperty(dev, "UsbLinkSpeed") ?? Registry.intProperty(dev, "USBSpeed").flatMap(USB.bitsPerSecond(usbSpeed:))

            var interfaces: [(Int, Int, Int)] = []
            var bsd: String?
            var driver: String?
            Registry.walk(dev) { entry in
                let cls = Registry.className(entry)
                if cls == "IOUSBHostInterface",
                   let c = Registry.intProperty(entry, "bInterfaceClass") {
                    interfaces.append((c, Registry.intProperty(entry, "bInterfaceSubClass") ?? 0,
                                       Registry.intProperty(entry, "bInterfaceProtocol") ?? 0))
                }
                if cls.hasPrefix("AppleUSBNCM") && cls.contains("Data") { driver = cls }
                if bsd == nil, let b = Registry.property(entry, "BSD Name") as? String, b.hasPrefix("en") { bsd = b }
            }
            result.append(QuestUSBDevice(productID: pid, serial: serial, productName: name,
                                         interfaces: interfaces, ncmBSDName: bsd, ncmDriverClass: driver,
                                         linkSpeedBps: speed))
        }
        return result
    }

    /// AppleUSBNCMData controller properties for a BSD interface (link status, NTB sizes, ...).
    public static func ncmControllerProperties(bsdName: String) -> [String: Any] {
        guard let matching = IOServiceMatching("AppleUSBNCMData") else { return [:] }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(it) }
        while case let svc = IOIteratorNext(it), svc != 0 {
            defer { IOObjectRelease(svc) }
            var found = false
            Registry.walk(svc) { e in if (Registry.property(e, "BSD Name") as? String) == bsdName { found = true } }
            guard found else { continue }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { return [:] }
            return dict
        }
        return [:]
    }
}
