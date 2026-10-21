import SwiftUI
import AppKit
import CleanerKit
import UninstallEngine

@MainActor @Observable
final class UninstallerModel {
    @ObservationIgnored weak var app: AppModel?

    enum Tab: Hashable { case apps, leftovers }
    enum Sort: Hashable { case size, name, lastUsed }
    enum Filter: Hashable { case all, unused, appStore }
    enum OrphanState { case notScanned, scanning, loaded }

    var phase: ModulePhase = .idle
    var tab: Tab = .apps
    var search = ""
    var sort: Sort = .size
    var filter: Filter = .all
    var showSystemApps = false

    // Apps
    var selectedAppID: URL?
    var checkedApps: Set<URL> = []
    var remnants: [AppRemnant] = []
    var remnantsLoading = false
    var remnantSelection: Set<URL> = []
    /// An app dropped onto the window that the inventory did not list (e.g. outside /Applications).
    var externalApps: [InstalledApp] = []
    /// Apps whose bundle is being sized after a drop.
    var preparingDrop = false
    /// Bundles of the apps running right now (standardized), kept current by NSWorkspace launch/quit notifications.
    var runningURLs: Set<URL> = []

    /// Confident leftovers of every checked app (what a batch removal takes), filled in the background.
    var batchRemnants: [URL: [AppRemnant]] = [:]

    // Leftovers of deleted apps
    var orphanState: OrphanState = .notScanned
    var orphanProgress = ScanProgress(phase: "", fraction: 0)
    var orphans: [OrphanGroup] = []
    var focusedOrphanID: String?
    var orphanSelection: Set<URL> = []

    // Result
    var result: RemovalResult?
    var resultTitle = ""

    @ObservationIgnored private let finder = RemnantFinder()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var remnantsTask: Task<Void, Never>?
    @ObservationIgnored private var batchTask: Task<Void, Never>?
    @ObservationIgnored private var orphanTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    /// The last confirmed removal, so «Повторить» can retry exactly what failed.
    @ObservationIgnored private var lastRequest: RemovalRequest?
    /// The finder has been given the inventory we already loaded (saves it a rescan).
    @ObservationIgnored private var finderSynced = false

    private func syncFinder() async {
        guard !finderSynced, let apps = app?.apps, !apps.isEmpty else { return }
        await finder.setInstalledApps(apps)
        finderSynced = true
    }

    // MARK: Apps list

    var allApps: [InstalledApp] { (app?.apps ?? []) + externalApps.filter { e in !(app?.apps ?? []).contains { $0.url == e.url } } }

