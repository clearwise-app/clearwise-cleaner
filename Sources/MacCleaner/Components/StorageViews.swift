import SwiftUI
import SpaceEngine

// MARK: - Category colours

extension StorageCategory.Kind {
    /// One distinct hue per category, bright enough for the dark sidebar and spaced around the colour wheel.
    var color: Color {
        switch self {
        case .apps: return Color(hex: 0x5B8CFF)       // blue
        case .documents: return Color(hex: 0xFFC14D)  // amber
        case .media: return Color(hex: 0xFF6FB1)      // pink
        case .music: return Color(hex: 0xFF7A45)      // orange
        case .developer: return Color(hex: 0x3DDC97)  // green
        case .iCloud: return Color(hex: 0x4FD8F0)     // cyan
        case .appData: return Color(hex: 0xA97BFF)    // violet
        case .trash: return Color(hex: 0xC8DD5A)      // lime
        case .system: return Color(hex: 0x9A9AAE)     // neutral grey, like macOS "System Data"
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [color.mix(with: .white, by: 0.18), color], startPoint: .top, endPoint: .bottom)
    }
}

enum StorageFmt {
    /// "18 %", "<1 %", "0 %" — `Fmt.percent`, so the non-breaking space matches the rest of the app.
    static func percent(_ share: Double) -> String {
        Fmt.percent(share)
    }

    /// One decimal below 10 %: "4,2 %", "18 %", "<0,1 %".
    static func precisePercent(_ share: Double) -> String {
        Fmt.percent(share, digits: share * 100 < 10 ? 1 : 0)
    }
}

// MARK: - Segmented bar

/// The disk as one capsule: a coloured segment per category, proportional to the whole disk; the free part is
/// the dim track. Segments grow in from the left when data arrives. Hover reports the segment under the mouse.
struct StorageSegmentBar: View {
    let breakdown: StorageBreakdown
    var height: CGFloat = 8
    var hovered: StorageCategory.Kind?
    var onHover: ((StorageCategory.Kind?) -> Void)?

    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown = false

    static let gap: CGFloat = 1.5

    /// Used categories in drawing order: biggest first, «Система и прочее» last (next to the free track).
    static func order(_ b: StorageBreakdown) -> [StorageCategory] {
        b.categories.filter { $0.bytes > 0 && $0.kind != .system } + b.categories.filter { $0.bytes > 0 && $0.kind == .system }
    }

    struct Segment { let kind: StorageCategory.Kind; let x: CGFloat; let width: CGFloat }

    static func layout(_ b: StorageBreakdown, width: CGFloat, minWidth: CGFloat = 2.5) -> [Segment] {
        var x: CGFloat = 0
        var out: [Segment] = []
        for c in order(b) {
            let w = max(minWidth, CGFloat(b.share(c.bytes)) * width)
            guard x < width else { break }
            out.append(Segment(kind: c.kind, x: x, width: min(w, width - x)))
            x += w
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let segments = Self.layout(breakdown, width: geo.size.width)
            let progress: CGFloat = (grown || isSnapshot) ? 1 : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.11))
                    .overlay(Pill().strokeBorder(.white.opacity(0.05), lineWidth: 0.5))
                ForEach(Array(segments.enumerated()), id: \.element.kind) { i, s in
                    let isLast = i == segments.count - 1
                    let lead: CGFloat = i == 0 ? height / 2 : 1.5
                    let trail: CGFloat = isLast ? height / 2 : 1.5
                    let dim = hovered != nil && hovered != s.kind
                    UnevenRoundedRectangle(topLeadingRadius: lead, bottomLeadingRadius: lead,
                                           bottomTrailingRadius: trail, topTrailingRadius: trail, style: .continuous)
                        .fill(s.kind.gradient)
                        // A white wash, not `.brightness`: that filter smears the layer's edge pixels.
                        .overlay(Color.white.opacity(hovered == s.kind ? 0.1 : 0))
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: lead, bottomLeadingRadius: lead,
                                                          bottomTrailingRadius: trail, topTrailingRadius: trail, style: .continuous))
                        .opacity(dim ? 0.32 : 1)
                        .shadow(color: s.kind.color.opacity(hovered == s.kind ? 0.75 : 0), radius: 5)
                        .frame(width: max(1, (s.width - (isLast ? 0 : Self.gap)) * progress), height: height)
                        .offset(x: s.x * progress)
                }
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard let onHover else { return }
                switch phase {
                case .active(let p):
                    onHover(segments.first { p.x >= $0.x - Self.gap && p.x <= $0.x + $0.width }?.kind)
                case .ended:
                    onHover(nil)
                }
            }
            .animation(Theme.quick, value: hovered)
        }
        .frame(height: height)
        .onAppear { grow() }
        .onChange(of: breakdown.measuredAt) { _, _ in
            grown = false
            grow()
        }
        .accessibilityElement()
        .accessibilityLabel("Занято \(StorageFmt.percent(breakdown.share(breakdown.used))) диска")
        .accessibilityValue(Self.order(breakdown).prefix(4)
            .map { "\($0.title) \(StorageFmt.percent(breakdown.share($0.bytes))), \(Fmt.size($0.bytes))" }
            .joined(separator: "; "))
    }

    private func grow() {
        guard !grown else { return }
        if reduceMotion || isSnapshot { grown = true; return }
        withAnimation(.spring(response: 0.9, dampingFraction: 0.82).delay(0.1)) { grown = true }
    }
}

