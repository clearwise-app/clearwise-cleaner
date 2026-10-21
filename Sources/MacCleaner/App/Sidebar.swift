import SwiftUI
import CleanerKit
import SpaceEngine

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights. The app's name lives at the bottom (`Wordmark`):
            // a header here only repeated Smart Care's icon and could not be clicked.
            Color.clear.frame(height: 52)

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

            // One column: the storage card and the access pill share the same width.
            VStack(spacing: 8) {
                SidebarStorage()
                FDAPill()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            Wordmark()
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
        }
        .frame(width: Theme.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(SidebarBackground())
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
            .foregroundStyle(.themeTertiary)
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func item(_ module: AppModule) -> some View {
        SidebarItem(module: module, selected: model.selection == module) {
            ModuleBadge(module: module)
        } action: {
            model.select(module)
        }
        .padding(.horizontal, 10)
    }
}

/// Reduce Transparency: an opaque sidebar instead of the translucent dark wash.
private struct SidebarBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Color(hex: 0x0E0C14)
        } else {
            ZStack {
                Color.black.opacity(0.34)
                LinearGradient(colors: [.white.opacity(0.04), .clear], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

private struct SidebarItem<Badge: View>: View {
    let module: AppModule
    let selected: Bool
    @ViewBuilder let badge: Badge
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                IconTile(symbol: module.symbol, tint: module.tint, size: 26)
                    .accessibilityHidden(true)
                Text(module.sidebarTitle)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.82))
                    .lineLimit(1)
                Spacer(minLength: 0)
                badge
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
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hover = $0 }
        .animation(Theme.quick, value: hover)
    }
}

// MARK: - Badges

/// Each badge is its own view that reads only its module, so a scan tick in one module re-renders
/// one small badge — not the whole sidebar. Percentages are whole numbers: the text changes ≤ 100 times.
private struct ModuleBadge: View {
    let module: AppModule
    @Environment(AppModel.self) private var model

    var body: some View {
        switch module {
        case .smartCare: SmartCareBadge(model: model.smartCare)
        case .junk: JunkBadge(model: model.junk)
        case .uninstaller: AppsBadge()
        case .oldFiles: OldFilesBadge(model: model.oldFiles)
        case .duplicates: DuplicatesBadge(model: model.duplicates)
        case .diskMap: EmptyView()
        }
    }
}

private struct SmartCareBadge: View {
    let model: SmartCareModel
    var body: some View {
        if model.phase == .scanning { BadgeText(text: "…", spoken: "сканирование") }
    }
}

private struct JunkBadge: View {
    let model: JunkModel
    var body: some View {
        if model.phase == .scanning {
            PercentBadge(percent: Int(model.progress.fraction * 100))
        } else if model.phase == .results, model.totalSize > 0 {
            SizeBadge(bytes: model.totalSize)
        }
    }
}

private struct AppsBadge: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.appsState == .loaded {
            let n = model.nonSystemAppCount
            BadgeText(text: Fmt.integer(n), spoken: Fmt.apps(n))
        }
    }
}

private struct OldFilesBadge: View {
    let model: OldFilesModel
    var body: some View {
        if model.phase == .scanning {
            PercentBadge(percent: Int(model.progress.fraction * 100))
        } else if model.phase == .results, model.totalSize > 0 {
            SizeBadge(bytes: model.totalSize)
        }
    }
}

private struct DuplicatesBadge: View {
    let model: DuplicatesModel
    var body: some View {
        if model.phase == .scanning {
            PercentBadge(percent: Int(model.progress.fraction * 100))
        } else if model.phase == .results, model.reclaimable > 0 {
            SizeBadge(bytes: model.reclaimable)
        }
    }
}

private struct PercentBadge: View, Equatable {
    let percent: Int
    var body: some View {
        BadgeText(text: Fmt.percent(Double(percent) / 100), spoken: "сканирование \(Fmt.percent(Double(percent) / 100))")
    }
}

private struct SizeBadge: View, Equatable {
    let bytes: Int64
    var body: some View {
        BadgeText(text: Fmt.size(bytes), spoken: "найдено \(Fmt.size(bytes))")
    }
}

private struct BadgeText: View, Equatable {
    let text: String
    /// What VoiceOver reads after the module name: «найдено 28,1 ГБ», «сканирование 47 %».
    let spoken: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .lineLimit(1)
            .fixedSize()
            .monospacedDigit()
            .foregroundStyle(.themeTertiary)
            .accessibilityLabel(spoken)
    }
}

// MARK: - Storage widget

