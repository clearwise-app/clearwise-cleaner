import Foundation
import CleanerKit
@testable import UninstallEngine

/// A fake Mac in a temp directory: home, /Library, receipts, var/folders C|T, /Applications.
final class Fixture {
    let root: URL
    let roots: SearchRoots
    private let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("UninstallEngineTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        roots = SearchRoots.fixture(root: root)
        for dir in [roots.home, roots.systemLibrary, roots.receipts, roots.userCacheDir!, roots.userTempDir!] + roots.applicationDirs {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    deinit {
        // Only ever removes our own temp fixture tree.
        if root.path.contains("UninstallEngineTests-") { try? fm.removeItem(at: root) }
    }

    var home: URL { roots.home }
    var lib: URL { roots.home.appendingPathComponent("Library") }
    var sysLib: URL { roots.systemLibrary }
    var apps: URL { roots.applicationDirs[0] }

    /// Creates a minimal `.app` with Contents/Info.plist and returns its InstalledApp.
    @discardableResult
    func makeApp(_ name: String, id: String, in dir: URL? = nil, teamID: String? = nil,
                 extra: [String: Any] = [:], system: Bool = false) throws -> InstalledApp {
        let url = (dir ?? apps).appendingPathComponent("\(name).app", isDirectory: true)
        var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleExecutable": name,
                                   "CFBundleShortVersionString": "1.0"]
        info.merge(extra) { $1 }
        try writePlist(info, to: url.appendingPathComponent("Contents/Info.plist"))
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        return InstalledApp(url: url, name: name, bundleID: id, version: "1.0", teamID: teamID, size: 0,
                            lastUsed: nil, isSystemApp: system, isAppStore: false)
    }

    @discardableResult
    func dir(_ base: URL, _ rel: String, ageDays: Double? = 30) throws -> URL {
        let url = base.appendingPathComponent(rel, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent("data"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2048).write(to: url.appendingPathComponent("data/blob"))
        if let ageDays { try age(url, days: ageDays) }
        return url
    }

    @discardableResult
    func file(_ base: URL, _ rel: String, bytes: Int = 128, ageDays: Double? = 30) throws -> URL {
        let url = base.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        if let ageDays { try age(url, days: ageDays) }
        return url
    }

    @discardableResult
    func plist(_ base: URL, _ rel: String, _ dict: [String: Any], ageDays: Double? = 30) throws -> URL {
        let url = base.appendingPathComponent(rel)
        try writePlist(dict, to: url)
        if let ageDays { try age(url, days: ageDays) }
        return url
    }

    func writePlist(_ dict: [String: Any], to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url)
    }

    func age(_ url: URL, days: Double) throws {
        let date = Date().addingTimeInterval(-days * 24 * 3600)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// `groups` / `teams`: code-signature facts by app path. `mounted`: which `<root>/Volumes/<name>` count as attached.
    func finder(known: [InstalledApp]?, groups: [String: [String]] = [:], teams: [String: String] = [:],
                mounted: @escaping @Sendable (String) -> Bool = { _ in false },
                locator: @escaping @Sendable (String) -> URL? = { _ in nil }) -> RemnantFinder {
        let byPath = groups, teamByPath = teams
        return RemnantFinder(roots: roots, knownApps: known, appLocator: locator, signProvider: { url in
            let p = url.standardizedFileURL.path
            return CodeSignInfo(teamID: teamByPath[p], appGroups: byPath[p] ?? [])
        }, volumeMounted: mounted)
    }

    /// A non-app bundle (plug-in, prefpane, input method…) with Contents/Info.plist.
    @discardableResult
    func makeBundle(_ base: URL, _ rel: String, id: String) throws -> URL {
        let url = base.appendingPathComponent(rel, isDirectory: true)
        try writePlist(["CFBundleIdentifier": id], to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }
}

extension Array where Element == AppRemnant {
    func remnant(_ url: URL) -> AppRemnant? {
        let p = url.standardizedFileURL.path
        return first { $0.item.url.standardizedFileURL.path == p }
    }
    var paths: Set<String> { Set(map { $0.item.url.standardizedFileURL.path }) }
}
