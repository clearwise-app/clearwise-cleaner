import SwiftUI

/// The centrepiece of the cleaning scene: a glass disc with a sweeping broom, dust flying off each stroke,
/// and a thick gradient progress ring with a glowing leading cap around it.
struct BroomDial: View {
    let tint: ModuleTint
    let fraction: Double
    /// Seconds since the cleanup started; drives the sweep.
    let time: Double
    /// Seconds since the cleanup finished (nil while working): the flourish.
    let finishTime: Double?
    let diameter: CGFloat
    var reduceMotion = false

    private var lineWidth: CGFloat { diameter * 0.05 }
    private var disc: CGFloat { diameter - lineWidth * 2 - diameter * 0.075 }

    var body: some View {
        ZStack {
            // Halo
            Circle()
                .fill(RadialGradient(colors: [tint.accent.opacity(0.38), tint.accent2.opacity(0.14), .clear],
                                     center: .center, startRadius: disc * 0.3, endRadius: diameter * 0.95))
                .frame(width: diameter * 1.9, height: diameter * 1.9)
                .allowsHitTesting(false)

            // Faint orbit outside the ring
            Circle()
                .strokeBorder(.white.opacity(0.06), style: StrokeStyle(lineWidth: 1, dash: [2, 7]))
                .frame(width: diameter + diameter * 0.16, height: diameter + diameter * 0.16)
                .rotationEffect(.degrees(reduceMotion ? 0 : time * 6))

            ring

            discView
        }
        .frame(width: diameter * 1.18, height: diameter * 1.18)
    }

    // MARK: Ring

    private var ring: some View {
        let value = max(0, min(1, fraction))
        let r = (diameter - lineWidth) / 2
        let angle = Angle.degrees(360 * value - 90)
        return ZStack {
            Circle()
                .stroke(.white.opacity(0.09), lineWidth: lineWidth)
            Circle()
                .stroke(.black.opacity(0.18), lineWidth: 1)
                .padding(lineWidth / 2)
                .blur(radius: 1)

            Circle()
                .trim(from: 0, to: max(0.001, value))
                .stroke(value >= 0.999
                        // Closed ring: a seamless loop instead of a dark-to-bright arc.
                        ? AngularGradient(colors: [tint.accent, tint.accent2, Color.white.opacity(0.9), tint.accent2, tint.accent],
                                          center: .center)
                        : AngularGradient(colors: [tint.accent2.opacity(0.85), tint.accent, Color.white.opacity(0.95)],
                                          center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(0.02, value))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.accent.opacity(0.75), radius: lineWidth * 0.7)
                .opacity(value > 0 ? 1 : 0)

            // Glowing leading cap
            if value > 0.004 && value < 0.999 {
                ZStack {
                    Circle().fill(.white.opacity(0.35)).frame(width: lineWidth * 2.1, height: lineWidth * 2.1).blur(radius: lineWidth * 0.5)
                    Circle().fill(.white).frame(width: lineWidth * 0.95, height: lineWidth * 0.95)
                        .shadow(color: tint.accent, radius: lineWidth * 0.6)
                }
                .offset(x: cos(angle.radians) * r, y: sin(angle.radians) * r)
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(.easeOut(duration: 0.35), value: value)
    }

    // MARK: Disc

    private var discView: some View {
        let pulse = reduceMotion && finishTime == nil ? 1 + 0.025 * sin(time * 2 * .pi / 2.6) : 1
        return ZStack {
            Circle()
                .fill(LinearGradient(colors: [tint.accent2.opacity(0.42), tint.mesh[4].opacity(0.9), .black.opacity(0.55)],
                                     startPoint: .top, endPoint: .bottom))
            Circle()
                .fill(RadialGradient(colors: [tint.accent.opacity(0.35), .clear],
                                     center: .init(x: 0.5, y: 0.78), startRadius: 0, endRadius: disc * 0.55))
            Canvas { ctx, size in
                BroomRenderer(tint: tint, time: time, finishTime: finishTime, still: reduceMotion)
                    .draw(in: &ctx, size: size)
            }
            .clipShape(Circle())
            // Gloss
            Circle()
                .fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.02), .clear],
                                     startPoint: .top, endPoint: .center))
                .padding(disc * 0.025)
                .allowsHitTesting(false)
            Circle()
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.06), .white.opacity(0.18)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1.25)

            if let ft = finishTime {
                DoneBadge(tint: tint, size: disc * 0.24)
                    .scaleEffect(Self.pop(ft - 0.35))
                    .opacity(min(1, max(0, (ft - 0.35) * 6)))
                    .offset(x: disc * 0.26, y: disc * 0.27)
            }
        }
        .frame(width: disc, height: disc)
        .scaleEffect(pulse)
        .shadow(color: .black.opacity(0.4), radius: 24, y: 14)
    }

    /// Overshooting pop-in, 0 before the start.
    static func pop(_ t: Double) -> Double {
        guard t > 0 else { return 0.001 }
        let x = min(1, t / 0.4)
        return max(0.001, sin(x * .pi / 2) * (1 + 0.22 * sin(x * .pi)))
    }
}

