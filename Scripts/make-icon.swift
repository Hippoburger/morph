// Draws Resources/AppIcon.icns: the convert arrows on an indigo-to-purple squircle.
//   swift Scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // Apple's grid: the shape fills 824 of 1024 with a 185.4 corner radius.
    let inset = s * 100 / 1024, rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: s * 185.4 / 1024, yRadius: s * 185.4 / 1024)
    NSGradient(colors: [NSColor(red: 0.36, green: 0.35, blue: 0.95, alpha: 1), NSColor(red: 0.72, green: 0.29, blue: 0.93, alpha: 1)])!
        .draw(in: shape, angle: -45)
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold).applying(.init(paletteColors: [.white]))
    let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    symbol.draw(in: NSRect(x: (s - symbol.size.width) / 2, y: (s - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! draw(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try! draw(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print("wrote Resources/AppIcon.icns")
