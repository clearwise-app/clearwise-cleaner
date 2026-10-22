import SwiftUI
import CleanerKit

// MARK: - Plan

/// What a module wants removed, described for the full-screen cleaning scene.
/// Stages are what the user sees («Кэш приложений», «Приложение»…); units are the actual engine calls,
/// run one after another so «Остановить» can stop between them. User-owned files go in chunks of
/// `chunkSize`, so stopping takes effect after the current chunk; root-owned items stay one unit (one prompt).
struct CleaningPlan {
    struct Stage {
        var title: String
        var symbol: String
        /// Shows this file's Finder icon instead of the symbol (apps).
        var iconURL: URL? = nil
        var items: [(url: URL, size: Int64)]
        /// Items behind the administrator prompt: the status says «Ожидание пароля…» while they are pending.
        var adminURLs: Set<URL> = []
    }

    struct Unit {
        /// Stage shown as active as soon as the unit starts (e.g. «Завершение приложения»).
        var activates: Int?
        /// Stage the unit belongs to (the last one added before it): the driver flushes progress when it changes.
        var stage: Int?
        var run: @MainActor (_ progress: @escaping RemovalProgressHandler) async -> RemovalResult
    }

    /// Items per unit for user-owned files: big enough that the main thread isn't woken per file,
    /// small enough that «Остановить» reacts within a moment.
    static let chunkSize = 25

    var title: String
    var symbol: String
    var tint: ModuleTint
    /// Status line prefix for the current stage: «Сейчас — Xcode: DerivedData», «Удаляем — Spotify».
    var activity: String
    private(set) var stages: [Stage] = []
    private(set) var units: [Unit] = []

    init(title: String, module: AppModule, tint: ModuleTint? = nil) {
        self.title = title
        self.symbol = module.symbol
        self.tint = tint ?? module.tint
        self.activity = module == .uninstaller ? "Удаляем" : "Сейчас"
    }

    @discardableResult
    mutating func addStage(_ title: String, symbol: String, iconURL: URL? = nil,
                           items: [(url: URL, size: Int64)], admin: Set<URL> = []) -> Int {
        stages.append(Stage(title: title, symbol: symbol, iconURL: iconURL, items: items, adminURLs: admin))
        return stages.count - 1
    }

    mutating func addUnit(activating stage: Int? = nil,
                          _ run: @escaping @MainActor (_ progress: @escaping RemovalProgressHandler) async -> RemovalResult) {
        units.append(Unit(activates: stage, stage: stage ?? stages.indices.last, run: run))
    }

    /// Splits `elements` into units of about `size`; `run` gets one chunk per engine call.
    /// Callers dedupe nested URLs up front, so chunking never changes what an engine call drops.
    mutating func addChunks<T>(_ elements: [T], size: Int = CleaningPlan.chunkSize,
                               _ run: @escaping @MainActor ([T], _ progress: @escaping RemovalProgressHandler) async -> RemovalResult) {
        let n = max(1, size)
        for start in stride(from: 0, to: elements.count, by: n) {
            let chunk = Array(elements[start..<min(start + n, elements.count)])
            addUnit { progress in await run(chunk, progress) }
        }
    }

    /// One engine call per element, grouped into units of about `chunkSize`: a stop request takes effect
    /// after the current chunk. Results are exactly those of calling `run` per element.
    mutating func addEach<T>(_ elements: [T],
                             _ run: @escaping @MainActor (T, _ progress: @escaping RemovalProgressHandler) async -> RemovalResult) {
        addChunks(elements) { chunk, progress in
            var total = RemovalResult()
            for e in chunk { total.merge(await run(e, progress)) }
            return total
        }
    }

    /// The common case: plain files moved to the Trash, one `FileRemover` call per chunk.
    mutating func addTrashUnits(_ urls: [URL], knownSizes: [URL: Int64]) {
        addChunks(urls) { chunk, progress in
            await FileRemover.moveToTrash(chunk, knownSizes: knownSizes, progress: progress)
        }
    }

