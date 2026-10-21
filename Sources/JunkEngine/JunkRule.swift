import Foundation
import CleanerKit

/// Stable ids of the junk categories (`JunkCategory.id`).
public enum JunkCategoryID {
    public static let userCaches = "user-caches"
    public static let userLogs = "user-logs"
    public static let crashReports = "crash-reports"
    public static let systemLogs = "system-logs"
    public static let browserCaches = "browser-caches"
    public static let xcodeDerivedData = "xcode-derived-data"
    public static let xcodeArchives = "xcode-archives"
    public static let xcodeDeviceSupport = "xcode-device-support"
    public static let simulatorCaches = "simulator-caches"
    public static let deviceLogs = "xcode-device-logs"
    public static let packageCaches = "dev-package-caches"
    public static let cargoRegistry = "cargo-registry"
    public static let jetbrainsCaches = "jetbrains-caches"
    public static let temporaryFiles = "temporary-files"
    public static let installers = "old-installers"
    public static let mailDownloads = "mail-downloads"
    public static let iosBackups = "ios-backups"
    public static let brokenPreferences = "broken-preferences"
    public static let brokenLaunchAgents = "broken-launch-agents"
    public static let trash = "trash"
}

/// Something a rule wants to offer as one removable item, before sizing.
struct JunkCandidate: Sendable {
    let url: URL
    /// Optional human-readable label (browser name, device name, missing executable…).
    var note: String?

    init(_ url: URL, note: String? = nil) {
        self.url = url
        self.note = note
    }
}

/// A folder (or file) a rule looks at, and how it is turned into items.
struct JunkLocation: Sendable {
    enum Base: Sendable { case home, absolute, temporary }
    enum Mode: Sendable {
        /// The path itself is one item.
        case itself
        /// Each direct child is an item (so the user can deselect individual apps' data).
        case children
        /// Each child of each child is an item (e.g. `Archives/<date>/<name>.xcarchive`).
        case grandchildren
    }

    var base: Base
    var path: String
    var mode: Mode
    var includeHidden = false

    static func home(_ path: String, _ mode: Mode = .children, includeHidden: Bool = false) -> JunkLocation {
        JunkLocation(base: .home, path: path, mode: mode, includeHidden: includeHidden)
    }

    static func absolute(_ path: String, _ mode: Mode = .children) -> JunkLocation {
        JunkLocation(base: .absolute, path: path, mode: mode)
    }

    static func temporary(_ mode: Mode = .children) -> JunkLocation {
        JunkLocation(base: .temporary, path: "", mode: mode)
    }

    func resolve(in env: JunkEnvironment) -> URL? {
        switch base {
        case .home: return env.homePath(path)
        case .absolute: return URL(fileURLWithPath: path)
        case .temporary:
            guard let root = env.temporaryRoot else { return nil }
            return path.isEmpty ? root : root.appendingPathComponent(path)
        }
    }
}

/// Case-insensitive name filter for top-level entries.
enum NameMatch: Sendable {
    case exact(String)
    case prefix(String)
    case suffix(String)

    func matches(_ name: String) -> Bool {
        let n = name.lowercased()
        switch self {
        case .exact(let s): return n == s.lowercased()
        case .prefix(let s): return n.hasPrefix(s.lowercased())
        case .suffix(let s): return n.hasSuffix(s.lowercased())
        }
    }
}

/// Declarative description of one junk category. Adding a category = adding one `JunkRule` to `JunkCatalog`.
struct JunkRule: Sendable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let risk: RiskLevel
    /// Ticked after a scan even though `risk` is not `.safe`: regenerable, just slow or costly to recreate.
    /// Nil = only `.safe` rules are.
    var selectedByDefault: Bool? = nil
    /// Progress label shown while this rule is processed.
    var phase: String
    /// Rules with higher priority claim paths first. Catch-all rules (all of `~/Library/Caches`)
    /// use 0 so that specific rules (browser caches, Homebrew…) own their folders and nothing is counted twice.
    var priority: Int = 1
    var locations: [JunkLocation] = []
    /// Custom discovery for rules that need to look inside files (broken plists, launch agents…).
    var collector: (@Sendable (JunkEnvironment) -> [JunkCandidate])? = nil
    /// Entries never offered, matched against the item's name.
    var excludedNames: [NameMatch] = []
    /// Skip items whose content changed within `JunkEnvironment.activeWindow` (being written right now).
    var skipsActiveItems = false
    /// Only offer items untouched for at least this long.
    var minimumAge: TimeInterval? = nil
    /// Skip trees that contain UNIX sockets (a running process uses them).
    var skipsSockets = false
    /// Only offer items the current user can remove without admin rights.
    var requiresUserDeletable = false
    /// Keep zero-byte items (a 0-byte plist is exactly what "broken" looks like).
    var keepsEmptyItems = false
    /// Fill `FileItem.lastUsed` from Spotlight (only for user files where it matters).
    var wantsLastUsed = false
    /// Sort items newest first instead of biggest first.
    var sortsNewestFirst = false

    init(id: String, title: String, detail: String, symbol: String, risk: RiskLevel, phase: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.risk = risk
        self.phase = phase ?? title
    }

    func excludes(_ name: String, env: JunkEnvironment) -> Bool {
        if env.isOwnFile(name) { return true }
        if name == ".DS_Store" || name == ".localized" { return true }
        return excludedNames.contains { $0.matches(name) }
    }

    /// Raw candidates before cross-category de-duplication and sizing. Cheap: directory listings only.
    func candidates(in env: JunkEnvironment) -> [JunkCandidate] {
        var result: [JunkCandidate] = []
        for location in locations {
            guard let root = location.resolve(in: env) else { continue }
            switch location.mode {
            case .itself:
                if FS.exists(root) { result.append(JunkCandidate(root)) }
            case .children:
                result += FS.children(of: root, includeHidden: location.includeHidden).map { JunkCandidate($0) }
            case .grandchildren:
                for child in FS.children(of: root, includeHidden: location.includeHidden) where FS.isDirectory(child) {
                    result += FS.children(of: child, includeHidden: location.includeHidden).map { JunkCandidate($0) }
                }
            }
        }
        if let collector { result += collector(env) }
        return result.filter { !excludes($0.url.lastPathComponent, env: env) }
    }
}

/// Small read-only file system helpers. Unreadable folders (no Full Disk Access) yield nothing.
enum FS {
    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    static func isDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func children(of url: URL, includeHidden: Bool = false) -> [URL] {
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        let list = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: options)) ?? []
        return list.map { $0.standardizedFileURL }.sorted { $0.path < $1.path }
    }

    static func canList(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    /// Comparison key: macOS volumes are case-insensitive by default, so `Caches/Yarn` and `Caches/yarn`
    /// must be treated as the same folder.
    static func key(_ url: URL) -> String {
        url.standardizedFileURL.path.lowercased()
    }
}
