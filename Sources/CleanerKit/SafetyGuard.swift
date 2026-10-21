import Foundation

/// Last line of defence: every removal in the app goes through `FileRemover`,
/// and `FileRemover` refuses anything `SafetyGuard` marks as protected.
/// Scanners should not rely on it — they must only emit what is meant to be removed —
/// but a bug in a scanner must never be able to touch the system or the user's core folders.
public enum SafetyGuard {
    public static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

    /// Exact folders that must never be removed themselves (their contents may be).
    private static var protectedExact: Set<String> {
        let h = home.path
        var set: Set<String> = [
            "/", "/Applications", "/Library", "/System", "/Users", "/Volumes", "/private",
            "/private/var", "/private/tmp", "/private/etc", "/usr", "/bin", "/sbin", "/opt", "/cores",
            "/Library/Application Support", "/Library/Caches", "/Library/Preferences", "/Library/Logs",
            "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools",
            "/Library/Frameworks", "/Library/Extensions", "/Library/Receipts", "/private/var/db/receipts",
            h,
        ]
        let userFolders = [
            "Library", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public",
            "Applications", ".Trash",
            "Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Containers",
            "Library/Group Containers", "Library/Logs", "Library/LaunchAgents", "Library/Saved Application State",
            "Library/Cookies", "Library/WebKit", "Library/HTTPStorages", "Library/Developer",
            "Library/Application Scripts", "Library/Mobile Documents", "Library/CloudStorage",
        ]
        for f in userFolders { set.insert(h + "/" + f) }
        return set
    }

    /// Anything inside these is off limits.
    private static var protectedPrefixes: [String] {
        let h = home.path
        return [
            "/System/", "/bin/", "/sbin/", "/usr/bin/", "/usr/lib/", "/usr/libexec/", "/usr/sbin/", "/usr/share/",
            "/private/etc/", "/private/var/vm/", "/Library/Apple/",
            h + "/Library/Keychains/",
            h + "/Library/Mobile Documents/",   // iCloud Drive
            h + "/Library/CloudStorage/",       // Dropbox, Google Drive, OneDrive…
            h + "/Library/Messages/",
            h + "/Library/Mail/",
            h + "/Library/Accounts/",
            h + "/Library/Calendars/",
            h + "/Library/Photos/",
            h + "/Library/Application Support/AddressBook/",
            h + "/Library/Application Support/com.apple.TCC/",
        ]
    }

    /// Returns a human-readable reason if `url` must not be removed, nil if it is allowed.
    public static func refusalReason(for url: URL) -> String? {
        guard url.isFileURL else { return "Не локальный файл" }
        let path = url.standardizedFileURL.path
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let resolved = (parent as NSString).appendingPathComponent(url.lastPathComponent)

        for candidate in Set([path, resolved, stripPrivate(path), stripPrivate(resolved)]) {
            if protectedExact.contains(candidate) { return "Системная или пользовательская папка" }
            for prefix in protectedPrefixes where candidate.hasPrefix(prefix) {
                return "Защищённая область macOS"
            }
            if candidate.hasPrefix("/System/Applications/") || isAppleBundledApp(candidate) {
                return "Встроенное приложение macOS"
            }
        }
        // Very shallow paths (e.g. /Users/name) are never what a cleaner wants.
        if URL(fileURLWithPath: resolved).pathComponents.count < 3 { return "Слишком общий путь" }
        return nil
    }

    public static func isProtected(_ url: URL) -> Bool { refusalReason(for: url) != nil }

    /// True when `url` is inside a Trash folder (user or volume), the only place permanent deletion is allowed.
    public static func isInsideTrash(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path.hasPrefix(home.path + "/.Trash/") { return true }
        // /Volumes/<name>/.Trashes/<uid>/...
        let comps = url.standardizedFileURL.pathComponents
        if comps.count > 4, comps[1] == "Volumes", comps[3] == ".Trashes" { return true }
        return false
    }

    private static func stripPrivate(_ p: String) -> String {
        p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p
    }

    private static func isAppleBundledApp(_ path: String) -> Bool {
        // Safari and a few others live in /Applications but are part of the OS.
        let appleInApplications = ["/Applications/Safari.app"]
        return appleInApplications.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
