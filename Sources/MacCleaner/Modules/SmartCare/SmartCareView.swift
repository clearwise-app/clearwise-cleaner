import SwiftUI
import CleanerKit
import SpaceEngine

struct SmartCareView: View {
    let model: SmartCareModel
    @Environment(AppModel.self) private var app

    var body: some View {
        switch model.phase {
        case .idle, .scanning:
            // `areas` reads three models: once per body, then passed on.
            let areas = model.areas
            let scanning = model.phase == .scanning
            ModuleStage(module: .smartCare,
                        state: scanning
                            ? .progress(ScanProgress(phase: SmartCareModel.phaseText(of: areas),
                                                     fraction: SmartCareModel.fraction(of: areas),
                                                     currentPath: model.currentPath))
                            : .idle(button: "Сканировать", enabled: true),
                        onAction: model.startScan, onStop: model.stop, dimsOptionsWhileWorking: false, showsTrashHint: true,
                        onGrantAccess: { app.presentAccessSheet() }) {
                LastCleanupChip()
            } options: {
                AreaPills(areas: areas, scanning: scanning)
            }
        case .results, .cleaning:
            // While cleaning, the overlay covers this screen; the overview stays underneath.
            SmartCareResults(model: model)
        case .done:
            CompletionView(tint: .smartCare, result: model.result ?? RemovalResult(), title: "Mac стал чище",
                           permanent: model.resultWasPermanent,
                           onGrantAccess: { app.presentAccessSheet() },
                           onRetry: model.retryFailed,
                           onEmptyTrash: { app.requestEmptyTrash() },
                           onDone: model.finish)
        }
    }
}

/// What Smart Care checks; turns into live status while scanning.
private struct AreaPills: View {
    let areas: [SmartCareModel.AreaStatus]
    let scanning: Bool

