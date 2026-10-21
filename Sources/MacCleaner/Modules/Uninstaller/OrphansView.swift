import SwiftUI
import CleanerKit

/// Left panel of the "Остатки" tab: deleted apps that still have files on disk.
struct OrphanListPanel: View {
    let model: UninstallerModel

    var body: some View {
        switch model.orphanState {
        case .notScanned:
            VStack(spacing: 14) {
                Spacer()
                IconTile(symbol: "questionmark.folder.fill", tint: .uninstaller, size: 52)
                Text("Следы удалённых приложений")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Найдём настройки, кэши и службы приложений, которых уже нет на Mac.")
                    .font(.caption12)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 250)
                Button("Найти остатки") { Task { await model.scanOrphans() } }
                    .buttonStyle(PillButtonStyle(kind: .primary(.uninstaller)))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case .scanning:
            VStack(spacing: 12) {
                Spacer()
                ScanButton(mode: .progress(model.orphanProgress.fraction), tint: .uninstaller, diameter: 76)
                Text(model.orphanProgress.phase.isEmpty ? "Сканирование…" : model.orphanProgress.phase)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case .loaded:
            if model.orphans.isEmpty {
                EmptyState(symbol: "checkmark.seal.fill", title: "Чисто",
                           message: "Удалённые приложения не оставили следов.", tint: .uninstaller,
                           actionTitle: "Проверить снова") { Task { await model.scanOrphans() } }
                    .frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(Fmt.apps(model.orphans.count).capitalizedFirst) · \(Fmt.size(model.orphansSize))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Button { Task { await model.scanOrphans() } } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                        .help("Проверить снова")
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.orphans) { g in
                                OrphanRow(group: g, selected: model.focusedOrphanID == g.id, state: model.orphanState(of: g),
                                          onSelect: { model.focusedOrphanID = g.id },
                                          onCheck: { model.toggleOrphanGroup(g) })
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 12)
                    }
                }
            }
        }
    }
}

private struct OrphanRow: View {
    let group: OrphanGroup
    let selected: Bool
    let state: CheckState
    let onSelect: () -> Void
    let onCheck: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            CheckBox(state: state, tint: .uninstaller, action: onCheck)
            GhostAppIcon(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text("\(Fmt.items(group.remnants.count)) · \(group.id)")
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            SizeText(bytes: group.totalSize, font: .system(size: 12, weight: .medium, design: .rounded), color: Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? AnyShapeStyle(ModuleTint.uninstaller.horizontal.opacity(0.32)) : AnyShapeStyle(Color.white.opacity(hover ? 0.06 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(selected ? 0.16 : 0), lineWidth: 0.75))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hover = $0 }
    }
}

/// Dashed "missing app" icon for leftovers whose app is gone.
struct GhostAppIcon: View {
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(.white.opacity(0.06))
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                .foregroundStyle(.white.opacity(0.35))
            Image(systemName: "questionmark")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(width: size, height: size)
    }
}

struct OrphanDetailView: View {
    let model: UninstallerModel

    var body: some View {
        if let g = model.focusedOrphan {
            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    GhostAppIcon(size: 72)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(g.displayName)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text(g.id)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                        Text("Приложение удалено, но его файлы остались на диске.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    BigSize(bytes: g.totalSize, size: 40, weight: .light)
                }
                .padding(.horizontal, 30)
                .padding(.top, 28)

                ScrollView {
                    VStack(spacing: 12) {
                        RemnantGroups(remnants: g.remnants, selection: model.orphanSelection,
                                      toggle: model.toggleOrphan, toggleGroup: { items in
                                          let ids = items.map(\.id)
                                          if ids.allSatisfy(model.orphanSelection.contains) { model.orphanSelection.subtract(ids) }
                                          else { model.orphanSelection.formUnion(ids) }
                                      })
                    }
                    .padding(.horizontal, 30)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                }

                ActionFooter(title: "Удалить", tint: .uninstaller, enabled: !model.selectedOrphanRemnants.isEmpty,
                             action: model.requestRemoveOrphans) {
                    SelectionSummary(bytes: model.selectedOrphanRemnants.reduce(0) { $0 + $1.item.size },
                                     count: model.selectedOrphanRemnants.count, label: "Выбрано во всех приложениях")
                } trailing: {
                    Label("Всё попадёт в Корзину", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        } else {
            EmptyState(symbol: "questionmark.folder.fill", title: "Остатки удалённых приложений",
                       message: "Когда приложение удаляют простым перетаскиванием в Корзину, его настройки и кэши остаются. Здесь их можно найти и убрать.",
                       tint: .uninstaller)
        }
    }
}
