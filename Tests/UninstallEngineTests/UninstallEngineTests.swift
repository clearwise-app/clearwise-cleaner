import XCTest
import CleanerKit
@testable import UninstallEngine

final class RemnantFinderTests: XCTestCase {

    func testExactBundleIDMatchesAcrossLocations() async throws {
        let fx = try Fixture()
        let app = try fx.makeApp("Foo Writer", id: "com.acme.foowriter")
        let uuid = UUID().uuidString

        let caches = try fx.dir(fx.lib, "Caches/com.acme.foowriter")
        let helperCache = try fx.dir(fx.lib, "Caches/com.acme.foowriter.helper")
        let shipIt = try fx.dir(fx.lib, "Caches/com.acme.foowriter.ShipIt")
        let prefs = try fx.plist(fx.lib, "Preferences/com.acme.foowriter.plist", ["a": 1])
        let byHost = try fx.plist(fx.lib, "Preferences/ByHost/com.acme.foowriter.\(uuid).plist", ["a": 1])
        let saved = try fx.dir(fx.lib, "Saved Application State/com.acme.foowriter.savedState")
        let container = try fx.dir(fx.lib, "Containers/\(UUID().uuidString)")
        try fx.plist(container, ".com.apple.containermanagerd.metadata.plist", ["MCMMetadataIdentifier": "com.acme.foowriter"])
        let http = try fx.dir(fx.lib, "HTTPStorages/com.acme.foowriter")
        let cookies = try fx.file(fx.lib, "Cookies/com.acme.foowriter.binarycookies")
        let support = try fx.dir(fx.lib, "Application Support/Foo Writer")
        let receipt = try fx.plist(fx.roots.receipts, "com.acme.foowriter.pkg.plist", ["PackageIdentifier": "com.acme.foowriter.pkg"])
        let bom = try fx.file(fx.roots.receipts, "com.acme.foowriter.pkg.bom")
        let darwinCache = try fx.dir(fx.roots.userCacheDir!, "com.acme.foowriter")
        let sysSupport = try fx.dir(fx.sysLib, "Application Support/com.acme.foowriter")
        let crash = try fx.file(fx.lib, "Logs/DiagnosticReports/Foo Writer-2026-01-02-101010.ips")
        let dot = try fx.dir(fx.home, ".foowriter")
        // Must not match.
        let unrelated = try fx.dir(fx.lib, "Caches/com.acme.foowriterpro")
        let apple = try fx.plist(fx.lib, "Preferences/com.apple.finder.plist", ["a": 1])
        let unknownUUID = try fx.dir(fx.lib, "Containers/\(UUID().uuidString)")

        let finder = fx.finder(known: [app])
        let found = await finder.remnants(for: app)

        for url in [caches, helperCache, shipIt, prefs, byHost, saved, container, http, cookies, receipt, bom, darwinCache, sysSupport] {
            XCTAssertEqual(found.remnant(url)?.confidence, .high, "expected high: \(url.path)")
        }
        XCTAssertEqual(found.remnant(support)?.confidence, .medium)
        XCTAssertEqual(found.remnant(crash)?.confidence, .medium)
        XCTAssertEqual(found.remnant(crash)?.kind, .crashReports)
        XCTAssertEqual(found.remnant(dot)?.confidence, .low)
        XCTAssertEqual(found.remnant(container)?.kind, .containers)
        XCTAssertEqual(found.remnant(prefs)?.kind, .preferences)
        XCTAssertEqual(found.remnant(receipt)?.kind, .receipts)
        XCTAssertNil(found.remnant(unrelated))
        XCTAssertNil(found.remnant(apple))
        XCTAssertNil(found.remnant(unknownUUID))

        XCTAssertEqual(found.remnant(receipt)?.requiresAdmin, true)
        XCTAssertEqual(found.remnant(sysSupport)?.requiresAdmin, true)
        XCTAssertEqual(found.remnant(caches)?.requiresAdmin, false)
        XCTAssertEqual(found.remnant(darwinCache)?.requiresAdmin, false)
        XCTAssertGreaterThan(found.remnant(caches)?.item.size ?? 0, 0)

        // Sorted by kind order, then size.
        let order = RemnantKind.allCases
        let kinds = found.map { order.firstIndex(of: $0.kind)! }
        XCTAssertEqual(kinds, kinds.sorted())
    }