    var body: some View {
        HStack(spacing: 10) {
            ForEach(areas, id: \.title) { area in
                HStack(spacing: 8) {
                    if scanning {
                        ZStack {
                            Circle().stroke(.white.opacity(0.15), lineWidth: 2.5)
                            Circle().trim(from: 0, to: area.done ? 1 : max(0.03, area.fraction))
                                .stroke(area.done ? Theme.success : ModuleTint.smartCare.accent,
                                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            if area.done {
                                Image(systemName: "checkmark").font(.system(size: 7, weight: .black)).foregroundStyle(Theme.success)
                            }
                        }
                        .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: area.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ModuleTint.smartCare.accent)
                    }
                    Text(area.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                    if scanning && area.done {
                        Text(area.detail)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(.white.opacity(0.07)))
                .overlay(Pill().strokeBorder(.white.opacity(0.1), lineWidth: 0.75))
            }
        }
    }
}


private struct SmartCareResults: View {
    let model: SmartCareModel
    @Environment(AppModel.self) private var app

    var body: some View {
        let junk = app.junk
        let digest = model.digest()
        if junk.categories.isEmpty && digest.isEmpty {
            SmartCareAllClear(onRescan: model.startScan, onOpenDiskMap: { app.select(.diskMap) },
                              onGrantAccess: { app.presentAccessSheet() })
        } else {
            overview(digest: digest)
        }
    }

    private func overview(digest: SmartCareModel.Digest) -> some View {
        let total = model.totalBytes
        let count = model.totalCount
        let found = app.junk.totalSize + digest.orphansBytes + digest.oldBytes
        return VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.system(size: 11, weight: .bold))
                        Text("УМНАЯ ОЧИСТКА").font(.system(size: 11, weight: .bold)).tracking(0.8)
                    }
                    .foregroundStyle(ModuleTint.smartCare.accent)
                    BigSize(bytes: total, size: 64)
                        .padding(.top, 2)
                    Text(total > 0
                         ? "выбрано для очистки · ещё \(Fmt.size(max(0, found - total))) не выбрано"
                         : "ничего не выбрано — включите то, что хотите очистить")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                    PartialAccessNote(onGrantAccess: { app.presentAccessSheet() })
                        .padding(.top, 6)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    LastCleanupChip()
                    Button { model.startScan() } label: { Label("Сканировать заново", systemImage: "arrow.clockwise") }
                        .buttonStyle(PillButtonStyle(kind: .quiet))
                }
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.top, 30)

            TrashHint()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.page)
                .padding(.top, 12)

            ScrollViewReader { scroller in
            ScrollView {
                VStack(spacing: 14) {
                    TileRow {
                        JunkTile(model: model, junk: app.junk, digest: digest) { app.select(.junk) }
                        LeftoversTile(model: model, uninstaller: app.uninstaller, digest: digest) {
                            app.uninstaller.tab = .leftovers
                            app.select(.uninstaller)
                        }
                    }
                    if model.expanded == .junk { JunkDrawer(junk: app.junk) }
                    if model.expanded == .leftovers { LeftoversDrawer(uninstaller: app.uninstaller) }
                    TileRow {
                        OldFilesTile(model: model, oldFiles: app.oldFiles, digest: digest) { app.select(.oldFiles) }
                        UnusedAppsTile(digest: digest) {
                            app.uninstaller.tab = .apps
                            app.uninstaller.filter = .unused
                            app.select(.uninstaller)
                        }
                    }
                    .id(SmartCareModel.Area.oldFiles)
                    if model.expanded == .oldFiles { OldFilesDrawer(oldFiles: app.oldFiles) }
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.top, 18)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)
            // The lower row's list opens below the window's edge: bring its tile to the top.
            .onChange(of: model.expanded) { _, area in
                guard area == .oldFiles else { return }
                withAnimation(Theme.spring) { scroller.scrollTo(SmartCareModel.Area.oldFiles, anchor: .top) }
            }
            }

            ActionFooter(title: (model.includesTrash ? ConfirmCopy.Verb.deleteForever : .clean).button, tint: .smartCare,
                         enabled: count > 0, action: model.requestClean) {
                SelectionSummary(bytes: total, count: count)
            } trailing: {
                FooterNote(permanent: model.includesTrash)
            }
        }
        // Ticking inside a section (here or in its own module) turns its switch on; unticking everything, off.
        .onChange(of: app.junk.selectedCount) { model.selectionChanged(.junk, from: $0, to: $1) }
        .onChange(of: app.uninstaller.orphanSelection.count) { model.selectionChanged(.leftovers, from: $0, to: $1) }
        .onChange(of: app.oldFiles.selection.count) { model.selectionChanged(.oldFiles, from: $0, to: $1) }
    }
}

/// Two tiles side by side, as tall as the taller one.
private struct TileRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) { content }
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Nothing found anywhere: a calm result with two ways forward instead of a disabled round button.
private struct SmartCareAllClear: View {
    let onRescan: () -> Void
    let onOpenDiskMap: () -> Void
    let onGrantAccess: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            IconTile(symbol: "checkmark.seal.fill", tint: .smartCare, size: 64)
            Text("Mac в порядке")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Мусора, следов удалённых приложений и забытых файлов не нашли. Загляните позже — со временем они накопятся снова.")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(action: onRescan) { Label("Сканировать заново", systemImage: "arrow.clockwise") }
                    .buttonStyle(PillButtonStyle(kind: .primary(.smartCare)))
                Button("Открыть Карту диска", action: onOpenDiskMap)
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            }
            .padding(.top, 4)
            PartialAccessNote(onGrantAccess: onGrantAccess)
                .padding(.top, 6)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


// MARK: Lists under the tiles

private struct JunkDrawer: View {
    let junk: JunkModel

    var body: some View {
        VStack(spacing: 10) {
            SelectionBar(text: "Отмеченное попадёт в Корзину, остальное останется на месте",
                         onDefaults: junk.selectDefaults,
                         mode: Binding(get: { junk.mode }, set: { junk.select(mode: $0) }),
                         onNone: junk.selectNone)
            ForEach(junk.categories) { cat in
                JunkCategoryCard(model: junk, category: cat, tint: .smartCare)
            }
        }
        .transition(Theme.motion(.drawer))
    }
}

