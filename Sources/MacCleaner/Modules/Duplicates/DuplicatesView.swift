import SwiftUI
import CleanerKit
import SpaceEngine
import QuickLook

struct DuplicatesView: View {
    @Bindable var model: DuplicatesModel
    @Environment(AppModel.self) private var app

    var body: some View {
        switch model.phase {
        case .idle, .scanning:
            ModuleStage(module: .duplicates,
                        state: model.phase == .scanning ? .progress(model.progress)
                            : .idle(button: "Сканировать", enabled: !model.activeRoots.isEmpty),
                        onAction: model.startScan, onStop: model.stop,
                        onGrantAccess: app.presentAccessSheet) {
                DuplicatesOptionsView(model: model)
            }
        case .results, .cleaning:
            // While copies move, the cleaning scene covers this screen; there is no screen of its own.
            DuplicatesResults(model: model)
        case .done:
            CompletionView(tint: .duplicates, result: model.result ?? RemovalResult(), title: "Перемещено в Корзину",
                           noun: .copies,
                           onGrantAccess: app.presentAccessSheet,
                           onRetry: model.retryFailed,
                           onEmptyTrash: app.requestEmptyTrash,
                           onDone: model.finish)
        }
    }
}

// MARK: - Options

private struct DuplicatesOptionsView: View {
    @Bindable var model: DuplicatesModel

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Text("Файлы от").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                Segmented(options: DuplicatesModel.sizeOptions.map { ($0, Fmt.size($0)) },
                          selection: $model.minSize, tint: .duplicates, compact: true)
            }
            HStack(spacing: 6) {
                Text("Где искать:")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                ForEach(model.roots, id: \.self) { url in
                    Chip(title: Fmt.folderTitle(url), selected: !model.disabledRoots.contains(url), tint: .duplicates) {
                        model.toggleRoot(url)
                    }
                }
                Chip(title: "Папка…", symbol: "plus", selected: false, tint: .duplicates) { model.addRoot() }
            }
            Label("Сравниваем содержимое, а не имена: в каждой группе файлы совпадают байт в байт.",
                  systemImage: "checkmark.shield.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

// MARK: - Results

private struct DuplicatesResults: View {
    @Bindable var model: DuplicatesModel
    @Environment(AppModel.self) private var app

    var body: some View {
        if model.groups.isEmpty {
            VStack(spacing: 0) {
                EmptyState(symbol: "checkmark.seal.fill", title: "Дубликатов не нашлось",
                           message: "Среди файлов от \(Fmt.size(model.minSize)) в выбранных папках одинаковых нет. Уменьшите порог или добавьте папку.",
                           tint: .duplicates, actionTitle: "Изменить параметры", action: model.newScan)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PartialAccessNote(onGrantAccess: app.presentAccessSheet)
                    .padding(.bottom, 26)
            }
        } else {
            VStack(spacing: 0) {
                ResultsHeader(module: .duplicates, bytes: model.reclaimable, caption: caption,
                              onGrantAccess: app.presentAccessSheet) {
                    HStack(spacing: 8) {
                        Button { model.newScan() } label: { Label("Параметры", systemImage: "slider.horizontal.3") }
                            .buttonStyle(PillButtonStyle(kind: .quiet))
                        Button { model.startScan() } label: { Label("Сканировать заново", systemImage: "arrow.clockwise") }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    DupKindsColumn(model: model)
                        .frame(width: 236)
                    GroupsList(model: model)
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.top, 22)
                .padding(.bottom, 4)

                ActionFooter(title: "В Корзину", tint: .duplicates, enabled: model.markedCount > 0,
                             action: model.requestTrash) {
                    SelectionSummary(bytes: model.markedBytes, count: model.markedCount, noun: .copies)
                } trailing: {
                    KeptSummary(bytes: model.keptSize, count: model.keptCount)
                }
            }
            .quickLookPreview($model.quickLookURL, in: model.visibleURLs)
        }
    }

    private var caption: String {
        let m = model.extraCopies
        return "\(Fmt.groups(model.groups.count)) · \(Fmt.integer(m)) \(Fmt.plural(m, "лишняя копия", "лишние копии", "лишних копий"))"
    }
}

private struct KeptSummary: View {
    let bytes: Int64
    let count: Int

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("Остаётся на диске")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Fmt.files(count))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                SizeText(bytes: bytes, font: .number(24, weight: .light))
            }
        }
        .accessibilityElement(children: .combine)
        .help("В каждой группе всегда остаётся хотя бы одна копия")
    }
}

// MARK: - Kinds overview

private struct DupKindsColumn: View {
    let model: DuplicatesModel

    var body: some View {
        VStack(spacing: 2) {
            DupKindRow(symbol: "square.grid.2x2.fill", title: "Все дубликаты", count: model.groups.count,
                       size: model.reclaimable, fraction: 1, selected: model.kindFilter == nil) {
                withAnimation(Theme.quick) { model.kindFilter = nil }
            }
            Hairline().padding(.vertical, 4).padding(.horizontal, 8)
            ForEach(model.kinds, id: \.kind) { k in
                DupKindRow(symbol: k.kind.symbol, title: k.kind.title, count: k.groups, size: k.size,
                           fraction: Double(k.size) / Double(max(1, model.reclaimable)),
                           selected: model.kindFilter == k.kind) {
                    withAnimation(Theme.quick) { model.kindFilter = k.kind }
                }
            }
        }
        .padding(6)
        .glass(radius: 16, shadow: false)
    }
}

