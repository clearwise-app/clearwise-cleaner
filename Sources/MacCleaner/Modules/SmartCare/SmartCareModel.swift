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

    var fraction: Double {
        let a = areas
        guard !a.isEmpty else { return 0 }
        return a.reduce(0) { $0 + $1.fraction } / Double(a.count)
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
        guard let app, app.junk.selectedCount > 0 else { return }
        let junk = app.junk
        var message = "Будет очищен только выбранный системный мусор — кэши и журналы, которые создаются заново. Файлы попадут в Корзину."
        if junk.includesTrash { message += " Содержимое Корзины будет удалено безвозвратно." }
        app.ask(Confirmation(
            title: "Очистить системный мусор?",
            message: message,
            count: junk.selectedCount,
            bytes: junk.selectedSize,
            confirmTitle: "Очистить",
            permanent: junk.includesTrash,
            needsAdmin: junk.selectedPairs.contains { $0.0.id == JunkCategoryID.systemLogs },
            tint: .smartCare,
            action: { [weak self] in self?.startClean() }
        ))
    }

    private func startClean() {
        task = Task {
            guard let app else { return }
            withAnimation(Theme.spring) { phase = .cleaning }
            await app.junk.clean(title: "Умная очистка", module: .smartCare)
            result = app.junk.result
            app.junk.finish()
            withAnimation(Theme.spring) { phase = .done }
        }
    }

    func finish() {
        result = nil
        withAnimation(Theme.spring) { phase = .results; reviewing = false }
    }
}
