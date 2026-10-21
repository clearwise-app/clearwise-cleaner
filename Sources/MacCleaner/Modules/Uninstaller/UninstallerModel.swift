import SwiftUI
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

    // Leftovers of deleted apps
    var orphanState: OrphanState = .notScanned
    var orphanProgress = ScanProgress(phase: "", fraction: 0)
    var orphans: [OrphanGroup] = []
    var focusedOrphanID: String?
    var orphanSelection: Set<URL> = []

    // Work / result
    var workingTitle = ""
    var result: RemovalResult?
    var resultTitle = ""

    @ObservationIgnored private let finder = RemnantFinder()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var remnantsTask: Task<Void, Never>?
    /// The finder has been given the inventory we already loaded (saves it a rescan).
    @ObservationIgnored private var finderSynced = false

    private func syncFinder() async {
        guard !finderSynced, let apps = app?.apps, !apps.isEmpty else { return }
        await finder.setInstalledApps(apps)
        finderSynced = true
    }

    // MARK: Apps list

    var allApps: [InstalledApp] { (app?.apps ?? []) + externalApps.filter { e in !(app?.apps ?? []).contains { $0.url == e.url } } }

    var visibleApps: [InstalledApp] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var list = allApps.filter { showSystemApps || !$0.isSystemApp }
        if !q.isEmpty {
            list = list.filter { $0.name.lowercased().contains(q) || ($0.bundleID?.lowercased().contains(q) ?? false) }
        }
        switch filter {
        case .all: break
        case .unused: list = list.filter { (Fmt.monthsSince($0.lastUsed) ?? 999) >= 6 }
        case .appStore: list = list.filter(\.isAppStore)
        }
        switch sort {
        case .size: list.sort { $0.size > $1.size }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .lastUsed: list.sort { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
        return list
    }

    var selectedApp: InstalledApp? { allApps.first { $0.url == selectedAppID } }

    var unusedApps: [InstalledApp] {
        allApps.filter { !$0.isSystemApp && (Fmt.monthsSince($0.lastUsed) ?? 999) >= 6 }
    }

    func startScan() {
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
    func onAppear() {
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

    func toggleChecked(_ a: InstalledApp) {
        if checkedApps.contains(a.url) { checkedApps.remove(a.url) } else { checkedApps.insert(a.url) }
    }

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

    // MARK: Remnants

    var remnantGroups: [(kind: RemnantKind, items: [AppRemnant])] {
        RemnantKind.allCases.compactMap { kind in
            let items = remnants.filter { $0.kind == kind }
            return items.isEmpty ? nil : (kind, items)
        }
    }

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

    func isRunning(_ a: InstalledApp) -> Bool { AppUninstaller.isRunning(a) }

    // MARK: Actions

    func requestUninstall() {
        guard let app, let target = selectedApp, !target.isSystemApp else { return }
        let picked = selectedRemnants
        app.ask(Confirmation(
            title: "Удалить «\(target.name)»?",
            message: "Приложение и выбранные остатки будут перемещены в Корзину — их можно вернуть, пока Корзина не очищена.",
            count: 1 + picked.count,
            bytes: target.size + picked.reduce(0) { $0 + $1.item.size },
            confirmTitle: "Удалить",
            needsAdmin: picked.contains(where: \.requiresAdmin),
            warning: isRunning(target) ? "«\(target.name)» сейчас запущено — оно будет закрыто." : nil,
            tint: .uninstaller,
            action: { [weak self] in self?.run(title: "Удаляем «\(target.name)»…") {
                await AppUninstaller.uninstall(target, remnants: picked, removeBundle: true)
            } done: { "«\(target.name)» удалено" } }
        ))
    }

    func requestReset() {
        guard let app, let target = selectedApp else { return }
        let picked = selectedRemnants
        guard !picked.isEmpty else { return }
        app.ask(Confirmation(
            title: "Сбросить «\(target.name)»?",
            message: "Приложение останется, а его настройки, кэши и данные будут перемещены в Корзину. При следующем запуске оно начнёт с чистого листа.",
            count: picked.count,
            bytes: picked.reduce(0) { $0 + $1.item.size },
            confirmTitle: "Сбросить",
            needsAdmin: picked.contains(where: \.requiresAdmin),
            warning: isRunning(target) ? "Закройте «\(target.name)» перед сбросом, иначе оно может пересоздать файлы." : nil,
            tint: .uninstaller,
            action: { [weak self] in self?.run(title: "Сбрасываем «\(target.name)»…") {
                await AppUninstaller.remove(picked)
            } done: { "«\(target.name)» сброшено" } }
        ))
    }

    var checkedAppList: [InstalledApp] { allApps.filter { checkedApps.contains($0.url) && !$0.isSystemApp } }

    /// Batch uninstall: gathers confident leftovers for every checked app, then asks once.
    func requestBatchUninstall() {
        let targets = checkedAppList
        guard let app, !targets.isEmpty else { return }
        task = Task {
            workingTitle = "Ищем остатки…"
            var plan: [(InstalledApp, [AppRemnant])] = []
            await syncFinder()
            for t in targets {
                let found = await finder.remnants(for: t).filter { $0.confidence >= .medium }
                plan.append((t, found))
            }
            workingTitle = ""
            let bytes = plan.reduce(Int64(0)) { $0 + $1.0.size + $1.1.reduce(0) { $0 + $1.item.size } }
            let count = plan.reduce(0) { $0 + 1 + $1.1.count }
            let running = plan.map(\.0).filter(isRunning)
            app.ask(Confirmation(
                title: "Удалить \(Fmt.apps(targets.count))?",
                message: "Приложения и их остатки (только точные совпадения) будут перемещены в Корзину — их можно вернуть, пока Корзина не очищена.",
                count: count,
                bytes: bytes,
                confirmTitle: "Удалить",
                needsAdmin: plan.contains { $0.1.contains(where: \.requiresAdmin) },
                warning: running.isEmpty ? nil : "Будут закрыты: \(running.map(\.name).joined(separator: ", ")).",
                tint: .uninstaller,
                action: { self.run(title: "Удаляем \(Fmt.apps(targets.count))…") {
                    var total = RemovalResult()
                    for (a, r) in plan { total.merge(await AppUninstaller.uninstall(a, remnants: r, removeBundle: true)) }
                    return total
                } done: { "Удалено \(Fmt.apps(targets.count))" } }
            ))
        }
    }

    private func run(title: String, _ work: @escaping @MainActor () async -> RemovalResult, done: @escaping @MainActor () -> String) {
        task = Task {
            workingTitle = title
            withAnimation(Theme.spring) { phase = .cleaning }
            let r = await work()
            // Files moved: the finder's index of what exists is stale now.
            await finder.invalidate()
            finderSynced = false
            result = r
            resultTitle = done()
            app?.didRemove(r)
            withAnimation(Theme.spring) { phase = .done }
        }
    }

    func finish() {
        result = nil
        withAnimation(Theme.spring) { phase = .results }
        if let selected = selectedApp { selectedAppID = nil; select(selected) }
        else if let first = visibleApps.first { select(first) }
    }

    func forget(_ removed: Set<URL>) {
        if let app {
            let before = app.apps.count
            app.apps.removeAll { removed.contains($0.url.standardizedFileURL) }
            if app.apps.count != before { checkedApps.subtract(removed) }
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

    func scanOrphans() async {
        guard let app else { return }
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

    func requestRemoveOrphans() {
        let picked = selectedOrphanRemnants
        guard let app, !picked.isEmpty else { return }
        app.ask(Confirmation(
            title: "Удалить остатки?",
            message: "Файлы удалённых приложений будут перемещены в Корзину — их можно вернуть, пока Корзина не очищена.",
            count: picked.count,
            bytes: picked.reduce(0) { $0 + $1.item.size },
            confirmTitle: "Переместить в Корзину",
            needsAdmin: picked.contains(where: \.requiresAdmin),
            tint: .uninstaller,
            action: { [weak self] in self?.run(title: "Удаляем остатки…") {
                await AppUninstaller.remove(picked)
            } done: { "Остатки удалены" } }
        ))
    }
}
