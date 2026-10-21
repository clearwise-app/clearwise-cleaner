import Foundation
import Darwin

/// Caches of apps built on Electron or another Chromium embedding (Slack, Discord, VS Code, Cursor, Notion,
/// Figma, Obsidian, Postman…). Each keeps a whole Chromium user data folder in
/// `~/Library/Application Support/<App>` (or `<Vendor>/<App>`, or the same inside its container), and the
/// regenerable part of it never shows up in `~/Library/Caches`.
///
/// A folder counts as such only if it has Chromium's `Local State` file. Inside it, and inside each Electron
/// session partition (`Partitions/<name>`), only the real folders named in `regenerableFolders` are offered.
/// Everything else stays, notably `Local Storage`, `IndexedDB`, `Session Storage`, `WebStorage`, `Cookies`,
/// `Local State`, `Preferences`, `databases` and `blob_storage` (sign-ins, drafts, offline data), and the whole
/// `Service Worker` folder: Chromium treats its `CacheStorage` as site data, not cache (apps keep their offline
/// copy there), and removing `ScriptCache` breaks the registered workers.
///
/// Browsers' user data folders belong to "Кэш браузеров". A folder whose app is running is skipped as a whole
/// (see `RunningApps`): Chromium keeps these caches open and memory-mapped.
enum ChromiumAppCaches {
    /// What Chromium rebuilds by itself: the HTTP cache, V8 code cache, GPU and shader caches, component
    /// downloads, and the VS Code family's own code cache and downloaded extension packages.
    static let regenerableFolders = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "GrShaderCache", "GraphiteDawnCache", "ShaderCache", "GPUPersistentCache", "component_crx_cache",
        "CachedData", "CachedExtensionVSIXs",
    ]

    static func candidates(_ env: JunkEnvironment) -> [JunkCandidate] {
        let folders = userDataFolders(in: env)
        guard !folders.isEmpty else { return [] }
        let running = env.runningApps()
        let names = InstalledChromiumApps.displayNames(in: env.applicationFolders)
        var result: [JunkCandidate] = []
        for root in folders where !running.uses(root) {
            let app = names.lookup(nameKeys(of: root)) ?? root.lastPathComponent
            for (url, label) in caches(in: root) {
                result.append(JunkCandidate(url, note: "\(app) · \(label)"))
            }
        }
        return result
    }

    /// The Chromium user data folder a cache item belongs to (its parent, or three levels up for a partition).
    static func owningUserDataFolder(of url: URL) -> URL? {
        var folder = url.deletingLastPathComponent()
        for _ in 0..<3 {
            if isUserDataFolder(folder) { return folder }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: Discovery

    static func userDataFolders(in env: JunkEnvironment) -> [URL] {
        var bases = [env.homePath("Library/Application Support")]
        // Opening other apps' containers without Full Disk Access brings up a blocking consent prompt.
        if env.readsAppContainers {
            for container in FS.children(of: env.homePath("Library/Containers"))
            where FS.isDirectory(container) && !container.lastPathComponent.lowercased().hasPrefix("com.apple.") {
                bases.append(container.appendingPathComponent("Data/Library/Application Support"))
            }
        }
        let browsers = Set(BrowserCacheSpec.all.compactMap(\.userDataFolder).map { FS.key(env.homePath($0)) })
        var result: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            let key = FS.key(url)
            if !browsers.contains(key), seen.insert(key).inserted { result.append(url) }
        }
        for base in bases where FS.isDirectory(base) {
            for child in FS.children(of: base) where FS.isDirectory(child) {
                if isUserDataFolder(child) { add(child); continue }
                // One vendor level: `Microsoft/Teams`, `Google/Chrome`…
                let name = child.lastPathComponent.lowercased()
                if name.hasPrefix("com.apple.") || name == "mobilesync" || name == "addressbook" { continue }
                for grandchild in FS.children(of: child) where isUserDataFolder(grandchild) { add(grandchild) }
            }
        }
        return result
    }

    static func isUserDataFolder(_ url: URL) -> Bool {
        var st = stat()
        let localState = url.appendingPathComponent("Local State")
        return FS.isDirectory(url) && lstat(localState.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    /// Allowed cache folders of one user data folder and of its partitions. Symlinks are never followed.
    static func caches(in root: URL) -> [(URL, String)] {
        var result = regenerableFolders.map { (root.appendingPathComponent($0), $0) }
        let partitions = root.appendingPathComponent("Partitions")
        if FS.isDirectory(partitions) {
            for partition in FS.children(of: partitions) where FS.isDirectory(partition) {
                result += regenerableFolders.map {
                    (partition.appendingPathComponent($0), "\(partition.lastPathComponent) · \($0)")
                }
            }
        }
        return result.filter { FS.isDirectory($0.0) }
    }

    /// Names an app could give its data folder: `Teams` → "teams", plus "microsoft teams" for `Microsoft/Teams`.
    static func nameKeys(of root: URL) -> [String] {
        let name = root.lastPathComponent.lowercased()
        let parent = root.deletingLastPathComponent().lastPathComponent
        guard parent != "Application Support" else { return [name] }
        return [name, parent.lowercased() + " " + name]
    }

    /// Bundle id of the container the folder lives in (`~/Library/Containers/<id>/Data/…`), if any.
    static func containerID(of root: URL) -> String? {
        let parts = root.pathComponents
        guard let i = parts.firstIndex(of: "Containers"), i > 0, parts[i - 1] == "Library",
              i + 2 < parts.count, parts[i + 2] == "Data" else { return nil }
        return parts[i + 1].lowercased()
    }
}

// MARK: - Running apps

/// What is running right now, as far as Chromium user data goes. Chromium starts every helper process
/// (GPU, network, renderers) with `--user-data-dir=<folder>`, which names the folder in use exactly;
/// bundle names and ids of running apps catch apps whose main process alone is left.
struct RunningApps: Sendable {
    /// `FS.key`s of the `--user-data-dir` folders on running processes' command lines.
    var userDataFolders: Set<String> = []
    /// Lowercased `CFBundleName`, `CFBundleDisplayName`, `CFBundleExecutable` and bundle file names.
    var names: Set<String> = []
    /// Lowercased bundle ids.
    var bundleIDs: Set<String> = []

    func uses(_ root: URL) -> Bool {
        let key = FS.key(root)
        if userDataFolders.contains(where: { $0 == key || $0.hasPrefix(key + "/") || key.hasPrefix($0 + "/") }) {
            return true
        }
        if ChromiumAppCaches.nameKeys(of: root).contains(where: names.contains) { return true }
        if let id = ChromiumAppCaches.containerID(of: root), bundleIDs.contains(id) { return true }
        return false
    }

    /// Reads the command lines of the current user's processes (the same data `ps` shows).
    static func current() -> RunningApps {
        var result = RunningApps()
        var bundles = Set<String>()
        for pid in userProcessIDs() {
            guard let (executable, arguments) = commandLine(of: pid) else { continue }
            for (i, arg) in arguments.enumerated() {
                var value: String?
                if arg.hasPrefix("--user-data-dir=") {
                    value = String(arg.dropFirst("--user-data-dir=".count))
                } else if arg == "--user-data-dir", i + 1 < arguments.count {
                    value = arguments[i + 1]
                }
                if let value, value.hasPrefix("/") { result.userDataFolders.insert(FS.key(URL(fileURLWithPath: value))) }
            }
            if let bundle = outermostBundle(of: executable) { bundles.insert(bundle) }
        }
        for path in bundles {
            let url = URL(fileURLWithPath: path)
            result.names.insert(url.deletingPathExtension().lastPathComponent.lowercased())
            guard let info = InstalledChromiumApps.infoPlist(of: url) else { continue }
            for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
                if let name = info[key] as? String, !name.isEmpty { result.names.insert(name.lowercased()) }
            }
            if let id = info["CFBundleIdentifier"] as? String { result.bundleIDs.insert(id.lowercased()) }
        }
        return result
    }

    /// `/Applications/Slack.app/Contents/Frameworks/Slack Helper (GPU).app/…` → `/Applications/Slack.app`.
    static func outermostBundle(of executable: String) -> String? {
        guard let range = executable.range(of: ".app/", options: .caseInsensitive) else { return nil }
        return String(executable[..<range.lowerBound]) + ".app"
    }

    private static func userProcessIDs() -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // Room for processes started between the two calls.
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / stride).map { $0.kp_proc.p_pid }.filter { $0 > 0 }
    }

    /// `KERN_PROCARGS2`: argc, the executable path, padding, then argv. Nil for processes we may not read.
    private static func commandLine(of pid: pid_t) -> (String, [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var strings: [String] = []
        var i = MemoryLayout<Int32>.size
        while i < size, strings.count <= argc {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            if i > start { strings.append(String(decoding: buffer[start..<i], as: UTF8.self)) }
            while i < size, buffer[i] == 0 { i += 1 }
        }
        guard let executable = strings.first else { return nil }
        return (executable, Array(strings.dropFirst().prefix(argc).dropFirst()))
    }
}

