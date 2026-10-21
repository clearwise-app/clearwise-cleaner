import Foundation
import CleanerKit

/// What all installed apps together own — used to decide that a leftover belongs to nobody.
struct InstalledOwnership: Sendable {
    let ids: [String]
    let groups: Set<String>
    let teams: Set<String>
    /// "com.google", "com.microsoft"…
    let vendorPrefixes: Set<String>
    let vendorTokens: Set<String>
    let names: Set<String>

    /// `bundles`: installed non-app bundles (audio plug-ins, prefpanes, input methods…), which keep
    /// their preferences/caches just like apps do.
    init(_ sigs: [AppSignature], bundles: [InstalledBundles.Bundle] = []) {
        var ids = Set<String>(), groups = Set<String>(), teams = Set<String>()
        var prefixes = Set<String>(), tokens = Set<String>(), names = Set<String>()
        for b in bundles {
            ids.insert(b.id)
            let comps = b.id.split(separator: ".")
            if comps.count >= 3 {
                prefixes.insert(comps.prefix(2).joined(separator: "."))
                let v = NameRules.normalize(String(comps[1]))
                if v.count >= 3 { tokens.insert(v) }
            }
            if b.name.count >= 5, !NameRules.genericNames.contains(b.name) { names.insert(b.name) }
        }
        for s in sigs {
            ids.formUnion(s.ownedIDs)
            for g in s.appGroups {
                groups.insert(g)
                groups.insert(NameRules.stripGroupPrefixes(g).core)
            }
            if let t = s.teamID { teams.insert(t.lowercased()) }
            for id in s.ownedIDs {
                let comps = id.split(separator: ".")
                if comps.count >= 3 { prefixes.insert(comps.prefix(2).joined(separator: ".")) }
            }
            tokens.formUnion(s.vendorTokens)
            names.formUnion(s.strongNames)
        }
        self.ids = Array(ids)
        self.groups = groups
        self.teams = teams
        vendorPrefixes = prefixes
        vendorTokens = tokens
        self.names = names
    }

    /// Lowercased identifier (group/team prefixes already stripped).
    func ownsID(_ core: String, full: String, team: String?) -> Bool {
        if let team, teams.contains(team) { return true }
        if groups.contains(full) || groups.contains(core) { return true }
        let stripped = NameRules.strippingHelperSuffixes(core)
        for id in ids {
            if core == id || stripped == id { return true }
            if core.hasPrefix(id + ".") || core.hasPrefix(id + "-") || core.hasPrefix(id + "_") { return true }
            // Candidate is a parent of an installed ID (com.foo.app vs installed com.foo.app.pro).
            if id.hasPrefix(core + ".") { return true }
        }
        let comps = core.split(separator: ".").map(String.init)
        let vendor = comps.prefix(2).joined(separator: ".")
        // Group containers and shared vendor components are kept while any app of the vendor is installed.
        if full.hasPrefix("group.") || team != nil || OrphanRules.isSharedVendorComponent(core) {
            if vendorPrefixes.contains(vendor) { return true }
        }
        // Name mentioned in the ID: com.tinyspeck.slackmacgap ↔ "Slack".
        for c in comps.dropFirst() {
            let n = NameRules.normalize(c)
            if ownsName(n) { return true }
        }
        return false
    }

    func ownsName(_ n: String) -> Bool {
        guard n.count >= 5 else { return false }
        if vendorTokens.contains(n) || names.contains(n) { return true }
        return names.contains { $0.count >= 5 && (n.contains($0) || $0.contains(n)) }
    }
}

/// Installed non-app bundles (plug-ins, prefpanes, screen savers, input methods…).
enum InstalledBundles {
    struct Bundle: Sendable, Hashable {
        /// Lowercased CFBundleIdentifier.
        let id: String
        /// Normalised file name without extension.
        let name: String
    }

    static func scan(_ dirs: [URL]) -> [Bundle] {
        concurrentMap(dirs) { list($0, depthLeft: 1) }.flatMap { $0 }
    }

    /// Bundles directly in `dir`, plus one level of plain vendor folders (VST3/FabFilter/Pro-Q 3.vst3).
    private static func list(_ dir: URL, depthLeft: Int) -> [Bundle] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [Bundle] = []
        for name in names where !name.hasPrefix(".") {
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let id = BundleInfo.bundleIdentifier(of: url)?.lowercased() {
                guard !NameRules.isAppleID(id) else { continue }
                out.append(Bundle(id: id, name: NameRules.normalize(url.deletingPathExtension().lastPathComponent)))
            } else if depthLeft > 0, url.pathExtension.isEmpty {
                out += list(url, depthLeft: depthLeft - 1)
            }
        }
        return out
    }
}