    /// Runs `other` after this plan, in one scene (Smart Care joins the junk, leftovers and old-files plans).
    mutating func append(_ other: CleaningPlan) {
        let offset = stages.count
        stages += other.stages
        units += other.units.map { unit in
            var u = unit
            u.activates = u.activates.map { $0 + offset }
            u.stage = u.stage.map { $0 + offset }
            return u
        }
    }

    var isEmpty: Bool { units.isEmpty }
}

/// `FileRemover` drops a URL nested inside another one of the same call. Splitting a call into
/// one-item units must not change that, so plans dedupe up front. Sizes are keyed by both spellings.
enum CleaningPrep {
    static func dedupe(_ urls: [URL]) -> [URL] { FileRemover.dedupeNested(urls) }

    static func sizes(_ pairs: [(URL, Int64)]) -> [URL: Int64] {
        var out: [URL: Int64] = [:]
        for (url, size) in pairs {
            if out[url] == nil { out[url] = size }
            let std = url.standardizedFileURL
            if out[std] == nil { out[std] = size }
        }
        return out
    }
}

// MARK: - Session

struct CleaningStage: Identifiable {
    enum State: Equatable { case waiting, active, done }

    let id: Int
    let title: String
    let symbol: String
    let iconURL: URL?
    let totalBytes: Int64
    let itemCount: Int
    var processedBytes: Int64 = 0
    var freedBytes: Int64 = 0
    var doneItems = 0
    var state: State = .waiting

    var fraction: Double {
        if state == .done { return 1 }
        if totalBytes > 0 { return min(1, Double(processedBytes) / Double(totalBytes)) }
        return itemCount > 0 ? min(1, Double(doneItems) / Double(itemCount)) : 0
    }
}

/// Live state of one cleanup, shown by `CleaningOverlay`. Fed by the engines' `RemovalStep`s.
@MainActor @Observable
final class CleaningSession {
    let title: String
    let symbol: String
    let tint: ModuleTint
    /// «Сейчас» / «Удаляем»: prefix of the current-stage line.
    let activity: String
    private(set) var stages: [CleaningStage]
    private(set) var currentStageID: Int?
    private(set) var currentURL: URL?
    /// `moveToTrashAsAdmin` is waiting for the password prompt.
    private(set) var awaitingAdmin = false
    private(set) var freedBytes: Int64 = 0
    private(set) var processedBytes: Int64 = 0
    private(set) var processedItems = 0
    let totalBytes: Int64
    let totalItems: Int

    /// The user pressed «Остановить»; the driver stops before the next unit (chunk).
    private(set) var cancelRequested = false
    /// More than the current unit is left, so stopping would actually skip something.
    var canCancel = false
    private(set) var finished = false
    /// Finished early because of «Остановить».
    private(set) var stopped = false

    let startedAt = Date()
    private(set) var finishedAt: Date?

    /// Snapshots: render the time-based animation at this many seconds after the start.
    var frozenTime: Double?

    @ObservationIgnored private var stageOf: [String: Int] = [:]
    @ObservationIgnored private var sizeOf: [String: Int64] = [:]
    @ObservationIgnored private var adminKeys: Set<String> = []
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var doneKeys: Set<String> = []
    /// Item order, for the snapshot driver.
    @ObservationIgnored private var orderedItems: [(key: String, url: URL)] = []

