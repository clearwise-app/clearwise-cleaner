import Foundation
import CleanerKit

/// Lists apps installed in /Applications (one level of sub-folders, e.g. Utilities, Setapp) and ~/Applications.
public actor AppInventory {
    let roots: SearchRoots

    public init() { roots = .live }
    init(roots: SearchRoots) { self.roots = roots }

    public func installedApps(progress: ProgressHandler? = nil) async -> [InstalledApp] {
        progress?(ScanProgress(phase: "Поиск приложений", fraction: 0))
        let bundles = Self.appBundleURLs(in: roots.applicationDirs)
        let total = max(bundles.count, 1)

        let apps: [InstalledApp] = await withTaskGroup(of: InstalledApp?.self) { group in
            var results: [InstalledApp] = []
            var iterator = bundles.makeIterator()
            var done = 0
            // Bounded concurrency: sizing walks every file inside each bundle.
            for _ in 0..<min(8, bundles.count) {
                if let url = iterator.next() { group.addTask { Self.describe(url, sized: true) } }
            }
            while let app = await group.next() {
                done += 1
                if let app { results.append(app) }
                progress?(ScanProgress(phase: "Анализ приложений", fraction: Double(done) / Double(total),
                                       currentPath: app?.url.path))
                if let url = iterator.next() { group.addTask { Self.describe(url, sized: true) } }
            }
            return results
        }
        progress?(ScanProgress(phase: "Готово", fraction: 1))
        return Self.sorted(apps)
    }

    static func sorted(_ apps: [InstalledApp]) -> [InstalledApp] {
        apps.sorted { a, b in
            let r = a.name.localizedStandardCompare(b.name)
            return r == .orderedSame ? a.url.path < b.url.path : r == .orderedAscending
        }
    }

    /// Fast inventory without sizes / Spotlight dates (used internally to know "who else is installed").
    static func lightweightApps(roots: SearchRoots) -> [InstalledApp] {
        let urls = appBundleURLs(in: roots.applicationDirs)
        return sorted(concurrentMap(urls) { describe($0, sized: false) }.compactMap { $0 })
    }

    /// `.app` bundles directly in each root, plus one level into plain sub-folders.
    /// Never descends into a bundle, so helper apps nested inside other apps are skipped.
    static func appBundleURLs(in roots: [URL]) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        var seen = Set<String>()
        var result: [URL] = []

        func add(_ url: URL) {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted { result.append(url.standardizedFileURL) }
        }
        func children(_ dir: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        }

        for root in roots {
            for item in children(root) {
                let v = try? item.resourceValues(forKeys: Set(keys))
                if v?.isSymbolicLink == true { continue }
                if item.pathExtension.lowercased() == "app" {
                    add(item)
                } else if v?.isDirectory == true, v?.isPackage != true {
                    for sub in children(item) where sub.pathExtension.lowercased() == "app" {
                        if (try? sub.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
                        add(sub)
                    }
                }
            }
        }
        return result
    }

    static func describe(_ url: URL, sized: Bool) -> InstalledApp? {
        guard let info = BundleInfo(appURL: url) else { return nil }
        let bundleID = info.bundleID
        let path = url.standardizedFileURL.path
        let isSystem = (bundleID?.lowercased().hasPrefix("com.apple.") ?? false)
            || path.hasPrefix("/System/")
            || url.lastPathComponent == "Safari.app"
        let isAppStore = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
        return InstalledApp(
            url: url,
            name: info.name,
            bundleID: bundleID,
            version: info.version,
            teamID: CodeSigning.teamID(for: url),
            size: sized ? FileSizer.allocatedSize(of: url) : 0,
            lastUsed: sized ? FileMetadata.lastUsedDate(of: url) : nil,
            isSystemApp: isSystem,
            isAppStore: isAppStore
        )
    }
}
