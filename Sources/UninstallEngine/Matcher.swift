import Foundation
import CleanerKit

/// Everything that identifies one app on disk: IDs, names, vendor, team.
struct AppSignature: Sendable {
    let appURL: URL
    let appPath: String
    /// Lowercased CFBundleIdentifier.
    let bundleID: String?
    /// Lowercased IDs owned by the app (main ID, helper-stripped variant, embedded helpers/extensions), longest first.
    let ownedIDs: [String]
    /// Lowercased `com.apple.security.application-groups`.
    let appGroups: Set<String>
    let teamID: String?
    /// Normalised names (≥ 5 chars, not generic). An exact match is medium confidence.
    let strongNames: Set<String>
    /// Normalised 4-char names ("Code"). An exact match is only low confidence.
    let weakNames: Set<String>
    /// Lowercased process names for crash reports ("google chrome", "telegram").
    let processNames: Set<String>
    /// Normalised vendor folder names ("google" for com.google.Chrome / "Google Chrome").
    let vendorTokens: Set<String>
    /// "com.google" for com.google.Chrome (nil for two-component IDs).
    let vendorPrefix: String?
    let isApple: Bool

    init(app: InstalledApp, info: BundleInfo?, sign: CodeSignInfo, nestedIDs: [String]) {
        appURL = app.url.standardizedFileURL
        appPath = appURL.path
        let bid = (app.bundleID ?? info?.bundleID)?.lowercased()
        bundleID = bid
        isApple = bid.map(NameRules.isAppleID) ?? false

        var owned: Set<String> = []
        if let bid {
            owned.insert(bid)
            let stripped = NameRules.strippingHelperSuffixes(bid)
            if stripped.split(separator: ".").count >= 3 { owned.insert(stripped) }
        }
        for id in nestedIDs { owned.insert(id.lowercased()) }
        ownedIDs = owned.sorted { $0.count > $1.count }
        appGroups = Set(sign.appGroups.map { $0.lowercased() })
        teamID = app.teamID ?? sign.teamID

        var rawNames: [String] = [app.name, app.url.deletingPathExtension().lastPathComponent]
        if let info {
            rawNames += [info.displayName, info.bundleName, info.executable].compactMap { $0 }
        }
        var strong: Set<String> = []
        var weak: Set<String> = []
        func addName(_ raw: String, allowWeak: Bool) {
            for variant in [raw, NameRules.strippingTrailingVersion(raw)].compactMap({ $0 }) {
                let n = NameRules.normalize(variant)
                guard !NameRules.genericNames.contains(n) else { continue }
                if n.count >= 5 { strong.insert(n) } else if n.count == 4, allowWeak { weak.insert(n) }
            }
        }
        for raw in rawNames { addName(raw, allowWeak: true) }
        if let bid {
            // Last meaningful component of the bundle ID: com.google.Chrome → "chrome".
            let comps = bid.split(separator: ".").map(String.init)
            if comps.count >= 3, let last = comps.dropFirst(2).last(where: { !NameRules.genericIDComponents.contains($0) }) {
                addName(last, allowWeak: false)
            }
        }
        strongNames = strong
        weakNames = weak.subtracting(strong)
        // Not a generic executable name («Electron», «Helper»…): every other Electron app's crash reports would match.
        processNames = Set(rawNames.map { $0.lowercased() }
            .filter { $0.count >= 3 && !NameRules.genericNames.contains(NameRules.normalize($0)) })

        var vendors: Set<String> = []
        if let bid {
            let comps = bid.split(separator: ".").map(String.init)
            if comps.count >= 3 {
                let v = NameRules.normalize(comps[1])
                if v.count >= 3 { vendors.insert(v) }
            }
        }
        let words = app.name.split(whereSeparator: { $0 == " " || $0 == "-" })
        if words.count >= 2 {
            let w = NameRules.normalize(String(words[0]))
            if w.count >= 4 { vendors.insert(w) }
        }
        vendorTokens = vendors
        if let bid, bid.split(separator: ".").count >= 3 {
            vendorPrefix = bid.split(separator: ".").prefix(2).joined(separator: ".")
        } else {
            vendorPrefix = nil
        }
    }
}

