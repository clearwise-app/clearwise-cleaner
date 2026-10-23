import Foundation
import CleanerKit
import JunkEngine
import UninstallEngine
import SpaceEngine
import HealthEngine
import StartupEngine

/// What the server remembers between calls: the last junk scan (`clean_junk` works on it), the app list,
/// the leftovers of removed apps, the startup items. A removal drops what it changed; the next call re-reads.
public actor CleanerState {
    public init() {}

    var junk: [JunkCategory] = []
    var junkNotes: [URL: String] = [:]
    var docker: DockerStatus = .absent
    var apps: [InstalledApp] = []
    var orphans: [OrphanGroup] = []
    var startupItems: [StartupItem] = []

    let scanner = JunkScanner()
    let inventory = AppInventory()
    let remnants = RemnantFinder()
    let analyzer = FileAnalyzer()

    /// Tests put a scan here instead of scanning the real home folder.
    public func preload(junk: [JunkCategory], notes: [URL: String] = [:]) {
        self.junk = junk
        self.junkNotes = notes
    }

    func scanJunk() async -> [JunkCategory] {
        junk = await scanner.scan()
        junkNotes = await scanner.notes
        docker = await scanner.docker
        return junk
    }

    func loadApps() async -> [InstalledApp] {
        if apps.isEmpty {
            apps = await inventory.installedApps()
            await remnants.setInstalledApps(apps)
        }
        return apps
    }

    func forgetApps() {
        apps = []
        orphans = []
    }
}

/// The tools an MCP client gets. Every tool that removes something is a dry run until `confirm` is true,
/// and then does exactly what the app does: to the Trash, except the Trash's own content and Docker.
public enum CleanerTools {
    public static let instructions = """
    Clearwise Cleaner for macOS. Read-only tools: scan_junk, list_apps, app_footprint, find_leftovers, \
    old_files, large_files, duplicates, mac_health, startup_items, disk_usage. Tools that remove something \
    (clean_junk, uninstall_app, remove_leftovers, trash_files, set_startup_item, empty_trash) are a DRY RUN \
    unless called with confirm=true: show the user the dry run first, and pass confirm=true only after they \
    agreed to that exact list. Removed files go to the macOS Trash (recoverable) with two exceptions the \
    tools name: emptying the Trash is permanent, and Docker frees its images and cache at once. \
    Sizes are bytes; paths are absolute. Full Disk Access belongs to the host app (Terminal, Claude, \
    Cursor): without it some caches and the Trash are invisible, and scan_junk says so.
    """

    public struct Pick: Equatable {
        public let category: JunkCategory
        public let items: [FileItem]
        public static func == (l: Pick, r: Pick) -> Bool { l.category.id == r.category.id && l.items == r.items }
    }

    public static func all(state: CleanerState = CleanerState()) -> [MCPTool] {
        [scanJunk(state), cleanJunk(state), diskUsage(), listApps(state), appFootprint(state), uninstallApp(state),
         findLeftovers(state), removeLeftovers(state), oldFiles(state), largeFiles(state), duplicates(state),
         trashFiles(), macHealth(), startupItems(state), setStartupItem(state), emptyTrash()]
    }

    // MARK: Junk

