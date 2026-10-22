import Foundation
import CleanerKit

/// Discovery logic for categories that need more than a directory listing.
/// Everything here is read-only.
enum SpecialCollectors {

    // MARK: Old installers

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]

    /// `.dmg/.pkg/.mpkg/.iso/.xip` directly in ~/Downloads and ~/Desktop or one folder deep.
    static func installers(_ env: JunkEnvironment) -> [JunkCandidate] {
        var result: [JunkCandidate] = []
        for folder in ["Downloads", "Desktop"] {
            for child in FS.children(of: env.homePath(folder)) {
                if isInstaller(child) {
                    result.append(JunkCandidate(child))
                } else if isPlainFolder(child) {
                    result += FS.children(of: child).filter(isInstaller).map { JunkCandidate($0) }
                }
            }
        }
        return result
    }

    private static func isInstaller(_ url: URL) -> Bool {
        installerExtensions.contains(url.pathExtension.lowercased())
    }

    /// A real folder, not a bundle like `.app` or an installer package.
    private static func isPlainFolder(_ url: URL) -> Bool {
        guard FS.isDirectory(url) else { return false }
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        return !isPackage
    }

    // MARK: Group containers

    /// Children of `~/Library/Group Containers/<id>/Library/Caches` of third-party apps. Only with Full Disk
    /// Access (otherwise macOS shows a blocking consent prompt). Apple's containers and Safari extensions'
    /// (their content blocker rules live there) are never opened.
    static func groupContainerCaches(_ env: JunkEnvironment) -> [JunkCandidate] {
        guard env.readsAppContainers else { return [] }
        var result: [JunkCandidate] = []
        for container in FS.children(of: env.homePath("Library/Group Containers")) where FS.isDirectory(container) {
            let name = container.lastPathComponent.lowercased()
            if SafetyGuard.isAppleGroupContainerName(name) || name.contains("safari") { continue }
            let caches = container.appendingPathComponent("Library/Caches")
            guard FS.isDirectory(container.appendingPathComponent("Library")), FS.isDirectory(caches) else { continue }
            result += FS.children(of: caches).map { JunkCandidate($0) }
        }
        return result
    }

    // MARK: JetBrains

    /// `~/Library/Caches/JetBrains/<IDE>/{caches,index,tmp,log,jcef_cache}` — only the folders listed in
    /// `JunkCatalog.jetBrainsRegenerableFolders`, and only real folders (never symlinks). `LocalHistory`
    /// and any other entry are never returned.
    static func jetBrainsCaches(_ env: JunkEnvironment) -> [JunkCandidate] {
        var result: [JunkCandidate] = []
        let base = env.homePath("Library/Caches/JetBrains")
        for ide in FS.children(of: base) where FS.isDirectory(ide) {
            for name in JunkCatalog.jetBrainsRegenerableFolders {
                let url = ide.appendingPathComponent(name)
                if FS.isDirectory(url) {
                    result.append(JunkCandidate(url, note: "\(ide.lastPathComponent) · \(name)"))
                }
            }
        }
        return result
    }

    // MARK: System logs

    /// Archived (rotated) logs and diagnostic reports from `/Library/Logs` and `/private/var/log`,
    /// plus anything there the user can already remove. Active logs that syslog/installd keep open
    /// (system.log, install.log, wifi.log…) are left alone.
    static func systemLogs(_ env: JunkEnvironment) -> [JunkCandidate] {
        var result: [JunkCandidate] = []
        for root in env.systemLogRoots {
            for child in FS.children(of: root) {
                let name = child.lastPathComponent
                if name == "DiagnosticReports", FS.isDirectory(child) {
                    result += FS.children(of: child).map { JunkCandidate($0, note: note(for: $0)) }
                } else if isRotatedLog(name) || FileManager.default.isDeletableFile(atPath: child.path) {
                    result.append(JunkCandidate(child, note: note(for: child)))
                }
            }
        }
        return result
    }

    private static func note(for url: URL) -> String? {
        FileManager.default.isDeletableFile(atPath: url.path) ? nil : "Нужен пароль администратора"
    }

    static func isRotatedLog(_ name: String) -> Bool {
        let lower = name.lowercased()
        let archiveExt = [".gz", ".bz2", ".xz", ".zip", ".old", ".bak"]
        if archiveExt.contains(where: { lower.hasSuffix($0) }) { return true }
        // keybagd.log.0, daily.out.3
        if let last = lower.split(separator: ".").last, lower.contains("."), last.allSatisfy(\.isNumber) { return true }
        return false
    }

    // MARK: iOS backups

    /// Each backup folder is one item, labelled with the device name and backup date from `Info.plist`.
    /// The newest backup of each device is `neverAuto`: no cleanup mode ticks a device's last copy.
    static func iosBackups(_ env: JunkEnvironment) -> [JunkCandidate] {
        let root = env.homePath("Library/Application Support/MobileSync/Backup")
        struct Backup { let url: URL; let device: String?; let deviceKey: String; let date: Date? }
        let backups: [Backup] = FS.children(of: root).filter(FS.isDirectory).map { url in
            let info = (try? Data(contentsOf: url.appendingPathComponent("Info.plist")))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            let device = (info?["Device Name"] as? String) ?? (info?["Display Name"] as? String)
            // One device = one identifier; without one, every folder counts as its own device (never ticked).
            let key = (info?["Target Identifier"] as? String) ?? (info?["Unique Identifier"] as? String) ?? url.path
            return Backup(url: url, device: device, deviceKey: key, date: info?["Last Backup Date"] as? Date)
        }
        // The label marks the newest backup overall; the mode guard protects the newest of every device.
        let newestOverall = backups.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }?.url
        var newest: [String: Backup] = [:]
        for b in backups {
            if let current = newest[b.deviceKey], (current.date ?? .distantPast) >= (b.date ?? .distantPast) { continue }
            newest[b.deviceKey] = b
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return backups.map { b in
            var parts = [b.device ?? "Устройство"]
            if let date = b.date { parts.append(formatter.string(from: date)) }
            if b.url == newestOverall, backups.count > 1 { parts.append("самая свежая") }
            return JunkCandidate(b.url, note: parts.joined(separator: " · "), neverAuto: newest[b.deviceKey]?.url == b.url)
        }
    }

    // MARK: Broken preferences

    /// `~/Library/Preferences/*.plist` (and `ByHost/`) that PropertyListSerialization cannot parse into a dictionary.
    /// Apple's own and global preference files are never offered; unreadable files (permissions) are skipped,
    /// as are files written within the last minute (cfprefsd may be mid-write).
    static func brokenPreferences(_ env: JunkEnvironment) -> [JunkCandidate] {
        let root = env.homePath("Library/Preferences")
        let files = FS.children(of: root) + FS.children(of: root.appendingPathComponent("ByHost"))
        return files.compactMap { url in
            let name = url.lastPathComponent
            guard url.pathExtension == "plist",
                  !name.hasPrefix("com.apple."), !name.hasPrefix(".Global"), !FS.isDirectory(url),
                  !recentlyModified(url, env: env)
            else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }   // unreadable ≠ broken
            // A preferences file is always a dictionary; a bare word would parse as an OpenStep string.
            if (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any] { return nil }
            return JunkCandidate(url, note: data.isEmpty ? "Пустой файл" : "Файл повреждён и не читается")
        }
    }

    // MARK: Broken launch agents

    /// `~/Library/LaunchAgents/*.plist` that cannot be parsed or whose `Program` /
    /// `ProgramArguments[0]` no longer exists. Executables on unmounted volumes or in folders we
    /// cannot list (privacy protection) are treated as "unknown", not broken.
    static func brokenLaunchAgents(_ env: JunkEnvironment) -> [JunkCandidate] {
        FS.children(of: env.homePath("Library/LaunchAgents")).compactMap { url in
            guard url.pathExtension == "plist", !FS.isDirectory(url) else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
                return JunkCandidate(url, note: "Файл повреждён и не читается")
            }
            guard let program = executablePath(of: plist) else { return nil }   // BundleProgram etc. — can't verify
            let expanded = program.hasPrefix("~") ? env.home.path + program.dropFirst() : program
            guard expanded.hasPrefix("/") else { return nil }                    // resolved via PATH — can't verify
            let exe = URL(fileURLWithPath: expanded)
            if FS.exists(exe) || !isVerifiablyMissing(exe) { return nil }
            return JunkCandidate(url, note: "Программа не найдена: \(program)")
        }
    }

    static func executablePath(of plist: [String: Any]) -> String? {
        if let program = plist["Program"] as? String, !program.isEmpty { return program }
        if let args = plist["ProgramArguments"] as? [String], let first = args.first, !first.isEmpty { return first }
        return nil
    }

    /// True only when we can actually see that the file is gone: its volume is mounted and the
    /// nearest existing parent folder is listable.
    private static func isVerifiablyMissing(_ url: URL) -> Bool {
        let comps = url.pathComponents
        if comps.count > 2, comps[1] == "Volumes", !FS.exists(URL(fileURLWithPath: "/Volumes/" + comps[2])) {
            return false
        }
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" && !FS.exists(parent) { parent = parent.deletingLastPathComponent() }
        return FS.canList(parent)
    }

    private static func recentlyModified(_ url: URL, env: JunkEnvironment) -> Bool {
        guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return false }
        return env.now.timeIntervalSince(date) < env.activeWindow
    }
}
