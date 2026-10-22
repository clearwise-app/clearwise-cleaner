import SwiftUI
import CleanerKit
import SpaceEngine

/// Byte-identical copies of one file. `id` is the first path at scan time and never changes.
struct DuplicateGroup: Identifiable, Hashable {
    let id: URL
    var files: [AnalyzedFile] { didSet { oldestID = DuplicateRules.byAge(files).first?.id } }
    /// Oldest by modification date, stored: rows ask for it on every body and must not re-sort the group.
    private(set) var oldestID: URL?

    init(id: URL, files: [AnalyzedFile]) {
        self.id = id
        self.files = files
        self.oldestID = DuplicateRules.byAge(files).first?.id
    }

    var kind: FileKind { files.first?.kind ?? .other }
    var name: String { files.first?.item.name ?? "" }
    /// Size of one copy (allocated sizes of identical files can differ by a block; take the largest).
    var copySize: Int64 { files.map(\.item.size).max() ?? 0 }
    /// Everything except one copy.
    var reclaimable: Int64 { copySize * Int64(max(0, files.count - 1)) }
    var extraCopies: Int { max(0, files.count - 1) }
}

/// Which copy stays by default. Pure, so it is easy to reason about.
enum DuplicateRules {
    static var downloads: URL { SafetyGuard.home.appendingPathComponent("Downloads") }

    static func byAge(_ files: [AnalyzedFile]) -> [AnalyzedFile] {
        files.enumerated().sorted { a, b in
            let da = a.element.item.modified ?? .distantFuture
            let db = b.element.item.modified ?? .distantFuture
            return da != db ? da < db : a.offset < b.offset
        }.map(\.element)
    }

    static func isInside(_ url: URL, _ dir: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path + "/")
    }

    /// The oldest copy — unless it sits in ~/Downloads and another copy lives elsewhere:
    /// then the oldest copy outside Downloads (the one the user has filed away) stays.
    static func defaultKeep(_ files: [AnalyzedFile], downloads: URL = downloads) -> URL? {
        let ordered = byAge(files)
        guard let oldest = ordered.first else { return nil }
        if isInside(oldest.id, downloads), let outside = ordered.first(where: { !isInside($0.id, downloads) }) {
            return outside.id
        }
        return oldest.id
    }
}

@MainActor @Observable
final class DuplicatesModel {
    @ObservationIgnored weak var app: AppModel?

    enum Sort: Hashable { case size, name }

    var minSize: Int64 = 1_000_000
    var roots: [URL] = FileAnalyzer.defaultRoots
    var disabledRoots: Set<URL> = []

    var phase: ModulePhase = .idle
    var progress = ScanProgress(phase: "", fraction: 0)
    var groups: [DuplicateGroup] = [] {
        didSet { groupsGeneration &+= 1; recountFiles() }
    }
    /// Copies that will go to the Trash. Invariant: never every copy of a group.
    /// Mutated only through `mark`/`unmark`/`clearSelection`, which keep the counters below current.
    private(set) var marked: Set<URL> = []
    /// Size and number of the marked copies, kept in step with `marked` (never recomputed per body).
    private(set) var markedBytes: Int64 = 0
    private(set) var markedCount = 0
    /// All copies in all groups.
    private(set) var fileCount = 0
    private(set) var fileBytes: Int64 = 0
    var kindFilter: FileKind?
    var sort: Sort = .size
    var quickLookURL: URL?
    var result: RemovalResult?
    /// Group that just refused to lose its last copy — shows «Одна копия всегда остаётся».
    var ruleHint: URL?

    @ObservationIgnored private let analyzer = FileAnalyzer()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var hintTask: Task<Void, Never>?
    /// Bumped whenever `groups` changes; with `kindFilter` and `sort` it keys the visible-list cache.
    @ObservationIgnored private var groupsGeneration = 0
    @ObservationIgnored private var sizeByID: [URL: Int64] = [:]
    @ObservationIgnored private var visibleCache: (key: VisibleKey, groups: [DuplicateGroup], urls: [URL])?

    private struct VisibleKey: Equatable {
        var generation: Int
        var kind: FileKind?
        var sort: Sort
    }

    static let sizeOptions: [Int64] = [1_000_000, 10_000_000, 100_000_000]

    var activeRoots: [URL] { roots.filter { !disabledRoots.contains($0) } }

