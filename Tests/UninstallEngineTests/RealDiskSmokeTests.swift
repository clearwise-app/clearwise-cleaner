import XCTest
import CleanerKit
@testable import UninstallEngine

/// Read-only run against the real disk. Prints what would be offered; never removes anything.
/// Run with: UNINSTALL_REAL_DISK=1 xcrun xctest -XCTest RealDiskSmokeTests <bundle>
final class RealDiskSmokeTests: XCTestCase {
    func testPrintRealDiskResults() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UNINSTALL_REAL_DISK"] == "1", "set UNINSTALL_REAL_DISK=1")

        var t = Date()
        let apps = await AppInventory().installedApps()
        print("INVENTORY: \(apps.count) apps in \(ms(t)) ms (with sizes)")
        for a in apps {
            print("  \(a.name) | \(a.bundleID ?? "-") | team \(a.teamID ?? "-") | \(ByteFormat.string(a.size)) | system=\(a.isSystemApp) mas=\(a.isAppStore)")
        }

        let finder = RemnantFinder()
        await finder.setInstalledApps(apps)
        await finder.setAvoidPrivacyPrompts(true) // never read inside other apps' containers here (TCC prompt)
        let wanted = (ProcessInfo.processInfo.environment["UNINSTALL_APPS"] ?? "Telegram,Google Chrome,Code,Claude")
            .split(separator: ",").map(String.init)
        for name in wanted {
            guard let app = apps.first(where: { $0.name == name && !$0.isSystemApp }) else { continue }
            t = Date()
            let remnants = await finder.remnants(for: app)
            print("\nREMNANTS for \(app.name) (\(app.bundleID ?? "-")): \(remnants.count) items, \(ms(t)) ms")
            for r in remnants {
                print("  [\(r.kind.rawValue)] \(r.confidence) admin=\(r.requiresAdmin) \(ByteFormat.string(r.item.size))  \(r.item.url.path)")
            }
        }

        if ProcessInfo.processInfo.environment["UNINSTALL_ORPHAN_NO_QUIET"] == "1" {
            await finder.setOrphanQuietPeriod(0)
            print("\n(orphan 7-day quiet period disabled for this run)")
        }
        t = Date()
        let orphans = await finder.orphans(installed: apps, progress: nil)
        print("\nORPHANS: \(orphans.count) groups in \(ms(t)) ms")
        for g in orphans.prefix(10) {
            print("  \(g.displayName) [\(g.id)] \(ByteFormat.string(g.totalSize))")
            for r in g.remnants { print("     \(r.confidence) admin=\(r.requiresAdmin) \(r.item.url.path)") }
        }
    }

    private func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }
}