/// Read-only facts about paths that may point to unplugged drives or privacy-protected folders.
enum PathFacts {
    /// True when `path` is the mount point of a mounted file system (`/Volumes/Macintosh HD` → "/" counts).
    static func isMountPoint(_ path: String) -> Bool {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return false }
        let mnt = withUnsafeBytes(of: st.f_mntonname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return mnt == path || mnt == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// `/Volumes/<name>` for a path on an external volume, nil otherwise.
    static func volumeRoot(of path: String, volumes: String) -> String? {
        guard path.hasPrefix(volumes + "/"),
              let name = path.dropFirst(volumes.count + 1).split(separator: "/").first else { return nil }
        return volumes + "/" + name
    }

    static func isOnUnmountedVolume(_ path: String, volumes: String, mounted: (String) -> Bool) -> Bool {
        guard let root = volumeRoot(of: path, volumes: volumes) else { return false }
        return !mounted(root)
    }

    enum Presence { case present, missing, unknown }

    /// Folders macOS guards with privacy prompts; never probed (a missing-looking file may just be hidden).
    static func isPrivacyProtected(_ path: String, home: String) -> Bool {
        ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"].contains {
            let p = home + "/" + $0
            return path == p || path.hasPrefix(p + "/")
        }
    }

    /// `.missing` only when it is certain: an absolute path whose nearest existing ancestor is a directory
    /// we can list, on a mounted volume, outside privacy-protected folders. Anything doubtful is `.unknown`.
    static func presence(of rawPath: String, volumes: String, home: String, mounted: (String) -> Bool) -> Presence {
        guard rawPath.hasPrefix("/") else { return .unknown } // PATH-relative ("sh") or "~/…": cannot tell
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        if isOnUnmountedVolume(path, volumes: volumes, mounted: mounted) { return .unknown }
        if isPrivacyProtected(path, home: home) { return .unknown }
        var st = stat()
        if lstat(path, &st) == 0 { return .present }
        guard errno == ENOENT || errno == ENOTDIR else { return .unknown }
        var current = (path as NSString).deletingLastPathComponent
        while true {
            if lstat(current, &st) == 0 {
                guard let dir = opendir(current) else { return .unknown } // unreadable: cannot verify
                closedir(dir)
                return .missing
            }
            guard errno == ENOENT || errno == ENOTDIR, current != "/" else { return .unknown }
            current = (current as NSString).deletingLastPathComponent
        }
    }
}

enum OrphanRules {
    /// Components shared by several apps of one vendor (updaters, licensing). Orphans only if no app of
    /// that vendor is installed.
    static let sharedVendorPrefixes = [
        "com.google.keystone", "com.google.googleupdater", "com.google.softwareupdate", "com.google.googlesoftwareupdate",
        "com.microsoft.autoupdate", "com.microsoft.office", "com.microsoft.shared", "com.microsoft.oneauth",
        "com.microsoft.identity", "com.microsoft.errorreporting", "com.microsoft.licensing", "com.microsoft.mau",
        "com.microsoft.package", "com.adobe.", "com.jetbrains.toolbox", "com.mozilla.update",
    ]

    static func isSharedVendorComponent(_ id: String) -> Bool {
        sharedVendorPrefixes.contains { id.hasPrefix($0) }
    }

    /// Never reported as leftovers: developer toolchains and system components that are not apps.
    static let neverOrphanPrefixes = [
        "org.swift.", "org.llvm.", "org.python.", "org.nodejs.", "org.rust-lang.", "org.golang.", "org.gnu.",
        "org.git-scm.", "org.cups.", "org.openssh.", "com.openssh.", "org.macports.", "org.pqrs.", "com.github.cli",
        "org.mozilla.nss", "org.sparkle-project.", "com.crashlytics", "io.sentry", "com.plausiblelabs.",
        "com.segment.", "io.fabric.", "com.firebase.", "com.google.firebase", "com.microsoft.dotnet", "org.r-project.",
        "com.oracle.java", "com.oracle.jdk", "net.java.", "org.openjdk.", "com.amazon.aws.cli", "org.virtualbox.",
        "com.vmware.fusion.", "com.parallels.", "com.docker.vmnetd", "com.docker.socket",
    ]

    static func isNeverOrphan(_ id: String) -> Bool {
        neverOrphanPrefixes.contains { id.hasPrefix($0) || id + "." == $0 }
    }

    /// Group key for an identifier: helper suffixes stripped, first three components.
    static func ownerKey(_ id: String) -> String {
        let stripped = NameRules.strippingHelperSuffixes(id)
        return stripped.split(separator: ".").prefix(3).joined(separator: ".")
    }

