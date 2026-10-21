import SwiftUI
import CleanerKit
import SpaceEngine

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights.
            Color.clear.frame(height: 44)

            HStack(spacing: 10) {
                AppGlyph(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("MacCleaner").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                    Text("Чисто и безопасно").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 22)

            item(.smartCare)
            section("Очистка")
            item(.junk)
            section("Приложения")
            item(.uninstaller)
            section("Файлы")
            item(.oldFiles)
            item(.duplicates)
            item(.diskMap)

            Spacer(minLength: 12)

            SidebarStorage().padding(.horizontal, 14).padding(.bottom, 10)
            FDAPill().padding(.horizontal, 14).padding(.bottom, 16)
        }
        .frame(width: Theme.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(
            ZStack {
                Color.black.opacity(0.34)
                LinearGradient(colors: [.white.opacity(0.04), .clear], startPoint: .top, endPoint: .bottom)
            }
        )
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.hairline).frame(width: 1)
        }
        // The storage card floats past the sidebar edge, over the module content.
        .zIndex(1)
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 6)
    }

    private func item(_ module: AppModule) -> some View {
        SidebarItem(module: module, selected: model.selection == module, badge: badge(for: module)) {
            model.select(module)
        }
        .padding(.horizontal, 10)
    }

    private func badge(for module: AppModule) -> String? {
        switch module {
        case .smartCare:
            return model.smartCare.phase == .scanning ? "…" : nil
        case .junk:
            if model.junk.phase == .scanning { return "\(Int(model.junk.progress.fraction * 100))%" }
            return model.junk.phase == .results && model.junk.totalSize > 0 ? Fmt.size(model.junk.totalSize) : nil
        case .uninstaller:
            return model.appsState == .loaded ? "\(model.apps.filter { !$0.isSystemApp }.count)" : nil
        case .oldFiles:
            return model.oldFiles.phase == .results && model.oldFiles.totalSize > 0 ? Fmt.size(model.oldFiles.totalSize) : nil
        case .duplicates:
            let d = model.duplicates
            if d.phase == .scanning { return "\(Int(d.progress.fraction * 100))%" }
            return d.phase == .results && d.reclaimable > 0 ? Fmt.size(d.reclaimable) : nil
        case .diskMap:
            return nil
        }
    }
}

private struct SidebarItem: View {
    let module: AppModule
    let selected: Bool
    let badge: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                IconTile(symbol: module.symbol, tint: module.tint, size: 26)
                Text(module.sidebarTitle)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.82))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .fixedSize()
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(selected ? 0.13 : (hover ? 0.06 : 0)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(selected ? 0.1 : 0), lineWidth: 0.75)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Theme.quick, value: hover)
    }
}

/// Bottom-left disk widget: free space, the disk as coloured category segments, the top categories in percent.
/// Hovering a segment shows its share and size; hovering (or clicking) the widget opens the full breakdown.
private struct SidebarStorage: View {
    @Environment(AppModel.self) private var model
    @State private var hoveredSegment: StorageCategory.Kind?
    @State private var hoverWidget = false
    @State private var hoverCard = false
    @State private var pinned = false
    @State private var cardVisible = false
    @State private var cardTask: Task<Void, Never>?
    @State private var tooltipSize = CGSize(width: 160, height: 42)
    @State private var titleHeight: CGFloat = 30