private struct DupKindRow: View {
    let symbol: String
    let title: String
    let count: Int
    let size: Int64
    let fraction: Double
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, tint: .duplicates, size: 26, muted: !selected)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(Fmt.groups(count)).font(.caption11).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 4)
                SizeText(bytes: size, font: .system(size: 12, weight: .semibold, design: .rounded), color: Theme.textSecondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(selected ? 0.12 : (hover ? 0.05 : 0)))
            )
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geo in
                    Capsule().fill(ModuleTint.duplicates.horizontal.opacity(selected ? 0.9 : 0.45))
                        .frame(width: max(3, (geo.size.width - 52) * fraction), height: 2)
                        .offset(x: 44, y: geo.size.height - 5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Groups

private struct GroupsList: View {
    @Bindable var model: DuplicatesModel

    var body: some View {
        let groups = model.visibleGroups
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Menu {
                    Button("Отметить все дубликаты", systemImage: "checkmark.circle") { model.selectAllDuplicates() }
                    Button("Снять отметки", systemImage: "circle") { model.clearSelection() }
                    Divider()
                    Button("Как после сканирования", systemImage: "arrow.uturn.backward") { model.resetToDefault() }
                } label: {
                    Label("Автовыбор", systemImage: "checklist")
                }
                .menuStyle(.button)
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .fixedSize()
                .help("Отметить все копии, кроме одной в каждой группе, или снять отметки")

                Text(model.kindFilter?.title ?? "Все дубликаты")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Segmented(options: [(DuplicatesModel.Sort.size, "Размер"), (.name, "Имя")],
                          selection: $model.sort, tint: .duplicates, compact: true)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            Hairline()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(groups) { g in
                        GroupCard(model: model, group: g)
                    }
                }
                .padding(10)
            }
        }
        .glass(radius: 16, shadow: false)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct GroupCard: View {
    let model: DuplicatesModel
    let group: DuplicateGroup

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        let showsHint = model.ruleHint == group.id
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                FileThumbnail(url: group.files.first?.item.url ?? group.id, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.cardTitle)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(Fmt.copies(group.files.count)) по \(Fmt.size(group.copySize))")
                        .font(.caption12)
                        .foregroundStyle(.themeSecondary)
                    RuleLine(model: model, group: group)
                }
                Spacer(minLength: 8)
                if showsHint {
                    Label("Одна копия всегда остаётся", systemImage: "lock.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(Theme.warning.opacity(0.14)))
                        .overlay(Capsule().strokeBorder(Theme.warning.opacity(0.3), lineWidth: 0.5))
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("в Корзину")
                            .font(.caption11)
                            .foregroundStyle(.themeSecondary)
                        SizeText(bytes: model.markedSize(in: group),
                                 font: .system(size: 14, weight: .semibold, design: .rounded))
                    }
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Hairline().padding(.horizontal, 14)

            VStack(spacing: 0) {
                ForEach(group.files) { f in
                    CopyRow(model: model, group: group, file: f)
                }
            }
            .padding(.vertical, 4)
        }
        .background(shape.fill(.white.opacity(0.045)))
        .overlay(shape.strokeBorder(showsHint ? Theme.warning.opacity(0.45) : .white.opacity(0.07), lineWidth: 1))
        .animation(Theme.quick, value: showsHint)
    }
}

/// Why these copies are marked: the rule in one line, with a menu to pick the copy that stays instead.
private struct RuleLine: View {
    let model: DuplicatesModel
    let group: DuplicateGroup