    static func scanJunk(_ state: CleanerState) -> MCPTool {
        MCPTool(name: "scan_junk",
                description: """
                Scan for system junk: app and browser caches, logs, developer caches (Xcode, npm, pip, Homebrew…), \
                temporary files, old installers, iPhone backups, the Trash, Docker. Read-only. Returns categories \
                with items, and which items a cleanup mode would tick: gentle (what apps recreate by themselves), \
                enhanced (also what is downloaded or rebuilt again), maximum (also old installers, archives, older \
                backups). Nothing is removed; use clean_junk.
                """,
                inputSchema: JSON.schema([
                    "mode": ["type": "string", "enum": ["gentle", "enhanced", "maximum"],
                             "description": "Which mode's ticks to report (default gentle)."],
                    "max_items_per_category": ["type": "integer", "description": "Items listed per category (default 50)."],
                ])) { args in
            let mode = try parseMode(Args.string(args, "mode")) ?? .gentle
            let limit = max(1, Args.int(args, "max_items_per_category", default: 50))
            let categories = await state.scanJunk()
            let notes = await state.junkNotes
            let docker = await state.docker
            var ticked: Int64 = 0
            let list: [[String: Any]] = categories.map { cat in
                let auto = Set(cat.autoSelected(in: mode).map(\.url))
                let autoBytes = cat.items.filter { auto.contains($0.url) }.reduce(0) { $0 + $1.size }
                ticked += autoBytes
                return [
                    "id": cat.id, "title": cat.title, "about": cat.detail, "risk": riskName(cat.risk),
                    "destination": destination(for: cat),
                    "ticked_from_mode": cat.gentlestMode.map(modeName) ?? NSNull(),
                    "total_bytes": cat.totalSize, "total_human": JSON.human(cat.totalSize),
                    "item_count": cat.items.count, "ticked_count": auto.count, "ticked_bytes": autoBytes,
                    "items": cat.items.prefix(limit).map { item in
                        itemJSON(item, note: notes[item.url], ticked: auto.contains(item.url),
                                 mode: cat.neverAuto.contains(item.url) ? nil : (cat.itemModes[item.url] ?? cat.mode))
                    },
                    "more_items": max(0, cat.items.count - limit),
                ]
            }
            let total = categories.reduce(0) { $0 + $1.totalSize }
            return ToolOutput(text: JSON.text([
                "full_disk_access": Permissions.hasFullDiskAccess,
                "docker": dockerName(docker),
                "mode": modeName(mode),
                "total_bytes": total, "total_human": JSON.human(total),
                "ticked_bytes": ticked, "ticked_human": JSON.human(ticked),
                "categories": list,
                "note": "Nothing was removed. clean_junk with the same mode cleans what is ticked; name items or categories to choose by hand.",
            ]))
        }
    }

    static func cleanJunk(_ state: CleanerState) -> MCPTool {
        MCPTool(name: "clean_junk",
                description: """
                Remove junk found by scan_junk. Choose by `mode` (everything that mode ticks), by `categories` \
                (whole categories; the newest backup of each device is still left out unless named in `items`), \
                or by `items` (exact paths from scan_junk). DRY RUN unless confirm=true. Files go to the Trash; \
                the Trash category is emptied for good; Docker frees its own space at once. Scans first if needed.
                """,
                inputSchema: JSON.schema([
                    "mode": ["type": "string", "enum": ["gentle", "enhanced", "maximum"]],
                    "categories": ["type": "array", "items": ["type": "string"], "description": "Category ids from scan_junk."],
                    "items": ["type": "array", "items": ["type": "string"], "description": "Paths (or Docker ids) from scan_junk."],
                    "confirm": ["type": "boolean", "description": "false/absent = dry run; true = remove."],
                ])) { args in
            let mode = try parseMode(Args.string(args, "mode"))
            let paths = Args.strings(args, "items")
            let categoryIDs = Args.strings(args, "categories")
            guard mode != nil || !paths.isEmpty || !categoryIDs.isEmpty else {
                throw RPCError.invalidParams("Give mode, categories or items.")
            }
            var categories = await state.junk
            if categories.isEmpty { categories = await state.scanJunk() }
            let (picks, unknown) = select(from: categories, paths: paths, categoryIDs: categoryIDs, mode: mode)
            let notes = await state.junkNotes
            let total = picks.reduce(0) { $0 + $1.items.reduce(0) { $0 + $1.size } }
            if !Args.bool(args, "confirm") {
                return ToolOutput(text: JSON.text([
                    "dry_run": true,
                    "total_bytes": total, "total_human": JSON.human(total),
                    "would_remove": picks.map { pick -> [String: Any] in
                        let bytes = pick.items.reduce(0) { $0 + $1.size }
                        return ["category": pick.category.id, "title": pick.category.title,
                                "destination": destination(for: pick.category),
                                "count": pick.items.count, "bytes": bytes, "human": JSON.human(bytes),
                                "items": pick.items.prefix(50).map { itemJSON($0, note: notes[$0.url], ticked: nil, mode: nil) },
                                "more_items": max(0, pick.items.count - 50)]
                    },
                    "unknown_items": unknown,
                    "note": "Nothing was removed. Call again with confirm=true to remove exactly this.",
                ]))
            }
            var result = RemovalResult()
            for pick in picks {
                result.merge(await JunkCleaner.clean(pick.items, in: pick.category))
            }
            await state.preload(junk: [])   // stale after a removal
            var out = removalJSON(result)
            out["unknown_items"] = unknown
            return ToolOutput(text: JSON.text(out))
        }
    }

