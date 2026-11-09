import Foundation
import AppKit
import CleanerKit

public enum AppUninstaller {
    static let quitTimeout: TimeInterval = 5

    /// Quits the app if running, unloads its launch agents, moves remnants and then the bundle (if removeBundle) to Trash.
    /// System apps are refused. If the app does not quit within ~5 s nothing is removed.
    public static func uninstall(_ app: InstalledApp, remnants: [AppRemnant], removeBundle: Bool = true,
                                 progress: RemovalProgressHandler? = nil) async -> RemovalResult {
        await uninstall(app, remnants: remnants, removeBundle: removeBundle, deferAdmin: false, progress: progress).result
    }

    /// Root-owned parts left for a later `finish` call, so several apps share one administrator prompt.
    public struct PendingAdmin: Sendable {
        /// Root-owned items, in order (each app's bundle after its leftovers).
        public var adminItems: [URL] = []
        /// User-movable bundles of apps that also had root-owned parts: still moved after them («bundle last»).
        public var userBundles: [URL] = []
        public var knownSizes: [URL: Int64] = [:]
        public init() {}
        public var isEmpty: Bool { adminItems.isEmpty && userBundles.isEmpty }
        public mutating func merge(_ other: PendingAdmin) {
            adminItems += other.adminItems
            userBundles += other.userBundles
            knownSizes.merge(other.knownSizes) { a, _ in a }
        }
    }

    /// Batch uninstall: like `uninstall`, but an app's root-owned part (and then its bundle) is returned
    /// instead of done. Run `finish` with the merged parts of all apps: one password for the whole batch.
    public static func uninstallDeferringAdmin(_ app: InstalledApp, remnants: [AppRemnant],
                                               progress: RemovalProgressHandler? = nil) async -> (result: RemovalResult, pending: PendingAdmin) {
        await uninstall(app, remnants: remnants, removeBundle: true, deferAdmin: true, progress: progress)
    }

    /// The deferred root-owned items of several apps under one administrator prompt, then their bundles.
    public static func finish(_ pending: PendingAdmin, progress: RemovalProgressHandler? = nil) async -> RemovalResult {
        var result = RemovalResult()
        if !pending.adminItems.isEmpty {
            result.merge(await FileRemover.moveToTrashAsAdmin(pending.adminItems, knownSizes: pending.knownSizes, progress: progress))
        }
        if !pending.userBundles.isEmpty {
            result.merge(await FileRemover.moveToTrash(pending.userBundles, knownSizes: pending.knownSizes, progress: progress))
        }
        return result
    }

    static func uninstall(_ app: InstalledApp, remnants: [AppRemnant], removeBundle: Bool, deferAdmin: Bool,
                          progress: RemovalProgressHandler?) async -> (result: RemovalResult, pending: PendingAdmin) {
        if app.isSystemApp || SafetyGuard.isProtected(app.url) {
            return (RemovalResult(failed: [RemovalFailure(url: app.url, reason: String(localized: "Системное приложение нельзя удалить", bundle: .module))]), PendingAdmin())
        }
        if isRunning(app) {
            let quit = await requestQuit(app)
            if !quit {
                let reason = RemovalFailure.appRunning
                var result = RemovalResult()
                if removeBundle { result.failed.append(RemovalFailure(url: app.url, reason: reason)) }
                result.failed += remnants.map { RemovalFailure(url: $0.item.url, reason: reason) }
                return (result, PendingAdmin())
            }
        }
        let plan = RemovalPlan(app: app, remnants: remnants, removeBundle: removeBundle,
                               bundleNeedsAdmin: removeBundle && !userCanMove(app.url))
        guard deferAdmin, !plan.adminItems.isEmpty else { return (await execute(plan, progress: progress), PendingAdmin()) }
        // Everything the user can do now; the root-owned part and then the bundle wait for `finish`.
        for agent in plan.launchAgentsToUnload { bootout(agent) }
        var result = RemovalResult()
        if !plan.userItems.isEmpty {
            result.merge(await FileRemover.moveToTrash(plan.userItems, knownSizes: plan.knownSizes, progress: progress))
        }
        var pending = PendingAdmin()
        pending.adminItems = plan.adminItems
        pending.userBundles = plan.userBundle.map { [$0] } ?? []
        pending.knownSizes = plan.knownSizes
        return (result, pending)
    }

