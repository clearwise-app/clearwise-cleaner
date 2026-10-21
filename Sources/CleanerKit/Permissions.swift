import Foundation
import AppKit

public enum Permissions {
    /// Full Disk Access is needed to see other apps' containers, Mail data and some caches.
    /// There is no public API to query it, so probe a TCC-protected file.
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

    @MainActor
    public static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

private extension FileHandle {
    func closeFileReturningTrue() -> Bool {
        try? close()
        return true
    }
}
