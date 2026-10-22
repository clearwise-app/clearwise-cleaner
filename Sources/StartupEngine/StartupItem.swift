import Foundation

/// One thing macOS starts on its own: a launchd job from a plist folder, or a login / background item
/// that an app registered with Background Task Management (SMAppService, «Объекты входа»).
public struct StartupItem: Identifiable, Sendable, Equatable {
    public enum Source: String, Sendable, CaseIterable {
        /// `~/Library/LaunchAgents` — runs as the user, managed without a password.
        case userAgent
        /// `/Library/LaunchAgents` — runs as every user; the plist is root-owned.
        case globalAgent
        /// `/Library/LaunchDaemons` — runs as root; every change needs the administrator password.
        case daemon
        /// Registered by an app through SMAppService / login items: only System Settings may toggle it.
        case backgroundTask
    }

    /// How the screen groups items.
    public enum Group: Int, Sendable, CaseIterable, Comparable {
        case loginItems, agents, daemons
        public static func < (l: Group, r: Group) -> Bool { l.rawValue < r.rawValue }
    }

    public enum State: Sendable, Equatable {
        case running(pid: Int)
        /// Loaded into launchd, waiting for its trigger (interval, socket, path…).
        case loaded
        case notLoaded
        /// launchd could not be asked (BTM-only items, unreadable output).
        case unknown
    }

    /// `path` for plist items (one plist = one job), `btm:<identifier>` otherwise.
    public let id: String
    public let source: Source
    public let group: Group
    /// launchd `Label`, or the BTM identifier's bundle ID for background items.
    public let label: String
    public let plist: URL?
    /// Program / ProgramArguments[0] (or BTM «Executable Path»).
    public let program: String?
    public let arguments: [String]
    public let runAtLoad: Bool
    public let keepAlive: Bool
    /// Seconds between runs (`StartInterval`), if any.
    public let interval: Int?
    /// The plist exists but launchd cannot use it (no Label, unreadable).
    public let isMalformed: Bool
    /// The program path is absolute and the file is gone (the junk scan offers these as «Неработающие агенты»).
    public let programMissing: Bool

    public var ownerName: String?
    public var ownerBundleID: String?
    public var ownerAppURL: URL?
    /// «Developer Name» from BTM (e.g. "Google LLC").
    public var developerName: String?
    public var signer: Signer

    public var state: State
    /// `launchctl disable` override: launchd will not load it.
    public var disabledByOverride: Bool
    /// Turned off in System Settings → Login Items (BTM disposition).
    public var disabledInSettings: Bool
    /// The plist itself says `Disabled = true`.
    public let disabledInPlist: Bool

    /// Part of macOS (com.apple.* label or bundle): hidden by default, never acted on.
    public let isApple: Bool

    public init(id: String, source: Source, group: Group, label: String, plist: URL?, program: String?,
                arguments: [String] = [], runAtLoad: Bool = false, keepAlive: Bool = false, interval: Int? = nil,
                isMalformed: Bool = false, programMissing: Bool = false, ownerName: String? = nil,
                ownerBundleID: String? = nil, ownerAppURL: URL? = nil, developerName: String? = nil,
                signer: Signer = .unknown, state: State = .unknown, disabledByOverride: Bool = false,
                disabledInSettings: Bool = false, disabledInPlist: Bool = false, isApple: Bool = false) {
        self.id = id
        self.source = source
        self.group = group
        self.label = label
        self.plist = plist
        self.program = program
        self.arguments = arguments
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.interval = interval
        self.isMalformed = isMalformed
        self.programMissing = programMissing
        self.ownerName = ownerName
        self.ownerBundleID = ownerBundleID
        self.ownerAppURL = ownerAppURL
        self.developerName = developerName
        self.signer = signer
        self.state = state
        self.disabledByOverride = disabledByOverride
        self.disabledInSettings = disabledInSettings
        self.disabledInPlist = disabledInPlist
        self.isApple = isApple
    }

    /// Will start on its own (at login, boot, on a timer…) unless something turned it off.
    public var isEnabled: Bool { !disabledByOverride && !disabledInSettings && !disabledInPlist && !isMalformed }

    public var isRunning: Bool { if case .running = state { true } else { false } }

    /// Owner app name, then BTM's name, then the label.
    public var displayName: String { ownerName ?? developerName ?? label }

    /// The launchd domain this job lives in (`gui/<uid>` for agents, `system` for daemons).
    public func domain(uid: uid_t) -> String? {
        switch source {
        case .userAgent, .globalAgent: "gui/\(uid)"
        case .daemon: "system"
        case .backgroundTask: nil
        }
    }
}

/// Who signed the program launchd starts.
public enum Signer: Sendable, Equatable {
    case apple
    case appStore
    /// Developer ID: the certificate's name ("Google LLC") and Team ID.
    case developerID(name: String?, team: String?)
    /// Signed, but not by Apple, the App Store or a Developer ID (development certificates…).
    case other(name: String?, team: String?)
    case adHoc
    case unsigned
    /// The signature does not match the program (modified after signing).
    case invalid
    /// The program is missing, not a path, or was not checked.
    case unknown

    public var team: String? {
        switch self {
        case .developerID(_, let t), .other(_, let t): t
        default: nil
        }
    }
}

enum AppleIDs {
    /// Apple-owned identifiers, including legacy ones that do not start with com.apple
    /// (same list as the uninstaller's `NameRules.appleIDPrefixes`).
    static let prefixes = ["com.apple.", "is.workflow.", "systemgroup.com.apple.", "apple."]

    static func isApple(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower == "com.apple" || prefixes.contains { lower.hasPrefix($0) }
    }
}