    /// Filtered and sorted list. Not cached: read it once per body (`let apps = model.visibleApps`).
    var visibleApps: [InstalledApp] {
        let q = search.trimmingCharacters(in: .whitespaces)
        var list = allApps.filter { showSystemApps || !$0.isSystemApp }
        if !q.isEmpty {
            list = list.filter { $0.name.localizedStandardContains(q) || ($0.bundleID?.localizedStandardContains(q) ?? false) }
        }
        switch filter {
        case .all: break
        case .unused: list = list.filter { (Fmt.monthsSince($0.lastUsed) ?? 999) >= 6 }
        case .appStore: list = list.filter(\.isAppStore)
        }
        switch sort {
        case .size: list.sort { $0.size > $1.size }
        case .name: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .lastUsed: list.sort { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
        return list
    }

    var selectedApp: InstalledApp? { allApps.first { $0.url == selectedAppID } }

    var unusedApps: [InstalledApp] {
        allApps.filter { !$0.isSystemApp && (Fmt.monthsSince($0.lastUsed) ?? 999) >= 6 }
    }

    func startScan() {
        app?.storage.noteUserScan()
        task?.cancel()
        task = Task { await loadApps() }
    }

    func loadApps() async {
        guard let app else { return }
        withAnimation(Theme.spring) { phase = .scanning }
        await app.loadApps()
        withAnimation(Theme.spring) { phase = .results }
        if selectedAppID == nil, let first = visibleApps.first { select(first) }
    }

    /// Shows the list immediately if apps were already loaded elsewhere (e.g. by Smart Care).
    /// `observeWorkspace` is off in snapshots so renders don't depend on what runs on this Mac.
    func onAppear(observeWorkspace: Bool = true) {
        if observeWorkspace { observeRunningApps() }
        if phase == .idle, app?.appsState == .loaded {
            phase = .results
            if selectedAppID == nil, let first = visibleApps.first { select(first) }
        }
    }

    func select(_ target: InstalledApp) {
        guard selectedAppID != target.url || remnants.isEmpty else { return }
        selectedAppID = target.url
        remnants = []
        remnantSelection = []
        remnantsLoading = true
        remnantsTask?.cancel()
        remnantsTask = Task {
            await syncFinder()
            let found = await finder.remnants(for: target)
            guard !Task.isCancelled, selectedAppID == target.url else { return }
            remnants = found.sorted { $0.item.size > $1.item.size }
            remnantSelection = Set(found.filter { $0.confidence >= .medium }.map(\.id))
            remnantsLoading = false
        }
    }

    /// Arrow keys in the app list: moves the selection within what is shown.
    func moveSelection(by delta: Int, in apps: [InstalledApp]) {
        guard !apps.isEmpty else { return }
        let current = apps.firstIndex { $0.url == selectedAppID }
        let next = current.map { min(max($0 + delta, 0), apps.count - 1) } ?? (delta > 0 ? 0 : apps.count - 1)
        select(apps[next])
    }

    func toggleChecked(_ a: InstalledApp) {
        guard !a.isSystemApp else { return }
        if checkedApps.contains(a.url) { checkedApps.remove(a.url) } else { checkedApps.insert(a.url) }
        loadBatchRemnants()
    }

    func clearChecked() { checkedApps = [] }

    /// Drag & drop entry point.
    func open(appURL: URL) {
        tab = .apps
        let url = appURL.standardizedFileURL
        Task {
            if let known = allApps.first(where: { $0.url.standardizedFileURL == url }) {
                if phase != .results { phase = .results }
                select(known)
                return
            }
            preparingDrop = true
            phase = .results
            let made = await Self.makeApp(from: url)
            preparingDrop = false
            externalApps.append(made)
            select(made)
            // Load the rest of the list in the background so the user can keep going.
            if app?.appsState == .notLoaded { await app?.loadApps() }
        }
    }

    nonisolated static func makeApp(from url: URL) async -> InstalledApp {
        await Task.detached(priority: .userInitiated) {
            let bundle = Bundle(url: url)
            let info = bundle?.infoDictionary ?? [:]
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let receipt = url.appendingPathComponent("Contents/_MASReceipt/receipt")
            return InstalledApp(
                url: url, name: name, bundleID: bundle?.bundleIdentifier,
                version: info["CFBundleShortVersionString"] as? String, teamID: nil,
                size: FileSizer.allocatedSize(of: url), lastUsed: FileMetadata.lastUsedDate(of: url),
                isSystemApp: AppInventory.isPartOfOS(url) || url.lastPathComponent == "Safari.app",
                isAppStore: FileManager.default.fileExists(atPath: receipt.path)
            )
        }.value
    }

    // MARK: Running apps

    func isRunning(_ a: InstalledApp) -> Bool { runningURLs.contains(a.url.standardizedFileURL) }

    /// Replaces per-body `NSWorkspace.runningApplications` scans with one set updated on launch/quit.
    private func observeRunningApps() {
        guard workspaceObservers.isEmpty else { return }
        refreshRunning()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunning() }
            })
        }
    }

    private func refreshRunning() {
        let now = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL })
        if now != runningURLs { runningURLs = now }
    }

    // MARK: Remnants

    var selectedRemnants: [AppRemnant] { remnants.filter { remnantSelection.contains($0.id) } }
    var selectedRemnantsSize: Int64 { selectedRemnants.reduce(0) { $0 + $1.item.size } }
    var remnantsSize: Int64 { remnants.reduce(0) { $0 + $1.item.size } }

    func toggle(_ r: AppRemnant) {
        if remnantSelection.contains(r.id) { remnantSelection.remove(r.id) } else { remnantSelection.insert(r.id) }
    }

    func toggleGroup(_ items: [AppRemnant]) {
        let ids = items.map(\.id)
        if ids.allSatisfy(remnantSelection.contains) { remnantSelection.subtract(ids) } else { remnantSelection.formUnion(ids) }
    }

    // MARK: Batch

    var checkedAppList: [InstalledApp] { allApps.filter { checkedApps.contains($0.url) && !$0.isSystemApp } }

    /// Sizes for the batch summary: bundles, leftovers found so far, and whether the search is still running.
    struct BatchTotals {
        var appsSize: Int64 = 0
        var remnantsSize: Int64 = 0
        var count = 0
        var loading = false
        var total: Int64 { appsSize + remnantsSize }
    }

    func batchTotals(_ list: [InstalledApp]) -> BatchTotals {
        var t = BatchTotals()
        for a in list {
            t.appsSize += a.size
            t.count += 1
            if let found = batchRemnants[a.url] {
                t.remnantsSize += found.reduce(0) { $0 + $1.item.size }
                t.count += found.count
            } else {
                t.loading = true
            }
        }
        return t
    }

    /// Finds confident leftovers of checked apps one by one, so the summary can show real totals.
    private func loadBatchRemnants() {
        guard batchTask == nil, checkedAppList.contains(where: { batchRemnants[$0.url] == nil }) else { return }
        batchTask = Task {
            await syncFinder()
            while !Task.isCancelled, let next = checkedAppList.first(where: { batchRemnants[$0.url] == nil }) {
                let found = await finder.remnants(for: next).filter { $0.confidence >= .medium }
                batchRemnants[next.url] = found.sorted { $0.item.size > $1.item.size }
            }
            batchTask = nil
        }
    }

    // MARK: Actions

    func requestUninstall() {
        guard let app, let target = selectedApp, !target.isSystemApp else { return }
        let picked = selectedRemnants
        var c = Confirmation.make(
            .delete, title: "Удалить «\(target.name)»?",
            message: "Приложение и выбранные остатки попадут в Корзину — их можно вернуть, пока Корзина не очищена.",
            count: 1 + picked.count, bytes: target.size + picked.reduce(0) { $0 + $1.item.size },
            needsAdmin: picked.contains(where: \.requiresAdmin),
            warning: isRunning(target) ? "«\(target.name)» сейчас запущено — оно будет закрыто." : nil,
            tint: .uninstaller,
            action: { [weak self] in
                self?.run(RemovalRequest(apps: [.init(app: target, remnants: picked)], title: "Удаление «\(target.name)»",
                                         doneTitle: "«\(target.name)» удалено"))
            })
        c.confirmTitle = "Удалить приложение"
        app.ask(c)
    }

    func requestReset() {
        guard let app, let target = selectedApp, !target.isSystemApp else { return }
        let picked = selectedRemnants
        guard !picked.isEmpty else { return }
        var c = Confirmation.make(
            .delete, title: "Сбросить данные «\(target.name)»?",
            message: "Приложение останется, а его настройки, кэши и данные попадут в Корзину. При следующем запуске оно начнёт с чистого листа.",
            count: picked.count, bytes: picked.reduce(0) { $0 + $1.item.size },
            needsAdmin: picked.contains(where: \.requiresAdmin),
            warning: isRunning(target) ? "Закройте «\(target.name)» перед сбросом, иначе оно может пересоздать файлы." : nil,
            tint: .uninstaller,
            action: { [weak self] in
                self?.run(RemovalRequest(loose: picked, title: "Сброс «\(target.name)»", doneTitle: "Данные «\(target.name)» сброшены"))
            })
        c.confirmTitle = "Сбросить данные"
        app.ask(c)
    }

    /// Batch uninstall: confident leftovers of every checked app (found in the background), one confirmation.
    func requestBatchUninstall() {
        let targets = checkedAppList
        guard app != nil, !targets.isEmpty else { return }
        task = Task {
            await syncFinder()
            var plan: [RemovalRequest.AppEntry] = []
            for t in targets {
                let found: [AppRemnant]
                if let known = batchRemnants[t.url] {
                    found = known
                } else {
                    found = await finder.remnants(for: t).filter { $0.confidence >= .medium }
                    batchRemnants[t.url] = found
                }
                plan.append(.init(app: t, remnants: found))
            }
            guard !Task.isCancelled, let app else { return }
            let bytes = plan.reduce(Int64(0)) { $0 + $1.app.size + $1.remnants.reduce(0) { $0 + $1.item.size } }
            let count = plan.reduce(0) { $0 + 1 + $1.remnants.count }
            let running = targets.filter(isRunning)
            let n = targets.count
            var c = Confirmation.make(
                .delete, title: "Удалить \(Fmt.apps(n))?",
                message: "Приложения и их остатки (только точные совпадения) попадут в Корзину — их можно вернуть, пока Корзина не очищена.",
                count: count, bytes: bytes,
                needsAdmin: plan.contains { $0.remnants.contains(where: \.requiresAdmin) },
                warning: running.isEmpty ? nil : "Будут закрыты: \(running.map(\.name).joined(separator: ", ")).",
                tint: .uninstaller,
                action: {
                    self.run(RemovalRequest(apps: plan, title: "Удаление \(Fmt.apps(n))",
                                            doneTitle: "Удалено \(Fmt.apps(n))"))
                })
            c.confirmTitle = "Удалить \(Fmt.apps(n))"
            app.ask(c)
        }
    }

    private func run(_ request: RemovalRequest) {
        lastRequest = request
        let plan = Self.plan(for: request, running: isRunning)
        task = Task {
            // The cleaning overlay covers the module; the screen underneath stays as it was.
            let r = await app?.runCleaning(plan) ?? RemovalResult()
            // Straight after the scene returns (no suspension) so it fades into the completion screen.
            result = r
            resultTitle = request.doneTitle
            // `.done` first: `didRemove` updates other models, and a phase set after it can be lost.
            withAnimation(Theme.spring) { phase = .done }
            app?.didRemove(r)
            // Files moved: the finder's index of what exists is stale now.
            finderSynced = false
            batchTask?.cancel()
            batchTask = nil
            batchRemnants = [:]
            await finder.invalidate()
        }
    }

    /// «Повторить» on the completion screen: only what failed last time, no new confirmation.
    var canRetry: Bool { retryRequest != nil }

    private var retryRequest: RemovalRequest? {
        guard let lastRequest, let result, !result.failed.isEmpty else { return nil }
        return lastRequest.retrying(failed: Set(result.failed.map(\.url.standardizedFileURL)))
    }

    func retry() {
        guard let again = retryRequest else { return }
        run(again)
    }

    // MARK: Cleaning plans

    /// One confirmed removal: whole apps (quit, leftovers, bundle — one engine call each) and/or loose leftovers.
    struct RemovalRequest {
        struct AppEntry { var app: InstalledApp; var remnants: [AppRemnant] }
        var apps: [AppEntry] = []
        var loose: [AppRemnant] = []
        /// Orphans: loose leftovers staged per deleted app.
        var groups: [OrphanGroup] = []
        var title: String
        var doneTitle: String

        var isEmpty: Bool { apps.isEmpty && loose.isEmpty }

        /// What is left to do after `failed`: an app whose bundle is still there is retried whole
        /// (with its failed leftovers); leftovers of an app already in the Trash become loose items.
        func retrying(failed: Set<URL>) -> RemovalRequest? {
            func didFail(_ url: URL) -> Bool { failed.contains(url.standardizedFileURL) }
            var next = RemovalRequest(groups: groups, title: title, doneTitle: doneTitle)
            for e in apps {
                let left = e.remnants.filter { didFail($0.item.url) }
                if didFail(e.app.url) && !e.app.isSystemApp {
                    next.apps.append(AppEntry(app: e.app, remnants: left))
                } else {
                    next.loose += left
                }
            }
            next.loose += loose.filter { didFail($0.item.url) }
            return next.isEmpty ? nil : next
        }
    }

    static func plan(for r: RemovalRequest, running: (InstalledApp) -> Bool) -> CleaningPlan {
        var plan: CleaningPlan
        if r.apps.count == 1, let e = r.apps.first {
            plan = uninstallPlan(e.app, remnants: e.remnants, running: running(e.app))
        } else if !r.apps.isEmpty {
            plan = batchPlan(r.apps.map { ($0.app, $0.remnants) })
        } else {
            plan = CleaningPlan(title: r.title, module: .uninstaller)
        }
        plan.title = r.title
        if !r.loose.isEmpty { addLeftovers(&plan, r.loose, groups: r.groups) }
        return plan
    }

    /// Single app: «Завершение приложения» (if running), leftovers by kind, root-owned leftovers, then the app.
    /// Still one engine call — it quits the app first and moves the bundle last.
    static func uninstallPlan(_ target: InstalledApp, remnants picked: [AppRemnant], running: Bool) -> CleaningPlan {
        var plan = CleaningPlan(title: "Удаление «\(target.name)»", module: .uninstaller)
        let quit = running ? plan.addStage("Завершение приложения", symbol: "power", items: []) : nil
        let ordered = byKind(picked)
        addRemnantStages(&plan, ordered)
        plan.addStage("Приложение", symbol: "app.fill", iconURL: target.url, items: [(target.url, target.size)],
                      admin: bundleNeedsAdmin(target) ? [target.url] : [])
        plan.addUnit(activating: quit) { progress in
            await AppUninstaller.uninstall(target, remnants: ordered, removeBundle: true, progress: progress)
        }
        return plan
    }

    /// Batch: one stage and one engine call per app.
    static func batchPlan(_ apps: [(InstalledApp, [AppRemnant])]) -> CleaningPlan {
        var plan = CleaningPlan(title: "Удаление \(Fmt.apps(apps.count))", module: .uninstaller)
        for (a, remnants) in apps {
            let ordered = byKind(remnants)
            var admin = Set(ordered.filter(\.requiresAdmin).map(\.item.url))
            if bundleNeedsAdmin(a) { admin.insert(a.url) }
            let stage = plan.addStage(a.name, symbol: "app.fill", iconURL: a.url,
                                      items: ordered.map { ($0.item.url, $0.item.size) } + [(a.url, a.size)], admin: admin)
            plan.addUnit(activating: stage) { progress in
                await AppUninstaller.uninstall(a, remnants: ordered, removeBundle: true, progress: progress)
            }
        }
        return plan
    }

    /// Leftovers only (reset, orphans).
    static func removalPlan(_ picked: [AppRemnant], title: String, byApp: Bool, groups: [OrphanGroup] = []) -> CleaningPlan {
        var plan = CleaningPlan(title: title, module: .uninstaller)
        addLeftovers(&plan, picked, groups: byApp ? groups : [])
        return plan
    }

    /// User-owned leftovers go in chunks (a stop request lands between chunks); root-owned ones together
    /// at the end so the administrator password is asked once. Nested URLs are dropped up front, so
    /// chunking never moves a folder and then fails on a file that was inside it.
    private static func addLeftovers(_ plan: inout CleaningPlan, _ picked: [AppRemnant], groups: [OrphanGroup]) {
        let kept = Set(CleaningPrep.dedupe(picked.map(\.item.url)).map(\.standardizedFileURL))
        let deduped = picked.filter { kept.contains($0.item.url.standardizedFileURL) }
        let ordered: [AppRemnant]
        if groups.isEmpty {
            ordered = byKind(deduped)
            addRemnantStages(&plan, ordered)
        } else {
            let ids = Set(deduped.map(\.id))
            var staged: [AppRemnant] = []
            for g in groups {
                let items = g.remnants.filter { ids.contains($0.id) && !$0.requiresAdmin }
                guard !items.isEmpty else { continue }
                plan.addStage(g.displayName, symbol: "app.dashed", items: items.map { ($0.item.url, $0.item.size) })
                staged += items
            }
            // Anything not in a known group still gets removed, after the grouped ones.
            let stagedIDs = Set(staged.map(\.id))
            let rest = deduped.filter { !$0.requiresAdmin && !stagedIDs.contains($0.id) }
            if !rest.isEmpty { addRemnantStages(&plan, byKind(rest), adminToo: false) }
            ordered = staged + rest + deduped.filter(\.requiresAdmin)
            addAdminStage(&plan, ordered)
        }
        let user = ordered.filter { !$0.requiresAdmin }
        let admin = ordered.filter(\.requiresAdmin)
        plan.addChunks(user) { chunk, progress in await AppUninstaller.remove(chunk, progress: progress) }
        if !admin.isEmpty {
            plan.addUnit { progress in await AppUninstaller.remove(admin, progress: progress) }
        }
    }

    private static func byKind(_ remnants: [AppRemnant]) -> [AppRemnant] {
        let order = Dictionary(uniqueKeysWithValues: RemnantKind.allCases.enumerated().map { ($1, $0) })
        return remnants.enumerated().sorted { a, b in
            let ka = order[a.element.kind] ?? 0, kb = order[b.element.kind] ?? 0
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
    }

    private static func addRemnantStages(_ plan: inout CleaningPlan, _ ordered: [AppRemnant], adminToo: Bool = true) {
        for kind in RemnantKind.allCases {
            let items = ordered.filter { $0.kind == kind && !$0.requiresAdmin }
            guard !items.isEmpty else { continue }
            plan.addStage(kind.title, symbol: kind.symbol, items: items.map { ($0.item.url, $0.item.size) })
        }
        if adminToo { addAdminStage(&plan, ordered) }
    }

    private static func addAdminStage(_ plan: inout CleaningPlan, _ ordered: [AppRemnant]) {
        let admin = ordered.filter(\.requiresAdmin)
        guard !admin.isEmpty else { return }
        plan.addStage("Системные компоненты", symbol: "lock.shield.fill", items: admin.map { ($0.item.url, $0.item.size) },
                      admin: Set(admin.map(\.item.url)))
    }

    /// Mirrors the engine's check: a bundle the user cannot move goes through the administrator prompt.
    private static func bundleNeedsAdmin(_ app: InstalledApp) -> Bool {
        let parent = app.url.deletingLastPathComponent().path
        return Darwin.access(parent, W_OK) != 0 || Darwin.access(app.url.path, W_OK) != 0
    }

    func finish() {
        // `result` stays: the completion screen fades out with its numbers (the next cleanup replaces it).
        lastRequest = nil
        withAnimation(Theme.spring) { phase = .results }
        if let selected = selectedApp { selectedAppID = nil; select(selected) }
        else if let first = visibleApps.first { select(first) }
        loadBatchRemnants()
    }

    func forget(_ removed: Set<URL>) {
        if let app {
            let before = app.apps.count
            app.apps.removeAll { removed.contains($0.url.standardizedFileURL) }
            if app.apps.count != before { checkedApps = checkedApps.filter { !removed.contains($0.standardizedFileURL) } }
        }
        externalApps.removeAll { removed.contains($0.url.standardizedFileURL) }
        if let id = selectedAppID, removed.contains(id.standardizedFileURL) {
            selectedAppID = nil
            remnants = []
        }
        remnants.removeAll { removed.contains($0.id.standardizedFileURL) }
        orphans = orphans.compactMap { g in
            let left = g.remnants.filter { !removed.contains($0.id.standardizedFileURL) }
            return left.isEmpty ? nil : OrphanGroup(id: g.id, displayName: g.displayName, remnants: left)
        }
        orphanSelection.subtract(removed)
    }

    // MARK: Orphans

    /// Buttons call this; a second click while scanning does nothing.
    func startOrphanScan() {
        guard orphanState != .scanning else { return }
        orphanTask?.cancel()
        orphanTask = Task { await scanOrphans() }
    }

    func scanOrphans() async {
        guard let app, orphanState != .scanning else { return }
        orphanState = .scanning
        orphanProgress = ScanProgress(phase: "Ищем приложения", fraction: 0)
        let installed = await app.loadApps()
        let relay = progressRelay { [weak self] p in self?.orphanProgress = p }
        let found = await finder.orphans(installed: installed, progress: relay)
        applyOrphans(found)
    }

    func applyOrphans(_ found: [OrphanGroup]) {
        orphans = found.sorted { $0.totalSize > $1.totalSize }
        orphanSelection = Set(orphans.flatMap { $0.remnants.filter { $0.confidence == .high }.map(\.id) })
        focusedOrphanID = orphans.first?.id
        orphanState = .loaded
    }

    var orphansSize: Int64 { orphans.reduce(0) { $0 + $1.totalSize } }
    var focusedOrphan: OrphanGroup? { orphans.first { $0.id == focusedOrphanID } }
    var selectedOrphanRemnants: [AppRemnant] { orphans.flatMap(\.remnants).filter { orphanSelection.contains($0.id) } }

    func orphanState(of g: OrphanGroup) -> CheckState {
        CheckState(selected: g.remnants.filter { orphanSelection.contains($0.id) }.count, total: g.remnants.count)
    }

    func toggleOrphanGroup(_ g: OrphanGroup) {
        let ids = g.remnants.map(\.id)
        if orphanState(of: g) == .on { orphanSelection.subtract(ids) } else { orphanSelection.formUnion(ids) }
    }

    func toggleOrphan(_ r: AppRemnant) {
        if orphanSelection.contains(r.id) { orphanSelection.remove(r.id) } else { orphanSelection.insert(r.id) }
    }

    func toggleOrphanItems(_ items: [AppRemnant]) {
        let ids = items.map(\.id)
        if ids.allSatisfy(orphanSelection.contains) { orphanSelection.subtract(ids) } else { orphanSelection.formUnion(ids) }
    }

    /// Arrow keys in the leftovers list.
    func moveOrphanFocus(by delta: Int) {
        guard !orphans.isEmpty else { return }
        let current = orphans.firstIndex { $0.id == focusedOrphanID }
        let next = current.map { min(max($0 + delta, 0), orphans.count - 1) } ?? (delta > 0 ? 0 : orphans.count - 1)
        focusedOrphanID = orphans[next].id
    }

    func requestRemoveOrphans() {
        let picked = selectedOrphanRemnants
        guard let app, !picked.isEmpty else { return }
        var c = Confirmation.make(
            .delete, title: "Удалить остатки?",
            message: "Файлы удалённых приложений попадут в Корзину — их можно вернуть, пока Корзина не очищена.",
            count: picked.count, bytes: picked.reduce(0) { $0 + $1.item.size },
            needsAdmin: picked.contains(where: \.requiresAdmin), tint: .uninstaller,
            action: { [weak self] in
                guard let self else { return }
                self.run(RemovalRequest(loose: picked, groups: self.orphans, title: "Удаление остатков", doneTitle: "Остатки удалены"))
            })
        c.confirmTitle = "Удалить остатки"
        app.ask(c)
    }
}
