import Foundation
import CleanerKit

// CONTRACT (used by the UI — keep these signatures):
//   public actor AppInventory { public init(); public func installedApps(progress: ProgressHandler?) async -> [InstalledApp] }
//   public actor RemnantFinder {
//       public init()
//       public func remnants(for app: InstalledApp) async -> [AppRemnant]
//       public func orphans(installed: [InstalledApp], progress: ProgressHandler?) async -> [OrphanGroup]
//   }
//   public enum AppUninstaller {
//       public static func uninstall(_ app: InstalledApp, remnants: [AppRemnant], removeBundle: Bool) async -> RemovalResult
//       public static func remove(_ remnants: [AppRemnant]) async -> RemovalResult
//       public static func isRunning(_ app: InstalledApp) -> Bool
//   }
// STUB — to be replaced by the UninstallEngine implementation.

public actor AppInventory {
    public init() {}
    public func installedApps(progress: ProgressHandler? = nil) async -> [InstalledApp] { [] }
}

public actor RemnantFinder {
    public init() {}
    public func remnants(for app: InstalledApp) async -> [AppRemnant] { [] }
    public func orphans(installed: [InstalledApp], progress: ProgressHandler? = nil) async -> [OrphanGroup] { [] }
}

public enum AppUninstaller {
    /// Quits the app if running, unloads its launch agents, moves bundle (if removeBundle) and remnants to Trash.
    public static func uninstall(_ app: InstalledApp, remnants: [AppRemnant], removeBundle: Bool = true) async -> RemovalResult { RemovalResult() }
    /// Removes leftovers only (used for orphans and "reset app").
    public static func remove(_ remnants: [AppRemnant]) async -> RemovalResult { RemovalResult() }
    public static func isRunning(_ app: InstalledApp) -> Bool { false }
}
