import XCTest
@testable import StartupEngine

/// Read-only run against this Mac. Prints what the screen would list; never changes anything.
/// Run with: STARTUP_REAL_MAC=1 swift test --filter RealMacSmokeTests
/// STARTUP_REAL_MAC_BTM=1 also reads Background Task Management: macOS then asks for the administrator password.
final class RealMacSmokeTests: XCTestCase {
    func testPrintRealStartupItems() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STARTUP_REAL_MAC"] == "1", "set STARTUP_REAL_MAC=1")
        let scanner = StartupScanner()
        var t = Date()
        let plists = scanner.launchdItems()
        print("LAUNCHD: \(plists.count) items in \(Int(Date().timeIntervalSince(t) * 1000)) ms")
        t = Date()
        let btm = ProcessInfo.processInfo.environment["STARTUP_REAL_MAC_BTM"] == "1" ? scanner.backgroundTasks() : .unavailable
        print("BTM: readable=\(btm.isReadable) \(btm.records.count) records in \(Int(Date().timeIntervalSince(t) * 1000)) ms")
        for i in scanner.merging(plists, with: btm) {
            print("  [\(i.group)] \(i.displayName) | \(i.label) | \(i.source) | \(i.state) | enabled=\(i.isEnabled)"
                  + " override=\(i.disabledByOverride) settings=\(i.disabledInSettings) apple=\(i.isApple) | \(i.signer)"
                  + " | owner \(i.ownerName ?? "-") \(i.ownerBundleID ?? "-") | \(i.plist?.path ?? "-") | \(i.program ?? "-")"
                  + " | disable: \(StartupActions.refusal(.disable, for: i) ?? "ok") remove: \(StartupActions.refusal(.remove, for: i) ?? "ok")")
        }
    }
}