    // MARK: Derived

    var reclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable } }
    var extraCopies: Int { groups.reduce(0) { $0 + $1.extraCopies } }

    var kinds: [(kind: FileKind, groups: Int, size: Int64)] {
        FileKind.allCases.compactMap { kind in
            let g = groups.filter { $0.kind == kind }
            return g.isEmpty ? nil : (kind, g.count, g.reduce(0) { $0 + $1.reclaimable })
        }
        .sorted { $0.size > $1.size }
    }

    /// Filtered and sorted once per change of `groups`, `kindFilter` or `sort`, not once per body.
    var visibleGroups: [DuplicateGroup] { visible().groups }
    /// URLs of every copy in `visibleGroups`, in the same order (Quick Look).
    var visibleURLs: [URL] { visible().urls }

    private func visible() -> (groups: [DuplicateGroup], urls: [URL]) {
        let key = VisibleKey(generation: groupsGeneration, kind: kindFilter, sort: sort)
        if let c = visibleCache, c.key == key { return (c.groups, c.urls) }
        var list = key.kind.map { k in groups.filter { $0.kind == k } } ?? groups
        switch key.sort {
        case .size: list.sort { $0.reclaimable != $1.reclaimable ? $0.reclaimable > $1.reclaimable : $0.name < $1.name }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        let urls = list.flatMap { $0.files.map(\.item.url) }
        visibleCache = (key, list, urls)
        return (list, urls)
    }

    /// For the snapshot driver and the cleaning plan; the footer reads the counters instead.
    var markedFiles: [AnalyzedFile] { groups.flatMap { $0.files.filter { marked.contains($0.id) } } }
    var markedSize: Int64 { markedBytes }
    var keptCount: Int { fileCount - markedCount }
    var keptSize: Int64 { fileBytes - markedBytes }

    func markedSize(in group: DuplicateGroup) -> Int64 {
        group.files.reduce(0) { marked.contains($1.id) ? $0 + $1.item.size : $0 }
    }

    func isMarked(_ file: AnalyzedFile) -> Bool { marked.contains(file.id) }

    /// Copies of the group that stay on disk.
    func kept(in group: DuplicateGroup) -> [AnalyzedFile] { group.files.filter { !marked.contains($0.id) } }

    // MARK: Marked counters

    private func recountFiles() {
        var bytes: Int64 = 0
        var count = 0
        var sizes: [URL: Int64] = [:]
        for g in groups {
            for f in g.files {
                bytes += f.item.size
                count += 1
                sizes[f.id] = f.item.size
            }
        }
        fileBytes = bytes
        fileCount = count
        sizeByID = sizes
    }

    private func mark(_ id: URL) {
        if marked.insert(id).inserted {
            markedCount += 1
            markedBytes += sizeByID[id] ?? 0
        }
    }

    private func unmark(_ id: URL) {
        if marked.remove(id) != nil {
            markedCount -= 1
            markedBytes -= sizeByID[id] ?? 0
        }
    }

    /// Rebuilds the counters from scratch (after groups changed under the selection).
    private func recountMarked() {
        markedCount = marked.count
        markedBytes = marked.reduce(0) { $0 + (sizeByID[$1] ?? 0) }
    }

    // MARK: Scan

    func startScan() {
        app?.storage.noteUserScan()
        task?.cancel()
        task = Task { await scan() }
    }

    func scan() async {
        withAnimation(Theme.spring) { phase = .scanning }
        progress = ScanProgress(phase: String(localized: "Подготовка"), fraction: 0)
        let started = Date()
        let scanRoots = activeRoots
        let relay = progressRelay { [weak self] p in
            guard let self, self.phase == .scanning else { return }
            self.progress = Self.display(p, roots: scanRoots, started: started, previous: self.progress.fraction)
        }
        let found = await analyzer.duplicates(roots: scanRoots, minSize: minSize, progress: relay)
        guard !Task.isCancelled, phase == .scanning else { return }
        apply(found)
    }

    /// The engine walks first (0 → 0.2, one step per folder), then hashes (0.2 → 1). Give both stages a
    /// readable label; during the walk the ring also creeps towards 18 % so a single big folder never looks frozen.
    private static func display(_ p: ScanProgress, roots: [URL], started: Date, previous: Double) -> ScanProgress {
        if p.fraction >= 1 { return ScanProgress(phase: String(localized: "Готово"), fraction: 1) }
        if p.fraction < 0.2 {
            let creep = 0.18 * (1 - exp(-Date().timeIntervalSince(started) / 25))
            let root = p.currentPath.flatMap { path in roots.first { path.hasPrefix($0.path + "/") } }
            let phase = root.map { String(localized: "Ищем файлы — \(Fmt.folderTitle($0))") } ?? String(localized: "Ищем файлы")
            return ScanProgress(phase: phase, fraction: max(previous, creep, p.fraction), currentPath: p.currentPath)
        }
        return ScanProgress(phase: String(localized: "Сравниваем содержимое файлов"), fraction: max(previous, p.fraction), currentPath: p.currentPath)
    }

    func apply(_ found: [[AnalyzedFile]]) {
        groups = found.filter { $0.count > 1 }.compactMap { files in
            files.first.map { DuplicateGroup(id: $0.id, files: files) }
        }
        kindFilter = nil
        resetToDefault()
        withAnimation(Theme.spring) { phase = .results }
    }

    func stop() {
        task?.cancel()
        withAnimation(Theme.spring) { phase = groups.isEmpty ? .idle : .results }
    }

    func newScan() {
        withAnimation(Theme.spring) { phase = .idle }
    }

    func toggleRoot(_ url: URL) {
        if disabledRoots.contains(url) { disabledRoots.remove(url) } else { disabledRoots.insert(url) }
    }

    func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Добавить")
        if panel.runModal() == .OK {
            for url in panel.urls where !roots.contains(url) { roots.append(url) }
        }
    }

    // MARK: Keep / remove

    /// Marks a copy for the Trash, or keeps it. Refuses to mark the last kept copy of a group.
    func setRemove(_ remove: Bool, _ file: AnalyzedFile, in group: DuplicateGroup) {
        if remove {
            let othersKept = group.files.contains { $0.id != file.id && !marked.contains($0.id) }
            guard othersKept else { flashRule(group); return }
            mark(file.id)
        } else {
            unmark(file.id)
        }
    }

    /// This copy stays, every other copy of the group goes to the Trash.
    func keepOnly(_ file: AnalyzedFile, in group: DuplicateGroup) {
        for f in group.files { if f.id == file.id { unmark(f.id) } else { mark(f.id) } }
    }

    /// Every copy except one per group. A copy the user already chose to keep wins over the default.
    func selectAllDuplicates() {
        for g in groups {
            let kept = g.files.filter { !marked.contains($0.id) }.map(\.id)
            let def = DuplicateRules.defaultKeep(g.files)
            let keep = kept.contains(where: { $0 == def }) ? def : (kept.first ?? def)
            for f in g.files { if f.id == keep { unmark(f.id) } else { mark(f.id) } }
        }
    }

    func clearSelection() {
        marked = []
        markedCount = 0
        markedBytes = 0
    }

    func resetToDefault() {
        clearSelection()
        for g in groups {
            let keep = DuplicateRules.defaultKeep(g.files)
            for f in g.files where f.id != keep { mark(f.id) }
        }
    }

    /// Restores the invariant after anything external changed the groups.
    private func normalize() {
        let all = Set(groups.flatMap { $0.files.map(\.id) })
        marked.formIntersection(all)
        recountMarked()
        for g in groups where g.files.allSatisfy({ marked.contains($0.id) }) {
            if let keep = DuplicateRules.defaultKeep(g.files) { unmark(keep) }
        }
    }

    private func flashRule(_ group: DuplicateGroup) {
        withAnimation(Theme.quick) { ruleHint = group.id }
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(Theme.spring) { self?.ruleHint = nil }
        }
    }

    // MARK: Remove

    /// What will actually be trashed: never the last copy, even if the selection were somehow inconsistent.
    private var safePicked: [AnalyzedFile] {
        groups.flatMap { g -> [AnalyzedFile] in
            let picked = g.files.filter { marked.contains($0.id) }
            guard picked.count == g.files.count else { return picked }
            let keep = DuplicateRules.defaultKeep(g.files)
            return picked.filter { $0.id != keep }
        }
    }

    func requestTrash() {
        let picked = safePicked
        guard let app, !picked.isEmpty else { return }
        app.ask(.make(.trash,
                      message: String(localized: "Лишние копии попадут в Корзину, в каждой группе останется хотя бы одна. Их можно вернуть, пока Корзина не очищена."),
                      count: picked.count, bytes: picked.reduce(0) { $0 + $1.item.size },
                      noun: .copies, tint: .duplicates) { [weak self] in self?.startTrash(picked) })
    }

    /// «Повторить» on the completion screen: the copies that stayed (they are still listed and marked) go again.
    func retryFailed() {
        let failed = Set((result?.failed ?? []).map { $0.url.standardizedFileURL })
        let again = safePicked.filter { failed.contains($0.id.standardizedFileURL) }
        guard !again.isEmpty else { return }
        startTrash(again)
    }

    private func startTrash(_ picked: [AnalyzedFile]) {
        let pickedIDs = Set(picked.map(\.id))
        let plan = groups.map { g in (g, g.files.filter { pickedIDs.contains($0.id) }, g.files.filter { !pickedIDs.contains($0.id) }) }
        // The cleaning scene covers the screen while this runs; the module stays on its results underneath.
        task?.cancel()
        task = Task {
            // A copy we keep must still be on disk right now; otherwise trashing the rest could lose the file.
            var skipped: [RemovalFailure] = []
            var urls: [URL] = []
            for (_, remove, keep) in plan where !remove.isEmpty {
                if keep.contains(where: { FileManager.default.fileExists(atPath: $0.item.url.path) }) {
                    urls += remove.map(\.item.url)
                } else {
                    skipped += remove.map { RemovalFailure(url: $0.item.url, reason: String(localized: "Оставляемая копия не найдена на диске — группа пропущена")) }
                }
            }
            // Nothing to clean: the confirmed «навсегда» must not carry over to a later cleanup.
            if urls.isEmpty { app?.deletePermanentlyOnce = false }
            var r = urls.isEmpty ? RemovalResult() : (await app?.runCleaning(Self.plan(picked, urls: urls)) ?? RemovalResult())
            r.failed += skipped
            result = r
            // `.done` first: `didRemove` updates other models, and a phase set after it can be lost.
            withAnimation(Theme.spring) { phase = .done }
            app?.didRemove(r)
        }
    }

    /// One stage per kind of file (largest first); Trash calls go in chunks, so «Остановить» works between chunks.
    static func plan(_ picked: [AnalyzedFile], urls: [URL]) -> CleaningPlan {
        var plan = CleaningPlan(title: String(localized: "Удаление дубликатов"), module: .duplicates)
        let sizes = CleaningPrep.sizes(picked.map { ($0.item.url, $0.item.size) })
        let kindOf = Dictionary(picked.map { ($0.item.url.standardizedFileURL.path, $0.kind) }, uniquingKeysWith: { a, _ in a })
        let unique = CleaningPrep.dedupe(urls)
        let kinds = FileKind.allCases.map { kind in (kind, unique.filter { kindOf[$0.path] == kind }) }
            .filter { !$0.1.isEmpty }
            .sorted { $0.1.reduce(0) { $0 + (sizes[$1] ?? 0) } > $1.1.reduce(0) { $0 + (sizes[$1] ?? 0) } }
        var staged = Set<String>()
        for (kind, files) in kinds {
            staged.formUnion(files.map(\.path))
            plan.addStage(kind.title, symbol: kind.symbol, items: files.map { ($0, sizes[$0] ?? 0) })
            plan.addTrashUnits(files, knownSizes: sizes)
        }
        let rest = unique.filter { !staged.contains($0.path) }
        if !rest.isEmpty {
            plan.addStage(FileKind.other.title, symbol: FileKind.other.symbol, items: rest.map { ($0, sizes[$0] ?? 0) })
            plan.addTrashUnits(rest, knownSizes: sizes)
        }
        return plan
    }

    func forget(_ removed: Set<URL>) {
        guard !removed.isEmpty else { return }
        // One assignment: `groups` has observers that rebuild the caches.
        var updated = groups
        for i in updated.indices {
            updated[i].files.removeAll { removed.contains($0.id.standardizedFileURL) }
        }
        updated.removeAll { $0.files.count < 2 }
        groups = updated
        normalize()
    }

    func finish() {
        // `result` stays: the completion screen fades out with its numbers (the next cleanup replaces it).
        withAnimation(Theme.spring) { phase = groups.isEmpty ? .idle : .results }
    }
}
