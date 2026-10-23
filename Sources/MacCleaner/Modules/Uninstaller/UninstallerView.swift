import SwiftUI
import CleanerKit

struct UninstallerView: View {
    let model: UninstallerModel
    @Environment(AppModel.self) private var app
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        Group {
            switch model.phase {
            case .idle, .scanning:
                ModuleStage(module: .uninstaller,
                            state: model.phase == .scanning ? .progress(app.appsProgress)
                                                            : .idle(button: String(localized: "Показать приложения"), enabled: true),
                            onAction: model.startScan, onGrantAccess: { app.presentAccessSheet() }) {
                    DropHint()
                }
            case .results, .cleaning:
                // The cleaning overlay covers the module while a removal runs; the browser stays underneath.
                UninstallerBrowser(model: model)
            case .done:
                completion
            }
        }
        .onAppear { model.onAppear(observeWorkspace: !isSnapshot) }
    }

    private var completion: some View {
        let retry: (() -> Void)? = model.canRetry ? { model.retry() } : nil
        return CompletionView(tint: .uninstaller, result: model.result ?? RemovalResult(), title: model.resultTitle,
                              noun: .items,
                              onGrantAccess: { app.presentAccessSheet() },
                              onRetry: retry,
                              onEmptyTrash: { app.requestEmptyTrash() },
                              onDone: { model.finish() })
    }
}

private struct DropHint: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ModuleTint.uninstaller.accent)
                .accessibilityHidden(true)
            Text("Можно просто перетащить приложение в это окно")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 18)
        .frame(height: 40)
        .background(
            Capsule()
                .strokeBorder(style: StrokeStyle(lineWidth: 1.25, dash: [5, 5]))
                .foregroundStyle(.white.opacity(0.28))
        )
    }
}

// MARK: - Browser (list + detail)

private struct UninstallerBrowser: View {
    @Bindable var model: UninstallerModel

