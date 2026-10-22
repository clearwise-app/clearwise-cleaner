import Foundation

// MARK: - Files

/// A single file or folder found by any scanner.
public struct FileItem: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    /// Allocated size on disk in bytes (recursive for folders).
    public let size: Int64
    public let isDirectory: Bool
    /// Last time the user opened it (kMDItemLastUsedDate), falling back to access date.
    public let lastUsed: Date?
    public let modified: Date?

    public init(url: URL, size: Int64, isDirectory: Bool, lastUsed: Date? = nil, modified: Date? = nil) {
        self.url = url
        self.size = size
        self.isDirectory = isDirectory
        self.lastUsed = lastUsed
        self.modified = modified
    }

    public var name: String { url.lastPathComponent }
}

/// How careful the user should be before removing something.
public enum RiskLevel: Int, Comparable, Sendable {
    /// Regenerated automatically (caches, logs).
    case safe
    /// Usually fine, but worth a look: user data may be involved, or recreating it costs time.
    case review
    /// Could lose work or settings.
    case caution

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - Junk

public struct JunkCategory: Identifiable, Sendable {
    /// Stable id, e.g. "user-caches", "xcode-derived-data".
    public let id: String
    /// User-facing title in Russian, e.g. "Кэш приложений".
    public let title: String
    /// One-sentence explanation in Russian of what it is and why it is safe/unsafe to remove.
    public let detail: String
    /// SF Symbol name.
    public let symbol: String
    public let risk: RiskLevel
    /// The gentlest cleanup mode that ticks the whole category after a scan; nil = no mode ticks it as a whole.
    public let mode: CleanupMode?
    /// Items ticked from a mode of their own, overriding `mode` (old Xcode archives, older iPhone backups, Docker).
    public var itemModes: [URL: CleanupMode]
    /// Items no mode ever ticks (the newest backup of each device).
    public var neverAuto: Set<URL>
    public var items: [FileItem]

    /// - Parameter mode: nil = by risk: `.safe` categories are ticked by every mode, the rest by none.
    public init(id: String, title: String, detail: String, symbol: String, risk: RiskLevel,
                mode: CleanupMode? = nil, itemModes: [URL: CleanupMode] = [:], neverAuto: Set<URL> = [],
                items: [FileItem]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.risk = risk
        self.mode = mode ?? (risk == .safe ? .gentle : nil)
        self.itemModes = itemModes
        self.neverAuto = neverAuto
        self.items = items
    }

    /// Ticked by the gentle mode (what a scan ticked before modes existed).
    public var isSelectedByDefault: Bool { mode == .gentle }

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    /// What `cleanup` ticks in this category.
    public func autoSelected(in cleanup: CleanupMode) -> [FileItem] {
        items.filter { item in
            guard !neverAuto.contains(item.url), let m = itemModes[item.url] ?? mode else { return false }
            return m <= cleanup
        }
    }

    /// The gentlest mode that ticks anything here, for the category's label.
    public var gentlestMode: CleanupMode? {
        (items.compactMap { neverAuto.contains($0.url) ? nil : (itemModes[$0.url] ?? mode) }).min()
    }
}

/// How far a cleanup goes: which categories a scan ticks by itself. Every tick can still be changed by hand,
/// and no mode ever ticks the user's own files, the Trash, Docker volumes or a device's newest backup.
public enum CleanupMode: Int, CaseIterable, Comparable, Sendable, Codable {
    /// What the system or an app recreates by itself.
    case gentle
    /// Also what is downloaded or rebuilt again at the cost of time: developer caches, Docker build cache.
    case enhanced
    /// Also what you are unlikely to need: unused Docker images, old installers and archives, older backups.
    case maximum

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .gentle: "Бережная"
        case .enhanced: "Усиленная"
        case .maximum: "Максимальная"
        }
    }

    public var summary: String {
        switch self {
        case .gentle: "Только то, что программы и macOS создадут заново сами."
        case .enhanced: "Плюс то, что скачается или пересоберётся заново: кэши разработчика, кэш сборки Docker."
        case .maximum: "Плюс то, что вряд ли понадобится: неиспользуемые образы Docker, старые установщики, архивы и копии."
        }
    }
}

// MARK: - Progress

public struct ScanProgress: Sendable {
    /// Short Russian label of what is happening, e.g. "Кэш браузеров".
    public var phase: String
    /// 0…1
    public var fraction: Double
    public var currentPath: String?

    public init(phase: String, fraction: Double, currentPath: String? = nil) {
        self.phase = phase
        self.fraction = fraction
        self.currentPath = currentPath
    }
}

public typealias ProgressHandler = @Sendable (ScanProgress) -> Void

// MARK: - Apps

public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let bundleID: String?
    public let version: String?
    /// Code-signing Team ID, used to match leftovers like group containers.
    public let teamID: String?
    /// Size of the .app bundle itself.
    public let size: Int64
    public let lastUsed: Date?
    /// Apple / system apps that must not be offered for removal.
    public let isSystemApp: Bool
    /// Installed from the Mac App Store (has _MASReceipt).
    public let isAppStore: Bool

    public init(url: URL, name: String, bundleID: String?, version: String?, teamID: String?,
                size: Int64, lastUsed: Date?, isSystemApp: Bool, isAppStore: Bool) {
        self.url = url
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.teamID = teamID
        self.size = size
        self.lastUsed = lastUsed
        self.isSystemApp = isSystemApp
        self.isAppStore = isAppStore
    }
}

public enum RemnantKind: String, CaseIterable, Sendable {
    case applicationSupport, caches, preferences, containers, groupContainers, savedState,
         logs, launchAgents, launchDaemons, privilegedHelpers, cookies, webData, httpStorages,
         crashReports, receipts, extensions, other

