import SwiftUI
import AppKit
import CleanerKit
import UninstallEngine
import SpaceEngine

/// Shared app state: navigation, permissions, disk usage, installed apps, pending confirmation.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    var selection: AppModule = .smartCare
    /// Last known Full Disk Access state. Changes go through `applyAccess(granted:)` (toast on grant).
    var hasFullDiskAccess: Bool
    var fdaBannerDismissed = false
    var disk: DiskUsage?
    /// Latest cleanup that moved or deleted something (Smart Care's «Последняя уборка»). Persisted.
    var lastCleanup: LastCleanup?
    var confirmation: Confirmation?
    var isDropTargeted = false
    /// Full-screen cleaning scene while a confirmed cleanup runs (see `runCleaning`).
    var cleaning: CleaningSession?
    /// Full Disk Access flow: first-run onboarding or the access sheet. Nil when closed.
    var accessFlow: AccessFlow?
    /// One transient message at the bottom of the content area.
    var toast: Toast?
    /// «Корзина очищена» after `requestEmptyTrash()` (covers the content area until «Готово»).
    var trashCompletion: TrashCompletion?
    /// «Хранилище» over the content area (a click on the sidebar disk widget). Closed by Esc, ✕ or any module.
    var storageExplorer: StorageExplorerModel?
    /// Bumped by «Найти» (⌘F). The Uninstaller's search field focuses itself when it changes
    /// (read it in `.onChange` and on appear: the module may have just been selected).
    var searchFocusRequest = 0
    /// A text field in the main window is being edited: ⌘⌫ belongs to it, not to «Очистить».
    private(set) var textInputFocused = false

    enum AppsState { case notLoaded, loading, loaded }
    var apps: [InstalledApp] = [] {
        didSet { nonSystemAppCount = apps.reduce(0) { $1.isSystemApp ? $0 : $0 + 1 } }
    }
    /// Cached for the sidebar badge (filtering the list on every render cost O(n) per scan tick).
    private(set) var nonSystemAppCount = 0
    var appsState: AppsState = .notLoaded
    var appsProgress = ScanProgress(phase: "", fraction: 0)
    @ObservationIgnored private var appsTask: Task<[InstalledApp], Never>?

    let smartCare = SmartCareModel()
    let junk = JunkModel()
    let uninstaller = UninstallerModel()
    let oldFiles = OldFilesModel()
    let duplicates = DuplicatesModel()
    let diskMap = DiskMapModel()
    let startup = StartupModel()
    /// Disk usage by category (sidebar widget). Measured at launch and after every cleanup.
    let storage: StorageModel

    /// False for snapshots and tests: no system probes, no UserDefaults, no real Trash.
    @ObservationIgnored let probesSystem: Bool
    @ObservationIgnored private var systemTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var focusObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var responderObservation: NSKeyValueObservation?

    init(probeSystem: Bool = true) {
        probesSystem = probeSystem
        hasFullDiskAccess = probeSystem ? Permissions.hasFullDiskAccess : true
        disk = probeSystem ? DiskUsage.startupVolume() : nil
        storage = StorageModel(live: probeSystem)
        lastCleanup = probeSystem ? LastCleanup.load() : nil
        if probeSystem { storage.refreshIfAllowed(fullDiskAccess: hasFullDiskAccess) }
        smartCare.app = self
        junk.app = self
        uninstaller.app = self
        oldFiles.app = self
        duplicates.app = self
        diskMap.app = self
        startup.app = self
        if probeSystem { observeTextFocus() }
    }

    var showsFDABanner: Bool { !hasFullDiskAccess && !fdaBannerDismissed }

    /// Something modal covers the main screens: confirmation, cleaning scene or the access flow.
    var isModalActive: Bool { confirmation != nil || cleaning != nil || accessFlow != nil }

    // MARK: System state

    /// Re-reads Full Disk Access and free space (app activation, after removals). The probes touch the
    /// disk, so they run off the main thread; results are applied on main.
    func refreshSystemState() {
        guard probesSystem else { return }
        systemTask?.cancel()
        systemTask = Task { [weak self] in
            let probe = await Task.detached(priority: .utility) {
                (access: Permissions.hasFullDiskAccess, disk: DiskUsage.startupVolume())
            }.value
            guard let self, !Task.isCancelled else { return }
            self.disk = probe.disk
            self.applyAccess(granted: probe.access)
            self.storage.refreshIfStale(disk: self.disk, fullDiskAccess: self.hasFullDiskAccess)
            self.systemTask = nil
        }
    }

    /// One place for Full Disk Access transitions.
    /// - granted inside the access flow → step 3 («Доступ открыт»);
    /// - granted outside it → toast «Полный доступ включён — пересканируйте…»;
    /// - revoked → only the sidebar pill turns yellow (no dialogs).
    func applyAccess(granted: Bool) {
        let changed = granted != hasFullDiskAccess
        if changed { hasFullDiskAccess = granted }
        // «Хранилище» fixed its fences (containers or not) when it opened.
        if changed, storageExplorer != nil { closeStorage() }
        guard granted else { return }
        if let flow = accessFlow, flow.awaitsGrant {
            markOnboardingDone()
            flow.didGrant()
        } else if changed {
            markOnboardingDone()
            if accessFlow == nil {
                showToast(Toast(text: "Полный доступ включён — пересканируйте, чтобы увидеть всё",
                                symbol: "checkmark.shield.fill", kind: .success,
                                actionTitle: canRescan ? "Сканировать заново" : nil,
                                action: { [weak self] in self?.rescanCurrent() }))
            }
        }
        if changed { storage.refreshIfStale(disk: disk, fullDiskAccess: true) }
    }

    /// Loads (once) the installed apps list; concurrent callers share one inventory run.
    @discardableResult
    func loadApps(force: Bool = false) async -> [InstalledApp] {
        if appsState == .loaded && !force { return apps }
        if let appsTask { return await appsTask.value }
        appsState = .loading
        appsProgress = ScanProgress(phase: "Ищем приложения", fraction: 0)
        let relay = progressRelay { [weak self] in self?.appsProgress = $0 }
        let task = Task { await AppInventory().installedApps(progress: relay) }
        appsTask = task
        let result = await task.value
        apps = result
        appsState = .loaded
        appsTask = nil
        return result
    }

    // MARK: Full Disk Access flow

    /// Launch: resume the flow after a relaunch from step 2a, or show the first-run onboarding once.
    /// `onboardingDone` comes from `@AppStorage(OnboardingKeys.done)` in RootView.
    func startAccessFlowIfNeeded(onboardingDone: Bool) {
        guard probesSystem, accessFlow == nil else { return }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: OnboardingKeys.awaitingGrant) {
            defaults.removeObject(forKey: OnboardingKeys.awaitingGrant)
            let mode: AccessFlow.Mode = onboardingDone ? .sheet : .onboarding
            if hasFullDiskAccess {
                markOnboardingDone()
                presentFlow(mode, step: .granted)
            } else {
                presentFlow(mode, step: .waiting)
            }
            return
        }
        if !onboardingDone { presentFlow(.onboarding, step: .welcome) }
    }

    /// Opens the Full Disk Access flow (steps 2–3 as an in-window sheet; Esc or «Не сейчас» closes it).
    /// Modules call this from FDA banners, PartialAccessNote and CompletionView's «Дать доступ».
    /// Once access is granted the steps never show again: a short toast confirms the state instead.
    func presentAccessSheet() {
        guard accessFlow == nil, cleaning == nil else { return }
        if hasFullDiskAccess {
            showToast(Toast(text: "Полный доступ к диску уже включён", symbol: "checkmark.shield.fill", kind: .success))
            return
        }
        if confirmation != nil { dismissConfirmation() }
        presentFlow(.sheet, step: .prime)
    }

    func presentFlow(_ mode: AccessFlow.Mode, step: AccessFlow.Step) {
        let flow = AccessFlow(mode: mode, step: .welcome, live: probesSystem)
        flow.app = self
        withAnimation(Theme.spring) { accessFlow = flow }
        // Through `go`, so entering 2a starts the polling.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { flow.go(step) }
    }

    func closeAccessFlow() {
        guard let flow = accessFlow else { return }
        flow.tearDown()
        withAnimation(Theme.softSpring) { accessFlow = nil }
    }

    /// Step 1 «Начать» (access already there) and 2b «Продолжить без доступа».
    func finishOnboarding() {
        markOnboardingDone()
        closeAccessFlow()
    }

    /// Step 3 «Начать умную очистку».
    func accessFlowStartSmartCare() {
        closeAccessFlow()
        select(.smartCare)
        smartCare.startScan()
    }

    private func markOnboardingDone() {
        guard probesSystem else { return }
        UserDefaults.standard.set(true, forKey: OnboardingKeys.done)
    }

    // MARK: Toasts

    func showToast(_ toast: Toast) {
        toastTask?.cancel()
        withAnimation(Theme.spring) { self.toast = toast }
        if probesSystem { AccessibilityNotification.Announcement(toast.text).post() }
        guard probesSystem else { return }
        let id = toast.id
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.action == nil ? 5 : 8))
            guard !Task.isCancelled, let self, self.toast?.id == id else { return }
            withAnimation(Theme.spring) { self.toast = nil }
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        withAnimation(Theme.spring) { toast = nil }
    }

    // MARK: Confirmations & navigation

    func ask(_ confirmation: Confirmation) {
        withAnimation(Theme.spring) { self.confirmation = confirmation }
    }

    func dismissConfirmation() {
        withAnimation(Theme.spring) { confirmation = nil }
    }

    func select(_ module: AppModule) {
        if trashCompletion != nil { trashCompletion = nil }
        if storageExplorer != nil { closeStorage() }
        withAnimation(Theme.softSpring) { selection = module }
    }

    /// Opens «Хранилище» on `kind` (default: the biggest category).
    func openStorage(_ kind: StorageCategory.Kind? = nil) {
        guard let b = storage.breakdown, !isModalActive else { return }
        let start = kind ?? b.categories.filter { $0.kind != .system }.max { $0.bytes < $1.bytes }?.kind ?? .apps
        if let open = storageExplorer {
            open.select(start)
            return
        }
        withAnimation(Theme.softSpring) {
            storageExplorer = StorageExplorerModel(kind: start, fullDiskAccess: hasFullDiskAccess)
        }
    }

    func closeStorage() {
        storageExplorer?.cancel()
        withAnimation(Theme.softSpring) { storageExplorer = nil }
    }

    /// Drag & drop of an .app anywhere on the window (or the Dock icon) opens it in the uninstaller.
    /// Refused (with a beep) while a confirmation, the cleaning scene or the access flow is up:
    /// switching modules then would lose that module's completion screen.
    @discardableResult
    func handleDrop(_ urls: [URL]) -> Bool {
        guard let app = urls.first(where: { $0.pathExtension.lowercased() == "app" }) else { return false }
        guard !isModalActive else {
            NSSound.beep()
            return false
        }
        select(.uninstaller)
        uninstaller.open(appURL: app)
        return true
    }

    /// Called after any removal so every screen stays consistent.
    func didRemove(_ result: RemovalResult) {
        let removed = Set(result.removed.map(\.standardizedFileURL))
        guard !removed.isEmpty else { return }
        if result.freedBytes > 0 {
            let cleanup = LastCleanup(date: Date(), bytes: result.freedBytes)
            lastCleanup = cleanup
            if probesSystem { cleanup.save() }
        }
        junk.forget(removed)
        oldFiles.forget(removed)
        duplicates.forget(removed)
        uninstaller.forget(removed)
        if storage.persistsResults { storage.refresh() }
        refreshSystemState()
    }

    // MARK: Text focus (⌘⌫ must not steal "delete to line start" from a text field)

    private func observeTextFocus() {
        let center = NotificationCenter.default
        focusObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.track(window) }
        })
    }

    private func track(_ window: NSWindow) {
        responderObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
            let editing = (window.firstResponder as? NSTextView)?.isEditable == true
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.textInputFocused != editing else { return }
                    self.textInputFocused = editing
                }
            }
        }
    }
}

