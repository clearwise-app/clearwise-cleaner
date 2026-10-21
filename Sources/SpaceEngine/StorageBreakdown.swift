import Foundation
import CleanerKit

// MARK: - Model

/// One slice of the startup disk ("Приложения", "Фото и видео", …), like macOS Settings → Storage.
public struct StorageCategory: Identifiable, Sendable, Equatable, Codable {
    public enum Kind: String, CaseIterable, Sendable, Codable {
        case apps, documents, media, music, developer, iCloud, appData, trash, system

        public var title: String {
            switch self {
            case .apps: return "Приложения"
            case .documents: return "Документы"
            case .media: return "Фото и видео"
            case .music: return "Музыка"
            case .developer: return "Разработка"
            case .iCloud: return "iCloud Drive"
            case .appData: return "Данные приложений"
            case .trash: return "Корзина"
            case .system: return "Система и прочее"
            }
        }

        /// Fits the narrow sidebar legend.
        public var shortTitle: String {
            switch self {
            case .media: return "Медиа"
            case .appData: return "Данные"
            case .iCloud: return "iCloud"
            case .system: return "Система"
            default: return title
            }
        }

        public var symbol: String {
            switch self {
            case .apps: return "square.grid.2x2.fill"
            case .documents: return "doc.fill"
            case .media: return "photo.fill"
            case .music: return "music.note"
            case .developer: return "hammer.fill"
            case .iCloud: return "icloud.fill"
            case .appData: return "shippingbox.fill"
            case .trash: return "trash.fill"
            case .system: return "gearshape.fill"
            }
        }
    }

    public var kind: Kind
    public var bytes: Int64
    public var id: Kind { kind }
    public var title: String { kind.title }
    public var symbol: String { kind.symbol }

    public init(kind: Kind, bytes: Int64) {
        self.kind = kind
        self.bytes = bytes
    }
}

/// What the startup disk is made of. `free + Σ categories.bytes == total` (up to rounding of clamping).
public struct StorageBreakdown: Sendable, Equatable, Codable {
    public var volumeName: String
    public var total: Int64
    /// Free as Finder shows it: purgeable space counts as free (see `StorageAnalyzer.capacity(of:)`).
    public var free: Int64
    /// Every `Kind` exactly once, biggest first.
    public var categories: [StorageCategory]
    public var measuredAt: Date
    /// Wall time of the measurement, seconds.
    public var duration: TimeInterval
    /// Without Full Disk Access other apps' containers are not measured (they end up in «Система и прочее»).
    public var fullDiskAccess: Bool

    public var used: Int64 { max(0, total - free) }

    public init(volumeName: String, total: Int64, free: Int64, categories: [StorageCategory],
                measuredAt: Date = Date(), duration: TimeInterval = 0, fullDiskAccess: Bool = true) {
        self.volumeName = volumeName
        self.total = total
        self.free = free
        self.categories = categories.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.kind.rawValue < $1.kind.rawValue }
        self.measuredAt = measuredAt
        self.duration = duration
        self.fullDiskAccess = fullDiskAccess
    }

    public func bytes(_ kind: StorageCategory.Kind) -> Int64 {
        categories.first { $0.kind == kind }?.bytes ?? 0
    }

    /// Share of the whole disk, 0…1.
    public func share(_ bytes: Int64) -> Double {
        total > 0 ? min(1, max(0, Double(bytes) / Double(total))) : 0
    }

    public func share(_ kind: StorageCategory.Kind) -> Double { share(bytes(kind)) }

    /// Builds a breakdown from measured folders: «Система и прочее» is whatever of `used` is not explained by
    /// them (never negative). When the folders add up to more than `used` — clones and hard links are counted
    /// once per path, purgeable files count as free — they are scaled down so the bar never exceeds the disk.
    public static func compose(volumeName: String, total: Int64, free: Int64,
                               measured: [StorageCategory.Kind: Int64],
                               measuredAt: Date = Date(), duration: TimeInterval = 0,
                               fullDiskAccess: Bool = true) -> StorageBreakdown {
        let total = max(0, total)
        let free = min(max(0, free), total)
        let used = total - free
        var sizes = measured.filter { $0.key != .system }.mapValues { max(0, $0) }
        let known = sizes.values.reduce(0, +)
        if known > used, known > 0 {
            let k = Double(used) / Double(known)
            sizes = sizes.mapValues { Int64(Double($0) * k) }
        }
        let explained = sizes.values.reduce(0, +)
        sizes[.system] = max(0, used - explained)
        let categories = StorageCategory.Kind.allCases.map { StorageCategory(kind: $0, bytes: sizes[$0] ?? 0) }
        return StorageBreakdown(volumeName: volumeName, total: total, free: free, categories: categories,
                                measuredAt: measuredAt, duration: duration, fullDiskAccess: fullDiskAccess)
    }
}