    func testGroupContainersByAppGroupAndTeamID() async throws {
        let fx = try Fixture()
        let app = try fx.makeApp("Teleport", id: "com.acme.teleport", teamID: "ABCDE12345")
        let group = try fx.dir(fx.lib, "Group Containers/ABCDE12345.com.acme.sharedstuff")
        let teamOnly = try fx.dir(fx.lib, "Group Containers/ABCDE12345.misc")
        let byBundle = try fx.dir(fx.lib, "Group Containers/ABCDE12345.com.acme.teleport")
        let groupPrefs = try fx.plist(fx.lib, "Preferences/group.com.acme.legacy.plist", ["a": 1])
        let otherTeam = try fx.dir(fx.lib, "Group Containers/ZZZZZ99999.com.other.x")

        let groups = [app.url.standardizedFileURL.path: ["ABCDE12345.com.acme.sharedstuff", "group.com.acme.legacy"]]
        let found = await fx.finder(known: [app], groups: groups).remnants(for: app)
        XCTAssertEqual(found.remnant(group)?.confidence, .high)
        XCTAssertEqual(found.remnant(byBundle)?.confidence, .high)
        XCTAssertEqual(found.remnant(groupPrefs)?.confidence, .high)
        XCTAssertEqual(found.remnant(teamOnly)?.confidence, .medium)
        XCTAssertEqual(found.remnant(teamOnly)?.kind, .groupContainers)
        XCTAssertNil(found.remnant(otherTeam))

        // Another app of the same developer: the team-only match is no longer safe.
        let sibling = try fx.makeApp("Teleport Pro", id: "com.acme.tpro", teamID: "ABCDE12345")
        let found2 = await fx.finder(known: [app, sibling], groups: groups).remnants(for: app)
        XCTAssertNil(found2.remnant(teamOnly))
        XCTAssertEqual(found2.remnant(group)?.confidence, .high)
    }

    func testLaunchItemsMatchedByProgramPathAndHelperTool() async throws {
        let fx = try Fixture()
        let app = try fx.makeApp("Syncer", id: "com.vendorx.syncer")
        let agent = try fx.plist(fx.lib, "LaunchAgents/com.totally.different.plist", [
            "Label": "com.totally.different",
            "ProgramArguments": [app.url.appendingPathComponent("Contents/MacOS/agent").path, "--bg"],
        ])
        let helper = try fx.file(fx.sysLib, "PrivilegedHelperTools/net.vx.privhelper")
        let daemon = try fx.plist(fx.sysLib, "LaunchDaemons/net.vx.privhelper.plist", [
            "Label": "net.vx.privhelper",
            "Program": helper.path,
            "AssociatedBundleIdentifiers": ["com.vendorx.syncer"],
        ])
        let foreign = try fx.plist(fx.lib, "LaunchAgents/com.someone.else.plist", [
            "Label": "com.someone.else", "Program": "/usr/local/bin/else",
        ])

        let found = await fx.finder(known: [app]).remnants(for: app)
        XCTAssertEqual(found.remnant(agent)?.confidence, .high)
        XCTAssertEqual(found.remnant(agent)?.kind, .launchAgents)
        XCTAssertEqual(found.remnant(daemon)?.confidence, .high)
        XCTAssertEqual(found.remnant(daemon)?.kind, .launchDaemons)
        XCTAssertEqual(found.remnant(daemon)?.requiresAdmin, true)
        XCTAssertEqual(found.remnant(helper)?.confidence, .high)
        XCTAssertEqual(found.remnant(helper)?.kind, .privilegedHelpers)
        XCTAssertNil(found.remnant(foreign))
    }

    func testNotionVersusNotionCalendar() async throws {
        let fx = try Fixture()
        let notion = try fx.makeApp("Notion", id: "notion.id")
        let calendar = try fx.makeApp("Notion Calendar", id: "com.cron.electron")
        let nSupport = try fx.dir(fx.lib, "Application Support/Notion")
        let nCache = try fx.dir(fx.lib, "Caches/notion.id")
        let nLogs = try fx.dir(fx.lib, "Logs/Notion")
        let cSupport = try fx.dir(fx.lib, "Application Support/Notion Calendar")
        let cCache = try fx.dir(fx.lib, "Caches/com.cron.electron")
        let cLogs = try fx.dir(fx.lib, "Logs/Notion Calendar")

        let finder = fx.finder(known: [notion, calendar])
        let forNotion = await finder.remnants(for: notion).paths
        let forCalendar = await finder.remnants(for: calendar).paths
        for u in [nSupport, nCache, nLogs] { XCTAssertTrue(forNotion.contains(u.path), u.path) }
        for u in [cSupport, cCache, cLogs] { XCTAssertFalse(forNotion.contains(u.path), u.path) }
        for u in [cSupport, cCache, cLogs] { XCTAssertTrue(forCalendar.contains(u.path), u.path) }
        for u in [nSupport, nCache, nLogs] { XCTAssertFalse(forCalendar.contains(u.path), u.path) }
    }

