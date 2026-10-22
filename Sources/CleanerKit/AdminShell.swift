import Foundation

/// Runs a shell command as root after the standard macOS administrator password prompt
/// (`osascript … with administrator privileges`). The one place the app asks for that password.
/// Internal to CleanerKit: other modules get typed operations only (`FileRemover`, `LaunchdRootCommand`),
/// never a free-form root shell.
enum AdminShell {
    /// Runs `shell` as root. Returns success, or a localized reason («Отменено пользователем»…).
    /// Blocks until the prompt is answered: call it off the main thread.
    static func run(_ shell: String) -> (ok: Bool, error: String?) {
        let script = "do shell script \(appleScriptString(shell)) with administrator privileges"
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
        return (false, message.contains("-128") ? String(localized: "Отменено пользователем", bundle: .module)
                                                : String(localized: "Нет прав администратора", bundle: .module))
    }

    /// Single-quoted for /bin/sh.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// A launchd command for the system domain: with `FileRemover`'s admin moves and deletes, the only thing the app
/// runs as root. Built and quoted here; a label or plist that fails the checks never reaches the shell.
public enum LaunchdRootCommand: Sendable, Equatable {
    case disable(label: String)
    case enable(label: String)
    case bootout(label: String)
    /// A daemon plist directly in /Library/LaunchDaemons.
    case bootstrap(plist: URL)

    /// launchd labels are reverse-DNS-like; anything else is refused.
    public static func isValidLabel(_ label: String) -> Bool {
        label.count <= 200 && label.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    /// The shell line, or nil when the label or plist is refused.
    public var shellLine: String? {
        let launchctl = "/bin/launchctl"
        func labelled(_ verb: String, _ label: String) -> String? {
            Self.isValidLabel(label) ? "\(launchctl) \(verb) \(AdminShell.quote("system/" + label))" : nil
        }
        switch self {
        case .disable(let label): return labelled("disable", label)
        case .enable(let label): return labelled("enable", label)
        case .bootout(let label): return labelled("bootout", label)
        case .bootstrap(let plist):
            let url = plist.standardizedFileURL
            guard url.deletingLastPathComponent().path == "/Library/LaunchDaemons", url.pathExtension == "plist" else { return nil }
            return "\(launchctl) bootstrap system \(AdminShell.quote(url.path))"
        }
    }

    /// Runs `commands` as root after one password prompt; each runs even if one before it fails.
    /// Blocks until the prompt is answered: call it off the main thread.
    public static func run(_ commands: [LaunchdRootCommand]) -> (ok: Bool, error: String?) {
        let lines = commands.compactMap(\.shellLine)
        guard !lines.isEmpty else { return (true, nil) }
        return AdminShell.run(lines.joined(separator: " ; ") + " ; exit 0")
    }
}
