import XCTest
import CleanerKit
@testable import JunkEngine

/// All fixtures live in a fresh temporary directory; the scanner is pointed at a fake home inside it,
/// so the real home folder is never scanned by these tests and nothing real is ever removed.
final class JunkEngineTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home") }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("JunkEngineTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Only our own fixture directory inside $TMPDIR.
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

    private func plist(_ relative: String, _ object: Any) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        return try file(relative, data: data)
    }

    /// `now` defaults to one hour ahead, so freshly created fixtures are not "in use right now".
    private func scan(now: Date = Date().addingTimeInterval(3600),
                      progress: ProgressHandler? = nil) async -> (JunkScanner, [JunkCategory]) {
        let scanner = JunkScanner(environment: .sandboxed(in: root, now: now))
        let result = await scanner.scan(progress: progress)
        return (scanner, result)
    }

    private func category(_ id: String, in list: [JunkCategory]) -> JunkCategory? { list.first { $0.id == id } }

    private func relPaths(_ c: JunkCategory?) -> [String] {
        (c?.items ?? []).map { rel($0.url) }
    }

    private func rel(_ url: URL) -> String {
        let p = url.path
        guard let r = p.range(of: "/home/") else { return p }
        return String(p[r.upperBound...])
    }

    private func assertNoOverlap(_ list: [JunkCategory], file: StaticString = #filePath, line: UInt = #line) {
        let keys = list.flatMap { c in c.items.map { (c.id, $0.url.standardizedFileURL.path.lowercased()) } }
        for (i, a) in keys.enumerated() {
            for b in keys[(i + 1)...] {
                XCTAssertFalse(a.1 == b.1 || a.1.hasPrefix(b.1 + "/") || b.1.hasPrefix(a.1 + "/"),
                               "Overlap: \(a.0) \(a.1) vs \(b.0) \(b.1)", file: file, line: line)
            }
        }
    }

    // MARK: Caches

    func testUserCachesFoundAndSizedPerChildFolder() async throws {
        try file("Library/Caches/com.foo.app/blob.bin", bytes: 100_000)
        try file("Library/Caches/com.foo.app/sub/deeper/more.bin", bytes: 20_000)
        try file("Library/Caches/com.bar.tool/data", bytes: 50_000)
        try file("Library/Caches/CloudKit/keep", bytes: 50_000)
        try file("Library/Caches/com.apple.bird/keep", bytes: 50_000)
        try file("Library/Caches/com.apple.Safari.SafeBrowsing/keep", bytes: 50_000)
        try file("Library/Caches/com.example.MacCleaner/own", bytes: 50_000)

        let (_, result) = await scan()
        let caches = try XCTUnwrap(category(JunkCategoryID.userCaches, in: result))
        XCTAssertEqual(relPaths(caches), ["Library/Caches/com.foo.app", "Library/Caches/com.bar.tool"])
        XCTAssertEqual(caches.risk, .safe)
        XCTAssertTrue(caches.isSelectedByDefault)
        XCTAssertGreaterThanOrEqual(caches.items[0].size, 120_000)
        XCTAssertGreaterThanOrEqual(caches.items[1].size, 50_000)
        XCTAssertTrue(caches.items[0].isDirectory)
    }

    func testCachesBeingWrittenRightNowAreSkipped() async throws {
        try file("Library/Caches/com.busy.app/live", bytes: 10_000)
        let (_, now) = await scan(now: Date())
        XCTAssertNil(category(JunkCategoryID.userCaches, in: now))
        let (_, later) = await scan()
        XCTAssertNotNil(category(JunkCategoryID.userCaches, in: later))
    }

    func testBrowserCachesDoNotDoubleCountWithUserCaches() async throws {
        try file("Library/Caches/Google/Chrome/Default/Cache/Cache_Data/f1", bytes: 200_000)
        try file("Library/Caches/Google/OtherGoogleThing/x", bytes: 10_000)
        try file("Library/Caches/com.apple.Safari/WebKitCache/f", bytes: 30_000)
        try file("Library/Caches/Firefox/Profiles/abc.default/cache2/entries/e", bytes: 40_000)
        try file("Library/Caches/com.unrelated/x", bytes: 5_000)
        let chrome = "Library/Application Support/Google/Chrome"
        try file("\(chrome)/Default/GPUCache/data_0", bytes: 8_000)
        try file("\(chrome)/Profile 1/Code Cache/js/x", bytes: 8_000)
        try file("\(chrome)/GrShaderCache/s", bytes: 8_000)
        // Profile data that must never be offered:
        try file("\(chrome)/Default/History", bytes: 8_000)
        try file("\(chrome)/Default/Cookies", bytes: 8_000)
        try file("\(chrome)/Default/Login Data", bytes: 8_000)
        try file("Library/Containers/com.apple.Safari/Data/Library/Caches/com.apple.Safari/x", bytes: 8_000)

        let (scanner, result) = await scan()
        let browsers = try XCTUnwrap(category(JunkCategoryID.browserCaches, in: result))
        XCTAssertEqual(Set(relPaths(browsers)), [
            "Library/Caches/Google/Chrome",
            "Library/Caches/com.apple.Safari",
            "Library/Caches/Firefox",
            "\(chrome)/Default/GPUCache",
            "\(chrome)/Profile 1/Code Cache",
            "\(chrome)/GrShaderCache",
            "Library/Containers/com.apple.Safari/Data/Library/Caches/com.apple.Safari",
        ])
        let caches = try XCTUnwrap(category(JunkCategoryID.userCaches, in: result))
        // The Google folder is split: its non-browser child stays in user caches.
        XCTAssertEqual(Set(relPaths(caches)), ["Library/Caches/Google/OtherGoogleThing", "Library/Caches/com.unrelated"])

        let all = result.flatMap(\.items).map { rel($0.url) }
        XCTAssertFalse(all.contains { $0.contains("History") || $0.contains("Cookies") || $0.contains("Login Data") })
        assertNoOverlap(result)

        let chromeItem = try XCTUnwrap(browsers.items.first { rel($0.url) == "Library/Caches/Google/Chrome" })
        let note = await scanner.note(for: chromeItem.url)
        XCTAssertEqual(note, "Google Chrome · кэш")
    }

    func testDeveloperJunk() async throws {
        try file("Library/Developer/Xcode/DerivedData/App-abcdef/Build/x", bytes: 300_000)
        try file("Library/Developer/Xcode/DerivedData/ModuleCache.noindex/m", bytes: 10_000)
        try file("Library/Developer/Xcode/Archives/2026-10-01/App 01.10.2026.xcarchive/Info.plist", bytes: 5_000)
        try file("Library/Developer/Xcode/iOS DeviceSupport/iPhone18,4 27.2/Symbols/x", bytes: 50_000)
        try file("Library/Developer/CoreSimulator/Caches/dyld/x", bytes: 5_000)
        try file("Library/Caches/Homebrew/downloads/abc--wget.bottle.tar.gz", bytes: 70_000)
        try file("Library/Caches/yarn/v6/pkg", bytes: 6_000)   // lowercase on disk, rule says "Yarn"
        try file(".npm/_cacache/content-v2/x", bytes: 9_000)
        try file(".gradle/caches/modules-2/x", bytes: 9_000)
        try file(".cargo/registry/cache/index.crates.io-1/serde.crate", bytes: 9_000)

        let (_, result) = await scan()
        XCTAssertEqual(Set(relPaths(category(JunkCategoryID.xcodeDerivedData, in: result))),
                       ["Library/Developer/Xcode/DerivedData/App-abcdef", "Library/Developer/Xcode/DerivedData/ModuleCache.noindex"])
        let archives = try XCTUnwrap(category(JunkCategoryID.xcodeArchives, in: result))
        XCTAssertEqual(archives.risk, .review)
        XCTAssertEqual(archives.items.map(\.name), ["App 01.10.2026.xcarchive"])
        XCTAssertEqual(category(JunkCategoryID.xcodeDeviceSupport, in: result)?.risk, .review)
        XCTAssertNotNil(category(JunkCategoryID.simulatorCaches, in: result))
        XCTAssertEqual(category(JunkCategoryID.cargoRegistry, in: result)?.risk, .review)

        let packages = Set(relPaths(category(JunkCategoryID.packageCaches, in: result)).map { $0.lowercased() })
        XCTAssertTrue(packages.contains("library/caches/homebrew/downloads"))
        XCTAssertTrue(packages.contains("library/caches/yarn"))
        XCTAssertTrue(packages.contains(".npm/_cacache"))
        XCTAssertTrue(packages.contains(".gradle/caches/modules-2"))
        // Homebrew and Yarn live in ~/Library/Caches but must not be counted there as well.
        XCTAssertNil(category(JunkCategoryID.userCaches, in: result))
        assertNoOverlap(result)
    }

    // MARK: Broken items

    func testBrokenPreferencesDetection() async throws {
        _ = try plist("Library/Preferences/com.good.app.plist", ["key": "value"])
        try file("Library/Preferences/com.bad.app.plist", data: Data("this is <not> a plist".utf8))
        try file("Library/Preferences/com.empty.app.plist", data: Data())
        try file("Library/Preferences/com.apple.finder.plist", data: Data("broken but Apple's".utf8))
        try file("Library/Preferences/ByHost/com.bad.host.ABC.plist", data: Data("garbage".utf8))
        try file("Library/Preferences/notes.txt", data: Data("garbage".utf8))

        let (_, result) = await scan()
        let broken = try XCTUnwrap(category(JunkCategoryID.brokenPreferences, in: result))
        XCTAssertEqual(Set(broken.items.map(\.name)), ["com.bad.app.plist", "com.empty.app.plist", "com.bad.host.ABC.plist"])
        XCTAssertEqual(broken.risk, .review)
        XCTAssertFalse(broken.isSelectedByDefault)
    }

    func testBrokenLaunchAgentDetection() async throws {
        let existing = try file("Applications/Tool.app/Contents/MacOS/tool", bytes: 100)
        let missing = home.appendingPathComponent("Applications/Gone.app/Contents/MacOS/gone").path
        _ = try plist("Library/LaunchAgents/com.ok.agent.plist", ["Label": "ok", "ProgramArguments": [existing.path, "--x"]])
        _ = try plist("Library/LaunchAgents/com.gone.agent.plist", ["Label": "gone", "Program": missing])
        _ = try plist("Library/LaunchAgents/com.gone2.agent.plist", ["Label": "gone2", "ProgramArguments": [missing]])
        _ = try plist("Library/LaunchAgents/com.volume.agent.plist", ["Label": "v", "Program": "/Volumes/NoSuchVolume-\(UUID())/bin/x"])
        _ = try plist("Library/LaunchAgents/com.path.agent.plist", ["Label": "p", "ProgramArguments": ["python3", "-m", "x"]])
        try file("Library/LaunchAgents/com.garbage.agent.plist", data: Data("nope".utf8))

        let (scanner, result) = await scan()
        let agents = try XCTUnwrap(category(JunkCategoryID.brokenLaunchAgents, in: result))
        XCTAssertEqual(Set(agents.items.map(\.name)),
                       ["com.gone.agent.plist", "com.gone2.agent.plist", "com.garbage.agent.plist"])
        XCTAssertEqual(agents.risk, .review)
        let gone = try XCTUnwrap(agents.items.first { $0.name == "com.gone.agent.plist" })
        let note = await scanner.note(for: gone.url)
        XCTAssertEqual(note, "Программа не найдена: \(missing)")
    }

    // MARK: User files

    func testOldInstallersAreReviewAndNotSelected() async throws {
        try file("Downloads/Some App 2.3.dmg", bytes: 80_000)
        try file("Desktop/Installers/driver.pkg", bytes: 20_000)
        try file("Downloads/macOS.xip", bytes: 10_000)
        try file("Downloads/report.pdf", bytes: 10_000)
        try file("Downloads/a/b/too-deep.dmg", bytes: 10_000)

        let (_, result) = await scan()
        let installers = try XCTUnwrap(category(JunkCategoryID.installers, in: result))
        XCTAssertEqual(installers.risk, .review)
        XCTAssertFalse(installers.isSelectedByDefault)
        XCTAssertEqual(installers.items.map(\.name), ["Some App 2.3.dmg", "driver.pkg", "macOS.xip"])
    }

    func testIOSBackupsAreCautionWithDeviceNames() async throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = Date(timeIntervalSince1970: 1_760_000_000)
        let base = "Library/Application Support/MobileSync/Backup"
        _ = try plist("\(base)/00008110-AAAA/Info.plist", ["Device Name": "iPhone Старый", "Last Backup Date": old])
        try file("\(base)/00008110-AAAA/Manifest.db", bytes: 50_000)
        _ = try plist("\(base)/00008120-BBBB/Info.plist", ["Device Name": "iPad Новый", "Last Backup Date": new])
        try file("\(base)/00008120-BBBB/Manifest.db", bytes: 10_000)

        let (scanner, result) = await scan()
        let backups = try XCTUnwrap(category(JunkCategoryID.iosBackups, in: result))
        XCTAssertEqual(backups.risk, .caution)
        XCTAssertFalse(backups.isSelectedByDefault)
        let notes = await scanner.notes
        let newest = try XCTUnwrap(backups.items.first { $0.name == "00008120-BBBB" })
        let oldest = try XCTUnwrap(backups.items.first { $0.name == "00008110-AAAA" })
        XCTAssertTrue(notes[newest.url]?.hasPrefix("iPad Новый") == true)
        XCTAssertTrue(notes[newest.url]?.hasSuffix("самая свежая") == true)
        XCTAssertTrue(notes[oldest.url]?.hasPrefix("iPhone Старый") == true)
        XCTAssertFalse(notes[oldest.url]?.contains("самая свежая") == true)
    }

    func testTemporaryFilesNeedThreeDaysOfInactivity() async throws {
        let tmp = root.appendingPathComponent("tmp")
        try file("old-session/data.bin", bytes: 30_000, in: tmp)
        try file("com.apple.something/x", bytes: 30_000, in: tmp)

        let (_, soon) = await scan(now: Date().addingTimeInterval(24 * 3600))
        XCTAssertNil(category(JunkCategoryID.temporaryFiles, in: soon))

        let (_, later) = await scan(now: Date().addingTimeInterval(4 * 24 * 3600))
        let temp = try XCTUnwrap(category(JunkCategoryID.temporaryFiles, in: later))
        XCTAssertEqual(temp.items.map(\.name), ["old-session"])
    }

    func testLogsAndCrashReportsAreSeparate() async throws {
        try file("Library/Logs/SomeApp/app.log", bytes: 10_000)
        try file("Library/Logs/DiagnosticReports/SomeApp-2026-10-01.ips", bytes: 5_000)
        let sys = root.appendingPathComponent("system/private/var/log")
        try file("wifi.log.0.bz2", bytes: 5_000, in: sys)

        let (_, result) = await scan()
        XCTAssertEqual(relPaths(category(JunkCategoryID.userLogs, in: result)), ["Library/Logs/SomeApp"])
        XCTAssertEqual(category(JunkCategoryID.crashReports, in: result)?.items.map(\.name), ["SomeApp-2026-10-01.ips"])
        XCTAssertEqual(category(JunkCategoryID.systemLogs, in: result)?.risk, .review)
        assertNoOverlap(result)
    }

    func testRotatedLogNames() {
        XCTAssertTrue(SpecialCollectors.isRotatedLog("system.log.0.gz"))
        XCTAssertTrue(SpecialCollectors.isRotatedLog("keybagd.log.0"))
        XCTAssertTrue(SpecialCollectors.isRotatedLog("wifi.log.2.bz2"))
        XCTAssertFalse(SpecialCollectors.isRotatedLog("system.log"))
        XCTAssertFalse(SpecialCollectors.isRotatedLog("install.log"))
        XCTAssertFalse(SpecialCollectors.isRotatedLog("2026"))
    }

    // MARK: Results shape

    func testEmptyCategoriesAreDroppedAndSortedBySize() async throws {
        let (_, empty) = await scan()
        XCTAssertTrue(empty.isEmpty)

        try file("Library/Caches/com.big/x", bytes: 500_000)
        try file("Library/Logs/Small/x.log", bytes: 4_096)
        try file("Library/Caches/com.zero/.keep", bytes: 0)   // zero-byte → dropped
        let (_, result) = await scan()
        XCTAssertEqual(result.map(\.id), [JunkCategoryID.userCaches, JunkCategoryID.userLogs])
        XCTAssertTrue(result.allSatisfy { !$0.items.isEmpty })
        XCTAssertEqual(relPaths(result[0]), ["Library/Caches/com.big"])
    }

    func testProgressIsMonotonicAndFinishes() async throws {
        for i in 0..<20 { try file("Library/Caches/com.app\(i)/x", bytes: 1000) }
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var values: [ScanProgress] = []
        }
        let box = Box()
        _ = await scan { p in box.lock.lock(); box.values.append(p); box.lock.unlock() }
        let fractions = box.values.map(\.fraction)
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertEqual(box.values.last?.fraction, 1)
        XCTAssertEqual(box.values.last?.phase, "Готово")
        XCTAssertTrue(box.values.contains { $0.phase == "Кэш приложений" })
    }

    // MARK: Cleaning (temp fixtures only)

    func testCleaningMovesFixtureToTrashAndRefusesForeignItems() async throws {
        let target = try file("Library/Caches/com.fixture.junkengine-test/x", bytes: 1024).deletingLastPathComponent()
        let outsider = try file("Documents/keep-me.txt", bytes: 100)

        let (_, result) = await scan()
        let caches = try XCTUnwrap(category(JunkCategoryID.userCaches, in: result))
        XCTAssertEqual(caches.items.count, 1)

        let foreign = FileItem(url: outsider, size: 100, isDirectory: false)
        let removal = await JunkCleaner.clean(caches.items + [foreign], in: caches)
        XCTAssertEqual(removal.removed.map(\.lastPathComponent), [target.lastPathComponent])
        XCTAssertEqual(removal.failed.map(\.url), [outsider])
        XCTAssertGreaterThan(removal.freedBytes, 0)
        XCTAssertFalse(fm.fileExists(atPath: target.path))
        XCTAssertTrue(fm.fileExists(atPath: outsider.path))
    }

    // MARK: JetBrains

    func testJetBrainsOffersOnlyRegenerableFoldersAndNeverLocalHistory() async throws {
        let ide = "Library/Caches/JetBrains/IntelliJIdea2024.1"
        for d in ["caches", "index", "tmp", "log", "jcef_cache", "LocalHistory", "other", "frameworks"] {
            try file("\(ide)/\(d)/data.bin", bytes: 20_000)
        }
        try file("\(ide)/LocalHistory/changes.storageData", bytes: 50_000)
        try file("\(ide)/loose-file.bin", bytes: 20_000)
        try file("Library/Caches/JetBrains/PyCharm2024.2/caches/c", bytes: 20_000)
        try file("Library/Caches/JetBrains/PyCharm2024.2/LocalHistory/h", bytes: 20_000)
        try file("Library/Caches/com.foo.app/blob", bytes: 20_000)

        let (_, result) = await scan()
        let jb = try XCTUnwrap(category(JunkCategoryID.jetbrainsCaches, in: result))
        XCTAssertEqual(jb.risk, .review)
        XCTAssertFalse(jb.isSelectedByDefault)
        XCTAssertEqual(Set(relPaths(jb)), [
            "\(ide)/caches", "\(ide)/index", "\(ide)/tmp", "\(ide)/log", "\(ide)/jcef_cache",
            "Library/Caches/JetBrains/PyCharm2024.2/caches",
        ])
        // Nothing under JetBrains is offered by any other category, and LocalHistory by none at all.
        let all = result.flatMap { c in c.items.map { (c.id, rel($0.url)) } }
        XCTAssertFalse(all.contains { $0.1.contains("LocalHistory") }, "LocalHistory must never be offered")
        XCTAssertTrue(all.filter { $0.1.contains("JetBrains") }.allSatisfy { $0.0 == JunkCategoryID.jetbrainsCaches })
        XCTAssertEqual(relPaths(category(JunkCategoryID.userCaches, in: result)), ["Library/Caches/com.foo.app"])
        assertNoOverlap(result)
    }

    func testJetBrainsSymlinkedSubfolderIsNotOffered() async throws {
        let ide = home.appendingPathComponent("Library/Caches/JetBrains/GoLand2024.1")
        try fm.createDirectory(at: ide, withIntermediateDirectories: true)
        let elsewhere = root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try file("precious", bytes: 20_000, in: elsewhere)
        try fm.createSymbolicLink(at: ide.appendingPathComponent("caches"), withDestinationURL: elsewhere)
        let (_, result) = await scan()
        XCTAssertNil(category(JunkCategoryID.jetbrainsCaches, in: result))
    }

    // MARK: Planner performance

    func testClaimedPathsSemantics() {
        var c = ClaimedPaths()
        c.claim("/a/b/c")
        XCTAssertTrue(c.coversOrInside("/a/b/c"))
        XCTAssertTrue(c.coversOrInside("/a/b/c/d/e"))
        XCTAssertFalse(c.coversOrInside("/a/b"))
        XCTAssertFalse(c.coversOrInside("/a/b/cc"))
        XCTAssertTrue(c.containsClaimed(inside: "/a/b"))
        XCTAssertTrue(c.containsClaimed(inside: "/a"))
        XCTAssertFalse(c.containsClaimed(inside: "/a/b/c"), "strictly below only")
        XCTAssertFalse(c.containsClaimed(inside: "/a/bb"))
        c.claim("/a/x")
        XCTAssertTrue(c.containsClaimed(inside: "/a"))
        XCTAssertFalse(c.coversOrInside("/a"))
        XCTAssertEqual(c.count, 2)
    }

    func testPlannerSplitsFolderAroundHigherPriorityPath() throws {
        try file("Library/Caches/Tool/keep.bin")
        try file("Library/Caches/Tool/mine/inner.bin")
        try file("Library/Caches/Tool/other.bin")
        var high = JunkCatalog.derivedData; high.priority = 2
        var low = JunkCatalog.userCaches; low.priority = 0
        let env = JunkEnvironment.sandboxed(in: root)
        let tool = home.appendingPathComponent("Library/Caches/Tool")
        let out = JunkPlanner.assign([high, low],
                                     [[JunkCandidate(tool.appendingPathComponent("mine"))], [JunkCandidate(tool)]], env: env)
        XCTAssertEqual(out[0].map { $0.url.lastPathComponent }, ["mine"])
        XCTAssertEqual(out[1].map { $0.url.lastPathComponent }, ["keep.bin", "other.bin"])
    }

    func testPlannerIsNotQuadratic() {
        // 20 000 synthetic paths (nothing on disk): 10 000 claimed by a high-priority rule, and the same
        // number again as lower-priority duplicates/children that must be dropped.
        let base = root.appendingPathComponent("home/Library/Caches/Synthetic")
        let high = (0..<10_000).map { JunkCandidate(base.appendingPathComponent("pkg\($0)/data")) }
        let low = (0..<10_000).map { i in
            JunkCandidate(base.appendingPathComponent(i.isMultiple(of: 2) ? "pkg\(i)/data/inner" : "other\(i)"))
        }
        var r1 = JunkCatalog.derivedData; r1.priority = 2
        var r2 = JunkCatalog.userCaches; r2.priority = 0
        let env = JunkEnvironment.sandboxed(in: root)
        // The planner's own work (guard stubbed out): was ~7 s for 8k items when quadratic.
        let t0 = Date()
        let out = JunkPlanner.assign([r1, r2], [high, low], env: env, isProtected: { _ in false })
        let dt = Date().timeIntervalSince(t0)
        XCTAssertEqual(out[0].count, 10_000)
        XCTAssertEqual(out[1].count, 5_000, "children of claimed paths are dropped, the rest kept")
        XCTAssertLessThan(dt, 1.0, "planner took \(dt)s for 20k paths")

        // Same input through the real SafetyGuard (a few syscalls per path in a debug build): generous bound,
        // still orders of magnitude below the old quadratic behaviour.
        let t1 = Date()
        let real = JunkPlanner.assign([r1, r2], [high, low], env: env)
        let dt1 = Date().timeIntervalSince(t1)
        XCTAssertEqual(real[0].count, 10_000)
        XCTAssertEqual(real[1].count, 5_000)
        XCTAssertLessThan(dt1, 8.0, "planner with real guard took \(dt1)s for 20k paths")
    }

    func testTrashCategoryIsFoundButPermanentDeletionIsRefusedOutsideRealTrash() async throws {
        let trashed = try file(".Trash/old file.txt", bytes: 2048)
        try file(".Trash/.hidden-folder/x", bytes: 2048)

        let (_, result) = await scan()
        let trash = try XCTUnwrap(category(JunkCategoryID.trash, in: result))
        XCTAssertEqual(Set(trash.items.map(\.name)), ["old file.txt", ".hidden-folder"])
        XCTAssertEqual(trash.risk, .review)
        XCTAssertFalse(trash.isSelectedByDefault, "emptying the Trash is permanent, so it must not be pre-selected")
        XCTAssertTrue(trash.detail.contains("безвозвратно"))

        // The fake ~/.Trash is not the real Trash, so FileRemover must refuse permanent deletion.
        let removal = await JunkCleaner.clean(trash.items, in: trash)
        XCTAssertTrue(removal.removed.isEmpty)
        XCTAssertEqual(removal.failed.count, 2)
        XCTAssertTrue(fm.fileExists(atPath: trashed.path))
    }

    // MARK: Real disk (read-only, opt-in)

    /// `JUNK_REAL_SCAN=1 swift test --filter JunkEngineTests.testRealDiskScanReadOnly`
    /// Scans the real home folder and prints what it found. Never cleans anything.
    func testRealDiskScanReadOnly() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JUNK_REAL_SCAN"] == "1", "Set JUNK_REAL_SCAN=1 to run")
        let start = Date()
        let result = await JunkScanner().scan()
        let elapsed = Date().timeIntervalSince(start)
        var lines = ["REAL SCAN: \(result.count) categories, \(ByteFormat.string(result.reduce(0) { $0 + $1.totalSize })) total, \(String(format: "%.2f", elapsed)) s"]
        for c in result {
            lines.append("  [\(c.risk)] \(c.title) (\(c.id)): \(ByteFormat.string(c.totalSize)), \(c.items.count) items")
            for item in c.items.prefix(3) { lines.append("      \(ByteFormat.string(item.size))  \(item.url.path)") }
        }
        print(lines.joined(separator: "\n"))
        assertNoOverlap(result)
    }
}
