import SwiftUI
import CleanerKit

// MARK: - Checkbox

enum CheckState {
    case on, off, mixed

    init(selected: Int, total: Int) {
        if selected == 0 { self = .off } else if selected >= total { self = .on } else { self = .mixed }
    }
}

struct CheckBox: View {
    let state: CheckState
    var tint: ModuleTint
    var disabled = false
    /// What is being checked, for VoiceOver and the tooltip ("Кэш браузеров").
    var label: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            let shape = RoundedRectangle(cornerRadius: 5.5, style: .continuous)
            ZStack {
                if state == .off {
                    shape.fill(.white.opacity(0.04))
                    shape.strokeBorder(.white.opacity(0.38), lineWidth: 1.25)
                } else {
                    shape.fill(tint.gradient)
                    shape.strokeBorder(.white.opacity(0.3), lineWidth: 0.75)
                    Image(systemName: state == .on ? "checkmark" : "minus")
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .animation(Theme.quick, value: state)
        .help(helpText)
        .accessibilityLabel(label.isEmpty ? "Отметить" : label)
        .accessibilityValue(stateText)
        .accessibilityAddTraits(.isToggle)
    }

    private var stateText: String {
        switch state {
        case .on: "отмечено"
        case .off: "не отмечено"
        case .mixed: "частично"
        }
    }

    private var helpText: String {
        let verb = state == .off ? "Отметить" : "Снять отметку"
        return label.isEmpty ? verb : "\(verb): \(label)"
    }
}

// MARK: - Badges

/// Solid capsule with dark ink: ≥ 4.5:1 on every fill we use (colored text on a 16 % tint
/// measured 2.5–3.6:1). Meaning is carried by icon + text, never by color alone.
struct Badge: View {
    let text: String
    var color: Color
    var symbol: String? = nil

    static let ink = Color(hex: 0x14101C)

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold)).accessibilityHidden(true)
            }
            Text(text).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(Self.ink)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color))
        .overlay(Pill().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

struct RiskBadge: View {
    let risk: RiskLevel

    /// Lighter badge fills than the UI accents, so dark ink reads at 8:1 and more.
    static let safeFill = Color(hex: 0x5BE8A3)
    static let reviewFill = Color(hex: 0xFFC46B)
    static let cautionFill = Color(hex: 0xFF8A8A)

    var body: some View {
        switch risk {
        case .safe: Badge(text: "Безопасно", color: Self.safeFill, symbol: "checkmark.shield.fill")
        case .review: Badge(text: "Проверьте", color: Self.reviewFill, symbol: "eye.fill")
        case .caution: Badge(text: "Осторожно", color: Self.cautionFill, symbol: "exclamationmark.triangle.fill")
        }
    }
}

// MARK: - Sizes

/// Big light numeral with a smaller unit: "12,4 ГБ".
struct BigSize: View {
    let bytes: Int64
    var size: CGFloat = 64
    var weight: Font.Weight = .thin

    var body: some View {
        let p = Fmt.sizeParts(bytes)
        HStack(alignment: .firstTextBaseline, spacing: size * 0.1) {
            Text(p.value)
                .font(.number(size, weight: weight))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(p.unit)
                .font(.number(size * 0.4, weight: .light))
                .foregroundStyle(Theme.textSecondary)
        }
        .foregroundStyle(Theme.text)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Fmt.size(bytes))
    }
}

struct SizeText: View {
    let bytes: Int64
    var font: Font = .system(size: 13, weight: .medium, design: .rounded)
    var color: Color = Theme.text

