import Foundation
import CleanerKit

// MARK: - Shared walk state (cancellation + throttled progress)

/// Thread-safe helper shared by the concurrent walkers: cancellation flag and progress throttling.
final class WalkMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledFlag = false
    private var lastReport = Date.distantPast
    private var completed = 0
    private let total: Int
    private let handler: ProgressHandler?
    private let minInterval: TimeInterval

    /// A monitor that also reports cancellation of `parent` (the one the task-cancellation handler flips).
    private let parent: WalkMonitor?

    init(totalUnits: Int, handler: ProgressHandler?, minInterval: TimeInterval = 0.1, parent: WalkMonitor? = nil) {
        self.total = max(1, totalUnits)
        self.handler = handler
        self.minInterval = minInterval
        self.parent = parent
    }

    var isCancelled: Bool {
        lock.lock(); let own = cancelledFlag; lock.unlock()
        return own || (parent?.isCancelled ?? false)
    }
    func cancel() { lock.lock(); cancelledFlag = true; lock.unlock() }

    /// Reports at most every `minInterval` seconds.
    func report(phase: String, path: String?) {
        guard let handler else { return }
        lock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= minInterval else { lock.unlock(); return }
        lastReport = now
        let fraction = Double(completed) / Double(total)
        lock.unlock()
        handler(ScanProgress(phase: phase, fraction: min(fraction, 0.99), currentPath: path))
    }

    func unitFinished(phase: String) {
        lock.lock()
        completed += 1
        let fraction = Double(completed) / Double(total)
        lastReport = Date()
        lock.unlock()
        handler?(ScanProgress(phase: phase, fraction: min(fraction, 1), currentPath: nil))
    }

    /// Unconditional report with an explicit fraction (for multi-stage pipelines).
    func force(phase: String, fraction: Double, path: String? = nil) {
        handler?(ScanProgress(phase: phase, fraction: min(max(fraction, 0), 1), currentPath: path))
    }
}

// MARK: - Walker

/// A file (or package treated as one item) that survived the cheap filters of the walk.
struct WalkedFile {
    let url: URL
    /// Allocated size on disk (whole subtree for packages).
    let allocatedSize: Int64
    /// Logical size in bytes (0 for packages).
    let logicalSize: Int64
    let modified: Date?
    let isPackage: Bool
}

/// Fast recursive walk with prefetched resource keys. It only READS.
enum FileWalker {
    /// Folders never descended into (and never reported).
    static let skippedDirectoryNames: Set<String> = ["node_modules", ".git", ".svn", ".hg"]

    /// Libraries whose deletion would be catastrophic: skipped completely, as if they were not there.
    static let skippedPackageExtensions: Set<String> = [
        "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary",
        "musiclibrary", "tvlibrary", "imovielibrary",
    ]

    /// Other apps' data folders. Opening them without Full Disk Access makes macOS ask the user for consent
    /// (the call blocks until answered), and nothing in there is a file the user would clean up by hand.
    static var appDataParents: Set<String> { appDataParents(home: SafetyGuard.home) }

    static func appDataParents(home: URL) -> Set<String> {
        let lib = home.appendingPathComponent("Library").path
        return [lib + "/Containers", lib + "/Group Containers"]
    }

    // MARK: Protected areas

    /// Home-relative folders whose whole subtree is off limits to the walk. `SafetyGuard` protects these
    /// as *prefixes* ("everything inside"); the folders such as `~/Documents` that it merely refuses to
    /// remove *themselves* are NOT areas: the walk must go through them to reach the user's files.
    private static let protectedHomeAreas = [
        "Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage", "Library/Messages",
        "Library/Mail", "Library/Accounts", "Library/Calendars", "Library/Photos",
        "Library/Application Support/AddressBook", "Library/Application Support/com.apple.TCC",
    ]
    private static let protectedSystemAreas = [
        "/System", "/bin", "/sbin", "/usr/bin", "/usr/lib", "/usr/libexec", "/usr/sbin", "/usr/share",
        "/private/etc", "/private/var/vm", "/Library/Apple",
    ]

    /// True when `url` is a protected area or lies inside one (Keychains, Mail, Messages, iCloud Drive,
    /// CloudStorage, system folders…). The walk neither descends into nor reports anything there.
    ///
    /// This is deliberately NOT `SafetyGuard.isProtected(url)`, which answers a different question —
    /// "may this exact folder be removed?" — and is true for `~/Documents`, `~/Desktop`, `~/Downloads`…
    static func isInProtectedArea(_ url: URL, home: URL = SafetyGuard.home) -> Bool {
        let path = url.standardizedFileURL.path
        let withSlash = path.hasSuffix("/") ? path : path + "/"
        let h = home.standardizedFileURL.path
        let prefixes = protectedHomeAreas.map { h + "/" + $0 + "/" } + protectedSystemAreas.map { $0 + "/" }
        if prefixes.contains(where: { withSlash.hasPrefix($0) || withSlash.hasPrefix("/private" + $0) }) { return true }
        // Whatever else SafetyGuard protects *inside* a folder (it also resolves symlinks / `/private`).
        return SafetyGuard.isProtected(url.appendingPathComponent("_probe_"))
    }

