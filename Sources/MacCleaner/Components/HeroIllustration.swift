import SwiftUI

struct HeroSpec {
    struct Satellite {
        let symbol: String
        /// Degrees, 0 = right, counter-clockwise.
        let angle: Double
        /// Distance from center as a fraction of the hero size.
        let distance: Double
        var scale: Double = 1
    }

    let symbol: String
    let satellites: [Satellite]
}

/// Layered, glowing centrepiece: glow orb, orbit rings, a glossy gradient tile with the module glyph,
/// and small glass "satellites" floating around it.
struct HeroIllustration: View {
    let spec: HeroSpec
    let tint: ModuleTint
    var size: CGFloat = 230
    /// Scanning: orbit spins and a comet runs around it.
    var active = false

    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var floating = false
    @State private var spin = false

    private var animated: Bool { !isSnapshot && !reduceMotion }

    var body: some View {
        let tile = size * 0.6
        ZStack {
            // Glow orb
            Circle()
                .fill(RadialGradient(colors: [tint.accent.opacity(active ? 0.6 : 0.5), tint.accent2.opacity(0.18), .clear],
                                     center: .center, startRadius: 0, endRadius: size * 0.78))
                .frame(width: size * 1.7, height: size * 1.7)
                .animation(.easeInOut(duration: 0.8), value: active)

            // Orbits
            Circle()
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                .frame(width: size * 1.18, height: size * 1.18)
            Circle()
                .strokeBorder(.white.opacity(0.045), style: StrokeStyle(lineWidth: 1, dash: [2, 6]))
                .frame(width: size * 1.5, height: size * 1.5)
                .rotationEffect(.degrees(spin ? 360 : 0))

            if active {
                Comet(tint: tint, animated: animated)
                    .frame(width: size * 1.18, height: size * 1.18)
                    .transition(.opacity)
            }

            // Satellites
            ForEach(Array(spec.satellites.enumerated()), id: \.offset) { i, sat in
                let rad = sat.angle * .pi / 180
                let bob = size * 0.025 * (i.isMultiple(of: 2) ? 1 : -1)
                SatelliteBubble(symbol: sat.symbol, tint: tint, size: size * 0.2 * sat.scale)
                    .offset(x: cos(rad) * size * sat.distance,
                            y: -sin(rad) * size * sat.distance + (floating ? bob : -bob))
                    .animation(animated ? .easeInOut(duration: 2.8 + Double(i) * 0.45).repeatForever(autoreverses: true) : nil,
                               value: floating)
            }

            // Main tile
            HeroTile(symbol: spec.symbol, tint: tint, size: tile)
                .offset(y: (floating ? -1 : 1) * size * 0.022)
                .animation(animated ? .easeInOut(duration: 3.4).repeatForever(autoreverses: true) : nil, value: floating)
        }
        .frame(width: size * 1.6, height: size * 1.25)
        .onAppear {
            guard animated else { return }
            floating = true
            withAnimation(.linear(duration: 90).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

private struct HeroTile: View {
    let symbol: String
    let tint: ModuleTint
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        ZStack {
            // Depth: a darker slab underneath
            shape
                .fill(LinearGradient(colors: [tint.accent2.opacity(0.9), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                .offset(y: size * 0.05)
                .scaleEffect(0.97)
            shape.fill(tint.gradient)
            // Gloss
            shape.fill(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05), .clear],
                                      startPoint: .top, endPoint: .center))
            // Inner light from bottom
            shape.fill(RadialGradient(colors: [.white.opacity(0.2), .clear],
                                      center: .init(x: 0.5, y: 1.1), startRadius: 0, endRadius: size * 0.6))
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.08)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.82)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.22), radius: size * 0.04, y: size * 0.03)
        }
        .frame(width: size, height: size)
        .shadow(color: tint.accent2.opacity(0.55), radius: size * 0.22, y: size * 0.12)
        .shadow(color: .black.opacity(0.35), radius: size * 0.14, y: size * 0.16)
    }
}

private struct SatelliteBubble: View {
    let symbol: String
    let tint: ModuleTint
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.white, tint.accent], startPoint: .top, endPoint: .bottom))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.3), radius: size * 0.25, y: size * 0.15)
    }
}

/// A bright head with a fading tail running along an orbit — the "working" cue.
private struct Comet: View {
    let tint: ModuleTint
    let animated: Bool
    @State private var turn = false

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.22)
                .stroke(AngularGradient(colors: [.clear, tint.accent.opacity(0.9)], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(79)),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            GeometryReader { geo in
                let r = geo.size.width / 2
                let a = 0.22 * 2 * Double.pi
                Circle()
                    .fill(.white)
                    .frame(width: 7, height: 7)
                    .shadow(color: tint.accent, radius: 6)
                    .position(x: r + cos(a) * r, y: r + sin(a) * r)
            }
        }
        .rotationEffect(.degrees(turn ? 360 : 0) + .degrees(-60))
        .onAppear {
            guard animated else { return }
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { turn = true }
        }
    }
}

extension AppModule {
    var hero: HeroSpec {
        switch self {
        case .smartCare:
            HeroSpec(symbol: "sparkles", satellites: [
                .init(symbol: "trash.fill", angle: 150, distance: 0.56),
                .init(symbol: "shippingbox.fill", angle: 35, distance: 0.58, scale: 0.9),
                .init(symbol: "doc.fill", angle: 210, distance: 0.6, scale: 0.75),
                .init(symbol: "internaldrive.fill", angle: -28, distance: 0.6, scale: 0.85),
            ])
        case .junk:
            HeroSpec(symbol: "bubbles.and.sparkles.fill", satellites: [
                .init(symbol: "doc.text.fill", angle: 145, distance: 0.58),
                .init(symbol: "internaldrive.fill", angle: 30, distance: 0.6, scale: 0.85),
                .init(symbol: "hammer.fill", angle: -30, distance: 0.6, scale: 0.8),
                .init(symbol: "trash.fill", angle: 215, distance: 0.58, scale: 0.75),
            ])
        case .uninstaller:
            HeroSpec(symbol: "xmark.app.fill", satellites: [
                .init(symbol: "folder.fill", angle: 150, distance: 0.58),
                .init(symbol: "slider.horizontal.3", angle: 32, distance: 0.6, scale: 0.85),
                .init(symbol: "shippingbox.fill", angle: -30, distance: 0.6, scale: 0.8),
                .init(symbol: "bolt.fill", angle: 212, distance: 0.58, scale: 0.75),
            ])
        case .oldFiles:
            HeroSpec(symbol: "archivebox.fill", satellites: [
                .init(symbol: "clock.fill", angle: 148, distance: 0.58),
                .init(symbol: "film.fill", angle: 32, distance: 0.6, scale: 0.85),
                .init(symbol: "doc.zipper", angle: -30, distance: 0.6, scale: 0.8),
                .init(symbol: "photo.fill", angle: 212, distance: 0.58, scale: 0.75),
            ])
        case .diskMap:
            HeroSpec(symbol: "chart.pie.fill", satellites: [
                .init(symbol: "folder.fill", angle: 150, distance: 0.58),
                .init(symbol: "internaldrive.fill", angle: 32, distance: 0.6, scale: 0.85),
                .init(symbol: "music.note", angle: -30, distance: 0.6, scale: 0.8),
                .init(symbol: "film.fill", angle: 212, distance: 0.58, scale: 0.75),
            ])
        }
    }
}
