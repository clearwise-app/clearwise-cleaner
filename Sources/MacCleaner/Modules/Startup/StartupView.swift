import SwiftUI
import StartupEngine

struct StartupView: View {
    @Bindable var model: StartupModel

    var body: some View {
        switch model.phase {
        case .idle, .scanning:
            ModuleStage(module: .startup,
                        state: model.phase == .scanning ? .busy(String(localized: "Читаем агенты и службы…")) : .idle(button: String(localized: "Проверить"), enabled: true),
                        onAction: model.startScan)
        case .results, .cleaning, .done:
            StartupResultsView(model: model)
                .quickLookPreview($model.quickLookURL, in: model.visibleItems.compactMap(\.plist))
        }
    }
}

private struct StartupResultsView: View {
    let model: StartupModel

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.groups, id: \.group) { entry in
                        if !entry.items.isEmpty || entry.group == .loginItems {
                            StartupGroupCard(model: model, group: entry.group, items: entry.items)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.top, 22)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)
            footer
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: AppModule.startup.symbol).font(.system(size: 11, weight: .bold))
                    Text(AppModule.startup.title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.8)
                }
                .foregroundStyle(ModuleTint.startup.accent)
                Text(Fmt.integer(model.enabledThirdPartyCount))
                    .font(.number(58, weight: .light))
                    .foregroundStyle(Theme.text)
                    .padding(.top, 2)
                Text(caption)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            HStack(spacing: 10) {
                Toggle(isOn: Binding(get: { model.showApple }, set: { model.showApple = $0 })) {
                    Text("Объекты macOS")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Службы Apple только показываются: изменить или удалить их здесь нельзя.")
                Button { model.startScan() } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .disabled(model.isBusy)
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.top, 30)
    }

    private var caption: String {
        let n = model.enabledThirdPartyCount
        let verb = Fmt.verb(n, one: String(localized: "запускается само"), other: String(localized: "запускаются сами"))
        var text = String(localized: "\(verb) · \(Fmt.items(model.items.count { !$0.isApple })) от сторонних разработчиков")
        if model.hiddenAppleCount > 0 { text += " · " + String(localized: "объекты macOS скрыты") }
        return text
    }

    @ViewBuilder private var footer: some View {
        let off = model.disablable
        let on = model.enablable
        let remove = model.removable
        let primaryIsEnable = off.isEmpty && !on.isEmpty
        ActionFooter(title: primaryIsEnable ? String(localized: "Включить") : String(localized: "Выключить"), tint: .startup,
                     enabled: !model.isBusy && !(primaryIsEnable ? on : off).isEmpty,
                     action: { primaryIsEnable ? model.requestEnable(on) : model.requestDisable(off) }) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Выбрано")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                Text(model.selectedItems.isEmpty ? String(localized: "ничего") : Fmt.items(model.selectedItems.count))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(model.selectedItems.isEmpty ? Theme.textSecondary : Theme.text)
            }
            .accessibilityElement(children: .combine)
        } trailing: {
            HStack(spacing: 8) {
                if !primaryIsEnable && !on.isEmpty {
                    Button("Включить") { model.requestEnable(on) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                Button("Удалить…") { model.requestRemove(remove) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .disabled(remove.isEmpty || model.isBusy)
                    .help("Файл настройки — в Корзину, сама программа остаётся")
            }
        }
    }
}

// MARK: - Group card

private struct StartupGroupCard: View {
    let model: StartupModel
    let group: StartupItem.Group
    let items: [StartupItem]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                IconTile(symbol: group.symbol, tint: .startup, size: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title)
                        .font(.cardTitle)
                        .foregroundStyle(Theme.text)
                        .accessibilityAddTraits(.isHeader)
                    Text(group.detail)
                        .font(.caption12)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                // «0 объектов» would be a claim: without the password, login items are simply unknown.
                if !items.isEmpty || group != .loginItems || model.loginItemsState == .read {
                    Text(items.isEmpty ? String(localized: "нет") : Fmt.items(items.count))
                        .font(.caption11)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            if !items.isEmpty {
                Hairline()
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        StartupRow(model: model, item: item)
                        if item.id != items.last?.id { Hairline(inset: 66) }
                    }
                }
                .padding(.vertical, 4)
            }
            if group == .loginItems {
                Hairline()
                LoginItemsNote(model: model, isEmpty: items.isEmpty)
            }
        }
        .glass(radius: 16, shadow: false)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// What this screen can and cannot see about login items, and the way to the rest.