// MARK: - Roots

/// Where each category lives. Injectable so tests can point everything at a fake home.
public struct StorageRoots: Sendable {
    public var home: URL
    public var applications: [URL]
    /// Machine-wide developer folders counted as «Разработка»: `/Library/Developer` and the Xcode simulator
    /// runtimes macOS keeps in `/System/Library/AssetsV2` (often tens of GB that would otherwise look like "System").
    public var systemDeveloper: [URL]
    /// Any path on the volume whose capacity is reported.
    public var volume: URL

    public init(home: URL = SafetyGuard.home,
                applications: [URL]? = nil,
                systemDeveloper: [URL]? = nil,
                volume: URL = URL(fileURLWithPath: "/")) {
        self.home = home
        self.applications = applications ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        self.systemDeveloper = systemDeveloper ?? Self.defaultSystemDeveloper()
        self.volume = volume
    }

    static func defaultSystemDeveloper() -> [URL] {
        let assets = URL(fileURLWithPath: "/System/Library/AssetsV2")
        let runtimes = ((try? FileManager.default.contentsOfDirectory(atPath: assets.path)) ?? [])
            .filter { $0.hasPrefix("com_apple_MobileAsset_") && $0.hasSuffix("SimulatorRuntime") }
            .sorted()
            .map { assets.appendingPathComponent($0) }
        return [URL(fileURLWithPath: "/Library/Developer")] + runtimes
    }

    /// Package-manager and toolchain folders in the home folder («Разработка»).
    public static let developerDotFolders = [
        ".npm", ".yarn", ".pnpm-store", ".bun", ".deno", ".gradle", ".m2", ".cargo", ".rustup", ".cocoapods",
        ".pub-cache", ".android", ".nvm", ".pyenv", ".conda", ".cache", ".swiftpm", ".expo", ".docker",
        ".vscode", ".cursor", ".gem", ".kube", ".minikube",
    ]

    /// Home folders that have a category of their own; every other visible folder of the home counts as
    /// «Документы» (projects, `~/Work`, …).
    static let knownHomeFolders: Set<String> = [
        "Library", "Applications", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music",
    ]

    /// Folders measured for each category. Roots never overlap: a folder that is another category's root
    /// (`~/Library/Developer` inside `~/Library`) is skipped by the walk of the outer root.
    func plan() -> [(kind: StorageCategory.Kind, url: URL)] {
        let h = home
        let lib = h.appendingPathComponent("Library")
        var list: [(StorageCategory.Kind, URL)] = applications.map { (.apps, $0) }
        list += ["Documents", "Desktop", "Downloads"].map { (.documents, h.appendingPathComponent($0)) }
        list += ["Pictures", "Movies"].map { (.media, h.appendingPathComponent($0)) }
        list.append((.music, h.appendingPathComponent("Music")))
        list.append((.developer, lib.appendingPathComponent("Developer")))
        list.append((.developer, lib.appendingPathComponent("Android")))
        list += Self.developerDotFolders.map { (.developer, h.appendingPathComponent($0)) }
        list += systemDeveloper.map { (.developer, $0) }
        list.append((.iCloud, lib.appendingPathComponent("Mobile Documents")))
        list.append((.appData, lib))
        list.append((.trash, h.appendingPathComponent(".Trash")))

        // Other visible folders of the home (`~/Projects`, `~/Public`, …) are the user's own files.
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
        if let entries = try? FileManager.default.contentsOfDirectory(at: h, includingPropertiesForKeys: Array(keys),
                                                                       options: [.skipsHiddenFiles]) {
            for e in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = e.lastPathComponent
                guard !name.hasPrefix("."), !Self.knownHomeFolders.contains(name),
                      let v = try? e.resourceValues(forKeys: keys),
                      v.isDirectory == true, v.isSymbolicLink != true else { continue }
                list.append((.documents, e))
            }
        }
        return list.map { (kind: $0.0, url: $0.1) }
    }
}

// MARK: - Analyzer

