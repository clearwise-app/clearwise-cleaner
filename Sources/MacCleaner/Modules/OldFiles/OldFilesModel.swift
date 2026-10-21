import SwiftUI
import CleanerKit
import SpaceEngine

@MainActor @Observable
final class OldFilesModel {
    @ObservationIgnored weak var app: AppModel?

    enum Mode: Hashable { case old, large }
    enum Sort: Hashable { case size, date, name }

    var mode: Mode = .old
    var months = 6
    var oldMinSize: Int64 = 10_000_000
    var largeMinSize: Int64 = 100_000_000
    var roots: [URL] = OldFilesOptions.default.roots
    var disabledRoots: Set<URL> = []

    var phase: ModulePhase = .idle
    var progress = ScanProgress(phase: "", fraction: 0)
    var files: [AnalyzedFile] = []
    /// Mode the current results were produced with.
    var resultMode: Mode = .old
    /// Nothing is ever pre-selected here: these are the user's own files.
    var selection: Set<URL> = []
    var kindFilter: FileKind?
    var sort: Sort = .size
    var quickLookURL: URL?
    var result: RemovalResult?

    @ObservationIgnored private let analyzer = FileAnalyzer()
    @ObservationIgnored private var task: Task<Void, Never>?

    static let periodOptions = [3, 6, 12, 24]
    static let sizeOptions: [Int64] = [10_000_000, 50_000_000, 100_000_000, 500_000_000, 1_000_000_000]

    var minSize: Int64 {
        get { mode == .old ? oldMinSize : largeMinSize }
        set { if mode == .old { oldMinSize = newValue } else { largeMinSize = newValue } }
    }

    var activeRoots: [URL] { roots.filter { !disabledRoots.contains($0) } }

    // MARK: Derived

    var totalSize: Int64 { files.reduce(0) { $0 + $1.item.size } }

    var kinds: [(kind: FileKind, count: Int, size: Int64)] {
        FileKind.allCases.compactMap { kind in
            let f = files.filter { $0.kind == kind }
            return f.isEmpty ? nil : (kind, f.count, f.reduce(0) { $0 + $1.item.size })
        }
        .sorted { $0.size > $1.size }
    }

    var visibleFiles: [AnalyzedFile] {
        var list = kindFilter.map { k in files.filter { $0.kind == k } } ?? files
        switch sort {
        case .size: list.sort { $0.item.size > $1.item.size }
        case .date: list.sort { ($0.item.lastUsed ?? $0.item.modified ?? .distantPast) < ($1.item.lastUsed ?? $1.item.modified ?? .distantPast) }
        case .name: list.sort { $0.item.name.localizedCaseInsensitiveCompare($1.item.name) == .orderedAscending }
        }
        return list
    }

    var selectedFiles: [AnalyzedFile] { files.filter { selection.contains($0.id) } }
    var selectedSize: Int64 { selectedFiles.reduce(0) { $0 + $1.item.size } }

    // MARK: Scan

    func startScan() {
        app?.storage.noteUserScan()
        task?.cancel()
        task = Task { await scan() }
    }

    func scan() async {
        let scanMode = mode
        withAnimation(Theme.spring) { phase = .scanning }
        progress = ScanProgress(phase: "Подготовка", fraction: 0)
        let relay = progressRelay { [weak self] p in
            guard let self, self.phase == .scanning else { return }
            self.progress = p
        }
        let found: [AnalyzedFile]
        switch scanMode {
        case .old:
            let options = OldFilesOptions(roots: activeRoots, unusedForDays: months * 30, minSize: oldMinSize)
            found = await analyzer.oldFiles(options, progress: relay)
        case .large:
            found = await analyzer.largeFiles(roots: activeRoots, minSize: largeMinSize, progress: relay)
        }
        guard !Task.isCancelled, phase == .scanning else { return }
        apply(found, mode: scanMode)
    }

    func apply(_ found: [AnalyzedFile], mode scanMode: Mode) {
        files = found
        resultMode = scanMode
        selection = []
        kindFilter = nil
        withAnimation(Theme.spring) { phase = .results }
    }

    func stop() {
        task?.cancel()
        withAnimation(Theme.spring) { phase = files.isEmpty ? .idle : .results }
    }

    func newScan() {
        withAnimation(Theme.spring) { phase = .idle }
    }

    func toggle(_ f: AnalyzedFile) {
        if selection.contains(f.id) { selection.remove(f.id) } else { selection.insert(f.id) }
    }

    func toggleRoot(_ url: URL) {
        if disabledRoots.contains(url) { disabledRoots.remove(url) } else { disabledRoots.insert(url) }
    }

    func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Добавить"
        if panel.runModal() == .OK {
            for url in panel.urls where !roots.contains(url) { roots.append(url) }
        }
    }

    // MARK: Remove

    func requestTrash() {
        let picked = selectedFiles
        guard let app, !picked.isEmpty else { return }
        app.ask(Confirmation(
            title: "Переместить в Корзину?",
            message: "Выбранные файлы будут перемещены в Корзину — их можно вернуть, пока Корзина не очищена.",
            count: picked.count,
            bytes: picked.reduce(0) { $0 + $1.item.size },
            confirmTitle: "Переместить в Корзину",
            tint: .oldFiles,
            action: { [weak self] in self?.startTrash(picked) }
        ))
    }

    private func startTrash(_ picked: [AnalyzedFile]) {
        task = Task {
            withAnimation(Theme.spring) { phase = .cleaning }
            let r = await app?.runCleaning(Self.plan(picked)) ?? RemovalResult()
            result = r
            app?.didRemove(r)
            withAnimation(Theme.spring) { phase = .done }
        }
    }

    /// One stage per kind (largest first), one Trash call per file so «Остановить» works between files.
    static func plan(_ picked: [AnalyzedFile]) -> CleaningPlan {
        var plan = CleaningPlan(title: "Удаление старых и больших файлов", module: .oldFiles)
        let sizes = CleaningPrep.sizes(picked.map { ($0.item.url, $0.item.size) })
        let urls = CleaningPrep.dedupe(picked.map(\.item.url))
        let kept = Set(urls.map(\.path))
        let unique = picked.filter { kept.contains($0.item.url.standardizedFileURL.path) }
        let kinds = FileKind.allCases.map { kind in (kind, unique.filter { $0.kind == kind }) }
            .filter { !$0.1.isEmpty }
            .sorted { $0.1.reduce(0) { $0 + $1.item.size } > $1.1.reduce(0) { $0 + $1.item.size } }
        for (kind, files) in kinds {
            plan.addStage(kind.title, symbol: kind.symbol, items: files.map { ($0.item.url, $0.item.size) })
            plan.addTrashUnits(files.map { $0.item.url.standardizedFileURL }, knownSizes: sizes)
        }
        return plan
    }

    func forget(_ removed: Set<URL>) {
        files.removeAll { removed.contains($0.id.standardizedFileURL) }
        selection.subtract(removed)
    }

    func finish() {
        result = nil
        withAnimation(Theme.spring) { phase = files.isEmpty ? .idle : .results }
    }
}
