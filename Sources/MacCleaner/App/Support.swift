import AppKit
import CleanerKit
import Foundation

/// Wraps a MainActor setter into an engine `ProgressHandler`, throttled to ~30 updates/s
/// so a fast scanner cannot flood the main thread.
func progressRelay(_ apply: @escaping @MainActor (ScanProgress) -> Void) -> ProgressHandler {
    let gate = ThrottleGate(interval: 1.0 / 30.0)
    return { progress in
        guard gate.allow(force: progress.fraction >= 1) else { return }
        Task { @MainActor in apply(progress) }
    }
}

final class ThrottleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last: TimeInterval = 0
    private let interval: TimeInterval

    init(interval: TimeInterval) { self.interval = interval }

    func allow(force: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if force || now - last >= interval {
            last = now
            return true
        }
        return false
    }
}

struct DiskUsage: Equatable {
    var name: String
    var total: Int64
    var available: Int64
    var used: Int64 { max(0, total - available) }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func startupVolume() -> DiskUsage? {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeLocalizedNameKey]
        guard let v = try? url.resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity,
              let available = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskUsage(name: v.volumeLocalizedName ?? "Macintosh HD", total: Int64(total), available: available)
    }
}

/// A destructive action waiting for the user's explicit OK.
struct Confirmation: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var count: Int
    var bytes: Int64
    var confirmTitle: String
    /// Emptying the Trash: cannot be undone.
    var permanent = false
    var needsAdmin = false
    var warning: String? = nil
    var tint: ModuleTint
    var action: @MainActor () -> Void
}

enum Finder {
    @MainActor static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @MainActor static func reveal(_ url: URL) { reveal([url]) }

    @MainActor static func openTrash() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
    }
}

/// Icons are expensive to fetch, cache them per path.
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for url: URL) -> NSImage {
        if let hit = cache[url.path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[url.path] = image
        return image
    }
}
