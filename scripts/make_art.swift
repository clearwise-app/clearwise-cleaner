// Draws the project art in the app's colours.
// Usage: swift scripts/make_art.swift banner <icon.png> <screenshot> <out.jpg>   (2560×1280: README header, social preview)
//        swift scripts/make_art.swift dmg <out.png> <scale>                       (660×400 pt: DMG window background)
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}

/// Renders into a bitmap `w×h` pixels with a top-left origin, so layout reads top to bottom.
func render(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
    ctx.cgContext.translateBy(x: 0, y: CGFloat(h))
    ctx.cgContext.scaleBy(x: 1, y: -1)
    draw(ctx.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func text(_ s: String, _ font: NSFont, _ c: NSColor, kern: CGFloat = 0) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c, .kern: kern])
}

/// Text filled with a left-to-right gradient (drawn through a mask of the glyphs).
func drawGradientText(_ s: String, _ font: NSFont, at p: CGPoint, _ colors: [NSColor], in ctx: CGContext) -> CGSize {
    let str = text(s, font, .white, kern: -2)
    let size = str.size()
    let mask = render(Int(ceil(size.width)), Int(ceil(size.height))) { _ in str.draw(at: .zero) }
    ctx.saveGState()
    // The mask is drawn upright in the flipped context.
    ctx.translateBy(x: p.x, y: p.y + size.height)
    ctx.scaleBy(x: 1, y: -1)
    let rect = CGRect(origin: .zero, size: size)
    ctx.clip(to: rect, mask: mask.cgImage!)
    let g = CGGradient(colorsSpace: nil, colors: colors.map(\.cgColor) as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: 0), options: [])
    ctx.restoreGState()
    return size
}

func glow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, _ c: NSColor) {
    let g = CGGradient(colorsSpace: nil, colors: [c.cgColor, c.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

func save(_ rep: NSBitmapImageRep, _ path: String, jpeg: Bool) {
    let data = jpeg ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])!
                    : rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

func banner(icon: NSImage, shot: NSImage, out: String) {
    let W: CGFloat = 2560, H: CGFloat = 1280
    let rep = render(Int(W), Int(H)) { ctx in
        let bg = CGGradient(colorsSpace: nil, colors: [color(0x0E0624).cgColor, color(0x23105E).cgColor,
                                                       color(0x3A1062).cgColor] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: W, y: H), options: [])
        glow(ctx, center: CGPoint(x: 380, y: 300), radius: 900, color(0x55209A, 0.55))
        glow(ctx, center: CGPoint(x: 2100, y: 1150), radius: 1000, color(0x86226C, 0.55))

        // Left column: icon, name, tagline, three promises.
        let x: CGFloat = 170
        var y: CGFloat = 230
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 24), blur: 60, color: color(0x000000, 0.45).cgColor)
        icon.draw(in: CGRect(x: x - 22, y: y - 22, width: 264, height: 264), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        ctx.restoreGState()
        y += 270
        let titleFont = rounded(150, .heavy)
        _ = drawGradientText("Clearwise", titleFont, at: CGPoint(x: x - 6, y: y), [color(0xC27BFF), color(0xFF5FAE)], in: ctx)
        y += 168
        text("Cleaner", rounded(150, .medium), .white, kern: -2).draw(at: CGPoint(x: x - 6, y: y))
        y += 215
        let tagline = rounded(46, .regular)
        text("Аккуратная очистка Mac: мусор, старые", tagline, color(0xFFFFFF, 0.78)).draw(at: CGPoint(x: x, y: y))
        y += 62
        text("файлы и приложения со всеми следами", tagline, color(0xFFFFFF, 0.78)).draw(at: CGPoint(x: x, y: y))
        y += 110
        var cx = x
        for chip in ["Всё — в Корзину", "Без интернета", "macOS 15+"] {
            let s = text(chip, rounded(34, .semibold), .white)
            let r = CGRect(x: cx, y: y, width: s.size().width + 56, height: 72)
            let path = NSBezierPath(roundedRect: r, xRadius: 36, yRadius: 36)
            color(0xFFFFFF, 0.10).setFill(); path.fill()
            color(0xFFFFFF, 0.18).setStroke(); path.lineWidth = 2; path.stroke()
            s.draw(at: CGPoint(x: r.minX + 28, y: r.midY - s.size().height / 2))
            cx = r.maxX + 20
        }

        // Right: the app itself, bleeding off the edge.
        let sw: CGFloat = 1540, sh = sw * shot.size.height / shot.size.width
        let frame = CGRect(x: 1180, y: (H - sh) / 2, width: sw, height: sh)
        let clip = NSBezierPath(roundedRect: frame, xRadius: 30, yRadius: 30)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 40), blur: 120, color: color(0x000000, 0.6).cgColor)
        color(0x12082B).setFill(); clip.fill()
        ctx.restoreGState()
        ctx.saveGState()
        clip.addClip()
        shot.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        ctx.restoreGState()
        color(0xFFFFFF, 0.14).setStroke(); clip.lineWidth = 3; clip.stroke()
    }
    save(rep, out, jpeg: true)
}

