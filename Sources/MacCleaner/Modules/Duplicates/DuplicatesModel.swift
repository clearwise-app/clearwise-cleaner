import SwiftUI
import CleanerKit
import SpaceEngine

/// Byte-identical copies of one file. `id` is the first path at scan time and never changes.
struct DuplicateGroup: Identifiable, Hashable {
    let id: URL
    var files: [AnalyzedFile]

    var kind: FileKind { files.first?.kind ?? .other }
    var name: String { files.first?.item.name ?? "" }
    /// Size of one copy (allocated sizes of identical files can differ by a block; take the largest).
    var copySize: Int64 { files.map(\.item.size).max() ?? 0 }
    /// Everything except one copy.
    var reclaimable: Int64 { copySize * Int64(max(0, files.count - 1)) }
    var extraCopies: Int { max(0, files.count - 1) }
    /// Oldest by modification date (the engine already sorts this way; kept explicit for safety).
    var oldest: URL? { DuplicateRules.byAge(files).first?.id }
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
    var groups: [DuplicateGroup] = []
    /// Copies that will go to the Trash. Invariant: never every copy of a group.
    var marked: Set<URL> = []
    var kindFilter: FileKind?
    var sort: Sort = .size
    var quickLookURL: URL?
    var result: RemovalResult?
    /// Group that just refused to lose its last copy — shows «Одна копия всегда остаётся».
    var ruleHint: URL?

    @ObservationIgnored private let analyzer = FileAnalyzer()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var hintTask: Task<Void, Never>?

    static let sizeOptions: [Int64] = [1_000_000, 10_000_000, 100_000_000]

    var activeRoots: [URL] { roots.filter { !disabledRoots.contains($0) } }

    // MARK: Derived

