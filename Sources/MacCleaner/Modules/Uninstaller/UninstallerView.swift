import SwiftUI
import CleanerKit

struct UninstallerView: View {
    let model: UninstallerModel
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch model.phase {
            case .idle, .scanning:
                ModuleStage(module: .uninstaller,
                            state: model.phase == .scanning ? .progress(app.appsProgress) : .idle(button: "Сканировать", enabled: true),
                            onAction: model.startScan) {
                    DropHint()
                }
            case .results:
                UninstallerBrowser(model: model)
            case .cleaning:
                ModuleStage(module: .uninstaller, title: model.workingTitle,
                            subtitle: "Файлы перемещаются в Корзину. Если macOS спросит пароль — это для системных служб приложения.",
                            state: .busy(""))
            case .done:
                CompletionView(tint: .uninstaller, result: model.result ?? RemovalResult(), title: model.resultTitle,
                               onDone: model.finish)
            }
        }
        .onAppear { model.onAppear() }
    }
}

private struct DropHint: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ModuleTint.uninstaller.accent)
            Text("Или перетащите приложение в это окно")
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
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Segmented(options: [(UninstallerModel.Tab.apps, "Приложения"), (.leftovers, "Остатки")],
                          selection: $model.tab, tint: .uninstaller)
                    .padding(.top, 22)
                    .padding(.bottom, 14)
                if model.tab == .apps {
                    AppListPanel(model: model)
                } else {
                    OrphanListPanel(model: model)
                }
            }
            .frame(width: 316)
            .background(Color.black.opacity(0.14))
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }

            Group {
                if model.tab == .apps {
                    AppDetailView(model: model)
                } else {
                    OrphanDetailView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - App list

private struct AppListPanel: View {
    @Bindable var model: UninstallerModel
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $model.search, prompt: "Поиск приложений")
                .padding(.horizontal, 16)

            HStack(spacing: 6) {
                Chip(title: "Все", selected: model.filter == .all, tint: .uninstaller) { model.filter = .all }
                Chip(title: "Давно не открывались", selected: model.filter == .unused, tint: .uninstaller) { model.filter = .unused }
                Chip(title: "App Store", selected: model.filter == .appStore, tint: .uninstaller) { model.filter = .appStore }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            HStack {
                Text(Fmt.apps(model.visibleApps.count))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                SortMenu(sort: $model.sort, showSystem: $model.showSystemApps)
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 4)

            if app.appsState == .loading && model.visibleApps.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Ищем приложения…").font(.caption12).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.visibleApps) { a in
                            AppRow(app: a, selected: model.selectedAppID == a.url, checked: model.checkedApps.contains(a.url),
                                   onSelect: { model.select(a) }, onCheck: { model.toggleChecked(a) })
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }

            if !model.checkedAppList.isEmpty {
                BatchBar(model: model)
                    .padding(12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: model.checkedApps)
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(prompt).font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .focused($focused)
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(focused ? ModuleTint.uninstaller.accent.opacity(0.7) : .white.opacity(0.1), lineWidth: 1))
    }
}

private struct SortMenu: View {
    @Binding var sort: UninstallerModel.Sort
    @Binding var showSystem: Bool

    private var title: String {
        switch sort {
        case .size: "По размеру"
        case .name: "По имени"
        case .lastUsed: "Давно не использовались"
        }
    }

