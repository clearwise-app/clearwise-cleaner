import SwiftUI
import CleanerKit
import JunkEngine

@MainActor @Observable
final class JunkModel {
    @ObservationIgnored weak var app: AppModel?

    var phase: ModulePhase = .idle
    var progress = ScanProgress(phase: "", fraction: 0)
    var categories: [JunkCategory] = []
    var selection: Set<URL> = []
    var expanded: Set<String> = []
    /// Friendlier labels from the scanner ("Google Chrome · Default · GPUCache", iPhone name…).
    var notes: [URL: String] = [:]
    var result: RemovalResult?
    /// The last clean emptied the Trash (permanent).
    var resultWasPermanent = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let scanner = JunkScanner()

    // MARK: Derived

    var totalSize: Int64 { categories.reduce(0) { $0 + $1.totalSize } }
    var itemCount: Int { categories.reduce(0) { $0 + $1.items.count } }

    /// Selection totals are kept per category and updated where the selection changes (toggle, select*, apply,
    /// forget), so a body never walks every item to learn «Выбрано 12 ГБ · 342 объекта».
    private(set) var selectedBytesByCategory: [String: Int64] = [:]
    private(set) var selectedCountByCategory: [String: Int] = [:]
    private(set) var selectedSize: Int64 = 0
    private(set) var selectedCount = 0

    func selectedSize(in cat: JunkCategory) -> Int64 { selectedBytesByCategory[cat.id] ?? 0 }

    func state(of cat: JunkCategory) -> CheckState {
        CheckState(selected: selectedCountByCategory[cat.id] ?? 0, total: cat.items.count)
    }

