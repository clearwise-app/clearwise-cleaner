import SwiftUI
import CleanerKit
import SpaceEngine

struct CollectedItem: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let size: Int64
    let isDirectory: Bool
    var name: String { url.lastPathComponent }
}

@MainActor @Observable
final class DiskMapModel {
    @ObservationIgnored weak var app: AppModel?

    enum Location: Hashable {
        case home, startup, custom(URL)

        var url: URL {
            switch self {
            case .home: SafetyGuard.home
            case .startup: URL(fileURLWithPath: "/")
            case .custom(let u): u
            }
        }

        var title: String {
            switch self {
            case .home: "Домашняя папка"
            case .startup: "Macintosh HD"
            case .custom(let u): u.lastPathComponent
            }
        }
    }

    var location: Location = .home
    var phase: ModulePhase = .idle
    var progress = ScanProgress(phase: "", fraction: 0)
    var root: DirectoryNode?
    /// Zoom path, root first. The last element is the node in the center.
    var stack: [DirectoryNode] = []
    var hoveredID: UUID?
    var zoomLoading = false
    /// Where the clicked segment was, so the zoom can grow out of it.
    var zoomOrigin: ZoomOrigin?
    /// 0 → 1 while the map grows into the new focus.
    var zoomProgress: Double = 1
    var collector: [CollectedItem] = []
    var collectorTargeted = false
    var result: RemovalResult?
    /// Removed during this session: url → bytes, so the map shrinks without a rescan.
    var removedBytes: [URL: Int64] = [:]

    @ObservationIgnored private let mapper = SpaceMapper()
    @ObservationIgnored private var task: Task<Void, Never>?

    static let mapDepth = 6

    var focus: DirectoryNode? { stack.last }

    var segments: [SunSegment] {
        guard let focus else { return [] }
        return SunburstLayout.segments(focus: focus, maxDepth: SunburstLayout.rings, size: size(of:), isRemoved: isRemoved)
    }

    func size(of node: DirectoryNode) -> Int64 {
        guard !removedBytes.isEmpty else { return node.size }
        let base = node.url.standardizedFileURL.path
        var minus: Int64 = 0
        for (url, bytes) in removedBytes where url.path == base || url.path.hasPrefix(base + "/") { minus += bytes }
        return max(0, node.size - minus)
    }

    func isRemoved(_ url: URL) -> Bool { removedBytes[url.standardizedFileURL] != nil }

    /// False for the engine's synthetic "Прочее" bucket (it has the parent's URL) — never collect, reveal or trash it.
    func isActionable(_ node: DirectoryNode, in parent: DirectoryNode?) -> Bool {
        guard node.isActionable else { return false }
        if let parent, SpaceMapper.isOtherBucket(node, in: parent) { return false }
        // Belt and braces: a node that shares a URL with any folder on the zoom path is never a real child.
        if stack.contains(where: { $0.url.standardizedFileURL == node.url.standardizedFileURL }) { return false }
        return true
    }

    func children(of node: DirectoryNode) -> [DirectoryNode] {
        node.children.filter { !isRemoved($0.url) }.sorted { size(of: $0) > size(of: $1) }
    }

    // MARK: Scan

    func startScan() {
        app?.storage.noteUserScan()
        task?.cancel()
        task = Task { await scan() }
    }

    func scan() async {
        let target = location.url
        withAnimation(Theme.spring) { phase = .scanning }
        progress = ScanProgress(phase: "Подготовка", fraction: 0)
        let relay = progressRelay { [weak self] p in
            guard let self, self.phase == .scanning else { return }
            self.progress = p
        }
        let node = await mapper.map(target, depth: Self.mapDepth, progress: relay)
        guard !Task.isCancelled, phase == .scanning else { return }
        apply(node)
    }

    func apply(_ node: DirectoryNode) {
        root = node
        stack = [node]
        removedBytes = [:]
        zoomOrigin = nil
        withAnimation(Theme.spring) { phase = .results }
    }

    func stop() {
        task?.cancel()
        withAnimation(Theme.spring) { phase = root == nil ? .idle : .results }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Выбрать"
        if panel.runModal() == .OK, let url = panel.url {
            location = .custom(url)
        }
    }

    // MARK: Navigation

    func zoom(into node: DirectoryNode, from segment: SunSegment? = nil) {
        guard node.isDirectory, node.isActionable, size(of: node) > 0 else { return }
        zoomOrigin = segment.map { ZoomOrigin(start: $0.start, end: $0.end, depth: $0.depth) }
        if node.children.isEmpty {
            // Deeper than the initial map: map this branch on demand.
            zoomLoading = true
            Task {
                let mapped = await mapper.map(node.url, depth: Self.mapDepth, progress: nil)
                zoomLoading = false
                if !mapped.children.isEmpty {
                    stack.append(mapped)
                    animateZoom()
                }
            }
        } else {
            stack.append(node)
            animateZoom()
        }
        hoveredID = nil
    }

