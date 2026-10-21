import Foundation

/// The single place where the app removes files.
/// Default behaviour is "move to Trash" so every action is undoable from Finder.
public enum FileRemover {
    /// Moves items to the user's Trash. Protected paths are refused and reported as failures.
    public static func moveToTrash(_ urls: [URL], knownSizes: [URL: Int64] = [:],
                                   progress: RemovalProgressHandler? = nil) async -> RemovalResult {
        await Task.detached(priority: .userInitiated) {
            var result = RemovalResult()
            for url in dedupeNested(urls) {
                progress?(RemovalStep(url: url, bytes: 0, done: false))
                var freed: Int64 = 0
                defer { progress?(RemovalStep(url: url, bytes: freed, done: true)) }
                if let reason = SafetyGuard.refusalReason(for: url) {
                    result.failed.append(RemovalFailure(url: url, reason: reason))
                    continue
                }
                guard FileManager.default.fileExists(atPath: url.path) || isSymlink(url) else {
                    // Already gone — treat as success, nothing freed.
                    result.removed.append(url)
                    continue
                }
                let size = knownSizes[url] ?? FileSizer.allocatedSize(of: url)
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    result.removed.append(url)
                    result.freedBytes += size
                    freed = size
                } catch {
                    result.failed.append(RemovalFailure(url: url, reason: error.localizedDescription))
                }
            }
            return result
        }.value
    }

    /// Moves root-owned items (e.g. /Library/LaunchDaemons/*.plist) to the user's Trash
    /// after asking for the administrator password once via the standard macOS prompt.
    ///
    /// Hardening (root acts on paths the user typed a password for, possibly much later):
    /// - items inside world-writable or sticky folders (/Library/Caches, /Users/Shared…) never go through root —
    ///   another user or process could swap them; they are trashed as the current user or reported;
    /// - the destination name is random (UUID) and the move is refused if it already exists or is a link;
    /// - ownership is NOT changed afterwards (a recursive chown as root could be redirected via hard links),
    ///   so Finder will ask for the password again when emptying the Trash, and "Put Back" is not available.
    /// A privileged helper (SMAppService + XPC, fd-based renames) would close the remaining TOCTOU window.
    public static func moveToTrashAsAdmin(_ urls: [URL], knownSizes: [URL: Int64] = [:],
                                          progress: RemovalProgressHandler? = nil) async -> RemovalResult {
        var result = RemovalResult()
        var allowed: [URL] = []
        var sharedFolderItems: [URL] = []
        for url in dedupeNested(urls) {
            if let reason = SafetyGuard.refusalReason(for: url) {
                result.failed.append(RemovalFailure(url: url, reason: reason))
                progress?(RemovalStep(url: url, bytes: 0, done: true))
            } else if isInSharedWritableFolder(url) {
                sharedFolderItems.append(url)
            } else {
                allowed.append(url)
            }
        }
        if !sharedFolderItems.isEmpty {
            // Plain user-level trash; if the user may not move it, it stays (root is never used here).
            result.merge(await moveToTrash(sharedFolderItems, knownSizes: knownSizes, progress: progress))
        }
        guard !allowed.isEmpty else { return result }
        for url in allowed { progress?(RemovalStep(url: url, bytes: 0, done: false)) }

        let trash = SafetyGuard.home.appendingPathComponent(".Trash").path
        var commands: [String] = []
        for url in allowed {
            let dest = shellQuote("\(trash)/\(url.lastPathComponent) \(UUID().uuidString.prefix(8))")
            let source = shellQuote(url.path)
            commands.append("{ [ ! -e \(dest) ] && [ ! -L \(dest) ] && /bin/mv -n -- \(source) \(dest); }")
        }
        // Each item is checked on disk afterwards, so one failed move must not fail the whole batch.
        let shell = commands.joined(separator: " ; ") + " ; exit 0"
        let script = "do shell script \(appleScriptString(shell)) with administrator privileges"

        let sizes = allowed.map { knownSizes[$0] ?? FileSizer.allocatedSize(of: $0) }
        // osascript in a child process: shows the standard password prompt without blocking the UI.
        let ok: (Bool, String?) = await Task.detached(priority: .userInitiated) {
            runOsascript(script)
        }.value
        for (url, size) in zip(allowed, sizes) {
            let gone = !FileManager.default.fileExists(atPath: url.path) && !isSymlink(url)
            if ok.0, gone {
                result.removed.append(url)
                result.freedBytes += size
                progress?(RemovalStep(url: url, bytes: size, done: true))
            } else {
                result.failed.append(RemovalFailure(url: url, reason: ok.1 ?? "Не удалось переместить"))
                progress?(RemovalStep(url: url, bytes: 0, done: true))
            }
        }
        return result
    }

    /// True when any folder on the way to `url` (below /) is world-writable or sticky,
    /// i.e. other users or processes can rename things there.
    static func isInSharedWritableFolder(_ url: URL) -> Bool {
        var dir = url.deletingLastPathComponent().standardizedFileURL
        while dir.path != "/" && !dir.path.isEmpty {
            var st = stat()
            if lstat(dir.path, &st) == 0 {
                let mode = st.st_mode
                if (mode & S_IFMT) == S_IFLNK { return true }
                if mode & S_IWOTH != 0 || mode & S_ISVTX != 0 { return true }
            }
            dir = dir.deletingLastPathComponent()
        }
        return false
    }

    /// Permanently deletes items. Only allowed for items already inside a Trash folder
    /// (this is how "Empty Trash" works). Anything else is refused.
    public static func deletePermanentlyFromTrash(_ urls: [URL], knownSizes: [URL: Int64] = [:],
                                                 progress: RemovalProgressHandler? = nil) async -> RemovalResult {
        await Task.detached(priority: .userInitiated) {
            var result = RemovalResult()
            for url in dedupeNested(urls) {
                progress?(RemovalStep(url: url, bytes: 0, done: false))
                var freed: Int64 = 0
                defer { progress?(RemovalStep(url: url, bytes: freed, done: true)) }
                guard SafetyGuard.isInsideTrash(url), !SafetyGuard.isProtected(url) else {
                    result.failed.append(RemovalFailure(url: url, reason: "Безвозвратное удаление разрешено только в Корзине"))
                    continue
                }
                let size = knownSizes[url] ?? FileSizer.allocatedSize(of: url)
                do {
                    try FileManager.default.removeItem(at: url)
                    result.removed.append(url)
                    result.freedBytes += size
                    freed = size
                } catch {
                    result.failed.append(RemovalFailure(url: url, reason: error.localizedDescription))
                }
            }
            return result
        }.value
    }

    /// Drops URLs that are inside another URL in the same list, so a folder and its child
    /// are not removed (and counted) twice.
    public static func dedupeNested(_ urls: [URL]) -> [URL] {
        // Keeps the caller's order (uninstall relies on "bundle last"). O(n · depth).
        var seen = Set<String>()
        let unique = urls.map { $0.standardizedFileURL }.filter { seen.insert($0.path).inserted }
        return unique.filter { url in
            var parent = (url.path as NSString).deletingLastPathComponent
            while parent.count > 1 {
                if seen.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }
    }

    private static func runOsascript(_ script: String) -> (Bool, String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return (false, error.localizedDescription) }
        process.waitUntilExit()
        if process.terminationStatus == 0 { return (true, nil) }
        let message = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (false, message.contains("-128") ? "Отменено пользователем" : "Нет прав администратора")
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