private struct DoneBadge: View {
    let tint: ModuleTint
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Theme.success, Color(hex: 0x1FB874)], startPoint: .top, endPoint: .bottom))
            Circle().fill(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center))
            Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.25)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.success.opacity(0.6), radius: size * 0.3)
    }
}

// MARK: - Broom

/// Draws the broom, its shadow on the "floor", dust and sparkles for a given moment.
/// Pure function of time, so snapshots can freeze any phase.
struct BroomRenderer {
    let tint: ModuleTint
    let time: Double
    let finishTime: Double?
    var still = false

    static let period = 1.15
    /// Rest pose: handle leaning right, bristles bottom-left — the classic broom silhouette.
    static let rest = 20.0
    static let amplitude = 15.0

    private let straw = [Color(hex: 0xFFE7A6), Color(hex: 0xF7C25A), Color(hex: 0xDE8F2E)]
    private let strawDark = Color(hex: 0x9A5A17)
    private let woodLight = Color(hex: 0xFFF1DC)
    private let wood = Color(hex: 0xE0AC72)
    private let woodDark = Color(hex: 0xA86A39)

    /// Angle in degrees and bristle flex (−1…1, positive bends the tips right).
    func pose() -> (angle: Double, flex: Double, scale: Double) {
        if let ft = finishTime {
            // Flourish: one big flick that settles back, with a little bounce in size.
            let decay = exp(-ft * 2.6)
            let flick = sin(ft * 2 * .pi / 0.85) * decay
            let angle = Self.rest - 30 * flick
            let flex = 0.9 * cos(ft * 2 * .pi / 0.85) * decay
            let scale = 1 + 0.07 * sin(min(1, ft / 0.6) * .pi)
            return (angle, flex, scale)
        }
        if still { return (Self.rest, 0, 1) }
        let w = 2 * Double.pi / Self.period
        let angle = Self.rest + Self.amplitude * sin(w * time)
        // Tips trail the motion: when the broom swings left (angle grows), they bend right.
        let flex = 0.75 * cos(w * time)
        return (angle, flex, 1)
    }

    func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let S = min(size.width, size.height)
        let L = S * 0.66
        let pivot = CGPoint(x: size.width * 0.6, y: size.height * 0.17)
        let p = pose()
        let theta = p.angle * .pi / 180
        let tip = CGPoint(x: pivot.x - L * p.scale * sin(theta), y: pivot.y + L * p.scale * cos(theta))

        drawFloor(&ctx, size: size, tip: tip, S: S)
        if !still && finishTime == nil { drawPuffs(&ctx, S: S, pivot: pivot, L: L) }
        if let ft = finishTime { drawBurst(&ctx, size: size, S: S, ft: ft) }

        var broom = ctx
        broom.addFilter(.shadow(color: .black.opacity(0.38), radius: S * 0.03, x: S * 0.012, y: S * 0.03))
        broom.drawLayer { layer in
            layer.translateBy(x: pivot.x, y: pivot.y)
            layer.rotate(by: .radians(theta))
            layer.scaleBy(x: L * p.scale, y: L * p.scale)
            drawBroom(&layer, flex: p.flex * 0.07)
        }