    var body: some View {
        let kept = model.kept(in: group)
        HStack(spacing: 5) {
            Text(rule(kept))
                .foregroundStyle(.themeSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("·").foregroundStyle(.themeSecondary).accessibilityHidden(true)
            Menu {
                ForEach(group.files) { f in
                    let title = "Оставить копию в «\(folder(f))»"
                    let current = kept.count == 1 && kept[0].id == f.id
                    Button {
                        model.keepOnly(f, in: group)
                    } label: {
                        if current { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            } label: {
                Text("Изменить").fontWeight(.semibold).foregroundStyle(Theme.text)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Выбрать, какая копия останется")
            .accessibilityLabel("Изменить, какая копия останется")
        }
        .font(.system(size: 11.5))
    }

    private func rule(_ kept: [AnalyzedFile]) -> String {
        switch kept.count {
        case 1: "Оставляем копию в «\(folder(kept[0]))», остальные — в Корзину"
        case group.files.count: "Все копии остаются на диске"
        default: "Остаётся \(Fmt.copies(kept.count)), остальные — в Корзину"
        }
    }

    private func folder(_ file: AnalyzedFile) -> String { DuplicateFolder.title(file) }
}

enum DuplicateFolder {
    /// The folder a copy lives in, as the user knows it («Фильмы», «Загрузки»).
    static func title(_ file: AnalyzedFile) -> String {
        Fmt.folderTitle(file.item.url.deletingLastPathComponent())
    }
}

private struct CopyRow: View {
    let model: DuplicatesModel
    let group: DuplicateGroup
    let file: AnalyzedFile
    @State private var hover = false

    var body: some View {
        let removing = model.isMarked(file)
        let url = file.item.url
        HStack(spacing: 14) {
            KeepToggle(removing: removing, folder: DuplicateFolder.title(file), tint: .duplicates) {
                model.setRemove($0, file, in: group)
            }
            VStack(alignment: .leading, spacing: 2) {
                pathLine.opacity(removing ? 0.62 : 1)
                HStack(spacing: 8) {
                    Label(detail, systemImage: "calendar")
                        .labelStyle(TightLabel(weight: .regular))
                        .foregroundStyle(.themeSecondary)
                        .fixedSize()
                        .help("Дата изменения")
                    if file.id == group.oldestID {
                        Label("самая старая", systemImage: "clock.fill")
                            .labelStyle(TightLabel())
                            .foregroundStyle(.themeSecondary)
                            .fixedSize()
                    }
                    if removing {
                        Label("в Корзину", systemImage: "trash.fill")
                            .labelStyle(TightLabel())
                            .foregroundStyle(Theme.text)
                            .fixedSize()
                    }
                }
                .font(.system(size: 11))
            }
            .help(url.path)
            Spacer(minLength: 8)
            // All copies weigh the same: the size gives way to the actions on hover.
            ZStack(alignment: .trailing) {
                SizeText(bytes: file.item.size, font: .system(size: 12.5, weight: .medium, design: .rounded),
                         color: removing ? Theme.textSecondary : Theme.textTertiary)
                    .opacity(hover ? 0 : 1)
                HStack(spacing: 6) {
                    IconButton(symbol: "eye.fill", help: "Быстрый просмотр", size: 24) { model.quickLookURL = url }
                    IconButton(symbol: "magnifyingglass", help: "Показать в Finder", size: 24) { Finder.reveal(url) }
                }
                .opacity(hover ? 1 : 0)
            }
            .frame(minWidth: 60, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hover ? 0.045 : 0)).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button("Оставить только эту") { model.keepOnly(file, in: group) }
            Divider()
            Button("Быстрый просмотр") { model.quickLookURL = url }
            Button("Показать в Finder") { Finder.reveal(url) }
            Button("Скопировать путь") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
        }
    }

    /// Only the folder truncates (it is what tells copies apart). The file name is shown when it differs
    /// from the group title, so a renamed copy («… (1).dmg») is still recognisable.
    private var pathLine: some View {
        let folder = Fmt.path(file.item.url.deletingLastPathComponent()) + "/"
        let name = file.item.name
        return HStack(spacing: 0) {
            Text(folder)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if name != group.name {
                // Gives way to the folder: the folder is what tells the copies apart.
                Text(name)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .font(.rowTitle)
    }

    private var detail: String {
        guard let m = file.item.modified else { return "дата неизвестна" }
        return Fmt.date(m)
    }
}

/// Explicit two-state choice per copy: what happens to this file is always spelled out.
/// For VoiceOver it is one adjustable element («Копия в Загрузки, В Корзину»); the active segment is also
/// bold and outlined, so the state never rests on color alone.
private struct KeepToggle: View {
    let removing: Bool
    let folder: String
    let tint: ModuleTint
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment("Оставить", symbol: "checkmark", keep: true, active: !removing) { onChange(false) }
            segment("В Корзину", symbol: "trash.fill", keep: false, active: removing) { onChange(true) }
        }
        .padding(2)
        .background(Capsule().fill(.black.opacity(0.24)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.75))
        .fixedSize()
        .animation(Theme.quick, value: removing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Копия в \(folder)")
        .accessibilityValue(removing ? "В Корзину" : "Оставить")
        .accessibilityHint("Листайте, чтобы выбрать: оставить или в Корзину")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(true)
            case .decrement: onChange(false)
            @unknown default: break
            }
        }
    }

    private func segment(_ title: String, symbol: String, keep: Bool, active: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
                Text(title).font(.system(size: 11.5, weight: active ? .bold : .medium))
            }
            .foregroundStyle(active ? (keep ? Theme.success : .white) : Theme.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background {
                if active {
                    if keep {
                        Capsule().fill(Theme.success.opacity(0.16))
                            .overlay(Capsule().strokeBorder(Theme.success.opacity(0.65), lineWidth: 1.25))
                    } else {
                        Capsule().fill(tint.horizontal.opacity(0.7))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.7), lineWidth: 1.25))
                    }
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(keep ? "Оставить эту копию" : "Переместить эту копию в Корзину")
    }
}

private struct TightLabel: LabelStyle {
    var weight: Font.Weight = .medium
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9.5, weight: .semibold))
            configuration.title.fontWeight(weight)
        }
    }
}