    var body: some View {
        let batch = model.tab == .apps ? model.checkedAppList : []
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Segmented(options: [(UninstallerModel.Tab.apps, String(localized: "Приложения")), (.leftovers, String(localized: "Остатки"))],
                          selection: $model.tab, tint: .uninstaller)
                    .padding(.top, 22)
                    .padding(.bottom, 14)
                if model.tab == .apps {
                    AppListPanel(model: model, checked: batch)
                } else {
                    OrphanListPanel(model: model)
                }
            }
            .frame(width: 332)
            .background(Color.black.opacity(0.14))
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }

            Group {
                if model.tab == .leftovers {
                    OrphanDetailView(model: model)
                } else if !batch.isEmpty {
                    // Checked apps replace the single-app detail: one list, one total, one «Удалить».
                    BatchSummaryView(model: model, apps: batch)
                } else {
                    AppDetailView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - App list

private struct AppListPanel: View {
    @Bindable var model: UninstallerModel
    /// Checked apps (system apps excluded), computed once by the parent.
    let checked: [InstalledApp]
    @Environment(AppModel.self) private var app
    @FocusState private var listFocused: Bool

    var body: some View {
        let apps = model.visibleApps
        let batchMode = !checked.isEmpty
        VStack(spacing: 0) {
            // ⌘F (`AppModel.requestSearchFocus`) bumps the request; the field focuses itself on change.
            SearchField(text: $model.search, prompt: String(localized: "Поиск приложений"), focusRequest: app.searchFocusRequest)
                .padding(.horizontal, 16)

            HStack(spacing: 6) {
                Chip(title: String(localized: "Все"), selected: model.filter == .all, tint: .uninstaller) { model.filter = .all }
                Chip(title: String(localized: "Давно не открывались"), selected: model.filter == .unused, tint: .uninstaller) { model.filter = .unused }
                Chip(title: "App Store", selected: model.filter == .appStore, tint: .uninstaller) { model.filter = .appStore }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            HStack {
                Text(Fmt.apps(apps.count))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                SortMenu(sort: $model.sort, showSystem: $model.showSystemApps)
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 4)

            if app.appsState == .loading && apps.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Ищем приложения…").font(.caption12).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if apps.isEmpty {
                Text(model.search.isEmpty ? String(localized: "Нет приложений с этим фильтром") : String(localized: "Ничего не найдено по «\(model.search)»"))
                    .font(.caption12)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(apps) { a in
                                let isChecked = model.checkedApps.contains(a.url)
                                AppRow(app: a, selected: model.selectedAppID == a.url, focused: listFocused,
                                       checked: isChecked, running: model.isRunning(a), batchMode: batchMode,
                                       onSelect: {
                                           listFocused = true
                                           if batchMode { model.toggleChecked(a) } else { model.select(a) }
                                       },
                                       onCheck: { model.toggleChecked(a) })
                                    .id(a.url)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 12)
                    }
                    // Arrow keys move the selection, Space checks it (macOS list behaviour).
                    .focusable()
                    .focusEffectDisabled()
                    .focused($listFocused)
                    .onMoveCommand { direction in
                        switch direction {
                        case .up: model.moveSelection(by: -1, in: apps)
                        case .down: model.moveSelection(by: 1, in: apps)
                        default: break
                        }
                    }
                    .onKeyPress(.space) {
                        guard let a = model.selectedApp else { return .ignored }
                        model.toggleChecked(a)
                        return .handled
                    }
                    .onChange(of: model.selectedAppID) { _, id in
                        guard listFocused, let id else { return }
                        proxy.scrollTo(id)
                    }
                    .accessibilityLabel("Приложения")
                }
            }

            // Only the bar's own insertion animates; the list above just resizes.
            VStack(spacing: 0) {
                if batchMode {
                    BatchBar(apps: checked, onClear: model.clearChecked)
                        .padding(12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Theme.spring, value: batchMode)
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String
    /// Bump to move keyboard focus into the field (⌘F).
    var focusRequest = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .focused($focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Очистить поиск")
                .accessibilityLabel("Очистить поиск")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(focused ? ModuleTint.uninstaller.accent.opacity(0.7) : .white.opacity(0.1), lineWidth: 1))
        .onChange(of: focusRequest) { focused = true }
    }
}

private struct SortMenu: View {
    @Binding var sort: UninstallerModel.Sort
    @Binding var showSystem: Bool

    private var title: String {
        switch sort {
        case .size: String(localized: "По размеру")
        case .name: String(localized: "По имени")
        case .lastUsed: String(localized: "Давно не открывались")
        }
    }

    var body: some View {
        Menu {
            Picker("Сортировка", selection: $sort) {
                Text("По размеру").tag(UninstallerModel.Sort.size)
                Text("По имени").tag(UninstallerModel.Sort.name)
                Text("Давно не открывались").tag(UninstallerModel.Sort.lastUsed)
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Показывать системные приложения", isOn: $showSystem)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Сортировка: \(title)")
    }
}

/// «2 дня назад» / «не открывалось 8 месяцев» with a clock, or the system-app note.
private struct LastUsedLabel: View {
    let app: InstalledApp

    var body: some View {
        let idle = Fmt.idleHint(app.lastUsed)
        HStack(spacing: 4) {
            Image(systemName: app.isSystemApp ? "lock.fill" : "clock")
                .font(.system(size: 9.5, weight: .semibold))
                .accessibilityHidden(true)
            Text(text(idle))
                .lineLimit(1)
        }
        .font(.caption11)
        .foregroundStyle(idle != nil && !app.isSystemApp ? Theme.warning.opacity(0.9) : Theme.textTertiary)
    }

    private func text(_ idle: String?) -> String {
        if app.isSystemApp { return String(localized: "Системное — не удаляется") }
        return idle ?? Fmt.ago(app.lastUsed)
    }

    static func spoken(_ app: InstalledApp) -> String {
        if app.isSystemApp { return String(localized: "системное, не удаляется") }
        return Fmt.idleHint(app.lastUsed) ?? String(localized: "открывалось \(Fmt.ago(app.lastUsed))")
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let selected: Bool
    /// The list has keyboard focus: the selected row draws the focus ring.
    let focused: Bool
    let checked: Bool
    let running: Bool
    /// Some apps are checked: a click checks instead of opening the detail.
    let batchMode: Bool
    let onSelect: () -> Void
    let onCheck: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            CheckBox(state: checked ? .on : .off, tint: .uninstaller, disabled: app.isSystemApp, label: app.name, action: onCheck)
            FileIcon(url: app.url, size: 34)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                .overlay(alignment: .bottomTrailing) {
                    if running {
                        Circle().fill(Theme.success).frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                            .help("Запущено")
                    }
                }
            // Size sits on the name line so the date line gets the full width and never truncates.
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !app.isSystemApp {
                        SizeText(bytes: app.size, font: .system(size: 12, weight: .medium, design: .rounded),
                                 color: Theme.textSecondary)
                            .fixedSize()
                    }
                }
                LastUsedLabel(app: app)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? AnyShapeStyle(ModuleTint.uninstaller.horizontal.opacity(batchMode ? 0.16 : 0.32))
                               : AnyShapeStyle(Color.white.opacity(hover ? 0.06 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected && focused ? ModuleTint.uninstaller.accent.opacity(0.9) : .white.opacity(selected ? 0.16 : 0),
                                  lineWidth: selected && focused ? 1.5 : 0.75))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hover = $0 }
        .opacity(app.isSystemApp ? 0.55 : 1)
        .help(app.bundleID ?? app.url.path)
        .contextMenu {
            Button("Показать в Finder") { Finder.reveal(app.url) }
            if !app.isSystemApp {
                Button(checked ? String(localized: "Снять отметку") : String(localized: "Отметить для удаления"), action: onCheck)
            }
        }
        // VoiceOver: one element per app; activating it opens the detail, the action checks it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(app.name), \(app.isSystemApp ? "" : Fmt.size(app.size) + ", ")\(LastUsedLabel.spoken(app))\(running ? ", " + String(localized: "запущено") : "")")
        .accessibilityValue(checked ? String(localized: "отмечено") : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect() }
        .accessibilityAction(named: checked ? String(localized: "Снять отметку") : String(localized: "Отметить для удаления")) { if !app.isSystemApp { onCheck() } }
        .accessibilityAction(named: "Показать в Finder") { Finder.reveal(app.url) }
    }
}

/// Compact one-line reminder under the list: what is checked and how to clear it.
private struct BatchBar: View {
    let apps: [InstalledApp]
    let onClear: () -> Void

    var body: some View {
        let bytes = apps.reduce(Int64(0)) { $0 + $1.size }
        HStack(spacing: 10) {
            HStack(spacing: -9) {
                ForEach(apps.prefix(3)) { a in
                    FileIcon(url: a.url, size: 24)
                }
            }
            .accessibilityHidden(true)
            if apps.count > 3 {
                Text("+\(apps.count - 3)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
            }
            Text("\(Fmt.size(bytes)) + остатки")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 4)
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Снять отметки")
            .accessibilityLabel("Снять отметки")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .glass(radius: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Отмечено \(Fmt.apps(apps.count)), \(Fmt.size(bytes)) плюс остатки")
    }
}

// MARK: - Batch summary

private struct BatchSummaryView: View {
    let model: UninstallerModel
    let apps: [InstalledApp]

    var body: some View {
        let totals = model.batchTotals(apps)
        let n = apps.count
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    ForEach(Array(apps.prefix(3).enumerated().reversed()), id: \.element.id) { i, a in
                        FileIcon(url: a.url, size: 58)
                            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                            .offset(x: CGFloat(i) * 14, y: CGFloat(i) * -4)
                    }
                }
                .frame(width: 58 + CGFloat(min(n, 3) - 1) * 14, height: 68, alignment: .leading)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(Fmt.apps(n).capitalizedFirst)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Text("Вместе с остатками — только точные совпадения.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    BigSize(bytes: totals.total, size: 36, weight: .light)
                    Text("приложения \(Fmt.size(totals.appsSize))")
                    Text("остатки \(totals.loading ? String(localized: "ищем…") : Fmt.size(totals.remnantsSize))")
                }
                .font(.caption12)
                .foregroundStyle(Theme.textTertiary)
                .monospacedDigit()
                .fixedSize()
            }
            .padding(.horizontal, 30)
            .padding(.top, 28)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Hairline() }
                        BatchAppRow(app: a, remnants: model.batchRemnants[a.url], running: model.isRunning(a),
                                    onRemove: { model.toggleChecked(a) })
                    }
                }
                .padding(.vertical, 2)
                .glass(radius: 16, shadow: false)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 30)
                .padding(.top, 20)
                .padding(.bottom, 12)
            }

            ActionFooter(title: String(localized: "Удалить \(n)"), tint: .uninstaller, action: model.requestBatchUninstall) {
                SelectionSummary(bytes: totals.total, count: totals.count, label: String(localized: "Будет удалено"), noun: .items)
            } trailing: {
                Button("Снять отметки", action: model.clearChecked)
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .help("Вернуться к одному приложению")
            }
        }
    }
}

