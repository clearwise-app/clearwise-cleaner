import SwiftUI
import CleanerKit
import UninstallEngine

/// Shared app state: navigation, permissions, disk usage, installed apps, pending confirmation.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    var selection: AppModule = .smartCare
    var hasFullDiskAccess: Bool
    var fdaBannerDismissed = false
    var disk: DiskUsage?
    var confirmation: Confirmation?
    var isDropTargeted = false
    /// Full-screen cleaning scene while a confirmed cleanup runs (see `runCleaning`).
    var cleaning: CleaningSession?

    enum AppsState { case notLoaded, loading, loaded }
    var apps: [InstalledApp] = []
    var appsState: AppsState = .notLoaded
    var appsProgress = ScanProgress(phase: "", fraction: 0)
    @ObservationIgnored private var appsTask: Task<[InstalledApp], Never>?

    let smartCare = SmartCareModel()
    let junk = JunkModel()
    let uninstaller = UninstallerModel()
    let oldFiles = OldFilesModel()
    let duplicates = DuplicatesModel()
    let diskMap = DiskMapModel()
    /// Disk usage by category (sidebar widget). Measured at launch and after every cleanup.
    let storage: StorageModel

    init(probeSystem: Bool = true) {
        hasFullDiskAccess = probeSystem ? Permissions.hasFullDiskAccess : true
        disk = probeSystem ? DiskUsage.startupVolume() : nil
        storage = StorageModel(live: probeSystem)
        if probeSystem { storage.refreshIfAllowed(fullDiskAccess: hasFullDiskAccess) }
        smartCare.app = self
        junk.app = self
        uninstaller.app = self
        oldFiles.app = self
        duplicates.app = self
        diskMap.app = self
    }

    var showsFDABanner: Bool { !hasFullDiskAccess && !fdaBannerDismissed }

    func refreshSystemState() {
        hasFullDiskAccess = Permissions.hasFullDiskAccess
        disk = DiskUsage.startupVolume()
        storage.refreshIfStale(disk: disk, fullDiskAccess: hasFullDiskAccess)
    }

    /// Loads (once) the installed apps list; concurrent callers share one inventory run.
    @discardableResult
    func loadApps(force: Bool = false) async -> [InstalledApp] {
        if appsState == .loaded && !force { return apps }
        if let appsTask { return await appsTask.value }
        appsState = .loading
        appsProgress = ScanProgress(phase: "Ищем приложения", fraction: 0)
        let relay = progressRelay { [weak self] in self?.appsProgress = $0 }
        let task = Task { await AppInventory().installedApps(progress: relay) }
        appsTask = task
        let result = await task.value
        apps = result
        appsState = .loaded
        appsTask = nil
        return result
    }

    // MARK: Shared actions for every module (wave 2 contracts)

    /// Opens the Full Disk Access flow (explanation + steps + live detection).
    /// Modules call this from FDA banners, PartialAccessNote and CompletionView's «Дать доступ».
    /// Placeholder until the onboarding workstream replaces it: opens System Settings directly.
    func presentAccessSheet() {
        Permissions.openFullDiskAccessSettings()
    }

    /// «Очистить Корзину…» from CompletionView: confirm (permanent), then empty ~/.Trash through
    /// the cleaning overlay. Placeholder until the shell workstream implements it.
    func requestEmptyTrash() {}

    func ask(_ confirmation: Confirmation) {
        withAnimation(Theme.spring) { self.confirmation = confirmation }
    }

    func dismissConfirmation() {
        withAnimation(Theme.spring) { confirmation = nil }
    }

    func select(_ module: AppModule) {
        withAnimation(Theme.softSpring) { selection = module }
    }

    /// Drag & drop of an .app anywhere on the window (or the Dock icon) opens it in the uninstaller.
    @discardableResult
    func handleDrop(_ urls: [URL]) -> Bool {
        guard let app = urls.first(where: { $0.pathExtension.lowercased() == "app" }) else { return false }
        select(.uninstaller)
        uninstaller.open(appURL: app)
        return true
    }

    /// Called after any removal so every screen stays consistent.
    func didRemove(_ result: RemovalResult) {
        let removed = Set(result.removed.map(\.standardizedFileURL))
        guard !removed.isEmpty else { return }
        junk.forget(removed)
        oldFiles.forget(removed)
        duplicates.forget(removed)
        uninstaller.forget(removed)
        if storage.persistsResults { storage.refresh() }
        refreshSystemState()
    }
}
