import SwiftUI
import CleanerKit
import SpaceEngine

struct DiskMapView: View {
    let model: DiskMapModel
    @Environment(AppModel.self) private var app

    var body: some View {
        switch model.phase {
        case .idle, .scanning:
            ModuleStage(module: .diskMap,
                        state: model.phase == .scanning ? .progress(model.progress) : .idle(button: String(localized: "Сканировать"), enabled: true),
                        onAction: model.startScan, onStop: model.stop,
                        onGrantAccess: app.presentAccessSheet) {
                LocationPicker(model: model)
            }
        case .results, .cleaning:
            // While objects move, the cleaning scene covers this screen; there is no screen of its own.
            DiskMapResults(model: model)
        case .done:
            CompletionView(tint: .diskMap, result: model.result ?? RemovalResult(), title: String(localized: "Перемещено в Корзину"),
                           noun: .items,
                           onGrantAccess: app.presentAccessSheet,
                           onRetry: model.retryFailed,
                           onEmptyTrash: app.requestEmptyTrash,
                           onDone: model.finish)
        }
    }
}

private struct LocationPicker: View {
    let model: DiskMapModel

    var body: some View {
        HStack(spacing: 8) {
            Chip(title: String(localized: "Домашняя папка"), symbol: "house.fill", selected: model.location == .home, tint: .diskMap) {
                model.location = .home
            }
            Chip(title: "Macintosh HD", symbol: "internaldrive.fill", selected: model.location == .startup, tint: .diskMap) {
                model.location = .startup
            }
            if case .custom(let url) = model.location {
                Chip(title: url.lastPathComponent, symbol: "folder.fill", selected: true, tint: .diskMap) { model.chooseFolder() }
            }
            Chip(title: String(localized: "Другая папка…"), symbol: "folder.badge.plus", selected: false, tint: .diskMap) { model.chooseFolder() }
        }
    }
}

private struct DiskMapResults: View {
    let model: DiskMapModel

    var body: some View {
        let segments = model.segments
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Breadcrumbs(model: model)
                Spacer()
                Button { model.startScan() } label: { Label("Сканировать заново", systemImage: "arrow.clockwise") }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Button {
                    // Pick, then scan: the label promises a folder dialog, not a detour through the start screen.
                    if model.chooseFolder() { model.startScan() }
                } label: {
                    Label("Другая папка…", systemImage: "folder")
                }
                .buttonStyle(PillButtonStyle(kind: .quiet))
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)

            HStack(alignment: .top, spacing: 18) {
                SunburstView(model: model, segments: segments)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Floats over the map's bottom edge (the list stays clear), so nothing jumps when a refusal appears.
                    .overlay(alignment: .bottom) {
                        if let refusal = model.lastRefusal {
                            RefusalBanner(refusal: refusal, onDismiss: model.dismissRefusal)
                                .padding(.bottom, 6)
                                .transition(Theme.motion(.move(edge: .bottom).combined(with: .opacity)))
                        }
                    }
                ChildrenList(model: model, colors: Dictionary(segments.filter { $0.depth == 1 }.map { ($0.id, $0.color) },
                                                               uniquingKeysWith: { a, _ in a }))
                    .frame(width: 330)
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 14)

            CollectorTray(model: model)
                .padding(.horizontal, 28)
                .padding(.bottom, 22)
        }
    }
}

/// Why «+» or a drop was refused: a warning of its own with a close button, not text squeezed into the hint.
private struct RefusalBanner: View {
    let refusal: DiskMapModel.Refusal
    let onDismiss: () -> Void
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(refusal.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text(refusal.detail)
                    .font(.caption12)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            IconButton(symbol: "xmark", help: String(localized: "Закрыть"), size: 22, action: onDismiss)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.55)))
        .glass(radius: 14, shadow: false)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.warning.opacity(0.55), lineWidth: 1))
        .frame(maxWidth: 640)
        .onAppear {
            guard !isSnapshot else { return }
            AccessibilityNotification.Announcement("\(refusal.title). \(refusal.detail)").post()
        }
    }
}

