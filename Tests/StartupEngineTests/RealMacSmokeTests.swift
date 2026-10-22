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

    /// Disable → enable → remove on a throwaway agent this test creates itself (`/bin/sleep`), then cleans up.
    /// Touches nothing else. Run with: STARTUP_REAL_ACTIONS=1 swift test --filter RealMacSmokeTests
    func testThrowawayAgentRoundTrip() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STARTUP_REAL_ACTIONS"] == "1", "set STARTUP_REAL_ACTIONS=1")
        let label = "com.clearwise.test.sleep"
        let env = StartupEnvironment.live
        let plist = env.userAgents.appendingPathComponent(label + ".plist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path), "leftover from an earlier run")
        let job: [String: Any] = ["Label": label, "ProgramArguments": ["/bin/sleep", "600"], "RunAtLoad": true]
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist)
        defer {
            _ = env.run(StartupScanner.launchctl, ["bootout", "gui/\(env.uid)/\(label)"], 10)
            try? FileManager.default.removeItem(at: plist)
        }
        _ = env.run(StartupScanner.launchctl, ["bootstrap", "gui/\(env.uid)", plist.path], 10)
        let scanner = StartupScanner(environment: env)
        func current() throws -> StartupItem { try XCTUnwrap(scanner.launchdItems().first { $0.label == label }) }

        var item = try current()
        print("loaded: \(item.state) signer \(item.signer)")
        XCTAssertTrue(item.isRunning)
        XCTAssertEqual(item.signer, .apple)
        XCTAssertFalse(item.isApple, "an Apple program does not make the job Apple's")

        let off = await StartupActions.perform(.disable, on: [item], environment: env)
        XCTAssertEqual(off.succeeded, [item.id], "\(off.failed)")
        item = try current()
        print("disabled: \(item.state) override \(item.disabledByOverride)")
        XCTAssertTrue(item.disabledByOverride)
        XCTAssertEqual(item.state, .notLoaded)

        let on = await StartupActions.perform(.enable, on: [item], environment: env)
        XCTAssertEqual(on.succeeded, [item.id], "\(on.failed)")
        item = try current()
        print("enabled: \(item.state) override \(item.disabledByOverride)")
        XCTAssertFalse(item.disabledByOverride)
        XCTAssertTrue(item.isRunning)

        let removed = await StartupActions.perform(.remove, on: [item], environment: env)
        XCTAssertEqual(removed.succeeded, [item.id], "\(removed.failed)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertNil(scanner.launchdItems().first { $0.label == label })
        let services = env.run(StartupScanner.launchctl, ["print", "gui/\(env.uid)"], 10).map { LaunchctlOutput.services($0.text) }
        XCTAssertNil(services?[label] ?? nil, "unloaded")
        XCTAssertFalse(services?.keys.contains(label) ?? true)

        // Our own throwaway file in the Trash: delete it for good.
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: trash.path) {
            for name in names where name.hasPrefix(label) {
                try? FileManager.default.removeItem(at: trash.appendingPathComponent(name))
                print("cleaned up ~/.Trash/\(name)")
            }
        } else {
            print("could not list ~/.Trash (no Full Disk Access): \(label).plist stays in the Trash")
        }
    }
}