    init(title: String, symbol: String, tint: ModuleTint, activity: String = "Сейчас", stages plan: [CleaningPlan.Stage]) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.activity = activity
        var built: [CleaningStage] = []
        var bytes: Int64 = 0
        var count = 0
        for (i, s) in plan.enumerated() {
            var stageBytes: Int64 = 0
            var stageCount = 0
            for item in s.items {
                let key = Self.key(item.url)
                guard stageOf[key] == nil else { continue }
                stageOf[key] = i
                sizeOf[key] = max(0, item.size)
                orderedItems.append((key, item.url))
                stageBytes += max(0, item.size)
                stageCount += 1
            }
            for url in s.adminURLs { adminKeys.insert(Self.key(url)) }
            built.append(CleaningStage(id: i, title: s.title, symbol: s.symbol, iconURL: s.iconURL,
                                       totalBytes: stageBytes, itemCount: stageCount))
            bytes += stageBytes
            count += stageCount
        }
        stages = built
        totalBytes = bytes
        totalItems = count
    }

    convenience init(plan: CleaningPlan) {
        self.init(title: plan.title, symbol: plan.symbol, tint: plan.tint, activity: plan.activity, stages: plan.stages)
    }

    nonisolated static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    // MARK: Derived

    /// 0…1 for the ring: bytes processed (freed or refused) over the total, items when sizes are unknown.
    var fraction: Double {
        if finished && !stopped { return 1 }
        if totalBytes > 0 { return min(1, Double(processedBytes) / Double(totalBytes)) }
        return totalItems > 0 ? min(1, Double(processedItems) / Double(totalItems)) : (finished ? 1 : 0)
    }

    var currentStage: CleaningStage? { currentStageID.map { stages[$0] } }
    var doneStages: Int { stages.filter { $0.state == .done }.count }

    // MARK: Updates

    func requestCancel() {
        guard !finished else { return }
        cancelRequested = true
    }

    func activate(_ stageID: Int) {
        guard stages.indices.contains(stageID) else { return }
        if currentStageID != stageID {
            // A stage without items (quitting the app) is over once anything else starts.
            if let previous = currentStageID, stages[previous].itemCount == 0 { stages[previous].state = .done }
            if let previous = currentStageID, stages[previous].state == .active { stages[previous].state = .waiting }
            currentStageID = stageID
        }
        if stages[stageID].state != .done { stages[stageID].state = .active }
    }

    func apply(_ steps: [RemovalStep]) {
        for step in steps { apply(step) }
    }

    func apply(_ step: RemovalStep) {
        guard !finished else { return }
        let key = Self.key(step.url)
        if !step.done {
            inFlight.insert(key)
            currentURL = step.url
            if let s = stageOf[key] { activate(s) }
        } else {
            inFlight.remove(key)
            guard doneKeys.insert(key).inserted else { return }
            processedItems += 1
            freedBytes += max(0, step.bytes)
            processedBytes += sizeOf[key] ?? max(0, step.bytes)
            if let s = stageOf[key] {
                stages[s].doneItems += 1
                stages[s].freedBytes += max(0, step.bytes)
                stages[s].processedBytes += sizeOf[key] ?? max(0, step.bytes)
                if stages[s].doneItems >= stages[s].itemCount {
                    stages[s].state = .done
                } else if currentStageID == s {
                    stages[s].state = .active
                }
            }
        }
        // Several items "started" at once only happens while the admin prompt is up.
        awaitingAdmin = inFlight.count > 1 || !inFlight.isDisjoint(with: adminKeys)
    }

    func finish() {
        stopped = cancelRequested && processedItems < totalItems
        if !stopped {
            for i in stages.indices { stages[i].state = .done }
        } else {
            for i in stages.indices where stages[i].state == .active { stages[i].state = .waiting }
        }
        currentStageID = nil
        currentURL = nil
        awaitingAdmin = false
        inFlight = []
        canCancel = false
        finishedAt = Date()
        finished = true
    }

    /// Seconds between the start and the finish, for the flourish (frozen snapshots use `frozenTime`).
    var finishElapsed: Double? { finishedAt.map { $0.timeIntervalSince(startedAt) } }

    // MARK: Snapshot driver

    /// Fake progress for snapshots: processes items in order until `fraction` of the bytes is done,
    /// then leaves the next item in flight. Never touches the disk.
    func simulate(to fraction: Double, failingEvery: Int = 0) {
        let target = Int64(Double(totalBytes) * fraction)
        let targetItems = Int(Double(totalItems) * fraction)
        var n = 0
        for (key, url) in orderedItems {
            let reached = totalBytes > 0 ? processedBytes >= target : processedItems >= targetItems
            if reached {
                apply(RemovalStep(url: url, bytes: 0, done: false))
                return
            }
            n += 1
            apply(RemovalStep(url: url, bytes: 0, done: false))
            let failed = failingEvery > 0 && n % failingEvery == 0
            apply(RemovalStep(url: url, bytes: failed ? 0 : (sizeOf[key] ?? 0), done: true))
        }
    }

    /// Snapshot of the admin prompt: every item of the stage is "started" and none is done yet.
    func simulateAdminWait(stage: Int) {
        for (key, url) in orderedItems where stageOf[key] == stage {
            apply(RemovalStep(url: url, bytes: 0, done: false))
        }
    }

    func simulateFinish(at time: Double) {
        finish()
        finishedAt = startedAt.addingTimeInterval(time)
    }
}

