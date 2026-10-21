import SwiftUI
import CleanerKit
import JunkEngine

/// Dashboard: runs the junk, old-files and leftovers scans together and reuses their results,
/// so a category shows the same numbers here and in its own module.
@MainActor @Observable
final class SmartCareModel {
    @ObservationIgnored weak var app: AppModel?

    var phase: ModulePhase = .idle
    var result: RemovalResult?
    /// The last clean emptied the Trash (permanent).
    var resultWasPermanent = false
    /// Second step after the overview: the user picks what to delete and what to keep.
    var reviewing = false
    @ObservationIgnored private var task: Task<Void, Never>?

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
        withAnimation(Theme.spring) { phase = .scanning; reviewing = false }
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

    // MARK: Review → Clean

    func openReview() { withAnimation(Theme.spring) { reviewing = true } }
    func closeReview() { withAnimation(Theme.spring) { reviewing = false } }


    func requestClean() {
        guard let app, let confirmation = app.junk.confirmation(tint: .smartCare, action: { [weak self] in self?.startClean() }) else { return }
        app.ask(confirmation)
    }

    private func startClean() {
        task = Task {
            guard let app else { return }
            withAnimation(Theme.spring) { phase = .cleaning }
            await app.junk.clean(title: "Умная очистка", module: .smartCare)
            result = app.junk.result
            resultWasPermanent = app.junk.resultWasPermanent
            app.junk.finish()
            withAnimation(Theme.spring) { phase = .done }
        }
    }

    /// «Повторить» on the completion screen: back to the review with the refused items selected, and ask again.
    func retryFailed() {
        guard let app, let result else { return }
        app.junk.selectFailed(from: result)
        finish()
        openReview()
        requestClean()
    }

    func finish() {
        result = nil
        withAnimation(Theme.spring) { phase = .results; reviewing = false }
    }
}