private struct BatchAppRow: View {
    let app: InstalledApp
    let remnants: [AppRemnant]?
    let running: Bool
    let onRemove: () -> Void

    var body: some View {
        let leftovers = remnants?.reduce(Int64(0)) { $0 + $1.item.size }
        HStack(spacing: 12) {
            FileIcon(url: app.url, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if running {
                        Badge(text: String(localized: "Запущено"), color: Theme.success, symbol: "play.fill")
                            .help("При удалении приложение будет закрыто")
                    }
                }
                Group {
                    if let remnants, let leftovers {
                        Text("приложение \(Fmt.size(app.size)) · остатки \(remnants.isEmpty ? String(localized: "не найдены") : "\(Fmt.size(leftovers)), \(Fmt.items(remnants.count))")")
                    } else {
                        Text("приложение \(Fmt.size(app.size)) · ищем остатки…")
                    }
                }
                .font(.caption11)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            SizeText(bytes: app.size + (leftovers ?? 0), font: .system(size: 12.5, weight: .semibold, design: .rounded),
                     color: Theme.textSecondary)
                .fixedSize()
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Не удалять «\(app.name)»")
            .accessibilityLabel("Не удалять «\(app.name)»")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .help(app.bundleID ?? app.url.path)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - App detail

private struct AppDetailView: View {
    let model: UninstallerModel

    var body: some View {
        if model.preparingDrop {
            ProgressView("Открываем приложение…")
                .controlSize(.small)
                .foregroundStyle(Theme.textSecondary)
        } else if let a = model.selectedApp {
            let running = model.isRunning(a)
            VStack(spacing: 0) {
                AppHeader(app: a, running: running, remnantsSize: model.remnantsSize, remnantsLoading: model.remnantsLoading)
                    .padding(.horizontal, 30)
                    .padding(.top, 28)

                ScrollView {
                    VStack(spacing: 12) {
                        // The bundle itself — always part of «Удалить».
                        RemnantSection(title: String(localized: "Приложение"), symbol: "macwindow", total: a.size) {
                            FileRow(url: a.url, size: a.size, tint: .uninstaller) {
                                if a.isAppStore { Badge(text: "App Store", color: ModuleTint.uninstaller.accent) }
                            }
                        }
                        if a.isSystemApp {
                            InfoCard(symbol: "lock.shield.fill", color: .white.opacity(0.75),
                                     text: String(localized: "«\(a.name)» входит в macOS. Системные приложения защищены: их нельзя удалить или сбросить, а обновление macOS всё равно вернёт их на место."))
                        } else if model.remnantsLoading {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Ищем настройки, кэши и службы приложения…")
                                    .font(.caption12).foregroundStyle(Theme.textSecondary)
                                Spacer()
                            }
                            .padding(16)
                            .glass(radius: 16, shadow: false)
                        } else if model.remnants.isEmpty {
                            InfoCard(symbol: "checkmark.seal.fill", color: Theme.success,
                                     text: String(localized: "Других файлов не найдено — приложение хранит всё внутри себя."))
                        } else {
                            RemnantGroups(remnants: model.remnants, selection: model.remnantSelection,
                                          toggle: model.toggle, toggleGroup: model.toggleGroup)
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                }

                if !a.isSystemApp {
                    ActionFooter(title: String(localized: "Удалить"), tint: .uninstaller, action: model.requestUninstall) {
                        SelectionSummary(bytes: a.size + model.selectedRemnantsSize,
                                         count: 1 + model.selectedRemnants.count, label: String(localized: "Будет удалено"), noun: .items)
                    } trailing: {
                        Button(action: model.requestReset) {
                            Label("Сбросить данные", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .disabled(model.selectedRemnants.isEmpty)
                        .help("Удалить только настройки и данные, оставив само приложение")
                    }
                }
            }
        } else {
            EmptyState(symbol: "arrow.down.app.fill", title: String(localized: "Выберите приложение"),
                       message: String(localized: "Или перетащите .app в окно — покажем всё, что оно оставило на диске."), tint: .uninstaller)
        }
    }
}

private struct InfoCard: View {
    let symbol: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            Text(text)
                .font(.caption12)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .glass(radius: 16, shadow: false)
        .accessibilityElement(children: .combine)
    }
}

private struct AppHeader: View {
    let app: InstalledApp
    let running: Bool
    let remnantsSize: Int64
    let remnantsLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                FileIcon(url: app.url, size: 68)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                VStack(alignment: .leading, spacing: 5) {
                    Text(app.name)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .accessibilityAddTraits(.isHeader)
                    if let v = app.version {
                        Text("Версия \(v)")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    ViewThatFits(in: .horizontal) {
                        badges(all: true)
                        badges(all: false)
                    }
                }
                // The bundle ID is for the curious: a tooltip instead of a truncated line.
                .help(app.bundleID.map { "\($0)\n\(Fmt.path(app.url))" } ?? Fmt.path(app.url))
                Spacer(minLength: 12)
                if !app.isSystemApp { sizeBlock }
            }
            if running && !app.isSystemApp {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).accessibilityHidden(true)
                    Text("Приложение сейчас запущено — при удалении оно будет закрыто. Сохраните открытые документы.")
                        .font(.caption12).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.warning.opacity(0.12)))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func badges(all: Bool) -> some View {
        let idle = Fmt.idleHint(app.lastUsed)
        return HStack(spacing: 6) {
            if app.isSystemApp {
                Badge(text: String(localized: "Системное"), color: .white.opacity(0.7), symbol: "lock.fill")
            } else {
                Badge(text: idle?.capitalizedFirst ?? String(localized: "Открывалось \(Fmt.ago(app.lastUsed))"),
                      color: idle == nil ? .white.opacity(0.75) : Theme.warning, symbol: "clock.fill")
            }
            if app.isAppStore && all { Badge(text: "App Store", color: ModuleTint.uninstaller.accent, symbol: "bag.fill") }
            if running { Badge(text: String(localized: "Запущено"), color: Theme.success, symbol: "play.fill") }
        }
    }

    private var sizeBlock: some View {
        VStack(alignment: .trailing, spacing: 2) {
            BigSize(bytes: app.size + remnantsSize, size: 36, weight: .light)
            Text("приложение \(Fmt.size(app.size))")
            Text("остатки \(remnantsLoading ? "…" : Fmt.size(remnantsSize))")
        }
        .font(.caption12)
        .foregroundStyle(Theme.textTertiary)
        .monospacedDigit()
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Remnant groups (shared by app detail and leftovers)

struct RemnantSection<Content: View>: View {
    let title: String
    let symbol: String
    let total: Int64
    var count: Int? = nil
    var state: CheckState? = nil
    var onToggle: () -> Void = {}
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let state {
                    CheckBox(state: state, tint: .uninstaller, label: title, action: onToggle)
                }
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ModuleTint.uninstaller.accent)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.08)))
                        .accessibilityLabel(Fmt.items(count))
                }
                Spacer()
                SizeText(bytes: total, font: .system(size: 12.5, weight: .semibold, design: .rounded), color: Theme.textSecondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            Hairline()
            content.padding(.vertical, 2)
        }
        .glass(radius: 16, shadow: false)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct RemnantGroups: View {
    @Environment(AppModel.self) private var appModel
    let remnants: [AppRemnant]
    let selection: Set<URL>
    let toggle: (AppRemnant) -> Void
    let toggleGroup: ([AppRemnant]) -> Void

    /// Container sizes are not measured without Full Disk Access (avoids a system privacy prompt).
    private func unmeasured(_ r: AppRemnant) -> Bool {
        r.item.size == 0 && !appModel.hasFullDiskAccess && (r.kind == .containers || r.kind == .groupContainers)
    }

    var body: some View {
        ForEach(RemnantKind.allCases, id: \.self) { kind in
            let items = remnants.filter { $0.kind == kind }
            if !items.isEmpty {
                RemnantSection(title: kind.title, symbol: kind.symbol, total: items.reduce(0) { $0 + $1.item.size },
                               count: items.count,
                               state: CheckState(selected: items.filter { selection.contains($0.id) }.count, total: items.count),
                               onToggle: { toggleGroup(items) }) {
                    ForEach(items) { r in
                        FileRow(url: r.item.url, size: r.item.size, sizeLabel: unmeasured(r) ? "—" : nil,
                                isChecked: selection.contains(r.id), tint: .uninstaller,
                                onToggle: { toggle(r) }) {
                            if unmeasured(r) {
                                Badge(text: String(localized: "размер — нужен полный доступ"), color: .white.opacity(0.6), symbol: "lock.shield")
                                    .help("Без полного доступа к диску macOS не даёт измерить контейнеры других приложений.")
                            }
                            if r.confidence == .low {
                                Badge(text: String(localized: "возможно связано"), color: Theme.warning)
                                    .help("Совпадение только по имени. Проверьте, что файл действительно относится к этому приложению.")
                            }
                            if r.requiresAdmin {
                                Badge(text: String(localized: "пароль"), color: .white.opacity(0.7), symbol: "lock.fill")
                                    .help("Файл вне вашей папки — macOS попросит пароль администратора.")
                            }
                        }
                    }
                }
            }
        }
    }
}