    /// Selected items grouped by category. Walks every item: for building cleaning plans only, never from a body.
    var selectedPairs: [(JunkCategory, [FileItem])] {
        categories.compactMap { cat in
            let items = cat.items.filter { selection.contains($0.url) }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    /// Recounts from `selection`: after bulk changes (apply, select*, forget), O(items) once per change.
    private func rebuildTotals() {
        var bytes: [String: Int64] = [:]
        var counts: [String: Int] = [:]
        var totalBytes: Int64 = 0
        var totalCount = 0
        if !selection.isEmpty {
            for cat in categories {
                var b: Int64 = 0
                var c = 0
                for item in cat.items where selection.contains(item.url) {
                    b += item.size
                    c += 1
                }
                if c > 0 {
                    bytes[cat.id] = b
                    counts[cat.id] = c
                    totalBytes += b
                    totalCount += c
                }
            }
        }
        selectedBytesByCategory = bytes
        selectedCountByCategory = counts
        selectedSize = totalBytes
        selectedCount = totalCount
    }

    private func adjustTotals(_ id: String, bytes: Int64, count: Int) {
        let newBytes = (selectedBytesByCategory[id] ?? 0) + bytes
        let newCount = (selectedCountByCategory[id] ?? 0) + count
        selectedBytesByCategory[id] = newCount > 0 ? newBytes : nil
        selectedCountByCategory[id] = newCount > 0 ? newCount : nil
        selectedSize += bytes
        selectedCount += count
    }

    // MARK: Scan

    func startScan() {
        app?.storage.noteUserScan()
        task?.cancel()
        task = Task { await scan() }
    }

    func scan() async {
        withAnimation(Theme.spring) { phase = .scanning }
        progress = ScanProgress(phase: "Подготовка", fraction: 0)
        let relay = progressRelay { [weak self] p in
            guard let self, self.phase == .scanning else { return }
            self.progress = p
        }
        let found = await scanner.scan(progress: relay)
        notes = await scanner.notes
        guard !Task.isCancelled, phase == .scanning else { return }
        apply(found)
    }

    func stop() {
        task?.cancel()
        withAnimation(Theme.spring) { phase = categories.isEmpty ? .idle : .results }
    }

    func apply(_ found: [JunkCategory]) {
        categories = found.filter { !$0.items.isEmpty }.sorted { $0.totalSize > $1.totalSize }
        selection = Set(categories.filter(\.isSelectedByDefault).flatMap { $0.items.map(\.url) })
        expanded = []
        rebuildTotals()
        withAnimation(Theme.spring) { phase = .results }
    }

    // MARK: Selection

    func toggle(_ cat: JunkCategory) {
        let urls = cat.items.map(\.url)
        if state(of: cat) == .on {
            selection.subtract(urls)
            adjustTotals(cat.id, bytes: -(selectedBytesByCategory[cat.id] ?? 0), count: -(selectedCountByCategory[cat.id] ?? 0))
        } else {
            selection.formUnion(urls)
            adjustTotals(cat.id, bytes: cat.totalSize - (selectedBytesByCategory[cat.id] ?? 0),
                         count: cat.items.count - (selectedCountByCategory[cat.id] ?? 0))
        }
    }

    func toggle(_ item: FileItem, in cat: JunkCategory) {
        if selection.remove(item.url) != nil {
            adjustTotals(cat.id, bytes: -item.size, count: -1)
        } else {
            selection.insert(item.url)
            adjustTotals(cat.id, bytes: item.size, count: 1)
        }
    }

    /// Back to the selection right after the scan.
    func selectDefaults() {
        selection = Set(categories.filter(\.isSelectedByDefault).flatMap { $0.items.map(\.url) })
        rebuildTotals()
    }

    func selectNone() {
        selection = []
        rebuildTotals()
    }

    /// «Повторить»: selects exactly what the last clean could not remove.
    func selectFailed(from result: RemovalResult) {
        let failed = Set(result.failed.map { $0.url.standardizedFileURL })
        selection = Set(categories.flatMap(\.items).map(\.url).filter { failed.contains($0.standardizedFileURL) })
        rebuildTotals()
    }

    func toggleExpanded(_ cat: JunkCategory) {
        withAnimation(Theme.spring) {
            if expanded.contains(cat.id) { expanded.remove(cat.id) } else { expanded.insert(cat.id) }
        }
    }

    // MARK: Clean

    var includesTrash: Bool { (selectedCountByCategory[JunkCategoryID.trash] ?? 0) > 0 }
    var includesSystemLogs: Bool { (selectedCountByCategory[JunkCategoryID.systemLogs] ?? 0) > 0 }

    /// Round button / confirm verb: «Очистить», or «Удалить навсегда» when the Trash is part of the selection.
    var cleanVerb: ConfirmCopy.Verb { includesTrash ? .deleteForever : .clean }

    /// The selected bytes of the Trash category (emptied for good, unlike the rest).
    var selectedTrashBytes: Int64 { selectedBytesByCategory[JunkCategoryID.trash] ?? 0 }

    func confirmation(tint: ModuleTint, action: @escaping @MainActor () -> Void) -> Confirmation? {
        guard selectedCount > 0 else { return nil }
        return Self.cleanConfirmation(count: selectedCount, bytes: selectedSize, trashBytes: selectedTrashBytes,
                                      needsAdmin: includesSystemLogs, tint: tint, action: action)
    }

    /// «Очистить N объектов?» — everything goes to the Trash, except the Trash's own content (`trashBytes`), which
    /// is deleted for good. Smart Care uses it for junk, leftovers and old files together.
    static func cleanConfirmation(count: Int, bytes: Int64, trashBytes: Int64, needsAdmin: Bool, tint: ModuleTint,
                                  action: @escaping @MainActor () -> Void) -> Confirmation {
        let includesTrash = trashBytes > 0
        let onlyTrash = includesTrash && trashBytes == bytes
        var title: String?
        var message: String?
        if includesTrash && !onlyTrash {
            title = "Очистить \(ConfirmCopy.accusative(count, .items))?"
            message = "Остальное попадёт в Корзину — это можно вернуть. Содержимое самой Корзины (\(Fmt.size(trashBytes))) будет удалено навсегда."
        } else if !includesTrash {
            title = "Очистить \(ConfirmCopy.accusative(count, .items))?"
            message = "Всё попадёт в Корзину — это можно вернуть, пока Корзина не очищена."
        }
        return .make(includesTrash ? .deleteForever : .clean, title: title, message: message, count: count, bytes: bytes,
                     needsAdmin: needsAdmin, tint: tint, action: action)
    }

    func requestClean() {
        guard let app, let confirmation = confirmation(tint: .junk, action: { [weak self] in self?.startClean() }) else { return }
        app.ask(confirmation)
    }

    /// «Повторить» on the completion screen: back to the results with the refused items selected, and ask again.
    func retryFailed() {
        guard let result else { return }
        selectFailed(from: result)
        finish()
        requestClean()
    }

    func startClean() {
        task = Task { await clean() }
    }

    /// Runs the selected categories through the full-screen cleaning scene (Smart Care reuses it with its own look).
    /// `onDone` runs after `.done` is set and before the results are dropped elsewhere (Smart Care sets its own `.done` there).
    func clean(title: String = "Очистка системного мусора", module: AppModule = .junk,
               onDone: (() -> Void)? = nil) async {
        let pairs = selectedPairs
        resultWasPermanent = pairs.count == 1 && pairs[0].0.id == JunkCategoryID.trash
        withAnimation(Theme.spring) { phase = .cleaning }
        let plan = Self.plan(pairs, title: title, module: module)
        let total = await app?.runCleaning(plan) ?? RemovalResult()
        result = total
        // `.done` before `didRemove`: dropping the removed items re-renders the screens mid-update,
        // and a phase change made after that was lost (the completion screen never appeared).
        withAnimation(Theme.spring) { phase = .done }
        onDone?()
        app?.didRemove(total)
    }

    /// One stage per category, in the order shown; items go to the engine in chunks, so «Остановить» works between chunks.
    /// Root-owned system logs stay in a single call: one administrator prompt, as before.
    static func plan(_ pairs: [(JunkCategory, [FileItem])], title: String, module: AppModule) -> CleaningPlan {
        var plan = CleaningPlan(title: title, module: module)
        for (cat, items) in pairs {
            // JunkCleaner dedupes nested items per call; splitting the call must not change that.
            let keep = Set(CleaningPrep.dedupe(items.map(\.url)).map(\.path))
            let unique = items.filter { keep.contains($0.url.standardizedFileURL.path) }
            var userOwned = unique
            var rootOwned: [FileItem] = []
            if cat.id == JunkCategoryID.systemLogs {
                userOwned = unique.filter { FileManager.default.isDeletableFile(atPath: $0.url.path) }
                rootOwned = unique.filter { !FileManager.default.isDeletableFile(atPath: $0.url.path) }
            }
            plan.addStage(cat.title, symbol: cat.symbol, items: unique.map { ($0.url, $0.size) },
                          admin: Set(rootOwned.map(\.url)))
            plan.addChunks(userOwned) { chunk, progress in
                await JunkCleaner.clean(chunk, in: cat, progress: progress)
            }
            if !rootOwned.isEmpty {
                plan.addUnit { progress in await JunkCleaner.clean(rootOwned, in: cat, progress: progress) }
            }
        }
        return plan
    }

    /// Drops removed items from the results (after cleaning here or elsewhere). Does nothing, and notifies
    /// nobody, when none of them is listed here.
    func forget(_ removed: Set<URL>) {
        guard !categories.isEmpty, !removed.isEmpty else { return }
        var changed = false
        var next: [JunkCategory] = []
        next.reserveCapacity(categories.count)
        for cat in categories {
            let kept = cat.items.filter { !removed.contains($0.url.standardizedFileURL) }
            if kept.count == cat.items.count {
                next.append(cat)
                continue
            }
            changed = true
            if !kept.isEmpty {
                var c = cat
                c.items = kept
                next.append(c)
            }
        }
        guard changed else { return }
        categories = next
        selection = selection.filter { !removed.contains($0.standardizedFileURL) }
        rebuildTotals()
    }

    func finish() {
        // `result` stays: the completion screen fades out with its numbers (the next cleanup replaces it).
        withAnimation(Theme.spring) { phase = categories.isEmpty ? .idle : .results }
    }
}
