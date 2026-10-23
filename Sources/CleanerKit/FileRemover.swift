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
                    var landed: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
                    if let landed { result.inTrash.append(landed as URL) }
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
    /// `rootPrelude` runs as root first, in the same password prompt (e.g. `launchctl bootout system/<label>`);
    /// its result is ignored, the moves are checked on disk as always.
    public static func moveToTrashAsAdmin(_ urls: [URL], knownSizes: [URL: Int64] = [:], rootPrelude: [LaunchdRootCommand] = [],
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
        var destinations: [String] = []
        for url in allowed {
            let destPath = "\(trash)/\(url.lastPathComponent) \(UUID().uuidString.prefix(8))"
            destinations.append(destPath)
            let dest = shellQuote(destPath)
            let source = shellQuote(url.path)
            commands.append("{ [ ! -e \(dest) ] && [ ! -L \(dest) ] && /bin/mv -n -- \(source) \(dest); }")
        }
        // Each item is checked on disk afterwards, so one failed move must not fail the whole batch.
        let shell = (rootPrelude.compactMap(\.shellLine) + commands).joined(separator: " ; ") + " ; exit 0"

        let sizes = allowed.map { knownSizes[$0] ?? FileSizer.allocatedSize(of: $0) }
        // osascript in a child process: shows the standard password prompt without blocking the UI.
        let ok: (Bool, String?) = await Task.detached(priority: .userInitiated) {
            AdminShell.run(shell)
        }.value
        for (url, (size, destPath)) in zip(allowed, zip(sizes, destinations)) {
            let gone = !FileManager.default.fileExists(atPath: url.path) && !isSymlink(url)
            if ok.0, gone {
                if FileManager.default.fileExists(atPath: destPath) { result.inTrash.append(URL(fileURLWithPath: destPath)) }
                result.removed.append(url)
                result.freedBytes += size
                progress?(RemovalStep(url: url, bytes: size, done: true))
            } else {
                result.failed.append(RemovalFailure(url: url, reason: ok.1 ?? String(localized: "Не удалось переместить", bundle: .module)))
                progress?(RemovalStep(url: url, bytes: 0, done: true))
            }
        }
        return result
    }

    /// True when any folder on the way to `url` (below /) is world-writable or sticky,
    /// i.e. other users or processes can rename things there.
    static func isInSharedWritableFolder(_ url: URL) -> Bool {
        // The real folders: `standardizedFileURL` would turn /private/var/log into /var/log — a symlink —
        // and call every system log «shared», so root-owned logs could never be removed.
        var dir = url.deletingLastPathComponent().resolvingSymlinksInPath()
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
    /// Items of the user's own Trash that macOS refuses to the user (root-owned: App Store apps and daemons
    /// moved there by `moveToTrashAsAdmin`) are retried once as root, after the administrator password —
    /// like Finder's «Очистить Корзину».
    public static func deletePermanentlyFromTrash(_ urls: [URL], knownSizes: [URL: Int64] = [:],
                                                 progress: RemovalProgressHandler? = nil) async -> RemovalResult {
        let (firstPass, refused): (RemovalResult, [URL]) = await Task.detached(priority: .userInitiated) {
            var result = RemovalResult()
            var refused: [URL] = []
            for url in dedupeNested(urls) {
                progress?(RemovalStep(url: url, bytes: 0, done: false))
                var freed: Int64 = 0
                defer { progress?(RemovalStep(url: url, bytes: freed, done: true)) }
                guard SafetyGuard.isInsideTrash(url), !SafetyGuard.isProtected(url) else {
                    result.failed.append(RemovalFailure(url: url, reason: onlyInTrashReason))
                    continue
                }
                let size = knownSizes[url] ?? FileSizer.allocatedSize(of: url)
                do {
                    try FileManager.default.removeItem(at: url)
                    result.removed.append(url)
                    result.freedBytes += size
                    result.deletedForGood.append(url)
                    result.freedForGood += size
                    result.trashEmptiedBytes += size
                    freed = size
                } catch where isPermissionDenied(error) && isInUserTrash(url) {
                    refused.append(url)
                } catch {
                    result.failed.append(RemovalFailure(url: url, reason: error.localizedDescription))
                }
            }
            return (result, refused)
        }.value
        // A partly deleted root-owned folder is still there: one admin pass finishes it.
        guard !refused.isEmpty else { return firstPass }
        var result = firstPass
        result.merge(await deletePermanentlyFromTrashAsAdmin(refused, knownSizes: knownSizes, progress: progress))
        return result
    }

    /// Permanently deletes direct children of the user's own Trash as root, after one administrator password
    /// prompt. For items the user may not delete (see `deletePermanentlyFromTrash`); anything else is refused.
    ///
    /// Hardening: the shell enters the Trash with `cd -P` and checks it is the real, user-owned ~/.Trash
    /// before removing `./name` — a Trash swapped for a symlink cannot redirect root, and `rm` removes
    /// a symlinked item itself, never what it points to.
    public static func deletePermanentlyFromTrashAsAdmin(_ urls: [URL], knownSizes: [URL: Int64] = [:],
                                                        progress: RemovalProgressHandler? = nil) async -> RemovalResult {
        var result = RemovalResult()
        var allowed: [URL] = []
        for url in dedupeNested(urls) {
            if isInUserTrash(url), !SafetyGuard.isProtected(url) {
                allowed.append(url)
            } else {
                result.failed.append(RemovalFailure(url: url, reason: onlyInTrashReason))
                progress?(RemovalStep(url: url, bytes: 0, done: true))
            }
        }
        guard !allowed.isEmpty else { return result }
        for url in allowed { progress?(RemovalStep(url: url, bytes: 0, done: false)) }

        let trash = userTrash.path
        let removals = allowed.map { "/bin/rm -rf -- \(shellQuote("./" + $0.lastPathComponent))" }
        let shell = "cd -P -- \(shellQuote(trash)) && [ \"$(/bin/pwd -P)\" = \(shellQuote(trash)) ]"
            + " && [ \"$(/usr/bin/stat -f %u .)\" = \(getuid()) ] && { \(removals.joined(separator: " ; ")) ; } ; exit 0"

        let sizes = allowed.map { knownSizes[$0] ?? FileSizer.allocatedSize(of: $0) }
        let ok: (Bool, String?) = await Task.detached(priority: .userInitiated) {
            AdminShell.run(shell)
        }.value
        for (url, size) in zip(allowed, sizes) {
            let gone = !FileManager.default.fileExists(atPath: url.path) && !isSymlink(url)
            if ok.0, gone {
                result.removed.append(url)
                result.freedBytes += size
                result.deletedForGood.append(url)
                result.freedForGood += size
                result.trashEmptiedBytes += size
                progress?(RemovalStep(url: url, bytes: size, done: true))
            } else {
                result.failed.append(RemovalFailure(url: url, reason: ok.1 ?? String(localized: "Не удалось удалить", bundle: .module)))
                progress?(RemovalStep(url: url, bytes: 0, done: true))
            }
        }
        return result
    }

    /// True when the user cannot delete `url` themselves: it (or the folder it is) belongs to someone else,
    /// as items moved to the Trash by `moveToTrashAsAdmin` do. Lets callers keep such items in one unit
    /// (one password prompt).
    public static func needsAdminToDelete(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return st.st_uid != getuid()
    }

    /// ~/.Trash itself (a real folder owned by the user); the only place `deletePermanentlyFromTrashAsAdmin` acts.
    private static var userTrash: URL { SafetyGuard.home.appendingPathComponent(".Trash").standardizedFileURL }

    private static let onlyInTrashReason = String(localized: "Безвозвратное удаление разрешено только в Корзине", bundle: .module)

    private static func isInUserTrash(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              url.standardizedFileURL.deletingLastPathComponent().path == userTrash.path else { return false }
        var st = stat()
        return lstat(userTrash.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == getuid()
    }

    /// The item belongs to someone else (EACCES), so the administrator password helps. Not EPERM: that is macOS
    /// privacy protection or a locked file, which root cannot get past either, so no password is asked for.
    static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if let posix = ns.userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain {
            return posix.code == Int(EACCES)
        }
        if ns.domain == NSPOSIXErrorDomain { return ns.code == Int(EACCES) }
        return ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteNoPermissionError
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

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    private static func shellQuote(_ s: String) -> String { AdminShell.quote(s) }
}
