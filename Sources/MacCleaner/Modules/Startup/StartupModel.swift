import SwiftUI
import AppKit
import CleanerKit
import StartupEngine

/// «Автозапуск»: what starts with the Mac, and the explicit, reversible ways to stop it.
/// Nothing is selected or changed on its own; Apple's items are hidden by default and never acted on.
@MainActor @Observable
final class StartupModel {
    weak var app: AppModel?

    var phase: ModulePhase = .idle
    var items: [StartupItem] = []
    /// Item IDs ticked by the user.
    var selection: Set<String> = []
    var showApple = false
    var quickLookURL: URL?

    enum LoginItemsState: Equatable { case notRead, reading, read, failed }
    /// Background Task Management (System Settings → Login Items) is read only on request: it needs the password.
    var loginItemsState: LoginItemsState = .notRead
    /// An action (launchctl or the Trash) is running.
    private(set) var isBusy = false
    @ObservationIgnored private var snapshot: BackgroundTaskSnapshot?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored var environment: StartupEnvironment = .live

    static let loginItemsSettings = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    // MARK: Derived

    var visibleItems: [StartupItem] { showApple ? items : items.filter { !$0.isApple } }
    var hiddenAppleCount: Int { showApple ? 0 : items.count(where: \.isApple) }
    /// Sidebar badge: third-party items that will start on their own.
    var enabledThirdPartyCount: Int { items.count { !$0.isApple && $0.isEnabled } }

    var groups: [(group: StartupItem.Group, items: [StartupItem])] {
        let visible = visibleItems
        return StartupItem.Group.allCases.map { g in (g, visible.filter { $0.group == g }) }
    }

    var selectedItems: [StartupItem] { visibleItems.filter { selection.contains($0.id) } }
    var disablable: [StartupItem] { selectedItems.filter { StartupActions.refusal(.disable, for: $0) == nil } }
    var enablable: [StartupItem] { selectedItems.filter { StartupActions.refusal(.enable, for: $0) == nil } }
    var removable: [StartupItem] { selectedItems.filter { StartupActions.refusal(.remove, for: $0) == nil } }

    func isSelectable(_ item: StartupItem) -> Bool {
        [.disable, .enable, .remove].contains { StartupActions.refusal($0, for: item) == nil }
    }

