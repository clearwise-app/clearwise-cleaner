import SwiftUI

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
    static let textTertiary = Color.white.opacity(0.44)
    static let hairline = Color.white.opacity(0.09)
    static let fill = Color.white.opacity(0.06)
    static let fillStrong = Color.white.opacity(0.11)

    static let success = Color(hex: 0x3EE08F)
    static let warning = Color(hex: 0xFFB547)
    static let danger = Color(hex: 0xFF6464)

    static let sidebarWidth: CGFloat = 252

    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.86)
    static let softSpring = Animation.spring(response: 0.7, dampingFraction: 0.9)
    static let quick = Animation.easeOut(duration: 0.18)
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
    static let junk = ModuleTint(
        accent: Color(hex: 0x3CE6AE), accent2: Color(hex: 0x22B7D6),
        mesh: ([0x03141A, 0x062F38, 0x07362E,
               0x063940, 0x0C6058, 0x0A4D3C,
               0x020F13, 0x0A3A47, 0x0E5D4A] as [UInt32]).map { Color(hex: $0) }
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
               0x06364F, 0x0D6390, 0x113F7E,
               0x020B12, 0x0A3D5E, 0x0F578C] as [UInt32]).map { Color(hex: $0) }
    )
    static let diskMap = ModuleTint(
        accent: Color(hex: 0xFF72B6), accent2: Color(hex: 0xA874FF),
        mesh: ([0x18071F, 0x380D40, 0x480F36,
               0x31103F, 0x7A1E6C, 0x56196C,
               0x110518, 0x48134F, 0x7C1F58] as [UInt32]).map { Color(hex: $0) }
    )
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
}
