import Foundation
import CleanerKit

/// Builds the directory tree behind the sunburst chart. It only READS.
public actor SpaceMapper {
    private let avoidPrivacyPrompts: Bool

    /// - Parameter avoidPrivacyPrompts: without Full Disk Access, do not open `~/Library/Containers/*` and
    ///   `~/Library/Group Containers/*`: macOS would pop a consent dialog and block the scan until it is
    ///   answered. Those folders then count as 0 bytes (the UI should suggest granting Full Disk Access).
    public init(avoidPrivacyPrompts: Bool = true) {
        self.avoidPrivacyPrompts = avoidPrivacyPrompts
    }

    /// Name of the synthetic node that aggregates small siblings (the same value `DirectoryNode.name` gives it).
    public static let otherName = DirectoryNode.aggregateName
    /// Children smaller than this share of their parent are folded into "Прочее".
    public static let minChildShare = 0.01
    /// Hard cap of real children per node (an extra "Прочее" node may follow).
    public static let maxChildren = 40

    /// True for the synthetic "Прочее" child of `parent` (it shares the parent's URL and is not a directory).
    /// Never act on such a node's URL: it stands for several unrelated items, not for the parent folder.
    public static func isOtherBucket(_ node: DirectoryNode, in parent: DirectoryNode) -> Bool {
        node.isAggregate || (!node.isDirectory && node.children.isEmpty && node.url == parent.url)
    }

    /// Label for a node: "Прочее" for the synthetic bucket, the file name otherwise.
    public static func displayName(of node: DirectoryNode, in parent: DirectoryNode?) -> String {
        if let parent, isOtherBucket(node, in: parent) { return otherName }
        return node.name
    }

    private static var appDataFolders: Set<String> {
        let lib = SafetyGuard.home.appendingPathComponent("Library").path
        return [lib + "/Containers", lib + "/Group Containers"]
    }

    /// Real allocated sizes for the whole subtree; children are kept for `depth` levels only
    /// (`depth: 1` = root + its direct children). Symlinks are not followed and other volumes are not entered.
    public func map(_ root: URL, depth: Int = 4, progress: ProgressHandler? = nil) async -> DirectoryNode {
        let blocked: Set<String> = avoidPrivacyPrompts && !Permissions.hasFullDiskAccess ? Self.appDataFolders : []
        return await FileAnalyzer.runCancellable { monitor in
            SpaceScan(root: root, depth: max(0, depth), blockedParents: blocked,
                      monitor: WalkMonitor(totalUnits: 1, handler: progress, parent: monitor)).run()
        }
    }
}

// MARK: - Directory identity

/// Remembers which directories (by device + inode) were already entered, so a folder reachable by two paths
/// is measured once. On macOS `/Users` and `/System/Volumes/Data/Users` are the same directory (firmlinks):
/// without this, mapping `/` counted the whole data volume twice.
final class VisitedDirectories: @unchecked Sendable {
    struct Identity: Hashable, Sendable {
        let device: Int64
        let inode: UInt64
    }

    private let lock = NSLock()
    private var seen = Set<Identity>()

    /// Identity of the directory at `url` itself (not following a symlink in the last component).
    static func identity(of url: URL) -> Identity? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return Identity(device: Int64(st.st_dev), inode: UInt64(st.st_ino))
    }

    /// Records `identity`; returns false when it was already recorded (the directory is a repeat).
    func insert(_ identity: Identity) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen.insert(identity).inserted
    }

    /// True the first time the directory at `url` is seen. Unreadable identities are never treated as repeats.
    func firstVisit(of url: URL) -> Bool {
        guard let id = Self.identity(of: url) else { return true }
        return insert(id)
    }
}

/// Mirrors that must not be walked when mapping `/`: `/System/Volumes` holds the data volume under its
/// own name, which is the same content as `/Users`, `/Applications`, … seen through firmlinks.
func isFirmlinkMirror(_ url: URL, scanRoot: URL) -> Bool {
    scanRoot.standardizedFileURL.path == "/" && url.standardizedFileURL.path == "/System/Volumes"
}