private struct LeftoversDrawer: View {
    let uninstaller: UninstallerModel
    @State private var open: Set<String> = []

    var body: some View {
        VStack(spacing: 10) {
            SelectionBar(text: "Следы приложений, которых уже нет. Сразу отмечены только точные совпадения",
                         onDefaults: uninstaller.selectDefaultOrphans, onNone: { uninstaller.orphanSelection = [] })
            ForEach(uninstaller.orphans) { g in
                ChoiceCard(state: uninstaller.orphanState(of: g), symbol: "app.dashed", tint: .uninstaller,
                           title: g.displayName, detail: Fmt.items(g.remnants.count), bytes: g.totalSize,
                           items: g.remnants, expanded: open.contains(g.id),
                           onToggle: { uninstaller.toggleOrphanGroup(g) }, onExpand: { open.formSymmetricDifference([g.id]) }) { r in
                    FileRow(url: r.item.url, size: r.item.size, isChecked: uninstaller.orphanSelection.contains(r.id),
                            tint: .smartCare, indent: 30, onToggle: { uninstaller.toggleOrphan(r) })
                }
            }
        }
        .transition(Theme.motion(.drawer))
    }
}

private struct OldFilesDrawer: View {
    let oldFiles: OldFilesModel
    @State private var open: Set<FileKind> = []

    var body: some View {
        VStack(spacing: 10) {
            SelectionBar(text: "Это ваши файлы — отметьте то, что больше не нужно", onNone: { oldFiles.selection = [] })
            ForEach(groups, id: \.kind) { g in
                ChoiceCard(state: CheckState(selected: oldFiles.selectedCount(in: g.files), total: g.files.count),
                           symbol: g.kind.symbol, tint: .oldFiles, title: g.kind.title, detail: Fmt.files(g.files.count),
                           bytes: g.size, items: g.files, expanded: open.contains(g.kind),
                           onToggle: { oldFiles.toggleAll(in: g.files) }, onExpand: { open.formSymmetricDifference([g.kind]) }) { f in
                    FileRow(url: f.item.url, size: f.item.size, isChecked: oldFiles.selection.contains(f.id),
                            tint: .smartCare, indent: 30, onToggle: { oldFiles.toggle(f) })
                }
            }
        }
        .transition(Theme.motion(.drawer))
    }

    /// Old files by kind, biggest kind first, biggest file first.
    private var groups: [(kind: FileKind, files: [AnalyzedFile], size: Int64)] {
        Dictionary(grouping: oldFiles.files, by: \.kind)
            .map { kind, files in
                (kind, files.sorted { $0.item.size > $1.item.size }, files.reduce(0) { $0 + $1.item.size })
            }
            .sorted { $0.size > $1.size }
    }
}

/// A checkable group (an app's leftovers, a kind of file) that opens to its files, like `JunkCategoryCard`.
private struct ChoiceCard<Item: Identifiable, Row: View>: View {
    let state: CheckState
    let symbol: String
    let tint: ModuleTint
    let title: String
    let detail: String
    let bytes: Int64
    let items: [Item]
    let expanded: Bool
    let onToggle: () -> Void
    let onExpand: () -> Void
    @ViewBuilder let row: (Item) -> Row
    @State private var hover = false

