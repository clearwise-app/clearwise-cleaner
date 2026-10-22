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
        return Self.sorted(Self.disambiguated(apps))
    }

    /// Two copies with the same display name (Xcode + Xcode-beta) are shown by their file name.
    static func disambiguated(_ apps: [InstalledApp]) -> [InstalledApp] {
        let counts = Dictionary(apps.map { ($0.name, 1) }, uniquingKeysWith: +)
        return apps.map { app in
            let fileName = app.url.deletingPathExtension().lastPathComponent
            guard counts[app.name, default: 0] > 1, fileName != app.name else { return app }
            return InstalledApp(url: app.url, name: fileName, bundleID: app.bundleID, version: app.version,
                                teamID: app.teamID, size: app.size, lastUsed: app.lastUsed,
                                isSystemApp: app.isSystemApp, isAppStore: app.isAppStore)
        }
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

    /// Installed apps without sizes, Spotlight dates or code signatures: fast enough to run on demand.
    public static func quickList() -> [InstalledApp] {
        let urls = appBundleURLs(in: SearchRoots.live.applicationDirs)
        return sorted(disambiguated(concurrentMap(urls) { describe($0, sized: false, readTeam: false) }.compactMap { $0 }))
    }

    /// `.app` bundles directly in each root, plus `folderDepth` levels of plain sub-folders (1 for the
    /// visible inventory: Utilities, Setapp…). Never descends into a bundle, so helper apps nested inside
    /// other apps are skipped.
    static func appBundleURLs(in roots: [URL], folderDepth: Int = 1) -> [URL] {
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
        func walk(_ dir: URL, depthLeft: Int) {
            for item in children(dir) {
                let v = try? item.resourceValues(forKeys: Set(keys))
                if v?.isSymbolicLink == true { continue }
                if item.pathExtension.lowercased() == "app" {
                    add(item)
                } else if depthLeft > 0, v?.isDirectory == true, v?.isPackage != true {
                    walk(item, depthLeft: depthLeft - 1)
                }
            }
        }
        for root in roots { walk(root, depthLeft: folderDepth) }
        return result
    }

    /// Apps up to three folders deep (`/Applications/Adobe Creative Cloud/ACC/Creative Cloud.app`) that the
    /// visible one-level inventory misses. Used only to decide what other installed apps still own.
    static func deepAppsMissing(from known: [InstalledApp], roots: SearchRoots) -> [InstalledApp] {
        let knownPaths = Set(known.map { $0.url.standardizedFileURL.path })
        let urls = appBundleURLs(in: roots.applicationDirs, folderDepth: 3).filter { !knownPaths.contains($0.path) }
        return concurrentMap(urls) { describe($0, sized: false, readTeam: false) }.compactMap { $0 }
    }

    /// True for apps on the sealed system volume or symlinked into it (e.g. /Applications/Safari.app → Cryptexes).
    public static func isPartOfOS(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().path
        return path.hasPrefix("/System/") || resolved.hasPrefix("/System/")
    }

    /// `readTeam: false` leaves the Team ID to the code-signature read of the app's signature.
    static func describe(_ url: URL, sized: Bool, readTeam: Bool = true) -> InstalledApp? {
        guard let info = BundleInfo(appURL: url) else { return nil }
        let bundleID = info.bundleID
        // Only apps that are part of the OS are locked. Apple's App Store apps in /Applications
        // (Xcode, GarageBand, iMovie, iWork) are ordinary removable apps, often the biggest ones.
        let isSystem = isPartOfOS(url) || url.lastPathComponent == "Safari.app"
        let isAppStore = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
        return InstalledApp(
            url: url,
            name: info.name,
            bundleID: bundleID,
            version: info.version,
            teamID: readTeam ? CodeSigning.teamID(for: url) : nil,
            size: sized ? FileSizer.allocatedSize(of: url) : 0,
            lastUsed: sized ? FileMetadata.lastUsedDate(of: url) : nil,
            isSystemApp: isSystem,
            isAppStore: isAppStore
        )
    }
}