// MARK: - Scan

private struct Candidate {
    let url: URL
    let size: Int64
    let isDirectory: Bool
    let node: DirectoryNode?
}

/// Minimal LIFO thread pool (depth-first keeps memory small). Jobs never block waiting for other jobs,
/// so it cannot deadlock the way nested `DispatchQueue.concurrentPerform` calls can.
private final class WorkPool: @unchecked Sendable {
    private let cond = NSCondition()
    private var stack: [() -> Void] = []
    private var stopped = false

    init(threads: Int) {
        for i in 0..<max(1, threads) {
            let t = Thread { [self] in loop() }
            t.name = "SpaceMapper.worker.\(i)"
            t.qualityOfService = .userInitiated
            t.start()
        }
    }

    func submit(_ job: @escaping () -> Void) {
        cond.lock(); stack.append(job); cond.unlock(); cond.signal()
    }

    func shutdown() {
        cond.lock(); stopped = true; cond.unlock(); cond.broadcast()
    }

    private func loop() {
        while true {
            cond.lock()
            while stack.isEmpty && !stopped { cond.wait() }
            if stopped && stack.isEmpty { cond.unlock(); return }
            let job = stack.removeLast()
            cond.unlock()
            autoreleasepool { job() }
        }
    }
}

/// State of one folder while its subtree is being measured; finalised when all children are done.
private final class DirState: @unchecked Sendable {
    let url: URL
    let level: Int
    let parent: DirState?
    /// Whether this folder's children are kept in the tree (level < depth).
    let keepsChildren: Bool
    private let lock = NSLock()
    private var total: Int64 = 0
    private var candidates: [Candidate] = []
    /// 1 for the folder's own listing + 1 per subfolder still running.
    private var pending = 1
    private var node: DirectoryNode?

    init(url: URL, level: Int, parent: DirState?, depth: Int) {
        self.url = url; self.level = level; self.parent = parent
        self.keepsChildren = level < depth
    }

    func addLocal(candidates new: [Candidate], total add: Int64, pendingChildren: Int) {
        lock.lock()
        total += add
        candidates.append(contentsOf: new)
        pending += pendingChildren
        lock.unlock()
    }

    func childFinished(_ child: Candidate) {
        lock.lock()
        total += child.size
        if keepsChildren { candidates.append(child) }
        lock.unlock()
    }

    /// Returns true when this was the last outstanding piece.
    func decrement() -> Bool {
        lock.lock(); pending -= 1; let done = pending == 0; lock.unlock()
        return done
    }

    func snapshot() -> (total: Int64, candidates: [Candidate]) {
        lock.lock(); defer { lock.unlock() }
        return (total, candidates)
    }
}

