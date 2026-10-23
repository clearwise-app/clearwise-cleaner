import SwiftUI
import AppKit

/// Design tokens shared by every screen.
enum Theme {
    enum Radius {
        static let card: CGFloat = 18
        static let row: CGFloat = 12
        static let small: CGFloat = 8
        static let tile: CGFloat = 9
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 20
        static let xl: CGFloat = 32
        static let page: CGFloat = 36
    }

    // Text on dark tinted backgrounds.
    static let text = Color.white
    static let textSecondary = Color.white.opacity(0.68)
    /// Metadata only (paths, counts, dates) at 11 pt and up; never field labels.
    /// 0.62 keeps ≥ 4.5:1 over the darkened mesh and glass (0.44 measured 2.45–3.5:1).
    static let textTertiary = Color.white.opacity(0.62)
    static let hairline = Color.white.opacity(0.09)
    static let fill = Color.white.opacity(0.06)
    static let fillStrong = Color.white.opacity(0.11)

    static let success = Color(hex: 0x3EE08F)
    static let warning = Color(hex: 0xFFB547)
    static let danger = Color(hex: 0xFF6464)

    static let sidebarWidth: CGFloat = 252

    // Motion. The springs settle without a visible overshoot — the app should feel calm, not springy — and
    // nothing that moves takes longer than about half a second. Under Reduce Motion they become a short ease
    // so moves, offsets and scales settle almost at once; pair moving transitions with `Theme.motion(_:)`.
    /// Screens, dialogs and toasts appearing or going away; a phase changing.
    static var spring: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.9)
    }
    /// Switching modules and other whole-screen swaps: critically damped, so a crossfade has no tail.
    static var softSpring: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.55, dampingFraction: 1)
    }
    /// Hover, selection and other small state changes.
    static var quick: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.2)
    }

    /// System Reduce Motion setting. AppKit caches it and keeps it current, so reading it is cheap.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// `transition` as is, or a plain crossfade under Reduce Motion.
    static func motion(_ transition: AnyTransition) -> AnyTransition {
        reduceMotion ? .opacity : transition
    }

    /// Opening and closing a list in place: no bounce, the content below simply makes room.
    static var unfold: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.3)
    }
}

extension AnyTransition {
    /// A list opening under its tile: fades in a few points above its place; on closing it only fades,
    /// so it never slides across the tiles above it.
    static var drawer: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: -8)),
                   // Gone before the content below moves up into its place.
                   removal: .opacity.animation(.easeOut(duration: 0.1)))
    }
}

// MARK: - Increase Contrast / Reduce Transparency

extension Theme {
    /// Tertiary text that follows Increase Contrast (0.62 → 0.8).
    static func textTertiary(_ contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? .white.opacity(0.8) : textTertiary
    }
    /// Secondary text that follows Increase Contrast (0.68 → 0.85).
    static func textSecondary(_ contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? .white.opacity(0.85) : textSecondary
    }
    /// Separators: 0.09 → 0.25 under Increase Contrast.
    static func hairline(_ contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? .white.opacity(0.25) : hairline
    }
    /// Card and control outlines: at least 0.4 under Increase Contrast.
    static func strokeOpacity(_ base: Double, _ contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? max(base, 0.4) : base
    }
}

/// Text colors that resolve against the environment, so a view gets the Increase Contrast variant
/// without reading the setting itself: `.foregroundStyle(.themeTertiary)`.
struct ThemeTextStyle: ShapeStyle {
    enum Level { case secondary, tertiary }
    let level: Level

    func resolve(in environment: EnvironmentValues) -> Color {
        switch level {
        case .secondary: Theme.textSecondary(environment.colorSchemeContrast)
        case .tertiary: Theme.textTertiary(environment.colorSchemeContrast)
        }
    }
}

extension ShapeStyle where Self == ThemeTextStyle {
    static var themeSecondary: ThemeTextStyle { ThemeTextStyle(level: .secondary) }
    static var themeTertiary: ThemeTextStyle { ThemeTextStyle(level: .tertiary) }
}

/// Per-module color identity: vivid accents for controls and a dark mesh for the background.
struct ModuleTint: Equatable {
    let accent: Color
    let accent2: Color
    /// 3×3 mesh, row-major from top-left. Kept dark so white text always reads.
    let mesh: [Color]

