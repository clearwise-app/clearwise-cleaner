import Foundation

/// Login items and background items as Background Task Management reports them (System Settings →
/// Login Items). `sfltool dumpbtm` asks for the administrator password (it reads the database with
/// `system.privilege.admin`) and takes seconds, so it only runs when the user asks for it.
public struct BackgroundTaskSnapshot: Sendable, Equatable {
    let records: [BTMRecord]
    /// False when the dump was cancelled, failed or was not understood: login items are then unknown (not «none»).
    public let isReadable: Bool

    public static let unavailable = BackgroundTaskSnapshot(records: [], isReadable: false)
}

/// Lists what starts automatically, without any password: launchd plists in the three
/// LaunchAgents/LaunchDaemons folders (with their launchd state, owner app and signer), plus the
/// SMAppService agents, daemons and login items inside apps whose job launchd has loaded.
/// `backgroundTasks()` adds what only Background Task Management knows. Reads only; never changes anything.
public struct StartupScanner: Sendable {
    let env: StartupEnvironment
    static let launchctl = "/bin/launchctl"
    static let sfltool = "/usr/bin/sfltool"

    public init(environment: StartupEnvironment = .live) {
        env = environment
    }

    /// Plist jobs from `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`, and the
    /// loaded jobs apps registered from their own bundles. Fast (< 1 s), no prompts.
    public func launchdItems() -> [StartupItem] {
        let state = LaunchdState.read(env)
        var items: [StartupItem] = []
        for source in [StartupItem.Source.userAgent, .globalAgent, .daemon] {
            guard let folder = env.folder(for: source) else { continue }
            for url in plists(in: folder) {
                items.append(item(at: url, source: source, state: state))
            }
        }
        items += embeddedItems(state: state)
        return Self.sorted(items)
    }

    /// Runs `sfltool dumpbtm`: macOS shows its administrator password prompt. Call off the main thread,
    /// only after the user asked; the timeout leaves time to type the password.
    public func backgroundTasks(timeout: TimeInterval = 120) -> BackgroundTaskSnapshot {
        guard let out = env.run(Self.sfltool, ["dumpbtm"], timeout), out.status == 0,
              case .records(let records) = BTMDump.parse(out.text) else { return .unavailable }
        return BackgroundTaskSnapshot(records: records, isReadable: true)
    }

    /// Adds what BTM knows to the plist items (developer, «off in System Settings», owner) and appends
    /// the items only BTM has (SMAppService login items, agents and daemons of apps).
    public func merging(_ items: [StartupItem], with snapshot: BackgroundTaskSnapshot) -> [StartupItem] {
        guard snapshot.isReadable else { return items }
        let records = snapshot.records.filter { $0.uid == Int(env.uid) || $0.uid <= 0 }
        var byIdentifier: [String: BTMRecord] = [:]
        for r in records where byIdentifier[r.identifier] == nil { byIdentifier[r.identifier] = r }
        var legacyByPath: [String: BTMRecord] = [:]
        for r in records where r.kind.contains(.legacy) {
            if let path = r.url.flatMap(Self.filePath) { legacyByPath[path] = r }
        }

        var result = items.map { item -> StartupItem in
            guard let plist = item.plist, let r = legacyByPath[plist.standardizedFileURL.path] else { return item }
            var item = item
            item.developerName = r.developerName
            item.disabledInSettings = !r.enabled
            if item.ownerAppURL == nil, let parent = r.parentIdentifier.flatMap({ byIdentifier[$0] }),
               let app = parent.url.flatMap(Self.filePath), app.hasSuffix(".app") {
                item.ownerAppURL = URL(fileURLWithPath: app)
                item.ownerName = Self.appName(URL(fileURLWithPath: app))
                item.ownerBundleID = parent.bundleID
            }
            return item
        }

        let services = LaunchdState.read(env)
        var seen = Set<String>()
        // Embedded jobs found without BTM are the same items: keep one (BTM's, it knows more).
        for r in records where r.isStandaloneStartupItem && seen.insert(r.identifier).inserted {
            let added = backgroundItem(r, parent: r.parentIdentifier.flatMap { byIdentifier[$0] }, state: services)
            result.removeAll { $0.source == .backgroundTask && $0.group == added.group && $0.label == added.label }
            result.append(added)
        }
        return Self.sorted(result)
    }

