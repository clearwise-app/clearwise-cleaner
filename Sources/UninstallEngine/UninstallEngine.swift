// UninstallEngine — installed apps inventory, leftover discovery, full uninstall, orphans.
//
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
//
// Additional public API: RemnantFinder.setInstalledApps(_:), RemnantFinder.invalidate().
//
// Files:
//   AppInventory.swift   — scanning /Applications, ~/Applications
//   BundleInfo.swift     — Info.plist, embedded helper IDs, code signature (Team ID, app groups)
//   Locations.swift      — search roots (injectable) and every location where traces live
//   LocationIndex.swift  — one-time listing of all locations with extracted identifiers
//   NameRules.swift      — normalisation, reverse-DNS detection, stoplists
//   Matcher.swift        — AppSignature + confidence rules
//   RemnantFinder.swift  — remnants(for:) with the cross-app false-positive guard
//   OrphanFinder.swift   — orphans(installed:progress:)
//   AppUninstaller.swift — quit → unload agents → trash remnants → trash bundle
