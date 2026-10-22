import SwiftUI
import CleanerKit
import JunkEngine
import SpaceEngine

/// Dashboard: runs the junk, old-files and leftovers scans together and reuses their results,
/// so a category shows the same numbers here and in its own module.
@MainActor @Observable
final class SmartCareModel {
    @ObservationIgnored weak var app: AppModel?

    var phase: ModulePhase = .idle
    var result: RemovalResult?
    /// The last clean emptied the Trash (permanent).
    var resultWasPermanent = false
    /// Sections whose selection goes into the clean. After a scan only the junk is; leftovers and old files are the
    /// user's call (their own selection inside is kept while a section is off).
    var included: Set<Area> = [.junk]
    /// The section opened under its tile to pick what goes.
    var expanded: Area?
    @ObservationIgnored private var task: Task<Void, Never>?

    enum Area: CaseIterable { case junk, leftovers, oldFiles }

    struct AreaStatus {
        let title: String
        let symbol: String
        let fraction: Double
        let done: Bool
        let detail: String
    }

    var areas: [AreaStatus] {
        guard let app else { return [] }
        let junkDone = app.junk.phase != .scanning
        let oldDone = app.oldFiles.phase != .scanning
        let orphansDone = app.uninstaller.orphanState == .loaded
        return [
            AreaStatus(title: "Системный мусор", symbol: AppModule.junk.symbol,
                       fraction: junkDone ? 1 : app.junk.progress.fraction, done: junkDone,
                       detail: junkDone ? Fmt.size(app.junk.totalSize) : app.junk.progress.phase),
            AreaStatus(title: "Остатки приложений", symbol: AppModule.uninstaller.symbol,
                       fraction: orphansDone ? 1 : app.uninstaller.orphanProgress.fraction, done: orphansDone,
                       detail: orphansDone ? Fmt.size(app.uninstaller.orphansSize) : app.uninstaller.orphanProgress.phase),
            AreaStatus(title: "Старые файлы", symbol: AppModule.oldFiles.symbol,
                       fraction: oldDone ? 1 : app.oldFiles.progress.fraction, done: oldDone,
                       detail: oldDone ? Fmt.size(app.oldFiles.totalSize) : app.oldFiles.progress.phase),
        ]
    }

    /// Average progress of the areas. Takes the array so a body computes `areas` once.
    static func fraction(of areas: [AreaStatus]) -> Double {
        guard !areas.isEmpty else { return 0 }
        return areas.reduce(0) { $0 + $1.fraction } / Double(areas.count)
    }

    static func phaseText(of areas: [AreaStatus]) -> String {
        let active = areas.filter { !$0.done }
        return active.isEmpty ? "Завершаем" : "Проверяем: " + active.map { $0.title.lowercased() }.joined(separator: ", ")
    }

    // MARK: Results digest

