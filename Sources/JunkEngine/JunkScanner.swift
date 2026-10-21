import Foundation
import CleanerKit

// CONTRACT (used by the UI — keep these signatures):
//   public actor JunkScanner { public init(); public func scan(progress: ProgressHandler?) async -> [JunkCategory] }
//   public enum JunkCleaner { public static func clean(_ items: [FileItem], in category: JunkCategory) async -> RemovalResult }
//
// Scanning is read-only. It runs in two passes:
//   1. every rule lists its candidates concurrently (directory listings, plist checks — cheap);
//   2. `JunkPlanner` de-duplicates across categories, then candidates are sized in parallel with fts(3).
// Unreadable folders (no Full Disk Access) are skipped silently.

public actor JunkScanner {
    private let environment: JunkEnvironment
    private let rules: [JunkRule]
    private let usesLiveClock: Bool

    /// Human-readable labels for items of the last scan, e.g. "Google Chrome · Default · GPUCache",
    /// "Мой iPhone · 12 окт. 2026 г., 10:00 · самая свежая", "Программа не найдена: /Applications/…".
    public private(set) var notes: [URL: String] = [:]

    public init() {
        self.init(environment: .live, liveClock: true)
    }

    /// Scanner over an injected environment (tests use a fake home in a temporary directory).
    init(environment: JunkEnvironment, rules: [JunkRule] = JunkCatalog.all, liveClock: Bool = false) {
        self.environment = environment
        self.rules = rules
        self.usesLiveClock = liveClock
    }

    public func note(for url: URL) -> String? { notes[url] }

    /// Scans all junk categories. Returns only categories with at least one item, sorted by size desc.
    public func scan(progress: ProgressHandler? = nil) async -> [JunkCategory] {
        var env = environment
        if usesLiveClock { env.now = Date() }
        let rules = self.rules
        progress?(ScanProgress(phase: "Поиск файлов", fraction: 0))

        // Pass 1: discovery.
        let raw: [[JunkCandidate]] = await withTaskGroup(of: (Int, [JunkCandidate]).self) { group in
            for (i, rule) in rules.enumerated() {
                group.addTask { (i, rule.candidates(in: env)) }
            }
            var collected = Array(repeating: [JunkCandidate](), count: rules.count)
            for await (i, candidates) in group { collected[i] = candidates }
            return collected
        }
        let assigned = JunkPlanner.assign(rules, raw, env: env)
        let jobs: [(Int, JunkCandidate)] = assigned.enumerated().flatMap { i, list in list.map { (i, $0) } }
        progress?(ScanProgress(phase: "Подсчёт размера", fraction: 0.05))

        // Pass 2: sizing, bounded parallelism, progress reported in completion order.
        var items = Array(repeating: [FileItem](), count: rules.count)
        var notes: [URL: String] = [:]
        await withTaskGroup(of: (Int, JunkCandidate, FileItem?).self) { group in
            var next = 0
            var done = 0
            let width = max(1, env.sizingConcurrency)
            while next < min(jobs.count, width) {
                let (i, c) = jobs[next]; next += 1
                group.addTask { (i, c, JunkSizing.item(for: c, rule: rules[i], env: env)) }
            }
            for await (i, candidate, item) in group {
                done += 1
                if let item {
                    items[i].append(item)
                    if let note = candidate.note { notes[item.url] = note }
                }
                progress?(ScanProgress(phase: rules[i].phase,
                                       fraction: 0.05 + 0.95 * Double(done) / Double(max(jobs.count, 1)),
                                       currentPath: candidate.url.path))
                if next < jobs.count {
                    let (j, c) = jobs[next]; next += 1
                    group.addTask { (j, c, JunkSizing.item(for: c, rule: rules[j], env: env)) }
                }
            }
        }

        var categories: [JunkCategory] = []
        for (i, rule) in rules.enumerated() where !items[i].isEmpty {
            var list = items[i]
            if rule.sortsNewestFirst {
                list.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            } else {
                list.sort { $0.size != $1.size ? $0.size > $1.size : $0.url.path < $1.url.path }
            }
            categories.append(JunkCategory(id: rule.id, title: rule.title, detail: rule.detail,
                                           symbol: rule.symbol, risk: rule.risk, items: list))
        }
        categories.sort { $0.totalSize > $1.totalSize }
        self.notes = notes
        progress?(ScanProgress(phase: "Готово", fraction: 1))
        return categories
    }
}

/// Measures one candidate and applies the rule's filters. Returns nil when the item should not be offered.
enum JunkSizing {
    static func item(for candidate: JunkCandidate, rule: JunkRule, env: JunkEnvironment) -> FileItem? {
        let url = candidate.url
        let m = TreeSizer.measure(url)
        guard m.exists else { return nil }
        if m.size == 0 && !rule.keepsEmptyItems { return nil }
        let activity = m.newestActivity ?? m.modification
        if rule.skipsActiveItems, let activity, env.now.timeIntervalSince(activity) < env.activeWindow { return nil }
        if let minimumAge = rule.minimumAge {
            guard let activity, env.now.timeIntervalSince(activity) >= minimumAge else { return nil }
        }
        if rule.skipsSockets && m.containsSocket { return nil }
        if rule.requiresUserDeletable && !FileManager.default.isDeletableFile(atPath: url.path) { return nil }
        let lastUsed = rule.wantsLastUsed ? FileMetadata.lastUsedDate(of: url) : nil
        return FileItem(url: url, size: m.size, isDirectory: m.isDirectory,
                        lastUsed: lastUsed, modified: m.newestModification ?? m.modification)
    }
}