    /// `~/Library` is app data, hidden by macOS, and never a place for user files; when its "hidden" flag
    /// was cleared the walk must still not wander into it from a parent root such as `~`.
    static func isLibraryOfHome(_ url: URL, home: URL) -> Bool {
        url.standardizedFileURL.path == home.standardizedFileURL.appendingPathComponent("Library").path
    }

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isRegularFileKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey,
    ]
    private static let keySet = Set(keys)

    struct Options {
        /// Files whose allocated size is below this are dropped before any further work.
        var minAllocatedSize: Int64
        /// Report packages (`.app`, `.xcodeproj`, …) as single items. When false they are skipped.
        var includePackages: Bool
        /// Label for progress.
        var phase: String
        /// The user's home folder, used to recognise protected areas. Tests point it at a fake home.
        var home: URL = SafetyGuard.home
    }

    static func displayPhase(for root: URL) -> String {
        switch root.lastPathComponent {
        case "Documents": return "Документы"
        case "Desktop": return "Рабочий стол"
        case "Downloads": return "Загрузки"
        case "Movies": return "Фильмы"
        case "Music": return "Музыка"
        case "Pictures": return "Изображения"
        default: return root.lastPathComponent.isEmpty ? "Диск" : root.lastPathComponent
        }
    }

    /// Removes roots that live inside another root so nothing is scanned (and reported) twice.
    static func normalizedRoots(_ roots: [URL]) -> [URL] {
        let sorted = Array(Set(roots.map { $0.standardizedFileURL })).sorted { $0.path.count < $1.path.count }
        var kept: [URL] = []
        for r in sorted where !kept.contains(where: { r.path == $0.path || r.path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }) {
            kept.append(r)
        }
        return kept
    }

    static func walk(root: URL, options: Options, monitor: WalkMonitor, visit: (WalkedFile) -> Void) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return }
        // A root that itself lies in a protected area (Keychains, iCloud Drive, Mail…) is never scanned.
        if isInProtectedArea(root, home: options.home) { return }

        let rootVolume = try? root.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles], errorHandler: { _, _ in true }
        ) else { return }

        let appData = appDataParents(home: options.home)
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited & 0x3F == 0 {
                if monitor.isCancelled { return }
                monitor.report(phase: options.phase, path: url.path)
            }
            guard let v = try? url.resourceValues(forKeys: keySet) else { continue }
            if v.isSymbolicLink == true { continue }

            if v.isDirectory == true {
                let name = url.lastPathComponent
                if skippedDirectoryNames.contains(name) { enumerator.skipDescendants(); continue }
                if (name == "Containers" || name == "Group Containers"), appData.contains(url.path) {
                    enumerator.skipDescendants(); continue
                }

                if v.isPackage == true {
                    enumerator.skipDescendants()
                    guard options.includePackages else { continue }
                    if skippedPackageExtensions.contains(url.pathExtension.lowercased()) { continue }
                    if isInProtectedArea(url, home: options.home) || SafetyGuard.isProtected(url) { continue }
                    let size = FileSizer.allocatedSize(of: url)
                    guard size >= options.minAllocatedSize else { continue }
                    visit(WalkedFile(url: url, allocatedSize: size, logicalSize: 0,
                                     modified: v.contentModificationDate, isPackage: true))
                    continue
                }

                // Plain folder: keep out of protected areas and other volumes. Descent is decided by the AREA a
                // folder belongs to — not by `SafetyGuard.isProtected`, which also flags ~/Documents, ~/Desktop…
                // (folders that must not be removed, but whose contents are exactly what we are looking for).
                if isInProtectedArea(url, home: options.home) || isLibraryOfHome(url, home: options.home) {
                    enumerator.skipDescendants(); continue
                }
                if let rootVolume,
                   let vol = (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier,
                   !vol.isEqual(rootVolume) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard v.isRegularFile == true else { continue }
            let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            guard size >= options.minAllocatedSize else { continue }
            visit(WalkedFile(url: url, allocatedSize: size, logicalSize: Int64(v.fileSize ?? 0),
                             modified: v.contentModificationDate, isPackage: false))
        }
    }

    /// True for iCloud items that are not fully downloaded (placeholders / dataless).
    static func isICloudPlaceholder(_ url: URL) -> Bool {
        if url.lastPathComponent.hasSuffix(".icloud") { return true }
        guard let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              v.isUbiquitousItem == true else { return false }
        return v.ubiquitousItemDownloadingStatus != .current
    }
}
