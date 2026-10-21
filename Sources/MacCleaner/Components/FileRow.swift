import SwiftUI

/// One file/folder line: checkbox, Finder icon, name + full path, badges, size, hover actions.
struct FileRow<Badges: View>: View {
    let url: URL
    let size: Int64
    /// Human label to show instead of the raw file name (e.g. "Google Chrome · Default · GPUCache").
    var title: String? = nil
    /// Replaces the formatted size (e.g. "—" when the size could not be measured).
    var sizeLabel: String? = nil
    var isChecked: Bool? = nil
    var tint: ModuleTint
    /// Extra info appended after the path (e.g. "открывался 8 мес. назад").
    var detail: String? = nil
    var indent: CGFloat = 0
    var onToggle: () -> Void = {}
    var onQuickLook: (() -> Void)? = nil
    @ViewBuilder var badges: Badges

    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            if let isChecked {
                CheckBox(state: isChecked ? .on : .off, tint: tint, action: onToggle)
            }
            Image(nsImage: IconCache.icon(for: url))
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title ?? url.lastPathComponent)
                        .font(.rowTitle)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    badges
                }
                HStack(spacing: 6) {
                    Text(Fmt.path(url))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail {
                        Text("·").foregroundStyle(Theme.textTertiary)
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            .help(url.path)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if let onQuickLook {
                    IconButton(symbol: "eye.fill", help: "Быстрый просмотр", size: 24, action: onQuickLook)
                }
                IconButton(symbol: "magnifyingglass", help: "Показать в Finder", size: 24) { Finder.reveal(url) }
            }
            .opacity(hover ? 1 : 0)
            Group {
                if let sizeLabel {
                    Text(sizeLabel).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundStyle(Theme.textTertiary)
                } else {
                    SizeText(bytes: size, font: .system(size: 12.5, weight: .medium, design: .rounded), color: Theme.textSecondary)
                }
            }
            .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.leading, 16 + indent)
        .padding(.trailing, 16)
        .frame(height: 46)
        .background(Rectangle().fill(.white.opacity(hover ? 0.045 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { if isChecked != nil { onToggle() } }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Показать в Finder") { Finder.reveal(url) }
            if let onQuickLook { Button("Быстрый просмотр", action: onQuickLook) }
            Button("Скопировать путь") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
        }
    }
}

extension FileRow where Badges == EmptyView {
    init(url: URL, size: Int64, title: String? = nil, isChecked: Bool? = nil, tint: ModuleTint, detail: String? = nil,
         indent: CGFloat = 0, onToggle: @escaping () -> Void = {}, onQuickLook: (() -> Void)? = nil) {
        self.init(url: url, size: size, title: title, isChecked: isChecked, tint: tint, detail: detail, indent: indent,
                  onToggle: onToggle, onQuickLook: onQuickLook, badges: { EmptyView() })
    }
}

/// Thin separator used inside glass cards.
struct Hairline: View {
    var inset: CGFloat = 0
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, inset)
    }
}