    /// Pure: what `clean_junk` would pick from `categories`.
    public static func select(from categories: [JunkCategory], paths: [String], categoryIDs: [String],
                              mode: CleanupMode?) -> (picks: [Pick], unknown: [String]) {
        let wanted = Set(paths.map { normalize($0).lowercased() })
        var seen: Set<String> = []
        var picks: [Pick] = []
        for cat in categories {
            var chosen: [FileItem] = []
            for item in cat.items {
                let key = pathKey(item.url).lowercased()
                let byPath = wanted.contains(key)
                let byCategory = categoryIDs.contains(cat.id) && !cat.neverAuto.contains(item.url)
                let byMode = mode.map { m in
                    !cat.neverAuto.contains(item.url) && ((cat.itemModes[item.url] ?? cat.mode).map { $0 <= m } ?? false)
                } ?? false
                if byPath { seen.insert(key) }
                if byPath || byCategory || byMode { chosen.append(item) }
            }
            if !chosen.isEmpty { picks.append(Pick(category: cat, items: chosen)) }
        }
        let unknown = paths.filter { !seen.contains(normalize($0).lowercased()) }
        return (picks, unknown)
    }

    // MARK: Disk

    static func diskUsage() -> MCPTool {
        MCPTool(name: "disk_usage", description: "The startup disk: total and free bytes. Read-only.",
                inputSchema: JSON.schema([:])) { _ in
            let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
                .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            let total = Int64(values?.volumeTotalCapacity ?? 0)
            let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
            return ToolOutput(text: JSON.text(["volume": values?.volumeName ?? "Macintosh HD",
                                               "total_bytes": total, "free_bytes": free,
                                               "total_human": JSON.human(total), "free_human": JSON.human(free)]))
        }
    }

    // MARK: Apps

    static func listApps(_ state: CleanerState) -> MCPTool {
        MCPTool(name: "list_apps",
                description: "Installed apps with size and last use, biggest first. Read-only. `unused_for_months` keeps only apps not opened for that long.",
                inputSchema: JSON.schema([
                    "unused_for_months": ["type": "integer"],
                    "limit": ["type": "integer", "description": "Default 200."],
                ])) { args in
            var apps = await state.loadApps()
            if let months = args["unused_for_months"] as? NSNumber, months.intValue > 0 {
                let cutoff = Date().addingTimeInterval(-Double(months.intValue) * 30 * 86_400)
                apps = apps.filter { ($0.lastUsed ?? .distantPast) < cutoff }
            }
            let limit = max(1, Args.int(args, "limit", default: 200))
            let sorted = apps.sorted { $0.size > $1.size }
            return ToolOutput(text: JSON.text([
                "count": apps.count,
                "apps": sorted.prefix(limit).map(appJSON),
            ]))
        }
    }

    static func appFootprint(_ state: CleanerState) -> MCPTool {
        MCPTool(name: "app_footprint",
                description: "One app's bundle and everything it left in Library (settings, caches, containers, agents). Read-only. `app` is a bundle id, a name or a path.",
                inputSchema: JSON.schema(["app": ["type": "string"]], required: ["app"])) { args in
            let app = try await resolveApp(Args.string(args, "app"), state)
            let remnants = await state.remnants.remnants(for: app)
            return ToolOutput(text: JSON.text(footprintJSON(app, remnants)))
        }
    }