    func testChromeVersusChromeRemoteDesktop() async throws {
        let fx = try Fixture()
        let chrome = try fx.makeApp("Google Chrome", id: "com.google.Chrome")
        let crd = try fx.makeApp("Chrome Remote Desktop", id: "com.google.chromeremotedesktop")
        let chromeData = try fx.dir(fx.lib, "Application Support/Google/Chrome")
        let chromeCache = try fx.dir(fx.lib, "Caches/com.google.Chrome")
        let chromeHelper = try fx.dir(fx.lib, "Caches/com.google.Chrome.helper")
        let chromePrefs = try fx.plist(fx.lib, "Preferences/com.google.Chrome.plist", ["a": 1])
        let chromeVendorCache = try fx.dir(fx.lib, "Caches/Google/Chrome")
        let updater = try fx.dir(fx.lib, "Application Support/Google/GoogleUpdater")
        let crdData = try fx.dir(fx.lib, "Application Support/Google/Chrome Remote Desktop")
        let crdCache = try fx.dir(fx.lib, "Caches/com.google.chromeremotedesktop")
        let googleFolder = fx.lib.appendingPathComponent("Application Support/Google")

        let finder = fx.finder(known: [chrome, crd])
        let forCRD = await finder.remnants(for: crd).paths
        let forChrome = await finder.remnants(for: chrome)

        for u in [chromeData, chromeCache, chromeHelper, chromePrefs, chromeVendorCache, updater, googleFolder] {
            XCTAssertFalse(forCRD.contains(u.path), "CRD must not take \(u.path)")
        }
        XCTAssertTrue(forCRD.contains(crdData.path))
        XCTAssertTrue(forCRD.contains(crdCache.path))

        XCTAssertEqual(forChrome.remnant(chromeCache)?.confidence, .high)
        XCTAssertEqual(forChrome.remnant(chromeHelper)?.confidence, .high)
        XCTAssertEqual(forChrome.remnant(chromeData)?.confidence, .medium)
        XCTAssertEqual(forChrome.remnant(chromeVendorCache)?.confidence, .medium)
        XCTAssertNil(forChrome.remnant(crdData))
        XCTAssertNil(forChrome.remnant(crdCache))
        XCTAssertNil(forChrome.remnant(updater))
        XCTAssertNil(forChrome.remnant(googleFolder), "vendor folder itself is shared, never offered")
    }

    func testVendorUpdaterOfferedOnlyForLastAppOfVendor() async throws {
        let fx = try Fixture()
        let chrome = try fx.makeApp("Google Chrome", id: "com.google.Chrome")
        let updaterSupport = try fx.dir(fx.lib, "Application Support/Google/GoogleUpdater")
        let keystoneAgent = try fx.plist(fx.lib, "LaunchAgents/com.google.keystone.agent.plist",
                                         ["Label": "com.google.keystone.agent", "Program": "/nonexistent/ksagent"])
        let updaterCache = try fx.dir(fx.lib, "Caches/com.google.GoogleUpdater")
        let rlz = try fx.dir(fx.lib, "Application Support/Google/RLZ")

        let alone = await fx.finder(known: [chrome]).remnants(for: chrome)
        for u in [updaterSupport, keystoneAgent, updaterCache] {
            XCTAssertEqual(alone.remnant(u)?.confidence, .low, u.path)
        }
        XCTAssertNil(alone.remnant(rlz))

        let drive = try fx.makeApp("Google Drive", id: "com.google.drivefs")
        let shared = await fx.finder(known: [chrome, drive]).remnants(for: chrome)
        for u in [updaterSupport, keystoneAgent, updaterCache] { XCTAssertNil(shared.remnant(u), u.path) }
    }