// MARK: - Toast

/// A short message at the bottom of the content area, optionally with one action.
struct Toast: Identifiable {
    enum Kind { case success, info, warning }
    let id = UUID()
    var text: String
    var symbol: String
    var kind: Kind = .info
    var actionTitle: String? = nil
    var action: (@MainActor () -> Void)? = nil
}

// MARK: - Menu commands

extension AppModel {
    /// «Сканировать заново» (⌘R) is possible: nothing modal and the module is not busy.
    var canRescan: Bool {
        guard !isModalActive else { return false }
        return switch selection {
        case .smartCare: smartCare.phase != .scanning && smartCare.phase != .cleaning
        case .junk: junk.phase != .scanning && junk.phase != .cleaning
        case .uninstaller:
            uninstaller.tab == .leftovers ? uninstaller.orphanState != .scanning
                                          : uninstaller.phase != .scanning && uninstaller.phase != .cleaning
        case .oldFiles: oldFiles.phase != .scanning && oldFiles.phase != .cleaning
        case .duplicates: duplicates.phase != .scanning && duplicates.phase != .cleaning
        case .diskMap: diskMap.phase != .scanning && diskMap.phase != .cleaning
        case .startup: startup.phase != .scanning && !startup.isBusy
        }
    }

    /// ⌘R: starts the current module's scan again.
    func rescanCurrent() {
        guard canRescan else { NSSound.beep(); return }
        dismissToast()
        switch selection {
        case .smartCare: smartCare.startScan()
        case .junk: junk.startScan()
        case .uninstaller:
            if uninstaller.tab == .leftovers {
                Task { await uninstaller.scanOrphans() }
            } else {
                Task {
                    await loadApps(force: true)
                    uninstaller.startScan()
                }
            }
        case .oldFiles: oldFiles.startScan()
        case .duplicates: duplicates.startScan()
        case .diskMap: diskMap.startScan()
        case .startup: startup.startScan()
        }
    }

