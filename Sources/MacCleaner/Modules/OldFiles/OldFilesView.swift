import SwiftUI
import CleanerKit
import SpaceEngine
import QuickLook

struct OldFilesView: View {
    @Bindable var model: OldFilesModel

    var body: some View {
        switch model.phase {
        case .idle, .scanning:
            ModuleStage(module: .oldFiles,
                        state: model.phase == .scanning ? .progress(model.progress)
                            : .idle(button: "Сканировать", enabled: !model.activeRoots.isEmpty),
                        onAction: model.startScan, onStop: model.stop) {
                OldFilesOptionsView(model: model)
            }
        case .results:
            OldFilesResults(model: model)
        case .cleaning:
            ModuleStage(module: .oldFiles, title: "Перемещаем в Корзину", subtitle: "Ещё пара секунд…", state: .busy(""))
        case .done:
            CompletionView(tint: .oldFiles, result: model.result ?? RemovalResult(), title: "Место освобождено",
                           onDone: model.finish)
        }
    }
}

private struct OldFilesOptionsView: View {
    @Bindable var model: OldFilesModel

    var body: some View {
        VStack(spacing: 16) {
            Segmented(options: [(OldFilesModel.Mode.old, "Давно не использовались"), (.large, "Большие")],
                      selection: $model.mode, tint: .oldFiles)

            HStack(spacing: 22) {
                if model.mode == .old {
                    labeled("Не открывались") {
                        Segmented(options: OldFilesModel.periodOptions.map { ($0, "\($0) мес.") },
                                  selection: $model.months, tint: .oldFiles, compact: true)
                    }
                }
                labeled("Размер от") {
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
                Chip(title: "Папка…", symbol: "plus", selected: false, tint: .oldFiles) { model.addRoot() }
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

    var body: some View {
        if model.files.isEmpty {
            EmptyState(symbol: "checkmark.seal.fill", title: "Ничего не найдено",
                       message: "\(caption.capitalizedFirst). Попробуйте уменьшить порог размера или срок.",
                       tint: .oldFiles, actionTitle: "Изменить параметры", action: model.newScan)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                ResultsHeader(module: .oldFiles, bytes: model.totalSize, caption: caption) {
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

                ActionFooter(title: "В Корзину", tint: .oldFiles, enabled: !model.selection.isEmpty,
                             action: model.requestTrash) {
                    SelectionSummary(bytes: model.selectedSize, count: model.selection.count)
                } trailing: {
                    Label("Ничего не выбрано заранее — это ваши файлы", systemImage: "hand.raised.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .quickLookPreview($model.quickLookURL, in: model.visibleFiles.map(\.item.url))
        }
    }

    private var caption: String {
        let n = Fmt.files(model.files.count)
        switch model.resultMode {
        case .old: return model.files.isEmpty ? "нет файлов, которые не открывались больше \(model.months) мес." : "\(n) не открывались больше \(model.months) мес."
        case .large: return model.files.isEmpty ? "нет файлов крупнее \(Fmt.size(model.largeMinSize))" : "\(n) крупнее \(Fmt.size(model.largeMinSize))"
        }
    }
}

private struct KindsColumn: View {
    let model: OldFilesModel

    var body: some View {
        VStack(spacing: 2) {
            KindRow(symbol: "square.grid.2x2.fill", title: "Все файлы", count: model.files.count, size: model.totalSize,
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
                CheckBox(state: CheckState(selected: files.filter { model.selection.contains($0.id) }.count, total: files.count),
                         tint: .oldFiles) {
                    let ids = files.map(\.id)
                    if ids.allSatisfy(model.selection.contains) { model.selection.subtract(ids) } else { model.selection.formUnion(ids) }
                }
                .help("Выбрать все в списке")
                Text(model.kindFilter?.title ?? "Все файлы")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Segmented(options: [(OldFilesModel.Sort.size, "Размер"), (.date, "Дата"), (.name, "Имя")],
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
        if let used = f.item.lastUsed { return "открывался \(Fmt.ago(used))" }
        if let mod = f.item.modified { return "изменён \(Fmt.ago(mod))" }
        return "не открывался"
    }
}