// MARK: - Installed apps

/// Finder names of installed apps that embed Chromium, keyed by the names their data folder may carry
/// (the data folder of "Visual Studio Code" is `Code`, Discord's is `discord`).
enum InstalledChromiumApps {
    struct Names {
        var byKey: [String: String] = [:]
        func lookup(_ keys: [String]) -> String? { keys.lazy.compactMap { byKey[$0] }.first }
    }

    static let frameworks = ["Electron Framework.framework", "Chromium Embedded Framework.framework"]

    static func displayNames(in folders: [URL]) -> Names {
        var names = Names()
        for folder in folders {
            for entry in FS.children(of: folder) {
                if entry.pathExtension.lowercased() == "app" {
                    add(entry, to: &names)
                } else if FS.isDirectory(entry) {
                    for app in FS.children(of: entry) where app.pathExtension.lowercased() == "app" { add(app, to: &names) }
                }
            }
        }
        return names
    }

    private static func add(_ app: URL, to names: inout Names) {
        let frameworksFolder = app.appendingPathComponent("Contents/Frameworks")
        guard frameworks.contains(where: { FS.exists(frameworksFolder.appendingPathComponent($0)) }) else { return }
        let display = app.deletingPathExtension().lastPathComponent
        var keys = [display]
        if let info = infoPlist(of: app) {
            keys += ["CFBundleName", "CFBundleDisplayName"].compactMap { info[$0] as? String }
        }
        for key in keys where !key.isEmpty && names.byKey[key.lowercased()] == nil {
            names.byKey[key.lowercased()] = display
        }
    }

    static func infoPlist(of app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
