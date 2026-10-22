import SwiftUI
import CleanerKit
import SpaceEngine
import QuickLook

struct OldFilesView: View {
    @Bindable var model: OldFilesModel
    @Environment(AppModel.self) private var app

    var body: some View {
        switch model.phase {
        case .idle, .scanning:
            ModuleStage(module: .oldFiles,
                        state: model.phase == .scanning ? .progress(model.progress)
                            : .idle(button: String(localized: "Сканировать"), enabled: !model.activeRoots.isEmpty),
                        onAction: model.startScan, onStop: model.stop,
                        onGrantAccess: app.presentAccessSheet) {
                OldFilesOptionsView(model: model)
            }
        case .results, .cleaning:
            // While files move, the cleaning scene covers this screen; there is no screen of its own.
            OldFilesResults(model: model)
        case .done:
            CompletionView(tint: .oldFiles, result: model.result ?? RemovalResult(), title: String(localized: "Перемещено в Корзину"),
                           noun: .files,
                           onGrantAccess: app.presentAccessSheet,
                           onRetry: model.retryFailed,
                           onEmptyTrash: app.requestEmptyTrash,
                           onDone: model.finish)
        }
    }
}

private struct OldFilesOptionsView: View {
    @Bindable var model: OldFilesModel

    var body: some View {
        VStack(spacing: 16) {
            Segmented(options: [(OldFilesModel.Mode.old, String(localized: "Давно не открывались")), (.large, String(localized: "Большие"))],
                      selection: $model.mode, tint: .oldFiles)

            HStack(spacing: 22) {
                if model.mode == .old {
                    labeled(String(localized: "Не открывались")) {
                        Segmented(options: OldFilesModel.periodOptions.map { ($0, String(localized: "\($0) мес.")) },
                                  selection: $model.months, tint: .oldFiles, compact: true)
                    }
                }
                labeled(String(localized: "Размер от")) {
                    Segmented(options: OldFilesModel.sizeOptions.map { ($0, Fmt.size($0)) },
                              selection: $model.minSize, tint: .oldFiles, compact: true)
                }
            }

            HStack(spacing: 6) {
                Text("Где искать:")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                ForEach(model.roots, id: \.self) { url in
                    Chip(title: Fmt.folderTitle(url), selected: !model.disabledRoots.contains(url), tint: .oldFiles) {
                        model.toggleRoot(url)
                    }
                }
                Chip(title: String(localized: "Папка…"), symbol: "plus", selected: false, tint: .oldFiles) { model.addRoot() }
            }
        }
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            content()
        }
    }
}

private struct OldFilesResults: View {
    @Bindable var model: OldFilesModel
    @Environment(AppModel.self) private var app

