import Foundation

/// Last line of defence: every removal in the app goes through `FileRemover`,
/// and `FileRemover` refuses anything `SafetyGuard` marks as protected.
/// Scanners should not rely on it — they must only emit what is meant to be removed —
/// but a bug in a scanner must never be able to touch the system or the user's core folders.
///
/// All comparisons are case-insensitive (APFS is), and both `/private/…` and short
/// (`/etc`, `/var`, `/tmp`) spellings are checked, because Foundation strips `/private`.
public enum SafetyGuard {
    public static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

    /// Exact folders that must never be removed themselves (their contents may be). Lowercased.
    private static let protectedExact: Set<String> = {
        let h = home.path
        var set: Set<String> = [
            "/", "/Applications", "/Library", "/System", "/Users", "/Users/Shared", "/Volumes", "/private",
            "/private/var", "/private/tmp", "/private/etc", "/usr", "/usr/local", "/bin", "/sbin", "/opt", "/cores",
            "/Library/Application Support", "/Library/Caches", "/Library/Preferences", "/Library/Logs",
            "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools",
            "/Library/Frameworks", "/Library/Extensions", "/Library/Receipts", "/private/var/db",
            "/private/var/db/receipts", "/private/var/folders",
            h,
        ]
        let userFolders = [
            "Library", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public",
            "Applications", ".Trash", ".ssh", ".gnupg", ".config",
            "Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Containers",
            "Library/Group Containers", "Library/Logs", "Library/LaunchAgents", "Library/Saved Application State",
            "Library/Cookies", "Library/WebKit", "Library/HTTPStorages", "Library/Developer",
            "Library/Application Scripts", "Library/Fonts", "Library/Audio", "Library/Input Methods",
            // iPhone backups may be removed one by one, never the whole folder.
            "Library/Application Support/MobileSync", "Library/Application Support/MobileSync/Backup",
        ]
        for f in userFolders { set.insert(h + "/" + f) }
        // Every protected area is also protected as a folder, not only its contents.
        for p in protectedPrefixList { set.insert(String(p.dropLast())) }
        return Set(set.map { $0.lowercased() })
    }()

    /// Anything inside these (and the folders themselves) is off limits. Each ends with "/".
    private static let protectedPrefixList: [String] = {
        let h = home.path
        return [
            "/System/", "/bin/", "/sbin/", "/usr/bin/", "/usr/lib/", "/usr/libexec/", "/usr/sbin/", "/usr/share/",
            "/private/etc/", "/private/var/vm/", "/private/var/db/dslocal/", "/private/var/db/TCC/",
            "/Library/Apple/", "/Library/Keychains/", "/Library/Security/",
            "/private/var/root/", "/private/var/at/", "/private/var/audit/", "/private/var/protected/",
            "/Library/Managed Preferences/", "/Library/SystemExtensions/", "/Library/StagedExtensions/",
            "/Library/Updates/",
            h + "/Library/Keychains/",
            h + "/Library/Mobile Documents/",   // iCloud Drive
            h + "/Library/CloudStorage/",       // Dropbox, Google Drive, OneDrive…
            h + "/Library/Messages/",
            h + "/Library/Mail/",
            h + "/Library/Safari/",
            h + "/Library/Accounts/",
            h + "/Library/Calendars/",
            h + "/Library/Photos/",
            h + "/Library/Passes/",
            h + "/Library/Sharing/",
            h + "/Library/IdentityServices/",
            h + "/Library/Application Support/AddressBook/",
            h + "/Library/Application Support/com.apple.TCC/",
            h + "/Library/Group Containers/group.com.apple.",
        ]
    }()

    private static let protectedPrefixes: [String] = protectedPrefixList.map { $0.lowercased() }

    /// Returns a human-readable reason if `url` must not be removed, nil if it is allowed.
    public static func refusalReason(for url: URL) -> String? {
        guard url.isFileURL else { return String(localized: "Не локальный файл", bundle: .module) }
        let candidates = spellings(of: url)

        for c in candidates {
            if protectedExact.contains(c) { return String(localized: "Системная или пользовательская папка", bundle: .module) }
            for prefix in protectedPrefixes where c.hasPrefix(prefix) {
                return String(localized: "Защищённая область macOS", bundle: .module)
            }
            if c.hasPrefix("/system/applications/") || isAppleBundledApp(c) {
                return String(localized: "Встроенное приложение macOS", bundle: .module)
            }
            if isAppleGroupContainer(c) { return String(localized: "Данные встроенных приложений macOS", bundle: .module) }
            if isAppleSystemConfig(c) { return String(localized: "Системная служба macOS", bundle: .module) }
            if isMediaLibrary(c) { return String(localized: "Медиатека (Фото, Музыка, TV)", bundle: .module) }
        }
        // Very shallow paths (e.g. /Users/name) are never what a cleaner wants.
        if candidates.contains(where: { URL(fileURLWithPath: $0).pathComponents.count < 3 }) {
            return String(localized: "Слишком общий путь", bundle: .module)
        }
        return nil
    }