private struct LoginItemsNote: View {
    let model: StartupModel
    let isEmpty: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if model.loginItemsState == .reading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.loginItemsState == .failed ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(model.loginItemsState == .failed ? Theme.warning : Theme.textTertiary)
                }
            }
            .frame(width: 18)
            .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if model.loginItemsState != .reading {
                // After a read the list is a snapshot: what the user changes in System Settings shows up only on a re-read.
                Button(model.loginItemsState == .failed ? "Попробовать снова"
                       : model.loginItemsState == .read ? "Прочитать снова" : "Прочитать список") { model.readLoginItems() }
                    .buttonStyle(PillButtonStyle(kind: model.loginItemsState == .read ? .quiet : .secondary))
                    .help("macOS спросит пароль администратора: без него список объектов входа не читается")
            }
            Button("Открыть настройки") { model.openLoginItemsSettings() }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                .help("Системные настройки → Основные → Объекты входа и расширения")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var text: String {
        switch model.loginItemsState {
        case .notRead:
            (isEmpty ? String(localized: "Здесь пока только то, что видно без пароля.") + " " : "")
                + String(localized: "Приложения из «Открывать при входе» знает только macOS — чтобы прочитать их список, она попросит пароль администратора.")
        case .reading:
            String(localized: "Ждём пароль администратора и читаем список объектов входа…")
        case .read:
            isEmpty
                ? String(localized: "Объектов входа нет: при входе в систему ничего не открывается само. Добавить приложение можно в Системных настройках.")
                : String(localized: "Объекты входа приложений включаются и выключаются только в Системных настройках — сторонним программам macOS этого не разрешает.")
        case .failed:
            String(localized: "Не удалось прочитать список объектов входа (пароль не введён или macOS не ответила). Его можно посмотреть в Системных настройках.")
        }
    }
}

// MARK: - Row

private struct StartupRow: View {
    let model: StartupModel
    let item: StartupItem
    @State private var hover = false
    @FocusState private var focused: Bool

    private var selectable: Bool { model.isSelectable(item) }
    private var checked: Bool { model.selection.contains(item.id) }
    private var location: URL? { item.plist ?? item.ownerAppURL }

    var body: some View {
        HStack(spacing: 12) {
            if selectable {
                CheckBox(state: checked ? .on : .off, tint: .startup, label: item.displayName) { model.toggle(item) }
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 18, height: 18)
                    .help(StartupActions.refusal(.remove, for: item) ?? "")
                    .accessibilityHidden(true)
            }
            icon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(item.displayName)
                        .font(.rowTitle)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    StartupStateBadge(item: item)
                }
                Text(details)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let location {
                    Text(Fmt.path(location))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.themeTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(location.path)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if item.source == .backgroundTask {
                    IconButton(symbol: "gearshape.fill", help: String(localized: "Открыть «Объекты входа» в Системных настройках"), size: 24) {
                        model.openLoginItemsSettings()
                    }
                }
                if let plist = item.plist {
                    IconButton(symbol: "eye.fill", help: String(localized: "Быстрый просмотр (⌘Y)"), size: 24) { model.quickLookURL = plist }
                        .keyboardShortcut(focused ? KeyboardShortcut("y", modifiers: .command) : nil)
                }
                if let location {
                    IconButton(symbol: "magnifyingglass", help: String(localized: "Показать в Finder"), size: 24) { Finder.reveal(location) }
                }
            }
            .opacity(hover || focused ? 1 : 0)
            .allowsHitTesting(hover || focused)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 64)
        .background(Rectangle().fill(.white.opacity(hover || focused ? 0.045 : 0)))
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(ModuleTint.startup.accent.opacity(0.85), lineWidth: 1.5)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(item) }
        .onHover { hover = $0 }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) {
            guard selectable else { return .ignored }
            model.toggle(item)
            return .handled
        }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityValue(selectable ? (checked ? "отмечено" : "не отмечено") : "только просмотр")
        .accessibilityAddTraits(selectable ? .isToggle : [])
        .accessibilityAction { model.toggle(item) }
        .accessibilityAction(named: "Показать в Finder") { if let location { Finder.reveal(location) } }
    }

    @ViewBuilder private var icon: some View {
        // An app that is gone (or not installed, in demo data) would show a blank document icon.
        if let app = item.ownerAppURL, FileManager.default.fileExists(atPath: app.path) {
            FileIcon(url: app, size: 34)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.07))
                Image(systemName: item.group == .daemons ? "gearshape.2.fill" : "terminal.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)
        }
    }

    /// «com.google.GoogleUpdater.wake · Developer ID: Google LLC · раз в час».
    private var details: String {
        var parts: [String] = []
        if item.label != item.displayName { parts.append(item.label) }
        if item.isMalformed { parts.append(String(localized: "нет метки (Label) — macOS этот файл не загружает")) }
        // A third-party job that runs a macOS tool (`/bin/sh`, `launchctl`…): the tool is Apple's, the job is not.
        if item.signer == .apple, !item.isApple, let program = item.program {
            parts.append(String(localized: "запускает программу macOS «\((program as NSString).lastPathComponent)»"))
        } else if let signer = item.signer.title {
            parts.append(signer)
        }
        if let schedule = item.schedule { parts.append(schedule) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var menu: some View {
        if StartupActions.refusal(.disable, for: item) == nil {
            Button("Выключить…") { model.requestDisable([item]) }
        }
        if StartupActions.refusal(.enable, for: item) == nil {
            Button("Включить…") { model.requestEnable([item]) }
        }
        if StartupActions.refusal(.remove, for: item) == nil {
            Button("Удалить из автозапуска…") { model.requestRemove([item]) }
        }
        if item.source == .backgroundTask {
            Button("Открыть «Объекты входа»") { model.openLoginItemsSettings() }
        }
        Divider()
        if let location { Button("Показать в Finder") { Finder.reveal(location) } }
        if let plist = item.plist { Button("Быстрый просмотр") { model.quickLookURL = plist } }
        Button("Скопировать метку") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.label, forType: .string)
        }
    }
}