    /// The current module has results and something selected for its destructive action.
    var canPerformPrimaryAction: Bool {
        guard !isModalActive, !textInputFocused else { return false }
        return switch selection {
        case .smartCare: smartCare.phase == .results && !junk.selection.isEmpty
        case .junk: junk.phase == .results && !junk.selection.isEmpty
        case .uninstaller:
            uninstaller.phase == .results && (uninstaller.tab == .leftovers
                ? !uninstaller.orphanSelection.isEmpty
                : !uninstaller.checkedApps.isEmpty || uninstaller.selectedApp.map { !$0.isSystemApp } == true)
        case .oldFiles: oldFiles.phase == .results && !oldFiles.selection.isEmpty
        case .duplicates: duplicates.phase == .results && !duplicates.marked.isEmpty
        case .diskMap: !diskMap.collector.isEmpty && diskMap.phase != .scanning && diskMap.phase != .cleaning
        case .startup: startup.phase == .results && !startup.isBusy && !startup.removable.isEmpty
        }
    }

    /// Menu title of ⌘⌫, the same verb as the module's round button.
    var primaryActionTitle: String {
        switch selection {
        case .smartCare, .junk: "Очистить…"
        case .uninstaller, .startup: "Удалить…"
        case .oldFiles, .duplicates, .diskMap: "Переместить в Корзину…"
        }
    }

