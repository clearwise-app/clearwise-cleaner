import SwiftUI
import CleanerKit

struct JunkView: View {
    let model: JunkModel

    var body: some View {
        switch model.phase {
        case .idle, .scanning:
            ModuleStage(module: .junk,
                        state: model.phase == .scanning ? .progress(model.progress) : .idle(button: "Сканировать", enabled: true),
                        onAction: model.startScan, onStop: model.stop)
        case .results:
            if model.categories.isEmpty {
                EmptyState(symbol: "checkmark.seal.fill", title: "Мусора не найдено",
                           message: "Кэши и журналы уже в порядке. Загляните позже — приложения со временем накопят новые.",
                           tint: .junk, actionTitle: "Сканировать заново", action: model.startScan)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                JunkResultsView(model: model)
            }
        case .cleaning:
            ModuleStage(module: .junk, title: "Очистка", subtitle: "Перемещаем выбранное в Корзину…",
                        state: .busy("Это займёт несколько секунд"))
        case .done:
            CompletionView(tint: .junk, result: model.result ?? RemovalResult(),
                           title: "Мусор убран", permanent: model.resultWasPermanent, onDone: model.finish)
        }
    }
}

private struct JunkResultsView: View {
    let model: JunkModel

    var body: some View {
        VStack(spacing: 0) {
            ResultsHeader(module: .junk, bytes: model.totalSize,
                          caption: "найдено · \(Fmt.categories(model.categories.count)) · \(Fmt.items(model.itemCount))") {
                Button { model.startScan() } label: {
                    Label("Сканировать заново", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.categories) { cat in
                        JunkCategoryCard(model: model, category: cat)
                    }
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.top, 22)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)

            ActionFooter(title: "Очистить", tint: .junk, enabled: model.selectedCount > 0, action: model.requestClean) {
                SelectionSummary(bytes: model.selectedSize, count: model.selectedCount)
            } trailing: {
                Label(model.includesTrash ? "Корзина очищается безвозвратно" : "Всё попадёт в Корзину",
                      systemImage: model.includesTrash ? "exclamationmark.triangle.fill" : "arrow.uturn.backward")
                    .font(.system(size: 12))
                    .foregroundStyle(model.includesTrash ? Theme.warning : Theme.textTertiary)
            }
        }
    }
}

private struct JunkCategoryCard: View {
    let model: JunkModel
    let category: JunkCategory
    @State private var hover = false

    private static let pageSize = 200
    @State private var shown = pageSize

    var body: some View {
        let expanded = model.expanded.contains(category.id)
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                CheckBox(state: model.state(of: category), tint: .junk) { model.toggle(category) }
                IconTile(symbol: category.symbol, tint: .junk, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(category.title)
                            .font(.cardTitle)
                            .foregroundStyle(Theme.text)
                        RiskBadge(risk: category.risk)
                    }
                    Text(category.detail)
                        .font(.caption12)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    SizeText(bytes: category.totalSize, font: .system(size: 15, weight: .semibold, design: .rounded))
                    Text(Fmt.items(category.items.count))
                        .font(.caption11)
                        .foregroundStyle(Theme.textTertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 16)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
            .onTapGesture { model.toggleExpanded(category) }
            .background(Rectangle().fill(.white.opacity(hover && !expanded ? 0.03 : 0)))
            .onHover { hover = $0 }

            if expanded {
                Hairline()
                LazyVStack(spacing: 0) {
                    ForEach(category.items.prefix(shown)) { item in
                        FileRow(url: item.url, size: item.size, title: model.notes[item.url], isChecked: model.selection.contains(item.url),
                                tint: .junk, indent: 30, onToggle: { model.toggle(item) })
                    }
                    if category.items.count > shown {
                        Button("Показать ещё \(Fmt.integer(min(Self.pageSize, category.items.count - shown)))") {
                            shown += Self.pageSize
                        }
                        .buttonStyle(PillButtonStyle(kind: .quiet))
                        .padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 4)
                .transition(.opacity)
            }
        }
        .glass(radius: 16, shadow: false)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