// MARK: - Relay

/// Collects engine steps from any thread and hands them to the session on the main thread,
/// at most ~30 times a second. Nothing is dropped: counts must add up — which is why this is not
/// `LatestValueRelay` (that one keeps only the newest value, right for scan progress, wrong for steps).
final class CleaningStepRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [RemovalStep] = []
    private var scheduled = false
    private var lastFlush: TimeInterval = 0
    private let interval: TimeInterval = 1.0 / 30.0
    private let session: CleaningSession

    init(_ session: CleaningSession) { self.session = session }

    var handler: RemovalProgressHandler {
        { [self] step in push(step) }
    }

    private func push(_ step: RemovalStep) {
        lock.lock()
        pending.append(step)
        let schedule = !scheduled
        scheduled = true
        let delay = max(0, lastFlush + interval - ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            MainActor.assumeIsolated { flush() }
        }
    }

    @MainActor func flush() {
        lock.lock()
        let steps = pending
        pending = []
        scheduled = false
        lastFlush = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        if !steps.isEmpty { session.apply(steps) }
    }
}

// MARK: - Driver

extension AppModel {
    /// Shows the cleaning scene, runs the plan unit by unit and returns the merged result.
    /// The caller applies the result (phase `.done`) right after this returns, without suspending;
    /// the scene then fades into the module's completion screen.
    func runCleaning(_ plan: CleaningPlan) async -> RemovalResult {
        let session = CleaningSession(plan: plan)
        withAnimation(.easeOut(duration: 0.45)) { cleaning = session }
        let relay = CleaningStepRelay(session)
        var total = RemovalResult()
        // Let the scene settle before anything moves (and before a possible admin prompt).
        try? await Task.sleep(for: .milliseconds(350))
        var stage: Int?
        for (i, unit) in plan.units.enumerated() {
            if session.cancelRequested { break }
            // Within a stage the relay alone paces updates (≤30/s); a finished stage lands at once.
            if i > 0, unit.stage != stage { relay.flush() }
            stage = unit.stage
            session.canCancel = i < plan.units.count - 1
            if let s = unit.activates { session.activate(s) }
            total.merge(await unit.run(relay.handler))
        }
        // «Удалить навсегда, минуя Корзину»: exactly what this cleanup put in the Trash goes for good —
        // the rest of the Trash is never touched. Root-owned items ask for the password once.
        if deletePermanentlyOnce, probesSystem, !total.inTrash.isEmpty {
            let purge = await FileRemover.deletePermanentlyFromTrash(total.inTrash)
            total.deletedPermanently = purge.failed.isEmpty
        }
        deletePermanentlyOnce = false
        // Everything the engines reported must be counted before the scene closes the ring.
        relay.flush()
        // A cleanup that took a blink still gets a moment of sweeping.
        let minimum = 1.4
        let elapsed = Date().timeIntervalSince(session.startedAt)
        if elapsed < minimum { try? await Task.sleep(for: .seconds(minimum - elapsed)) }
        withAnimation(.easeOut(duration: 0.5)) { session.finish() }
        // Ring closes, broom flourishes.
        try? await Task.sleep(for: .seconds(1.3))
        // Enqueued on the main actor, so it runs only after the current job ends — and the caller sets its
        // `.done` phase in that same job, synchronously after this returns (same actor, no hop). No delay needed.
        Task { @MainActor [weak self] in
            guard let self, self.cleaning === session else { return }
            withAnimation(.easeInOut(duration: 0.8)) { self.cleaning = nil }
        }
        return total
    }
}
