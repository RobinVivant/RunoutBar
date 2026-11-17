// Draws the app icon (four level bars on a dark squircle) and writes Resources/AppIcon.icns.
// Run: swift scripts/make-icon.swift
import AppKit

let colors: [NSColor] = ["#0a84ff", "#bf5af2", "#30d1b2", "#ff6482"].map { hex in
    let v = UInt64(hex.dropFirst(), radix: 16)!
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}
let levels: [CGFloat] = [0.55, 0.3, 0.8, 0.45]

func icon(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(starting: NSColor(white: 0.2, alpha: 1), ending: NSColor(white: 0.07, alpha: 1))!.draw(in: shape, angle: -90)
    NSColor(white: 1, alpha: 0.08).setStroke()
    shape.lineWidth = s * 0.004
    shape.stroke()

    let barWidth = tile.width * 0.12, gap = tile.width * 0.07
    let total = barWidth * 4 + gap * 3
    var x = tile.midX - total / 2
    let bottom = tile.minY + tile.height * 0.2, height = tile.height * 0.58
    for (color, level) in zip(colors, levels) {
        let track = NSBezierPath(roundedRect: NSRect(x: x, y: bottom, width: barWidth, height: height),
                                 xRadius: barWidth / 2, yRadius: barWidth / 2)
        NSColor(white: 1, alpha: 0.12).setFill()
        track.fill()
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        NSGradient(starting: color.blended(withFraction: 0.25, of: .white)!, ending: color)!
            .draw(in: NSRect(x: x, y: bottom, width: barWidth, height: height * level), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        x += barWidth + gap
    }
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: tile.midX - total / 2 + barWidth / 2 - tile.width * 0.022,
                                y: tile.minY + tile.height * 0.1, width: tile.width * 0.044,
                                height: tile.width * 0.044)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try! icon(size * scale).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
