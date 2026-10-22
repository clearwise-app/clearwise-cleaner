import Foundation
import CleanerKit

/// Where the scanner looks. Production code uses `.live`; tests build one around a fake home
/// in a temporary directory so the real home folder is never scanned or touched.
struct JunkEnvironment: Sendable {
    /// The user's home folder (`~`).
    var home: URL
    /// System-wide log folders (`/Library/Logs`, `/private/var/log`).
    var systemLogRoots: [URL]
    /// The per-user temporary folder (`$TMPDIR`, i.e. DARWIN_USER_TEMP_DIR). Nil disables the category.
    var temporaryRoot: URL?
    /// Name fragments identifying this app's own files (bundle id, product name) — never offered for removal.
    var ownIdentifiers: [String]
    /// "Now" for age checks; injectable so tests are deterministic.
    var now: Date
    /// Items whose newest content changed within this window are treated as "in use right now" and skipped
    /// (applies to rules with `skipsActiveItems`).
    var activeWindow: TimeInterval = 60
    /// Temporary items must be untouched for at least this long.
    var temporaryMinimumAge: TimeInterval = 3 * 24 * 3600
    /// How many items are sized in parallel.
    var sizingConcurrency: Int = max(4, ProcessInfo.processInfo.activeProcessorCount)
    /// Folders with installed apps (`/Applications`, `~/Applications`), for naming apps' data folders.
    var applicationFolders: [URL] = []
    /// Other apps' containers may be opened (Full Disk Access). Without it macOS shows a blocking consent prompt.
    var readsAppContainers = false
    /// Snapshot of running apps, taken when a scan needs it.
    var runningApps: @Sendable () -> RunningApps = { RunningApps() }
    /// The `docker` command, when installed. Tests inject a fake; the sandbox has none.
    var docker: DockerTool? = nil

    static var live: JunkEnvironment {
        var own = ["MacCleaner", "Clearwise Cleaner", "Clearwise"]
        if let id = Bundle.main.bundleIdentifier, !id.isEmpty { own.append(id) }
        return JunkEnvironment(
            home: FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL,
            systemLogRoots: [URL(fileURLWithPath: "/Library/Logs"), URL(fileURLWithPath: "/private/var/log")],
            temporaryRoot: URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL,
            ownIdentifiers: own,
            now: Date(),
            applicationFolders: [URL(fileURLWithPath: "/Applications"),
                                 FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")],
            readsAppContainers: Permissions.hasFullDiskAccess,
            runningApps: { RunningApps.current() },
            docker: DockerTool.locate(home: FileManager.default.homeDirectoryForCurrentUser)
        )
    }

    /// Environment rooted entirely inside `root` (a temporary directory) for tests.
    static func sandboxed(in root: URL, now: Date = Date()) -> JunkEnvironment {
        JunkEnvironment(
            home: root.appendingPathComponent("home"),
            systemLogRoots: [root.appendingPathComponent("system/Library/Logs"),
                             root.appendingPathComponent("system/private/var/log")],
            temporaryRoot: root.appendingPathComponent("tmp"),
            ownIdentifiers: ["MacCleaner"],
            now: now,
            applicationFolders: [root.appendingPathComponent("Applications")],
            readsAppContainers: true
        )
    }

    func homePath(_ relative: String) -> URL {
        relative.isEmpty ? home : home.appendingPathComponent(relative)
    }

    func isOwnFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ownIdentifiers.contains { lower.contains($0.lowercased()) }
    }
}