    private static var pageSize: Int { 200 }
    @State private var shown = 200

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                CheckBox(state: state, tint: .smartCare, label: title, action: onToggle)
                Button { withAnimation(Theme.unfold) { onExpand() } } label: {
                    HStack(spacing: 14) {
                        IconTile(symbol: symbol, tint: tint, size: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title)
                                .font(.cardTitle)
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Text(detail)
                                .font(.caption12)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 12)
                        SizeText(bytes: bytes, font: .system(size: 15, weight: .semibold, design: .rounded))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 16)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "развёрнуто" : "свёрнуто")
                .accessibilityHint("Показать или скрыть файлы")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(Rectangle().fill(.white.opacity(hover && !expanded ? 0.03 : 0)))
            .onHover { hover = $0 }

            if expanded {
                Hairline()
                LazyVStack(spacing: 0) {
                    ForEach(items.prefix(shown)) { row($0) }
                    if items.count > shown {
                        Button("Показать ещё \(Fmt.integer(min(Self.pageSize, items.count - shown)))") {
                            shown += Self.pageSize
                        }
                        .buttonStyle(PillButtonStyle(kind: .quiet))
                        .padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 4)
                .transition(.opacity)
            }
        }
        .glass(radius: 16, shadow: false)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct PreviewLine: View {
    let title: String
    let bytes: Int64

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.white.opacity(0.35)).frame(width: 4, height: 4)
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            SizeText(bytes: bytes, font: .system(size: 11.5, weight: .medium, design: .rounded), color: Theme.textTertiary)
        }
    }
}


// MARK: Tiles

private struct JunkTile: View {
    let model: SmartCareModel
    let junk: JunkModel
    let digest: SmartCareModel.Digest
    let onOpen: () -> Void

    var body: some View {
        let on = model.included.contains(.junk)
        let empty = junk.categories.isEmpty
        SmartTile(module: .junk, title: "Системный мусор", bytes: junk.totalSize,
                  caption: empty ? "Кэши и журналы в порядке"
                    : on ? "выбрано \(Fmt.size(junk.selectedSize))" : "не входит в очистку",
                  included: empty ? nil : on, onInclude: { model.setIncluded(.junk, $0) },
                  expanded: model.expanded == .junk, onExpand: empty ? nil : { model.toggleExpanded(.junk) },
                  opens: .junk, onOpen: onOpen) {
            ForEach(digest.junkTop) { PreviewLine(title: $0.title, bytes: $0.bytes) }
        }
    }
}

private struct LeftoversTile: View {
    let model: SmartCareModel
    let uninstaller: UninstallerModel
    let digest: SmartCareModel.Digest
    let onOpen: () -> Void

    var body: some View {
        let n = uninstaller.orphans.count
        let on = model.included.contains(.leftovers)
        SmartTile(module: .uninstaller, title: "Остатки удалённых приложений", bytes: digest.orphansBytes,
                  caption: n == 0 ? "Следов удалённых приложений не найдено"
                    : on ? "выбрано \(Fmt.size(uninstaller.selectedOrphansSize))"
                    : "\(Fmt.apps(n)) \(Fmt.verb(n, one: "оставило", other: "оставили")) после себя файлы",
                  included: n == 0 ? nil : on, onInclude: { model.setIncluded(.leftovers, $0) },
                  expanded: model.expanded == .leftovers, onExpand: n == 0 ? nil : { model.toggleExpanded(.leftovers) },
                  opens: .uninstaller, onOpen: onOpen) {
            ForEach(digest.orphanTop) { PreviewLine(title: $0.title, bytes: $0.bytes) }
        }
    }
}

private struct OldFilesTile: View {
    let model: SmartCareModel
    let oldFiles: OldFilesModel
    let digest: SmartCareModel.Digest
    let onOpen: () -> Void

    var body: some View {
        let n = digest.oldCount
        let on = model.included.contains(.oldFiles)
        SmartTile(module: .oldFiles, title: "Старые файлы", bytes: digest.oldBytes,
                  caption: n == 0 ? "Крупных забытых файлов нет"
                    : on ? "выбрано \(Fmt.size(oldFiles.selectedSize))"
                    : "\(Fmt.files(n)) \(Fmt.verb(n, one: "не открывался", other: "не открывались")) больше \(Fmt.months(oldFiles.months))",
                  included: n == 0 ? nil : on, onInclude: { model.setIncluded(.oldFiles, $0) },
                  expanded: model.expanded == .oldFiles, onExpand: n == 0 ? nil : { model.toggleExpanded(.oldFiles) },
                  opens: .oldFiles, onOpen: onOpen) {
            ForEach(digest.oldTop) { PreviewLine(title: $0.title, bytes: $0.bytes) }
        }
    }
}