/// Bottom-left disk widget: free space, the disk as coloured category segments, the top categories in percent.
/// A real button: click, Space or Return pins the full breakdown card (Esc closes it); hovering opens it too,
/// and hovering a segment shows its share and size. VoiceOver reads it as a list of categories.
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
    @FocusState private var focused: Bool

    private static let barHeight: CGFloat = 8
    private var storage: StorageModel { model.storage }
    private var hovered: StorageCategory.Kind? { hoveredSegment ?? storage.debugHovered }
    private var showsCard: Bool { cardVisible || pinned || storage.debugShowsDetails }

    var body: some View {
        Button(action: activate) {
            widget.frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(StorageWidgetStyle(highlighted: hoverWidget || showsCard, outlined: showsCard || focused))
        .focused($focused)
        .onHover { inside in
            hoverWidget = inside
            if !inside { hoveredSegment = nil }
            scheduleCard()
        }
        .onExitCommand { if showsCard { close() } }
        .overlay(alignment: .bottomLeading) { card }
        .animation(Theme.quick, value: hoverWidget)
        .animation(Theme.spring, value: showsCard)
        .help(storage.breakdown == nil ? "Показать, что занимает место на диске" : "")
        .accessibilityRepresentation {
            VStack {
                Button(accessibilityTitle, action: activate)
                    .accessibilityHint(storage.breakdown == nil ? "Измерить, что занимает место"
                                                                : (showsCard ? "Закрыть подробности" : "Показать подробности"))
                ForEach(accessibilityRows, id: \.self) { Text($0) }
            }
        }
    }

    private var widget: some View {
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
                    .foregroundStyle(.themeTertiary)
                    .lineLimit(1)
            } else {
                // Not measured yet (no Full Disk Access, nothing scanned): plain used/free bar + what a click does.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.08))
                        Capsule().fill(.white.opacity(0.35))
                            .frame(width: total > 0 ? geo.size.width * CGFloat(Double(total - free) / Double(total)) : 0)
                    }
                }
                .frame(height: Self.barHeight)
                Label("Показать, чем занят диск", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ModuleTint.smartCare.accent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Accessibility

    private var accessibilityTitle: String {
        "\(name): свободно \(Fmt.size(free)) из \(Fmt.size(total))"
    }

    /// «Приложения — 14 %, 71,3 ГБ», in the bar's order, then free space.
    private var accessibilityRows: [String] {
        guard let b = storage.breakdown else { return [] }
        return StorageSegmentBar.order(b).map { "\($0.title) — \(StorageFmt.percent(b.share($0.bytes))), \(Fmt.size($0.bytes))" }
            + ["Свободно — \(StorageFmt.percent(b.share(b.free))), \(Fmt.size(b.free))"]
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
                .foregroundStyle(.themeSecondary)
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
        }
        let freeLabel = Text(freeText)
            .font(.system(size: 10.5, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.themeTertiary)
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

    /// Top four categories in the bar's order, two content-sized columns: category icon, name, «12 %».
    /// Icons, not colour dots: several palette pairs merge under colour-vision deficiencies.
    private func legend(_ b: StorageBreakdown) -> some View {
        let top = Array(StorageSegmentBar.order(b).prefix(4))
        let rows = stride(from: 0, to: top.count, by: 2).map { Array(top[$0..<min($0 + 2, top.count)]) }
        return Grid(alignment: .leading, horizontalSpacing: 3, verticalSpacing: 4) {
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
        Image(systemName: c.kind.symbol)
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(c.kind.color)
            .frame(width: 11)
            .opacity(opacity)
        Text(c.kind.shortTitle)
            .foregroundStyle(.themeSecondary)
            .lineLimit(1)
            // Shrinks a little instead of widening the card past the sidebar (and past the access pill).
            .minimumScaleFactor(0.8)
            .opacity(opacity)
        Text(StorageFmt.percent(share))
            .fontWeight(.semibold)
            .foregroundStyle(Theme.text.opacity(0.9))
            .monospacedDigit()
            .fixedSize()
            .gridColumnAlignment(.trailing)
            .padding(.trailing, gap ? 6 : 0)
            .opacity(opacity)
    }

    @ViewBuilder
    private func tooltip(_ b: StorageBreakdown) -> some View {
        if let kind = hovered, let c = b.categories.first(where: { $0.kind == kind }) {
            GeometryReader { geo in
                let barWidth = geo.size.width
                let seg = StorageSegmentBar.layout(b, width: barWidth).first { $0.kind == kind }
                let center = seg.map { $0.x + $0.width / 2 } ?? barWidth / 2
                // Centered over the segment, kept inside the widget (10 pt padding on each side).
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
                              onClose: pinned ? { close() } : nil,
                              onGrantAccess: { close(); model.presentAccessSheet() })
                .onHover { inside in
                    hoverCard = inside
                    if !inside { hoveredSegment = nil }
                    scheduleCard()
                }
                // Esc closes the card from anywhere in the window, not only with the widget focused.
                .background {
                    Button("Закрыть", action: close)
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
                // Past the sidebar's right edge (the widget is inset 14 pt), bottom-aligned with the widget.
                .offset(x: Theme.sidebarWidth - 14 + 10)
                .transition(Theme.motion(.opacity.combined(with: .offset(x: -8))))
        }
    }

    // MARK: Behaviour

    private func activate() {
        if storage.breakdown == nil { storage.requestMeasure() } else if showsCard { close() } else { pinned = true }
    }

    private func close() {
        cardTask?.cancel()
        pinned = false
        cardVisible = false
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

private struct StorageWidgetStyle: ButtonStyle {
    let highlighted: Bool
    let outlined: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.1 : (highlighted ? 0.085 : 0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(outlined ? 0.1 : 0), lineWidth: 0.75))
            )
    }
}

// MARK: - Access pill

/// «Нет полного доступа · Дать доступ» (yellow) opens the access sheet; with access, a green status
/// that shows «Доступ открыт» in a popover. A revoked access only turns this pill yellow — no dialogs.
private struct FDAPill: View {
    @Environment(AppModel.self) private var model
    @State private var showsPopover = false
    @State private var hover = false

    var body: some View {
        let granted = model.hasFullDiskAccess
        // Radius = height / 2 on a rounded rectangle: a stroked `Capsule` leaves hairlines at both ends.
        let shape = RoundedRectangle(cornerRadius: 15, style: .circular)
        Button {
            if granted { showsPopover.toggle() } else { model.presentAccessSheet() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(granted ? Theme.success : Theme.warning)
                if granted {
                    Text("Полный доступ к диску")
                        .foregroundStyle(.themeSecondary)
                } else {
                    // «Нет полного доступа · Дать доступ»; the dot goes first when the sidebar is tight.
                    ViewThatFits(in: .horizontal) {
                        missingLabel(separator: true)
                        missingLabel(separator: false)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                shape.fill(granted ? Color.white.opacity(hover ? 0.09 : 0.06)
                                   : Theme.warning.opacity(hover ? 0.2 : 0.14))
            )
            .overlay(shape.strokeBorder(granted ? Color.clear : Theme.warning.opacity(0.4), lineWidth: 0.75))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .popover(isPresented: $showsPopover, arrowEdge: .top) { AccessGrantedPopover() }
        .help(granted ? "\(AppInfo.name) видит все файлы, которые нужны для сканирования."
                      : "Системные настройки → Конфиденциальность и безопасность → Полный доступ к диску")
        .accessibilityLabel(granted ? "Полный доступ к диску включён" : "Нет полного доступа к диску")
        .accessibilityHint(granted ? "Показать подробности" : "Показать, как дать доступ")
        .animation(Theme.quick, value: granted)
    }
}

private extension FDAPill {
    func missingLabel(separator: Bool) -> some View {
        HStack(spacing: separator ? 4 : 8) {
            Text("Нет полного доступа")
                .foregroundStyle(Theme.text.opacity(0.9))
                .fixedSize()
            if separator { Text("·").foregroundStyle(.themeTertiary) }
            Text("Дать доступ")
                .fontWeight(.semibold)
                .foregroundStyle(Theme.warning)
                .fixedSize()
        }
    }
}

private struct AccessGrantedPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Доступ открыт", systemImage: "checkmark.shield.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.success)
            Text("\(AppInfo.name) видит все файлы, которые нужны для сканирования. Отключить доступ можно в Системных настройках.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Открыть Системные настройки") { Permissions.openFullDiskAccessSettings() }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 270)
    }
}

/// The app's own mark: violet→magenta rounded square with sparkles.
/// «Clearwise Cleaner» at the bottom of the sidebar: the brand, quietly, under the disk status.
private struct Wordmark: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Clearwise")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundStyle(ModuleTint.smartCare.horizontal)
            Text("Cleaner")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.themeSecondary)
            Spacer(minLength: 6)
            Text(AppInfo.version)
                .font(.system(size: 10.5, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.themeTertiary)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(AppInfo.name), версия \(AppInfo.version)")
    }
}

struct AppGlyph: View {
    var size: CGFloat = 30

    var body: some View {
        IconTile(symbol: "sparkles", tint: .smartCare, size: size)
    }
}
