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
    /// Whether the scan could ask Docker; «not running» gets a hint under the list.
    var dockerStatus: DockerStatus = .absent
    /// Which categories a scan ticks. Changing it re-ticks the list; hand-made ticks are then replaced.
    var mode: CleanupMode = .gentle
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

    /// The category's box counts the items a mode may tick: the newest backup of each device (`neverAuto`)
    /// is ticked only by hand, row by row — so the box is «on» once everything else is.
    func state(of cat: JunkCategory) -> CheckState {
        let selected = selectedCountByCategory[cat.id] ?? 0
        let auto = cat.items.count - cat.neverAuto.count
        if selected == 0 { return .off }
        return auto > 0 && selected >= auto ? .on : .mixed
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

    /// Also Smart Care's junk scan, so the saved mode is loaded here, not in `startScan`.
    func scan() async {
        // Settings may have changed it since the last scan; snapshots and tests stay gentle.
        if app?.probesSystem ?? false { mode = .saved }
        withAnimation(Theme.spring) { phase = .scanning }
        progress = ScanProgress(phase: String(localized: "Подготовка"), fraction: 0)
        let relay = progressRelay { [weak self] p in
            guard let self, self.phase == .scanning else { return }
            self.progress = p
        }
        let found = await scanner.scan(progress: relay)
        // A stopped scan finishing late must not relabel the live results either.
        guard !Task.isCancelled, phase == .scanning else { return }
        notes = await scanner.notes
        dockerStatus = await scanner.docker
        apply(found)
    }

    func stop() {
        task?.cancel()
        withAnimation(Theme.spring) { phase = categories.isEmpty ? .idle : .results }
    }

    func apply(_ found: [JunkCategory]) {
        categories = found.filter { !$0.items.isEmpty }.sorted { $0.totalSize > $1.totalSize }
        selection = Set(categories.flatMap { $0.autoSelected(in: mode).map(\.url) })
        expanded = []
        rebuildTotals()
        withAnimation(Theme.spring) { phase = .results }
    }

    // MARK: Selection

    func toggle(_ cat: JunkCategory) {
        if state(of: cat) == .on {
            selection.subtract(cat.items.map(\.url))
            adjustTotals(cat.id, bytes: -(selectedBytesByCategory[cat.id] ?? 0), count: -(selectedCountByCategory[cat.id] ?? 0))
        } else {
            // Everything but the `neverAuto` items: a category tick never takes a device's last backup.
            let adding = cat.items.filter { !cat.neverAuto.contains($0.url) && !selection.contains($0.url) }
            selection.formUnion(adding.map(\.url))
            adjustTotals(cat.id, bytes: adding.reduce(0) { $0 + $1.size }, count: adding.count)
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

    /// Back to what the current mode ticks after a scan.
    func selectDefaults() {
        selection = Set(categories.flatMap { $0.autoSelected(in: mode).map(\.url) })
        rebuildTotals()
    }

    /// The picker above the list: remembers the mode and re-ticks the list for it.
    func select(mode new: CleanupMode) {
        guard new != mode else { return }
        mode = new
        if app?.probesSystem ?? false { CleanupMode.saved = new }
        selectDefaults()
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
        // A list opening in place: an ease, not a spring — the cards below should slide, not bounce.
        withAnimation(Theme.unfold) {
            if expanded.contains(cat.id) { expanded.remove(cat.id) } else { expanded.insert(cat.id) }
        }
    }

    // MARK: Clean

    var includesTrash: Bool { selectedTrashCount > 0 }
    var selectedTrashCount: Int { selectedCountByCategory[JunkCategoryID.trash] ?? 0 }
    var includesSystemLogs: Bool { (selectedCountByCategory[JunkCategoryID.systemLogs] ?? 0) > 0 }
    /// Docker frees its part at once, never through the Trash.
    var selectedDockerBytes: Int64 { selectedBytesByCategory[JunkCategoryID.docker] ?? 0 }

    /// Round button / confirm verb: «Очистить», or «Удалить навсегда» when the Trash is part of the selection.
    var cleanVerb: ConfirmCopy.Verb { includesTrash ? .deleteForever : .clean }

    /// The selected bytes of the Trash category (emptied for good, unlike the rest).
    var selectedTrashBytes: Int64 { selectedBytesByCategory[JunkCategoryID.trash] ?? 0 }

    func confirmation(tint: ModuleTint, action: @escaping @MainActor () -> Void) -> Confirmation? {
        guard selectedCount > 0 else { return nil }
        return Self.cleanConfirmation(count: selectedCount, bytes: selectedSize, trashBytes: selectedTrashBytes,
                                      trashCount: selectedTrashCount, dockerBytes: selectedDockerBytes,
                                      needsAdmin: includesSystemLogs, tint: tint, action: action)
    }

    /// «Очистить N объектов?» — everything goes to the Trash, except the Trash's own content (`trashBytes`), which
    /// is deleted for good. Smart Care uses it for junk, leftovers and old files together.
    static func cleanConfirmation(count: Int, bytes: Int64, trashBytes: Int64, trashCount: Int = 0, dockerBytes: Int64 = 0,
                                  needsAdmin: Bool, tint: ModuleTint, action: @escaping @MainActor () -> Void) -> Confirmation {
        let includesTrash = trashBytes > 0
        // By count, not bytes: an unsized item (no Full Disk Access) weighs 0 and must not make the Trash «everything».
        let onlyTrash = includesTrash && (trashCount > 0 ? trashCount == count : trashBytes == bytes)
        let docker = dockerBytes > 0 ? String(localized: " Docker (\(Fmt.size(dockerBytes))) очистит себя сам — сразу, без Корзины; тома с данными не трогаются.") : ""
        var title: String?
        var message: String?
        if includesTrash && !onlyTrash {
            title = String(localized: "Очистить \(ConfirmCopy.accusative(count, .items))?")
            message = String(localized: "Остальное попадёт в Корзину — это можно вернуть. Содержимое самой Корзины (\(Fmt.size(trashBytes))) будет удалено навсегда.") + docker
        } else if !includesTrash && dockerBytes > 0 && dockerBytes == bytes {
            title = String(localized: "Очистить Docker?")
            message = String(localized: "Docker удалит выбранное сам — сразу, без Корзины. Образы скачаются заново при следующем запуске; тома с данными не трогаются.")
        } else if !includesTrash {
            title = String(localized: "Очистить \(ConfirmCopy.accusative(count, .items))?")
            message = String(localized: "Всё попадёт в Корзину — это можно вернуть, пока Корзина не очищена.") + docker
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
    func clean(title: String = String(localized: "Очистка системного мусора"), module: AppModule = .junk,
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
