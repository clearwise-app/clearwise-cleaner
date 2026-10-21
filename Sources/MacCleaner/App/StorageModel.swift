import SwiftUI
import CleanerKit
import SpaceEngine

/// What the startup disk is made of (sidebar widget, Smart Care header). Measured in the background at launch
/// and after every cleanup; the last result is cached so the widget is filled instantly on the next launch.
@MainActor @Observable
final class StorageModel {
    private(set) var breakdown: StorageBreakdown?
    private(set) var isMeasuring = false

    // Debug hooks for `--snapshot`: force the hover / detail states that normally need the mouse.
    var debugHovered: StorageCategory.Kind?
    var debugShowsDetails = false

    @ObservationIgnored private var task: Task<Void, Never>?
    /// False in snapshots: no cache, no disk access.
    @ObservationIgnored let persistsResults: Bool
    private static let cacheKey = "storageBreakdown.v1"
    private static let consentKey = "storageMeasureConsent.v1"

    /// Measuring reads Desktop, Documents and Downloads. Without Full Disk Access that makes macOS ask
    /// for each folder, so the first measurement waits until the user scans something or asks for it —
    /// no permission prompts right at launch.
    private(set) var consented: Bool

    /// - Parameter live: false for snapshots and tests: no cache, no disk access.
    init(live: Bool) {
        persistsResults = live
        consented = live ? UserDefaults.standard.bool(forKey: Self.consentKey) : true
        if live { breakdown = Self.loadCache() }
    }

    /// Launch: measure only when it cannot trigger folder prompts (Full Disk Access) or the user agreed before.
    func refreshIfAllowed(fullDiskAccess: Bool) {
        guard persistsResults, fullDiskAccess || consented else { return }
        refresh()
    }

    /// The user started a scan (folder prompts are expected now) — from here on measuring is allowed.
    func noteUserScan() {
        guard persistsResults, !consented else { return }
        grantConsent()
        if task == nil { refresh() }
    }

    /// Click on the widget: "show what takes space".
    func requestMeasure() {
        grantConsent()
        if task == nil { refresh() }
    }

    private func grantConsent() {
        consented = true
        if persistsResults { UserDefaults.standard.set(true, forKey: Self.consentKey) }
    }

    /// Re-measures now (cancelling a measurement in flight). Called at launch and after any removal.
    func refresh() {
        task?.cancel()
        isMeasuring = true
        task = Task { [weak self] in
            let result = await StorageAnalyzer().breakdown()
            guard !Task.isCancelled, let self else { return }
            withAnimation(Theme.softSpring) { self.breakdown = result }
            self.isMeasuring = false
            self.task = nil
            if self.persistsResults { Self.saveCache(result) }
        }
    }

    /// Cheap check for `refreshSystemState()` (runs on every app activation): measures again only when the
    /// numbers are clearly out of date — free space moved by more than 1 GB, Full Disk Access changed, or the
    /// result is older than 10 minutes.
    func refreshIfStale(disk: DiskUsage?, fullDiskAccess: Bool) {
        guard persistsResults, task == nil, fullDiskAccess || consented else { return }
        guard let b = breakdown else { refresh(); return }
        let freeMoved = disk.map { abs($0.available - b.free) > 1_000_000_000 } ?? false
        if freeMoved || b.fullDiskAccess != fullDiskAccess || Date().timeIntervalSince(b.measuredAt) > 600 {
            refresh()
        }
    }

    /// Fills the model with fixed data (snapshots).
    func apply(_ breakdown: StorageBreakdown?) {
        task?.cancel()
        task = nil
        isMeasuring = breakdown == nil
        self.breakdown = breakdown
    }

    // MARK: Cache

    private static func loadCache() -> StorageBreakdown? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(StorageBreakdown.self, from: data)
    }

    private static func saveCache(_ b: StorageBreakdown) {
        if let data = try? JSONEncoder().encode(b) { UserDefaults.standard.set(data, forKey: cacheKey) }
    }
}