    func testStoplistAndShortNamesNeverMatchByName() async throws {
        let fx = try Fixture()
        let helperApp = try fx.makeApp("Helper", id: "com.zz.helperapp")
        let boxApp = try fx.makeApp("Box", id: "com.qq.boxer")
        let googleApp = try fx.makeApp("Google", id: "com.yy.gapp")
        let generic = try ["Helper", "Update", "Box", "Google", "Updater"].map { try fx.dir(fx.lib, "Application Support/\($0)") }
        let finder = fx.finder(known: [helperApp, boxApp, googleApp])
        for app in [helperApp, boxApp, googleApp] {
            let paths = await finder.remnants(for: app).paths
            for g in generic { XCTAssertFalse(paths.contains(g.path), "\(app.name) took \(g.lastPathComponent)") }
        }
        // ...but ID matches still work for such apps.
        let idCache = try fx.dir(fx.lib, "Caches/com.zz.helperapp")
        await finder.invalidate()
        let found = await finder.remnants(for: helperApp)
        XCTAssertEqual(found.remnant(idCache)?.confidence, .high)
    }

    func testClaudeCLIDataIsNotTheDesktopApp() async throws {
        let fx = try Fixture()
        let claude = try fx.makeApp("Claude", id: "com.anthropic.claudefordesktop")
        let support = try fx.dir(fx.lib, "Application Support/Claude")
        let cli = try fx.dir(fx.lib, "Caches/claude-cli-nodejs")
        let dot = try fx.dir(fx.home, ".claude")
        let shipIt = try fx.dir(fx.lib, "Caches/com.anthropic.claudefordesktop.ShipIt")
        let found = await fx.finder(known: [claude]).remnants(for: claude)
        XCTAssertEqual(found.remnant(support)?.confidence, .medium)
        XCTAssertEqual(found.remnant(shipIt)?.confidence, .high)
        XCTAssertNil(found.remnant(cli))
        XCTAssertNil(found.remnant(dot))
    }

    func testNameSuffixAndVersionVariants() async throws {
        let fx = try Fixture()
        let app = try fx.makeApp("Bartender 6", id: "com.surteesstudios.Bartender")
        let plain = try fx.dir(fx.lib, "Application Support/Bartender")
        let helper = try fx.dir(fx.lib, "Caches/BartenderHelper")
        let found = await fx.finder(known: [app]).remnants(for: app)
        XCTAssertEqual(found.remnant(plain)?.confidence, .medium)
        XCTAssertEqual(found.remnant(helper)?.confidence, .low)
    }

    func testSystemAppsGetNothing() async throws {
        let fx = try Fixture()
        let app = try fx.makeApp("Safari", id: "com.apple.Safari", system: true)
        try fx.dir(fx.lib, "Caches/com.apple.Safari")
        let found = await fx.finder(known: [app]).remnants(for: app)
        XCTAssertTrue(found.isEmpty)
        let result = await AppUninstaller.uninstall(app, remnants: [], removeBundle: true)
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertTrue(result.removed.isEmpty)
    }

    func testNestedDedupe() throws {
        let fx = try Fixture()
        let loc = Location(fx.lib.appendingPathComponent("Application Support"), .applicationSupport)
        func entry(_ rel: String) -> IndexEntry {
            let url = fx.lib.appendingPathComponent("Application Support/\(rel)")
            return IndexEntry(url: url, location: loc, name: url.lastPathComponent, stem: url.lastPathComponent,
                              ids: [], programPath: nil, isDirectory: true, modified: nil, insideVendorFolder: false)
        }
        let m = { (c: MatchConfidence) in MatchResult(confidence: c, specificity: 5, teamOnly: false) }
        let a = RemnantFinder.dedupeNested([(entry("Foo"), m(.high)), (entry("Foo/Bar"), m(.high)), (entry("Foo/Baz"), m(.low))])
        XCTAssertEqual(a.map { $0.0.name }, ["Foo"])
        let b = RemnantFinder.dedupeNested([(entry("Vendor"), m(.low)), (entry("Vendor/App"), m(.high))])
        XCTAssertEqual(b.map { $0.0.name }, ["App"])
        let c = RemnantFinder.dedupeNested([(entry("Foo"), m(.medium)), (entry("Foobar"), m(.medium))])
        XCTAssertEqual(Set(c.map { $0.0.name }), ["Foo", "Foobar"])
    }
}

final class OrphanFinderTests: XCTestCase {

