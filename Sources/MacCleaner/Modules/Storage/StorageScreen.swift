import SwiftUI
import CleanerKit
import SpaceEngine

/// «Хранилище»: the sidebar disk widget opened over the content area. The same breakdown as the hover card,
/// plus what each category is made of — folders can be opened level by level, sorted by size.
struct StorageScreen: View {
    let explorer: StorageExplorerModel
    @Environment(AppModel.self) private var app
    @State private var hovered: StorageCategory.Kind?

    var body: some View {
        ZStack {
            ModuleBackground(tint: .diskMap)
            if let b = app.storage.breakdown {
                VStack(alignment: .leading, spacing: 0) {
                    header(b)
                    StorageSegmentBar(breakdown: b, height: 12, hovered: hovered) { hovered = $0 }
                        .padding(.top, 18)
                    HStack(alignment: .top, spacing: 16) {
                        categories(b)
                            .frame(width: 340)
                        StorageContentsPanel(explorer: explorer, breakdown: b)
                    }
                    .padding(.top, 20)
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.top, 30)
                .padding(.bottom, 24)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        // Esc closes the screen from anywhere in the window.
        .background {
            Button("Закрыть", action: app.closeStorage)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onChange(of: app.storage.breakdown?.measuredAt) { explorer.reload() }
        .onDisappear { explorer.cancel() }
    }

    // MARK: Header

    private func header(_ b: StorageBreakdown) -> some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: "internaldrive.fill", tint: .uninstaller, size: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Хранилище")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("\(b.volumeName) · занято \(Fmt.size(b.used)) из \(Fmt.size(b.total)) · свободно \(Fmt.size(b.free))")
                    .font(.system(size: 13, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 12)
            @Bindable var explorer = explorer
            Picker("Сортировка", selection: $explorer.sort) {
                ForEach(StorageExplorerModel.Sort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Порядок категорий и файлов по размеру")
            IconButton(symbol: "xmark", help: "Закрыть (Esc)", size: 28, action: app.closeStorage)
        }
    }

    // MARK: Categories

    private func categories(_ b: StorageBreakdown) -> some View {
        let list = explorer.sortedCategories(b)
        let maxBytes = max(1, list.map(\.bytes).max() ?? 1)
        return ScrollView {
            VStack(spacing: 4) {
                ForEach(list) { c in
                    categoryRow(c, breakdown: b, maxBytes: maxBytes)
                }
            }
            .padding(8)
        }
        .scrollIndicators(.never)
        .glass(radius: 16, shadow: false)
    }

    private func categoryRow(_ c: StorageCategory, breakdown b: StorageBreakdown, maxBytes: Int64) -> some View {
        let selected = explorer.kind == c.kind
        return Button { withAnimation(Theme.quick) { explorer.select(c.kind) } } label: {
            HStack(spacing: 11) {
                CategoryGlyph(kind: c.kind, size: 28)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(c.title)
                            .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Fmt.size(c.bytes))
                            .font(.system(size: 12.5, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize()
                    }
                    ShareBar(fraction: Double(c.bytes) / Double(maxBytes), fill: c.kind.gradient)
                }
                Text(StorageFmt.precisePercent(b.share(c.bytes)))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                    .frame(width: 46, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? c.kind.color.opacity(0.2) : (hovered == c.kind ? Color.white.opacity(0.06) : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = c.kind } else if hovered == c.kind { hovered = nil }
        }
        .accessibilityLabel("\(c.title), \(Fmt.size(c.bytes)), \(StorageFmt.precisePercent(b.share(c.bytes)))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Contents

/// Right panel: breadcrumb and the measured contents of the current level.
private struct StorageContentsPanel: View {
    let explorer: StorageExplorerModel
    let breakdown: StorageBreakdown
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumb
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glass(radius: 16, shadow: false)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                crumb(explorer.kind.title, index: -1, isLast: explorer.path.isEmpty)
                ForEach(Array(explorer.path.enumerated()), id: \.offset) { i, url in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.themeTertiary)
                        .accessibilityHidden(true)
                    crumb(FileManager.default.displayName(atPath: url.path), index: i, isLast: i == explorer.path.count - 1)
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func crumb(_ title: String, index: Int, isLast: Bool) -> some View {
        Button(title) { withAnimation(Theme.quick) { explorer.goBack(to: index) } }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: isLast ? .semibold : .medium))
            .foregroundStyle(isLast ? Theme.text : Theme.textSecondary)
            .disabled(isLast)
            .lineLimit(1)
            .pointerStyle(isLast ? nil : .link)
    }

    @ViewBuilder private var content: some View {
        if let entries = explorer.sortedEntries {
            if entries.isEmpty {
                note(symbol: "tray", title: "Здесь пусто", text: "В этой папке нет файлов, которые занимают место.")
            } else {
                list(entries)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.regular)
                Text("Считаем размеры…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func list(_ entries: [StorageEntry]) -> some View {
        let maxBytes = max(1, entries.map(\.bytes).max() ?? 1)
        let levelTotal = max(1, entries.reduce(Int64(0)) { $0 + $1.bytes })
        return ScrollView {
            LazyVStack(spacing: 2) {
                if explorer.kind == .system && explorer.path.isEmpty {
                    systemNote(listed: entries.reduce(Int64(0)) { $0 + $1.bytes })
                }
                ForEach(entries) { e in
                    StorageEntryRow(entry: e, maxBytes: maxBytes, levelTotal: levelTotal, tint: explorer.kind,
                                    showsLocation: explorer.path.isEmpty) {
                        withAnimation(Theme.quick) { explorer.open(e) }
                    }
                }
            }
            .padding(8)
        }
        .scrollIndicators(.automatic)
        .id(explorer.path.last?.path ?? explorer.kind.rawValue)
    }

    /// «Система и прочее» is a remainder: say what the rows are and how much macOS does not let us list.
    private func systemNote(listed: Int64) -> some View {
        let rest = breakdown.bytes(.system) - listed
        var text = "Всё, что не попало в другие категории. Ниже — части, которые можно измерить."
        if rest > 1_000_000_000 {
            text += " Ещё \(Fmt.size(rest)) macOS не раскладывает по файлам: локальные снимки Time Machine, служебные данные файловой системы"
            text += breakdown.fullDiskAccess ? " и файлы других пользователей." : ", файлы других пользователей и — без полного доступа к диску — данные других приложений."
        }
        text += " Освободить место здесь можно в основном через «Общую библиотеку», Homebrew и скрытые папки; macOS и подкачку система держит сама."
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.05)))
        .padding(.bottom, 6)
    }

    private func note(symbol: String, title: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            Text(title)
                .font(.cardTitle)
                .foregroundStyle(Theme.text)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
    }
}

/// One file or folder: icon, name, size bar, share of this level, size; folders open on click.
private struct StorageEntryRow: View {
    let entry: StorageEntry
    let maxBytes: Int64
    let levelTotal: Int64
    let tint: StorageCategory.Kind
    /// Top level of a category: entries come from different folders (two «Developer»s), so show where each lives.
    let showsLocation: Bool
    let onOpen: () -> Void
    @State private var hover = false

    /// Finder name, except for the cryptic folders macOS keeps simulator runtimes in.
    private var title: String {
        let raw = entry.url.lastPathComponent
        let prefix = "com_apple_MobileAsset_", suffix = "SimulatorRuntime"
        if let custom = entry.title { return custom }
        if raw.hasPrefix(prefix), raw.hasSuffix(suffix) {
            let platform = raw.dropFirst(prefix.count).dropLast(suffix.count)
            return "Симуляторы \(platform)"
        }
        return entry.name
    }

    /// «~/Library», «/Library», «/System/Library/AssetsV2».
    private var location: String {
        let parent = entry.url.deletingLastPathComponent().path
        let home = SafetyGuard.home.path
        return parent == home ? "~" : parent.hasPrefix(home + "/") ? "~" + parent.dropFirst(home.count) : parent
    }

    var body: some View {
        HStack(spacing: 12) {
            // The row itself is the button (keyboard, VoiceOver); «Показать в Finder» sits next to it.
            Button { if entry.isFolder { onOpen() } } label: {
                HStack(spacing: 12) {
                    FileIcon(url: entry.url, size: 28)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(1)
                            if entry.detail == nil && showsLocation {
                                Text(location)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.themeTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            Spacer(minLength: 8)
                            Text(StorageFmt.precisePercent(Double(entry.bytes) / Double(levelTotal)))
                                .font(.system(size: 11.5, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.themeTertiary)
                                .fixedSize()
                            Text(Fmt.size(entry.bytes))
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Theme.text)
                                .frame(minWidth: 70, alignment: .trailing)
                        }
                        if let detail = entry.detail {
                            Text(detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.themeTertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        ShareBar(fraction: Double(entry.bytes) / Double(maxBytes), fill: tint.gradient)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel([title, entry.detail, Fmt.size(entry.bytes)].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint(entry.isFolder ? "Открыть папку" : "")
            IconButton(symbol: "magnifyingglass", help: "Показать в Finder", size: 24) { Finder.reveal(entry.url) }
                .opacity(hover ? 1 : 0.001)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.themeTertiary)
                .frame(width: 12)
                .opacity(entry.isFolder ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(hover ? 0.06 : 0))
        )
        .onHover { hover = $0 }
        .help(entry.url.path)
    }
}

/// Thin size bar relative to the biggest item of the list.
private struct ShareBar: View {
    let fraction: Double
    let fill: LinearGradient

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.07))
                Capsule().fill(fill)
                    .frame(width: fraction <= 0 ? 0 : max(3, geo.size.width * CGFloat(min(1, fraction))))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