struct MatchResult: Sendable {
    let confidence: MatchConfidence
    /// Tie-breaker between apps: length of the matched identifier (longer = more specific).
    let specificity: Int
    /// Only the Team ID prefix matched (group container of the same developer).
    let teamOnly: Bool
}

enum Matcher {
    private static let idSeparators: Set<Character> = [".", "-", "_", " "]
    private static let normalizedSuffixWords: [String] = NameRules.nameSuffixWords.map(NameRules.normalize)

    /// How strongly `entry` belongs to the app described by `sig`; nil if not at all.
    static func match(_ entry: IndexEntry, _ sig: AppSignature) -> MatchResult? {
        switch entry.location.style {
        case .crashReports:
            let process = entry.stem.lowercased()
            if sig.processNames.contains(process) { return MatchResult(confidence: .medium, specificity: process.count, teamOnly: false) }
            if sig.processNames.contains(where: { $0.count >= 4 && process.hasPrefix($0 + " ") }) {
                return MatchResult(confidence: .medium, specificity: process.count, teamOnly: false)
            }
            return nil
        case .dotFolders:
            guard !NameRules.cliDotFolders.contains(entry.stem.lowercased()) else { return nil }
            let n = NameRules.normalize(entry.stem)
            return sig.strongNames.contains(n) ? MatchResult(confidence: .low, specificity: n.count, teamOnly: false) : nil
        default:
            break
        }

        var teamMatch: MatchResult?
        if let program = entry.programPath, program.hasPrefix(sig.appPath + "/") {
            return MatchResult(confidence: .high, specificity: 2000, teamOnly: false)
        }
        for raw in entry.ids {
            let l = raw.lowercased()
            let (core, team) = NameRules.stripGroupPrefixes(l)
            if !sig.isApple && (NameRules.isAppleID(core) || NameRules.isAppleID(l)) { continue }
            if sig.appGroups.contains(l) {
                return MatchResult(confidence: .high, specificity: 1000, teamOnly: false)
            }
            if let m = idMatch(core, sig) ?? (core != l ? idMatch(l, sig) : nil) { return m }
            if let team, let own = sig.teamID, team == own.lowercased() {
                // Same developer, nothing app-specific: other apps of the team (possibly deep in
                // /Applications sub-folders) may share it. Never pre-selected.
                teamMatch = MatchResult(confidence: .low, specificity: 10, teamOnly: true)
            }
        }
        guard let byName = nameMatch(entry, sig) else { return teamMatch }
        if let teamMatch, byName.confidence < teamMatch.confidence { return teamMatch }
        return byName
    }

    /// Exact bundle ID, or `<id>.<anything>` / `<id>-<anything>` (helpers, ByHost, ShipIt…).
    static func idMatch(_ candidate: String, _ sig: AppSignature) -> MatchResult? {
        let stripped = NameRules.strippingHelperSuffixes(candidate)
        for owned in sig.ownedIDs {
            if candidate == owned || stripped == owned {
                return MatchResult(confidence: .high, specificity: owned.count, teamOnly: false)
            }
            // Prefix matches only for specific IDs: "com.foo" alone must not claim "com.foo.other".
            guard owned.split(separator: ".").count >= 3, candidate.count > owned.count,
                  candidate.hasPrefix(owned) else { continue }
            let next = candidate[candidate.index(candidate.startIndex, offsetBy: owned.count)]
            if idSeparators.contains(next) {
                return MatchResult(confidence: .high, specificity: owned.count, teamOnly: false)
            }
        }
        return nil
    }