    /// "com.spotify.client" → "Spotify", "com.tinyspeck.slackmacgap" → "Slack", "ru.keepcoder.Telegram" → "Telegram".
    static func displayName(forID id: String) -> String {
        let comps = id.split(separator: ".").map(String.init)
        var candidates = Array(comps.dropFirst())
        while let last = candidates.last, candidates.count > 1,
              NameRules.genericIDComponents.contains(last.lowercased()) || last.count < 3 {
            candidates.removeLast()
        }
        var name = candidates.last ?? id
        for suffix in ["macgap", "macos", "osx", "mac", "desktop", "app"] where name.lowercased().hasSuffix(suffix) {
            let base = String(name.dropLast(suffix.count))
            if base.count >= 4 { name = base; break }
        }
        name = name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        if let first = name.first, first.isLowercase { name = first.uppercased() + name.dropFirst() }
        return name
    }

    /// Plain folder names that look like macOS daemons ("familycircled", "mbuseragent").
    static func looksLikeSystemDaemon(_ name: String) -> Bool {
        guard name == name.lowercased(), !name.contains(" "), !name.contains("-") else { return false }
        return name.hasSuffix("d") || name.hasSuffix("agent") || name.hasSuffix("service")
    }
}

extension RemnantFinder {
    static let orphanQuietPeriod: TimeInterval = 7 * 24 * 3600

    public func orphans(installed: [InstalledApp], progress: ProgressHandler? = nil) async -> [OrphanGroup] {
        progress?(ScanProgress(phase: "Сбор сведений о приложениях", fraction: 0))
        if !installed.isEmpty { setInstalledApps(installed) }
        let apps = ownershipApps(installed.isEmpty ? nil : installed)
        prefetchSignatures(apps)
        let ownership = InstalledOwnership(apps.map { signature(for: $0) },
                                           bundles: InstalledBundles.scan(roots.installedBundleDirs))

        progress?(ScanProgress(phase: "Поиск остатков удалённых приложений", fraction: 0.2))
        let index = currentIndex()
        let candidates = Self.orphanCandidates(index: index, ownership: ownership, appLocator: appLocator,
                                               now: Date(), roots: roots, quietPeriod: orphanQuietPeriodValue,
                                               volumeMounted: volumeMounted)

        progress?(ScanProgress(phase: "Подсчёт размера", fraction: 0.6))
        let flat = candidates.flatMap { group in group.entries.map { (group.key, $0.0, $0.1) } }
        let avoid = avoidPrivacyPrompts
        let remnants = concurrentMap(flat) { triple -> (String, AppRemnant) in
            let (key, entry, confidence) = triple
            return (key, AppRemnant(item: Self.fileItem(entry, avoidPrompts: avoid), kind: entry.location.kind,
                                    confidence: confidence, requiresAdmin: Self.requiresAdmin(entry.url, roots: roots)))
        }
        var byKey: [String: [AppRemnant]] = [:]
        for (key, r) in remnants { byKey[key, default: []].append(r) }
        let groups = candidates.compactMap { c -> OrphanGroup? in
            guard let list = byKey[c.key], !list.isEmpty else { return nil }
            return OrphanGroup(id: c.id, displayName: c.displayName, remnants: Self.sortRemnants(list))
        }
        progress?(ScanProgress(phase: "Готово", fraction: 1))
        return groups.sorted { $0.totalSize != $1.totalSize ? $0.totalSize > $1.totalSize : $0.displayName < $1.displayName }
    }

    struct OrphanCandidate {
        let key: String
        var id: String
        var displayName: String
        var entries: [(IndexEntry, MatchConfidence)]
    }