/// Placeholder while the first measurement runs: a soft highlight sweeping along an empty track.
/// Under Reduce Motion (or with decorative animations paused) the highlight rests and the track breathes instead.
struct StorageShimmerBar: View {
    var height: CGFloat = 8
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.animationsPaused) private var animationsPaused
    @State private var phase: CGFloat = -0.4
    @State private var dim = false

    private var still: Bool { isSnapshot || reduceMotion || animationsPaused }

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(.white.opacity(dim ? 0.06 : 0.09))
                .overlay(alignment: .leading) {
                    LinearGradient(colors: [.clear, .white.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.45)
                        .offset(x: geo.size.width * (still ? 0.3 : phase))
                }
                .clipShape(Capsule())
        }
        .frame(height: height)
        .onAppear(perform: start)
        .onChange(of: still) { _, _ in start() }
        .accessibilityLabel("Считаем, что занимает место")
    }

    private func start() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { phase = -0.4; dim = false }
        guard !isSnapshot, !animationsPaused else { return }
        if reduceMotion {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
        } else {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.0 }
        }
    }
}

// MARK: - Tooltip

/// Small dark bubble for one category: icon, name, share of the disk and size.
struct StorageTooltip: View {
    let category: StorageCategory
    let breakdown: StorageBreakdown

    var body: some View {
        HStack(spacing: 9) {
            CategoryGlyph(kind: category.kind, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(category.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(StorageFmt.precisePercent(breakdown.share(category.bytes)) + " диска")
                        .foregroundStyle(category.kind.color)
                    Text("·").foregroundStyle(Theme.textTertiary)
                    Text(Fmt.size(category.bytes)).foregroundStyle(Theme.textSecondary)
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
            }
        }
        .fixedSize()
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .background(PopoverSurface(radius: 11))
    }
}

/// Opaque-enough glass for floating cards: they sit over the colourful module backgrounds.
struct PopoverSurface: View {
    var radius: CGFloat = 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(Color(hex: 0x15111F))
            GlassBackground(radius: radius, intensity: 1.1)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
    }
}

