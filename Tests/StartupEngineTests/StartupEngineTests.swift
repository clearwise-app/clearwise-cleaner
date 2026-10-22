import XCTest
import CleanerKit
@testable import StartupEngine

/// Everything runs against a fake Mac in a temporary directory and a fake launchd: no real job is
/// loaded, unloaded or moved by these tests.
final class StartupEngineTests: XCTestCase {
    private var root: URL!
    private var system: FakeSystem!
    private let fm = FileManager.default

    private var userAgents: URL { root.appendingPathComponent("home/Library/LaunchAgents") }
    private var globalAgents: URL { root.appendingPathComponent("Library/LaunchAgents") }
    private var daemons: URL { root.appendingPathComponent("Library/LaunchDaemons") }
    private var env: StartupEnvironment { system.environment(root: root) }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("StartupEngineTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        for dir in [userAgents, globalAgents, daemons] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        system = FakeSystem()
    }

    override func tearDownWithError() throws {
        // Only our own fixture directory inside $TMPDIR.
        if let root, root.path.contains("StartupEngineTests-") { try? fm.removeItem(at: root) }
    }

    @discardableResult
    private func plist(_ name: String, in dir: URL, _ dict: [String: Any]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    private func job(_ label: String, program: String = "/bin/sleep", extra: [String: Any] = [:]) -> [String: Any] {
        var d: [String: Any] = ["Label": label, "ProgramArguments": [program, "60"]]
        d.merge(extra) { $1 }
        return d
    }

    // MARK: - Parsers

    func testLaunchctlServicesBlock() {
        let services = LaunchctlOutput.services(Samples.guiPrint)
        XCTAssertEqual(services["com.example.vpn.helper"] ?? nil, 812)
        XCTAssertEqual(services["com.example.sync.agent"], .some(nil), "pid 0 = loaded, not running")
        XCTAssertEqual(services["com.example.broken"], .some(nil))
        XCTAssertNil(services["0x1234"], "lines of other blocks are ignored")
        XCTAssertEqual(services.count, 6)
        XCTAssertTrue(LaunchctlOutput.services("garbage\nno services here").isEmpty)
    }

    func testDisabledOverridesBothFormats() {
        let d = LaunchctlOutput.disabled(Samples.guiDisabled)
        XCTAssertEqual(d["com.example.updater"], true)
        XCTAssertEqual(d["com.example.legacy"], true)
        XCTAssertEqual(d["com.example.legacy2"], false)
        XCTAssertEqual(d["com.apple.Siri.agent"], false)
    }

    func testBTMDumpParsing() throws {
        guard case .records(let records) = BTMDump.parse(Samples.btm(home: "/Users/test")) else {
            return XCTFail("dump not understood")
        }
        let byID = Dictionary(records.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        let legacy = try XCTUnwrap(byID["8.com.example.sync.agent"])
        XCTAssertTrue(legacy.kind.contains(.legacy))
        XCTAssertTrue(legacy.kind.contains(.agent))
        XCTAssertFalse(legacy.enabled)
        XCTAssertEqual(legacy.developerName, "Example Inc.")
        XCTAssertEqual(legacy.associatedBundleIDs, ["com.example.sync"])
        XCTAssertEqual(legacy.parentIdentifier, "2.com.example.sync")
        XCTAssertEqual(legacy.uid, 501)
        XCTAssertFalse(legacy.isStandaloneStartupItem, "plist jobs come from their folders")

        let helper = try XCTUnwrap(byID["8.com.example.sync.helper"])
        XCTAssertTrue(helper.enabled)
        XCTAssertTrue(helper.isStandaloneStartupItem)
        XCTAssertTrue(try XCTUnwrap(byID["4.com.example.notes.launcher"]).isStandaloneStartupItem)
        XCTAssertFalse(try XCTUnwrap(byID["2.com.example.notes"]).isStandaloneStartupItem, "app records are parents only")
        XCTAssertFalse(try XCTUnwrap(byID["2048.com.example.notes.preview"]).isStandaloneStartupItem)
        XCTAssertNil(byID["Unknown Developer"]?.name)
        XCTAssertEqual(byID["4.com.example.other.user"]?.uid, 502)
    }

    func testBTMDumpUnreadableAndWordFallback() {
        XCTAssertEqual(BTMDump.parse(""), .unreadable)
        XCTAssertEqual(BTMDump.parse("Error: operation not permitted"), .unreadable)
        XCTAssertEqual(BTMDump.kindValue("curated legacy daemon (0x90010)"), [.daemon, .legacy, BTMRecord.Kind(rawValue: 0x80000)])
        XCTAssertEqual(BTMDump.kindValue("legacy agent"), [.agent, .legacy])
        XCTAssertTrue(BTMDump.isEnabled("[enabled allowed visible notified] (11)"))
        XCTAssertFalse(BTMDump.isEnabled("[disabled, allowed, notified] (0xa)"))
        XCTAssertTrue(BTMDump.isEnabled("(0xb)"))
    }

    // MARK: - Scanner

    func testLaunchdItemsStateOwnerAndSigner() throws {
        let app = root.appendingPathComponent("Applications/Example Sync.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let exe = app.appendingPathComponent("Contents/MacOS/SyncAgent")
        try Data("#!/bin/sh\n".utf8).write(to: exe)
        system.apps["com.example.sync"] = app
        system.apps["com.example.vpn"] = URL(fileURLWithPath: "/Applications/Example VPN.app")
        system.signers[exe.path] = .developerID(name: "Example Inc.", team: "ABCDE12345")

        try plist("com.example.sync.agent.plist", in: userAgents,
                  job("com.example.sync.agent", program: exe.path, extra: ["AssociatedBundleIdentifiers": "com.example.sync", "RunAtLoad": true]))
        try plist("com.example.updater.plist", in: userAgents, job("com.example.updater", extra: ["StartInterval": 3600]))
        try plist("com.example.vpn.helper.plist", in: globalAgents, job("com.example.vpn.helper", extra: ["KeepAlive": ["SuccessfulExit": false]]))
        try plist("com.example.vpn.daemon.plist", in: daemons, job("com.example.vpn.daemon"))
        try plist("com.example.gone.plist", in: daemons, job("com.example.gone", program: "/nonexistent/folder/tool"))
        try plist("com.apple.something.plist", in: daemons, job("com.apple.something"))
        try plist("com.example.empty.plist", in: userAgents, [:])
        try Data("not a plist".utf8).write(to: userAgents.appendingPathComponent("com.example.garbage.plist"))
        try Data().write(to: userAgents.appendingPathComponent(".hidden.plist"))

        let items = StartupScanner(environment: env).launchdItems()
        let byLabel = Dictionary(items.map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(items.count, 8)

        let sync = try XCTUnwrap(byLabel["com.example.sync.agent"])
        XCTAssertEqual(sync.source, .userAgent)
        XCTAssertEqual(sync.group, .agents)
        XCTAssertEqual(sync.state, .loaded)
        XCTAssertEqual(sync.ownerName, "Example Sync")
        XCTAssertEqual(sync.ownerBundleID, "com.example.sync")
        XCTAssertTrue(sync.runAtLoad)
        XCTAssertEqual(sync.signer, .developerID(name: "Example Inc.", team: "ABCDE12345"))
        XCTAssertTrue(sync.isEnabled)

        let updater = try XCTUnwrap(byLabel["com.example.updater"])
        XCTAssertEqual(updater.state, .notLoaded)
        XCTAssertTrue(updater.disabledByOverride)
        XCTAssertFalse(updater.isEnabled)
        XCTAssertEqual(updater.interval, 3600)

        let vpnHelper = try XCTUnwrap(byLabel["com.example.vpn.helper"])
        XCTAssertEqual(vpnHelper.source, .globalAgent)
        XCTAssertEqual(vpnHelper.state, .running(pid: 812))
        XCTAssertTrue(vpnHelper.keepAlive)
        XCTAssertEqual(vpnHelper.ownerName, "Example VPN", "label read as a bundle ID, minus the last part")

        let daemon = try XCTUnwrap(byLabel["com.example.vpn.daemon"])
        XCTAssertEqual(daemon.group, .daemons)
        XCTAssertEqual(daemon.state, .running(pid: 404))

        XCTAssertTrue(try XCTUnwrap(byLabel["com.example.gone"]).programMissing)
        XCTAssertTrue(try XCTUnwrap(byLabel["com.apple.something"]).isApple)
        let empty = try XCTUnwrap(byLabel["com.example.empty"])
        XCTAssertTrue(empty.isMalformed)
        XCTAssertFalse(empty.isEnabled)
        XCTAssertTrue(try XCTUnwrap(byLabel["com.example.garbage"]).isMalformed)
        XCTAssertEqual(items.map(\.group), items.map(\.group).sorted(), "grouped: agents, then daemons")
    }

    func testUnknownStateWhenLaunchctlFails() throws {
        try plist("com.example.a.plist", in: userAgents, job("com.example.a"))
        var e = env
        e.run = { _, _, _ in nil }
        let item = try XCTUnwrap(StartupScanner(environment: e).launchdItems().first)
        XCTAssertEqual(item.state, .unknown)
        XCTAssertEqual(StartupScanner(environment: e).backgroundTasks(), .unavailable)
    }

    func testMergingBackgroundTasks() throws {
        let home = root.appendingPathComponent("home").path
        system.btm = Samples.btm(home: home)
        try plist("com.example.sync.agent.plist", in: userAgents, job("com.example.sync.agent"))
        let scanner = StartupScanner(environment: system.environment(root: root, uid: 501))
        let snapshot = scanner.backgroundTasks()
        XCTAssertTrue(snapshot.isReadable)
        let items = scanner.merging(scanner.launchdItems(), with: snapshot)
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let legacy = try XCTUnwrap(items.first { $0.label == "com.example.sync.agent" })
        XCTAssertTrue(legacy.disabledInSettings, "switched off in System Settings")
        XCTAssertEqual(legacy.developerName, "Example Inc.")
        XCTAssertEqual(legacy.ownerName, "Example Sync", "owner from the BTM parent record")
        XCTAssertEqual(items.filter { $0.label == "com.example.sync.agent" }.count, 1, "no duplicate for the legacy record")

        let helper = try XCTUnwrap(byID["btm:8.com.example.sync.helper"])
        XCTAssertEqual(helper.source, .backgroundTask)
        XCTAssertEqual(helper.group, .agents)
        XCTAssertEqual(helper.plist?.path, "/Applications/Example Sync.app/Contents/Library/LaunchAgents/com.example.sync.helper.plist")
        XCTAssertEqual(helper.ownerName, "Example Sync")

        let login = try XCTUnwrap(byID["btm:4.com.example.notes.launcher"])
        XCTAssertEqual(login.group, .loginItems)
        XCTAssertNil(login.plist)
        XCTAssertEqual(login.ownerAppURL?.path, "/Applications/Example Notes.app")
        XCTAssertTrue(login.isEnabled)

        XCTAssertTrue(try XCTUnwrap(byID["btm:4.com.apple.mail.helper"]).isApple)
        XCTAssertNil(byID["btm:4.com.example.other.user"], "another user's items are not ours")
        XCTAssertNil(byID["btm:2.com.example.notes"])
        XCTAssertEqual(items.first?.group, .loginItems)
    }

    func testJobsInsideAppsNeedNoPassword() throws {
        let app = root.appendingPathComponent("Applications/Example Notes.app")
        try plist("Info.plist", in: try dir(app.appendingPathComponent("Contents")), ["CFBundleIdentifier": "com.example.notes"])
        let agents = try dir(app.appendingPathComponent("Contents/Library/LaunchAgents"))
        try plist("com.example.sync.helper.plist", in: agents,
                  ["Label": "com.example.sync.helper", "BundleProgram": "Contents/MacOS/Helper"])
        try plist("com.example.idle.plist", in: agents, ["Label": "com.example.idle", "BundleProgram": "Contents/MacOS/Idle"])
        let helper = app.appendingPathComponent("Contents/Library/LoginItems/Notes Launcher.app")
        try plist("Info.plist", in: try dir(helper.appendingPathComponent("Contents")),
                  ["CFBundleIdentifier": "com.example.notes.launcher", "CFBundleExecutable": "Launcher"])

        let items = StartupScanner(environment: env).launchdItems()
        XCTAssertEqual(items.count, 2, "only jobs launchd has loaded; com.example.idle is not")
        let login = try XCTUnwrap(items.first { $0.group == .loginItems })
        XCTAssertEqual(login.label, "com.example.notes.launcher")
        XCTAssertEqual(login.state, .running(pid: 930))
        XCTAssertEqual(login.ownerName, "Example Notes")
        XCTAssertEqual(login.source, .backgroundTask)
        XCTAssertNotNil(StartupActions.refusal(.disable, for: login))
        let agent = try XCTUnwrap(items.first { $0.group == .agents })
        XCTAssertEqual(agent.program, app.appendingPathComponent("Contents/MacOS/Helper").path)
        XCTAssertEqual(agent.state, .loaded)

        // BTM knows the same login item: one row, BTM's.
        system.btm = Samples.btm(home: "/Users/test")
        let scanner = StartupScanner(environment: system.environment(root: root, uid: 501))
        let merged = scanner.merging(scanner.launchdItems(), with: scanner.backgroundTasks())
        XCTAssertEqual(merged.filter { $0.label == "com.example.notes.launcher" }.map(\.id), ["btm:4.com.example.notes.launcher"])
        XCTAssertEqual(merged.filter { $0.label == "com.example.sync.helper" }.count, 1)
    }

    private func dir(_ url: URL) throws -> URL {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testUnreadableSnapshotLeavesItemsAlone() throws {
        try plist("com.example.a.plist", in: userAgents, job("com.example.a"))
        let scanner = StartupScanner(environment: env)
        let items = scanner.launchdItems()
        XCTAssertEqual(scanner.merging(items, with: .unavailable), items)
        system.btm = "sfltool: something new"
        XCTAssertFalse(scanner.backgroundTasks().isReadable)
    }

    func testHelpers() {
        XCTAssertEqual(StartupScanner.strippedIdentifier("8.com.example.a"), "com.example.a")
        XCTAssertEqual(StartupScanner.strippedIdentifier("Unknown Developer"), "Unknown Developer")
        XCTAssertEqual(StartupScanner.filePath("file:///Applications/Foo%20Bar.app/"), "/Applications/Foo Bar.app")
        XCTAssertNil(StartupScanner.filePath("Contents/Library/LaunchAgents/x.plist"))
        XCTAssertEqual(StartupScanner.enclosingApp("/Applications/Chrome.app/Contents/Frameworks/X.framework/Helpers/Up.app/Contents/MacOS/Up")?.path,
                       "/Applications/Chrome.app")
        XCTAssertNil(StartupScanner.enclosingApp("/usr/local/bin/tool"))
        XCTAssertEqual(CodeSignature.developerName(fromCertificate: "Developer ID Application: Google LLC (EQHXZ8M8AV)"), "Google LLC")
    }

    func testCodeSignatureOfRealFiles() throws {
        XCTAssertEqual(CodeSignature.signer(ofPath: "/bin/ls"), .apple)
        XCTAssertEqual(CodeSignature.signer(ofPath: "/nonexistent/tool"), .unknown)
        XCTAssertEqual(CodeSignature.signer(ofPath: "relative/tool"), .unknown)
        let script = root.appendingPathComponent("script.sh")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: script)
        XCTAssertTrue([.unsigned, .unknown].contains(CodeSignature.signer(ofPath: script.path)))
    }

    // MARK: - Policy

    private func item(_ label: String, source: StartupItem.Source, plist: URL? = nil, malformed: Bool = false,
                      overridden: Bool = false, settingsOff: Bool = false, apple: Bool = false) -> StartupItem {
        let folder: URL = switch source {
        case .userAgent: userAgents
        case .globalAgent: globalAgents
        case .daemon, .backgroundTask: daemons
        }
        let url = plist ?? folder.appendingPathComponent(label + ".plist")
        return StartupItem(id: url.path, source: source, group: source == .daemon ? .daemons : .agents, label: label,
                           plist: source == .backgroundTask ? nil : url, program: "/bin/sleep", isMalformed: malformed,
                           disabledByOverride: overridden, disabledInSettings: settingsOff, isApple: apple)
    }

    func testRefusals() {
        XCTAssertNil(StartupActions.refusal(.disable, for: item("com.example.a", source: .userAgent)))
        XCTAssertNotNil(StartupActions.refusal(.disable, for: item("com.apple.a", source: .userAgent, apple: true)))
        XCTAssertNotNil(StartupActions.refusal(.remove, for: item("com.apple.a", source: .daemon, apple: true)))
        XCTAssertNotNil(StartupActions.refusal(.disable, for: item("com.example.b", source: .backgroundTask)))
        XCTAssertNotNil(StartupActions.refusal(.disable, for: item("com.example.a", source: .userAgent, overridden: true)))
        XCTAssertNil(StartupActions.refusal(.enable, for: item("com.example.a", source: .userAgent, overridden: true)))
        XCTAssertEqual(StartupActions.refusal(.enable, for: item("com.example.a", source: .userAgent, settingsOff: true)),
                       "Включается в Системных настройках → Объекты входа")
        XCTAssertNotNil(StartupActions.refusal(.disable, for: item("x; rm -rf ~", source: .userAgent)))
        XCTAssertNotNil(StartupActions.refusal(.disable, for: item("com.example.e", source: .userAgent, malformed: true)))
        XCTAssertNil(StartupActions.refusal(.remove, for: item("com.example.e", source: .userAgent, malformed: true)))
        // SafetyGuard: Apple's own daemons folder entries.
        let appleDaemon = item("com.example.x", source: .daemon, plist: URL(fileURLWithPath: "/Library/LaunchDaemons/com.apple.foo.plist"))
        XCTAssertNotNil(StartupActions.refusal(.remove, for: appleDaemon))
        XCTAssertTrue(StartupActions.isValidLabel("com.google.GoogleUpdater.wake"))
        XCTAssertFalse(StartupActions.isValidLabel("-flag"))
        XCTAssertFalse(StartupActions.isValidLabel("a/b"))
    }

    func testPlanCommands() {
        let uid: uid_t = 501
        let agent = item("com.example.a", source: .userAgent)
        let global = item("com.example.g", source: .globalAgent)
        let daemon = item("com.example.d", source: .daemon, plist: URL(fileURLWithPath: "/Library/LaunchDaemons/it's.plist"))

        let off = StartupPlan(action: .disable, items: [agent, global, daemon], uid: uid)
        XCTAssertEqual(off.userCommands, [["disable", "gui/501/com.example.a"], ["bootout", "gui/501/com.example.a"],
                                          ["disable", "gui/501/com.example.g"], ["bootout", "gui/501/com.example.g"]])
        XCTAssertEqual(off.adminShell, "/bin/launchctl disable 'system/com.example.d' ; /bin/launchctl bootout 'system/com.example.d'")
        XCTAssertTrue(off.userTrash.isEmpty && off.adminTrash.isEmpty)

        let on = StartupPlan(action: .enable, items: [agent, daemon], uid: uid)
        XCTAssertEqual(on.userCommands, [["enable", "gui/501/com.example.a"], ["bootstrap", "gui/501", agent.plist!.path]])
        XCTAssertEqual(on.adminShell, "/bin/launchctl enable 'system/com.example.d' ; /bin/launchctl bootstrap system '/Library/LaunchDaemons/it'\\''s.plist'")

        let rm = StartupPlan(action: .remove, items: [agent, global, daemon, item("com.example.e", source: .userAgent, malformed: true)], uid: uid)
        XCTAssertEqual(rm.userCommands, [["bootout", "gui/501/com.example.a"], ["bootout", "gui/501/com.example.g"]])
        XCTAssertEqual(rm.userTrash.map(\.lastPathComponent), ["com.example.a.plist", "com.example.e.plist"])
        XCTAssertEqual(rm.adminTrash.map(\.lastPathComponent), ["com.example.g.plist", "it's.plist"])
        XCTAssertEqual(rm.adminShell, "/bin/launchctl bootout 'system/com.example.d'")
    }

    func testChangedOnDiskChecks() throws {
        let url = try plist("com.example.a.plist", in: userAgents, job("com.example.a"))
        let a = item("com.example.a", source: .userAgent, plist: url)
        XCTAssertNil(StartupActions.changedOnDisk(a, env))

        try plist("com.example.a.plist", in: userAgents, job("com.example.other"))
        XCTAssertNotNil(StartupActions.changedOnDisk(a, env), "label changed since the scan")

        let target = try plist("real.plist", in: root, job("com.example.l"))
        let link = userAgents.appendingPathComponent("com.example.l.plist")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(StartupActions.changedOnDisk(item("com.example.l", source: .userAgent, plist: link), env), "Это ссылка, а не файл")

        let elsewhere = try plist("com.example.w.plist", in: root, job("com.example.w"))
        XCTAssertNotNil(StartupActions.changedOnDisk(item("com.example.w", source: .userAgent, plist: elsewhere), env))

        // Global agents and daemons must be root's; a fixture file is ours.
        let g = try plist("com.example.g.plist", in: globalAgents, job("com.example.g"))
        XCTAssertEqual(StartupActions.changedOnDisk(item("com.example.g", source: .globalAgent, plist: g), env), "Неожиданный владелец файла")
        XCTAssertEqual(StartupActions.changedOnDisk(item("com.example.gone", source: .userAgent), env), "Файла уже нет")
    }

    func testDisableThenEnableUserAgent() async throws {
        let url = try plist("com.example.a.plist", in: userAgents, job("com.example.a"))
        let scanner = StartupScanner(environment: env)
        var a = try XCTUnwrap(scanner.launchdItems().first { $0.plist == url })

        let off = await StartupActions.perform(.disable, on: [a], environment: env)
        XCTAssertEqual(off.succeeded, [a.id])
        XCTAssertTrue(off.failed.isEmpty)
        XCTAssertTrue(system.calls.contains(["disable", "gui/\(getuid())/com.example.a"]))
        XCTAssertTrue(system.calls.contains(["bootout", "gui/\(getuid())/com.example.a"]))
        XCTAssertTrue(fm.fileExists(atPath: url.path), "disabling never touches the file")

        a = try XCTUnwrap(scanner.launchdItems().first { $0.plist == url })
        XCTAssertTrue(a.disabledByOverride)
        let on = await StartupActions.perform(.enable, on: [a], environment: env)
        XCTAssertEqual(on.succeeded, [a.id])
        XCTAssertTrue(system.calls.contains(["bootstrap", "gui/\(getuid())", url.path]))
        XCTAssertFalse(try XCTUnwrap(scanner.launchdItems().first { $0.plist == url }).disabledByOverride)
    }

    func testPerformRefusesAppleAndStaleItems() async throws {
        let url = try plist("com.example.a.plist", in: userAgents, job("com.example.a"))
        let a = try XCTUnwrap(StartupScanner(environment: env).launchdItems().first)
        try fm.removeItem(at: url)
        let apple = item("com.apple.x", source: .userAgent, apple: true)
        let report = await StartupActions.perform(.disable, on: [a, apple], environment: env)
        XCTAssertTrue(report.succeeded.isEmpty)
        XCTAssertEqual(report.failed.map(\.id), [a.id, apple.id])
        XCTAssertFalse(system.calls.contains { $0.first == "disable" || $0.first == "bootout" }, "nothing reached launchctl")
    }
}