    /// ⌘⌫: asks the module's own confirmation (nothing is removed without it).
    func primaryActionCurrent() {
        // The menu item can fire while a text field became first responder after the menu was built:
        // give the keystroke back to it (⌘⌫ = delete to the beginning of the line).
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
            editor.doCommand(by: #selector(NSStandardKeyBindingResponding.deleteToBeginningOfLine(_:)))
            return
        }
        guard canPerformPrimaryAction else { NSSound.beep(); return }
        switch selection {
        case .smartCare: smartCare.requestClean()
        case .junk: junk.requestClean()
        case .uninstaller:
            if uninstaller.tab == .leftovers { uninstaller.requestRemoveOrphans() }
            else if !uninstaller.checkedApps.isEmpty { uninstaller.requestBatchUninstall() }
            else { uninstaller.requestUninstall() }
        case .oldFiles: oldFiles.requestTrash()
        case .duplicates: duplicates.requestTrash()
        case .diskMap: diskMap.requestTrash()
        case .startup: startup.requestRemove(startup.removable)
        }
    }

    /// ⌘F: the only search is the Uninstaller's app list; switch there first if needed.
    func requestSearchFocus() {
        guard !isModalActive else { NSSound.beep(); return }
        if selection == .uninstaller && uninstaller.tab == .apps {
            searchFocusRequest &+= 1
            return
        }
        select(.uninstaller)
        uninstaller.tab = .apps
        // Once the freshly selected module is on screen.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.searchFocusRequest &+= 1
        }
    }
}

