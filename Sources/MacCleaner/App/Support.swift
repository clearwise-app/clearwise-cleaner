import AppKit
import CleanerKit
import Foundation
import UniformTypeIdentifiers

/// The app's user-facing name: sidebar, onboarding, copy. Must match CFBundleDisplayName in scripts/build_app.sh
/// (System Settings lists the app under that name, and the onboarding tells the user to look for it).
enum AppInfo {
    static let name = "Clearwise Cleaner"
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

/// Wraps a MainActor setter into an engine `ProgressHandler`, coalesced to ~30 updates/s
/// so a fast scanner cannot flood the main thread. Only the latest value is kept, and a trailing
/// flush always delivers it, so the last update before completion is never dropped.
func progressRelay(_ apply: @escaping @MainActor (ScanProgress) -> Void) -> ProgressHandler {
    let relay = LatestValueRelay(interval: 1.0 / 30.0, apply: apply)
    return { progress in relay.push(progress, urgent: progress.fraction >= 1) }
}

/// Keeps the newest value and hands it to the main thread at most once per `interval`.
/// One scheduled flush at a time (lock + flag); `DispatchQueue.main` rather than a Task per tick.
final class LatestValueRelay<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Value?
    private var scheduled = false
    private var lastFlush: TimeInterval = 0
    private let interval: TimeInterval
    private let apply: @MainActor (Value) -> Void

    init(interval: TimeInterval, apply: @escaping @MainActor (Value) -> Void) {
        self.interval = interval
        self.apply = apply
    }

    /// `urgent` skips the remaining wait (e.g. the final 100 % tick).
    func push(_ value: Value, urgent: Bool = false) {
        lock.lock()
        pending = value
        guard !scheduled else { lock.unlock(); return }
        scheduled = true
        let delay = urgent ? 0 : max(0, lastFlush + interval - ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        if delay == 0 {
            DispatchQueue.main.async { [self] in MainActor.assumeIsolated { flush() } }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in MainActor.assumeIsolated { flush() } }
        }
    }

    @MainActor private func flush() {
        lock.lock()
        let value = pending
        pending = nil
        scheduled = false
        lastFlush = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        if let value { apply(value) }
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
    /// Icon of the dialog (permanent deletion always shows the warning sign).
    var symbol = "trash.fill"
    /// The big size line; off for actions that free no space (startup items).
    var showsSize = true
    /// How the count is spelled ("14 объектов" by default, "14 копий" for duplicates).
    var noun: (Int) -> String = Fmt.items
    var action: @MainActor () -> Void
    /// Shows «Удалить навсегда, минуя Корзину» (cleanups that move to the Trash).
    var offersPermanent = false
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

/// Icons are expensive to fetch, cache them per path. Bounded, and NSCache also drops entries
/// under memory pressure.
@MainActor
enum IconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 600
        return c
    }()
    private static let typeIcons: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 64
        return c
    }()

    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: key)
        return image
    }

    /// The Finder icon if it was fetched already; never touches the disk.
    static func cachedIcon(for url: URL) -> NSImage? {
        cache.object(forKey: url.path as NSString)
    }

    /// Generic icon for the file's type (folder when there is no extension), cached per extension.
    /// Cheap enough for `body`: a stand-in until the real icon arrives.
    static func genericIcon(for url: URL) -> NSImage {
        let ext = url.pathExtension.lowercased()
        let key = ext as NSString
        if let hit = typeIcons.object(forKey: key) { return hit }
        let type: UTType = ext.isEmpty ? .folder : (UTType(filenameExtension: ext) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        typeIcons.setObject(image, forKey: key)
        return image
    }
}
