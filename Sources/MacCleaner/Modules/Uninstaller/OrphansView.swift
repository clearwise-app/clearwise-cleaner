import SwiftUI
import CleanerKit

/// Left panel of the "Остатки" tab: deleted apps that still have files on disk.
struct OrphanListPanel: View {
    let model: UninstallerModel
    @FocusState private var listFocused: Bool

    var body: some View {
        switch model.orphanState {
        case .notScanned:
            VStack(spacing: 14) {
                Spacer()
                IconTile(symbol: "questionmark.folder.fill", tint: .uninstaller, size: 52)
                    .accessibilityHidden(true)
                Text("Следы удалённых приложений")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Найдём настройки, кэши и службы приложений, которых уже нет на Mac.")
                    .font(.caption12)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 250)
                Button("Найти остатки", action: model.startOrphanScan)
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
                // The detail pane carries the full "all clean" state and the rescan button.
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.success)
                        .accessibilityHidden(true)
                    Text("Ничего не найдено")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(Fmt.apps(model.orphans.count).capitalizedFirst) · \(Fmt.size(model.orphansSize))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button(action: model.startOrphanScan) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .help("Проверить снова")
                .accessibilityLabel("Проверить снова")
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.orphans) { g in
                            OrphanRow(group: g, selected: model.focusedOrphanID == g.id, focused: listFocused,
                                      state: model.orphanState(of: g),
                                      onSelect: { listFocused = true; model.focusedOrphanID = g.id },
                                      onCheck: { model.toggleOrphanGroup(g) })
                                .id(g.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .onMoveCommand { direction in
                    switch direction {
                    case .up: model.moveOrphanFocus(by: -1)
                    case .down: model.moveOrphanFocus(by: 1)
                    default: break
                    }
                }
                .onKeyPress(.space) {
                    guard let g = model.focusedOrphan else { return .ignored }
                    model.toggleOrphanGroup(g)
                    return .handled
                }
                .onChange(of: model.focusedOrphanID) { _, id in
                    guard listFocused, let id else { return }
                    proxy.scrollTo(id)
                }
                .accessibilityLabel("Остатки удалённых приложений")
            }
        }
    }
}

private struct OrphanRow: View {
    let group: OrphanGroup
    let selected: Bool
    let focused: Bool
    let state: CheckState
    let onSelect: () -> Void
    let onCheck: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            CheckBox(state: state, tint: .uninstaller, label: group.displayName, action: onCheck)
            GhostAppIcon(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(Fmt.items(group.remnants.count))
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            SizeText(bytes: group.totalSize, font: .system(size: 12, weight: .medium, design: .rounded), color: Theme.textSecondary)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? AnyShapeStyle(ModuleTint.uninstaller.horizontal.opacity(0.32)) : AnyShapeStyle(Color.white.opacity(hover ? 0.06 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected && focused ? ModuleTint.uninstaller.accent.opacity(0.9) : .white.opacity(selected ? 0.16 : 0),
                                  lineWidth: selected && focused ? 1.5 : 0.75))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hover = $0 }
        // The bundle ID would truncate in the row: it lives in the tooltip and the detail header.
        .help(group.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.displayName), \(Fmt.size(group.totalSize)), \(Fmt.items(group.remnants.count))")
        .accessibilityValue(state == .on ? "отмечено" : state == .mixed ? "частично отмечено" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect() }
        .accessibilityAction(named: state == .on ? "Снять отметку" : "Отметить для удаления") { onCheck() }
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
        .accessibilityHidden(true)
    }
}

struct OrphanDetailView: View {
    let model: UninstallerModel

    var body: some View {
        if let g = model.focusedOrphan {
            let picked = model.selectedOrphanRemnants
            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    GhostAppIcon(size: 72)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(g.displayName)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .accessibilityAddTraits(.isHeader)
                        Text(g.id)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(g.id)
                        Text("Приложение удалено, но его файлы остались на диске.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    BigSize(bytes: g.totalSize, size: 40, weight: .light)
                        .fixedSize()
                }
                .padding(.horizontal, 30)
                .padding(.top, 28)

                ScrollView {
                    VStack(spacing: 12) {
                        RemnantGroups(remnants: g.remnants, selection: model.orphanSelection,
                                      toggle: model.toggleOrphan, toggleGroup: model.toggleOrphanItems)
                    }
                    .padding(.horizontal, 30)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                }

                ActionFooter(title: "Удалить", tint: .uninstaller, enabled: !picked.isEmpty,
                             action: model.requestRemoveOrphans) {
                    SelectionSummary(bytes: picked.reduce(0) { $0 + $1.item.size },
                                     count: picked.count, label: "Выбрано во всех приложениях", noun: .items)
                } trailing: {
                    FooterNote()
                }
            }
        } else if model.orphanState == .loaded {
            EmptyState(symbol: "checkmark.seal.fill", title: "Следов не осталось",
                       message: "Удалённые приложения не оставили на этом Mac настроек, кэшей и служб. Если удалите что-то перетаскиванием в Корзину — загляните сюда снова.",
                       tint: .uninstaller, actionTitle: "Проверить снова", action: model.startOrphanScan)
        } else {
            EmptyState(symbol: "questionmark.folder.fill", title: "Остатки удалённых приложений",
                       message: "Когда приложение удаляют простым перетаскиванием в Корзину, его настройки и кэши остаются. Здесь их можно найти и убрать.",
                       tint: .uninstaller)
        }
    }
}
