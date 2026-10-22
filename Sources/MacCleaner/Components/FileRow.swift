import SwiftUI

/// One file/folder line: checkbox, Finder icon, name + full path, badges, size, hover actions.
///
/// Keyboard: the row is focusable (Tab), Space toggles the checkbox, ⌘Y opens Quick Look;
/// the Finder / Quick Look buttons show on hover and on focus. VoiceOver reads it as one toggle
/// with "Показать в Finder" / "Быстрый просмотр" actions.
struct FileRow<Badges: View>: View {
    let url: URL
    let size: Int64
    /// Human label to show instead of the raw file name (e.g. "Google Chrome · Default · GPUCache").
    var title: String? = nil
    /// Replaces the formatted size (e.g. "—" when the size could not be measured).
    var sizeLabel: String? = nil
    var isChecked: Bool? = nil
    var tint: ModuleTint
    /// Extra info appended after the path (e.g. "открывался 8 месяцев назад").
    var detail: String? = nil
    var indent: CGFloat = 0
    var onToggle: () -> Void = {}
    var onQuickLook: (() -> Void)? = nil
    @ViewBuilder var badges: Badges

    var body: some View {
        // Compared on data only: the closures are rebuilt by every parent body and would otherwise
        // make every visible row re-render on any selection change.
        FileRowContent(data: FileRowData(url: url, size: size, title: title, sizeLabel: sizeLabel,
                                         isChecked: isChecked, tint: tint, detail: detail, indent: indent,
                                         hasQuickLook: onQuickLook != nil),
                       onToggle: onToggle, onQuickLook: onQuickLook, badges: badges)
            .equatable()
    }
}

extension FileRow where Badges == EmptyView {
    init(url: URL, size: Int64, title: String? = nil, isChecked: Bool? = nil, tint: ModuleTint, detail: String? = nil,
         indent: CGFloat = 0, onToggle: @escaping () -> Void = {}, onQuickLook: (() -> Void)? = nil) {
        self.init(url: url, size: size, title: title, isChecked: isChecked, tint: tint, detail: detail, indent: indent,
                  onToggle: onToggle, onQuickLook: onQuickLook, badges: { EmptyView() })
    }
}

/// Everything a row shows. Closures stay out so equality means "looks the same".
struct FileRowData: Equatable {
    let url: URL
    let size: Int64
    let title: String?
    let sizeLabel: String?
    let isChecked: Bool?
    let tint: ModuleTint
    let detail: String?
    let indent: CGFloat
    let hasQuickLook: Bool
}

private struct FileRowContent<Badges: View>: View, Equatable {
    let data: FileRowData
    let onToggle: () -> Void
    let onQuickLook: (() -> Void)?
    let badges: Badges

    @State private var hover = false
    @FocusState private var focused: Bool

    /// Badges can't be compared, so rows that have them always re-render (as before);
    /// plain rows skip `body` while their data is unchanged.
    static func == (l: Self, r: Self) -> Bool {
        Badges.self == EmptyView.self && l.data == r.data
    }

    private var url: URL { data.url }
    private var displayTitle: String { data.title ?? url.lastPathComponent }
    /// Docker items are not files: no path, no Finder, no Quick Look.
    private var isFile: Bool { url.isFileURL }
    private var showsActions: Bool { (hover || focused) && isFile }

    var body: some View {
        HStack(spacing: 12) {
            if let isChecked = data.isChecked {
                CheckBox(state: isChecked ? .on : .off, tint: data.tint, label: displayTitle, action: onToggle)
                    .accessibilityHidden(true) // the row itself is the toggle for VoiceOver
            }
            if isFile {
                FileIcon(url: url, size: 22)
            } else {
                Image(systemName: "shippingbox.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(displayTitle)
                        .font(.rowTitle)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    badges
                }
                HStack(spacing: 6) {
                    Text(isFile ? Fmt.path(url) : "Docker")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.themeTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = data.detail {
                        Text("·").foregroundStyle(.themeTertiary).accessibilityHidden(true)
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.themeTertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            .help(isFile ? url.path : displayTitle)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if let onQuickLook {
                    IconButton(symbol: "eye.fill", help: String(localized: "Быстрый просмотр (⌘Y)"), size: 24, action: onQuickLook)
                        .keyboardShortcut(focused ? KeyboardShortcut("y", modifiers: .command) : nil)
                }
                IconButton(symbol: "magnifyingglass", help: String(localized: "Показать в Finder"), size: 24) { Finder.reveal(url) }
            }
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
            .focusable(false)
            .accessibilityHidden(true) // exposed as row actions below
            Group {
                if let sizeLabel = data.sizeLabel {
                    Text(sizeLabel).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundStyle(.themeTertiary)
                } else {
                    SizeText(bytes: data.size, font: .system(size: 12.5, weight: .medium, design: .rounded), color: Theme.textSecondary)
                }
            }
            .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.leading, 16 + data.indent)
        .padding(.trailing, 16)
        .frame(height: 46)
        .background(Rectangle().fill(.white.opacity(hover || focused ? 0.045 : 0)))
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(data.tint.accent.opacity(0.85), lineWidth: 1.5)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if data.isChecked != nil { onToggle() } }
        .onHover { hover = $0 }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) {
            guard data.isChecked != nil else { return .ignored }
            onToggle()
            return .handled
        }
        .contextMenu {
            if isFile {
                Button("Показать в Finder") { Finder.reveal(url) }
                if let onQuickLook { Button("Быстрый просмотр", action: onQuickLook) }
                Button("Скопировать путь") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(data.isChecked != nil ? .isToggle : [])
        .accessibilityAction { if data.isChecked != nil { onToggle() } }
        .accessibilityAction(named: "Показать в Finder") { Finder.reveal(url) }
        .modifier(QuickLookAction(onQuickLook: onQuickLook))
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if let isChecked = data.isChecked { parts.append(isChecked ? String(localized: "отмечено") : String(localized: "не отмечено")) }
        return parts.joined(separator: ", ")
    }
}

private struct QuickLookAction: ViewModifier {
    let onQuickLook: (() -> Void)?

    func body(content: Content) -> some View {
        if let onQuickLook {
            content.accessibilityAction(named: "Быстрый просмотр", onQuickLook)
        } else {
            content
        }
    }
}

/// Thin separator used inside glass cards.
struct Hairline: View {
    var inset: CGFloat = 0
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Rectangle().fill(Theme.hairline(contrast)).frame(height: 1).padding(.leading, inset)
            .accessibilityHidden(true)
    }
}