/// Measures what the startup disk is made of. It only READS; a typical home is done in a few seconds.
public actor StorageAnalyzer {
    private let roots: StorageRoots
    private let fullDiskAccess: Bool?
    private let capacityOverride: (total: Int64, free: Int64)?

    /// - Parameters:
    ///   - fullDiskAccess: nil = probe `Permissions.hasFullDiskAccess`. Without it `~/Library/Containers` and
    ///     `~/Library/Group Containers` are never entered: macOS would show a blocking "access data from other
    ///     apps" prompt. That data then falls into «Система и прочее».
    ///   - capacity: fixed volume numbers (tests); nil = ask the volume of `roots.volume`.
    public init(roots: StorageRoots = StorageRoots(), fullDiskAccess: Bool? = nil, capacity: (total: Int64, free: Int64)? = nil) {
        self.roots = roots
        self.fullDiskAccess = fullDiskAccess
        self.capacityOverride = capacity
    }

    public func breakdown(progress: ProgressHandler? = nil) async -> StorageBreakdown {
        let started = Date()
        let fda = fullDiskAccess ?? Permissions.hasFullDiskAccess
        let roots = self.roots
        let plan = roots.plan()
        let blocked = fda ? [] : FileWalker.appDataParents(home: roots.home).map { URL(fileURLWithPath: $0) }

        let sizes: [Int64] = await FileAnalyzer.runCancellable { outer in
            let monitor = WalkMonitor(totalUnits: plan.count, handler: progress, minInterval: 0.1, parent: outer)
            return ParallelTally(roots: plan.map(\.url), blocked: blocked, monitor: monitor).run()
        }
        var measured: [StorageCategory.Kind: Int64] = [:]
        for (i, entry) in plan.enumerated() { measured[entry.kind, default: 0] += sizes[i] }

        let cap = capacityOverride.map { (name: "Macintosh HD", total: $0.total, free: $0.free) }
            ?? Self.capacity(of: roots.volume)
        return StorageBreakdown.compose(volumeName: cap.name, total: cap.total, free: cap.free, measured: measured,
                                        measuredAt: Date(), duration: Date().timeIntervalSince(started),
                                        fullDiskAccess: fda)
    }

    /// Total and free space of the volume holding `url`. Free is `volumeAvailableCapacityForImportantUsage`:
    /// it includes purgeable space (local snapshots, optimised iCloud files, caches macOS may evict), exactly as
    /// Finder and Settings → Storage report "available". The raw `volumeAvailableCapacity` would look smaller.
    public static func capacity(of url: URL) -> (name: String, total: Int64, free: Int64) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey, .volumeLocalizedNameKey]
        let v = try? url.resourceValues(forKeys: keys)
        let total = Int64(v?.volumeTotalCapacity ?? 0)
        let free = v?.volumeAvailableCapacityForImportantUsage ?? Int64(v?.volumeAvailableCapacity ?? 0)
        return (v?.volumeLocalizedName ?? "Macintosh HD", total, free)
    }
}

// MARK: - Parallel tally

/// Sums allocated sizes of several folder trees at once with a shared LIFO work stack: every folder listing
/// is one job, so a single huge root (`~/Library`) is spread over all cores. Returns one total per root.
///
/// Folders are listed with `getattrlistbulk(2)`: name, type, device, inode and allocated size of many entries
/// per system call — several times faster than `URLResourceValues` (one stat-like call per entry plus Foundation
/// objects), which made this I/O-bound walk take 6 s on a 170 GB disk.
///
/// Rules: symlinks are not followed, other volumes are not entered, a directory reached twice (firmlinks,
/// nested roots) is counted once, and a directory that is itself one of the roots is left to that root.
final class ParallelTally: @unchecked Sendable {
    private struct Job { let path: String; let root: Int }

    private let roots: [URL]
    private let monitor: WalkMonitor
    private let visited = VisitedDirectories()
    /// Directories never entered by another root's walk: the roots themselves and the blocked folders.
    private var fenced = Set<VisitedDirectories.Identity>()
    private var rootIdentity: [VisitedDirectories.Identity?] = []

    private let cond = NSCondition()
    private var stack: [Job] = []
    private var pending = 0
    private var pendingPerRoot: [Int]
    private var totals: [Int64]

    private static let bufferSize = 256 * 1024

    init(roots: [URL], blocked: [URL], monitor: WalkMonitor) {
        self.roots = roots
        self.monitor = monitor
        self.pendingPerRoot = Array(repeating: 0, count: roots.count)
        self.totals = Array(repeating: 0, count: roots.count)
        for b in blocked { if let id = VisitedDirectories.identity(of: b) { fenced.insert(id) } }
    }

