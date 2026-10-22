import Foundation
import CleanerKit

/// A folder or file of the «Хранилище» screen with its size on disk.
public struct StorageEntry: Identifiable, Sendable, Equatable {
    public let url: URL
    public let bytes: Int64
    /// A folder that can be opened (not a package such as an `.app`).
    public let isFolder: Bool
    /// A human name instead of the folder's (parts of «Система и прочее»: «macOS», «Подкачка и сон»…).
    public var title: String?
    /// One line on what it is, shown instead of the location.
    public var detail: String?
    public var id: String { url.path }
    public var name: String { title ?? FileManager.default.displayName(atPath: url.path) }

    public init(url: URL, bytes: Int64, isFolder: Bool, title: String? = nil, detail: String? = nil) {
        self.url = url
        self.bytes = bytes
        self.isFolder = isFolder
        self.title = title
        self.detail = detail
    }
}

/// Read-only drill-down behind the «Хранилище» screen: what each category of `StorageBreakdown` is made of,
/// one folder level at a time, measured with the same walk (and the same fences) as the breakdown itself.
public struct StorageExplorer: Sendable {
    public var roots: StorageRoots
    /// Without it other apps' containers are never opened: macOS would show a blocking consent prompt.
    public var fullDiskAccess: Bool

    public init(roots: StorageRoots = StorageRoots(), fullDiskAccess: Bool) {
        self.roots = roots
        self.fullDiskAccess = fullDiskAccess
    }

    /// What a category is made of before sizing. Categories with several folders (Документы: Desktop, Documents,
    /// Downloads…) list those folders; a single folder (Данные приложений = ~/Library) and the Applications
    /// folders are opened right away, so the first level already shows apps and app data.
    /// «Система и прочее» has no folders of its own (see `systemParts()`).
    public func topLevel(of kind: StorageCategory.Kind) -> [URL] {
        guard kind != .system else { return [] }
        let own = roots.plan().filter { $0.kind == kind }.map(\.url).filter { Self.isDirectory($0) }
        if kind == .apps || own.count == 1 { return own.flatMap { children(of: $0) } }
        return own
    }