    func testOrphansExcludeInstalledAppleAndRecent() async throws {
        let fx = try Fixture()
        let app = try fx.makeApp("Foo Writer", id: "com.acme.foowriter")

        // Leftovers of a deleted app.
        let ghostCache = try fx.dir(fx.lib, "Caches/com.ghostsoft.spectre")
        let ghostPrefs = try fx.plist(fx.lib, "Preferences/com.ghostsoft.spectre.plist", ["a": 1])
        let ghostSupport = try fx.dir(fx.lib, "Application Support/Spectre")
        let ghostAgent = try fx.plist(fx.lib, "LaunchAgents/com.ghostsoft.spectre.agent.plist",
                                      ["Label": "com.ghostsoft.spectre.agent", "Program": "/nonexistent/spectre-agent"])
        let ghostDaemon = try fx.plist(fx.sysLib, "LaunchDaemons/com.ghostsoft.spectre.daemon.plist",
                                       ["Label": "com.ghostsoft.spectre.daemon", "Program": "/nonexistent/d"])
        let spotify = try fx.dir(fx.lib, "Caches/com.spotify.client")

        // Must not be orphans.
        let owned = try fx.dir(fx.lib, "Caches/com.acme.foowriter")
        let ownedHelper = try fx.dir(fx.lib, "Caches/com.acme.foowriter.helper")
        let vendorGroup = try fx.dir(fx.lib, "Group Containers/group.com.acme.shared")
        let apple = try fx.dir(fx.lib, "Caches/com.apple.Something")
        let appleGroup = try fx.dir(fx.lib, "Group Containers/group.com.apple.notes")
        let shortcutsGroup = try fx.dir(fx.lib, "Group Containers/group.is.workflow.shortcuts")
        let appleTeamGroup = try fx.dir(fx.lib, "Group Containers/243LU875E5.groups.com.apple.podcasts")
        let recent = try fx.dir(fx.lib, "Caches/com.fresh.thingapp", ageDays: nil)
        let short = try fx.dir(fx.lib, "Caches/io.x.y")
        let uuid = try fx.dir(fx.lib, "Caches/\(UUID().uuidString)")
        let liveTool = try fx.file(fx.home, "bin/runner")
        let toolAgent = try fx.plist(fx.lib, "LaunchAgents/com.tool.runner.plist", ["Label": "com.tool.runner", "Program": liveTool.path])
        let swiftpm = try fx.dir(fx.lib, "Caches/org.swift.swiftpm")
        let appleFolder = try fx.dir(fx.lib, "Application Support/CallHistoryDB")
        let daemonish = try fx.dir(fx.lib, "Caches/familycircled")
        let elsewhere = try fx.dir(fx.lib, "Caches/com.elsewhere.installedapp")

        let finder = fx.finder(known: [app], locator: { id in
            id == "com.elsewhere.installedapp" ? URL(fileURLWithPath: "/Applications") : nil
        })
        let groups = await finder.orphans(installed: [app], progress: nil)
        let all = groups.flatMap { $0.remnants }.paths

        let spectre = try XCTUnwrap(groups.first { $0.id == "com.ghostsoft.spectre" })
        XCTAssertEqual(spectre.displayName, "Spectre")
        XCTAssertEqual(spectre.remnants.paths,
                       Set([ghostCache, ghostPrefs, ghostSupport, ghostAgent, ghostDaemon].map(\.path)))
        XCTAssertEqual(spectre.remnants.remnant(ghostCache)?.confidence, .high)
        XCTAssertEqual(spectre.remnants.remnant(ghostSupport)?.confidence, .low)
        XCTAssertEqual(spectre.remnants.remnant(ghostDaemon)?.requiresAdmin, true)
        XCTAssertGreaterThan(spectre.totalSize, 0)

        let sp = try XCTUnwrap(groups.first { $0.id == "com.spotify.client" })
        XCTAssertEqual(sp.displayName, "Spotify")
        XCTAssertTrue(sp.remnants.paths.contains(spotify.path))

        for u in [owned, ownedHelper, vendorGroup, apple, appleGroup, shortcutsGroup, appleTeamGroup, recent, short, uuid, toolAgent, swiftpm, appleFolder, daemonish, elsewhere] {
            XCTAssertFalse(all.contains(u.path), "not an orphan: \(u.path)")
        }
        // Sorted by size, descending.
        XCTAssertEqual(groups.map(\.totalSize), groups.map(\.totalSize).sorted(by: >))
    }