private struct Breadcrumbs: View {
    let model: DiskMapModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.stack.enumerated()), id: \.offset) { i, node in
                if i > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
                let last = i == model.stack.count - 1
                Button {
                    model.zoomOut(to: i)
                } label: {
                    HStack(spacing: 5) {
                        if i == 0 {
                            Image(systemName: model.location == .startup ? "internaldrive.fill" : "house.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        Text(i == 0 ? model.location.title : node.name)
                            .font(.system(size: 12.5, weight: last ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(last ? Theme.text : Theme.textSecondary)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(Capsule().fill(.white.opacity(last ? 0.12 : 0.05)))
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!last)
            }
        }
    }
}

private struct ChildrenList: View {
    let model: DiskMapModel
    let colors: [UUID: Color]

    var body: some View {
        // Read once, hand down as plain values: rows must not each observe the hover or the collector.
        let hovered = model.hoveredID
        let collectedURLs = Set(model.collector.map(\.url))
        VStack(spacing: 0) {
            if let focus = model.focus {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.stack.count == 1 ? model.location.title : focus.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer()
                    SizeText(bytes: model.size(of: focus), font: .system(size: 13, weight: .semibold, design: .rounded),
                             color: Theme.textSecondary)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                Hairline()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let kids = model.children(of: focus).map { ($0, model.size(of: $0)) }
                        let total = max(1, model.size(of: focus))
                        ForEach(kids.prefix(150), id: \.0.id) { child, size in
                            ChildRow(model: model, node: child, actionable: model.isActionable(child, in: focus),
                                     color: colors[child.id] ?? .white.opacity(0.3),
                                     fraction: Double(size) / Double(total), size: size,
                                     highlighted: hovered == child.id,
                                     collected: collectedURLs.contains(child.url))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .glass(radius: 16, shadow: false)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// One child of the focused folder. Takes plain values only (`size`, `highlighted`, `collected`), so a hover on
/// the map re-runs `ChildrenList` once instead of every row. Keyboard: the row is focusable, Return opens the
/// folder on the map, «+» puts it into the collector; VoiceOver gets the same as actions.
private struct ChildRow: View {
    let model: DiskMapModel
    let node: DirectoryNode
    let actionable: Bool
    let color: Color
    let fraction: Double
    let size: Int64
    /// The segment on the map under the pointer is this row's.
    let highlighted: Bool
    let collected: Bool
    @State private var hover = false
    @FocusState private var focused: Bool

    private var active: Bool { hover || highlighted || focused }
    private var title: String { actionable ? node.name : SpaceMapper.otherName }

    var body: some View {
        let row = HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(actionable ? color : .white.opacity(0.2)).frame(width: 4, height: 26)
            Group {
                if actionable {
                    FileIcon(url: node.url, size: 20)
                } else {
                    Image(systemName: "square.grid.3x3.fill").resizable().scaledToFit().padding(2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(actionable ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.08))
                        Capsule().fill((actionable ? color : .white.opacity(0.3)).opacity(0.85))
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
                .frame(height: 3)
            }
            Spacer(minLength: 4)
            if actionable && active && !collected {
                IconButton(symbol: "plus", help: String(localized: "В сборщик (+)"), size: 22) { model.collect(node, parent: model.focus) }
                    .focusable(false)
            } else if collected {
                Image(systemName: "tray.full.fill").font(.system(size: 11)).foregroundStyle(ModuleTint.diskMap.accent)
            }
            SizeText(bytes: size, font: .system(size: 12, weight: .medium, design: .rounded),
                     color: Theme.textSecondary)
                .frame(minWidth: 58, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Rectangle().fill(.white.opacity(active && actionable ? 0.06 : 0)))
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(ModuleTint.diskMap.accent.opacity(0.85), lineWidth: 1.5)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onHover { h in
            hover = h
            model.hoveredID = h && actionable ? node.id : nil
        }
        .help(actionable ? node.url.path : String(localized: "Много мелких объектов вместе — их нельзя убрать одним действием"))

        if actionable {
            row
                .onTapGesture(count: 2) { open() }
                .focusable()
                .focusEffectDisabled()
                .focused($focused)
                .onKeyPress(characters: CharacterSet(charactersIn: "+=")) { _ in
                    model.collect(node, parent: model.focus)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard node.isDirectory else { return .ignored }
                    open()
                    return .handled
                }
                .draggable(node.url)
                .contextMenu {
                    if node.isDirectory { Button("Открыть на карте") { open() } }
                    Button("Добавить в сборщик") { model.collect(node, parent: model.focus) }
                    Button("Показать в Finder") { Finder.reveal(node.url) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(collected ? String(localized: "в сборщике") : "")
                .accessibilityAction { if node.isDirectory { open() } else { model.collect(node, parent: model.focus) } }
                .accessibilityAction(named: "Добавить в сборщик") { model.collect(node, parent: model.focus) }
                .modifier(OpenOnMapAction(isDirectory: node.isDirectory, open: open))
                .accessibilityAction(named: "Показать в Finder") { Finder.reveal(node.url) }
        } else {
            row.accessibilityElement(children: .combine)
        }
    }

    private func open() {
        if node.isDirectory { model.zoom(into: node) }
    }
}

private struct OpenOnMapAction: ViewModifier {
    let isDirectory: Bool
    let open: () -> Void

    func body(content: Content) -> some View {
        if isDirectory {
            content.accessibilityAction(named: "Открыть на карте", open)
        } else {
            content
        }
    }
}

/// DaisyDisk-like "Collector": gather items first, then move them all to Trash at once.
private struct CollectorTray: View {
    let model: DiskMapModel

    var body: some View {
        HStack(spacing: 16) {
            IconTile(symbol: "tray.and.arrow.down.fill", tint: .diskMap, size: 40, muted: model.collector.isEmpty)
            VStack(alignment: .leading, spacing: 2) {
                Text("Сборщик")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(model.collector.isEmpty
                     ? String(localized: "Перетащите сюда папки и файлы или нажмите «+» в списке — потом всё сразу уйдёт в Корзину.")
                     : "\(Fmt.items(model.collector.count).capitalizedFirst) · \(Fmt.size(model.collectorSize))")
                    .font(.caption12)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            .frame(width: model.collector.isEmpty ? nil : 190, alignment: .leading)

            if !model.collector.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.collector) { item in
                            CollectedChip(item: item) { model.uncollect(item) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                Button("В Корзину") { model.requestTrash() }
                    .buttonStyle(PillButtonStyle(kind: .primary(.diskMap), large: true))
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 74)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(model.collectorTargeted ? 0.12 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.25, dash: model.collector.isEmpty ? [6, 5] : []))
                .foregroundStyle(model.collectorTargeted ? ModuleTint.diskMap.accent : .white.opacity(0.18))
        )
        .dropDestination(for: URL.self) { urls, _ in
            model.collect(urls: urls)
            return true
        } isTargeted: { model.collectorTargeted = $0 }
        .animation(Theme.spring, value: model.collector)
    }
}

private struct CollectedChip: View {
    let item: CollectedItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            FileIcon(url: item.url, size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                SizeText(bytes: item.size, font: .system(size: 10.5, design: .rounded), color: Theme.textTertiary)
            }
            .frame(maxWidth: 120, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("Убрать из сборщика")
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.75))
        .help(item.url.path)
    }
}
