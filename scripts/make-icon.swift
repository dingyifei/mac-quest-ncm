// Renders assets/AppIcon.icns: a rounded tile with a cable glyph. Run: swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let r = NSRect(x: 0, y: 0, width: px, height: px).insetBy(dx: CGFloat(px) * 0.09, dy: CGFloat(px) * 0.09)
    let path = NSBezierPath(roundedRect: r, xRadius: r.width * 0.22, yRadius: r.width * 0.22)
    NSGradient(colors: [NSColor(red: 0.10, green: 0.35, blue: 0.95, alpha: 1), NSColor(red: 0.45, green: 0.15, blue: 0.85, alpha: 1)])!
        .draw(in: path, angle: -60)
    let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "cable.connector.horizontal", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let s = sym.size
        sym.draw(in: NSRect(x: (CGFloat(px) - s.width) / 2, y: (CGFloat(px) - s.height) / 2, width: s.width, height: s.height))
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: "assets/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "assets/AppIcon.icns"]
try p.run(); p.waitUntilExit()
try FileManager.default.removeItem(at: set)
print("wrote assets/AppIcon.icns")