    func toggle(_ item: StartupItem) {
        guard isSelectable(item) else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    // MARK: Scan

    func startScan() {
        scanTask?.cancel()
        // «Обновить» over results keeps the list on screen (the footer is disabled meanwhile); the first scan
        // shows the stage.
        if phase != .results { withAnimation(Theme.spring) { phase = .scanning } }
        isBusy = true
        scanTask = Task { await scan() }
    }

    func scan() async {
        let env = environment
        let snapshot = snapshot
        let found = await Task.detached(priority: .userInitiated) { () -> [StartupItem] in
            let scanner = StartupScanner(environment: env)
            let items = scanner.launchdItems()
            return snapshot.map { scanner.merging(items, with: $0) } ?? items
        }.value
        guard !Task.isCancelled else { isBusy = false; return }
        apply(found)
    }

    func apply(_ found: [StartupItem]) {
        items = found
        let ids = Set(found.map(\.id))
        selection = selection.filter { ids.contains($0) }
        isBusy = false
        withAnimation(Theme.spring) { phase = .results }
    }

    /// Reads System Settings → Login Items through `sfltool dumpbtm`; macOS asks for the administrator password.
    func readLoginItems() {
        guard loginItemsState != .reading else { return }
        loginItemsState = .reading
        let env = environment
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (BackgroundTaskSnapshot, [StartupItem]) in
                let scanner = StartupScanner(environment: env)
                let snapshot = scanner.backgroundTasks()
                return (snapshot, scanner.merging(scanner.launchdItems(), with: snapshot))
            }.value
            if result.0.isReadable {
                snapshot = result.0
                loginItemsState = .read
                apply(result.1)
            } else {
                loginItemsState = .failed
            }
        }
    }

    func openLoginItemsSettings() {
        NSWorkspace.shared.open(Self.loginItemsSettings)
    }

    // MARK: Actions (each behind the app's confirmation)

    func requestDisable(_ targets: [StartupItem]) {
        guard !targets.isEmpty else { return }
        let n = targets.count
        let daemons = targets.contains { $0.source == .daemon }
        confirm(title: n == 1 ? String(localized: "Выключить «\(targets[0].displayName)»?") : String(localized: "Выключить \(Fmt.items(n))?"),
                message: String(localized: "Работающее сейчас остановится и больше не будет запускаться само — ни при входе, ни по расписанию. Файлы остаются на месте: включить обратно можно здесь же, кнопкой «Включить»."),
                button: String(localized: "Выключить"), symbol: "power", count: n, needsAdmin: daemons,
                warning: Self.selfHealingWarning(targets)) { [weak self] in
            self?.perform(.disable, on: targets)
        }
    }

    func requestEnable(_ targets: [StartupItem]) {
        guard !targets.isEmpty else { return }
        let n = targets.count
        confirm(title: n == 1 ? String(localized: "Включить «\(targets[0].displayName)»?") : String(localized: "Включить \(Fmt.items(n))?"),
                message: String(localized: "macOS снова будет запускать это само. Если в настройках задан запуск при загрузке, оно запустится сразу."),
                button: String(localized: "Включить"), symbol: "power", count: n,
                needsAdmin: targets.contains { $0.source == .daemon }) { [weak self] in
            self?.perform(.enable, on: targets)
        }
    }

    func requestRemove(_ targets: [StartupItem]) {
        guard !targets.isEmpty else { return }
        let n = targets.count
        let rootOwned = targets.contains { $0.source != .userAgent }
        let undo = rootOwned
            ? String(localized: "Файл настройки (.plist) попадёт в Корзину, служба остановится. Сама программа не удаляется. Чтобы вернуть, перетащите файл из Корзины обратно в его папку (macOS спросит пароль).")
            : String(localized: "Файл настройки (.plist) попадёт в Корзину, служба остановится. Сама программа не удаляется. Вернуть можно из Корзины («Вернуть») — служба снова запустится при следующем входе в систему.")
        confirm(title: n == 1 ? String(localized: "Удалить «\(targets[0].displayName)» из автозапуска?") : String(localized: "Удалить из автозапуска \(Fmt.items(n))?"),
                message: undo, button: String(localized: "Удалить"), symbol: "trash.fill", count: n, needsAdmin: rootOwned,
                warning: Self.selfHealingWarning(targets)) { [weak self] in
            self?.perform(.remove, on: targets)
        }
    }

    /// Updaters and security tools often put their agent back: say so instead of promising it stays off.
    private static func selfHealingWarning(_ targets: [StartupItem]) -> String? {
        guard targets.contains(where: { $0.ownerAppURL != nil }) else { return nil }
        return String(localized: "Приложение может вернуть свою службу при следующем запуске или обновлении. Надёжнее — удалить само приложение в «Деинсталляторе».")
    }

    private func confirm(title: String, message: String, button: String, symbol: String, count: Int,
                         needsAdmin: Bool = false, warning: String? = nil, action: @escaping @MainActor () -> Void) {
        let noun: (Int) -> String = { Fmt.items($0) }
        app?.confirmation = Confirmation(title: title, message: message, count: count, bytes: 0, confirmTitle: button,
                                         needsAdmin: needsAdmin, warning: warning, tint: .startup,
                                         symbol: symbol, showsSize: false, noun: noun, action: action)
    }

    private func perform(_ action: StartupAction, on targets: [StartupItem]) {
        guard !isBusy else { return }
        isBusy = true
        let env = environment
        Task {
            let report = await StartupActions.perform(action, on: targets, environment: env)
            selection.subtract(report.succeeded)
            if !report.removal.removed.isEmpty { app?.didRemove(report.removal) }
            // Busy until the list is re-read: a second click meanwhile would act on stale items.
            await scan()
            isBusy = false
            announce(action, report: report, targets: targets)
        }
    }

    private func announce(_ action: StartupAction, report: StartupActionReport, targets: [StartupItem]) {
        let done = targets.filter { report.succeeded.contains($0.id) }
        if let failure = report.failed.first {
            let name = targets.first { $0.id == failure.id }?.displayName ?? String(localized: "объект")
            let text = done.isEmpty ? String(localized: "Не получилось: \(name) — \(failure.reason)")
                                    : String(localized: "Готово: \(Fmt.items(done.count)). Не получилось: \(name) — \(failure.reason)")
            app?.showToast(Toast(text: text, symbol: "exclamationmark.triangle.fill", kind: .warning))
            return
        }
        guard !done.isEmpty else { return }
        let what = done.count == 1 ? String(localized: "«\(done[0].displayName)»") : Fmt.items(done.count)
        switch action {
        case .disable:
            // The undo is one click away: the same items, enabled back (they are still on disk).
            app?.showToast(Toast(text: String(localized: "Выключено: \(what)"), symbol: "power", kind: .success,
                                 actionTitle: String(localized: "Включить"), action: { [weak self] in self?.undoDisable(done) }))
        case .enable:
            app?.showToast(Toast(text: String(localized: "Включено: \(what)"), symbol: "power", kind: .success))
        case .remove:
            app?.showToast(Toast(text: String(localized: "В Корзине: \(what)"), symbol: "trash.fill", kind: .success,
                                 actionTitle: String(localized: "Открыть Корзину"), action: { Finder.openTrash() }))
        }
    }

    /// Re-enables what was just disabled (fresh items: their state changed).
    private func undoDisable(_ done: [StartupItem]) {
        let ids = Set(done.map(\.id))
        perform(.enable, on: items.filter { ids.contains($0.id) })
    }
}