    func testDisplayNames() {
        XCTAssertEqual(OrphanRules.displayName(forID: "com.spotify.client"), "Spotify")
        XCTAssertEqual(OrphanRules.displayName(forID: "com.tinyspeck.slackmacgap"), "Slack")
        XCTAssertEqual(OrphanRules.displayName(forID: "ru.keepcoder.Telegram"), "Telegram")
        XCTAssertEqual(OrphanRules.displayName(forID: "com.microsoft.VSCode"), "VSCode")
    }
}

final class InventoryAndPlanTests: XCTestCase {

    func testInventoryScansOneLevelAndSkipsNestedApps() async throws {
        let fx = try Fixture()
        let zeta = try fx.makeApp("Zeta", id: "com.z.zeta")
        try fx.makeApp("Nested", id: "com.z.zeta.nested", in: zeta.url.appendingPathComponent("Contents/Library/LoginItems"))
        try fx.makeApp("Alpha", id: "com.a.alpha", in: fx.apps.appendingPathComponent("Utilities"),
                       extra: ["CFBundleDisplayName": "Alpha Display"])
        let store = try fx.makeApp("Beta", id: "com.b.beta", in: fx.roots.applicationDirs[1])
        try fx.file(store.url, "Contents/_MASReceipt/receipt")
        try fx.makeApp("Safari", id: "com.apple.Safari")
        try fx.dir(fx.apps, "Deep/Deeper/Hidden.app")

        let apps = await AppInventory(roots: fx.roots).installedApps()
        XCTAssertEqual(apps.map(\.name), ["Alpha Display", "Beta", "Safari", "Zeta"])
        XCTAssertEqual(apps.first { $0.name == "Beta" }?.isAppStore, true)
        XCTAssertEqual(apps.first { $0.name == "Safari" }?.isSystemApp, true)
        XCTAssertEqual(apps.first { $0.name == "Zeta" }?.isSystemApp, false)
        XCTAssertEqual(apps.first { $0.name == "Zeta" }?.version, "1.0")
    }

    func testRemovalPlanOrderAndSplit() throws {
        let fx = try Fixture()
        let app = try fx.makeApp("Syncer", id: "com.vendorx.syncer")
        func r(_ path: String, _ kind: RemnantKind, admin: Bool) -> AppRemnant {
            AppRemnant(item: FileItem(url: URL(fileURLWithPath: path), size: 10, isDirectory: false),
                       kind: kind, confidence: .high, requiresAdmin: admin)
        }
        let remnants = [
            r("/tmp/x/Caches/com.vendorx.syncer", .caches, admin: false),
            r("/tmp/x/LaunchAgents/com.vendorx.syncer.plist", .launchAgents, admin: false),
            r("/tmp/x/LaunchDaemons/com.vendorx.d.plist", .launchDaemons, admin: true),
            r(app.url.appendingPathComponent("Contents/Info.plist").path, .other, admin: false),
        ]
        let plan = RemovalPlan(app: app, remnants: remnants, removeBundle: true, bundleNeedsAdmin: false)
        XCTAssertEqual(plan.launchAgentsToUnload.map(\.lastPathComponent), ["com.vendorx.syncer.plist"])
        XCTAssertEqual(plan.userItems.count, 2)
        XCTAssertEqual(plan.adminItems.map(\.lastPathComponent), ["com.vendorx.d.plist"])
        XCTAssertEqual(plan.userBundle, app.url)
        XCTAssertFalse((plan.userItems + plan.adminItems).contains { $0.path.hasPrefix(app.url.path) },
                       "items inside the bundle are never listed separately")

        let adminPlan = RemovalPlan(app: app, remnants: remnants, removeBundle: true, bundleNeedsAdmin: true)
        XCTAssertNil(adminPlan.userBundle)
        XCTAssertEqual(adminPlan.adminItems.last, app.url, "bundle goes last in the single admin batch")

        let keep = RemovalPlan(app: app, remnants: remnants, removeBundle: false, bundleNeedsAdmin: false)
        XCTAssertNil(keep.userBundle)
        XCTAssertFalse(keep.adminItems.contains(app.url))
    }

    func testFakeAppIsNotRunning() throws {
        let fx = try Fixture()
        let app = try fx.makeApp("Nobody", id: "com.nobody.\(UUID().uuidString.prefix(8))")
        XCTAssertFalse(AppUninstaller.isRunning(app))
    }
}
