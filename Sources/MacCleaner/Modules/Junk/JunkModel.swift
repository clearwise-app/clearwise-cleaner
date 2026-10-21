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

    var selectedPairs: [(JunkCategory, [FileItem])] {
        categories.compactMap { cat in
            let items = cat.items.filter { selection.contains($0.url) }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    var selectedSize: Int64 { selectedPairs.reduce(0) { $0 + $1.1.reduce(0) { $0 + $1.size } } }
    var selectedCount: Int { selectedPairs.reduce(0) { $0 + $1.1.count } }

    func selectedSize(in cat: JunkCategory) -> Int64 {
        cat.items.reduce(0) { selection.contains($1.url) ? $0 + $1.size : $0 }
    }

    func state(of cat: JunkCategory) -> CheckState {
        CheckState(selected: cat.items.filter { selection.contains($0.url) }.count, total: cat.items.count)
    }

    // MARK: Scan

    func startScan() {
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
        withAnimation(Theme.spring) { phase = .results }
    }

    // MARK: Selection

    func toggle(_ cat: JunkCategory) {
        let urls = cat.items.map(\.url)
        if state(of: cat) == .on { selection.subtract(urls) } else { selection.formUnion(urls) }
    }

    func toggle(_ item: FileItem) {
        if selection.contains(item.url) { selection.remove(item.url) } else { selection.insert(item.url) }
    }

    func toggleExpanded(_ cat: JunkCategory) {
        withAnimation(Theme.spring) {
            if expanded.contains(cat.id) { expanded.remove(cat.id) } else { expanded.insert(cat.id) }
        }
    }

    // MARK: Clean

    var includesTrash: Bool { selectedPairs.contains { $0.0.id == JunkCategoryID.trash } }

    func requestClean() {
        guard let app, selectedCount > 0 else { return }
        let trashBytes = selectedPairs.filter { $0.0.id == JunkCategoryID.trash }.reduce(0) { $0 + $1.1.reduce(0) { $0 + $1.size } }
        var message = "Файлы будут перемещены в Корзину — их можно вернуть, пока Корзина не очищена."
        if includesTrash {
            message = trashBytes == selectedSize
                ? "Содержимое Корзины будет удалено безвозвратно. Это действие нельзя отменить."
                : "Файлы будут перемещены в Корзину. Содержимое самой Корзины (\(Fmt.size(trashBytes))) будет удалено безвозвратно."
        }
        app.ask(Confirmation(
            title: includesTrash && trashBytes == selectedSize ? "Очистить Корзину?" : "Очистить системный мусор?",
            message: message,
            count: selectedCount,
            bytes: selectedSize,
            confirmTitle: includesTrash ? "Очистить" : "Переместить в Корзину",
            permanent: includesTrash,
            needsAdmin: selectedPairs.contains { $0.0.id == JunkCategoryID.systemLogs },
            tint: .junk,
            action: { [weak self] in self?.startClean() }
        ))
    }

    func startClean() {
        task = Task { await clean() }
    }

    func clean() async {
        let pairs = selectedPairs
        resultWasPermanent = pairs.count == 1 && pairs[0].0.id == JunkCategoryID.trash
        withAnimation(Theme.spring) { phase = .cleaning }
        var total = RemovalResult()
        for (cat, items) in pairs {
            total.merge(await JunkCleaner.clean(items, in: cat))
        }
        result = total
        app?.didRemove(total)
        withAnimation(Theme.spring) { phase = .done }
    }

    /// Drops removed items from the results (after cleaning here or elsewhere).
    func forget(_ removed: Set<URL>) {
        guard !categories.isEmpty else { return }
        categories = categories.compactMap { cat in
            var c = cat
            c.items.removeAll { removed.contains($0.url.standardizedFileURL) }
            return c.items.isEmpty ? nil : c
        }
        selection.subtract(removed)
    }

    func finish() {
        result = nil
        withAnimation(Theme.spring) { phase = categories.isEmpty ? .idle : .results }
    }
}