    var reclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable } }
    var extraCopies: Int { groups.reduce(0) { $0 + $1.extraCopies } }
    var fileCount: Int { groups.reduce(0) { $0 + $1.files.count } }

    var kinds: [(kind: FileKind, groups: Int, size: Int64)] {
        FileKind.allCases.compactMap { kind in
            let g = groups.filter { $0.kind == kind }
            return g.isEmpty ? nil : (kind, g.count, g.reduce(0) { $0 + $1.reclaimable })
        }
        .sorted { $0.size > $1.size }
    }

    var visibleGroups: [DuplicateGroup] {
        var list = kindFilter.map { k in groups.filter { $0.kind == k } } ?? groups
        switch sort {
        case .size: list.sort { $0.reclaimable != $1.reclaimable ? $0.reclaimable > $1.reclaimable : $0.name < $1.name }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return list
    }

    var markedFiles: [AnalyzedFile] { groups.flatMap { $0.files.filter { marked.contains($0.id) } } }
    var markedSize: Int64 { markedFiles.reduce(0) { $0 + $1.item.size } }
    var keptCount: Int { fileCount - markedFiles.count }
    var keptSize: Int64 { groups.reduce(0) { $0 + $1.files.reduce(0) { $0 + $1.item.size } } - markedSize }

    func markedSize(in group: DuplicateGroup) -> Int64 {
        group.files.filter { marked.contains($0.id) }.reduce(0) { $0 + $1.item.size }
    }

    func isMarked(_ file: AnalyzedFile) -> Bool { marked.contains(file.id) }

    // MARK: Scan

    func startScan() {
        app?.storage.noteUserScan()
        task?.cancel()
        task = Task { await scan() }
    }

    func scan() async {
        withAnimation(Theme.spring) { phase = .scanning }
        progress = ScanProgress(phase: "Подготовка", fraction: 0)
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
        if p.fraction >= 1 { return ScanProgress(phase: "Готово", fraction: 1) }
        if p.fraction < 0.2 {
            let creep = 0.18 * (1 - exp(-Date().timeIntervalSince(started) / 25))
            let root = p.currentPath.flatMap { path in roots.first { path.hasPrefix($0.path + "/") } }
            let phase = root.map { "Ищем файлы — \(Fmt.folderTitle($0))" } ?? "Ищем файлы"
            return ScanProgress(phase: phase, fraction: max(previous, creep, p.fraction), currentPath: p.currentPath)
        }
        return ScanProgress(phase: "Сравниваем содержимое файлов", fraction: max(previous, p.fraction), currentPath: p.currentPath)
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
        panel.prompt = "Добавить"
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
            marked.insert(file.id)
        } else {
            marked.remove(file.id)
        }
    }

    /// This copy stays, every other copy of the group goes to the Trash.
    func keepOnly(_ file: AnalyzedFile, in group: DuplicateGroup) {
        for f in group.files { if f.id == file.id { marked.remove(f.id) } else { marked.insert(f.id) } }
    }

    /// Every copy except one per group. A copy the user already chose to keep wins over the default.
    func selectAllDuplicates() {
        for g in groups {
            let kept = g.files.filter { !marked.contains($0.id) }.map(\.id)
            let def = DuplicateRules.defaultKeep(g.files)
            let keep = kept.contains(where: { $0 == def }) ? def : (kept.first ?? def)
            for f in g.files { if f.id == keep { marked.remove(f.id) } else { marked.insert(f.id) } }
        }
    }

    func clearSelection() { marked = [] }

    func resetToDefault() {
        marked = []
        for g in groups {
            let keep = DuplicateRules.defaultKeep(g.files)
            for f in g.files where f.id != keep { marked.insert(f.id) }
        }
    }

    /// Restores the invariant after anything external changed the groups.
    private func normalize() {
        let all = Set(groups.flatMap { $0.files.map(\.id) })
        marked.formIntersection(all)
        for g in groups where g.files.allSatisfy({ marked.contains($0.id) }) {
            if let keep = DuplicateRules.defaultKeep(g.files) { marked.remove(keep) }
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
        app.ask(Confirmation(
            title: "Переместить копии в Корзину?",
            message: "Лишние копии будут перемещены в Корзину, в каждой группе останется хотя бы одна. Их можно вернуть, пока Корзина не очищена.",
            count: picked.count,
            bytes: picked.reduce(0) { $0 + $1.item.size },
            confirmTitle: "Переместить в Корзину",
            tint: .duplicates,
            noun: Fmt.copies,
            action: { [weak self] in self?.startTrash(picked) }
        ))
    }

    private func startTrash(_ picked: [AnalyzedFile]) {
        let pickedIDs = Set(picked.map(\.id))
        let plan = groups.map { g in (g, g.files.filter { pickedIDs.contains($0.id) }, g.files.filter { !pickedIDs.contains($0.id) }) }
        task = Task {
            withAnimation(Theme.spring) { phase = .cleaning }
            // A copy we keep must still be on disk right now; otherwise trashing the rest could lose the file.
            var skipped: [RemovalFailure] = []
            var urls: [URL] = []
            for (_, remove, keep) in plan where !remove.isEmpty {
                if keep.contains(where: { FileManager.default.fileExists(atPath: $0.item.url.path) }) {
                    urls += remove.map(\.item.url)
                } else {
                    skipped += remove.map { RemovalFailure(url: $0.item.url, reason: "Оставляемая копия не найдена на диске — группа пропущена") }
                }
            }
            var r = urls.isEmpty ? RemovalResult() : (await app?.runCleaning(Self.plan(picked, urls: urls)) ?? RemovalResult())
            r.failed += skipped
            result = r
            app?.didRemove(r)
            withAnimation(Theme.spring) { phase = .done }
        }
    }

    /// One stage per kind of file (largest first), one Trash call per copy so «Остановить» works between copies.
    static func plan(_ picked: [AnalyzedFile], urls: [URL]) -> CleaningPlan {
        var plan = CleaningPlan(title: "Удаление дубликатов", module: .duplicates)
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
        for i in groups.indices {
            groups[i].files.removeAll { removed.contains($0.id.standardizedFileURL) }
        }
        groups.removeAll { $0.files.count < 2 }
        normalize()
    }

    func finish() {
        result = nil
        withAnimation(Theme.spring) { phase = groups.isEmpty ? .idle : .results }
    }
}