        if !still { drawDust(&ctx, S: S, pivot: pivot, L: L) }
        drawTwinkles(&ctx, size: size, S: S)
    }

    /// Soft dust clouds rising where each stroke hits the floor (under the broom).
    private func drawPuffs(_ ctx: inout GraphicsContext, S: CGFloat, pivot: CGPoint, L: CGFloat) {
        let half = Self.period / 2
        let current = Int(floor(time / half))
        let theta = Self.rest * .pi / 180
        let tip = CGPoint(x: pivot.x - L * sin(theta), y: pivot.y + L * cos(theta))
        var layer = ctx
        layer.addFilter(.blur(radius: S * 0.025))
        for k in max(0, current - 1)...current {
            let age = time - Double(k) * half
            guard age > 0, age < 1.0 else { continue }
            let dir: CGFloat = k.isMultiple(of: 2) ? -1 : 1
            let x = age / 1.0
            for j in 0..<3 {
                let r = S * (0.04 + 0.07 * x) * (1 - CGFloat(j) * 0.2)
                let cx = tip.x + dir * S * (0.06 + 0.16 * x) * (1 + CGFloat(j) * 0.35)
                let cy = tip.y - S * (0.02 + 0.07 * x) * CGFloat(j + 1) * 0.6
                layer.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                           with: .color(Color(hex: 0xFFF2D6).opacity(0.22 * (1 - x))))
            }
        }
    }

    // MARK: Parts

    private func drawFloor(_ ctx: inout GraphicsContext, size: CGSize, tip: CGPoint, S: CGFloat) {
        // Soft contact shadow where the bristles touch the floor.
        let shadow = CGRect(x: tip.x - S * 0.2, y: tip.y - S * 0.03, width: S * 0.4, height: S * 0.07)
        var c = ctx
        c.addFilter(.blur(radius: S * 0.02))
        c.fill(Path(ellipseIn: shadow), with: .color(.black.opacity(0.32)))
        // Floor sheen line.
        let y = tip.y + S * 0.012
        let line = Path(CGRect(x: size.width * 0.08, y: y, width: size.width * 0.84, height: max(1, S * 0.004)))
        ctx.fill(line, with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.16), .white.opacity(0.22), .white.opacity(0.16), .clear]),
                                             startPoint: CGPoint(x: size.width * 0.08, y: y),
                                             endPoint: CGPoint(x: size.width * 0.92, y: y)))
    }

    private func drawBroom(_ c: inout GraphicsContext, flex f: Double) {
        // Bristles: flared trapezoid with bowed sides and a ragged hem; the hem trails the motion by `f`.
        let topY = 0.645, botY = 1.0
        let topW = 0.085, botW = 0.25
        var bristles = Path()
        bristles.move(to: CGPoint(x: -topW, y: topY))
        bristles.addLine(to: CGPoint(x: topW, y: topY))
        bristles.addQuadCurve(to: CGPoint(x: botW + f, y: botY - 0.01),
                              control: CGPoint(x: 0.2 + f * 0.35, y: 0.79))
        let teeth = 16
        for i in 0...teeth {
            let s = Double(i) / Double(teeth)
            let x = (botW + f) - s * 2 * botW
            let bow = 0.018 * (1 - pow(2 * s - 1, 2))
            let y = botY + bow - (i.isMultiple(of: 2) ? 0 : 0.026)
            bristles.addLine(to: CGPoint(x: x, y: y))
        }
        bristles.addQuadCurve(to: CGPoint(x: -topW, y: topY),
                              control: CGPoint(x: -0.2 + f * 0.35, y: 0.79))
        bristles.closeSubpath()
        c.fill(bristles, with: .linearGradient(Gradient(colors: straw),
                                               startPoint: CGPoint(x: 0, y: topY), endPoint: CGPoint(x: 0, y: botY)))
        // Side shading for volume.
        c.fill(bristles, with: .linearGradient(Gradient(stops: [.init(color: .black.opacity(0.18), location: 0),
                                                                 .init(color: .clear, location: 0.35),
                                                                 .init(color: .white.opacity(0.12), location: 0.55),
                                                                 .init(color: .black.opacity(0.22), location: 1)]),
                                               startPoint: CGPoint(x: -botW, y: 0.85), endPoint: CGPoint(x: botW, y: 0.85)))

        // Individual straws.
        let strands = 15
        for i in 0..<strands {
            let s = Double(i) / Double(strands - 1)
            let x0 = -topW * 0.85 + s * topW * 1.7
            let x1 = -botW * 0.92 + s * botW * 1.84 + f
            var strand = Path()
            strand.move(to: CGPoint(x: x0, y: topY + 0.01))
            strand.addQuadCurve(to: CGPoint(x: x1, y: botY - 0.02),
                                control: CGPoint(x: (x0 + x1) / 2 + (s - 0.5) * 0.05 + f * 0.25, y: 0.8))
            let dark = i.isMultiple(of: 2)
            c.stroke(strand, with: .color(dark ? strawDark.opacity(0.45) : .white.opacity(0.32)),
                     style: StrokeStyle(lineWidth: dark ? 0.0065 : 0.0045, lineCap: .round))
        }

        // Stitched band across the straws, in the module colour.
        let bandY = 0.735
        let bandHalf = topW + (botW - topW) * ((bandY - topY) / (botY - topY)) * 0.92
        var band = Path()
        band.move(to: CGPoint(x: -bandHalf + f * 0.2, y: bandY))
        band.addQuadCurve(to: CGPoint(x: bandHalf + f * 0.2, y: bandY), control: CGPoint(x: f * 0.2, y: bandY + 0.03))
        c.stroke(band, with: .linearGradient(Gradient(colors: [tint.accent2, tint.accent]),
                                             startPoint: CGPoint(x: -bandHalf, y: bandY), endPoint: CGPoint(x: bandHalf, y: bandY)),
                 style: StrokeStyle(lineWidth: 0.026, lineCap: .round))
        c.stroke(band.offsetBy(dx: 0, dy: -0.006), with: .color(.white.opacity(0.45)),
                 style: StrokeStyle(lineWidth: 0.006, lineCap: .round, dash: [0.018, 0.014]))

        // Handle.
        let handle = Path(roundedRect: CGRect(x: -0.027, y: -0.02, width: 0.054, height: 0.62), cornerRadius: 0.027)
        c.fill(handle, with: .linearGradient(Gradient(colors: [woodLight, wood, woodDark]),
                                             startPoint: CGPoint(x: -0.027, y: 0), endPoint: CGPoint(x: 0.027, y: 0)))
        c.fill(Path(roundedRect: CGRect(x: -0.016, y: 0.0, width: 0.009, height: 0.55), cornerRadius: 0.0045),
               with: .color(.white.opacity(0.55)))

        // Cap with a hanging hole.
        let cap = Path(ellipseIn: CGRect(x: -0.04, y: -0.075, width: 0.08, height: 0.08))
        c.fill(cap, with: .linearGradient(Gradient(colors: [tint.accent, tint.accent2]),
                                          startPoint: CGPoint(x: 0, y: -0.075), endPoint: CGPoint(x: 0, y: 0.005)))
        c.fill(Path(ellipseIn: CGRect(x: -0.014, y: -0.049, width: 0.028, height: 0.028)), with: .color(.black.opacity(0.45)))
        c.stroke(cap, with: .color(.white.opacity(0.45)), lineWidth: 0.005)

        // Ferrule binding the straws to the handle.
        var ferrule = Path()
        ferrule.move(to: CGPoint(x: -0.042, y: 0.55))
        ferrule.addLine(to: CGPoint(x: 0.042, y: 0.55))
        ferrule.addLine(to: CGPoint(x: 0.094, y: 0.665))
        ferrule.addQuadCurve(to: CGPoint(x: -0.094, y: 0.665), control: CGPoint(x: 0, y: 0.69))
        ferrule.closeSubpath()
        c.fill(ferrule, with: .linearGradient(Gradient(colors: [tint.accent, tint.accent2]),
                                              startPoint: CGPoint(x: -0.09, y: 0.55), endPoint: CGPoint(x: 0.09, y: 0.67)))
        c.fill(ferrule, with: .linearGradient(Gradient(colors: [.white.opacity(0.5), .clear, .black.opacity(0.25)]),
                                              startPoint: CGPoint(x: -0.09, y: 0.6), endPoint: CGPoint(x: 0.09, y: 0.6)))
        for y in [0.58, 0.625] {
            let half = 0.042 + (y - 0.55) / 0.115 * 0.052
            c.stroke(Path { $0.move(to: CGPoint(x: -half, y: y)); $0.addLine(to: CGPoint(x: half, y: y)) },
                     with: .color(.black.opacity(0.28)), lineWidth: 0.008)
            c.stroke(Path { $0.move(to: CGPoint(x: -half, y: y + 0.008)); $0.addLine(to: CGPoint(x: half, y: y + 0.008)) },
                     with: .color(.white.opacity(0.35)), lineWidth: 0.004)
        }
        c.stroke(ferrule, with: .color(.white.opacity(0.3)), lineWidth: 0.004)
    }

    /// Dust kicked off at the fastest point of every stroke, flying the way the broom moves.
    private func drawDust(_ ctx: inout GraphicsContext, S: CGFloat, pivot: CGPoint, L: CGFloat) {
        let half = Self.period / 2
        let life = 1.1
        let current = Int(floor(time / half))
        let gravity = S * 1.1
        for k in max(0, current - 2)...current {
            // At t = k·half the swing passes the rest pose at full speed.
            let born = Double(k) * half
            let theta = Self.rest * .pi / 180
            let tip = CGPoint(x: pivot.x - L * sin(theta), y: pivot.y + L * cos(theta))
            // Tip x-velocity sign: angle grows when cos(wt) > 0, and a growing angle moves the tip left.
            let dir: CGFloat = k.isMultiple(of: 2) ? -1 : 1
            for j in 0..<16 {
                let r1 = Self.hash(k, j, 1), r2 = Self.hash(k, j, 2), r3 = Self.hash(k, j, 3)
                let t0 = born + r3 * 0.12
                let age = time - t0
                guard age > 0, age < life else { continue }
                let vx = dir * S * (0.45 + 0.75 * r1)
                let vy = -S * (0.25 + 0.55 * r2)
                // Kicked off the leading edge of the bristles.
                let x = tip.x + dir * S * (0.1 + 0.06 * r2) + vx * age
                let y = tip.y - S * 0.01 + vy * age + 0.5 * gravity * age * age
                let fade = pow(1 - age / life, 1.4)
                let size = S * (0.014 + 0.022 * r3)
                if j % 4 == 0 {
                    drawSpark(&ctx, at: CGPoint(x: x, y: y), radius: size * 1.4, color: .white.opacity(0.9 * fade))
                } else {
                    let color: Color = j % 3 == 0 ? tint.accent.opacity(0.85 * fade) : Color(hex: 0xFFE7B0).opacity(0.75 * fade)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)), with: .color(color))
                }
            }
        }
    }

    /// Sparkles radiating out of the disc when the job is done.
    private func drawBurst(_ ctx: inout GraphicsContext, size: CGSize, S: CGFloat, ft: Double) {
        guard ft < 1.4 else { return }
        let center = CGPoint(x: size.width / 2, y: size.height * 0.5)
        let x = ft / 1.4
        let fade = pow(1 - x, 1.2)
        for i in 0..<14 {
            let a = Double(i) / 14 * 2 * .pi + 0.2
            let r = S * (0.12 + 0.36 * (1 - pow(1 - x, 3))) * (i.isMultiple(of: 2) ? 1 : 0.82)
            let p = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
            drawSpark(&ctx, at: p, radius: S * (i.isMultiple(of: 3) ? 0.03 : 0.02),
                      color: (i.isMultiple(of: 2) ? Color.white : tint.accent).opacity(fade))
        }
    }

    private func drawTwinkles(_ ctx: inout GraphicsContext, size: CGSize, S: CGFloat) {
        let spots: [(CGFloat, CGFloat, Double)] = [(0.24, 0.3, 0), (0.78, 0.58, 1.7), (0.33, 0.62, 3.1), (0.7, 0.28, 4.4)]
        for (x, y, phase) in spots {
            let v = still ? 0.6 : max(0, sin(time * 1.9 + phase))
            guard v > 0.05 else { continue }
            drawSpark(&ctx, at: CGPoint(x: size.width * x, y: size.height * y), radius: S * 0.028 * v,
                      color: .white.opacity(0.75 * v))
        }
    }

    /// Four-pointed star.
    private func drawSpark(_ ctx: inout GraphicsContext, at p: CGPoint, radius r: CGFloat, color: Color) {
        let k = r * 0.22
        var star = Path()
        star.move(to: CGPoint(x: p.x, y: p.y - r))
        star.addQuadCurve(to: CGPoint(x: p.x + r, y: p.y), control: CGPoint(x: p.x + k, y: p.y - k))
        star.addQuadCurve(to: CGPoint(x: p.x, y: p.y + r), control: CGPoint(x: p.x + k, y: p.y + k))
        star.addQuadCurve(to: CGPoint(x: p.x - r, y: p.y), control: CGPoint(x: p.x - k, y: p.y + k))
        star.addQuadCurve(to: CGPoint(x: p.x, y: p.y - r), control: CGPoint(x: p.x - k, y: p.y - k))
        ctx.fill(star, with: .color(color))
    }

    /// Deterministic 0…1 noise.
    static func hash(_ a: Int, _ b: Int, _ c: Int) -> Double {
        var h = UInt64(truncatingIfNeeded: a &* 73_856_093) ^ UInt64(truncatingIfNeeded: b &* 19_349_663) ^ UInt64(truncatingIfNeeded: c &* 83_492_791)
        h = (h ^ (h >> 13)) &* 0x5bd1e995
        h ^= h >> 15
        return Double(h % 10_000) / 10_000
    }
}