/// Category icon on its colour (doubles as the colour dot).
struct CategoryGlyph: View {
    let kind: StorageCategory.Kind
    var size: CGFloat = 22

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        ZStack {
            shape.fill(kind.gradient)
            shape.fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
            shape.strokeBorder(.white.opacity(0.2), lineWidth: 0.6)
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Detail card

/// Everything on the disk: one row per category (icon, name, mini bar, % and GB) and the used / free / total line.
struct StorageDetailCard: View {
    let breakdown: StorageBreakdown
    var hovered: StorageCategory.Kind?
    var onHover: ((StorageCategory.Kind?) -> Void)?
    /// A click on a category row: open it in «Хранилище». Rows are not clickable when nil.
    var onSelect: ((StorageCategory.Kind) -> Void)?
    var onClose: (() -> Void)?
    /// «Дать доступ» in the no-access note: the in-app access flow.
    var onGrantAccess: (() -> Void)?

    var body: some View {
        let b = breakdown
        let maxBytes = max(1, b.categories.map(\.bytes).max() ?? 1)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                IconTile(symbol: "internaldrive.fill", tint: .uninstaller, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(b.volumeName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text("Занято \(Fmt.size(b.used)) из \(Fmt.size(b.total))")
                        .font(.system(size: 11.5, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: -2) {
                    Text(StorageFmt.percent(b.share(b.used)))
                        .font(.number(24, weight: .light))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                    Text("занято")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                if let onClose {
                    IconButton(symbol: "xmark", help: "Закрыть", size: 20, action: onClose)
                        .padding(.leading, 2)
                }
            }
            .padding(.bottom, 12)

            StorageSegmentBar(breakdown: b, height: 10, hovered: hovered, onHover: onHover)
                .padding(.bottom, 12)

            VStack(spacing: 2) {
                ForEach(b.categories) { c in
                    row(c, maxBytes: maxBytes)
                }
                freeRow
            }

            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 10)

            if onSelect != nil {
                Text("Нажмите на категорию или на диск, чтобы посмотреть файлы")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 8)
            }

            HStack(spacing: 0) {
                total("Занято", b.used, color: Theme.text)
                Spacer(minLength: 6)
                total("Свободно", b.free, color: Theme.success)
                Spacer(minLength: 6)
                total("Всего", b.total, color: Theme.textSecondary)
            }

            if !b.fullDiskAccess {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 9.5)).padding(.top, 2)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Без полного доступа к диску данные других приложений входят в «Система и прочее».")
                            .fixedSize(horizontal: false, vertical: true)
                        if let onGrantAccess {
                            Button("Дать доступ", action: onGrantAccess)
                                .buttonStyle(.plain)
                                .fontWeight(.semibold)
                                .foregroundStyle(Theme.warning)
                                .pointerStyle(.link)
                                .help("Как дать \(AppInfo.name) полный доступ к диску")
                        }
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.warning.opacity(0.85))
                .padding(.top, 10)
            }
        }
        .padding(16)
        .frame(width: 336)
        .background(PopoverSurface(radius: 18))
    }

    private func row(_ c: StorageCategory, maxBytes: Int64) -> some View {
        let isHovered = hovered == c.kind
        let dim = hovered != nil && !isHovered
        return HStack(spacing: 10) {
            CategoryGlyph(kind: c.kind, size: 22)
                .saturation(c.bytes == 0 ? 0.2 : 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(c.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Fmt.size(c.bytes))
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.07))
                        Capsule().fill(c.kind.gradient)
                            .frame(width: c.bytes == 0 ? 0 : max(3, geo.size.width * CGFloat(Double(c.bytes) / Double(maxBytes))))
                    }
                }
                .frame(height: 3)
            }
            Text(StorageFmt.precisePercent(breakdown.share(c.bytes)))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(c.bytes == 0 ? Theme.textTertiary : Theme.text)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(c.kind.color.opacity(isHovered ? 0.16 : 0))
        )
        .opacity(dim ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if c.bytes > 0 { onSelect?(c.kind) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onSelect != nil && c.bytes > 0 ? .isButton : [])
        .accessibilityAction { if c.bytes > 0 { onSelect?(c.kind) } }
        .pointerStyle(onSelect != nil && c.bytes > 0 ? .link : nil)
        .onHover { inside in
            if inside { onHover?(c.kind) } else if hovered == c.kind { onHover?(nil) }
        }
        .animation(Theme.quick, value: hovered)
    }

    private var freeRow: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 22 * 0.3, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
                Image(systemName: "circle.dashed").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }
            .frame(width: 22, height: 22)
            Text("Свободно")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 4)
            Text(Fmt.size(breakdown.free))
                .font(.system(size: 11.5, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
            Text(StorageFmt.precisePercent(breakdown.share(breakdown.free)))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.success)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func total(_ label: String, _ bytes: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            Text(Fmt.size(bytes))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}