    // MARK: - Plist items

    private func plists(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".plist") && !$0.hasPrefix(".") }.sorted()
            .map { folder.appendingPathComponent($0) }
            .filter { url in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
            }
    }

    private func item(at url: URL, source: StartupItem.Source, state: LaunchdState) -> StartupItem {
        let stem = url.deletingPathExtension().lastPathComponent
        let parsed = LaunchdPlist.read(url)
        let label = parsed?.label ?? stem
        let program = parsed?.program
        let group: StartupItem.Group = source == .daemon ? .daemons : .agents
        var item = StartupItem(
            id: url.standardizedFileURL.path, source: source, group: group, label: label, plist: url,
            program: program, arguments: parsed?.arguments ?? [], runAtLoad: parsed?.runAtLoad ?? false,
            keepAlive: parsed?.keepAlive ?? false, interval: parsed?.interval,
            isMalformed: parsed?.label == nil, programMissing: program.map(Self.isMissing) ?? false,
            disabledInPlist: parsed?.disabled ?? false,
            isApple: AppleIDs.isApple(label) || AppleIDs.isApple(stem))
        let domain = source == .daemon ? state.system : state.gui
        if parsed?.label != nil {
            item.state = domain.state(of: label)
            item.disabledByOverride = domain.overrides[label] ?? false
        } else {
            item.state = .notLoaded
        }
        if let owner = owner(associated: parsed?.associatedBundleIDs ?? [], program: program, label: parsed?.label) {
            item.ownerName = owner.name
            item.ownerBundleID = owner.bundleID
            item.ownerAppURL = owner.app
        }
        if let program, program.hasPrefix("/"), !item.programMissing { item.signer = env.signer(program) }
        return item
    }

    private struct Owner {
        var name: String?
        var bundleID: String?
        var app: URL?
    }

    /// AssociatedBundleIdentifiers, then the `.app` the program lives in, then the label read as a bundle ID.
    private func owner(associated: [String], program: String?, label: String?) -> Owner? {
        let ids = associated.filter { !AppleIDs.isApple($0) }
        for id in ids {
            if let app = env.appForBundleID(id) { return Owner(name: Self.appName(app), bundleID: id, app: app) }
        }
        if let program, let app = Self.enclosingApp(program) {
            return Owner(name: Self.appName(app), bundleID: Bundle(url: app)?.bundleIdentifier, app: app)
        }
        if let label, !AppleIDs.isApple(label) {
            var comps = label.split(separator: ".").map(String.init)
            while comps.count >= 3 {
                let id = comps.joined(separator: ".")
                if let app = env.appForBundleID(id) { return Owner(name: Self.appName(app), bundleID: id, app: app) }
                comps.removeLast()
            }
        }
        return ids.first.map { Owner(name: nil, bundleID: $0, app: nil) }
    }

    // MARK: - Jobs inside app bundles (SMAppService)

    /// `Foo.app/Contents/Library/LaunchAgents|LaunchDaemons/*.plist` and `…/LoginItems/*.app` whose job
    /// launchd has loaded: the app registered them (SMAppService or SMLoginItemSetEnabled, whose job label
    /// is the helper's bundle ID). Registered but not loaded ones are only visible through BTM.
    private func embeddedItems(state: LaunchdState) -> [StartupItem] {
        guard state.gui.services != nil || state.system.services != nil else { return [] }
        var items: [StartupItem] = []
        var seen = Set<String>()
        for folder in env.appFolders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".app") {
                let app = folder.appendingPathComponent(name)
                guard seen.insert(app.standardizedFileURL.path).inserted else { continue }
                items += embeddedItems(in: app, state: state)
            }
        }
        return items
    }

    private func embeddedItems(in app: URL, state: LaunchdState) -> [StartupItem] {
        let library = app.appendingPathComponent("Contents/Library")
        var items: [StartupItem] = []
        let appID = Bundle(url: app)?.bundleIdentifier
        func add(_ group: StartupItem.Group, label: String, plist: URL?, location: URL, parsed: LaunchdPlist?,
                 domain: LaunchdState.Domain) {
            guard domain.services?[label] != nil else { return }
            let program = parsed.flatMap { Self.program(of: $0, app: app) }
                ?? (plist == nil ? Bundle(url: location)?.executableURL?.path : nil)
            var item = StartupItem(
                id: "app:" + location.standardizedFileURL.path, source: .backgroundTask, group: group, label: label,
                plist: plist, program: program, arguments: parsed?.arguments ?? [],
                runAtLoad: parsed?.runAtLoad ?? false, keepAlive: parsed?.keepAlive ?? false, interval: parsed?.interval,
                ownerName: Self.appName(app), ownerBundleID: appID, ownerAppURL: app,
                state: domain.state(of: label), disabledByOverride: domain.overrides[label] ?? false,
                isApple: [label, appID].compactMap { $0 }.contains(where: AppleIDs.isApple))
            item.signer = env.signer(program ?? app.path)
            items.append(item)
        }
        for (sub, group, domain) in [("LaunchAgents", StartupItem.Group.agents, state.gui),
                                     ("LaunchDaemons", .daemons, state.system)] {
            for plist in plists(in: library.appendingPathComponent(sub)) {
                guard let parsed = LaunchdPlist.read(plist), let label = parsed.label else { continue }
                add(group, label: label, plist: plist, location: plist, parsed: parsed, domain: domain)
            }
        }
        let loginItems = library.appendingPathComponent("LoginItems")
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: loginItems.path)) ?? []).sorted()
        where name.hasSuffix(".app") {
            let helper = loginItems.appendingPathComponent(name)
            guard let id = Bundle(url: helper)?.bundleIdentifier else { continue }
            add(.loginItems, label: id, plist: nil, location: helper, parsed: nil, domain: state.gui)
        }
        return items
    }

    // MARK: - Background (BTM-only) items

    private func backgroundItem(_ r: BTMRecord, parent: BTMRecord?, state: LaunchdState) -> StartupItem {
        let id = Self.strippedIdentifier(r.identifier)
        let group: StartupItem.Group = r.kind.contains(.daemon) ? .daemons
            : r.kind.contains(.agent) ? .agents : .loginItems
        let parentApp = parent?.url.flatMap(Self.filePath).map { URL(fileURLWithPath: $0) }
        // SMAppService plists live inside the app: «Contents/Library/LaunchAgents/x.plist» relative to it.
        var location: URL?
        if let url = r.url {
            if let path = Self.filePath(url) { location = URL(fileURLWithPath: path) }
            else if let parentApp, let rel = url.removingPercentEncoding { location = parentApp.appendingPathComponent(rel) }
        }
        let plist = location.flatMap { $0.pathExtension == "plist" ? $0 : nil }
        let parsed = plist.flatMap(LaunchdPlist.read)
        let program = r.executablePath ?? parsed.flatMap { p in ownerAppOf(location, parentApp).flatMap { Self.program(of: p, app: $0) } ?? p.program }
        let ownerApp = parentApp ?? location.flatMap { Self.enclosingApp($0.path) } ?? location.flatMap { $0.pathExtension == "app" ? $0 : nil }
        let label = parsed?.label ?? r.bundleID ?? id

        var item = StartupItem(
            id: "btm:" + r.identifier, source: .backgroundTask, group: group, label: label, plist: plist,
            program: program, arguments: parsed?.arguments ?? [], runAtLoad: parsed?.runAtLoad ?? false,
            keepAlive: parsed?.keepAlive ?? false, interval: parsed?.interval,
            programMissing: program.map(Self.isMissing) ?? false,
            ownerName: ownerApp.map(Self.appName) ?? r.name, ownerBundleID: parent?.bundleID ?? r.bundleID,
            ownerAppURL: ownerApp, developerName: r.developerName, disabledInSettings: !r.enabled,
            isApple: [r.bundleID, parent?.bundleID, id].compactMap { $0 }.contains(where: AppleIDs.isApple))
        if let parsedLabel = parsed?.label {
            item.state = (group == .daemons ? state.system : state.gui).state(of: parsedLabel)
        }
        if let target = program ?? ownerApp?.path, target.hasPrefix("/"), !item.programMissing {
            item.signer = env.signer(target)
        }
        return item
    }

    private func ownerAppOf(_ location: URL?, _ parentApp: URL?) -> URL? {
        parentApp ?? location.flatMap { Self.enclosingApp($0.path) }
    }

    // MARK: - Helpers

    /// Absolute `Program`/`ProgramArguments[0]`, else `BundleProgram` inside `app`.
    static func program(of plist: LaunchdPlist, app: URL) -> String? {
        if let p = plist.program, p.hasPrefix("/") { return p }
        return plist.bundleProgram.map { app.appendingPathComponent($0).path } ?? plist.program
    }

    static func sorted(_ items: [StartupItem]) -> [StartupItem] {
        items.sorted {
            if $0.group != $1.group { return $0.group < $1.group }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    /// `8.com.google.GoogleUpdater.wake` → `com.google.GoogleUpdater.wake` (BTM prefixes the type number).
    static func strippedIdentifier(_ identifier: String) -> String {
        guard let dot = identifier.firstIndex(of: "."), Int(identifier[..<dot]) != nil else { return identifier }
        return String(identifier[identifier.index(after: dot)...])
    }

    /// `file:///Applications/Foo%20Bar.app/` → `/Applications/Foo Bar.app`; nil for relative or non-file URLs.
    static func filePath(_ url: String) -> String? {
        guard url.hasPrefix("file://"), let u = URL(string: url), u.isFileURL else { return nil }
        return u.standardizedFileURL.path
    }

    /// The outermost `.app` bundle a path is inside (helpers inside an app belong to that app).
    static func enclosingApp(_ path: String) -> URL? {
        let comps = URL(fileURLWithPath: path).pathComponents
        guard let i = comps.firstIndex(where: { $0.hasSuffix(".app") }), i < comps.count - 1 || path.hasSuffix(".app") else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(comps[...i])))
    }

    static func appName(_ app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Absolute program path that is verifiably gone (its volume is mounted).
    static func isMissing(_ program: String) -> Bool {
        guard program.hasPrefix("/") else { return false }
        let comps = URL(fileURLWithPath: program).pathComponents
        if comps.count > 2, comps[1] == "Volumes", !FileManager.default.fileExists(atPath: "/Volumes/" + comps[2]) {
            return false
        }
        return !FileManager.default.fileExists(atPath: program)
    }
}

/// What launchd reports for the user's GUI domain and the system domain.
struct LaunchdState {
    struct Domain {
        /// Nil when `launchctl print` failed: states are then unknown.
        var services: [String: Int?]?
        var overrides: [String: Bool] = [:]

        func state(of label: String) -> StartupItem.State {
            guard let services else { return .unknown }
            guard let entry = services[label] else { return .notLoaded }
            if let pid = entry { return .running(pid: pid) }
            return .loaded
        }
    }

    var gui: Domain
    var system: Domain

    static func read(_ env: StartupEnvironment) -> LaunchdState {
        func domain(_ name: String) -> Domain {
            let printed = env.run(StartupScanner.launchctl, ["print", name], 10)
            let disabled = env.run(StartupScanner.launchctl, ["print-disabled", name], 10)
            return Domain(services: printed.flatMap { $0.status == 0 ? LaunchctlOutput.services($0.text) : nil },
                          overrides: disabled.map { LaunchctlOutput.disabled($0.text) } ?? [:])
        }
        return LaunchdState(gui: domain("gui/\(env.uid)"), system: domain("system"))
    }
}