    static func uninstallApp(_ state: CleanerState) -> MCPTool {
        MCPTool(name: "uninstall_app",
                description: """
                Move an app and its leftovers to the Trash. DRY RUN unless confirm=true. `keep_data` removes only the \
                app bundle and keeps settings and data. Refused while the app is running and for macOS's own apps.
                """,
                inputSchema: JSON.schema([
                    "app": ["type": "string"], "keep_data": ["type": "boolean"], "confirm": ["type": "boolean"],
                ], required: ["app"])) { args in
            let app = try await resolveApp(Args.string(args, "app"), state)
            let remnants = Args.bool(args, "keep_data") ? [] : await state.remnants.remnants(for: app)
            guard Args.bool(args, "confirm") else {
                var out = footprintJSON(app, remnants)
                out["dry_run"] = true
                out["destination"] = "trash"
                out["note"] = "Nothing was removed. Call again with confirm=true to move exactly this to the Trash."
                return ToolOutput(text: JSON.text(out))
            }
            if AppUninstaller.isRunning(app) {
                return ToolOutput(text: "\(app.name) is running. Quit it first.", isError: true)
            }
            let result = await AppUninstaller.uninstall(app, remnants: remnants)
            await state.forgetApps()
            await state.remnants.invalidate()
            return ToolOutput(text: JSON.text(removalJSON(result)))
        }
    }

    static func findLeftovers(_ state: CleanerState) -> MCPTool {
        MCPTool(name: "find_leftovers",
                description: "Files left behind by apps that were already removed, grouped by app. Read-only.",
                inputSchema: JSON.schema([:])) { _ in
            let apps = await state.loadApps()
            let groups = await state.remnants.orphans(installed: apps)
            await state.setOrphans(groups)
            let total = groups.reduce(0) { $0 + $1.totalSize }
            return ToolOutput(text: JSON.text([
                "total_bytes": total, "total_human": JSON.human(total),
                "groups": groups.map { g in
                    ["id": g.id, "name": g.displayName, "bytes": g.totalSize, "human": JSON.human(g.totalSize),
                     "files": g.remnants.map(remnantJSON)]
                },
            ]))
        }
    }

    static func removeLeftovers(_ state: CleanerState) -> MCPTool {
        MCPTool(name: "remove_leftovers",
                description: "Move leftovers from find_leftovers to the Trash, by group id or by path. DRY RUN unless confirm=true.",
                inputSchema: JSON.schema([
                    "groups": ["type": "array", "items": ["type": "string"]],
                    "paths": ["type": "array", "items": ["type": "string"]],
                    "confirm": ["type": "boolean"],
                ])) { args in
            var groups = await state.orphans
            if groups.isEmpty {
                let apps = await state.loadApps()
                groups = await state.remnants.orphans(installed: apps)
                await state.setOrphans(groups)
            }
            let ids = Set(Args.strings(args, "groups"))
            let paths = Set(Args.strings(args, "paths").map { normalize($0).lowercased() })
            guard !ids.isEmpty || !paths.isEmpty else { throw RPCError.invalidParams("Give groups or paths.") }
            // A whole group means what the app itself ticks — the sure matches; a name-only guess goes only by path.
            let chosen = groups.flatMap { g in
                g.remnants.filter { (ids.contains(g.id) && $0.confidence == .high) || paths.contains(pathKey($0.item.url).lowercased()) }
            }
            let total = chosen.reduce(0) { $0 + $1.item.size }
            guard Args.bool(args, "confirm") else {
                return ToolOutput(text: JSON.text([
                    "dry_run": true, "destination": "trash", "count": chosen.count,
                    "total_bytes": total, "total_human": JSON.human(total),
                    "files": chosen.map(remnantJSON),
                    "note": "Nothing was removed. Call again with confirm=true.",
                ]))
            }
            let result = await AppUninstaller.remove(chosen)
            await state.setOrphans([])
            return ToolOutput(text: JSON.text(removalJSON(result)))
        }
    }

