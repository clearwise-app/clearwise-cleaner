import SwiftUI

/// Translucent "glass" surface. Built from fills and strokes rather than system materials so it
/// looks identical over the animated mesh, in snapshots, and on every macOS version.
///
/// A dark underlay sits beneath the white sheen so text on the card keeps 4.5:1 even over the
/// lightest mesh nodes. Reduce Transparency swaps the whole thing for an opaque surface;
/// Increase Contrast strengthens the outline.
struct GlassBackground: View {
    var radius: CGFloat = Theme.Radius.card
    var intensity: Double = 1
    var shadow = true

    @Environment(\.moduleTint) private var tint
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    /// How much the underlay darkens what is behind the card.
    static let underlay = 0.2

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if reduceTransparency {
                shape.fill(tint.solidSurface)
                    .overlay(shape.fill(.white.opacity(0.06 * intensity)))
            } else {
                shape.fill(.black.opacity(Self.underlay))
                    .overlay(
                        shape.fill(LinearGradient(colors: [.white.opacity(0.105 * intensity), .white.opacity(0.045 * intensity)],
                                                  startPoint: .top, endPoint: .bottom))
                    )
            }
        }
        .overlay(
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(Theme.strokeOpacity(0.24, contrast)),
                                                       .white.opacity(Theme.strokeOpacity(0.05, contrast))],
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
        .accessibilityHidden(true) // decoration: the title next to it carries the meaning
    }
}
