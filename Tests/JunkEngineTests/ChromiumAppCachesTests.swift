import XCTest
import CleanerKit
@testable import JunkEngine

/// Electron / Chromium app caches against a fake home in a temporary directory (see `JunkEngineTests`).
final class ChromiumAppCachesTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home") }
    private let fm = FileManager.default
    private let support = "Library/Application Support"

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ChromiumAppCachesTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, root.path.hasPrefix(fm.temporaryDirectory.path) { try? fm.removeItem(at: root) }
    }

    // MARK: Helpers

    @discardableResult
    private func file(_ relative: String, bytes: Int = 4096, in base: URL? = nil, data: Data? = nil) throws -> URL {
        let url = (base ?? home).appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data ?? Data(repeating: 0x5A, count: bytes)).write(to: url)
        return url
    }

    /// A Chromium user data folder: `Local State` plus the given folders, each holding one file.
    private func userData(_ relative: String, _ folders: [String]) throws {
        try file("\(relative)/Local State", bytes: 100)
        for folder in folders { try file("\(relative)/\(folder)/data_0", bytes: 10_000) }
    }

    private func fakeApp(_ name: String, bundleName: String, framework: String = "Electron Framework.framework") throws {
        let app = root.appendingPathComponent("Applications/\(name).app/Contents")
        try fm.createDirectory(at: app.appendingPathComponent("Frameworks/\(framework)"), withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": bundleName], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Info.plist"))
    }

    private func environment(running: RunningApps = RunningApps()) -> JunkEnvironment {
        var env = JunkEnvironment.sandboxed(in: root, now: Date().addingTimeInterval(3600))
        env.runningApps = { running }
        return env
    }

    private func scan(_ env: JunkEnvironment) async -> (JunkScanner, [JunkCategory]) {
        let scanner = JunkScanner(environment: env)
        return (scanner, await scanner.scan())
    }

    private func items(_ id: String, in list: [JunkCategory]) -> Set<String> {
        Set((list.first { $0.id == id }?.items ?? []).map { rel($0.url) })
    }

    private func rel(_ url: URL) -> String {
        let p = url.path
        guard let r = p.range(of: "/home/") else { return p }
        return String(p[r.upperBound...])
    }

    // MARK: Tests

    func testOffersOnlyRegenerableFoldersOfChromiumApps() async throws {
        let slack = "\(support)/Slack"
        try userData(slack, ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
                             "Service Worker/CacheStorage", "Service Worker/ScriptCache", "Service Worker/Database",
                             "Local Storage", "IndexedDB", "Session Storage", "WebStorage", "databases", "blob_storage",
                             "logs", "Crashpad", "Partitions/workspace/Cache", "Partitions/workspace/IndexedDB",
                             "Partitions/workspace/Local Storage"])
        try file("\(slack)/Cookies", bytes: 8_000)
        try file("\(slack)/Preferences", bytes: 8_000)
        try userData("\(support)/Code", ["CachedData", "CachedExtensionVSIXs", "User/globalStorage", "Backups"])
        try userData("\(support)/Microsoft/Teams", ["Cache", "IndexedDB"])
        // Not a Chromium user data folder (no `Local State`): never looked into.
        try file("\(support)/SomeApp/Cache/x", bytes: 10_000)
        // A symlinked cache folder is not followed.
        try file("elsewhere/precious/doc", bytes: 10_000)
        try userData("\(support)/Linked", [])
        try fm.createSymbolicLink(at: home.appendingPathComponent("\(support)/Linked/Cache"),
                                  withDestinationURL: home.appendingPathComponent("elsewhere/precious"))

        let (scanner, result) = await scan(environment())
        let found = items(JunkCategoryID.chromiumAppCaches, in: result)
        XCTAssertEqual(found, [
            "\(slack)/Cache", "\(slack)/Code Cache", "\(slack)/GPUCache", "\(slack)/DawnGraphiteCache",
            "\(slack)/DawnWebGPUCache", "\(slack)/Partitions/workspace/Cache",
            "\(support)/Code/CachedData", "\(support)/Code/CachedExtensionVSIXs",
            "\(support)/Microsoft/Teams/Cache",
        ])
        let all = result.flatMap(\.items).map { rel($0.url) }
        for forbidden in ["Service Worker", "Local Storage", "IndexedDB", "Session Storage", "WebStorage", "databases",
                          "blob_storage", "Cookies", "Preferences", "Local State", "User", "SomeApp", "Linked", "precious"] {
            XCTAssertFalse(all.contains { $0.contains(forbidden) }, "\(forbidden) must never be offered")
        }

        let category = try XCTUnwrap(result.first { $0.id == JunkCategoryID.chromiumAppCaches })
        XCTAssertEqual(category.risk, .safe)
        XCTAssertTrue(category.isSelectedByDefault)
        let partition = try XCTUnwrap(category.items.first { rel($0.url) == "\(slack)/Partitions/workspace/Cache" })
        let note = await scanner.note(for: partition.url)
        XCTAssertEqual(note, "Slack · workspace · Cache")
    }

    func testRunningAppsAreSkipped() async throws {
        try userData("\(support)/Slack", ["Cache"])
        try userData("\(support)/discord", ["Cache"])
        try userData("Library/Containers/com.example.notes/Data/\(support)/Notes", ["Cache"])
        try userData("\(support)/Obsidian", ["Cache"])

        var running = RunningApps()
        running.userDataFolders = [FS.key(home.appendingPathComponent("\(support)/Slack"))]
        running.names = ["discord"]          // Discord.app is running, its folder is lowercase
        running.bundleIDs = ["com.example.notes"]
        let (_, result) = await scan(environment(running: running))
        XCTAssertEqual(items(JunkCategoryID.chromiumAppCaches, in: result), ["\(support)/Obsidian/Cache"])

        // The clean-time check finds the same folder from an item.
        let item = home.appendingPathComponent("\(support)/Slack/Cache")
        XCTAssertEqual(ChromiumAppCaches.owningUserDataFolder(of: item).map(FS.key),
                       FS.key(home.appendingPathComponent("\(support)/Slack")))
        let partitionItem = home.appendingPathComponent("\(support)/Slack/Partitions/a/Cache")
        try file("\(support)/Slack/Partitions/a/Cache/x")
        XCTAssertTrue(running.uses(try XCTUnwrap(ChromiumAppCaches.owningUserDataFolder(of: partitionItem))))
    }

    func testRunningProcessesAreReadFromTheirCommandLine() throws {
        let marker = home.appendingPathComponent("\(support)/Fake App")
        let process = Process()
        // The extra argument becomes the script's $0, so the shell just sleeps with it on its command line.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30; exit 0", "--user-data-dir=\(marker.path)"]
        try process.run()
        defer { process.terminate() }
        Thread.sleep(forTimeInterval: 0.2)
        let running = RunningApps.current()
        XCTAssertTrue(running.userDataFolders.contains(FS.key(marker)), "\(running.userDataFolders)")
        XCTAssertTrue(running.uses(marker))

        XCTAssertEqual(RunningApps.outermostBundle(of: "/Applications/Slack.app/Contents/Frameworks/Slack Helper (GPU).app/Contents/MacOS/Slack Helper (GPU)"),
                       "/Applications/Slack.app")
        XCTAssertNil(RunningApps.outermostBundle(of: "/usr/bin/true"))
    }

    func testBrowsersStayInBrowserCategory() async throws {
        let chrome = "\(support)/Google/Chrome"
        try userData(chrome, ["GrShaderCache", "component_crx_cache", "Default/Cache", "Default/Code Cache"])
        let edge = "\(support)/Microsoft Edge"
        try userData(edge, ["GrShaderCache", "component_crx_cache"])
        let opera = "\(support)/com.operasoftware.Opera"
        try userData(opera, ["Cache", "GPUCache"])
        try userData("\(support)/Chromium", ["GrShaderCache"])   // unknown browser: only its top-level shader cache

        let (_, result) = await scan(environment())
        let browsers = items(JunkCategoryID.browserCaches, in: result)
        XCTAssertTrue(browsers.isSuperset(of: ["\(chrome)/GrShaderCache", "\(chrome)/Default/Cache", "\(edge)/GrShaderCache",
                                               "\(opera)/Cache", "\(opera)/GPUCache"]))
        XCTAssertEqual(items(JunkCategoryID.chromiumAppCaches, in: result), ["\(support)/Chromium/GrShaderCache"])
    }

    func testContainersOnlyWithFullDiskAccess() async throws {
        let slack = "Library/Containers/com.tinyspeck.slackmacgap/Data/\(support)/Slack"
        try userData(slack, ["Cache", "Local Storage"])
        try userData("Library/Containers/com.apple.Something/Data/\(support)/Web", ["Cache"])

        var env = environment()
        let (_, withAccess) = await scan(env)
        XCTAssertEqual(items(JunkCategoryID.chromiumAppCaches, in: withAccess), ["\(slack)/Cache"])

        env.readsAppContainers = false
        let (_, withoutAccess) = await scan(env)
        XCTAssertTrue(items(JunkCategoryID.chromiumAppCaches, in: withoutAccess).isEmpty)
    }

    func testGroupContainerCachesOfThirdPartyAppsOnlyWithFullDiskAccess() async throws {
        let telegram = "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram"
        try file("\(telegram)/Library/Caches/media/x", bytes: 20_000)
        try file("\(telegram)/appstore/account-1/postbox/db", bytes: 20_000)   // messages: not a cache
        try file("Library/Group Containers/group.com.apple.notes/Library/Caches/x", bytes: 20_000)
        try file("Library/Group Containers/UBF8T346G9.com.apple.share/Library/Caches/x", bytes: 20_000)
        try file("Library/Group Containers/ABCDE12345.com.adguard.safari.AdGuard/Library/Caches/rules", bytes: 20_000)

        var env = environment()
        let (_, withAccess) = await scan(env)
        XCTAssertEqual(items(JunkCategoryID.userCaches, in: withAccess), ["\(telegram)/Library/Caches/media"])

        env.readsAppContainers = false
        let (_, withoutAccess) = await scan(env)
        XCTAssertTrue(items(JunkCategoryID.userCaches, in: withoutAccess).isEmpty)
    }

    func testItemsAreLabelledWithInstalledAppName() async throws {
        try fakeApp("Visual Studio Code", bundleName: "Code")
        try fakeApp("Discord", bundleName: "Discord")
        try fakeApp("Not Chromium", bundleName: "Plain", framework: "Sparkle.framework")
        try userData("\(support)/Code", ["CachedData"])
        try userData("\(support)/discord", ["Cache"])
        try userData("\(support)/Plain", ["Cache"])

        let (scanner, result) = await scan(environment())
        let category = try XCTUnwrap(result.first { $0.id == JunkCategoryID.chromiumAppCaches })
        var notes: [String: String] = [:]
        for item in category.items { notes[rel(item.url)] = await scanner.note(for: item.url) }
        XCTAssertEqual(notes, [
            "\(support)/Code/CachedData": "Visual Studio Code · CachedData",
            "\(support)/discord/Cache": "Discord · Cache",
            "\(support)/Plain/Cache": "Plain · Cache",
        ])
    }

    func testRecentlyWrittenCacheIsSkipped() async throws {
        try userData("\(support)/Slack", ["Cache"])
        var env = environment()
        env.now = Date()
        let (_, result) = await scan(env)
        XCTAssertTrue(items(JunkCategoryID.chromiumAppCaches, in: result).isEmpty)
    }

    // MARK: Real disk (read-only, opt-in)

    /// `JUNK_REAL_SCAN=1 swift test --filter ChromiumAppCachesTests.testRealDiskReadOnly`
    /// Lists the Chromium apps' data folders in the real home, which of them are in use, and what each would
    /// offer once closed. Never cleans anything.
    func testRealDiskReadOnly() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JUNK_REAL_SCAN"] == "1", "Set JUNK_REAL_SCAN=1 to run")
        let env = JunkEnvironment.live
        let running = RunningApps.current()
        var lines = ["CHROMIUM APPS (containers \(env.readsAppContainers ? "read" : "skipped, no Full Disk Access")):"]
        for folder in ChromiumAppCaches.userDataFolders(in: env) {
            let caches = ChromiumAppCaches.caches(in: folder).map { ($0.1, TreeSizer.measure($0.0).size) }
            let total = caches.reduce(0) { $0 + $1.1 }
            lines.append("  \(running.uses(folder) ? "RUNNING" : "idle   ") \(ByteFormat.string(total))  \(folder.path)")
            for (label, size) in caches where size > 0 { lines.append("      \(ByteFormat.string(size))  \(label)") }
        }
        print(lines.joined(separator: "\n"))
    }
}