    // MARK: Files

    static func oldFiles(_ state: CleanerState) -> MCPTool {
        MCPTool(name: "old_files",
                description: "Large files in Desktop, Documents, Downloads, Movies, Music and Pictures that were not opened for `months` (default 6) and are at least `min_mb` (default 50). Read-only; these are the user's own files.",
                inputSchema: JSON.schema([
                    "months": ["type": "integer"], "min_mb": ["type": "integer"], "limit": ["type": "integer"],
                ])) { args in
            var options = OldFilesOptions.default
            options.unusedForDays = max(1, Args.int(args, "months", default: 6)) * 30
            options.minSize = Int64(max(1, Args.int(args, "min_mb", default: 50))) * 1_000_000
            let files = await state.analyzer.oldFiles(options)
            return ToolOutput(text: filesJSON(files, limit: Args.int(args, "limit", default: 100)))
        }
    }

    static func largeFiles(_ state: CleanerState) -> MCPTool {
        MCPTool(name: "large_files",
                description: "The biggest files in the user's folders, at least `min_mb` (default 500). Read-only.",
                inputSchema: JSON.schema(["min_mb": ["type": "integer"], "limit": ["type": "integer"]])) { args in
            let minSize = Int64(max(1, Args.int(args, "min_mb", default: 500))) * 1_000_000
            let files = await state.analyzer.largeFiles(roots: FileAnalyzer.defaultRoots, minSize: minSize)
            return ToolOutput(text: filesJSON(files, limit: Args.int(args, "limit", default: 100)))
        }
    }

    static func duplicates(_ state: CleanerState) -> MCPTool {
        MCPTool(name: "duplicates",
                description: "Byte-identical files in the user's folders, at least `min_mb` (default 10), most wasted space first. In each group the oldest file comes first (likely the original). Read-only.",
                inputSchema: JSON.schema(["min_mb": ["type": "integer"], "limit": ["type": "integer"]])) { args in
            let minSize = Int64(max(1, Args.int(args, "min_mb", default: 10))) * 1_000_000
            let groups = await state.analyzer.duplicates(roots: FileAnalyzer.defaultRoots, minSize: minSize)
            let limit = max(1, Args.int(args, "limit", default: 50))
            let wasted = groups.reduce(0) { $0 + $1.dropFirst().reduce(0) { $0 + $1.item.size } }
            return ToolOutput(text: JSON.text([
                "group_count": groups.count, "wasted_bytes": wasted, "wasted_human": JSON.human(wasted),
                "groups": groups.prefix(limit).map { g in
                    ["wasted_bytes": g.dropFirst().reduce(0) { $0 + $1.item.size }, "files": g.map(fileJSON)]
                },
            ]))
        }
    }

    static func trashFiles() -> MCPTool {
        MCPTool(name: "trash_files",
                description: "Move files or folders to the Trash (for example from old_files or duplicates). DRY RUN unless confirm=true. System and personal-data locations are refused.",
                inputSchema: JSON.schema([
                    "paths": ["type": "array", "items": ["type": "string"]], "confirm": ["type": "boolean"],
                ], required: ["paths"])) { args in
            let paths = Args.strings(args, "paths")
            guard !paths.isEmpty else { throw RPCError.invalidParams("paths is empty") }
            let urls = paths.map { URL(fileURLWithPath: normalize($0)) }
            var rows: [[String: Any]] = []
            var total: Int64 = 0
            var ok: [URL] = []
            for url in urls {
                if let reason = SafetyGuard.refusalReason(for: url) {
                    rows.append(["path": url.path, "refused": reason])
                } else if !FileManager.default.fileExists(atPath: url.path) {
                    rows.append(["path": url.path, "refused": "not found"])
                } else {
                    let size = FileSizer.allocatedSize(of: url)
                    total += size
                    ok.append(url)
                    rows.append(["path": url.path, "bytes": size, "human": JSON.human(size)])
                }
            }
            guard Args.bool(args, "confirm") else {
                return ToolOutput(text: JSON.text([
                    "dry_run": true, "destination": "trash", "count": ok.count,
                    "total_bytes": total, "total_human": JSON.human(total), "files": rows,
                    "note": "Nothing was moved. Call again with confirm=true.",
                ]))
            }
            let result = await FileRemover.moveToTrash(ok)
            var out = removalJSON(result)
            out["refused"] = rows.filter { $0["refused"] != nil }
            return ToolOutput(text: JSON.text(out))
        }
    }

