// Draws the README banner and the social preview image from the app icon.
// Run: swift scripts/make-brand.swift
// Writes docs/banner.png (1600 x 440, shown 800 wide) and docs/social-preview.png (1280 x 640).
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let name = "Runout Bar"
let tagline = "Claude and Codex limits in your menu bar"
let palette = ["#0a84ff", "#bf5af2", "#30d1b2", "#ff6482"].map(color)
/// Filled segments out of 20 for each row of the decoration, one row per account color.
let fills = [14, 7, 17, 4]

func color(_ hex: String) -> NSColor {
    let v = UInt64(hex.dropFirst(), radix: 16)!
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}

func text(_ string: String, _ font: NSFont, alpha: CGFloat = 1, tracking: CGFloat = 0) -> NSAttributedString {
    NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(white: 1, alpha: alpha),
                                                    .kern: tracking])
}

/// The app icon without the transparent margin the icon grid leaves around the tile.
func drawIcon(_ icon: NSImage, in rect: NSRect) {
    let margin = rect.width * 0.1 / 0.8
    icon.draw(in: rect.insetBy(dx: -margin, dy: -margin))
}

/// Rows of segmented level bars, as the account rows in the popover draw them.
func drawBars(at origin: NSPoint, segment: CGFloat, gap: CGFloat, rowGap: CGFloat) {
    for (row, fill) in fills.enumerated() {
        let y = origin.y - CGFloat(row) * (segment + rowGap)
        for index in 0..<20 {
            let rect = NSRect(x: origin.x + CGFloat(index) * (segment + gap), y: y, width: segment, height: segment)
            (index < fill ? palette[row] : NSColor(white: 1, alpha: 0.09)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: segment * 0.28, yRadius: segment * 0.28).fill()
        }
    }
}

func barsSize(segment: CGFloat, gap: CGFloat, rowGap: CGFloat) -> NSSize {
    NSSize(width: segment * 20 + gap * 19, height: segment * CGFloat(fills.count) + rowGap * CGFloat(fills.count - 1))
}

func canvas(_ width: Int, _ height: Int, radius: CGFloat, _ draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    let inset: CGFloat = radius > 0 ? 1 : 0  // room for the border of the rounded card
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
    NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1),
               ending: NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1))!.draw(in: shape, angle: -70)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // Two soft glows in the account colors, so the card is not a flat grey.
    for (glow, center) in [(palette[0], NSPoint(x: bounds.width * 0.08, y: bounds.height * 1.05)),
                           (palette[1], NSPoint(x: bounds.width * 0.98, y: -bounds.height * 0.1))] {
        NSGradient(starting: glow.withAlphaComponent(0.22), ending: glow.withAlphaComponent(0))!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: bounds.width * 0.42, options: [])
    }
    NSGraphicsContext.restoreGraphicsState()
    if radius > 0 {
        NSColor(white: 1, alpha: 0.1).setStroke()
        shape.lineWidth = 2
        shape.stroke()
    }
    draw(bounds)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

guard let icon = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns")) else {
    print("Resources/AppIcon.icns is missing: run swift scripts/make-icon.swift first")
    exit(1)
}

// README banner: icon, name and tagline on the left, level bars on the right.
let banner = canvas(1600, 440, radius: 44) { bounds in
    let tile: CGFloat = 196
    drawIcon(icon, in: NSRect(x: 96, y: bounds.midY - tile / 2, width: tile, height: tile))
    let title = text(name, rounded(104, .bold), tracking: -1)
    let sub = text(tagline, rounded(35, .medium), alpha: 0.62)
    let left = 96 + tile + 56
    let block = title.size().height + sub.size().height - 6
    title.draw(at: NSPoint(x: left, y: bounds.midY + block / 2 - title.size().height))
    sub.draw(at: NSPoint(x: left + 4, y: bounds.midY - block / 2))
    let size = barsSize(segment: 15, gap: 6, rowGap: 26)
    drawBars(at: NSPoint(x: bounds.maxX - 96 - size.width, y: bounds.midY + size.height / 2 - 15), segment: 15, gap: 6,
             rowGap: 26)
}

// Social preview: the same parts stacked and centered, with no transparent corners.
let social = canvas(1280, 640, radius: 0) { bounds in
    let tile: CGFloat = 176
    let title = text(name, rounded(96, .bold), tracking: -1)
    let sub = text(tagline, rounded(34, .medium), alpha: 0.62)
    let size = barsSize(segment: 16, gap: 7, rowGap: 14)
    var y = bounds.midY + (tile + 22 + title.size().height + sub.size().height + 44 + size.height) / 2
    y -= tile
    drawIcon(icon, in: NSRect(x: bounds.midX - tile / 2, y: y, width: tile, height: tile))
    y -= 22 + title.size().height
    title.draw(at: NSPoint(x: bounds.midX - title.size().width / 2, y: y))
    y -= sub.size().height
    sub.draw(at: NSPoint(x: bounds.midX - sub.size().width / 2, y: y))
    y -= 44 + 16
    drawBars(at: NSPoint(x: bounds.midX - size.width / 2, y: y), segment: 16, gap: 7, rowGap: 14)
}

for (rep, file) in [(banner, "docs/banner.png"), (social, "docs/social-preview.png")] {
    let url = root.appendingPathComponent(file)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("Wrote \(url.path)")
}