    public static func isProtected(_ url: URL) -> Bool { refusalReason(for: url) != nil }

    /// True when `url` is really inside a Trash folder (user or volume) — the only place permanent
    /// deletion is allowed. The parent is resolved, so `~/.Trash/link-to-home/Documents` is NOT inside.
    public static func isInsideTrash(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let path = (parent.path as NSString).appendingPathComponent(url.lastPathComponent).lowercased()
        let trash = home.appendingPathComponent(".Trash").resolvingSymlinksInPath().path.lowercased()
        if path.hasPrefix(trash + "/") { return true }
        // /Volumes/<name>/.Trashes/<uid>/...
        let comps = URL(fileURLWithPath: path).pathComponents
        if comps.count > 4, comps[1] == "volumes", comps[3] == ".trashes" { return true }
        return false
    }

    // MARK: - Helpers

    /// All lowercased spellings of the path to compare: as given, with the parent resolved,
    /// with and without the `/private` prefix.
    static func spellings(of url: URL) -> Set<String> {
        let std = trimSlash(url.standardizedFileURL.path)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let resolved = trimSlash((parent as NSString).appendingPathComponent(url.lastPathComponent))
        var out = Set<String>()
        for p in [std, resolved] {
            out.insert(p.lowercased())
            out.insert(stripPrivate(p).lowercased())
            out.insert(addPrivate(p).lowercased())
        }
        return out
    }

    private static func trimSlash(_ p: String) -> String {
        p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }

    private static func stripPrivate(_ p: String) -> String {
        p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p
    }

    private static func addPrivate(_ p: String) -> String {
        for short in ["/etc", "/var", "/tmp"] where p == short || p.hasPrefix(short + "/") {
            return "/private" + p
        }
        return p
    }

    private static func isAppleBundledApp(_ lowerPath: String) -> Bool {
        // Safari lives in /Applications (as a link into the system Cryptex) but is part of the OS.
        let appleInApplications = ["/applications/safari.app"]
        return appleInApplications.contains { lowerPath == $0 || lowerPath.hasPrefix($0 + "/") }
    }

    /// `~/Library/Group Containers/<id>` of Apple (Notes, Reminders, iWork sharing, iCloud, Mail, Home, Shortcuts…).
    private static func isAppleGroupContainer(_ lowerPath: String) -> Bool {
        let base = home.path.lowercased() + "/library/group containers/"
        guard lowerPath.hasPrefix(base) else { return false }
        let first = lowerPath.dropFirst(base.count).split(separator: "/").first.map(String.init) ?? ""
        return isAppleGroupContainerName(first)
    }

    /// A Group Containers folder name that belongs to Apple: `group.com.apple.*`, `<TEAM>.com.apple.*`, and the
    /// ones without that pattern — `com.apple.bird` (iCloud), `com.apple.MailPersonaStorage`,
    /// `group.is.workflow.*` (Shortcuts), `systemgroup.*`.
    public static func isAppleGroupContainerName(_ name: String) -> Bool {
        let n = name.lowercased()
        let prefixes = ["group.com.apple.", "com.apple.", "group.is.workflow.", "is.workflow.", "systemgroup.", "group.apple."]
        return prefixes.contains { n.hasPrefix($0) } || n.contains(".com.apple.")
    }

    /// `com.apple.*` launchd jobs and preferences in the system Library (never an app's leftover).
    private static func isAppleSystemConfig(_ lowerPath: String) -> Bool {
        for dir in ["/library/launchdaemons/", "/library/launchagents/", "/library/preferences/"]
        where lowerPath.hasPrefix(dir) {
            let name = lowerPath.dropFirst(dir.count).split(separator: "/").first.map(String.init) ?? ""
            if name.hasPrefix("com.apple.") { return true }
        }
        return false
    }

    /// Photos / Music / TV / iPhoto libraries and anything inside them.
    private static func isMediaLibrary(_ lowerPath: String) -> Bool {
        let exts = [".photoslibrary", ".musiclibrary", ".tvlibrary", ".photolibrary", ".aplibrary", ".migratedphotolibrary"]
        return lowerPath.split(separator: "/").contains { comp in exts.contains { comp.hasSuffix($0) } }
    }
}
