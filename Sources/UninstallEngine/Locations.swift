import Foundation
import CleanerKit

/// Every root the engine reads. Injectable so tests run against a fixture tree
/// and never touch the real disk.
struct SearchRoots: Sendable {
    var home: URL
    /// `/Library`
    var systemLibrary: URL
    /// `/private/var/db/receipts`
    var receipts: URL
    /// `confstr(_CS_DARWIN_USER_CACHE_DIR)` — `/private/var/folders/xx/…/C`
    var userCacheDir: URL?
    /// `confstr(_CS_DARWIN_USER_TEMP_DIR)` — `/private/var/folders/xx/…/T`
    var userTempDir: URL?
    /// `/Users/Shared`
    var usersShared: URL?
    /// Where installed apps live (`/Applications`, `~/Applications`).
    var applicationDirs: [URL]
    /// Mount point root for external drives (`/Volumes`).
    var volumes: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true)

    static var live: SearchRoots {
        let home = SafetyGuard.home
        return SearchRoots(
            home: home,
            systemLibrary: URL(fileURLWithPath: "/Library", isDirectory: true),
            receipts: URL(fileURLWithPath: "/private/var/db/receipts", isDirectory: true),
            userCacheDir: darwinDir(_CS_DARWIN_USER_CACHE_DIR),
            userTempDir: darwinDir(_CS_DARWIN_USER_TEMP_DIR),
            usersShared: URL(fileURLWithPath: "/Users/Shared", isDirectory: true),
            applicationDirs: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                home.appendingPathComponent("Applications", isDirectory: true),
            ]
        )
    }

    /// Layout used by tests: `<root>/home`, `<root>/Library`, `<root>/receipts`, `<root>/var/C|T`, `<root>/Applications`.
    static func fixture(root: URL) -> SearchRoots {
        SearchRoots(
            home: root.appendingPathComponent("home", isDirectory: true),
            systemLibrary: root.appendingPathComponent("Library", isDirectory: true),
            receipts: root.appendingPathComponent("receipts", isDirectory: true),
            userCacheDir: root.appendingPathComponent("var/C", isDirectory: true),
            userTempDir: root.appendingPathComponent("var/T", isDirectory: true),
            usersShared: root.appendingPathComponent("Shared", isDirectory: true),
            applicationDirs: [
                root.appendingPathComponent("Applications", isDirectory: true),
                root.appendingPathComponent("home/Applications", isDirectory: true),
            ],
            volumes: root.appendingPathComponent("Volumes", isDirectory: true)
        )
    }

    private static func darwinDir(_ name: Int32) -> URL? {
        let len = confstr(name, nil, 0)
        guard len > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: len)
        guard confstr(name, &buf, len) > 0 else { return nil }
        let path = String(cString: buf)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
    }

    /// True for paths outside the user's home that live in root-owned system areas.
    func isSystemArea(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return p.hasPrefix(systemLibrary.standardizedFileURL.path + "/")
            || p.hasPrefix(receipts.standardizedFileURL.path + "/")
    }
}

/// How entries of a location are named and must be interpreted.
enum LocationStyle: Sendable {
    /// Folder or file named by bundle ID or app name.
    case plain
    /// `<id>.plist`
    case preferences
    /// `<id>.<hardware UUID>.plist`
    case byHost
    /// `<id>` or UUID-named folder with `.com.apple.containermanagerd.metadata.plist`
    case containers
    /// `<TeamID>.<group>` / `group.<id>`
    case groupContainers
    /// `<id>.savedState`
    case savedState
    /// `<id>.binarycookies`
    case cookies
    /// launchd plists; Label / Program / AssociatedBundleIdentifiers are parsed.
    case launchd
    /// `<pkg id>.plist` / `<pkg id>.bom`
    case receipts
    /// Plug-in bundles; their CFBundleIdentifier is read.
    case bundles
    /// `<ProcessName>-YYYY-MM-DD-HHMMSS.ips`
    case crashReports
    /// `~/.<name>` / `~/.config/<name>`
    case dotFolders
}

struct Location: Sendable, Hashable {
    let url: URL
    let kind: RemnantKind
    let style: LocationStyle
    /// Look one level inside vendor folders (Application Support/Google/Chrome).
    let vendorNesting: Bool
    /// Part of the reverse "leftovers of deleted apps" scan.
    let orphanScan: Bool
    /// Plain-name (non reverse-DNS) entries may be reported as orphans here.
    let orphanPlainNames: Bool

    init(_ url: URL, _ kind: RemnantKind, _ style: LocationStyle = .plain, vendorNesting: Bool = false,
         orphanScan: Bool = false, orphanPlainNames: Bool = false) {
        self.url = url
        self.kind = kind
        self.style = style
        self.vendorNesting = vendorNesting
        self.orphanScan = orphanScan
        self.orphanPlainNames = orphanPlainNames
    }

    static func == (a: Location, b: Location) -> Bool { a.url == b.url && a.style == b.style }
    func hash(into h: inout Hasher) { h.combine(url) }
}

