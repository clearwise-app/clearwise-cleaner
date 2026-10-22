import SwiftUI
import CleanerKit

struct JunkView: View {
    let model: JunkModel
    @Environment(AppModel.self) private var app

    var body: some View {
        switch model.phase {
        case .idle, .scanning:
            ModuleStage(module: .junk,
                        state: model.phase == .scanning ? .progress(model.progress) : .idle(button: "Сканировать", enabled: true),
                        onAction: model.startScan, onStop: model.stop,
                        onGrantAccess: { app.presentAccessSheet() })
        case .results, .cleaning:
            // While cleaning, the overlay covers this screen; it keeps showing the results underneath.
            if !model.categories.isEmpty {
                JunkResultsView(model: model)
            } else if model.phase == .results {
                VStack(spacing: 4) {
                    EmptyState(symbol: "checkmark.seal.fill", title: "Мусора не найдено",
                               message: "Кэши и журналы уже в порядке. Загляните позже — приложения со временем накопят новые.",
                               tint: .junk, actionTitle: "Сканировать заново", action: model.startScan)
                    PartialAccessNote(onGrantAccess: { app.presentAccessSheet() })
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .done:
            CompletionView(tint: .junk, result: model.result ?? RemovalResult(),
                           title: "Мусор убран", permanent: model.resultWasPermanent,
                           onGrantAccess: { app.presentAccessSheet() },
                           onRetry: model.retryFailed,
                           onEmptyTrash: { app.requestEmptyTrash() },
                           onDone: model.finish)
        }
    }
}

private struct JunkResultsView: View {
    let model: JunkModel
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            ResultsHeader(module: .junk, bytes: model.totalSize,
                          caption: "найдено · \(Fmt.categories(model.categories.count)) · \(Fmt.items(model.itemCount))",
                          onGrantAccess: { app.presentAccessSheet() }) {
                Button { model.startScan() } label: {
                    Label("Сканировать заново", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    SelectionBar(text: "Отмеченное попадёт в Корзину, остальное останется на месте",
                                 onDefaults: model.selectDefaults, onNone: model.selectNone)
                    ForEach(model.categories) { cat in
                        JunkCategoryCard(model: model, category: cat)
                    }
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.top, 22)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)

            ActionFooter(title: model.cleanVerb.button, tint: .junk, enabled: model.selectedCount > 0,
                         selectedBytes: model.selectedSize, selectedCount: model.selectedCount,
                         noun: .items, permanent: model.includesTrash, action: model.requestClean)
        }
    }
}

/// Category with its items and keep/delete checkboxes. Also used by Smart Care's review step.
struct JunkCategoryCard: View {
    let model: JunkModel
    let category: JunkCategory
    var tint: ModuleTint = .junk
    @State private var hover = false

    private static let pageSize = 200
    @State private var shown = pageSize

    var body: some View {
        let expanded = model.expanded.contains(category.id)
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                CheckBox(state: model.state(of: category), tint: tint, label: category.title) { model.toggle(category) }
                Button { model.toggleExpanded(category) } label: {
                    HStack(spacing: 14) {
                        IconTile(symbol: category.symbol, tint: tint, size: 36)
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
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "развёрнуто" : "свёрнуто")
                .accessibilityHint("Показать или скрыть файлы категории")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(Rectangle().fill(.white.opacity(hover && !expanded ? 0.03 : 0)))
            .onHover { hover = $0 }

            if expanded {
                Hairline()
                LazyVStack(spacing: 0) {
                    ForEach(category.items.prefix(shown)) { item in
                        FileRow(url: item.url, size: item.size, title: model.notes[item.url], isChecked: model.selection.contains(item.url),
                                tint: tint, indent: 30, onToggle: { model.toggle(item, in: category) })
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