    static func orphanCandidates(index: LocationIndex, ownership: InstalledOwnership,
                                 appLocator: (String) -> URL?, now: Date, roots: SearchRoots,
                                 quietPeriod: TimeInterval = orphanQuietPeriod,
                                 volumeMounted: (String) -> Bool = { PathFacts.isMountPoint($0) }) -> [OrphanCandidate] {
        var groups: [String: OrphanCandidate] = [:]
        var locatorCache: [String: Bool] = [:]
        let volumes = roots.volumes.standardizedFileURL.path
        let home = roots.home.standardizedFileURL.path
        func installedSomewhere(_ id: String) -> Bool {
            if let cached = locatorCache[id] { return cached }
            var found = false
            if let url = appLocator(id), !url.path.contains("/.Trash/"), !SafetyGuard.isInsideTrash(url) {
                let path = url.standardizedFileURL.path
                // An app on an unplugged drive is still installed.
                found = PathFacts.isOnUnmountedVolume(path, volumes: volumes, mounted: volumeMounted)
                    || FileManager.default.fileExists(atPath: path)
            }
            locatorCache[id] = found
            return found
        }
        func presence(_ path: String) -> PathFacts.Presence {
            if SafetyGuard.isInsideTrash(URL(fileURLWithPath: path)) { return .missing }
            return PathFacts.presence(of: path, volumes: volumes, home: home, mounted: volumeMounted)
        }
        /// High only for a job whose Label is an exact bundle-style ID and whose program lived in a now-missing app.
        func launchJobIsSurelyOrphaned(_ entry: IndexEntry, program: String, id: String) -> Bool {
            guard let label = entry.label?.lowercased(), label == id, NameRules.isReverseDNS(label),
                  let r = program.range(of: ".app/", options: .caseInsensitive) else { return false }
            return presence(String(program[..<r.lowerBound]) + ".app") == .missing
        }

        for (location, entries) in index.entries where location.orphanScan {
            for entry in entries {
                if let modified = entry.modified, now.timeIntervalSince(modified) < quietPeriod { continue }
                if SafetyGuard.isProtected(entry.url) { continue }
                if NameRules.isUUID(entry.stem) { continue }
                // A launch job is a leftover only when its program is verifiably gone. Present, PATH-relative,
                // unreadable (privacy-protected) or on an unplugged drive: something may still own it.
                if location.style == .launchd {
                    guard let program = entry.programPath, presence(program) == .missing else { continue }
                }

                // Prefer an identifier that looks like a bundle ID.
                var chosen: (core: String, full: String, team: String?)?
                var appleOwned = false
                for raw in entry.ids {
                    let full = raw.lowercased()
                    let (core, team) = NameRules.stripGroupPrefixes(full)
                    if NameRules.isAppleID(core) || NameRules.isAppleID(full) || full.contains(".com.apple.") {
                        appleOwned = true
                        break
                    }
                    if NameRules.isReverseDNS(core) { chosen = (core, full, team); break }
                }
                if appleOwned { continue }

                if let chosen {
                    let (core, full, team) = chosen
                    guard NameRules.normalize(core).count >= 5, !NameRules.containsUUID(core) else { continue }
                    if OrphanRules.isNeverOrphan(core) { continue }
                    if ownership.ownsID(core, full: full, team: team) { continue }
                    let key = OrphanRules.ownerKey(core)
                    if installedSomewhere(core) || installedSomewhere(key) { continue }
                    let originalCore = NameRules.stripGroupPrefixes(entry.stem).core
                    let displayKey = OrphanRules.ownerKey(originalCore.lowercased() == core ? originalCore : core)
                    var confidence: MatchConfidence = (full == core && NameRules.isReverseDNS(entry.stem)) ? .high : .medium
                    if location.style == .launchd, confidence == .high,
                       !launchJobIsSurelyOrphaned(entry, program: entry.programPath ?? "", id: full) {
                        confidence = .medium // unloading someone's own job by mistake is worse than keeping it
                    }
                    groups[key, default: OrphanCandidate(key: key, id: displayKey,
                                                         displayName: OrphanRules.displayName(forID: displayKey),
                                                         entries: [])].entries.append((entry, confidence))
                } else if location.orphanPlainNames {
                    let stem = entry.stem
                    guard entry.isDirectory, !stem.contains(".") || stem.contains(" ") else { continue }
                    let n = NameRules.normalize(stem)
                    let lower = stem.lowercased()
                    guard n.count >= 5, !NameRules.containsUUID(stem), !NameRules.genericNames.contains(n),
                          !NameRules.appleFolderNames.contains(lower), !OrphanRules.looksLikeSystemDaemon(stem),
                          !["apple", "icloud", "siri", "macos"].contains(where: { lower.contains($0) }) else { continue }
                    if ownership.ownsName(n) { continue }
                    let key = "name:" + n
                    groups[key, default: OrphanCandidate(key: key, id: stem, displayName: stem, entries: [])]
                        .entries.append((entry, .low))
                }
            }
        }

        // Fold plain-name groups into the matching bundle-ID group ("Spotify" folder → com.spotify.client).
        var targetByToken: [String: String] = [:]
        for (key, g) in groups where !key.hasPrefix("name:") {
            let tokens = [NameRules.normalize(g.displayName)]
                + key.split(separator: ".").dropFirst().map { NameRules.normalize(String($0)) }
            for t in tokens where !t.isEmpty {
                if let existing = targetByToken[t], existing <= key { continue }
                targetByToken[t] = key
            }
        }
        for key in groups.keys where key.hasPrefix("name:") {
            if let target = targetByToken[String(key.dropFirst(5))], let plain = groups.removeValue(forKey: key) {
                groups[target]?.entries += plain.entries
            }
        }

        // Nested duplicates inside one group: the outer item covers the inner ones.
        return groups.values.map { g in
            var g = g
            g.entries = NestedPaths.outermost(g.entries) { $0.0.url.standardizedFileURL.path }
            return g
        }
    }
}