// MARK: - Empty Trash

/// Top-level item of ~/.Trash with its size on disk.
struct TrashItem: Sendable {
    let url: URL
    let size: Int64
}

struct TrashCompletion {
    let result: RemovalResult
    let tint: ModuleTint
}

enum SettingsKeys {
    /// «Показывать предупреждение перед очисткой Корзины» (Settings → Очистка). Default on.
    static let confirmEmptyTrash = "settings.confirmEmptyTrash.v1"
}

extension AppModel {
    enum TrashListing: Sendable {
        /// macOS hides ~/.Trash from apps without Full Disk Access.
        case unreadable
        case items([TrashItem])
    }

    static var trashURL: URL { SafetyGuard.home.appendingPathComponent(".Trash") }

    /// Lists the Trash's top-level items with sizes, off the main thread. Finder bookkeeping files are skipped.
    nonisolated static func listTrash(at trash: URL) async -> TrashListing {
        await Task.detached(priority: .userInitiated) {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: trash, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey], options: []
            ) else { return .unreadable }
            let skipped: Set<String> = [".DS_Store", ".localized"]
            let items = urls
                .filter { !skipped.contains($0.lastPathComponent) }
                .map { TrashItem(url: $0, size: FileSizer.allocatedSize(of: $0)) }
                .sorted { $0.size > $1.size }
            return .items(items)
        }.value
    }

    /// «Очистить Корзину…» from CompletionView: lists ~/.Trash, confirms (permanent), then empties it
    /// through the cleaning scene. Without Full Disk Access macOS hides the Trash: say so and offer access.
    func requestEmptyTrash() {
        guard !isModalActive else { NSSound.beep(); return }
        // Snapshots and tests never read (let alone empty) the real Trash.
        guard probesSystem else { return }
        Task { [weak self] in
            let listing = await Self.listTrash(at: Self.trashURL)
            guard let self else { return }
            switch listing {
            case .unreadable:
                self.showToast(Toast(text: "Нет доступа к Корзине — macOS показывает её только с полным доступом к диску",
                                     symbol: "lock.shield.fill", kind: .warning, actionTitle: "Дать доступ",
                                     action: { [weak self] in self?.presentAccessSheet() }))
            case .items(let items) where items.isEmpty:
                self.showToast(Toast(text: "Корзина уже пуста", symbol: "trash", kind: .info))
            case .items(let items):
                self.confirmEmptyTrash(items)
            }
        }
    }

    /// The «Удалить навсегда» confirmation with count and size (skipped only if turned off in Settings).
    func confirmEmptyTrash(_ items: [TrashItem]) {
        guard !items.isEmpty else { return }
        let warn = probesSystem ? (UserDefaults.standard.object(forKey: SettingsKeys.confirmEmptyTrash) as? Bool ?? true) : true
        let run: @MainActor () -> Void = { [weak self] in self?.emptyTrash(items) }
        guard warn else { run(); return }
        ask(.make(.deleteForever, title: "Очистить Корзину?",
                  count: items.count, bytes: items.reduce(0) { $0 + $1.size }, noun: .items,
                  tint: selection.tint, action: run))
    }

    /// One stage «Корзина»; `FileRemover` refuses anything outside a Trash folder.
    private func emptyTrash(_ items: [TrashItem]) {
        guard cleaning == nil, probesSystem else { return }
        let tint = selection.tint
        let pairs = items.map { (url: $0.url, size: $0.size) }
        var plan = CleaningPlan(title: "Очистка Корзины", module: selection, tint: tint)
        plan.symbol = "trash.fill"
        plan.activity = "Сейчас"
        plan.addStage("Корзина", symbol: "trash.fill", items: pairs)
        let sizes = CleaningPrep.sizes(pairs.map { ($0.url, $0.size) })
        // Items the user may not delete (apps uninstalled with the admin password) go in one unit last:
        // a single password prompt, like Finder's «Очистить Корзину».
        let urls = items.map(\.url)
        let adminOnly = urls.filter(FileRemover.needsAdminToDelete)
        plan.addChunks(urls.filter { !adminOnly.contains($0) }) { chunk, progress in
            await FileRemover.deletePermanentlyFromTrash(chunk, knownSizes: sizes, progress: progress)
        }
        if !adminOnly.isEmpty {
            plan.addChunks(adminOnly, size: adminOnly.count) { chunk, progress in
                await FileRemover.deletePermanentlyFromTrash(chunk, knownSizes: sizes, progress: progress)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.runCleaning(plan)
            // Synchronously after runCleaning (see its contract): the scene fades into «Удалено навсегда».
            self.finishCompletionScreen(of: self.selection)
            self.trashCompletion = TrashCompletion(result: result, tint: tint)
            self.didRemove(result)
        }
    }

    /// The module's own «В Корзине X» screen is out of date once the Trash is gone: return it to results,
    /// so «Готово» on the Trash completion leads back to a current screen.
    private func finishCompletionScreen(of module: AppModule) {
        switch module {
        case .smartCare: if smartCare.phase == .done { smartCare.finish() }
        case .junk: if junk.phase == .done { junk.finish() }
        case .uninstaller: if uninstaller.phase == .done { uninstaller.finish() }
        case .oldFiles: if oldFiles.phase == .done { oldFiles.finish() }
        case .duplicates: if duplicates.phase == .done { duplicates.finish() }
        case .diskMap: if diskMap.phase == .done { diskMap.finish() }
        case .startup: break
        }
    }

    func dismissTrashCompletion() {
        withAnimation(Theme.spring) { trashCompletion = nil }
    }
}

/// When the user last cleaned something and how much. A tiny record in UserDefaults.
struct LastCleanup: Equatable {
    let date: Date
    let bytes: Int64

    private static let dateKey = "lastCleanup.date"
    private static let bytesKey = "lastCleanup.bytes"

    static func load() -> LastCleanup? {
        let d = UserDefaults.standard
        guard let date = d.object(forKey: dateKey) as? Date else { return nil }
        return LastCleanup(date: date, bytes: Int64(d.integer(forKey: bytesKey)))
    }

    func save() {
        UserDefaults.standard.set(date, forKey: Self.dateKey)
        UserDefaults.standard.set(Int(bytes), forKey: Self.bytesKey)
    }
}