    private static let barHeight: CGFloat = 8
    private var storage: StorageModel { model.storage }
    private var hovered: StorageCategory.Kind? { hoveredSegment ?? storage.debugHovered }
    private var showsCard: Bool { cardVisible || pinned || storage.debugShowsDetails }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { titleHeight = $0 }
            if let b = storage.breakdown {
                StorageSegmentBar(breakdown: b, height: Self.barHeight, hovered: hovered) { kind in
                    hoveredSegment = kind
                    scheduleCard()
                }
                .overlay(alignment: .bottomLeading) { tooltip(b) }
                .zIndex(1)
                legend(b)
            } else if storage.isMeasuring {
                StorageShimmerBar(height: Self.barHeight)
                Text("Считаем, что занимает место…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            } else {
                // Not measured yet (no Full Disk Access, nothing scanned): plain used/free bar + an explicit action.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.08))
                        Capsule().fill(.white.opacity(0.35))
                            .frame(width: total > 0 ? geo.size.width * CGFloat(Double(total - free) / Double(total)) : 0)
                    }
                }
                .frame(height: Self.barHeight)
                Button { storage.requestMeasure() } label: {
                    Label("Показать, чем занят диск", systemImage: "chart.bar.xaxis")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ModuleTint.smartCare.accent)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(hoverWidget || showsCard ? 0.085 : 0.06))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(showsCard ? 0.1 : 0), lineWidth: 0.75))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { if storage.breakdown == nil { storage.requestMeasure() } else { togglePinned() } }
        .onHover { inside in
            hoverWidget = inside
            if !inside { hoveredSegment = nil }
            scheduleCard()
        }
        .overlay(alignment: .bottomLeading) { card }
        .animation(Theme.quick, value: hoverWidget)
        .animation(Theme.spring, value: showsCard)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Показать, что занимает место на диске")
    }

    // MARK: Parts

    private var free: Int64 { model.disk?.available ?? storage.breakdown?.free ?? 0 }
    private var total: Int64 { model.disk?.total ?? storage.breakdown?.total ?? 0 }
    private var name: String { model.disk?.name ?? storage.breakdown?.volumeName ?? "Macintosh HD" }

    private var titleRow: some View {
        let freeText = "свободно \(Fmt.size(free)) из \(Fmt.size(total))"
        let nameLabel = HStack(spacing: 5) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textSecondary)
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
        }
        let freeLabel = Text(freeText)
            .font(.system(size: 10.5, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                nameLabel.fixedSize()
                Spacer(minLength: 4)
                freeLabel.fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                nameLabel
                freeLabel
            }
        }
    }

    /// Top four categories in two content-sized columns: "● Приложения 12%".
    private func legend(_ b: StorageBreakdown) -> some View {
        let top = Array(b.categories.filter { $0.bytes > 0 }.prefix(4))
        let rows = stride(from: 0, to: top.count, by: 2).map { Array(top[$0..<min($0 + 2, top.count)]) }
        return Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(Array(rows[r].enumerated()), id: \.element.id) { i, c in
                        legendCell(c, share: b.share(c.bytes), gap: i == 0 && rows[r].count > 1)
                    }
                }
            }
        }
        .font(.system(size: 10.5, design: .rounded))
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Theme.quick, value: hovered)
    }

    @ViewBuilder
    private func legendCell(_ c: StorageCategory, share: Double, gap: Bool) -> some View {
        let opacity = hovered != nil && hovered != c.kind ? 0.45 : 1
        Circle().fill(c.kind.color).frame(width: 6, height: 6).opacity(opacity)
        Text(c.kind.shortTitle)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .opacity(opacity)
        Text(StorageFmt.percent(share))
            .fontWeight(.semibold)
            .foregroundStyle(Theme.text.opacity(0.9))
            .monospacedDigit()
            .fixedSize()
            .gridColumnAlignment(.trailing)
            .padding(.trailing, gap ? 10 : 0)
            .opacity(opacity)
    }

    @ViewBuilder
    private func tooltip(_ b: StorageBreakdown) -> some View {
        if let kind = hovered, let c = b.categories.first(where: { $0.kind == kind }) {
            GeometryReader { geo in
                let barWidth = geo.size.width
                let seg = StorageSegmentBar.layout(b, width: barWidth).first { $0.kind == kind }
                let center = seg.map { $0.x + $0.width / 2 } ?? barWidth / 2
                // Centered over the segment, kept inside the widget (12 pt padding on each side).
                let x = min(max(center - tooltipSize.width / 2, -8), barWidth - tooltipSize.width + 8)
                StorageTooltip(category: c, breakdown: b)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
                    // Floats just above the widget, so the title and free space stay readable.
                    .offset(x: x, y: -(tooltipSize.height + titleHeight + 8 + 12 + 6))
            }
            .frame(height: Self.barHeight)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    @ViewBuilder private var card: some View {
        if showsCard, let b = storage.breakdown {
            StorageDetailCard(breakdown: b, hovered: hovered,
                              onHover: { hoveredSegment = $0 },
                              onClose: pinned ? { togglePinned() } : nil)
                .onHover { inside in
                    hoverCard = inside
                    if !inside { hoveredSegment = nil }
                    scheduleCard()
                }
                // Past the sidebar's right edge (the widget is inset 14 pt), bottom-aligned with the widget.
                .offset(x: Theme.sidebarWidth - 14 + 10)
                .transition(.opacity.combined(with: .offset(x: -8)))
        }
    }

    // MARK: Behaviour

    private func togglePinned() {
        if pinned {
            pinned = false
            cardVisible = false
        } else {
            pinned = true
        }
    }

    /// Opens the card after a short hover over the widget (not while pointing at a segment, which has its own
    /// tooltip); closes it shortly after the mouse has left both the widget and the card.
    private func scheduleCard() {
        cardTask?.cancel()
        let wantsOpen = (hoverWidget && hoveredSegment == nil) || hoverCard
        let wantsClose = !hoverWidget && !hoverCard
        guard storage.breakdown != nil else { return }
        if wantsOpen && !cardVisible {
            cardTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                cardVisible = true
            }
        } else if wantsClose && cardVisible {
            cardTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                cardVisible = false
            }
        }
    }
}

private struct FDAPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            if model.hasFullDiskAccess { model.refreshSystemState() } else { Permissions.openFullDiskAccessSettings() }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.hasFullDiskAccess ? Theme.success : Theme.warning)
                    .frame(width: 7, height: 7)
                    .shadow(color: (model.hasFullDiskAccess ? Theme.success : Theme.warning).opacity(0.8), radius: 4)
                Text(model.hasFullDiskAccess ? "Полный доступ к диску" : "Доступ к диску")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !model.hasFullDiskAccess {
                    Text("Настроить")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(.white.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(model.hasFullDiskAccess ? "MacCleaner видит все файлы, которые нужны для сканирования." : "Откройте Настройки → Конфиденциальность → Полный доступ к диску и включите MacCleaner.")
    }
}

/// The app's own mark: violet→magenta rounded square with sparkles.
struct AppGlyph: View {
    var size: CGFloat = 30

    var body: some View {
        IconTile(symbol: "sparkles", tint: .smartCare, size: size)
    }
}
