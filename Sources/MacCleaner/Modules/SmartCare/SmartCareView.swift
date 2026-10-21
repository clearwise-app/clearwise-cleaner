import SwiftUI
import CleanerKit

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
                        onAction: model.startScan, onStop: model.stop, dimsOptionsWhileWorking: false,
                        onGrantAccess: { app.presentAccessSheet() }) {
                DiskCapsule(disk: app.disk)
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
            overview(junk: junk, digest: digest)
        }
    }

    private func overview(junk: JunkModel, digest: SmartCareModel.Digest) -> some View {
        GeometryReader { geo in
        let compact = geo.size.height < 780
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.system(size: 11, weight: .bold))
                        Text("УМНАЯ ОЧИСТКА").font(.system(size: 11, weight: .bold)).tracking(0.8)
                    }
                    .foregroundStyle(ModuleTint.smartCare.accent)
                    BigSize(bytes: junk.selectedSize, size: compact ? 52 : 64)
                        .padding(.top, 2)
                    Text(model.reviewing
                         ? "выбрано для очистки · ещё \(Fmt.size(max(0, junk.totalSize - junk.selectedSize))) не выбрано"
                         : junk.selectedSize > 0
                         ? "можно очистить прямо сейчас — только безопасный мусор"
                         : "безопасного мусора не найдено — загляните в разделы ниже")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                    PartialAccessNote(onGrantAccess: { app.presentAccessSheet() })
                        .padding(.top, 6)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    DiskCapsule(disk: app.disk)
                    if model.reviewing {
                        Button { model.closeReview() } label: { Label("Назад к обзору", systemImage: "chevron.left") }
                            .buttonStyle(PillButtonStyle(kind: .quiet))
                    } else {
                        Button { model.startScan() } label: { Label("Сканировать заново", systemImage: "arrow.clockwise") }
                            .buttonStyle(PillButtonStyle(kind: .quiet))
                    }
                }
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.top, 30)

            if model.reviewing {
                SmartCareReview(junk: junk)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
            Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    JunkTile(junk: junk, digest: digest, showsPreview: !compact) { app.select(.junk) }
                    LeftoversTile(uninstaller: app.uninstaller, digest: digest, showsPreview: !compact) {
                        app.uninstaller.tab = .leftovers
                        app.select(.uninstaller)
                    }
                }
                GridRow {
                    OldFilesTile(oldFiles: app.oldFiles, digest: digest, showsPreview: !compact) { app.select(.oldFiles) }
                    UnusedAppsTile(oldFiles: app.oldFiles, digest: digest, showsPreview: !compact) {
                        app.uninstaller.tab = .apps
                        app.uninstaller.filter = .unused
                        app.select(.uninstaller)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.top, compact ? 18 : 26)
            .transition(.opacity)

            Spacer(minLength: 10)
            }

            if model.reviewing {
                ActionFooter(title: junk.cleanVerb.button, tint: .smartCare, enabled: junk.selectedCount > 0, action: model.requestClean) {
                    SelectionSummary(bytes: junk.selectedSize, count: junk.selectedCount)
                } trailing: {
                    VStack(alignment: .trailing, spacing: 3) {
                        if junk.includesTrash { FooterNote(permanent: true) }
                        Text("Не выбрано")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                        SizeText(bytes: max(0, junk.totalSize - junk.selectedSize), font: .number(24, weight: .light))
                    }
                }
            } else {
                ActionFooter(title: "Проверить", tint: .smartCare, enabled: !junk.categories.isEmpty, action: model.openReview) {
                    SelectionSummary(bytes: junk.selectedSize, count: junk.selectedCount, label: "Безопасно очистить")
                } trailing: {
                    Label("Дальше вы выберете, что очистить, а что оставить", systemImage: "hand.raised.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        }
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

/// Step 2 of Smart Care: every junk category with its size and a keep/delete choice per category and per file.
private struct SmartCareReview: View {
    let junk: JunkModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Отмеченное попадёт в Корзину, остальное останется на месте", systemImage: "checklist")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Только безопасное") { junk.selectSafeOnly() }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                Button("Снять всё") { junk.selectNone() }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.top, 18)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(junk.categories) { cat in
                        JunkCategoryCard(model: junk, category: cat, tint: .smartCare)
                    }
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.automatic)
        }
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
    let junk: JunkModel
    let digest: SmartCareModel.Digest
    let showsPreview: Bool
    let onOpen: () -> Void

    var body: some View {
        SmartTile(module: .junk, title: "Системный мусор", bytes: junk.totalSize,
                  caption: junk.totalSize > 0
                    ? "из них \(Fmt.size(junk.selectedSize)) — безопасно и выбрано"
                    : "Кэши и журналы в порядке",
                  included: junk.selectedSize > 0, showsPreview: showsPreview, onOpen: onOpen) {
            ForEach(digest.junkTop) { PreviewLine(title: $0.title, bytes: $0.bytes) }
        }
    }
}

