import Foundation

/// The single place where the app removes files.
/// Default behaviour is "move to Trash" so every action is undoable from Finder.
public enum FileRemover {
    /// Moves items to the user's Trash. Protected paths are refused and reported as failures.
    public static func moveToTrash(_ urls: [URL], knownSizes: [URL: Int64] = [:]) async -> RemovalResult {
        await Task.detached(priority: .userInitiated) {
            var result = RemovalResult()
            for url in dedupeNested(urls) {
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
                } catch {
                    result.failed.append(RemovalFailure(url: url, reason: error.localizedDescription))
                }
            }
            return result
        }.value
    }

    /// Moves root-owned items (e.g. /Library/LaunchDaemons/*.plist) to the user's Trash
    /// after asking for the administrator password once via the standard macOS prompt.
    public static func moveToTrashAsAdmin(_ urls: [URL], knownSizes: [URL: Int64] = [:]) async -> RemovalResult {
        var result = RemovalResult()
        var allowed: [URL] = []
        for url in dedupeNested(urls) {
            if let reason = SafetyGuard.refusalReason(for: url) {
                result.failed.append(RemovalFailure(url: url, reason: reason))
            } else {
                allowed.append(url)
            }
        }
        guard !allowed.isEmpty else { return result }

        let trash = SafetyGuard.home.appendingPathComponent(".Trash").path
        let stamp = Int(Date().timeIntervalSince1970)
        var commands: [String] = []
        for (i, url) in allowed.enumerated() {
            let dest = "\(trash)/\(url.lastPathComponent) \(stamp)-\(i)"
            commands.append("/bin/mv -f -- \(shellQuote(url.path)) \(shellQuote(dest))")
        }
        let shell = commands.joined(separator: " ; ")
        let script = "do shell script \(appleScriptString(shell)) with administrator privileges"

        let sizes = allowed.map { knownSizes[$0] ?? FileSizer.allocatedSize(of: $0) }
        let ok: (Bool, String?) = await MainActor.run {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error { return (false, error[NSAppleScript.errorMessage] as? String ?? "Отменено") }
            return (true, nil)
        }
        for (url, size) in zip(allowed, sizes) {
            if ok.0, !FileManager.default.fileExists(atPath: url.path) {
                result.removed.append(url)
                result.freedBytes += size
            } else {
                result.failed.append(RemovalFailure(url: url, reason: ok.1 ?? "Не удалось переместить"))
            }
        }
        return result
    }

    /// Permanently deletes items. Only allowed for items already inside a Trash folder
    /// (this is how "Empty Trash" works). Anything else is refused.
    public static func deletePermanentlyFromTrash(_ urls: [URL], knownSizes: [URL: Int64] = [:]) async -> RemovalResult {
        await Task.detached(priority: .userInitiated) {
            var result = RemovalResult()
            for url in dedupeNested(urls) {
                guard SafetyGuard.isInsideTrash(url) else {
                    result.failed.append(RemovalFailure(url: url, reason: "Безвозвратное удаление разрешено только в Корзине"))
                    continue
                }
                let size = knownSizes[url] ?? FileSizer.allocatedSize(of: url)
                do {
                    try FileManager.default.removeItem(at: url)
                    result.removed.append(url)
                    result.freedBytes += size
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
        // Keeps the caller's order (uninstall relies on "bundle last").
        var seen = Set<String>()
        let unique = urls.map { $0.standardizedFileURL }.filter { seen.insert($0.path).inserted }
        return unique.filter { url in
            !unique.contains { other in other != url && url.path.hasPrefix(other.path + "/") }
        }
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
