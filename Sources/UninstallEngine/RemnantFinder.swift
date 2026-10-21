import Foundation
import AppKit
import CleanerKit

/// Finds every trace of an app on disk (and, in OrphanFinder.swift, traces of apps that are gone).
///
/// How it works: all search locations are listed once into a `LocationIndex` (cached for a short time),
/// then each entry is matched in memory against the app's `AppSignature` (bundle IDs, app groups,
/// Team ID, names, vendor). Every candidate is then checked against all *other* installed apps,
/// and dropped if another app claims it at least as strongly.
public actor RemnantFinder {
    let roots: SearchRoots
    /// Asks Launch Services whether an app with this bundle ID exists anywhere (conservative orphan check).
    let appLocator: @Sendable (String) -> URL?
    let signProvider: @Sendable (URL) -> CodeSignInfo

    private var index: LocationIndex?
    private var providedApps: [InstalledApp]?
    private var scannedApps: (apps: [InstalledApp], at: Date)?
    private var signatures: [URL: AppSignature] = [:]
    /// Do not read inside other apps' (group) containers when sizing. Reading there without Full Disk Access
    /// makes macOS show the blocking "access data from other apps" prompt; used by the read-only smoke run.
    /// nil = decide from the live Full Disk Access status (the app's default).
    var avoidPrivacyPromptsOverride: Bool?
    var avoidPrivacyPrompts: Bool { avoidPrivacyPromptsOverride ?? !Permissions.hasFullDiskAccess }
    /// Items modified more recently than this are never orphans (likely still used by something).
    var orphanQuietPeriodValue: TimeInterval = RemnantFinder.orphanQuietPeriod

    static let indexTTL: TimeInterval = 30
    static let appsTTL: TimeInterval = 300

    public init() {
        self.init(roots: .live, knownApps: nil,
                  appLocator: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
                  signProvider: { CodeSigning.info(for: $0) },
                  avoidPrivacyPrompts: nil) // live finder follows the Full Disk Access status
    }

    init(roots: SearchRoots, knownApps: [InstalledApp]?,
         appLocator: @escaping @Sendable (String) -> URL? = { _ in nil },
         signProvider: @escaping @Sendable (URL) -> CodeSignInfo = { CodeSigning.info(for: $0) },
         avoidPrivacyPrompts: Bool? = false) {
        self.roots = roots
        self.providedApps = knownApps
        self.avoidPrivacyPromptsOverride = avoidPrivacyPrompts
        self.appLocator = appLocator
        self.signProvider = signProvider
    }

    /// Optional: share the inventory the UI already has, so the finder does not rescan /Applications
    /// to learn which other apps are installed.
    public func setInstalledApps(_ apps: [InstalledApp]) {
        providedApps = apps
    }

    /// Drops cached directory listings (call after removing files).
    public func invalidate() {
        index = nil
        scannedApps = nil
    }

    // MARK: - Remnants of one app

    public func remnants(for app: InstalledApp) async -> [AppRemnant] {
        guard !app.isSystemApp else { return [] }
        let index = currentIndex()
        let sig = signature(for: app)
        let appURL = app.url.standardizedFileURL
        let others = installedApps().filter { $0.url.standardizedFileURL != appURL }
        prefetchSignatures(others)
        let otherSigs = others.map { signature(for: $0) }
        let otherTeams = Set(others.compactMap(\.teamID))

        let soleVendor = sig.vendorPrefix.flatMap { vendor in
            otherSigs.contains { o in o.ownedIDs.contains { $0.hasPrefix(vendor + ".") } } ? nil : vendor
        }
        let found = Self.collect(index: index, sig: sig, soleVendor: soleVendor)
        var accepted: [(IndexEntry, MatchResult)] = []
        for (entry, match) in found {
            let path = entry.url.standardizedFileURL.path
            if path == sig.appPath || path.hasPrefix(sig.appPath + "/") { continue }
            if match.teamOnly, let team = sig.teamID, otherTeams.contains(team) { continue }
            if SafetyGuard.isProtected(entry.url) { continue }
            if otherSigs.contains(where: { o in Matcher.match(entry, o).map { Matcher.dominates($0, over: match) } ?? false }) {
                continue
            }
            accepted.append((entry, match))
        }
        let deduped = Self.dedupeNested(accepted)
        return Self.makeRemnants(deduped, roots: roots, avoidPrompts: avoidPrivacyPrompts)
    }

    /// Raw candidates for one signature (no cross-app guard yet).
    /// `soleVendor`: the app is the last installed one of this vendor, so its shared updaters may go too.
    static func collect(index: LocationIndex, sig: AppSignature, soleVendor: String? = nil) -> [(IndexEntry, MatchResult)] {
        var out: [URL: (IndexEntry, MatchResult)] = [:]
        func add(_ e: IndexEntry, _ m: MatchResult) {
            if let existing = out[e.url], existing.1.confidence >= m.confidence { return }
            out[e.url] = (e, m)
        }
        for (_, entries) in index.entries {
            for e in entries {
                if let m = Matcher.match(e, sig) {
                    add(e, m)
                } else if Matcher.isVendorFolder(e, sig) {
                    for child in index.vendorChildren(of: e) {
                        if let m = Matcher.match(child, sig) ?? soleVendor.flatMap({ Matcher.sharedVendorComponentMatch(child, vendor: $0) }) {
                            add(child, m)
                        }
                    }
                } else if let soleVendor, let m = Matcher.sharedVendorComponentMatch(e, vendor: soleVendor) {
                    add(e, m)
                }
            }
        }
        // Privileged helpers referenced by one of the app's launch daemons/agents.
        let helperDir = index.roots.systemLibrary.appendingPathComponent("PrivilegedHelperTools").standardizedFileURL.path
        let helpers = index.entries.first(where: { $0.key.kind == .privilegedHelpers })?.value ?? []
        for (e, m) in out.values where m.confidence == .high {
            guard let program = e.programPath, program.hasPrefix(helperDir + "/") else { continue }
            if let helper = helpers.first(where: { $0.url.standardizedFileURL.path == program }) {
                add(helper, MatchResult(confidence: .high, specificity: m.specificity, teamOnly: false))
            }
        }
        return Array(out.values)
    }

    /// A folder and its child: keep the outer one unless the inner one is matched more confidently.
    static func dedupeNested(_ items: [(IndexEntry, MatchResult)]) -> [(IndexEntry, MatchResult)] {
        let sorted = items.sorted { $0.0.url.path.count < $1.0.url.path.count }
        var kept: [(IndexEntry, MatchResult)] = []
        for item in sorted {
            let p = item.0.url.standardizedFileURL.path
            if let i = kept.firstIndex(where: { p.hasPrefix($0.0.url.standardizedFileURL.path + "/") }) {
                if kept[i].1.confidence < item.1.confidence {
                    // The inner match is more certain: drop the outer guess, keep the inner item.
                    kept.remove(at: i)
                    kept.append(item)
                }
                continue
            }
            kept.append(item)
        }
        return kept
    }

    static func makeRemnants(_ items: [(IndexEntry, MatchResult)], roots: SearchRoots, avoidPrompts: Bool) -> [AppRemnant] {
        let existing = items.filter { FileManager.default.fileExists(atPath: $0.0.url.path) || isSymlink($0.0.url) }
        let remnants = concurrentMap(existing) { pair -> AppRemnant in
            let (entry, match) = pair
            return AppRemnant(item: fileItem(entry, avoidPrompts: avoidPrompts), kind: entry.location.kind,
                       confidence: match.confidence, requiresAdmin: requiresAdmin(entry.url, roots: roots))
        }
        return sortRemnants(remnants)
    }

    static func fileItem(_ entry: IndexEntry, avoidPrompts: Bool) -> FileItem {
        if avoidPrompts, entry.isDirectory, entry.location.kind == .containers || entry.location.kind == .groupContainers {
            return FileItem(url: entry.url, size: 0, isDirectory: true, lastUsed: nil, modified: entry.modified)
        }
        return FileSizer.item(for: entry.url)
    }

    func setAvoidPrivacyPrompts(_ value: Bool) { avoidPrivacyPromptsOverride = value }
    func setOrphanQuietPeriod(_ value: TimeInterval) { orphanQuietPeriodValue = value }

    static func sortRemnants(_ list: [AppRemnant]) -> [AppRemnant] {
        let order = Dictionary(uniqueKeysWithValues: RemnantKind.allCases.enumerated().map { ($1, $0) })
        return list.sorted { a, b in
            let ka = order[a.kind] ?? 0, kb = order[b.kind] ?? 0
            if ka != kb { return ka < kb }
            if a.item.size != b.item.size { return a.item.size > b.item.size }
            return a.item.url.path < b.item.url.path
        }
    }

    /// Needs the admin prompt: lives in a system area, or the user cannot move it.
    static func requiresAdmin(_ url: URL, roots: SearchRoots) -> Bool {
        if roots.isSystemArea(url) { return true }
        let parent = url.deletingLastPathComponent().path
        if access(parent, W_OK) != 0 { return true }
        var st = stat()
        if lstat(url.path, &st) == 0 {
            // Moving a directory to another parent rewrites its "..", which needs write access to it.
            if (st.st_mode & S_IFMT) == S_IFDIR, access(url.path, W_OK) != 0 { return true }
            var pst = stat()
            if stat(parent, &pst) == 0, (pst.st_mode & S_ISVTX) != 0, st.st_uid != getuid() { return true }
        }
        return false
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    // MARK: - Caches

    func currentIndex() -> LocationIndex {
        if let index, Date().timeIntervalSince(index.builtAt) < Self.indexTTL { return index }
        let fresh = LocationIndex(roots: roots)
        index = fresh
        return fresh
    }

    func installedApps() -> [InstalledApp] {
        if let providedApps { return providedApps }
        if let scannedApps, Date().timeIntervalSince(scannedApps.at) < Self.appsTTL { return scannedApps.apps }
        let apps = AppInventory.lightweightApps(roots: roots)
        scannedApps = (apps, Date())
        prefetchSignatures(apps)
        return apps
    }

    func signature(for app: InstalledApp) -> AppSignature {
        let key = app.url.standardizedFileURL
        if let s = signatures[key] { return s }
        let s = Self.makeSignature(app, signProvider: signProvider)
        signatures[key] = s
        return s
    }

    /// Builds signatures for many apps in parallel (code-signature reads dominate).
    func prefetchSignatures(_ apps: [InstalledApp]) {
        let missing = apps.filter { signatures[$0.url.standardizedFileURL] == nil }
        guard !missing.isEmpty else { return }
        let provider = signProvider
        let built = concurrentMap(missing) { Self.makeSignature($0, signProvider: provider) }
        for s in built { signatures[s.appURL] = s }
    }

    static func makeSignature(_ app: InstalledApp, signProvider: (URL) -> CodeSignInfo) -> AppSignature {
        let info = BundleInfo(appURL: app.url)
        return AppSignature(app: app, info: info, sign: signProvider(app.url), nestedIDs: info?.nestedBundleIDs() ?? [])
    }
}