    /// Removes leftovers only (used for orphans and "reset app").
    public static func remove(_ remnants: [AppRemnant], progress: RemovalProgressHandler? = nil) async -> RemovalResult {
        await execute(RemovalPlan(app: nil, remnants: remnants, removeBundle: false, bundleNeedsAdmin: false), progress: progress)
    }

    public static func isRunning(_ app: InstalledApp) -> Bool {
        !runningInstances(of: app).isEmpty
    }

    // MARK: - Internals

    static func runningInstances(of app: InstalledApp) -> [NSRunningApplication] {
        let path = app.url.standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.filter { running in
            if let url = running.bundleURL?.standardizedFileURL, url.path == path { return true }
            if let id = app.bundleID, running.bundleIdentifier == id,
               running.bundleURL == nil || running.bundleURL?.standardizedFileURL.path == path {
                return true
            }
            return false
        }
    }

    /// Politely asks the app to quit and waits. Never force-kills.
    static func requestQuit(_ app: InstalledApp) async -> Bool {
        for instance in runningInstances(of: app) { _ = instance.terminate() }
        let deadline = Date().addingTimeInterval(quitTimeout)
        while Date() < deadline {
            if !isRunning(app) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return !isRunning(app)
    }

    static func execute(_ plan: RemovalPlan, progress: RemovalProgressHandler? = nil) async -> RemovalResult {
        for agent in plan.launchAgentsToUnload { bootout(agent) }
        var result = RemovalResult()
        if !plan.userItems.isEmpty {
            result.merge(await FileRemover.moveToTrash(plan.userItems, knownSizes: plan.knownSizes, progress: progress))
        }
        if !plan.adminItems.isEmpty {
            // One administrator prompt for everything root-owned (bundle last when it needs admin).
            result.merge(await FileRemover.moveToTrashAsAdmin(plan.adminItems, knownSizes: plan.knownSizes, progress: progress))
        }
        if let bundle = plan.userBundle {
            result.merge(await FileRemover.moveToTrash([bundle], knownSizes: plan.knownSizes, progress: progress))
        }
        return result
    }

    /// `launchctl bootout gui/<uid> <plist>` — errors (not loaded) are ignored.
    static func bootout(_ plist: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())", plist.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {}
    }

    static func userCanMove(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().path
        return access(parent, W_OK) == 0 && access(url.path, W_OK) == 0
    }
}

/// Pure description of what will be done, in order. Kept separate so it can be unit-tested
/// without touching the disk.
struct RemovalPlan {
    /// Unloading a job is not undoable from the Trash, so it needs more certainty than moving a file:
    /// exact match, user domain, real file (not a link), not Apple's, and not refused by SafetyGuard.
    static func mayUnload(_ r: AppRemnant) -> Bool {
        let url = r.item.url
        guard r.confidence == .high, !r.requiresAdmin, !SafetyGuard.isProtected(url) else { return false }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return false }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return !NameRules.isAppleID(name)
    }

    var launchAgentsToUnload: [URL] = []
    var userItems: [URL] = []
    /// Root-owned items, including the bundle (last) if it needs admin rights.
    var adminItems: [URL] = []
    /// The bundle, moved last, when the user can move it.
    var userBundle: URL?
    var knownSizes: [URL: Int64] = [:]

    init(app: InstalledApp?, remnants: [AppRemnant], removeBundle: Bool, bundleNeedsAdmin: Bool) {
        let bundlePath = app?.url.standardizedFileURL.path
        for r in remnants {
            let url = r.item.url
            // Never let a remnant list smuggle in the bundle or something inside it.
            if let bundlePath, url.standardizedFileURL.path == bundlePath || url.standardizedFileURL.path.hasPrefix(bundlePath + "/") {
                continue
            }
            knownSizes[url] = r.item.size
            if r.kind == .launchAgents, url.pathExtension == "plist", Self.mayUnload(r) { launchAgentsToUnload.append(url) }
            if r.requiresAdmin { adminItems.append(url) } else { userItems.append(url) }
        }
        if removeBundle, let app, !app.isSystemApp {
            if app.size > 0 { knownSizes[app.url] = app.size }
            if bundleNeedsAdmin { adminItems.append(app.url) } else { userBundle = app.url }
        }
    }
}