extension SearchRoots {
    /// Folders (user and system Library) holding installed non-app bundles: audio plug-ins, prefpanes,
    /// screen savers, Quick Look / Spotlight importers, services, internet plug-ins, input methods.
    /// Their bundle IDs count as installed when looking for leftovers of deleted apps.
    var installedBundleDirs: [URL] {
        let rels = [
            "Audio/Plug-Ins/Components", "Audio/Plug-Ins/HAL", "Audio/Plug-Ins/VST", "Audio/Plug-Ins/VST3",
            "Audio/Plug-Ins/CLAP", "Audio/Plug-Ins/MAS", "PreferencePanes", "Screen Savers", "QuickLook",
            "Spotlight", "Services", "Internet Plug-Ins", "Input Methods",
        ]
        let libs = [home.appendingPathComponent("Library", isDirectory: true), systemLibrary]
        return libs.flatMap { lib in rels.map { lib.appendingPathComponent($0, isDirectory: true) } }
    }

    /// All places where traces of an app can live (docs/competitors.md §1).
    var locations: [Location] {
        let lib = home.appendingPathComponent("Library", isDirectory: true)
        func u(_ p: String) -> URL { lib.appendingPathComponent(p, isDirectory: true) }
        func s(_ p: String) -> URL { systemLibrary.appendingPathComponent(p, isDirectory: true) }

        var list: [Location] = [
            // User Library
            Location(u("Application Support"), .applicationSupport, vendorNesting: true, orphanScan: true, orphanPlainNames: true),
            Location(u("Application Scripts"), .containers),
            Location(u("Caches"), .caches, vendorNesting: true, orphanScan: true, orphanPlainNames: true),
            Location(u("Containers"), .containers, .containers, orphanScan: true),
            Location(u("Group Containers"), .groupContainers, .groupContainers, orphanScan: true),
            Location(u("Preferences"), .preferences, .preferences, orphanScan: true),
            Location(u("Preferences/ByHost"), .preferences, .byHost, orphanScan: true),
            Location(u("Saved Application State"), .savedState, .savedState, orphanScan: true),
            Location(u("HTTPStorages"), .httpStorages, orphanScan: true),
            Location(u("WebKit"), .webData, orphanScan: true),
            Location(u("Cookies"), .cookies, .cookies, orphanScan: true),
            Location(u("Logs"), .logs, vendorNesting: true, orphanScan: true, orphanPlainNames: true),
            Location(u("LaunchAgents"), .launchAgents, .launchd, orphanScan: true),
            Location(u("Logs/DiagnosticReports"), .crashReports, .crashReports),
            Location(u("Logs/DiagnosticReports/Retired"), .crashReports, .crashReports),
            Location(u("Internet Plug-Ins"), .extensions, .bundles),
            Location(u("PreferencePanes"), .extensions, .bundles),
            Location(u("QuickLook"), .extensions, .bundles),
            Location(u("Services"), .extensions, .bundles),
            Location(u("Screen Savers"), .extensions, .bundles),
            Location(u("Spotlight"), .extensions, .bundles),
            Location(u("Audio/Plug-Ins/Components"), .extensions, .bundles),
            Location(u("Audio/Plug-Ins/HAL"), .extensions, .bundles),
            Location(u("Audio/Plug-Ins/VST"), .extensions, .bundles),
            Location(u("Audio/Plug-Ins/VST3"), .extensions, .bundles),
            Location(u("Audio/Plug-Ins/MAS"), .extensions, .bundles),
            // SDK caches keyed by the host app's bundle ID.
            Location(u("Caches/com.crashlytics.data"), .caches),
            Location(u("Caches/com.plausiblelabs.crashreporter.data"), .caches),
            Location(u("Caches/SentryCrash"), .caches),
            Location(u("Application Support/com.crashlytics"), .applicationSupport),
            Location(u("WebKit/Databases"), .webData),

            // System Library (admin)
            Location(s("Application Support"), .applicationSupport, vendorNesting: true, orphanScan: true, orphanPlainNames: true),
            Location(s("Caches"), .caches, vendorNesting: true),
            Location(s("Preferences"), .preferences, .preferences),
            Location(s("Logs"), .logs, vendorNesting: true),
            Location(s("Logs/DiagnosticReports"), .crashReports, .crashReports),
            Location(s("LaunchAgents"), .launchAgents, .launchd, orphanScan: true),
            Location(s("LaunchDaemons"), .launchDaemons, .launchd, orphanScan: true),
            Location(s("PrivilegedHelperTools"), .privilegedHelpers, orphanScan: true),
            Location(s("Internet Plug-Ins"), .extensions, .bundles),
            Location(s("PreferencePanes"), .extensions, .bundles),
            Location(s("QuickLook"), .extensions, .bundles),
            Location(s("Services"), .extensions, .bundles),
            Location(s("Screen Savers"), .extensions, .bundles),
            Location(s("Spotlight"), .extensions, .bundles),
            Location(s("Extensions"), .extensions, .bundles),
            Location(s("Audio/Plug-Ins/Components"), .extensions, .bundles),
            Location(s("Audio/Plug-Ins/HAL"), .extensions, .bundles),
            Location(s("Audio/Plug-Ins/VST"), .extensions, .bundles),
            Location(s("Audio/Plug-Ins/VST3"), .extensions, .bundles),
            Location(s("Audio/Plug-Ins/MAS"), .extensions, .bundles),

            Location(receipts, .receipts, .receipts),
            Location(home, .other, .dotFolders),
            Location(home.appendingPathComponent(".config", isDirectory: true), .other, .dotFolders),
        ]
        if let usersShared { list.append(Location(usersShared, .applicationSupport)) }
        if let userCacheDir { list.append(Location(userCacheDir, .caches)) }
        if let userTempDir { list.append(Location(userTempDir, .caches)) }
        return list
    }
}
