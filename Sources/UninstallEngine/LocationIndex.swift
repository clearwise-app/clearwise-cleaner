import Foundation

/// One directory entry of a search location, with the identifiers we could extract from it.
struct IndexEntry: Sendable, Hashable {
    let url: URL
    let location: Location
    /// File name as on disk.
    let name: String
    /// Name without decorations (".plist", ".savedState", ByHost UUID, crash-report timestamp…).
    let stem: String
    /// Identifiers for ID matching (original case): the stem itself, container metadata identifier,
    /// plug-in CFBundleIdentifier, launchd Label / AssociatedBundleIdentifiers, receipt PackageIdentifier.
    let ids: [String]
    /// launchd Program / ProgramArguments[0].
    let programPath: String?
    let isDirectory: Bool
    let modified: Date?
    /// Found one level inside a vendor folder (e.g. Application Support/Google/Chrome).
    let insideVendorFolder: Bool

    static func == (a: IndexEntry, b: IndexEntry) -> Bool { a.url == b.url }
    func hash(into h: inout Hasher) { h.combine(url) }
}

/// One-time listing of every search location. Building it costs a few dozen `readdir`s plus
/// a handful of small plist reads; matching then happens in memory for any number of apps.
final class LocationIndex: @unchecked Sendable {
    let roots: SearchRoots
    let entries: [Location: [IndexEntry]]
    let builtAt: Date
    private var vendorChildrenCache: [URL: [IndexEntry]] = [:]
    private let lock = NSLock()

    init(roots: SearchRoots) {
        self.roots = roots
        let locations = roots.locations
        let lists = concurrentMap(locations) { Self.list($0, roots: roots) }
        var map: [Location: [IndexEntry]] = [:]
        for (loc, list) in zip(locations, lists) { map[loc] = list }
        entries = map
        builtAt = Date()
    }

    var allEntries: [IndexEntry] { entries.values.flatMap { $0 } }

    /// Entries one level inside a vendor folder, listed on demand and cached.
    func vendorChildren(of entry: IndexEntry) -> [IndexEntry] {
        lock.lock()
        if let cached = vendorChildrenCache[entry.url] { lock.unlock(); return cached }
        lock.unlock()
        let children = Self.list(entry.location, at: entry.url, roots: roots, insideVendor: true)
        lock.lock()
        vendorChildrenCache[entry.url] = children
        lock.unlock()
        return children
    }

    // MARK: - Listing

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]

    static func list(_ location: Location, roots: SearchRoots) -> [IndexEntry] {
        list(location, at: location.url, roots: roots, insideVendor: false)
    }

    static func list(_ location: Location, at dir: URL, roots: SearchRoots, insideVendor: Bool) -> [IndexEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let isHome = location.style == .dotFolders && dir.standardizedFileURL == roots.home.standardizedFileURL
        var out: [IndexEntry] = []
        out.reserveCapacity(names.count)
        for name in names {
            if location.style == .dotFolders {
                if isHome {
                    guard name.hasPrefix("."), name.count > 1, name != ".Trash", name != ".config" else { continue }
                } else if name.hasPrefix(".") { continue }
            } else if name.hasPrefix(".") || name == "Icon\r" {
                continue
            }
            let url = dir.appendingPathComponent(name)
            let v = try? url.resourceValues(forKeys: Set(keys))
            let isDir = (v?.isDirectory ?? false) && v?.isSymbolicLink != true
            if let entry = makeEntry(url: url, name: name, isDir: isDir, modified: v?.contentModificationDate,
                                     location: location, insideVendor: insideVendor) {
                out.append(entry)
            }
        }
        return out
    }

    private static func dropSuffix(_ s: String, _ suffix: String) -> String? {
        s.lowercased().hasSuffix(suffix.lowercased()) ? String(s.dropLast(suffix.count)) : nil
    }

    private static let droppableFileExtensions: Set<String> = [
        "log", "plist", "db", "sqlite", "sqlite3", "txt", "json", "ips", "crash", "lock", "binarycookies", "diag",
    ]

    static func makeEntry(url: URL, name: String, isDir: Bool, modified: Date?, location: Location,
                          insideVendor: Bool) -> IndexEntry? {
        var stem = name
        var ids: [String] = []
        var program: String?

        switch location.style {
        case .plain:
            if !isDir, let ext = name.split(separator: ".").last.map(String.init),
               name.contains("."), droppableFileExtensions.contains(ext.lowercased()) {
                stem = String(name.dropLast(ext.count + 1))
            }
        case .preferences:
            guard !isDir, let s = dropSuffix(name, ".plist") else { return nil }
            stem = s
        case .byHost:
            guard !isDir, var s = dropSuffix(name, ".plist") else { return nil }
            // com.foo.app.<UUID or 12-hex MAC>.plist
            if let dot = s.lastIndex(of: ".") {
                let tail = String(s[s.index(after: dot)...])
                if NameRules.isUUID(tail) || tail.range(of: #"^[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil {
                    s = String(s[..<dot])
                }
            }
            stem = s
        case .savedState:
            stem = dropSuffix(name, ".savedState") ?? name
        case .cookies:
            stem = dropSuffix(name, ".binarycookies") ?? name
        case .containers:
            if NameRules.isUUID(name) {
                let meta = url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
                if let id = BundleInfo.readPlist(meta)?["MCMMetadataIdentifier"] as? String, !id.isEmpty {
                    stem = id
                } else {
                    return nil // unknown UUID container: never guess
                }
            }
        case .groupContainers:
            break
        case .launchd:
            guard let s = dropSuffix(name, ".plist") else { return nil }
            stem = s
            if let plist = BundleInfo.readPlist(url) {
                if let label = plist["Label"] as? String { ids.append(label) }
                if let assoc = plist["AssociatedBundleIdentifiers"] as? [String] { ids += assoc }
                if let assoc = plist["AssociatedBundleIdentifiers"] as? String { ids.append(assoc) }
                program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
            }
        case .receipts:
            if let s = dropSuffix(name, ".plist") {
                stem = s
                if let pkg = BundleInfo.readPlist(url)?["PackageIdentifier"] as? String { ids.append(pkg) }
            } else if let s = dropSuffix(name, ".bom") {
                stem = s
            } else {
                return nil
            }
        case .bundles:
            if let dot = name.lastIndex(of: "."), dot != name.startIndex {
                stem = String(name[..<dot])
            }
            if isDir, let id = BundleInfo.bundleIdentifier(of: url) { ids.append(id) }
        case .crashReports:
            guard !isDir,
                  let r = name.range(of: #"[-_]\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { return nil }
            stem = String(name[..<r.lowerBound])
            return IndexEntry(url: url, location: location, name: name, stem: stem, ids: [],
                              programPath: nil, isDirectory: isDir, modified: modified, insideVendorFolder: false)
        case .dotFolders:
            stem = name.hasPrefix(".") ? String(name.dropFirst()) : name
            return IndexEntry(url: url, location: location, name: name, stem: stem, ids: [],
                              programPath: nil, isDirectory: isDir, modified: modified, insideVendorFolder: false)
        }
        ids.insert(stem, at: 0)
        return IndexEntry(url: url, location: location, name: name, stem: stem, ids: ids, programPath: program,
                          isDirectory: isDir, modified: modified, insideVendorFolder: insideVendor)
    }
}