    public var title: String {
        switch self {
        case .applicationSupport: "Данные приложения"
        case .caches: "Кэш"
        case .preferences: "Настройки"
        case .containers: "Контейнеры"
        case .groupContainers: "Групповые контейнеры"
        case .savedState: "Сохранённое состояние"
        case .logs: "Логи"
        case .launchAgents: "Агенты запуска"
        case .launchDaemons: "Системные службы"
        case .privilegedHelpers: "Вспомогательные утилиты"
        case .cookies: "Cookies"
        case .webData: "Веб-данные"
        case .httpStorages: "HTTP-хранилища"
        case .crashReports: "Отчёты о сбоях"
        case .receipts: "Квитанции установщика"
        case .extensions: "Расширения и плагины"
        case .other: "Прочее"
        }
    }

    public var symbol: String {
        switch self {
        case .applicationSupport: "folder.fill"
        case .caches: "internaldrive.fill"
        case .preferences: "slider.horizontal.3"
        case .containers, .groupContainers: "shippingbox.fill"
        case .savedState: "clock.arrow.circlepath"
        case .logs: "doc.text.fill"
        case .launchAgents, .launchDaemons: "bolt.fill"
        case .privilegedHelpers: "wrench.and.screwdriver.fill"
        case .cookies, .webData, .httpStorages: "globe"
        case .crashReports: "exclamationmark.triangle.fill"
        case .receipts: "doc.plaintext.fill"
        case .extensions: "puzzlepiece.extension.fill"
        case .other: "questionmark.folder.fill"
        }
    }
}

public enum MatchConfidence: Int, Comparable, Sendable {
    /// Matched by name only (fuzzy). Not selected by default.
    case low
    /// Matched by name inside a vendor folder, or by Team ID.
    case medium
    /// Matched by exact bundle identifier.
    case high

    public static func < (lhs: MatchConfidence, rhs: MatchConfidence) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct AppRemnant: Identifiable, Hashable, Sendable {
    public var id: URL { item.url }
    public let item: FileItem
    public let kind: RemnantKind
    public let confidence: MatchConfidence
    /// Lives outside the user's home (e.g. /Library/LaunchDaemons) and needs admin rights.
    public let requiresAdmin: Bool

    public init(item: FileItem, kind: RemnantKind, confidence: MatchConfidence, requiresAdmin: Bool) {
        self.item = item
        self.kind = kind
        self.confidence = confidence
        self.requiresAdmin = requiresAdmin
    }
}

/// Leftovers of an app that is no longer installed.
public struct OrphanGroup: Identifiable, Hashable, Sendable {
    /// Usually the bundle identifier the leftovers belong to.
    public let id: String
    public let displayName: String
    public let remnants: [AppRemnant]

    public init(id: String, displayName: String, remnants: [AppRemnant]) {
        self.id = id
        self.displayName = displayName
        self.remnants = remnants
    }

    public var totalSize: Int64 { remnants.reduce(0) { $0 + $1.item.size } }
}

// MARK: - Space

/// Node of the disk space map (sunburst / treemap).
public final class DirectoryNode: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let url: URL
    public let size: Int64
    public let isDirectory: Bool
    public let children: [DirectoryNode]
    /// Synthetic "Прочее" bucket aggregating small siblings. Its `url` is the PARENT folder,
    /// so it must never be offered for removal or opened as if it were a real item.
    public let isAggregate: Bool

    public init(url: URL, size: Int64, isDirectory: Bool, children: [DirectoryNode], isAggregate: Bool = false) {
        self.url = url
        self.size = size
        self.isDirectory = isDirectory
        self.children = children
        self.isAggregate = isAggregate
    }

    public var name: String { isAggregate ? "Прочее" : url.lastPathComponent }
    /// True when the node is a real file/folder the user may act on (reveal, trash).
    public var isActionable: Bool { !isAggregate }
}

// MARK: - Removal

public struct RemovalFailure: Hashable, Sendable {
    public let url: URL
    public let reason: String
    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

public struct RemovalResult: Sendable {
    public var removed: [URL]
    public var failed: [RemovalFailure]
    public var freedBytes: Int64
    /// Where moved items landed in the Trash, so «удалять сразу навсегда» deletes exactly them and nothing else.
    public var inTrash: [URL] = []
    /// The items are gone for good, not waiting in the Trash.
    public var deletedPermanently = false
    /// Removed by a tool that frees the space at once, never through the Trash (Docker); part of `removed`.
    public var deletedForGood: [URL] = []
    /// Bytes of `deletedForGood`; part of `freedBytes`.
    public var freedForGood: Int64 = 0

    public init(removed: [URL] = [], failed: [RemovalFailure] = [], freedBytes: Int64 = 0) {
        self.removed = removed
        self.failed = failed
        self.freedBytes = freedBytes
    }

    public mutating func merge(_ other: RemovalResult) {
        removed += other.removed
        failed += other.failed
        freedBytes += other.freedBytes
        inTrash += other.inTrash
        deletedForGood += other.deletedForGood
        freedForGood += other.freedForGood
    }
}

/// Live progress of a removal, for the cleaning animation.
/// Sent with `done == false` right before an item is processed and with `done == true` after it
/// (`bytes` = space freed by that item, 0 if it failed).
public struct RemovalStep: Sendable {
    public let url: URL
    public let bytes: Int64
    public let done: Bool
    public init(url: URL, bytes: Int64, done: Bool) {
        self.url = url
        self.bytes = bytes
        self.done = done
    }
}

public typealias RemovalProgressHandler = @Sendable (RemovalStep) -> Void