private struct StartupStateBadge: View {
    let item: StartupItem

    static let neutral = Color(hex: 0xB9B4C7)

    var body: some View {
        if item.isApple {
            Badge(text: "macOS", color: Self.neutral, symbol: "apple.logo")
        } else if item.isMalformed {
            Badge(text: String(localized: "Файл повреждён"), color: RiskBadge.cautionFill, symbol: "exclamationmark.triangle.fill")
                .help("В файле нет метки (Label): macOS его не загружает. Его можно удалить.")
        } else if item.programMissing {
            Badge(text: String(localized: "Программы нет"), color: RiskBadge.cautionFill, symbol: "exclamationmark.triangle.fill")
                .help("Программа удалена, а запись автозапуска осталась.")
        } else if item.disabledByOverride || item.disabledInPlist {
            Badge(text: String(localized: "Выключено"), color: Self.neutral, symbol: "power")
        } else if item.disabledInSettings {
            Badge(text: String(localized: "Выключено в Настройках"), color: Self.neutral, symbol: "power")
        } else {
            switch item.state {
            case .running:
                Badge(text: String(localized: "Работает"), color: RiskBadge.safeFill, symbol: "play.fill")
            case .loaded:
                Badge(text: String(localized: "Включено"), color: RiskBadge.safeFill, symbol: "checkmark")
                    .help("Загружено и ждёт своего часа: входа, расписания или обращения.")
            case .notLoaded:
                Badge(text: String(localized: "Не загружено"), color: RiskBadge.reviewFill, symbol: "pause.fill")
                    .help("Сейчас не загружено — запустится при следующем входе или перезагрузке.")
            case .unknown:
                Badge(text: String(localized: "Включено"), color: RiskBadge.safeFill, symbol: "checkmark")
            }
        }
    }
}

// MARK: - Copy

extension StartupItem.Group {
    var title: String {
        switch self {
        case .loginItems: String(localized: "Объекты входа")
        case .agents: String(localized: "Агенты")
        case .daemons: String(localized: "Системные службы")
        }
    }

    var detail: String {
        switch self {
        case .loginItems: String(localized: "Приложения и помощники, которые открываются при входе в систему.")
        case .agents: String(localized: "Фоновые программы вашей учётной записи: обновления, синхронизация, помощники.")
        case .daemons: String(localized: "Работают от имени системы для всех пользователей. Изменения — с паролем администратора.")
        }
    }

    var symbol: String {
        switch self {
        case .loginItems: "person.crop.circle.fill"
        case .agents: "gearshape.fill"
        case .daemons: "gearshape.2.fill"
        }
    }
}

extension StartupItem {
    /// «при входе», «раз в час», «держится запущенным».
    var schedule: String? {
        var parts: [String] = []
        if runAtLoad { parts.append(source == .daemon ? String(localized: "при загрузке") : String(localized: "при входе")) }
        if let interval {
            parts.append(interval % 3600 == 0 ? (interval == 3600 ? String(localized: "раз в час") : String(localized: "каждые \(interval / 3600) ч"))
                         : interval % 60 == 0 ? String(localized: "каждые \(interval / 60) мин") : String(localized: "каждые \(interval) с"))
        }
        if keepAlive { parts.append(String(localized: "перезапускается")) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

extension Signer {
    var title: String? {
        switch self {
        case .apple: String(localized: "Подпись Apple")
        case .appStore: "App Store"
        case .developerID(let name, _): name.map { "Developer ID: \($0)" } ?? "Developer ID"
        case .other(let name, _): name.map { String(localized: "Подпись: \($0)") } ?? String(localized: "Подпись разработчика")
        case .adHoc: String(localized: "Без подписи разработчика")
        case .unsigned: String(localized: "Без подписи")
        case .invalid: String(localized: "Подпись повреждена")
        case .unknown: nil
        }
    }
}
