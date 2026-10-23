import Foundation
import CleanerKit

/// What Docker (Docker Desktop, OrbStack, Colima — whatever the `docker` command talks to) can give back.
/// It all lives inside the engine's own virtual disk, so it is never touched as files: sizes come from
/// `docker system df`, and Docker itself frees them with `docker … prune` — at once, not through the Trash.
/// Volumes are never pruned: databases live there.
public enum DockerCleanup {
    public enum Kind: String, CaseIterable, Sendable {
        case stoppedContainers = "stopped-containers"
        case danglingImages = "dangling-images"
        case unusedImages = "unused-images"
        case buildCache = "build-cache"

        /// Stands for the item in the junk list and the selection; never a file.
        public var url: URL { URL(string: "\(DockerCleanup.scheme):///\(rawValue)")! }

        public init?(url: URL) {
            guard url.scheme == DockerCleanup.scheme else { return nil }
            self.init(rawValue: url.lastPathComponent)
        }

        public var title: String {
            switch self {
            case .stoppedContainers: String(localized: "Остановленные контейнеры", bundle: .module)
            case .danglingImages: String(localized: "Образы без имени (<none>)", bundle: .module)
            case .unusedImages: String(localized: "Неиспользуемые образы", bundle: .module)
            case .buildCache: String(localized: "Кэш сборки", bundle: .module)
            }
        }

        var note: String {
            switch self {
            case .stoppedContainers: String(localized: "Docker · удалится и то, что записано внутри контейнеров", bundle: .module)
            case .danglingImages: String(localized: "Docker · остатки старых сборок", bundle: .module)
            case .unusedImages: String(localized: "Docker · скачаются заново при следующем запуске", bundle: .module)
            case .buildCache: String(localized: "Docker · следующая сборка пройдёт дольше", bundle: .module)
            }
        }

        public var mode: CleanupMode {
            switch self {
            case .buildCache, .danglingImages: .enhanced
            case .unusedImages, .stoppedContainers: .maximum
            }
        }

        /// The one command for each kind. `--force` skips Docker's own y/N prompt; nothing touches volumes.
        var arguments: [String] {
            switch self {
            case .stoppedContainers: ["container", "prune", "--force"]
            case .danglingImages: ["image", "prune", "--force"]
            case .unusedImages: ["image", "prune", "--all", "--force"]
            case .buildCache: ["builder", "prune", "--force"]
            }
        }
    }

    public static let scheme = "docker-cleanup"

    /// Containers first: images they used become unused and go with «Неиспользуемые образы» in the same run.
    static let order: [Kind] = [.stoppedContainers, .danglingImages, .unusedImages, .buildCache]

    // MARK: Reading

    struct Usage: Equatable {
        var images: Int64 = 0          // reclaimable by `image prune --all`
        var dangling: Int64 = 0        // part of `images`
        var containers: Int64 = 0
        var buildCache: Int64 = 0
    }

