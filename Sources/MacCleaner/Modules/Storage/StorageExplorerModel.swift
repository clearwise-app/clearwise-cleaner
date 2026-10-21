import SwiftUI
import CleanerKit
import SpaceEngine

/// State of the «Хранилище» screen (opened from the sidebar disk widget): the selected category, the folders
/// opened inside it and their measured contents. Read-only: nothing here removes files.
@MainActor @Observable
final class StorageExplorerModel {
    enum Sort: String, CaseIterable, Identifiable {
        case largestFirst, smallestFirst
        var id: Self { self }
        var title: String { self == .largestFirst ? "Сначала большие" : "Сначала маленькие" }
    }

    private(set) var kind: StorageCategory.Kind
    /// Folders opened inside the category, outermost first. Empty: the category's own top level.
    private(set) var path: [URL] = []
    /// Measured contents of the current level; nil while measuring.
    private(set) var entries: [StorageEntry]?
    var sort: Sort = .largestFirst

    @ObservationIgnored private let explorer: StorageExplorer
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Levels measured during this visit (keyed by category + folder): going back is instant.
    @ObservationIgnored private var cache: [String: [StorageEntry]] = [:]

    init(kind: StorageCategory.Kind, fullDiskAccess: Bool, explorer: StorageExplorer? = nil) {
        self.kind = kind
        self.explorer = explorer ?? StorageExplorer(fullDiskAccess: fullDiskAccess)
        load()
    }

    /// Entries in the chosen order.
    var sortedEntries: [StorageEntry]? {
        entries.map { sort == .largestFirst ? $0 : $0.reversed() }
    }

    /// Categories in the chosen order; «Система и прочее» stays with the others (it has no folders to open).
    func sortedCategories(_ b: StorageBreakdown) -> [StorageCategory] {
        let list = b.categories.filter { $0.bytes > 0 }
        return sort == .largestFirst ? list.sorted { $0.bytes > $1.bytes } : list.sorted { $0.bytes < $1.bytes }
    }

    func select(_ kind: StorageCategory.Kind) {
        guard kind != self.kind || !path.isEmpty else { return }
        self.kind = kind
        path = []
        load()
    }

    func open(_ entry: StorageEntry) {
        guard entry.isFolder else { return }
        path.append(entry.url)
        load()
    }

    /// Breadcrumb: `index` -1 is the category itself.
    func goBack(to index: Int) {
        guard index < path.count - 1 else { return }
        path = Array(path.prefix(index + 1))
        load()
    }

    /// The disk changed (a cleanup, a new measurement): forget what was measured and measure the current level again.
    func reload() {
        cache = [:]
        load()
    }

    func cancel() { task?.cancel() }

    private var cacheKey: String { "\(kind.rawValue)|\(path.last?.path ?? "")" }

    private func load() {
        task?.cancel()
        let key = cacheKey
        if let hit = cache[key] {
            entries = hit
            return
        }
        entries = nil
        let explorer = self.explorer
        let folder = path.last
        let kind = self.kind
        task = Task { [weak self] in
            // Nonisolated async: runs off the main actor, and cancelling this task stops the walk.
            let result = await explorer.contents(of: kind, in: folder)
            guard let self, !Task.isCancelled, self.cacheKey == key else { return }
            self.cache[key] = result
            withAnimation(Theme.quick) { self.entries = result }
        }
    }
}
