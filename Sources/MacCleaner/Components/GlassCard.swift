import SwiftUI

/// Translucent "glass" surface. Built from fills and strokes rather than system materials so it
/// looks identical over the animated mesh, in snapshots, and on every macOS version.
struct GlassBackground: View {
    var radius: CGFloat = Theme.Radius.card
    var intensity: Double = 1
    var shadow = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(LinearGradient(colors: [.white.opacity(0.105 * intensity), .white.opacity(0.045 * intensity)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.05)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: .black.opacity(shadow ? 0.28 : 0), radius: 22, y: 12)
    }
}

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 18
    var radius: CGFloat = Theme.Radius.card
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(GlassBackground(radius: radius))
    }
}

extension View {
    func glass(radius: CGFloat = Theme.Radius.card, intensity: Double = 1, shadow: Bool = true) -> some View {
        background(GlassBackground(radius: radius, intensity: intensity, shadow: shadow))
    }
}

/// Rounded square with the module gradient and a glyph — used in lists, tiles and the sidebar.
struct IconTile: View {
    let symbol: String
    var tint: ModuleTint
    var size: CGFloat = 32
    var muted = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        ZStack {
            shape.fill(muted ? AnyShapeStyle(Color.white.opacity(0.12)) : AnyShapeStyle(tint.gradient))
            shape.fill(LinearGradient(colors: [.white.opacity(0.32), .clear], startPoint: .top, endPoint: .center))
            shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.75)
            Image(systemName: symbol)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: (muted ? Color.clear : tint.accent2).opacity(0.35), radius: size * 0.22, y: size * 0.1)
    }
}