    static func nameMatch(_ entry: IndexEntry, _ sig: AppSignature) -> MatchResult? {
        let stem = entry.stem
        let (core, _) = NameRules.stripGroupPrefixes(stem)
        if NameRules.isAppleID(core.lowercased()) { return nil }
        if NameRules.isUUID(stem) { return nil }

        if NameRules.isReverseDNS(core) {
            // Someone else's ID that mentions our name: org.telegram.desktop for "Telegram". Weak.
            let comps = core.split(separator: ".").dropFirst().map { NameRules.normalize(String($0)) }
            if comps.contains(where: { sig.strongNames.contains($0) }) {
                return MatchResult(confidence: .low, specificity: 1, teamOnly: false)
            }
            return nil
        }

        let n = NameRules.normalize(stem)
        guard n.count >= 4, !NameRules.genericNames.contains(n) else { return nil }
        if sig.strongNames.contains(n) {
            return MatchResult(confidence: .medium, specificity: n.count, teamOnly: false)
        }
        if sig.weakNames.contains(n) {
            return MatchResult(confidence: .low, specificity: n.count, teamOnly: false)
        }
        if let s = NameRules.strippingTrailingVersion(stem) {
            let d = NameRules.normalize(s)
            if sig.strongNames.contains(d) {
                return MatchResult(confidence: entry.insideVendorFolder ? .medium : .low, specificity: d.count, teamOnly: false)
            }
        }
        // "<AppName><suffix>": SpotifyHelper, Slack-Crashpad, Foo Updater.
        for name in sig.strongNames where n.count > name.count && n.hasPrefix(name) {
            let rest = String(n.dropFirst(name.count))
            if normalizedSuffixWords.contains(rest) || rest.allSatisfy(\.isNumber) {
                return MatchResult(confidence: .low, specificity: name.count, teamOnly: false)
            }
        }
        return nil
    }

    /// True when `other` claims the entry at least as strongly as `ours`.
    static func dominates(_ other: MatchResult, over ours: MatchResult) -> Bool {
        if ours.confidence == .high {
            return other.confidence == .high && other.specificity >= ours.specificity
        }
        if other.confidence != ours.confidence { return other.confidence > ours.confidence }
        return other.specificity >= ours.specificity
    }

    /// Vendor-wide updater/agent shared by all apps of one developer (GoogleUpdater, Keystone, MAU).
    /// Only offered (at low confidence) when the app is the last one of that vendor.
    static func sharedVendorComponentMatch(_ entry: IndexEntry, vendor: String) -> MatchResult? {
        guard let table = VendorComponents.table[vendor] else { return nil }
        for raw in entry.ids {
            let core = NameRules.stripGroupPrefixes(raw.lowercased()).core
            if table.ids.contains(where: { core == $0 || core.hasPrefix($0 + ".") || core.hasPrefix($0) }) {
                return MatchResult(confidence: .low, specificity: 1, teamOnly: false)
            }
        }
        if entry.insideVendorFolder, table.folders.contains(NameRules.normalize(entry.stem)) {
            return MatchResult(confidence: .low, specificity: 1, teamOnly: false)
        }
        return nil
    }

    /// Is this a vendor folder of the app (Application Support/Google for Google Chrome)?
    static func isVendorFolder(_ entry: IndexEntry, _ sig: AppSignature) -> Bool {
        guard entry.isDirectory, entry.location.vendorNesting, !entry.insideVendorFolder else { return false }
        return sig.vendorTokens.contains(NameRules.normalize(entry.stem))
    }
}

enum VendorComponents {
    /// Lowercased ID prefixes and normalised folder names of vendor-wide updaters.
    static let table: [String: (ids: [String], folders: Set<String>)] = [
        "com.google": (["com.google.keystone", "com.google.googleupdater", "com.google.softwareupdate",
                        "com.google.googlesoftwareupdate"], ["googleupdater", "googlesoftwareupdate", "keystone"]),
        "com.microsoft": (["com.microsoft.autoupdate", "com.microsoft.mau", "com.microsoft.update.agent"],
                          ["mau20", "microsoftautoupdate"]),
    ]
}