    func run(threads: Int = max(4, ProcessInfo.processInfo.activeProcessorCount)) -> [Int64] {
        // Identify every root first, so no walk can wander into another root (or a blocked folder) before it starts.
        for r in roots {
            var st = stat()
            let isDir = lstat(r.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR   // a symlinked root is skipped
            let id = isDir ? VisitedDirectories.Identity(device: Int64(st.st_dev), inode: UInt64(st.st_ino)) : nil
            rootIdentity.append(id)
            if let id { fenced.insert(id) }
        }
        let phase = "Анализ диска"
        for i in roots.indices {
            // Missing, a symlink, or the same folder as an earlier root: nothing (more) to measure.
            guard let id = rootIdentity[i], visited.insert(id) else {
                monitor.unitFinished(phase: phase)
                continue
            }
            stack.append(Job(path: roots[i].path, root: i))
            pending += 1
            pendingPerRoot[i] = 1
        }
        guard pending > 0 else { return totals }

        let group = DispatchGroup()
        for i in 0..<max(1, threads) {
            group.enter()
            let t = Thread { [self] in work(phase: phase); group.leave() }
            t.name = "StorageAnalyzer.worker.\(i)"
            t.qualityOfService = .userInitiated
            t.start()
        }
        group.wait()
        return totals
    }

    private func work(phase: String) {
        var local = [Int64](repeating: 0, count: roots.count)
        var subdirs: [String] = []
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            cond.lock()
            while stack.isEmpty && pending > 0 { cond.wait() }
            guard let job = stack.popLast() else { cond.unlock(); break }
            cond.unlock()

            subdirs.removeAll(keepingCapacity: true)
            local[job.root] += list(job, buffer: buffer, into: &subdirs)

            cond.lock()
            for s in subdirs { stack.append(Job(path: s, root: job.root)) }
            let delta = subdirs.count - 1
            pending += delta
            pendingPerRoot[job.root] += delta
            let rootDone = pendingPerRoot[job.root] == 0
            let allDone = pending == 0
            cond.unlock()

            if allDone { cond.broadcast() } else { for _ in 0..<min(subdirs.count, 8) { cond.signal() } }
            if rootDone { monitor.unitFinished(phase: phase) }
        }
        cond.lock()
        for i in totals.indices { totals[i] += local[i] }
        cond.unlock()
    }

    /// Sizes the files directly in `job.path` and collects the subfolders still to walk.
    private func list(_ job: Job, buffer: UnsafeMutableRawPointer, into subdirs: inout [String]) -> Int64 {
        if monitor.isCancelled { return 0 }
        let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        guard let rootDevice = rootIdentity[job.root]?.device else { return 0 }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FILEID)
        request.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)

        var total: Int64 = 0
        while true {
            let count = getattrlistbulk(fd, &request, buffer, Self.bufferSize, 0)
            if count <= 0 { break }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                // Attributes follow in bit order; each is present only when `returned` says so.
                var p = entry + 4
                let returned = p.loadUnaligned(as: attribute_set_t.self)
                p += MemoryLayout<attribute_set_t>.size
                var namePointer: UnsafeRawPointer?
                if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                    let ref = p.loadUnaligned(as: attrreference_t.self)
                    namePointer = p + Int(ref.attr_dataoffset)
                    p += MemoryLayout<attrreference_t>.size
                }
                var device = Int32(truncatingIfNeeded: rootDevice)
                if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 {
                    device = p.loadUnaligned(as: Int32.self); p += 4
                }
                var type: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    type = p.loadUnaligned(as: UInt32.self); p += 4
                }
                var fileID: UInt64?
                if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
                    fileID = p.loadUnaligned(as: UInt64.self); p += 8
                }

                if type == VREG.rawValue {
                    if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                        total += p.loadUnaligned(as: Int64.self)
                    }
                } else if type == VDIR.rawValue {
                    // Symlinks (VLNK) and special files are ignored; other volumes are not entered.
                    guard Int64(device) == rootDevice, let namePointer else { continue }
                    if let fileID {
                        let id = VisitedDirectories.Identity(device: Int64(device), inode: fileID)
                        if fenced.contains(id) || !visited.insert(id) { continue }
                    }
                    let name = String(cString: namePointer.assumingMemoryBound(to: CChar.self))
                    subdirs.append(job.path.hasSuffix("/") ? job.path + name : job.path + "/" + name)
                }
            }
        }
        return total
    }
}
