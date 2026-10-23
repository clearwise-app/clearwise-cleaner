import Foundation

/// Runs a system tool that only reports (`diskutil info`, `tmutil listlocalsnapshots`, `system_profiler`).
enum Command {
    /// Standard output, or nil when the tool failed, is missing or did not finish within `timeout` seconds
    /// (a dying disk can make `diskutil` hang; the check must still return).
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }

        // Read while the tool runs: a full pipe buffer would block it forever.
        var data = Data()
        let reader = DispatchQueue(label: "HealthEngine.Command.read")
        let readDone = DispatchSemaphore(value: 0)
        reader.async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        // A helper the tool spawned may still hold the pipe: a read that never ends must not hang the check.
        guard readDone.wait(timeout: .now() + 2) == .success else { return nil }
        return process.terminationStatus == 0 ? data : nil
    }
}
