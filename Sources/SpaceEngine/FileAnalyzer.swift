import Foundation
import CoreServices
import CleanerKit

// CONTRACT (used by the UI — keep these signatures):
//   FileKind, AnalyzedFile, OldFilesOptions, FileAnalyzer.oldFiles / largeFiles, SpaceMapper.map.
// Additional public API: FileAnalyzer.duplicates(roots:minSize:progress:), FileKind.classify(_:),
// OldFilesOptions.useSpotlight.

public struct AnalyzedFile: Identifiable, Hashable, Sendable {
    public let item: FileItem
    public let kind: FileKind
    public var id: URL { item.url }
    public init(item: FileItem, kind: FileKind) { self.item = item; self.kind = kind }
}

public struct OldFilesOptions: Sendable {
    public var roots: [URL]
    public var unusedForDays: Int
    public var minSize: Int64
    /// Ask Spotlight for `kMDItemLastUsedDate` / date added. Tests switch it off; the app keeps it on.
    public var useSpotlight: Bool

    public init(roots: [URL], unusedForDays: Int, minSize: Int64) {
        self.roots = roots; self.unusedForDays = unusedForDays; self.minSize = minSize
        self.useSpotlight = true
    }

    public static var `default`: OldFilesOptions {
        OldFilesOptions(roots: FileAnalyzer.defaultRoots, unusedForDays: 180, minSize: 10 * 1024 * 1024)
    }
}

