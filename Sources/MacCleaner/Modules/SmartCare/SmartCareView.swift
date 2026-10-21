import SwiftUI
import CleanerKit

struct SmartCareView: View {
    let model: SmartCareModel
    @Environment(AppModel.self) private var app

    var body: some View {
        switch model.phase {
        case .idle, .scanning:
            ModuleStage(module: .smartCare,
                        state: model.phase == .scanning
                            ? .progress(ScanProgress(phase: phaseText, fraction: model.fraction, currentPath: model.currentPath))
                            : .idle(button: "Сканировать", enabled: true),
                        onAction: model.startScan, onStop: model.stop, dimsOptionsWhileWorking: false) {
                DiskCapsule(disk: app.disk)
            } options: {
                AreaPills(model: model, scanning: model.phase == .scanning)
            }
        case .results:
            SmartCareResults(model: model)
        case .cleaning:
            ModuleStage(module: .smartCare, title: "Очистка", subtitle: "Убираем выбранный системный мусор…",
                        state: .busy("Файлы перемещаются в Корзину"))
        case .done:
            CompletionView(tint: .smartCare, result: model.result ?? RemovalResult(), title: "Mac стал чище",
                           permanent: false, onDone: model.finish)
        }
    }

    private var phaseText: String {
        let active = model.areas.filter { !$0.done }
        return active.isEmpty ? "Завершаем" : "Проверяем: " + active.map { $0.title.lowercased() }.joined(separator: ", ")
    }
}

/// What Smart Care checks; turns into live status while scanning.
private struct AreaPills: View {
    let model: SmartCareModel
    let scanning: Bool

    var body: some View {
        HStack(spacing: 10) {
            ForEach(model.areas, id: \.title) { area in
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
                .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.75))
            }
        }
    }
}

private struct SmartCareResults: View {
    let model: SmartCareModel
    @Environment(AppModel.self) private var app

    var body: some View {
        let junk = app.junk
        let un = app.uninstaller
        let old = app.oldFiles
        let unused = un.unusedApps
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
                    Text(junk.selectedSize > 0
                         ? "можно освободить прямо сейчас — только безопасный мусор"
                         : "безопасного мусора не найдено — загляните в разделы ниже")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    DiskCapsule(disk: app.disk)
                    Button { model.startScan() } label: { Label("Сканировать заново", systemImage: "arrow.clockwise") }
                        .buttonStyle(PillButtonStyle(kind: .quiet))
                }
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.top, 30)

            Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    SmartTile(module: .junk, title: "Системный мусор", bytes: junk.totalSize,
                              caption: junk.totalSize > 0
                                ? "из них \(Fmt.size(junk.selectedSize)) — безопасно и выбрано"
                                : "Кэши и журналы в порядке",
                              included: junk.selectedSize > 0, showsPreview: !compact) {
                        app.select(.junk)
                    } preview: {
                        ForEach(junk.categories.prefix(3)) { c in PreviewLine(title: c.title, bytes: c.totalSize) }
                    }
                    SmartTile(module: .uninstaller, title: "Остатки удалённых приложений", bytes: un.orphansSize,
                              caption: un.orphans.isEmpty
                                ? "Следов удалённых приложений не найдено"
                                : "\(Fmt.apps(un.orphans.count).capitalizedFirst) оставили после себя файлы",
                              included: false, showsPreview: !compact) {
                        un.tab = .leftovers
                        app.select(.uninstaller)
                    } preview: {
                        ForEach(un.orphans.prefix(3)) { g in PreviewLine(title: g.displayName, bytes: g.totalSize) }
                    }
                }
                GridRow {
                    SmartTile(module: .oldFiles, title: "Давно не открывались", bytes: old.totalSize,
                              caption: old.files.isEmpty
                                ? "Крупных забытых файлов нет"
                                : "\(Fmt.files(old.files.count).capitalizedFirst) не открывались больше \(old.months) мес.",
                              included: false, showsPreview: !compact) {
                        app.select(.oldFiles)
                    } preview: {
                        ForEach(old.files.sorted { $0.item.size > $1.item.size }.prefix(3)) { f in
                            PreviewLine(title: f.item.name, bytes: f.item.size)
                        }
                    }
                    SmartTile(module: .diskMap, symbol: "app.badge.fill", title: "Неиспользуемые приложения",
                              bytes: unused.reduce(0) { $0 + $1.size },
                              caption: unused.isEmpty
                                ? "Все приложения в ходу"
                                : "\(Fmt.apps(unused.count).capitalizedFirst) не открывались полгода и дольше",
                              included: false, showsPreview: !compact) {
                        un.tab = .apps
                        un.filter = .unused
                        app.select(.uninstaller)
                    } preview: {
                        HStack(spacing: 6) {
                            ForEach(unused.sorted { $0.size > $1.size }.prefix(7)) { a in
                                Image(nsImage: IconCache.icon(for: a.url)).resizable().interpolation(.high)
                                    .frame(width: 30, height: 30)
                                    .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.top, compact ? 18 : 26)

            Spacer(minLength: 10)

            ActionFooter(title: "Очистить", tint: .smartCare, enabled: junk.selectedCount > 0, action: model.requestClean) {
                SelectionSummary(bytes: junk.selectedSize, count: junk.selectedCount, label: "Будет очищено")
            } trailing: {
                Label("Остальное — только после вашего просмотра", systemImage: "hand.raised.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
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

private struct SmartTile<Preview: View>: View {
    let module: AppModule
    var symbol: String? = nil
    let title: String
    let bytes: Int64
    let caption: String
    let included: Bool
    var showsPreview = true
    let onOpen: () -> Void
    @ViewBuilder var preview: Preview
    @State private var hover = false

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
                    .padding(.top, 2)
                if showsPreview {
                    VStack(alignment: .leading, spacing: 5) { preview }
                        .padding(.top, 12)
                }
                Spacer(minLength: 10)
                HStack(spacing: 4) {
                    Text("Просмотреть")
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
