import Foundation
import Security

/// What the code signature tells us about a bundle.
struct CodeSignInfo: Sendable, Hashable {
    var teamID: String?
    /// `com.apple.security.application-groups`
    var appGroups: [String] = []
}

enum CodeSigning {
    /// Reads Team ID and app groups without validating the signature (fast, offline).
    static func info(for url: URL) -> CodeSignInfo {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return CodeSignInfo()
        }
        var cfInfo: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &cfInfo) == errSecSuccess,
              let dict = cfInfo as? [String: Any] else {
            return CodeSignInfo()
        }
        var result = CodeSignInfo()
        result.teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        if let ent = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
           let groups = ent["com.apple.security.application-groups"] as? [String] {
            result.appGroups = groups
        }
        return result
    }

    static func teamID(for url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var cfInfo: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &cfInfo) == errSecSuccess,
              let dict = cfInfo as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// Info.plist facts about an app bundle, read directly (no `Bundle` cache, so it is always fresh).
struct BundleInfo: Sendable {
    let url: URL
    let bundleID: String?
    let displayName: String?
    let bundleName: String?
    let executable: String?
    let version: String?
    let infoPlistURL: URL?

    /// Name shown to the user: CFBundleDisplayName → CFBundleName → file name.
    var name: String {
        let fileName = url.deletingPathExtension().lastPathComponent
        for candidate in [displayName, bundleName] {
            if let c = candidate?.trimmingCharacters(in: .whitespaces), !c.isEmpty { return c }
        }
        return fileName
    }

    init?(appURL: URL) {
        url = appURL
        let fm = FileManager.default
        var plistURL: URL?
        let contents = appURL.appendingPathComponent("Contents/Info.plist")
        if fm.fileExists(atPath: contents.path) {
            plistURL = contents
        } else {
            // iOS apps on Apple silicon: Foo.app/Wrapper/Foo.app/Info.plist (WrappedBundle symlink).
            let wrapped = appURL.appendingPathComponent("WrappedBundle/Info.plist")
            if fm.fileExists(atPath: wrapped.path) {
                plistURL = wrapped
            } else if let inner = try? fm.contentsOfDirectory(at: appURL.appendingPathComponent("Wrapper"), includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) {
                let p = inner.appendingPathComponent("Info.plist")
                if fm.fileExists(atPath: p.path) { plistURL = p }
            }
        }
        infoPlistURL = plistURL
        let dict = plistURL.flatMap(Self.readPlist) ?? [:]
        if dict.isEmpty && plistURL == nil {
            // A folder ending in .app without Info.plist is not something we can reason about.
            return nil
        }
        bundleID = (dict["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        displayName = dict["CFBundleDisplayName"] as? String
        bundleName = dict["CFBundleName"] as? String
        executable = dict["CFBundleExecutable"] as? String
        version = (dict["CFBundleShortVersionString"] as? String) ?? (dict["CFBundleVersion"] as? String)
    }

    static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// CFBundleIdentifier of any bundle (plug-in, appex, kext…).
    static func bundleIdentifier(of bundleURL: URL) -> String? {
        for rel in ["Contents/Info.plist", "Info.plist", "Resources/Info.plist"] {
            let p = bundleURL.appendingPathComponent(rel)
            if let id = readPlist(p)?["CFBundleIdentifier"] as? String, !id.isEmpty { return id }
        }
        return nil
    }

    /// Bundle IDs of helpers/extensions embedded in the app (login items, appex, XPC services…).
    /// Third-party frameworks (e.g. Sparkle) are excluded: only IDs that share the app's vendor prefix are kept.
    func nestedBundleIDs() -> [String] {
        let rels = [
            "Contents/Library/LoginItems", "Contents/Library/LaunchServices", "Contents/Library/SystemExtensions",
            "Contents/Library/QuickLook", "Contents/Library/Spotlight", "Contents/PlugIns", "Contents/XPCServices",
            "Contents/Helpers", "Contents/MacOS", "Contents/Extensions",
        ]
        let fm = FileManager.default
        var ids: [String] = []
        for rel in rels {
            let dir = url.appendingPathComponent(rel)
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for item in items where !item.pathExtension.isEmpty {
                if let id = Self.bundleIdentifier(of: item) { ids.append(id) }
            }
        }
        guard let main = bundleID?.lowercased() else { return ids }
        let vendor = main.split(separator: ".").prefix(2).joined(separator: ".")
        return ids.filter { id in
            let l = id.lowercased()
            return l != main && (l.hasPrefix(vendor + ".") || l == vendor)
        }
    }
}