    // MARK: Health

    static func macHealth() -> MCPTool {
        MCPTool(name: "mac_health",
                description: "Battery wear, SSD wear and SMART, free and purgeable space with local Time Machine snapshots, memory pressure, Intel-only apps. Read-only; takes about a second.",
                inputSchema: JSON.schema([:])) { _ in
            let report = await MacHealthCheck.run()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var object = (try? JSONSerialization.jsonObject(with: encoder.encode(report))) as? [String: Any] ?? [:]
            object["concerns"] = report.concerns.map { "\($0)" }
            return ToolOutput(text: JSON.text(object))
        }
    }

    // MARK: Startup

    static func startupItems(_ state: CleanerState) -> MCPTool {
        MCPTool(name: "startup_items",
                description: "Launch agents, daemons and login items with owner, signer and state. Read-only. macOS's own items are left out unless `include_apple`. Login items of apps are only known to macOS and need the administrator password; they are not listed here.",
                inputSchema: JSON.schema(["include_apple": ["type": "boolean"]])) { args in
            let includeApple = Args.bool(args, "include_apple")
            let items = await Task.detached { StartupScanner().launchdItems() }.value
            await state.setStartupItems(items)
            return ToolOutput(text: JSON.text([
                "count": items.count,
                "items": items.filter { includeApple || !$0.isApple }.map(startupJSON),
            ]))
        }
    }

    static func setStartupItem(_ state: CleanerState) -> MCPTool {
        MCPTool(name: "set_startup_item",
                description: "Disable (reversible), enable or remove startup items by id from startup_items. DRY RUN unless confirm=true. Removing moves the item's plist to the Trash; daemons need the administrator password, which macOS asks for in its own dialog.",
                inputSchema: JSON.schema([
                    "ids": ["type": "array", "items": ["type": "string"]],
                    "action": ["type": "string", "enum": ["disable", "enable", "remove"]],
                    "confirm": ["type": "boolean"],
                ], required: ["ids", "action"])) { args in
            let action: StartupAction = switch Args.string(args, "action") {
            case "disable": .disable
            case "enable": .enable
            case "remove": .remove
            default: throw RPCError.invalidParams("action must be disable, enable or remove")
            }
            let ids = Set(Args.strings(args, "ids"))
            guard !ids.isEmpty else { throw RPCError.invalidParams("ids is empty") }
            var items = await state.startupItems
            if items.isEmpty {
                items = await Task.detached { StartupScanner().launchdItems() }.value
                await state.setStartupItems(items)
            }
            let chosen = items.filter { ids.contains($0.id) }
            let unknown = ids.subtracting(chosen.map(\.id))
            let plan: [[String: Any]] = chosen.map { item in
                ["id": item.id, "name": item.displayName,
                 "result": StartupActions.refusal(action, for: item) ?? "ok"]
            }
            guard Args.bool(args, "confirm") else {
                return ToolOutput(text: JSON.text(["dry_run": true, "action": Args.string(args, "action") ?? "",
                                                   "items": plan, "unknown_ids": Array(unknown).sorted(),
                                                   "note": "Nothing was changed. Call again with confirm=true."]))
            }
            let report = await StartupActions.perform(action, on: chosen)
            await state.setStartupItems([])
            return ToolOutput(text: JSON.text([
                "succeeded": report.succeeded,
                "failed": report.failed.map { ["id": $0.id, "reason": $0.reason] },
                "unknown_ids": Array(unknown).sorted(),
            ]))
        }
    }

