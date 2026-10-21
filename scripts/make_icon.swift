// Draws the MacCleaner app icon at every size into an .iconset folder.
// Usage: swift scripts/make_icon.swift <output.iconset>
// The glyph is drawn with plain bezier paths (no SF Symbols — those may not be used in app icons).
import AppKit

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write("usage: make_icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(1)
}
let out = URL(fileURLWithPath: args[1])
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Four-pointed sparkle centred at `c` with outer radius `r`.
func sparkle(_ c: CGPoint, _ r: CGFloat, pinch: CGFloat = 0.16) -> NSBezierPath {
    let p = NSBezierPath()
    let k = r * pinch
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.curve(to: CGPoint(x: c.x + r, y: c.y), controlPoint1: CGPoint(x: c.x + k, y: c.y + k), controlPoint2: CGPoint(x: c.x + k, y: c.y + k))
    p.curve(to: CGPoint(x: c.x, y: c.y - r), controlPoint1: CGPoint(x: c.x + k, y: c.y - k), controlPoint2: CGPoint(x: c.x + k, y: c.y - k))
    p.curve(to: CGPoint(x: c.x - r, y: c.y), controlPoint1: CGPoint(x: c.x - k, y: c.y - k), controlPoint2: CGPoint(x: c.x - k, y: c.y - k))
    p.curve(to: CGPoint(x: c.x, y: c.y + r), controlPoint1: CGPoint(x: c.x - k, y: c.y + k), controlPoint2: CGPoint(x: c.x - k, y: c.y + k))
    p.close()
    return p
}

func drawIcon(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.setShouldAntialias(true)

    // macOS icon grid: 824×824 body centred in 1024, continuous-ish corners.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    color(0x2A0F5C).setFill()
    shape.fill()
    ctx.restoreGState()

    // Background gradient: deep violet → magenta
    ctx.saveGState()
    shape.addClip()
    NSGradient(colors: [color(0x2B0D63), color(0x6A22B8), color(0xD14FA8)], atLocations: [0, 0.55, 1],
               colorSpace: .sRGB)!.draw(in: body, angle: -55)
    // Soft glow behind the glyph
    NSGradient(colors: [color(0xFFB8F0, 0.55), color(0xC27BFF, 0.0)])!
        .draw(fromCenter: CGPoint(x: 500, y: 480), radius: 0, toCenter: CGPoint(x: 500, y: 480), radius: 380, options: [])
    // Top gloss
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    ctx.restoreGState()

    // Inner rim
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
    rim.lineWidth = 6
    NSColor.white.withAlphaComponent(0.22).setStroke()
    rim.stroke()

    // Sparkles
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x3A0A60, 0.55).cgColor)
    let big = sparkle(CGPoint(x: 470, y: 470), 250)
    NSGradient(colors: [NSColor.white, color(0xFFE3F6)])!.draw(in: big, angle: -90)
    NSColor.white.setFill()
    sparkle(CGPoint(x: 690, y: 700), 105, pinch: 0.18).fill()
    sparkle(CGPoint(x: 700, y: 300), 62, pinch: 0.2).fill()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    let data = drawIcon(px: px).representation(using: .png, properties: [:])!
    try data.write(to: out.appendingPathComponent(name + ".png"))
}
print("iconset:", out.path)
