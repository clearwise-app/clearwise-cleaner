import Foundation
import AppKit
import CleanerKit

public enum AppUninstaller {
    static let quitTimeout: TimeInterval = 5

    /// Quits the app if running, unloads its launch agents, moves remnants and then the bundle (if removeBundle) to Trash.
    /// System apps are refused. If the app does not quit within ~5 s nothing is removed.
    public static func uninstall(_ app: InstalledApp, remnants: [AppRemnant], removeBundle: Bool = true) async -> RemovalResult {
        if app.isSystemApp || SafetyGuard.isProtected(app.url) {
            return RemovalResult(failed: [RemovalFailure(url: app.url, reason: "Системное приложение нельзя удалить")])
        }
        if isRunning(app) {
            let quit = await requestQuit(app)
            if !quit {
                let reason = "Приложение запущено"
                var result = RemovalResult()
                if removeBundle { result.failed.append(RemovalFailure(url: app.url, reason: reason)) }
                result.failed += remnants.map { RemovalFailure(url: $0.item.url, reason: reason) }
                return result
            }
        }
        let plan = RemovalPlan(app: app, remnants: remnants, removeBundle: removeBundle,
                               bundleNeedsAdmin: removeBundle && !userCanMove(app.url))
        return await execute(plan)
    }

    /// Removes leftovers only (used for orphans and "reset app").
    public static func remove(_ remnants: [AppRemnant]) async -> RemovalResult {
        await execute(RemovalPlan(app: nil, remnants: remnants, removeBundle: false, bundleNeedsAdmin: false))
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

    static func execute(_ plan: RemovalPlan) async -> RemovalResult {
        for agent in plan.launchAgentsToUnload { bootout(agent) }
        var result = RemovalResult()
        if !plan.userItems.isEmpty {
            result.merge(await FileRemover.moveToTrash(plan.userItems, knownSizes: plan.knownSizes))
        }
        if !plan.adminItems.isEmpty {
            // One administrator prompt for everything root-owned (bundle last when it needs admin).
            result.merge(await FileRemover.moveToTrashAsAdmin(plan.adminItems, knownSizes: plan.knownSizes))
        }
        if let bundle = plan.userBundle {
            result.merge(await FileRemover.moveToTrash([bundle], knownSizes: plan.knownSizes))
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
            if r.kind == .launchAgents, url.pathExtension == "plist" { launchAgentsToUnload.append(url) }
            if r.requiresAdmin { adminItems.append(url) } else { userItems.append(url) }
        }
        if removeBundle, let app, !app.isSystemApp {
            if app.size > 0 { knownSizes[app.url] = app.size }
            if bundleNeedsAdmin { adminItems.append(app.url) } else { userBundle = app.url }
        }
    }
}
