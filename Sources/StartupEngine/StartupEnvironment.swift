import Foundation
import AppKit

/// Everything the startup scanner and actions touch outside memory, so tests can swap it for fixtures.
public struct StartupEnvironment: Sendable {
    public struct Output: Sendable, Equatable {
        public var status: Int32
        public var text: String
        public init(status: Int32, text: String) {
            self.status = status
            self.text = text
        }
    }

    public var uid: uid_t
    public var userAgents: URL
    public var globalAgents: URL
    public var daemons: URL
    /// Where apps live: their bundles may carry SMAppService agents, daemons and login items.
    public var appFolders: [URL]
    /// Runs a tool (absolute path) with arguments; nil when it could not start or ran past the timeout.
    public var run: @Sendable (_ tool: String, _ arguments: [String], _ timeout: TimeInterval) -> Output?
    /// Where Launch Services finds the app with this bundle ID.
    public var appForBundleID: @Sendable (String) -> URL?
    public var signer: @Sendable (String) -> Signer

    public init(uid: uid_t, userAgents: URL, globalAgents: URL, daemons: URL, appFolders: [URL] = [],
                run: @escaping @Sendable (String, [String], TimeInterval) -> Output?,
                appForBundleID: @escaping @Sendable (String) -> URL?,
                signer: @escaping @Sendable (String) -> Signer) {
        self.uid = uid
        self.userAgents = userAgents
        self.globalAgents = globalAgents
        self.daemons = daemons
        self.appFolders = appFolders
        self.run = run
        self.appForBundleID = appForBundleID
        self.signer = signer
    }

    public static var live: StartupEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return StartupEnvironment(
            uid: getuid(),
            userAgents: home.appendingPathComponent("Library/LaunchAgents"),
            globalAgents: URL(fileURLWithPath: "/Library/LaunchAgents"),
            daemons: URL(fileURLWithPath: "/Library/LaunchDaemons"),
            appFolders: [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Utilities"),
                         home.appendingPathComponent("Applications")],
            run: ProcessRunner.run,
            appForBundleID: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
            signer: { CodeSignature.signer(ofPath: $0) })
    }

    func folder(for source: StartupItem.Source) -> URL? {
        switch source {
        case .userAgent: userAgents
        case .globalAgent: globalAgents
        case .daemon: daemons
        case .backgroundTask: nil
        }
    }
}

enum ProcessRunner {
    @Sendable static func run(_ tool: String, _ arguments: [String], _ timeout: TimeInterval) -> StartupEnvironment.Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Read while the tool runs: a full pipe would block it forever.
        let box = DataBox()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        if reader.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return StartupEnvironment.Output(status: process.terminationStatus, text: String(decoding: box.data, as: UTF8.self))
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }
}
