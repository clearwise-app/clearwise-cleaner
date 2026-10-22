import Foundation

/// Runs a shell command as root after the standard macOS administrator password prompt
/// (`osascript … with administrator privileges`). The one place the app asks for that password.
/// Callers build the command with `quote` and must keep it short and checked: root runs it verbatim.
public enum AdminShell {
    /// Runs `shell` as root. Returns success, or a Russian reason («Отменено пользователем»…).
    /// Blocks until the prompt is answered: call it off the main thread.
    public static func run(_ shell: String) -> (ok: Bool, error: String?) {
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
        return (false, message.contains("-128") ? "Отменено пользователем" : "Нет прав администратора")
    }

    /// Single-quoted for /bin/sh.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