/// Removing apps is a decision of its own: this tile only leads to the uninstaller.
private struct UnusedAppsTile: View {
    let digest: SmartCareModel.Digest
    let onOpen: () -> Void

    var body: some View {
        let n = digest.unusedCount
        SmartTile(module: .uninstaller, symbol: "app.badge.fill", title: "Неиспользуемые приложения",
                  bytes: digest.unusedBytes,
                  caption: n == 0
                    ? "Все приложения в ходу"
                    : "\(Fmt.apps(n)) \(Fmt.verb(n, one: "не открывалось", other: "не открывались")) больше \(Fmt.months(6))",
                  showsChoiceBadge: true, opens: .uninstaller, onOpen: onOpen) {
            HStack(spacing: 6) {
                ForEach(digest.unusedTop) { a in
                    Image(nsImage: IconCache.icon(for: a.url)).resizable().interpolation(.high)
                        .frame(width: 30, height: 30)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                }
            }
            .padding(.top, 4)
        }
    }
}

private struct SmartTile<Preview: View>: View {
    let module: AppModule
    var symbol: String? = nil
    let title: String
    let bytes: Int64
    let caption: String
    /// The «входит в очистку» switch; nil hides it (nothing found).
    var included: Bool? = nil
    var onInclude: (Bool) -> Void = { _ in }
    /// «На ваш выбор» instead of a switch: the tile only leads to its section.
    var showsChoiceBadge = false
    var expanded = false
    /// Opens the list under the tile; nil when there is nothing to choose from.
    var onExpand: (() -> Void)? = nil
    let opens: AppModule
    let onOpen: () -> Void
    @ViewBuilder var preview: Preview
    @State private var hover = false

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity, alignment: .topLeading)
            .glass(radius: 18, intensity: hover || expanded ? 1.4 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(module.tint.accent.opacity(expanded ? 0.55 : 0), lineWidth: 1.25)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18))
            // The whole tile opens its list (or, without one, its section); the switch and links keep their own clicks.
            .onTapGesture { (onExpand ?? onOpen)() }
            .onHover { hover = $0 }
            .animation(Theme.quick, value: hover)
            .accessibilityElement(children: .contain)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                IconTile(symbol: symbol ?? module.symbol, tint: module.tint, size: 40)
                Spacer()
                if let included {
                    Toggle("Входит в очистку", isOn: Binding(get: { included }, set: onInclude))
                        .toggleStyle(TintSwitchStyle(tint: module.tint))
                        .help(included ? "Входит в очистку — выключите, чтобы не трогать" : "Не входит в очистку — включите, чтобы очистить")
                        .accessibilityLabel("\(title): входит в очистку")
                } else if showsChoiceBadge {
                    Badge(text: "На ваш выбор", color: .white.opacity(0.7), symbol: "hand.point.up.left.fill")
                }
            }
            Text(title)
                .font(.cardTitle)
                .foregroundStyle(Theme.text)
                .padding(.top, 14)
            BigSize(bytes: bytes, size: 34, weight: .light)
                .padding(.top, 2)
            Text(caption)
                .font(.caption12)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.top, 2)
            // Stays while the list is open: the tile keeps its height instead of jumping.
            VStack(alignment: .leading, spacing: 5) { preview }
                .padding(.top, 12)
            Spacer(minLength: 10)
            HStack(spacing: 4) {
                if let onExpand {
                    Button(action: onExpand) {
                        HStack(spacing: 5) {
                            Text(expanded ? "Свернуть" : "Выбрать, что очистить")
                                .contentTransition(.identity)   // a swap, not two labels fading over each other
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 8)
                    Button(action: onOpen) {
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Открыть раздел «\(opens.sidebarTitle)»")
                    .accessibilityLabel("Открыть раздел «\(opens.sidebarTitle)»")
                } else {
                    Button(action: onOpen) {
                        HStack(spacing: 4) {
                            Text("Откроется в разделе «\(opens.sidebarTitle)»").lineLimit(1)
                            Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
                                .offset(x: hover ? 3 : 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(module.tint.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
