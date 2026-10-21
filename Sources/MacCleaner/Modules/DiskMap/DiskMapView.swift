import SwiftUI
import CleanerKit
import SpaceEngine

struct DiskMapView: View {
    let model: DiskMapModel

    var body: some View {
        switch model.phase {
        case .idle, .scanning:
            ModuleStage(module: .diskMap,
                        state: model.phase == .scanning ? .progress(model.progress) : .idle(button: "Сканировать", enabled: true),
                        onAction: model.startScan, onStop: model.stop) {
                LocationPicker(model: model)
            }
        case .results:
            DiskMapResults(model: model)
        case .cleaning:
            ModuleStage(module: .diskMap, title: "Перемещаем в Корзину", subtitle: "Ещё пара секунд…", state: .busy(""))
        case .done:
            CompletionView(tint: .diskMap, result: model.result ?? RemovalResult(), title: "Место освобождено",
                           onDone: model.finish)
        }
    }
}

private struct LocationPicker: View {
    let model: DiskMapModel

    var body: some View {
        HStack(spacing: 8) {
            Chip(title: "Домашняя папка", symbol: "house.fill", selected: model.location == .home, tint: .diskMap) {
                model.location = .home
            }
            Chip(title: "Macintosh HD", symbol: "internaldrive.fill", selected: model.location == .startup, tint: .diskMap) {
                model.location = .startup
            }
            if case .custom(let url) = model.location {
                Chip(title: url.lastPathComponent, symbol: "folder.fill", selected: true, tint: .diskMap) { model.chooseFolder() }
            }
            Chip(title: "Другая папка…", symbol: "folder.badge.plus", selected: false, tint: .diskMap) { model.chooseFolder() }
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
                Button { model.startScan() } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Button { withAnimation(Theme.spring) { model.phase = .idle } } label: {
                    Label("Другое место", systemImage: "folder")
                }
                .buttonStyle(PillButtonStyle(kind: .quiet))
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)

            HStack(alignment: .top, spacing: 18) {
                SunburstView(model: model, segments: segments)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        let kids = model.children(of: focus)
                        let total = max(1, model.size(of: focus))
                        ForEach(Array(kids.prefix(150).enumerated()), id: \.element.id) { _, child in
                            ChildRow(model: model, node: child, actionable: model.isActionable(child, in: focus),
                                     color: colors[child.id] ?? .white.opacity(0.3),
                                     fraction: Double(model.size(of: child)) / Double(total))
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

private struct ChildRow: View {
    let model: DiskMapModel
    let node: DirectoryNode
    let actionable: Bool
    let color: Color
    let fraction: Double
    @State private var hover = false

    var body: some View {
        let highlighted = hover || model.hoveredID == node.id
        let collected = model.collector.contains { $0.url == node.url }
        let row = HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(actionable ? color : .white.opacity(0.2)).frame(width: 4, height: 26)
            Group {
                if actionable {
                    Image(nsImage: IconCache.icon(for: node.url)).resizable()
                } else {
                    Image(systemName: "square.grid.3x3.fill").resizable().scaledToFit().padding(2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(actionable ? node.name : SpaceMapper.otherName)
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
            if actionable && highlighted && !collected {
                IconButton(symbol: "plus", help: "В сборщик", size: 22) { model.collect(node, parent: model.focus) }
            } else if collected {
                Image(systemName: "tray.full.fill").font(.system(size: 11)).foregroundStyle(ModuleTint.diskMap.accent)
            }
            SizeText(bytes: model.size(of: node), font: .system(size: 12, weight: .medium, design: .rounded),
                     color: Theme.textSecondary)
                .frame(minWidth: 58, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Rectangle().fill(.white.opacity(highlighted && actionable ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { h in
            hover = h
            model.hoveredID = h && actionable ? node.id : nil
        }
        .help(actionable ? node.url.path : "Много мелких объектов вместе — их нельзя удалить одним действием")

        if actionable {
            row
                .onTapGesture(count: 2) { if node.isDirectory { model.zoom(into: node) } }
                .draggable(node.url)
                .contextMenu {
                    if node.isDirectory { Button("Открыть на карте") { model.zoom(into: node) } }
                    Button("Добавить в сборщик") { model.collect(node, parent: model.focus) }
                    Button("Показать в Finder") { Finder.reveal(node.url) }
                }
        } else {
            row
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
                Text(model.lastRefusal ?? (model.collector.isEmpty
                     ? "Перетащите сюда папки и файлы, которые хотите удалить, или нажмите «+» в списке."
                     : "\(Fmt.items(model.collector.count).capitalizedFirst) · \(Fmt.size(model.collectorSize))"))
                    .font(.caption12)
                    .foregroundStyle(model.lastRefusal == nil ? Theme.textSecondary : Theme.warning)
                    .lineLimit(2)
            }
            .frame(width: model.collector.isEmpty ? nil : 190, alignment: .leading)

            if !model.collector.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.collector) { item in
                            CollectedChip(item: item) { model.uncollect(item) }
                        }
                    }
                    .padding(.vertical, 4)
                }
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
            Image(nsImage: IconCache.icon(for: item.url)).resizable().frame(width: 18, height: 18)
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