    struct Line: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
    }

    /// Everything the overview tiles show that takes a sort or a scan over many items. Built once per set of results
    /// (see `digest()`), not once per body.
    struct Digest {
        var junkTop: [Line] = []
        var orphanTop: [Line] = []
        var oldTop: [Line] = []
        var orphansBytes: Int64 = 0
        var oldBytes: Int64 = 0
        var oldCount = 0
        var unusedTop: [InstalledApp] = []
        var unusedCount = 0
        var unusedBytes: Int64 = 0

        /// Nothing to offer in any tile.
        var isEmpty: Bool { orphanTop.isEmpty && oldCount == 0 && unusedCount == 0 }
    }

    private struct DigestKey: Equatable {
        var junkItems: Int
        var orphans: Int
        var oldFiles: Int
        var months: Int
        var apps: Int
    }

    @ObservationIgnored private var cached: (key: DigestKey, digest: Digest)?

    /// Top-3 lists, unused apps and sums for the tiles. Rebuilt only when the underlying results change
    /// (a rescan, or something removed in another module).
    func digest() -> Digest {
        guard let app else { return Digest() }
        let key = DigestKey(junkItems: app.junk.itemCount, orphans: app.uninstaller.orphans.count,
                            oldFiles: app.oldFiles.files.count, months: app.oldFiles.months, apps: app.apps.count)
        if let cached, cached.key == key { return cached.digest }
        var d = Digest()
        d.junkTop = app.junk.categories.prefix(3).map { Line(id: $0.id, title: $0.title, bytes: $0.totalSize) }
        d.orphansBytes = app.uninstaller.orphansSize
        d.orphanTop = app.uninstaller.orphans.prefix(3).map { Line(id: "\($0.id)", title: $0.displayName, bytes: $0.totalSize) }
        let old = app.oldFiles.files
        d.oldBytes = old.reduce(0) { $0 + $1.item.size }
        d.oldCount = old.count
        d.oldTop = old.sorted { $0.item.size > $1.item.size }.prefix(3)
            .map { Line(id: $0.item.url.path, title: $0.item.name, bytes: $0.item.size) }
        let unused = app.uninstaller.unusedApps
        d.unusedCount = unused.count
        d.unusedBytes = unused.reduce(0) { $0 + $1.size }
        d.unusedTop = Array(unused.sorted { $0.size > $1.size }.prefix(7))
        cached = (key, d)
        return d
    }

    /// Most specific "what is happening now" line.
    var currentPath: String? {
        guard let app else { return nil }
        return [app.junk.progress, app.oldFiles.progress, app.uninstaller.orphanProgress]
            .compactMap(\.currentPath).first
    }

    func startScan() {
        app?.storage.noteUserScan()
        task?.cancel()
        task = Task { await scan() }
    }

    func scan() async {
        guard let app else { return }
        withAnimation(Theme.spring) { phase = .scanning; included = [.junk]; expanded = nil }
        app.oldFiles.mode = .old
        async let junk: Void = app.junk.scan()
        async let old: Void = app.oldFiles.scan()
        async let leftovers: Void = app.uninstaller.scanOrphans()
        _ = await (junk, old, leftovers)
        guard !Task.isCancelled else { return }
        cached = nil
        app.refreshSystemState()
        withAnimation(Theme.spring) { phase = .results }
    }

    func stop() {
        task?.cancel()
        app?.junk.stop()
        app?.oldFiles.stop()
        withAnimation(Theme.spring) { phase = .idle }
    }

    // MARK: Choice

    func selectedBytes(_ area: Area) -> Int64 {
        guard let app else { return 0 }
        return switch area {
        case .junk: app.junk.selectedSize
        case .leftovers: app.uninstaller.selectedOrphansSize
        case .oldFiles: app.oldFiles.selectedSize
        }
    }

    func selectedCount(_ area: Area) -> Int {
        guard let app else { return 0 }
        return switch area {
        case .junk: app.junk.selectedCount
        case .leftovers: app.uninstaller.orphanSelection.count
        case .oldFiles: app.oldFiles.selection.count
        }
    }

    /// What the round button cleans: the selection of the sections that are on.
    var totalBytes: Int64 { included.reduce(0) { $0 + selectedBytes($1) } }
    var totalCount: Int { included.reduce(0) { $0 + selectedCount($1) } }
    var includesTrash: Bool { included.contains(.junk) && (app?.junk.includesTrash ?? false) }

    /// The tile's switch. Turning a section on with nothing ticked inside ticks what its own module ticks after a
    /// scan; old files are the user's own documents, so nothing is ticked for them and the list opens instead.
    func setIncluded(_ area: Area, _ on: Bool) {
        guard let app else { return }
        if on && selectedCount(area) == 0 {
            switch area {
            case .junk: app.junk.selectDefaults()
            case .leftovers: app.uninstaller.selectDefaultOrphans()
            case .oldFiles: break
            }
            if selectedCount(area) == 0 { toggleExpanded(area) }
        }
        withAnimation(Theme.quick) {
            if on { included.insert(area) } else { included.remove(area) }
        }
    }

    /// Ticking something inside a section turns it on; unticking everything turns it off.
    func selectionChanged(_ area: Area, from old: Int, to new: Int) {
        if new > old { included.insert(area) } else if new == 0 { included.remove(area) }
    }

    func toggleExpanded(_ area: Area) {
        withAnimation(Theme.unfold) { expanded = expanded == area ? nil : area }
    }

    // MARK: Clean

    func requestClean() {
        guard let app, totalCount > 0 else { return }
        let needsAdmin = (included.contains(.junk) && app.junk.includesSystemLogs)
            || (included.contains(.leftovers) && app.uninstaller.selectedOrphanRemnants.contains(where: \.requiresAdmin))
        app.ask(JunkModel.cleanConfirmation(count: totalCount, bytes: totalBytes,
                                            trashBytes: included.contains(.junk) ? app.junk.selectedTrashBytes : 0,
                                            dockerBytes: included.contains(.junk) ? app.junk.selectedDockerBytes : 0,
                                            needsAdmin: needsAdmin, tint: .smartCare) { [weak self] in self?.startClean() })
    }

    /// One cleaning scene for everything: junk categories, then leftovers by app, then old files by kind.
    static func plan(junk: [(JunkCategory, [FileItem])], leftovers: [AppRemnant], groups: [OrphanGroup],
                     oldFiles: [AnalyzedFile]) -> CleaningPlan {
        var plan = CleaningPlan(title: "Умная очистка", module: .smartCare)
        if !junk.isEmpty { plan.append(JunkModel.plan(junk, title: plan.title, module: .smartCare)) }
        if !leftovers.isEmpty {
            plan.append(UninstallerModel.removalPlan(leftovers, title: plan.title, byApp: true, groups: groups))
        }
        if !oldFiles.isEmpty { plan.append(OldFilesModel.plan(oldFiles)) }
        return plan
    }

    private func startClean() {
        task = Task {
            guard let app else { return }
            let junk = included.contains(.junk) ? app.junk.selectedPairs : []
            let leftovers = included.contains(.leftovers) ? app.uninstaller.selectedOrphanRemnants : []
            let old = included.contains(.oldFiles) ? app.oldFiles.selectedFiles : []
            resultWasPermanent = leftovers.isEmpty && old.isEmpty && junk.count == 1 && junk[0].0.id == JunkCategoryID.trash
            withAnimation(Theme.spring) { phase = .cleaning }
            let total = await app.runCleaning(Self.plan(junk: junk, leftovers: leftovers, groups: app.uninstaller.orphans,
                                                        oldFiles: old))
            result = total
            // `.done` before `didRemove`: dropping the removed items re-renders the screens mid-update.
            withAnimation(Theme.spring) { phase = .done }
            app.didRemove(total)
            // Modules with nothing left go back to «idle» (not one that started a scan of its own meanwhile).
            if app.junk.phase == .results { app.junk.finish() }
            if app.oldFiles.phase == .results { app.oldFiles.finish() }
        }
    }

    /// «Повторить» on the completion screen: exactly the refused items selected, in their sections, and ask again.
    func retryFailed() {
        guard let app, let result else { return }
        app.junk.selectFailed(from: result)
        app.uninstaller.selectFailedOrphans(from: result)
        app.oldFiles.selectFailed(from: result)
        included = Set(Area.allCases.filter { selectedCount($0) > 0 })
        finish()
        requestClean()
    }

    func finish() {
        // `result` stays: the completion screen fades out with its numbers (the next cleanup replaces it).
        withAnimation(Theme.spring) { phase = .results }
    }
}