private final class SpaceScan: @unchecked Sendable {
    let root: URL
    let depth: Int
    let monitor: WalkMonitor
    private let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .volumeIdentifierKey,
    ]
    private let keySet: Set<URLResourceKey>
    private var rootVolume: (any NSObjectProtocol)?
    private let visitedDirectories = VisitedDirectories()
    private let phase = String(localized: "Карта диска", bundle: .module)

    /// Folders whose children are not opened (see `SpaceMapper.init(avoidPrivacyPrompts:)`).
    let blockedParents: Set<String>

    init(root: URL, depth: Int, blockedParents: Set<String>, monitor: WalkMonitor) {
        self.blockedParents = blockedParents
        self.root = root
        self.depth = depth
        self.monitor = monitor
        self.keySet = Set(keys)
    }

    func run() -> DirectoryNode {
        rootVolume = (try? root.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        let v = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if v?.isDirectory != true {
            let size = v?.isSymbolicLink == true ? 0 : FileSizer.allocatedSize(of: root)
            return DirectoryNode(url: root, size: size, isDirectory: false, children: [])
        }

        _ = visitedDirectories.firstVisit(of: root)
        let pool = WorkPool(threads: max(4, ProcessInfo.processInfo.activeProcessorCount))
        let done = DispatchSemaphore(value: 0)
        let rootState = DirState(url: root, level: 0, parent: nil, depth: depth)
        var result: DirectoryNode?
        let resultLock = NSLock()

        // Called when a folder's subtree is complete: builds its node and notifies the parent.
        func finalize(_ state: DirState) {
            var current = state
            while true {
                let (total, candidates) = current.snapshot()
                let keepChildren = current.keepsChildren
                let node: DirectoryNode? = current.level <= depth
                    ? DirectoryNode(url: current.url, size: total, isDirectory: true,
                                    children: keepChildren ? Self.prune(candidates, parent: current.url, total: total) : [])
                    : nil
                guard let parent = current.parent else {
                    resultLock.lock(); result = node ?? DirectoryNode(url: root, size: total, isDirectory: true, children: []); resultLock.unlock()
                    done.signal()
                    return
                }
                parent.childFinished(Candidate(url: current.url, size: total, isDirectory: true, node: node))
                if parent.decrement() { current = parent } else { return }
            }
        }

        func process(_ state: DirState) {
            var subdirs: [DirState] = []
            var localTotal: Int64 = 0
            var localCandidates: [Candidate] = []
            let keepChildren = state.level < depth

            let blocked = !blockedParents.isEmpty && blockedParents.contains(state.url.deletingLastPathComponent().path)
            if !monitor.isCancelled && !blocked {
                monitor.report(phase: phase, path: state.url.path)
                if let entries = try? FileManager.default.contentsOfDirectory(
                    at: state.url, includingPropertiesForKeys: keys, options: []
                ) {
                    for entry in entries {
                        guard let v = try? entry.resourceValues(forKeys: keySet) else { continue }
                        if v.isSymbolicLink == true { continue }
                        if v.isDirectory == true {
                            if let rootVolume, let vol = v.volumeIdentifier, !vol.isEqual(rootVolume) { continue }
                            if isFirmlinkMirror(entry, scanRoot: root) { continue }
                            // The same directory reached through another path (firmlink): count it once.
                            if !visitedDirectories.firstVisit(of: entry) { continue }
                            subdirs.append(DirState(url: entry, level: state.level + 1, parent: state, depth: depth))
                        } else {
                            let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                            localTotal += size
                            if keepChildren { localCandidates.append(Candidate(url: entry, size: size, isDirectory: false, node: nil)) }
                        }
                    }
                }
            }
            // Register the children before any of them can finish.
            state.addLocal(candidates: localCandidates, total: localTotal, pendingChildren: subdirs.count)
            for sub in subdirs { pool.submit { process(sub) } }
            if state.decrement() { finalize(state) }
        }

        pool.submit { process(rootState) }
        done.wait()
        pool.shutdown()
        monitor.force(phase: FileWalker.donePhase, fraction: 1)
        resultLock.lock(); defer { resultLock.unlock() }
        return result ?? DirectoryNode(url: root, size: 0, isDirectory: true, children: [])
    }

    /// Keeps the biggest children (≥ 1 % of the parent, at most 40) and folds the rest into "Прочее".
    static func prune(_ candidates: [Candidate], parent: URL, total: Int64) -> [DirectoryNode] {
        let sorted = candidates.sorted {
            $0.size != $1.size ? $0.size > $1.size : $0.url.lastPathComponent < $1.url.lastPathComponent
        }
        let threshold = Double(total) * SpaceMapper.minChildShare
        var kept: [DirectoryNode] = []
        var rest: Int64 = 0
        for c in sorted {
            if kept.count < SpaceMapper.maxChildren, c.size > 0, Double(c.size) >= threshold {
                kept.append(c.node ?? DirectoryNode(url: c.url, size: c.size, isDirectory: c.isDirectory, children: []))
            } else {
                rest += c.size
            }
        }
        if rest > 0 {
            kept.append(DirectoryNode(url: parent, size: rest, isDirectory: false, children: [], isAggregate: true))
        }
        return kept
    }
}