    var body: some View {
        Text(Fmt.size(bytes))
            .font(font)
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Buttons

struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary(ModuleTint), secondary, quiet, destructive }
    var kind: Kind = .secondary
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind, large: large)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let kind: Kind
        let large: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hover = false

        var body: some View {
            let height: CGFloat = large ? 38 : 30
            // A rounded rectangle with radius = height / 2, not `Capsule`: stroking a Capsule leaves thin
            // vertical hairlines just outside both ends (degenerate straight segments in its path), which
            // showed on every large pill. Same outline, no artifacts.
            let shape = RoundedRectangle(cornerRadius: height / 2, style: .circular)
            configuration.label
                .font(.system(size: large ? 14 : 12.5, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, large ? 20 : 14)
                .frame(height: height)
                .background {
                    ZStack {
                        background
                        // Hover wash for the gradient kinds (secondary/quiet brighten their own fill);
                        // a fill rather than `.brightness`, which re-filtered the whole layer.
                        if hover && isEnabled && isFilled { Color.white.opacity(0.08) }
                    }
                    .clipShape(shape)
                }
                .overlay(shape.strokeBorder(.white.opacity(strokeOpacity), lineWidth: 0.75))
                .contentShape(shape)
                .shadow(color: shadowColor, radius: 10, y: 4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hover = $0 }
                .animation(Theme.quick, value: configuration.isPressed)
                .animation(Theme.quick, value: hover)
        }

        private var isFilled: Bool {
            switch kind {
            case .primary, .destructive: true
            case .secondary, .quiet: false
            }
        }

        private var foreground: Color {
            switch kind {
            case .primary, .destructive: .white
            case .secondary: Theme.text
            case .quiet: Theme.textSecondary
            }
        }

        @ViewBuilder private var background: some View {
            switch kind {
            case .primary(let tint):
                ZStack {
                    tint.horizontal
                    LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center)
                }
            case .destructive:
                LinearGradient(colors: [Color(hex: 0xFF6B6B), Color(hex: 0xE5395B)], startPoint: .leading, endPoint: .trailing)
            case .secondary:
                Color.white.opacity(hover ? 0.16 : 0.11)
            case .quiet:
                Color.white.opacity(hover ? 0.08 : 0.0)
            }
        }

        private var strokeOpacity: Double {
            switch kind {
            case .quiet: 0
            default: 0.2
            }
        }

        private var shadowColor: Color {
            switch kind {
            case .primary(let tint): tint.accent2.opacity(0.35)
            case .destructive: Color(hex: 0xE5395B).opacity(0.35)
            default: .clear
            }
        }
    }
}

/// Small round icon button (reveal in Finder, Quick Look, remove…).
struct IconButton: View {
    let symbol: String
    var help: String
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(hover ? Theme.text : Theme.textSecondary)
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(hover ? 0.16 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hover = $0 }
        .animation(Theme.quick, value: hover)
    }
}

// MARK: - Segmented control

/// Capsule segmented control with a sliding thumb.
struct Segmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var tint: ModuleTint
    var compact = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.0 == selection
                Button {
                    withAnimation(Theme.spring) { selection = option.0 }
                } label: {
                    Text(option.1)
                        .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
                        .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                        .padding(.horizontal, compact ? 10 : 14)
                        .frame(height: compact ? 24 : 28)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color.white.opacity(0.18))
                                    .overlay(Pill().strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
                                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                                    .matchedGeometryEffect(id: "thumb", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(.black.opacity(0.22)))
        .overlay(Pill().strokeBorder(.white.opacity(0.08), lineWidth: 0.75))
        .fixedSize()
    }
}

/// Selectable chip (filters, roots, locations).
struct Chip: View {
    let title: String
    var symbol: String? = nil
    var selected: Bool
    var tint: ModuleTint
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).accessibilityHidden(true)
                }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(
                Capsule().fill(selected ? AnyShapeStyle(tint.horizontal.opacity(0.55)) : AnyShapeStyle(Color.white.opacity(hover ? 0.12 : 0.07)))
            )
            .overlay(Pill().strokeBorder(.white.opacity(selected ? 0.3 : 0.1), lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hover = $0 }
        .fixedSize()
    }
}

/// Capsule replacement for strokes: a stroked SwiftUI `Capsule` leaves hairlines past both ends,
/// a rounded rectangle with radius = height / 2 looks identical and renders clean.
struct Pill: InsettableShape {
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        return RoundedRectangle(cornerRadius: min(r.width, r.height) / 2, style: .circular).path(in: r)
    }

    func inset(by amount: CGFloat) -> Pill {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}
