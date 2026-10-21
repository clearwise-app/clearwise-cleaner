import Foundation
import CryptoKit
import CleanerKit

extension FileAnalyzer {
    /// Groups of byte-identical files (≥ `minSize`), biggest wasted space first.
    /// Pipeline: group by size → SHA-256 of the first 64 KB → SHA-256 of the whole file.
    /// Hard links to the same inode are not duplicates (removing one frees nothing) and are collapsed.
    /// Inside a group the oldest file comes first (most likely the original).
    public func duplicates(roots: [URL], minSize: Int64, progress: ProgressHandler? = nil) async -> [[AnalyzedFile]] {
        await Self.runCancellable { monitor in
            DuplicateFinder.find(roots: roots, minSize: minSize, monitor: monitor, progress: progress)
        }
    }
}

enum DuplicateFinder {
    static let headBytes = 64 * 1024
    private static let chunk = 1024 * 1024

    private struct Candidate {
        let file: WalkedFile
        let inode: UInt64
        let device: Int32
    }

    static func find(roots rawRoots: [URL], minSize: Int64, monitor outer: WalkMonitor, progress: ProgressHandler?) -> [[AnalyzedFile]] {
        let roots = FileWalker.normalizedRoots(rawRoots)
        let monitor = WalkMonitor(totalUnits: 1, handler: progress, parent: outer)
        let phase = "Поиск дубликатов"

        // 1. Walk (first 20% of progress, one step per root). Packages are not entered: their internals are not the user's files.
        let sink = ResultSink<WalkedFile>()
        let walkedRoots = ResultSink<URL>()
        FileAnalyzer.concurrentRoots(roots) { root in
            let options = FileWalker.Options(minAllocatedSize: max(1, minSize), includePackages: false, phase: phase)
            FileWalker.walk(root: root, options: options, monitor: monitor) { file in
                if FileWalker.isICloudPlaceholder(file.url) { return }
                sink.append(file)
            }
            walkedRoots.append(root)
            monitor.force(phase: FileWalker.displayPhase(for: root),
                          fraction: 0.2 * Double(walkedRoots.values.count) / Double(max(1, roots.count)))
        }
        if monitor.isCancelled { return [] }
        monitor.force(phase: phase, fraction: 0.2)

        // 2. Group by logical size, dropping hard links.
        var bySize: [Int64: [Candidate]] = [:]
        for f in sink.values where f.logicalSize >= minSize {
            var st = stat()
            guard lstat(f.url.path, &st) == 0 else { continue }
            bySize[f.logicalSize, default: []].append(Candidate(file: f, inode: UInt64(st.st_ino), device: st.st_dev))
        }
        var sizeGroups: [[Candidate]] = []
        for (_, group) in bySize where group.count > 1 {
            var seen = Set<String>()
            let distinct = group.filter { seen.insert("\($0.device):\($0.inode)").inserted }
            if distinct.count > 1 { sizeGroups.append(distinct) }
        }

        // 3. Partial hash, then full hash — in parallel, groups are independent.
        let total = max(1, sizeGroups.count)
        let done = Counter()
        let resultSink = ResultSink<[Candidate]>()
        DispatchQueue.concurrentPerform(iterations: sizeGroups.count) { i in
            defer {
                let n = done.increment()
                monitor.report(phase: phase, path: nil)
                if n % 16 == 0 { monitor.force(phase: phase, fraction: 0.2 + 0.8 * Double(n) / Double(total)) }
            }
            if monitor.isCancelled { return }
            let group = sizeGroups[i]
            for sameHead in regroup(group, by: { hash($0.file.url, limit: headBytes) }) {
                for same in regroup(sameHead, by: { hash($0.file.url, limit: nil) }) {
                    resultSink.append(same)
                }
            }
        }
        if monitor.isCancelled { return [] }

        let groups: [[AnalyzedFile]] = resultSink.values.map { group in
            group.sorted { ($0.file.modified ?? .distantFuture) < ($1.file.modified ?? .distantFuture) }
                .map { c in
                    let item = FileItem(url: c.file.url, size: c.file.allocatedSize, isDirectory: false,
                                        lastUsed: c.file.modified, modified: c.file.modified)
                    return AnalyzedFile(item: item, kind: FileKind.classify(c.file.url))
                }
        }
        monitor.force(phase: "Готово", fraction: 1)
        return groups.sorted {
            let a = ($0.first?.item.size ?? 0) * Int64($0.count - 1)
            let b = ($1.first?.item.size ?? 0) * Int64($1.count - 1)
            return a != b ? a > b : ($0.first?.item.url.path ?? "") < ($1.first?.item.url.path ?? "")
        }
    }

    /// Splits `items` into buckets with equal, non-nil hashes; buckets of one are dropped.
    private static func regroup(_ items: [Candidate], by key: (Candidate) -> Data?) -> [[Candidate]] {
        var buckets: [Data: [Candidate]] = [:]
        for item in items {
            guard let h = key(item) else { continue }
            buckets[h, default: []].append(item)
        }
        return buckets.values.filter { $0.count > 1 }
    }

    /// SHA-256 of the file (or of its first `limit` bytes). Nil when unreadable.
    static func hash(_ url: URL, limit: Int?) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            let data: Data? = autoreleasepool {
                try? handle.read(upToCount: min(chunk, remaining))
            }
            guard let data, !data.isEmpty else { break }
            hasher.update(data: data)
            remaining -= data.count
        }
        return Data(hasher.finalize())
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func increment() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }
}