    /// `docker system df --format '{{json .}}'`: one JSON object per line, sizes as Docker prints them.
    static func parseSystemDF(_ text: String) -> Usage? {
        var usage = Usage()
        var sawAny = false
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = row["Type"] as? String else { continue }
            sawAny = true
            let reclaimable = (row["Reclaimable"] as? String).flatMap(parseSize) ?? 0
            switch type {
            case "Images": usage.images = reclaimable
            case "Containers": usage.containers = reclaimable
            case "Build Cache": usage.buildCache = reclaimable
            default: break   // «Local Volumes»: never offered
            }
        }
        return sawAny ? usage : nil
    }

    /// `docker images --filter dangling=true --format '{{json .}}'`: the sum of their sizes.
    static func parseDangling(_ text: String) -> Int64 {
        text.split(separator: "\n").reduce(0) { sum, line in
            guard let data = line.data(using: .utf8),
                  let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let size = (row["Size"] as? String).flatMap(parseSize) else { return sum }
            return sum + size
        }
    }

    /// «1.234GB (45%)», «512MB», «0B», «12.5kB» → bytes. Docker prints decimal units.
    static func parseSize(_ text: String) -> Int64? {
        let tokens = text.split(separator: " ").map(String.init)
        guard let head = tokens.first else { return nil }
        let number = head.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number), value.isFinite, value >= 0 else { return nil }
        var unit = head.dropFirst(number.count).uppercased()
        // «1.2 GB (50%)»: the unit as a token of its own, never the percentage.
        if unit.isEmpty, tokens.count > 1, !tokens[1].hasPrefix("(") { unit = tokens[1].uppercased() }
        let factor: Double = switch unit {
        case "B", "": 1
        case "KB": 1e3
        case "MB": 1e6
        case "GB": 1e9
        case "TB": 1e12
        default: -1
        }
        guard factor > 0, value * factor < Double(Int64.max) else { return nil }
        return Int64(value * factor)
    }

    /// `docker … prune` ends with «Total reclaimed space: 1.2GB».
    static func parseReclaimed(_ text: String) -> Int64? {
        guard let line = text.split(separator: "\n").last(where: { $0.contains("reclaimed space") }),
              let colon = line.lastIndex(of: ":") else { return nil }
        return parseSize(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    /// The category for the junk list, or why there is none.
    static func scan(_ tool: DockerTool) -> (category: JunkCategory?, status: DockerStatus) {
        guard let df = tool.run(["system", "df", "--format", "{{json .}}"], 30), df.status == 0,
              let usage = parseSystemDF(df.text) else { return (nil, .notRunning) }
        var dangling = Int64(0)
        if usage.images > 0, let out = tool.run(["images", "--filter", "dangling=true", "--format", "{{json .}}"], 30),
           out.status == 0 {
            dangling = min(parseDangling(out.text), usage.images)
        }
        let sizes: [Kind: Int64] = [
            .buildCache: usage.buildCache,
            .danglingImages: dangling,
            .unusedImages: usage.images - dangling,
            .stoppedContainers: usage.containers,
        ]
        let items = Kind.allCases.compactMap { kind -> FileItem? in
            guard let size = sizes[kind], size > 0 else { return nil }
            return FileItem(url: kind.url, size: size, isDirectory: false)
        }
        .sorted { $0.size > $1.size }
        guard !items.isEmpty else { return (nil, .ready) }
        let modes = Dictionary(uniqueKeysWithValues: items.compactMap { item in Kind(url: item.url).map { (item.url, $0.mode) } })
        let category = JunkCategory(
            id: JunkCategoryID.docker, title: "Docker",
            detail: String(localized: "Кэш сборки, образы и остановленные контейнеры. Их удаляет сам Docker — сразу, без Корзины; образы скачаются заново при следующем запуске. Тома с данными не трогаются.", bundle: .module),
            symbol: "shippingbox.circle.fill", risk: .review, itemModes: modes, items: items)
        return (category, .ready)
    }

    // MARK: Cleaning

    /// Why a kind could not be pruned.
    static let notFoundReason = String(localized: "Docker не найден", bundle: .module)
    static let noAnswerReason = String(localized: "Docker не ответил — проверьте, что он запущен", bundle: .module)

    /// Runs the prune command of each selected kind. Anything else is refused.
    static func clean(_ urls: [URL], tool: DockerTool?, progress: RemovalProgressHandler? = nil) -> RemovalResult {
        var result = RemovalResult()
        let kinds = Set(urls.compactMap(Kind.init(url:)))
        for url in urls where Kind(url: url) == nil {
            result.failed.append(RemovalFailure(url: url, reason: String(localized: "Не входит в категорию «Docker»", bundle: .module)))
        }
        for kind in order where kinds.contains(kind) {
            progress?(RemovalStep(url: kind.url, bytes: 0, done: false))
            var freed: Int64 = 0
            defer { progress?(RemovalStep(url: kind.url, bytes: freed, done: true)) }
            guard let tool else {
                result.failed.append(RemovalFailure(url: kind.url, reason: notFoundReason))
                continue
            }
            // Pruning a big cache can take minutes.
            guard let out = tool.run(kind.arguments, 600), out.status == 0 else {
                result.failed.append(RemovalFailure(url: kind.url, reason: noAnswerReason))
                continue
            }
            freed = parseReclaimed(out.text) ?? 0
            result.removed.append(kind.url)
            result.deletedForGood.append(kind.url)
            result.freedBytes += freed
            result.freedForGood += freed
        }
        return result
    }
}

/// Whether the junk scan could ask Docker.
public enum DockerStatus: Equatable, Sendable {
    /// No `docker` command on this Mac.
    case absent
    /// The command is there, but the engine did not answer (Docker Desktop or OrbStack is not running).
    case notRunning
    case ready
}

/// The `docker` command line tool. Only fixed install locations are used, never `$PATH`, and it always runs
/// as the user (it talks to the engine through the user's own socket).
struct DockerTool: Sendable {
    struct Output: Sendable {
        let status: Int32
        let text: String
    }

    let path: String
    var run: @Sendable (_ arguments: [String], _ timeout: TimeInterval) -> Output?

    static func locate(home: URL) -> DockerTool? {
        let candidates = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            home.appendingPathComponent(".docker/bin/docker").path,
            home.appendingPathComponent(".orbstack/bin/docker").path,
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            "/Applications/OrbStack.app/Contents/MacOS/xbin/docker",
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return DockerTool(path: path) { arguments, timeout in run(path, arguments, timeout) }
    }

    private static func run(_ tool: String, _ arguments: [String], _ timeout: TimeInterval) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        // An app started from the Finder has a bare PATH; credential helpers and the engine's CLI plugins
        // (buildx) are looked up there.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", environment["PATH"] ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ":")
        process.environment = environment
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
        return Output(status: process.terminationStatus, text: String(decoding: box.data, as: UTF8.self))
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }
}
