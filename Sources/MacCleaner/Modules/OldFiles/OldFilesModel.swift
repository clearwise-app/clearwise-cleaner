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
    var files: [AnalyzedFile] = [] {
        didSet { filesGeneration &+= 1; sizeByID = Dictionary(files.map { ($0.id, $0.item.size) }, uniquingKeysWith: { a, _ in a }) }
    }
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
    /// Bumped whenever `files` changes; with `kindFilter` and `sort` it keys the visible-list cache.
    @ObservationIgnored private var filesGeneration = 0
    @ObservationIgnored private var sizeByID: [URL: Int64] = [:]
    @ObservationIgnored private var visibleCache: (key: VisibleKey, files: [AnalyzedFile], urls: [URL])?

    private struct VisibleKey: Equatable {
        var generation: Int
        var kind: FileKind?
        var sort: Sort
    }

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

    /// Filtered and sorted once per change of `files`, `kindFilter` or `sort`, not once per body.
    var visibleFiles: [AnalyzedFile] { visible().files }
    /// URLs of `visibleFiles`, in the same order (Quick Look).
    var visibleURLs: [URL] { visible().urls }

    private func visible() -> (files: [AnalyzedFile], urls: [URL]) {
        let key = VisibleKey(generation: filesGeneration, kind: kindFilter, sort: sort)
        if let c = visibleCache, c.key == key { return (c.files, c.urls) }
        var list = key.kind.map { k in files.filter { $0.kind == k } } ?? files
        switch key.sort {
        case .size: list.sort { $0.item.size > $1.item.size }
        case .date: list.sort { ($0.item.lastUsed ?? $0.item.modified ?? .distantPast) < ($1.item.lastUsed ?? $1.item.modified ?? .distantPast) }
        case .name: list.sort { $0.item.name.localizedCaseInsensitiveCompare($1.item.name) == .orderedAscending }
        }
        let urls = list.map(\.item.url)
        visibleCache = (key, list, urls)
        return (list, urls)
    }

    var selectedFiles: [AnalyzedFile] { files.filter { selection.contains($0.id) } }
    /// Sum over the selection only (not over every file).
    var selectedSize: Int64 { selection.reduce(0) { $0 + (sizeByID[$1] ?? 0) } }

    /// How many of the listed files are selected, for the header checkbox.
    func selectedCount(in list: [AnalyzedFile]) -> Int {
        list.reduce(0) { selection.contains($1.id) ? $0 + 1 : $0 }
    }

    /// Header checkbox: select everything listed, or clear it when it is all selected already.
    func toggleAll(in list: [AnalyzedFile]) {
        let ids = list.map(\.id)
        if ids.allSatisfy(selection.contains) { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

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

    /// «Повторить» in Smart Care: exactly the files the last clean could not move.
    func selectFailed(from result: RemovalResult) {
        let failed = Set(result.failed.map { $0.url.standardizedFileURL })
        selection = Set(files.map(\.id).filter { failed.contains($0.standardizedFileURL) })
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
        app.ask(.make(.trash, count: picked.count, bytes: picked.reduce(0) { $0 + $1.item.size },
                      noun: .files, tint: .oldFiles) { [weak self] in self?.startTrash(picked) })
    }

    /// «Повторить» on the completion screen: the files that stayed (they are still listed) go again.
    func retryFailed() {
        let failed = Set((result?.failed ?? []).map { $0.url.standardizedFileURL })
        let again = files.filter { failed.contains($0.id.standardizedFileURL) }
        guard !again.isEmpty else { return }
        startTrash(again)
    }

    /// The cleaning scene covers the screen while this runs, so the module stays on its results underneath.
    private func startTrash(_ picked: [AnalyzedFile]) {
        task?.cancel()
        task = Task {
            let r = await app?.runCleaning(Self.plan(picked)) ?? RemovalResult()
            result = r
            // `.done` first: `didRemove` updates other models, and a phase set after it can be lost.
            withAnimation(Theme.spring) { phase = .done }
            app?.didRemove(r)
        }
    }

    /// One stage per kind (largest first); Trash calls go in chunks, so «Остановить» works between chunks.
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
        // `result` stays: the completion screen fades out with its numbers (the next cleanup replaces it).
        withAnimation(Theme.spring) { phase = files.isEmpty ? .idle : .results }
    }
}
