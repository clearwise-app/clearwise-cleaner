import Foundation
import AppKit

public enum Permissions {
    /// Full Disk Access is needed to see other apps' containers, Mail data and some caches.
    /// There is no public API to query it, so probe a TCC-protected file. Cheap and thread-safe:
    /// callers may poll it (once a second while the access flow waits) and run it off the main thread.
    /// Never probe other apps' containers here: that triggers the blocking "access data from other apps" prompt.
    public static var hasFullDiskAccess: Bool {
        let home = SafetyGuard.home
        let probes = [
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
            home.appendingPathComponent("Library/Safari/Bookmarks.plist"),
        ]
        for url in probes where FileManager.default.fileExists(atPath: url.path) {
            if (try? FileHandle(forReadingFrom: url))?.closeFileReturningTrue() == true { return true }
            if (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil { return true }
        }
        return false
    }

    /// System Settings → Privacy & Security → Full Disk Access. The first URL is the macOS 13+ settings
    /// extension; the second is the System Preferences pane id, kept as a fallback.
    public static let fullDiskAccessSettingsURLs: [URL] = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
    ].compactMap(URL.init(string:))

    /// Opens the Full Disk Access list in System Settings (falls back to the older pane URL).
    @MainActor
    public static func openFullDiskAccessSettings() {
        for url in fullDiskAccessSettingsURLs where NSWorkspace.shared.open(url) { return }
    }

    /// Shows the app bundle selected in Finder, so it can be dragged into the Full Disk Access list
    /// when macOS did not add it there by itself.
    @MainActor
    public static func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}

private extension FileHandle {
    func closeFileReturningTrue() -> Bool {
        try? close()
        return true
    }
}