    var body: some View {
        if model.files.isEmpty {
            VStack(spacing: 0) {
                EmptyState(symbol: "checkmark.seal.fill", title: String(localized: "Ничего не нашлось"),
                           message: emptyMessage, tint: .oldFiles,
                           actionTitle: String(localized: "Изменить параметры"), action: model.newScan)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PartialAccessNote(onGrantAccess: app.presentAccessSheet)
                    .padding(.bottom, 26)
            }
        } else {
            VStack(spacing: 0) {
                ResultsHeader(module: .oldFiles, bytes: model.totalSize, caption: caption,
                              onGrantAccess: app.presentAccessSheet) {
                    HStack(spacing: 8) {
                        Button { model.newScan() } label: { Label("Параметры", systemImage: "slider.horizontal.3") }
                            .buttonStyle(PillButtonStyle(kind: .quiet))
                        Button { model.startScan() } label: { Label("Сканировать заново", systemImage: "arrow.clockwise") }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    KindsColumn(model: model)
                        .frame(width: 236)
                    FilesList(model: model)
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.top, 22)
                .padding(.bottom, 4)

                ActionFooter(title: String(localized: "В Корзину"), tint: .oldFiles, enabled: !model.selection.isEmpty,
                             action: model.requestTrash) {
                    SelectionSummary(bytes: model.selectedSize, count: model.selection.count, noun: .files)
                } trailing: {
                    // Nothing is ticked for the user: say so while the selection is empty, then say where it goes.
                    if model.selection.isEmpty {
                        Label("Ничего не выбрано заранее — это ваши файлы", systemImage: "hand.raised.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.themeTertiary)
                    } else {
                        FooterNote()
                    }
                }
            }
            .quickLookPreview($model.quickLookURL, in: model.visibleURLs)
        }
    }

    /// «1 файл не открывался больше 6 месяцев», «13 файлов крупнее 100 МБ».
    private var caption: String {
        let n = model.files.count
        switch model.resultMode {
        case .old:
            return String(localized: "\(Fmt.files(n)) \(Fmt.verb(n, one: "не открывался", other: "не открывались")) больше \(Fmt.months(model.months))")
        case .large:
            return String(localized: "\(Fmt.files(n)) крупнее \(Fmt.size(model.largeMinSize))")
        }
    }

    private var emptyMessage: String {
        switch model.resultMode {
        case .old:
            String(localized: "Нет файлов от \(Fmt.size(model.oldMinSize)), которые не открывались больше \(Fmt.months(model.months)). Уменьшите размер или срок — или добавьте папку.")
        case .large:
            String(localized: "Нет файлов крупнее \(Fmt.size(model.largeMinSize)) в выбранных папках. Уменьшите размер или добавьте папку.")
        }
    }
}

private struct KindsColumn: View {
    let model: OldFilesModel

    var body: some View {
        VStack(spacing: 2) {
            KindRow(symbol: "square.grid.2x2.fill", title: String(localized: "Все файлы"), count: model.files.count, size: model.totalSize,
                    fraction: 1, selected: model.kindFilter == nil) { model.kindFilter = nil }
            Hairline().padding(.vertical, 4).padding(.horizontal, 8)
            ForEach(model.kinds, id: \.kind) { k in
                KindRow(symbol: k.kind.symbol, title: k.kind.title, count: k.count, size: k.size,
                        fraction: Double(k.size) / Double(max(1, model.totalSize)),
                        selected: model.kindFilter == k.kind) {
                    withAnimation(Theme.quick) { model.kindFilter = k.kind }
                }
            }
        }
        .padding(6)
        .glass(radius: 16, shadow: false)
    }
}

private struct KindRow: View {
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
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    IconTile(symbol: symbol, tint: .oldFiles, size: 26, muted: !selected)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(Fmt.files(count)).font(.caption11).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 4)
                    SizeText(bytes: size, font: .system(size: 12, weight: .semibold, design: .rounded), color: Theme.textSecondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(selected ? 0.12 : (hover ? 0.05 : 0)))
            )
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geo in
                    Capsule().fill(ModuleTint.oldFiles.horizontal.opacity(selected ? 0.9 : 0.45))
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

private struct FilesList: View {
    @Bindable var model: OldFilesModel

    var body: some View {
        let files = model.visibleFiles
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                CheckBox(state: CheckState(selected: model.selectedCount(in: files), total: files.count),
                         tint: .oldFiles, label: String(localized: "Выбрать все в списке")) {
                    model.toggleAll(in: files)
                }
                Text(model.kindFilter?.title ?? String(localized: "Все файлы"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Segmented(options: [(OldFilesModel.Sort.size, String(localized: "Размер")), (.date, String(localized: "Дата")), (.name, String(localized: "Имя"))],
                          selection: $model.sort, tint: .oldFiles, compact: true)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            Hairline()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(files) { f in
                        FileRow(url: f.item.url, size: f.item.size, isChecked: model.selection.contains(f.id), tint: .oldFiles,
                                detail: detail(f), onToggle: { model.toggle(f) },
                                onQuickLook: { model.quickLookURL = f.item.url })
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .glass(radius: 16, shadow: false)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func detail(_ f: AnalyzedFile) -> String {
        if let used = f.item.lastUsed { return String(localized: "открывался \(Fmt.ago(used))") }
        if let mod = f.item.modified { return String(localized: "изменён \(Fmt.ago(mod))") }
        return String(localized: "не открывался")
    }
}