    /// Direct children of `folder`. Folders that belong to another category (`~/Library/Developer` inside
    /// `~/Library`) are left out, like in the breakdown; so are symlinks and, without Full Disk Access,
    /// `~/Library/Containers` and `~/Library/Group Containers`.
    public func children(of folder: URL) -> [URL] {
        let folderPath = folder.standardizedFileURL.path
        let blocked = blockedPaths
        guard !blocked.contains(folderPath) else { return [] }
        let otherRoots = Set(roots.plan().map { $0.url.standardizedFileURL.path }).subtracting([folderPath])
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])) ?? []
        return items.filter { url in
            let path = url.standardizedFileURL.path
            if otherRoots.contains(path) || blocked.contains(path) { return false }
            return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        }
    }

    /// One level of the screen, measured: `folder` inside the category, or the category's top level when nil.
    /// Runs off the caller's actor (listing and sizing touch the disk). Cancellable.
    public func contents(of kind: StorageCategory.Kind, in folder: URL?) async -> [StorageEntry] {
        if folder == nil && kind == .system { return await systemParts() }
        return await measure(folder.map { children(of: $0) } ?? topLevel(of: kind))
    }

    // MARK: «Система и прочее»

    /// APFS volumes of the startup disk that hold macOS itself (their used space comes from the file system).
    static let systemVolumes: [(paths: [String], title: String, detail: String)] = [
        (["/"], "macOS", String(localized: "Сама система. Защищена от изменений, удалить нельзя", bundle: .module)),
        (["/System/Volumes/Preboot", "/System/Volumes/Update", "/System/Volumes/iSCPreboot",
          "/System/Volumes/xarts", "/System/Volumes/Hardware"],
         String(localized: "Загрузка и обновления", bundle: .module),
         String(localized: "Файлы запуска macOS и подготовленные обновления", bundle: .module)),
        (["/System/Volumes/VM"], String(localized: "Подкачка и сон", bundle: .module),
         String(localized: "Память, выгруженная на диск, и образ режима сна. macOS управляет сама", bundle: .module)),
    ]

    /// Folders outside every category, with what they are.
    static let systemFolders: [(path: String, title: String, detail: String)] = [
        ("/Library", String(localized: "Общая библиотека", bundle: .module),
         String(localized: "Данные программ для всех пользователей Mac", bundle: .module)),
        ("/private/var", String(localized: "Служебные данные macOS", bundle: .module),
         String(localized: "Журналы, кэши и временные файлы системы", bundle: .module)),
        ("/opt/homebrew", "Homebrew", String(localized: "Программы, установленные через brew", bundle: .module)),
        ("/usr/local", "/usr/local", String(localized: "Консольные программы (Homebrew на Intel)", bundle: .module)),
        ("/Users/Shared", String(localized: "Общая папка", bundle: .module),
         String(localized: "Файлы, доступные всем пользователям", bundle: .module)),
    ]

    /// What «Система и прочее» is made of, as far as macOS lets it be measured: the system volumes, shared
    /// folders outside the home, and hidden items of the home that no category counts (`~/.claude`, `~/.zsh_history`).
    /// The rest (local Time Machine snapshots, APFS metadata, other users' files) cannot be listed.
    public func systemParts() async -> [StorageEntry] {
        var volumes: [StorageEntry] = []
        for v in Self.systemVolumes {
            let bytes = v.paths.compactMap(Self.volumeSpaceUsed).reduce(0, +)
            volumes.append(StorageEntry(url: URL(fileURLWithPath: v.paths[0]), bytes: bytes, isFolder: false,
                                        title: v.title, detail: v.detail))
        }
        let fm = FileManager.default
        let folders = Self.systemFolders.filter { fm.fileExists(atPath: $0.path) }
        let info = Dictionary(folders.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var urls = folders.map { URL(fileURLWithPath: $0.path) }
        urls += uncountedHomeItems()
        let measured = await measure(urls).map { e -> StorageEntry in
            guard let i = info[e.url.path] else {
                return StorageEntry(url: e.url, bytes: e.bytes, isFolder: e.isFolder,
                                    detail: String(localized: "Скрытое в домашней папке", bundle: .module))
            }
            return StorageEntry(url: e.url, bytes: e.bytes, isFolder: e.isFolder, title: i.title, detail: i.detail)
        }
        // Dotfiles of a few KB are not where the space went.
        let worthShowing = measured.filter { info[$0.url.path] != nil || $0.bytes >= 1_000_000 }
        return (volumes.filter { $0.bytes > 0 } + worthShowing).sorted { $0.bytes > $1.bytes }
    }

    /// Items of the home that no category measures: hidden folders other than the developer ones and the Trash,
    /// and loose files (visible folders are «Документы»).
    func uncountedHomeItems() -> [URL] {
        let planned = Set(roots.plan().map { $0.url.standardizedFileURL.path })
        let library = roots.home.appendingPathComponent("Library").standardizedFileURL.path
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: roots.home, includingPropertiesForKeys: Array(keys), options: [])) ?? []
        return items.filter { url in
            let path = url.standardizedFileURL.path
            guard !planned.contains(path), path != library,
                  let v = try? url.resourceValues(forKeys: keys), v.isSymbolicLink != true else { return false }
            return url.lastPathComponent.hasPrefix(".") || v.isDirectory != true
        }
    }

    /// Space used by one APFS volume (not the whole container), from `getattrlist(ATTR_VOL_SPACEUSED)`.
    static func volumeSpaceUsed(_ path: String) -> Int64? {
        // Only a mounted volume of the startup disk's APFS container: an unmounted path would report `/`
        // (counted twice), and xART / Hardware live in another container on Apple silicon.
        guard let mount = mountInfo(path), mount.onName == path || path == "/",
              let root = mountInfo("/"), container(of: mount.fromName) == container(of: root.fromName) else { return nil }
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        // Packed reply: u_int32_t length, then the off_t (4-byte aligned, hence the unaligned load).
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { buffer.deallocate() }
        guard getattrlist(path, &attrs, buffer, 64, 0) == 0 else { return nil }
        return max(0, buffer.loadUnaligned(fromByteOffset: 4, as: Int64.self))
    }

    private static func mountInfo(_ path: String) -> (onName: String, fromName: String)? {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return nil }
        let on = withUnsafeBytes(of: st.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let from = withUnsafeBytes(of: st.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return (on, from)
    }

    /// `/dev/disk3s1s1` → `disk3` (the APFS container's synthesized disk).
    private static func container(of device: String) -> String {
        let name = device.split(separator: "/").last.map(String.init) ?? device
        guard name.hasPrefix("disk") else { return name }
        let rest = name.dropFirst(4)
        return "disk" + rest.prefix { $0.isNumber }
    }

    /// Sizes `urls` (folders in parallel, like the breakdown), drops empty ones, biggest first. Cancellable.
    public func measure(_ urls: [URL]) async -> [StorageEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
        // A blocked folder is never measured, even when passed in directly (roots are always walked).
        let fenced = blockedPaths
        let urls = urls.filter { !fenced.contains($0.standardizedFileURL.path) }
        var folders: [URL] = []
        var openable: [Bool] = []
        var files: [URL] = []
        for url in urls {
            let v = try? url.resourceValues(forKeys: keys)
            if v?.isDirectory == true {
                folders.append(url)
                openable.append(v?.isPackage != true)
            } else {
                files.append(url)
            }
        }
        // Other categories' folders (`/Library/Developer` inside `/Library`) are never counted twice.
        let blocked = (blockedPaths.map { URL(fileURLWithPath: $0) } + roots.plan().map(\.url))
        let toTally = folders
        let folderSizes: [Int64] = toTally.isEmpty ? [] : await FileAnalyzer.runCancellable { outer in
            let monitor = WalkMonitor(totalUnits: toTally.count, handler: nil, minInterval: 0.1, parent: outer)
            return ParallelTally(roots: toTally, blocked: blocked, monitor: monitor).run()
        }
        guard !Task.isCancelled else { return [] }
        var entries = zip(folders, zip(folderSizes, openable)).map {
            StorageEntry(url: $0.0, bytes: $0.1.0, isFolder: $0.1.1)
        }
        entries += files.map { StorageEntry(url: $0, bytes: FileSizer.allocatedSize(of: $0), isFolder: false) }
        return entries.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
    }

    /// Without Full Disk Access: other apps' containers, and the per-app cache folders macOS keeps under
    /// `/private/var/folders` (opening them can bring up the same consent prompt).
    /// Spelled the way `standardizedFileURL` spells paths (it drops `/private`), so comparisons really match.
    private var blockedPaths: Set<String> {
        guard !fullDiskAccess else { return [] }
        let raw = FileWalker.appDataParents(home: roots.home).union(["/private/var/folders"])
        return Set(raw.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