private struct LeftoversTile: View {
    let uninstaller: UninstallerModel
    let digest: SmartCareModel.Digest
    let showsPreview: Bool
    let onOpen: () -> Void

    var body: some View {
        let n = uninstaller.orphans.count
        SmartTile(module: .uninstaller, title: "Остатки удалённых приложений", bytes: digest.orphansBytes,
                  caption: n == 0
                    ? "Следов удалённых приложений не найдено"
                    : "\(Fmt.apps(n)) \(Fmt.verb(n, one: "оставило", other: "оставили")) после себя файлы",
                  included: false, opens: .uninstaller, showsPreview: showsPreview, onOpen: onOpen) {
            ForEach(digest.orphanTop) { PreviewLine(title: $0.title, bytes: $0.bytes) }
        }
    }
}

private struct OldFilesTile: View {
    let oldFiles: OldFilesModel
    let digest: SmartCareModel.Digest
    let showsPreview: Bool
    let onOpen: () -> Void

    var body: some View {
        let n = digest.oldCount
        SmartTile(module: .oldFiles, title: "Старые файлы", bytes: digest.oldBytes,
                  caption: n == 0
                    ? "Крупных забытых файлов нет"
                    : "\(Fmt.files(n)) \(Fmt.verb(n, one: "не открывался", other: "не открывались")) больше \(Fmt.months(oldFiles.months))",
                  included: false, opens: .oldFiles, showsPreview: showsPreview, onOpen: onOpen) {
            ForEach(digest.oldTop) { PreviewLine(title: $0.title, bytes: $0.bytes) }
        }
    }
}

private struct UnusedAppsTile: View {
    let oldFiles: OldFilesModel
    let digest: SmartCareModel.Digest
    let showsPreview: Bool
    let onOpen: () -> Void

    var body: some View {
        let n = digest.unusedCount
        SmartTile(module: .uninstaller, symbol: "app.badge.fill", title: "Неиспользуемые приложения",
                  bytes: digest.unusedBytes,
                  caption: n == 0
                    ? "Все приложения в ходу"
                    : "\(Fmt.apps(n)) \(Fmt.verb(n, one: "не открывалось", other: "не открывались")) больше \(Fmt.months(6))",
                  included: false, opens: .uninstaller, showsPreview: showsPreview, onOpen: onOpen) {
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
    let included: Bool
    /// The section a tile that is not part of the cleaning leads to: «Откроется в разделе «…»».
    var opens: AppModule? = nil
    var showsPreview = true
    let onOpen: () -> Void
    @ViewBuilder var preview: Preview
    @State private var hover = false

    private var openText: String {
        opens.map { "Откроется в разделе «\($0.sidebarTitle)»" } ?? "Просмотреть"
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    IconTile(symbol: symbol ?? module.symbol, tint: module.tint, size: 40)
                    Spacer()
                    if included {
                        Badge(text: "Входит в очистку", color: Theme.success, symbol: "checkmark")
                    } else {
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
                if showsPreview {
                    VStack(alignment: .leading, spacing: 5) { preview }
                        .padding(.top, 12)
                }
                Spacer(minLength: 10)
                HStack(spacing: 4) {
                    Text(openText)
                        .lineLimit(1)
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
                        .offset(x: hover ? 3 : 0)
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(module.tint.accent)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 196, maxHeight: .infinity, alignment: .topLeading)
            .glass(radius: 18, intensity: hover ? 1.4 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hover = $0 }
        .animation(Theme.quick, value: hover)
    }
}