    var gradient: LinearGradient {
        LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var horizontal: LinearGradient {
        LinearGradient(colors: [accent, accent2], startPoint: .leading, endPoint: .trailing)
    }

    static let smartCare = ModuleTint(
        accent: Color(hex: 0xC27BFF), accent2: Color(hex: 0xFF5FAE),
        mesh: ([0x12082B, 0x2A0F5C, 0x3A0D4E,
               0x23105E, 0x55209A, 0x7A1E7C,
               0x0E0624, 0x3A1062, 0x86226C] as [UInt32]).map { Color(hex: $0) }
    )
    // Junk and Duplicates had the lightest centre nodes, right under the result cards;
    // they are darkened ~25 % so tertiary text on glass keeps 4.5:1.
    static let junk = ModuleTint(
        accent: Color(hex: 0x3CE6AE), accent2: Color(hex: 0x22B7D6),
        mesh: ([0x03141A, 0x062F38, 0x07362E,
               0x063940, 0x0A4C46, 0x0A4D3C,
               0x020F13, 0x0A3A47, 0x0B4A3B] as [UInt32]).map { Color(hex: $0) }
    )
    static let uninstaller = ModuleTint(
        accent: Color(hex: 0x5AA8FF), accent2: Color(hex: 0x8A6CFF),
        mesh: ([0x060E28, 0x0C1F5E, 0x191350,
               0x0A1C50, 0x1B44A6, 0x2C2486,
               0x040A1E, 0x13297C, 0x2D1F7E] as [UInt32]).map { Color(hex: $0) }
    )
    static let oldFiles = ModuleTint(
        accent: Color(hex: 0xFFC14D), accent2: Color(hex: 0xFF7A3D),
        mesh: ([0x190B04, 0x3B1A07, 0x481909,
               0x381906, 0x7A3A0E, 0x6C2610,
               0x110703, 0x4A2208, 0x7E2C12] as [UInt32]).map { Color(hex: $0) }
    )
    static let duplicates = ModuleTint(
        accent: Color(hex: 0x52E3FF), accent2: Color(hex: 0x3A7CFF),
        mesh: ([0x03121C, 0x06304A, 0x0A2846,
               0x06364F, 0x0A4E73, 0x0D2F5E,
               0x020B12, 0x0A3D5E, 0x0B4169] as [UInt32]).map { Color(hex: $0) }
    )
    static let diskMap = ModuleTint(
        accent: Color(hex: 0xFF72B6), accent2: Color(hex: 0xA874FF),
        mesh: ([0x18071F, 0x380D40, 0x480F36,
               0x31103F, 0x7A1E6C, 0x56196C,
               0x110518, 0x48134F, 0x7C1F58] as [UInt32]).map { Color(hex: $0) }
    )
    static let health = ModuleTint(
        accent: Color(hex: 0x9BE15D), accent2: Color(hex: 0x2FB872),
        mesh: ([0x0D1405, 0x22350B, 0x163416,
               0x1C330C, 0x3A5A14, 0x1E4E25,
               0x090F04, 0x283F0F, 0x2B5A1E] as [UInt32]).map { Color(hex: $0) }
    )
    /// Coral: the one hue no other module uses (Здоровье Mac is green).
    static let startup = ModuleTint(
        accent: Color(hex: 0xFF8A80), accent2: Color(hex: 0xFF4F7B),
        mesh: ([0x1A0608, 0x3A0E14, 0x2E0A1E,
               0x33100F, 0x5E1A22, 0x4A1430,
               0x120405, 0x3F1016, 0x55182C] as [UInt32]).map { Color(hex: $0) }
    )
}

extension ModuleTint {
    /// Opaque surface for Reduce Transparency: the mesh's centre node, darkened by half.
    var solidSurface: Color { mesh[4].mix(with: .black, by: 0.5) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Typography

extension Font {
    /// Huge light numerals for sizes ("12,4").
    static func number(_ size: CGFloat, weight: Font.Weight = .thin) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static let pageTitle = Font.system(size: 30, weight: .bold)
    static let pageSubtitle = Font.system(size: 15, weight: .regular)
    static let sectionTitle = Font.system(size: 17, weight: .semibold)
    static let cardTitle = Font.system(size: 14, weight: .semibold)
    static let rowTitle = Font.system(size: 13, weight: .medium)
    static let body13 = Font.system(size: 13)
    static let caption12 = Font.system(size: 12)
    static let caption11 = Font.system(size: 11)
    static let label11 = Font.system(size: 11, weight: .semibold)
}

// MARK: - Environment

extension EnvironmentValues {
    /// True when the view is being rendered for a static snapshot: animations stay at rest.
    @Entry var isSnapshot: Bool = false
    @Entry var moduleTint: ModuleTint = .smartCare
    /// Full Disk Access is granted: a refusal is then never «дайте полный доступ». Set by RootView.
    @Entry var hasFullDiskAccess: Bool = false
    /// True when decorative, continuously running animations must stop: window inactive,
    /// or the full-screen cleaning overlay covers the content. Set by RootView.
    @Entry var animationsPaused: Bool = false
}