/// Light, so Finder's dark icon labels stay readable. App icon sits at (165, 205), Applications at (495, 205).
func dmgBackground(out: String, scale: CGFloat) {
    let W: CGFloat = 660, H: CGFloat = 400
    let rep = render(Int(W * scale), Int(H * scale)) { ctx in
        ctx.scaleBy(x: scale, y: scale)
        let bg = CGGradient(colorsSpace: nil, colors: [color(0xFBF7FF).cgColor, color(0xF3E9FF).cgColor,
                                                       color(0xFCE8F4).cgColor] as CFArray, locations: [0, 0.6, 1])!
        ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: W, y: H), options: [])
        glow(ctx, center: CGPoint(x: 120, y: 60), radius: 260, color(0xC27BFF, 0.16))
        glow(ctx, center: CGPoint(x: 600, y: 380), radius: 300, color(0xFF5FAE, 0.14))

        let title = text("Перетащите Clearwise Cleaner в Программы", rounded(17, .semibold), color(0x3A1062))
        title.draw(at: CGPoint(x: (W - title.size().width) / 2, y: 46))
        let hint = text("Первый запуск: Системные настройки → Конфиденциальность и безопасность → «Всё равно открыть»",
                        rounded(10.5, .regular), color(0x3A1062, 0.6))
        hint.draw(at: CGPoint(x: (W - hint.size().width) / 2, y: 346))

        // Arrow between the two icons.
        let arrow = NSBezierPath()
        arrow.move(to: CGPoint(x: 262, y: 205))
        arrow.curve(to: CGPoint(x: 384, y: 201), controlPoint1: CGPoint(x: 300, y: 178), controlPoint2: CGPoint(x: 350, y: 178))
        arrow.lineWidth = 3.5
        arrow.lineCapStyle = .round
        arrow.setLineDash([1, 9], count: 2, phase: 0)
        color(0xB45CE6).setStroke(); arrow.stroke()
        let head = NSBezierPath()
        // A chevron along the curve's end direction (≈ 35° down-right).
        head.move(to: CGPoint(x: 386, y: 191)); head.line(to: CGPoint(x: 392, y: 207)); head.line(to: CGPoint(x: 375, y: 207))
        head.lineWidth = 3.5; head.lineCapStyle = .round; head.lineJoinStyle = .round
        color(0xD55BC4).setStroke(); head.stroke()
    }
    save(rep, out, jpeg: false)
}

let args = CommandLine.arguments
switch args.dropFirst().first {
case "banner" where args.count == 5:
    banner(icon: NSImage(contentsOfFile: args[2])!, shot: NSImage(contentsOfFile: args[3])!, out: args[4])
case "dmg" where args.count == 4:
    dmgBackground(out: args[2], scale: CGFloat(Double(args[3]) ?? 1))
default:
    FileHandle.standardError.write("usage: make_art.swift banner <icon.png> <screenshot> <out.jpg> | dmg <out.png> <scale>\n".data(using: .utf8)!)
    exit(1)
}