    // MARK: Trash

    static func emptyTrash() -> MCPTool {
        MCPTool(name: "empty_trash",
                description: "Delete everything in the user's Trash FOR GOOD. DRY RUN unless confirm=true. Items the system owns ask for the administrator password in a macOS dialog.",
                inputSchema: JSON.schema(["confirm": ["type": "boolean"]])) { args in
            let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: trash.path) else {
                return ToolOutput(text: "The Trash cannot be read: the host app needs Full Disk Access.", isError: true)
            }
            let urls = names.filter { $0 != ".DS_Store" }.map { trash.appendingPathComponent($0) }
            let sizes = Dictionary(uniqueKeysWithValues: urls.map { ($0, FileSizer.allocatedSize(of: $0)) })
            let total = sizes.values.reduce(0, +)
            guard Args.bool(args, "confirm") else {
                return ToolOutput(text: JSON.text([
                    "dry_run": true, "destination": "permanent", "count": urls.count,
                    "total_bytes": total, "total_human": JSON.human(total),
                    "items": urls.map { ["path": $0.path, "bytes": sizes[$0] ?? 0] },
                    "note": "Nothing was deleted. This cannot be undone: call again with confirm=true only on the user's explicit word.",
                ]))
            }
            let result = await FileRemover.deletePermanentlyFromTrash(urls, knownSizes: sizes)
            return ToolOutput(text: JSON.text(removalJSON(result)))
        }
    }

    // MARK: Shared pieces

    static func parseMode(_ text: String?) throws -> CleanupMode? {
        guard let text else { return nil }
        switch text.lowercased() {
        case "gentle", "бережная": return .gentle
        case "enhanced", "усиленная": return .enhanced
        case "maximum", "максимальная": return .maximum
        default: throw RPCError.invalidParams("mode must be gentle, enhanced or maximum")
        }
    }

    static func modeName(_ mode: CleanupMode) -> String {
        switch mode {
        case .gentle: "gentle"
        case .enhanced: "enhanced"
        case .maximum: "maximum"
        }
    }

    static func riskName(_ risk: RiskLevel) -> String {
        switch risk {
        case .safe: "safe"
        case .review: "review"
        case .caution: "caution"
        }
    }

    static func dockerName(_ status: DockerStatus) -> String {
        switch status {
        case .absent: "not_installed"
        case .notRunning: "not_running"
        case .ready: "ready"
        }
    }

    /// Where a category's items go when removed.
    public static func destination(for category: JunkCategory) -> String {
        switch category.id {
        case JunkCategoryID.trash: "permanent"
        case JunkCategoryID.docker: "docker"
        default: "trash"
        }
    }

    /// A file's path, or a Docker item's id (`docker-cleanup:///build-cache`). Standardized (`/private` dropped),
    /// the same spelling `normalize` gives a path a client sends back.
    public static func pathKey(_ url: URL) -> String { url.isFileURL ? url.standardizedFileURL.path : url.absoluteString }

    static func normalize(_ path: String) -> String {
        if path.hasPrefix("\(DockerCleanup.scheme):") { return path }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    static func itemJSON(_ item: FileItem, note: String?, ticked: Bool?, mode: CleanupMode?) -> [String: Any] {
        var row: [String: Any] = ["path": pathKey(item.url), "bytes": item.size, "human": JSON.human(item.size)]
        if let note { row["note"] = note }
        if let ticked { row["ticked"] = ticked }
        if let mode { row["ticked_from_mode"] = modeName(mode) }
        if item.url.isFileURL { row["is_folder"] = item.isDirectory }
        return row
    }

    static func fileJSON(_ file: AnalyzedFile) -> [String: Any] {
        ["path": file.item.url.path, "bytes": file.item.size, "human": JSON.human(file.item.size),
         "kind": file.kind.rawValue, "last_used": JSON.date(file.item.lastUsed), "modified": JSON.date(file.item.modified)]
    }

    static func filesJSON(_ files: [AnalyzedFile], limit: Int) -> String {
        let total = files.reduce(0) { $0 + $1.item.size }
        return JSON.text(["count": files.count, "total_bytes": total, "total_human": JSON.human(total),
                          "files": files.prefix(max(1, limit)).map(fileJSON)])
    }

    static func appJSON(_ app: InstalledApp) -> [String: Any] {
        ["name": app.name, "bundle_id": app.bundleID ?? NSNull(), "version": app.version ?? NSNull(),
         "path": app.url.path, "bytes": app.size, "human": JSON.human(app.size),
         "last_used": JSON.date(app.lastUsed), "is_system": app.isSystemApp, "is_app_store": app.isAppStore]
    }

    static func remnantJSON(_ r: AppRemnant) -> [String: Any] {
        ["path": r.item.url.path, "bytes": r.item.size, "human": JSON.human(r.item.size),
         "kind": r.kind.rawValue, "confidence": "\(r.confidence)", "needs_admin": r.requiresAdmin]
    }

    static func footprintJSON(_ app: InstalledApp, _ remnants: [AppRemnant]) -> [String: Any] {
        let leftovers = remnants.reduce(0) { $0 + $1.item.size }
        return ["app": appJSON(app), "running": AppUninstaller.isRunning(app),
                "leftovers_bytes": leftovers, "leftovers_human": JSON.human(leftovers),
                "total_bytes": app.size + leftovers, "total_human": JSON.human(app.size + leftovers),
                "leftovers": remnants.map(remnantJSON)]
    }

    static func startupJSON(_ item: StartupItem) -> [String: Any] {
        [
            "id": item.id, "name": item.displayName, "label": item.label,
            "group": "\(item.group)", "source": item.source.rawValue,
            "owner": item.ownerName ?? NSNull(), "developer": item.developerName ?? NSNull(),
            "signer_team": item.signer.team ?? NSNull(), "apple": item.isApple,
            "enabled": item.isEnabled, "running": item.isRunning, "malformed": item.isMalformed,
            "plist": item.plist?.path ?? NSNull(), "program": item.program ?? NSNull(),
            "can": ["disable": StartupActions.refusal(.disable, for: item) ?? "ok",
                    "enable": StartupActions.refusal(.enable, for: item) ?? "ok",
                    "remove": StartupActions.refusal(.remove, for: item) ?? "ok"],
        ]
    }

    static func removalJSON(_ result: RemovalResult) -> [String: Any] {
        [
            "removed_count": result.removed.count,
            "freed_bytes": result.freedBytes, "freed_human": JSON.human(result.freedBytes),
            "in_trash_bytes": result.freedBytes - result.freedForGood,
            "freed_at_once_bytes": result.freedForGood,
            "failed": result.failed.map { ["path": pathKey($0.url), "reason": $0.reason] },
        ]
    }

    static func resolveApp(_ query: String?, _ state: CleanerState) async throws -> InstalledApp {
        guard let query else { throw RPCError.invalidParams("app is required") }
        let apps = await state.loadApps()
        let q = query.lowercased()
        let path = normalize(query).lowercased()
        let matches = apps.filter {
            $0.bundleID?.lowercased() == q || $0.name.lowercased() == q || $0.url.path.lowercased() == path
                || $0.url.lastPathComponent.lowercased() == q
        }
        guard let app = matches.first else {
            throw RPCError.invalidParams("No installed app matches \"\(query)\" (use a bundle id, the exact name or the path).")
        }
        // Two copies (/Applications and ~/Applications, say): never guess which one is meant.
        if matches.count > 1 {
            throw RPCError.invalidParams("Several apps match \"\(query)\": \(matches.map(\.url.path).joined(separator: ", ")). Give the path.")
        }
        return app
    }
}

extension CleanerState {
    func setOrphans(_ groups: [OrphanGroup]) { orphans = groups }
    func setStartupItems(_ items: [StartupItem]) { startupItems = items }
}