    var body: some View {
        Menu {
            Picker("Сортировка", selection: $sort) {
                Text("По размеру").tag(UninstallerModel.Sort.size)
                Text("По имени").tag(UninstallerModel.Sort.name)
                Text("Давно не использовались").tag(UninstallerModel.Sort.lastUsed)
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
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let selected: Bool
    let checked: Bool
    let onSelect: () -> Void
    let onCheck: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            CheckBox(state: checked ? .on : .off, tint: .uninstaller, disabled: app.isSystemApp, action: onCheck)
            Image(nsImage: IconCache.icon(for: app.url))
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                subtitle
            }
            Spacer(minLength: 6)
            if app.isSystemApp {
                Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            } else {
                SizeText(bytes: app.size, font: .system(size: 12, weight: .medium, design: .rounded), color: Theme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? AnyShapeStyle(ModuleTint.uninstaller.horizontal.opacity(0.32)) : AnyShapeStyle(Color.white.opacity(hover ? 0.06 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.white.opacity(selected ? 0.16 : 0), lineWidth: 0.75))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hover = $0 }
        .opacity(app.isSystemApp ? 0.55 : 1)
        .contextMenu {
            Button("Показать в Finder") { Finder.reveal(app.url) }
        }
    }

    @ViewBuilder private var subtitle: some View {
        if app.isSystemApp {
            Text("Системное — не удаляется").font(.caption11).foregroundStyle(Theme.textTertiary).lineLimit(1)
        } else if let hint = Fmt.idleHint(app.lastUsed) {
            Text(hint).font(.caption11).foregroundStyle(Theme.warning.opacity(0.85)).lineLimit(1)
        } else {
            Text("Открывалось \(Fmt.ago(app.lastUsed))").font(.caption11).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
    }
}

private struct BatchBar: View {
    let model: UninstallerModel

    var body: some View {
        let list = model.checkedAppList
        HStack(spacing: 10) {
            HStack(spacing: -10) {
                ForEach(list.prefix(3)) { a in
                    Image(nsImage: IconCache.icon(for: a.url)).resizable().frame(width: 26, height: 26)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(Fmt.apps(list.count).capitalizedFirst).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text("\(Fmt.size(list.reduce(0) { $0 + $1.size })) без остатков").font(.caption11).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 4)
            Button("Удалить") { model.requestBatchUninstall() }
                .buttonStyle(PillButtonStyle(kind: .primary(.uninstaller)))
        }
        .padding(10)
        .glass(radius: 14)
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
            VStack(spacing: 0) {
                AppHeader(app: a, model: model)
                    .padding(.horizontal, 30)
                    .padding(.top, 28)

                ScrollView {
                    VStack(spacing: 12) {
                        // The bundle itself — always part of "Удалить полностью".
                        RemnantSection(title: "Приложение", symbol: "macwindow", total: a.size) {
                            FileRow(url: a.url, size: a.size, tint: .uninstaller) {
                                if a.isAppStore { Badge(text: "App Store", color: ModuleTint.uninstaller.accent) }
                            }
                        }
                        if model.remnantsLoading {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Ищем настройки, кэши и службы приложения…")
                                    .font(.caption12).foregroundStyle(Theme.textSecondary)
                                Spacer()
                            }
                            .padding(16)
                            .glass(radius: 16, shadow: false)
                        } else if model.remnants.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.success)
                                Text("Других файлов не найдено — приложение хранит всё внутри себя.")
                                    .font(.caption12).foregroundStyle(Theme.textSecondary)
                                Spacer()
                            }
                            .padding(16)
                            .glass(radius: 16, shadow: false)
                        } else {
                            RemnantGroups(remnants: model.remnants, selection: model.remnantSelection,
                                          toggle: model.toggle, toggleGroup: model.toggleGroup)
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                }

                ActionFooter(title: "Удалить", tint: .uninstaller, enabled: !a.isSystemApp, action: model.requestUninstall) {
                    SelectionSummary(bytes: a.size + model.selectedRemnantsSize,
                                     count: 1 + model.selectedRemnants.count, label: "Будет удалено")
                } trailing: {
                    Button { model.requestReset() } label: {
                        Label("Сбросить", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .disabled(model.selectedRemnants.isEmpty)
                    .help("Удалить только настройки и данные, оставив само приложение")
                }
            }
        } else {
            EmptyState(symbol: "arrow.down.app.fill", title: "Выберите приложение",
                       message: "Или перетащите .app в окно — покажем всё, что оно оставило на диске.", tint: .uninstaller)
        }
    }
}

private struct AppHeader: View {
    let app: InstalledApp
    let model: UninstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                Image(nsImage: IconCache.icon(for: app.url))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 68, height: 68)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                VStack(alignment: .leading, spacing: 5) {
                    Text(app.name)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let v = app.version {
                            Text("Версия \(v)").foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        if let id = app.bundleID {
                            Text(id).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                                .lineLimit(1).truncationMode(.middle)
                                .layoutPriority(-1)
                        }
                    }
                    .font(.system(size: 12.5))
                    ViewThatFits(in: .horizontal) {
                        badges(all: true)
                        badges(all: false)
                    }
                }
                Spacer(minLength: 12)
                sizeBlock
            }
            if model.isRunning(app) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    Text("Приложение сейчас запущено — при удалении оно будет закрыто. Сохраните открытые документы.")
                        .font(.caption12).foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.warning.opacity(0.12)))
            }
        }
    }

    private func badges(all: Bool) -> some View {
        HStack(spacing: 6) {
            Badge(text: Fmt.idleHint(app.lastUsed)?.capitalizedFirst ?? "Открывалось \(Fmt.ago(app.lastUsed))",
                  color: Fmt.idleHint(app.lastUsed) == nil ? .white.opacity(0.75) : Theme.warning, symbol: "clock.fill")
            if app.isAppStore && all { Badge(text: "App Store", color: ModuleTint.uninstaller.accent, symbol: "bag.fill") }
            if model.isRunning(app) { Badge(text: "Запущено", color: Theme.success, symbol: "play.fill") }
            if app.isSystemApp { Badge(text: "Системное", color: .white.opacity(0.7), symbol: "lock.fill") }
        }
    }

    private var sizeBlock: some View {
        VStack(alignment: .trailing, spacing: 2) {
            BigSize(bytes: app.size + model.remnantsSize, size: 36, weight: .light)
            Text("приложение \(Fmt.size(app.size))")
            Text("остатки \(model.remnantsLoading ? "…" : Fmt.size(model.remnantsSize))")
        }
        .font(.caption12)
        .foregroundStyle(Theme.textTertiary)
        .monospacedDigit()
        .fixedSize()
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
                    CheckBox(state: state, tint: .uninstaller, action: onToggle)
                }
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ModuleTint.uninstaller.accent)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.08)))
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
                                Badge(text: "размер — нужен полный доступ", color: .white.opacity(0.6), symbol: "lock.shield")
                                    .help("Без полного доступа к диску macOS не даёт измерить контейнеры других приложений.")
                            }
                            if r.confidence == .low {
                                Badge(text: "возможно связано", color: Theme.warning)
                                    .help("Совпадение только по имени. Проверьте, что файл действительно относится к этому приложению.")
                            }
                            if r.requiresAdmin {
                                Badge(text: "пароль", color: .white.opacity(0.7), symbol: "lock.fill")
                                    .help("Файл вне вашей папки — macOS попросит пароль администратора.")
                            }
                        }
                    }
                }
            }
        }
    }
}