    private func animateZoom() {
        zoomProgress = 0
        Task { @MainActor in
            withAnimation(.spring(response: 0.62, dampingFraction: 0.9)) { zoomProgress = 1 }
        }
    }

    func zoomOut(to index: Int) {
        guard index >= 0, index < stack.count - 1 else { return }
        zoomOrigin = nil
        stack.removeSubrange((index + 1)...)
        hoveredID = nil
        animateZoom()
    }

    func node(with id: UUID?) -> DirectoryNode? {
        guard let id, let focus else { return nil }
        return Self.find(id, in: focus, depth: SunburstLayout.rings)
    }

    private static func find(_ id: UUID, in node: DirectoryNode, depth: Int) -> DirectoryNode? {
        if node.id == id { return node }
        guard depth > 0 else { return nil }
        for c in node.children { if let hit = find(id, in: c, depth: depth - 1) { return hit } }
        return nil
    }

    // MARK: Collector

    var collectorSize: Int64 { collector.reduce(0) { $0 + $1.size } }

    func collect(_ node: DirectoryNode, parent: DirectoryNode?) {
        guard isActionable(node, in: parent) else { NSSound.beep(); return }
        collect(CollectedItem(url: node.url, size: size(of: node), isDirectory: node.isDirectory))
    }

    func collect(_ item: CollectedItem) {
        guard !collector.contains(where: { $0.url == item.url }) else { return }
        // Never collect a folder that is on the current zoom path (e.g. the scanned root itself).
        if stack.contains(where: { $0.url.standardizedFileURL == item.url.standardizedFileURL }) {
            NSSound.beep()
            lastRefusal = "«\(item.name)» сейчас открыта на карте — выберите отдельные объекты внутри."
            return
        }
        if let reason = SafetyGuard.refusalReason(for: item.url) {
            NSSound.beep()
            lastRefusal = "«\(item.name)» нельзя удалить: \(reason.lowercased())."
            return
        }
        lastRefusal = nil
        // A folder swallows anything already collected inside it.
        collector.removeAll { $0.url.path.hasPrefix(item.url.path + "/") }
        guard !collector.contains(where: { item.url.path.hasPrefix($0.url.path + "/") }) else { return }
        withAnimation(Theme.spring) { collector.append(item) }
    }

    var lastRefusal: String?

    func collect(urls: [URL]) {
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let known = findNode(url)
            collect(CollectedItem(url: url, size: known.map(size(of:)) ?? FileSizer.allocatedSize(of: url), isDirectory: isDir))
        }
    }

    private func findNode(_ url: URL) -> DirectoryNode? {
        guard let root else { return nil }
        var node = root
        let target = url.standardizedFileURL.path
        while node.url.standardizedFileURL.path != target {
            guard let next = node.children.first(where: { target == $0.url.standardizedFileURL.path || target.hasPrefix($0.url.standardizedFileURL.path + "/") }) else { return nil }
            node = next
        }
        return node
    }

    func uncollect(_ item: CollectedItem) {
        withAnimation(Theme.spring) { collector.removeAll { $0.id == item.id } }
    }

    func requestTrash() {
        let picked = collector
        guard let app, !picked.isEmpty else { return }
        app.ask(Confirmation(
            title: "Переместить в Корзину?",
            message: "Собранные объекты будут перемещены в Корзину — их можно вернуть, пока Корзина не очищена.",
            count: picked.count,
            bytes: picked.reduce(0) { $0 + $1.size },
            confirmTitle: "Переместить в Корзину",
            tint: .diskMap,
            action: { [weak self] in self?.startTrash(picked) }
        ))
    }

    private func startTrash(_ picked: [CollectedItem]) {
        task = Task {
            withAnimation(Theme.spring) { phase = .cleaning }
            let sizes = Dictionary(picked.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a })
            let r = await app?.runCleaning(Self.plan(picked)) ?? RemovalResult()
            for url in r.removed { removedBytes[url.standardizedFileURL] = sizes[url] ?? 0 }
            collector.removeAll { r.removed.contains($0.url) }
            result = r
            app?.didRemove(r)
            withAnimation(Theme.spring) { phase = .done }
        }
    }

    /// The collector as one stage, one Trash call per object so «Остановить» works between objects.
    static func plan(_ picked: [CollectedItem]) -> CleaningPlan {
        var plan = CleaningPlan(title: "Удаление собранных объектов", module: .diskMap)
        let sizes = CleaningPrep.sizes(picked.map { ($0.url, $0.size) })
        let urls = CleaningPrep.dedupe(picked.map(\.url))
        plan.addStage("Собранные объекты", symbol: "tray.full.fill", items: urls.map { ($0, sizes[$0] ?? 0) })
        plan.addTrashUnits(urls, knownSizes: sizes)
        return plan
    }

    func finish() {
        result = nil
        withAnimation(Theme.spring) { phase = root == nil ? .idle : .results }
    }
}