public actor FileAnalyzer {
    public init() {}

    /// Personal folders scanned by default.
    public static var defaultRoots: [URL] {
        let h = SafetyGuard.home
        return ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"].map { h.appendingPathComponent($0) }
    }

    /// Files (and packages, as one item) ≥ `minSize` that were not used for ≥ `unusedForDays`, biggest first.
    /// "Last used" = Spotlight last-opened date (never older than the content modification date), else
    /// the later of content-modified and date-added. The effective date is returned in `FileItem.lastUsed`.
    public func oldFiles(_ options: OldFilesOptions, progress: ProgressHandler? = nil) async -> [AnalyzedFile] {
        await Self.runCancellable { monitor in
            Self.collectOldFiles(options, monitor: monitor, progress: progress)
        }
    }

    /// Files (and packages, as one item) ≥ `minSize`, any age, biggest first.
    public func largeFiles(roots: [URL], minSize: Int64, progress: ProgressHandler? = nil) async -> [AnalyzedFile] {
        await Self.runCancellable { monitor in
            Self.collectLargeFiles(roots: roots, minSize: minSize, monitor: monitor, progress: progress)
        }
    }

    // MARK: - Implementation

    /// Runs blocking work off the cooperative pool; cancelling the calling task stops the walk early.
    static func runCancellable<T: Sendable>(
        _ work: @escaping @Sendable (WalkMonitor) -> T
    ) async -> T {
        let box = MonitorBox()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                work(box.monitor)
            }.value
        } onCancel: {
            box.monitor.cancel()
        }
    }

    /// The monitor must exist before the work starts so `onCancel` can reach it; progress is wired in later.
    final class MonitorBox: @unchecked Sendable {
        let monitor = WalkMonitor(totalUnits: 1, handler: nil)
    }

    static func collectOldFiles(_ options: OldFilesOptions, monitor outer: WalkMonitor, progress: ProgressHandler?) -> [AnalyzedFile] {
        let roots = FileWalker.normalizedRoots(options.roots)
        let monitor = WalkMonitor(totalUnits: roots.count, handler: progress, parent: outer)
        let cutoff = Date().addingTimeInterval(-Double(max(0, options.unusedForDays)) * 86_400)
        let sink = ResultSink<AnalyzedFile>()

        concurrentRoots(roots) { root in
            let phase = FileWalker.displayPhase(for: root)
            let walkOptions = FileWalker.Options(minAllocatedSize: options.minSize, includePackages: true, phase: phase)
            FileWalker.walk(root: root, options: walkOptions, monitor: monitor) { file in
                // The effective date is never earlier than the content modification date, so a recently
                // modified file can be rejected without the (slow) Spotlight query.
                if let modified = file.modified, modified > cutoff { return }
                if FileWalker.isICloudPlaceholder(file.url) { return }
                if SafetyGuard.isProtected(file.url) { return }

                let last = effectiveLastUsed(of: file.url, modified: file.modified, useSpotlight: options.useSpotlight)
                guard let last, last <= cutoff else { return }
                sink.append(makeItem(file, lastUsed: last))
            }
            monitor.unitFinished(phase: phase)
        }
        return finish(sink.values, monitor: monitor)
    }

    static func collectLargeFiles(roots rawRoots: [URL], minSize: Int64, monitor outer: WalkMonitor, progress: ProgressHandler?) -> [AnalyzedFile] {
        let roots = FileWalker.normalizedRoots(rawRoots)
        let monitor = WalkMonitor(totalUnits: roots.count, handler: progress, parent: outer)
        let sink = ResultSink<AnalyzedFile>()

        concurrentRoots(roots) { root in
            let phase = FileWalker.displayPhase(for: root)
            let walkOptions = FileWalker.Options(minAllocatedSize: minSize, includePackages: true, phase: phase)
            FileWalker.walk(root: root, options: walkOptions, monitor: monitor) { file in
                if FileWalker.isICloudPlaceholder(file.url) { return }
                if SafetyGuard.isProtected(file.url) { return }
                let last = effectiveLastUsed(of: file.url, modified: file.modified, useSpotlight: true)
                sink.append(makeItem(file, lastUsed: last))
            }
            monitor.unitFinished(phase: phase)
        }
        return finish(sink.values, monitor: monitor)
    }

    private static func finish(_ files: [AnalyzedFile], monitor: WalkMonitor) -> [AnalyzedFile] {
        // Roots are normalised, but be defensive about duplicates (e.g. via firmlinks).
        var seen = Set<URL>()
        let unique = files.filter { seen.insert($0.item.url).inserted }
        let sorted = unique.sorted {
            $0.item.size != $1.item.size ? $0.item.size > $1.item.size : $0.item.url.path < $1.item.url.path
        }
        monitor.force(phase: "Готово", fraction: 1)
        return sorted
    }

    private static func makeItem(_ file: WalkedFile, lastUsed: Date?) -> AnalyzedFile {
        let item = FileItem(url: file.url, size: file.allocatedSize, isDirectory: file.isPackage,
                            lastUsed: lastUsed, modified: file.modified)
        return AnalyzedFile(item: item, kind: FileKind.classify(file.url))
    }

    /// Spotlight last-used (never earlier than the content modification date), else max(modified, date added).
    static func effectiveLastUsed(of url: URL, modified: Date?, useSpotlight: Bool) -> Date? {
        guard useSpotlight else { return modified }
        let dates = SpotlightDates.read(url)
        if let used = dates.lastUsed {
            if let modified, modified > used { return modified }
            return used
        }
        return [modified, dates.added].compactMap { $0 }.max()
    }

    /// Runs `body` for every root, in parallel (roots are usually different folders on the same SSD).
    static func concurrentRoots(_ roots: [URL], _ body: @Sendable (URL) -> Void) {
        guard roots.count > 1 else { roots.forEach(body); return }
        DispatchQueue.concurrentPerform(iterations: roots.count) { body(roots[$0]) }
    }
}

// MARK: - Helpers

/// Lock-protected append-only collection used by concurrent walkers.
final class ResultSink<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func append(_ value: T) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return storage }
}

enum SpotlightDates {
    struct Dates { var lastUsed: Date?; var added: Date? }

    static func read(_ url: URL) -> Dates {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return Dates() }
        return Dates(lastUsed: MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date,
                     added: MDItemCopyAttribute(item, kMDItemDateAdded) as? Date)
    }
}
