import SwiftUI
import HealthEngine

struct HealthView: View {
    let model: HealthModel

    var body: some View {
        if model.phase == .results, let report = model.report {
            HealthResults(model: model, report: report)
        } else {
            ModuleStage(module: .health,
                        state: model.phase == .checking ? .busy(String(localized: "Проверяем аккумулятор, диск и программы…"))
                                                        : .idle(button: String(localized: "Проверить"), enabled: true),
                        onAction: model.startCheck)
        }
    }
}

// MARK: - Results

private struct HealthResults: View {
    let model: HealthModel
    let report: MacHealthReport

    private var cards: [AnyView] {
        var list: [AnyView] = []
        if let b = report.battery { list.append(AnyView(BatteryCard(model: model, battery: b))) }
        if let d = report.drive { list.append(AnyView(DriveCard(model: model, drive: d))) }
        if let s = report.space { list.append(AnyView(SpaceCard(model: model, space: s))) }
        if let v = report.vitals { list.append(AnyView(MemoryCard(model: model, vitals: v))) }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    // Intel-only apps are the one thing the user can act on: first when there are any.
                    let intelFirst = report.architectures.map { !$0.intelOnly.isEmpty } ?? false
                    if intelFirst, let a = report.architectures { IntelAppsCard(model: model, report: a) }
                    // Two cards per row, both as tall as the taller one.
                    Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                        ForEach(Array(stride(from: 0, to: cards.count, by: 2)), id: \.self) { i in
                            GridRow(alignment: .top) {
                                cards[i]
                                if i + 1 < cards.count { cards[i + 1] } else { Color.clear.gridCellUnsizedAxes(.vertical) }
                            }
                        }
                    }
                    if !intelFirst, let a = report.architectures { IntelAppsCard(model: model, report: a) }
                    Label("Только чтение: эта проверка ничего не удаляет и не меняет. Данные не покидают Mac.",
                          systemImage: "lock.shield")
                        .font(.caption12)
                        .foregroundStyle(.themeTertiary)
                        .padding(.top, 4)
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.top, 22)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.automatic)
        }
    }

    private var header: some View {
        let concerns = report.concerns
        return HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: AppModule.health.symbol).font(.system(size: 11, weight: .bold))
                    Text(AppModule.health.title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.8)
                }
                .foregroundStyle(AppModule.health.tint.accent)
                Text(concerns.isEmpty ? "Всё в порядке" : "Есть на что взглянуть")
                    .font(.number(46, weight: .light))
                    .foregroundStyle(Theme.text)
                    .padding(.top, 2)
                Text(HealthCopy.summary(concerns, checkedAt: report.measuredAt))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { model.startCheck() } label: {
                Label("Проверить снова", systemImage: "arrow.clockwise")
            }
            .buttonStyle(PillButtonStyle(kind: .secondary))
            .disabled(model.phase == .checking)
            .padding(.bottom, 6)
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.top, 30)
    }
}

// MARK: - Cards

private struct BatteryCard: View {
    let model: HealthModel
    let battery: BatteryHealth

    var body: some View {
        GaugeCard(id: "battery", model: model, symbol: "battery.100percent", title: String(localized: "Аккумулятор"),
                  gauge: battery.maximumCapacityPercent.map { Double($0) / 100 }, gaugeCaption: String(localized: "ёмкость"),
                  tone: tone, verdict: verdict, explanation: explanation, facts: facts,
                  details: details, note: HealthCopy.battery)
    }

    private var needsService: Bool { battery.condition.map { $0 != .normal } ?? false }

    private var tone: GaugeTone {
        if needsService { return .bad }
        if let p = battery.maximumCapacityPercent, p < 80 { return .watch }
        return .good
    }

    private var verdict: String {
        if needsService { return String(localized: "Пора менять") }
        guard let p = battery.maximumCapacityPercent else { return String(localized: "Работает нормально") }
        if p >= 90 { return String(localized: "Отличное состояние") }
        if p >= 80 { return String(localized: "Хорошее состояние") }
        return String(localized: "Заметно изношен")
    }

    private var explanation: String {
        if needsService { return String(localized: "macOS рекомендует заменить аккумулятор в сервисе.") }
        guard let p = battery.maximumCapacityPercent else { return String(localized: "macOS не сообщает о неполадках.") }
        return String(localized: "Полностью заряженный, он держит \(Fmt.percent(Double(p) / 100)) от того, что держал новым.")
    }

    private var facts: [GaugeFact] {
        var list: [GaugeFact] = []
        if let charge = battery.chargePercent {
            let source = battery.isCharging ? String(localized: "заряжается") : (battery.isPluggedIn ? String(localized: "от сети") : String(localized: "от батареи"))
            list.append(GaugeFact(label: String(localized: "Заряд сейчас"), value: "\(charge)\(Fmt.nbsp)% · \(source)", fill: Double(charge) / 100))
        }
        let cycles = battery.cycleCount
        if let rated = battery.designCycleCount, rated > 0 {
            list.append(GaugeFact(label: String(localized: "Циклы зарядки"), value: String(localized: "\(Fmt.integer(cycles)) из \(Fmt.integer(rated))"),
                                  fill: min(1, Double(cycles) / Double(rated))))
        } else {
            list.append(GaugeFact(label: String(localized: "Циклы зарядки"), value: Fmt.integer(cycles), fill: nil))
        }
        return list
    }

    private var details: [HealthRow] {
        var list: [HealthRow] = []
        if let full = battery.fullChargeCapacity, let design = battery.designCapacity {
            list.append(HealthRow(String(localized: "Ёмкость по контроллеру"), String(localized: "\(Fmt.integer(full)) из \(Fmt.integer(design)) мА·ч")))
        }
        if let t = battery.temperatureCelsius {
            list.append(HealthRow(String(localized: "Температура"), "\(Fmt.number(t, digits: 1))\(Fmt.nbsp)°C"))
        }
        return list
    }
}

private struct DriveCard: View {
    let model: HealthModel
    let drive: DriveHealth

    /// What is left of the SSD's rated write endurance (NVMe reports what is used up).
    private var lifeLeft: Int? { drive.nvme?.percentageUsed.map { max(0, 100 - $0) } }
    private var failing: Bool { drive.smart == .failing }
    private var spareLow: Bool { drive.nvme?.spareBelowThreshold == true }

    var body: some View {
        GaugeCard(id: "drive", model: model, symbol: "internaldrive.fill", title: String(localized: "Диск"),
                  gauge: lifeLeft.map { Double($0) / 100 }, gaugeCaption: String(localized: "ресурс"),
                  tone: tone, verdict: verdict, explanation: explanation, facts: facts,
                  details: details, note: HealthCopy.drive)
    }

    private var tone: GaugeTone {
        if failing || spareLow { return .bad }
        if let left = lifeLeft, left < 20 { return .watch }
        return .good
    }

    private var verdict: String {
        if failing { return String(localized: "Диск сообщает о сбое") }
        if spareLow { return String(localized: "Резерв на исходе") }
        guard let left = lifeLeft else {
            return drive.smart == .verified ? String(localized: "Неполадок нет") : String(localized: "Нет данных о здоровье")
        }
        if left >= 90 { return String(localized: "Отличное состояние") }
        if left >= 50 { return String(localized: "Хорошее состояние") }
        if left > 0 { return String(localized: "Заметный износ") }
        return String(localized: "Ресурс выработан")
    }

    private var explanation: String {
        if failing || spareLow { return String(localized: "Сохраните важные файлы на другой диск и обратитесь в сервис.") }
        if let left = lifeLeft {
            if left == 0 { return String(localized: "Это расчёт производителя, а не дата отказа. Держите резервную копию.") }
            return String(localized: "Осталось \(Fmt.percent(Double(left) / 100)) ресурса, который производитель закладывает на запись.")
        }
        return drive.smart == .verified ? String(localized: "Самопроверка диска не нашла неполадок.") : String(localized: "Этот Mac не сообщает данные о здоровье диска.")
    }

    private var facts: [GaugeFact] {
        var list: [GaugeFact] = []
        if let total = drive.containerTotal, let free = drive.containerFree, total > 0 {
            let used = max(0, total - free)
            list.append(GaugeFact(label: String(localized: "Занято"), value: String(localized: "\(Fmt.size(used)) из \(Fmt.size(total))"),
                                  fill: Double(used) / Double(total)))
        }
        if let written = drive.nvme?.bytesWritten {
            list.append(GaugeFact(label: String(localized: "Записано за всё время"), value: Fmt.size(written), fill: nil))
        }
        return list
    }

    private var details: [HealthRow] {
        var list: [HealthRow] = []
        if let m = drive.model { list.append(HealthRow(String(localized: "Модель"), m)) }
        list.append(HealthRow(String(localized: "Самопроверка (SMART)"), HealthCopy.smart(drive.smart)))
        guard let n = drive.nvme else { return list }
        if let used = n.percentageUsed { list.append(HealthRow(String(localized: "Израсходовано ресурса"), "\(used)\(Fmt.nbsp)%")) }
        if let read = n.bytesRead { list.append(HealthRow(String(localized: "Прочитано за всё время"), Fmt.size(read))) }
        if let spare = n.availableSpare { list.append(HealthRow(String(localized: "Резервные блоки"), Fmt.percent(Double(spare) / 100))) }
        if let h = n.powerOnHours { list.append(HealthRow(String(localized: "Наработка"), HealthCopy.hours(h))) }
        if let t = n.temperatureCelsius { list.append(HealthRow(String(localized: "Температура"), "\(Fmt.integer(t))\(Fmt.nbsp)°C")) }
        if let e = n.mediaErrors { list.append(HealthRow(String(localized: "Ошибки носителя"), Fmt.integer(e))) }
        if let u = n.unsafeShutdowns { list.append(HealthRow(String(localized: "Внезапные выключения"), Fmt.integer(u))) }
        return list
    }
}

private struct SpaceCard: View {
    let model: HealthModel
    let space: SpaceReport

    var body: some View {
        let parts = Fmt.sizeParts(space.freeNow)
        HealthCard(id: "space", model: model, symbol: "externaldrive.fill.badge.timemachine", title: String(localized: "Свободное место"),
                   status: nil,
                   metric: HealthMetric(value: parts.value, unit: parts.unit, caption: String(localized: "свободно прямо сейчас")),
                   rows: rows, details: details, note: HealthCopy.space)
    }

    private var rows: [HealthRow] {
        [
            HealthRow(String(localized: "Finder показывает свободным"), Fmt.size(space.availableWithPurgeable)),
            HealthRow(String(localized: "Из них освободит macOS"), Fmt.size(space.purgeable)),
            HealthRow(String(localized: "Снимки Time Machine на диске"), space.snapshots.isEmpty ? String(localized: "нет") : Fmt.integer(space.snapshots.count)),
        ]
    }

    private var details: [HealthRow] {
        space.snapshots.prefix(12).map { s in
            HealthRow(s.date.map(HealthCopy.dateTime) ?? String(localized: "Снимок"), s.date == nil ? s.name : "Time Machine")
        }
    }
}

private struct MemoryCard: View {
    let model: HealthModel
    let vitals: SystemVitals

    var body: some View {
        HealthCard(id: "memory", model: model, symbol: "memorychip.fill", title: String(localized: "Память"),
                   status: status,
                   metric: HealthMetric(value: pressureWord, unit: nil,
                                        caption: String(localized: "давление памяти — как в Мониторе системы"), isWord: true),
                   rows: rows, details: [], note: HealthCopy.memory)
    }

    private var status: HealthStatus? {
        switch vitals.memoryPressure {
        case .normal: .ok
        case .warning: .warning(String(localized: "Повышенное"))
        case .critical: .danger(String(localized: "Высокое"))
        case .unknown: nil
        }
    }

    private var pressureWord: String {
        switch vitals.memoryPressure {
        case .normal: String(localized: "Нормальное")
        case .warning: String(localized: "Повышенное")
        case .critical: String(localized: "Высокое")
        case .unknown: String(localized: "Нет данных")
        }
    }

    private var rows: [HealthRow] {
        // RAM is sold and shown by Apple in binary gigabytes: 16 ГБ, not 17,2.
        let ram = Double(vitals.physicalMemory) / 1_073_741_824
        var list = [HealthRow(String(localized: "Оперативная память"), "\(Fmt.number(ram, digits: ram.rounded() == ram ? 0 : 1))\(Fmt.nbsp)" + String(localized: "ГБ"))]
        if let swap = vitals.swapUsed { list.append(HealthRow(String(localized: "Своп на диске"), swap > 0 ? Fmt.size(swap) : String(localized: "не используется"))) }
        if let boot = vitals.bootTime { list.append(HealthRow(String(localized: "Без перезагрузки"), HealthCopy.uptime(since: boot, now: Date()))) }
        return list
    }
}

private struct IntelAppsCard: View {
    let model: HealthModel
    let report: ArchitectureReport

    var body: some View {
        let intel = report.intelOnly
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                IconTile(symbol: "cpu.fill", tint: .health, size: 30)
                Text("Программы только для Intel")
                    .font(.cardTitle)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                StatusBadge(status: intel.isEmpty ? .ok : .warning(String(localized: "Проверьте")))
            }
            if intel.isEmpty {
                // Nothing to act on: one line instead of a big zero, then which apps that verdict covers.
                Text(HealthCopy.intelCaption(intel: 0, total: report.apps.count).capitalizedFirst)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                if !report.apps.isEmpty {
                    CheckedAppsList(apps: report.apps)
                        .padding(.top, 14)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    MetricText(metric: HealthMetric(value: Fmt.integer(intel.count), unit: nil, caption: ""))
                    Text(HealthCopy.intelCaption(intel: intel.count, total: report.apps.count))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 10)
            }

            if !intel.isEmpty {
                Text(HealthCopy.rosetta)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                VStack(spacing: 0) {
                    ForEach(intel) { app in
                        if app.id != intel.first?.id { Hairline(inset: 40) }
                        IntelAppRow(app: app)
                    }
                }
                .padding(.top, 12)
            }

            Text("Универсальных: \(Fmt.integer(report.universalCount)) · только для Apple silicon: \(Fmt.integer(report.appleSiliconOnlyCount)) · программы macOS не учитываются")
                .font(.caption11)
                .foregroundStyle(.themeTertiary)
                .padding(.top, intel.isEmpty ? 6 : 12)
        }
        .padding(18)
        .glass(radius: 16, shadow: false)
    }
}

/// Every app the check looked at, five at a time; «Показать все» unfolds the rest in place.
private struct CheckedAppsList: View {
    let apps: [AppArchitecture]
    @State private var showsAll = false
    private static let preview = 5

    var body: some View {
        let sorted = apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let shown = showsAll ? sorted : Array(sorted.prefix(Self.preview))
        VStack(alignment: .leading, spacing: 0) {
            Text("Проверенные программы")
                .font(.label11)
                .foregroundStyle(.themeTertiary)
            VStack(spacing: 0) {
                ForEach(shown) { app in
                    if app.id != shown.first?.id { Hairline(inset: 40) }
                    IntelAppRow(app: app)
                }
            }
            .padding(.top, 4)
            if sorted.count > Self.preview {
                Button(showsAll ? "Свернуть" : "Показать все (\(Fmt.integer(sorted.count)))") {
                    withAnimation(Theme.unfold) { showsAll.toggle() }
                }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                .padding(.top, 6)
            }
        }
    }
}

private struct IntelAppRow: View {
    let app: AppArchitecture
    @State private var hover = false

    /// «Intel (x86_64)», «Универсальная (arm64, x86_64)» or «Apple silicon (arm64)».
    private var architecture: String {
        let names = app.architectures.sorted().map(\.title).joined(separator: ", ")
        if app.isIntelOnly { return "Intel (\(names))" }
        if app.isUniversal { return String(localized: "Универсальная (\(names))") }
        return "Apple silicon (\(names))"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.icon(for: app.url))
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.rowTitle)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text([app.version.map { String(localized: "Версия \($0)") }, architecture]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption11)
                    .foregroundStyle(.themeTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            IconButton(symbol: "magnifyingglass", help: String(localized: "Показать в Finder")) { Finder.reveal(app.url) }
                .opacity(hover ? 1 : 0.7)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Card building blocks

private enum HealthStatus: Equatable {
    case ok, warning(String), danger(String)
}

private struct HealthMetric {
    let value: String
    let unit: String?
    let caption: String
    /// A word ("Проверен") instead of a number: a smaller face so it fits the half-width card.
    var isWord = false
}

private struct HealthRow: Identifiable {
    let label: String
    let value: String
    var id: String { label + value }
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

private struct StatusBadge: View {
    let status: HealthStatus

    var body: some View {
        switch status {
        case .ok: Badge(text: String(localized: "Норма"), color: RiskBadge.safeFill, symbol: "checkmark.circle.fill")
        case .warning(let t): Badge(text: t, color: RiskBadge.reviewFill, symbol: "eye.fill")
        case .danger(let t): Badge(text: t, color: RiskBadge.cautionFill, symbol: "exclamationmark.triangle.fill")
        }
    }
}

private struct MetricText: View {
    let metric: HealthMetric

    var body: some View {
        let size: CGFloat = metric.isWord ? 30 : 48
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(metric.value)
                .font(.number(size, weight: metric.isWord ? .light : .thin))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            if let unit = metric.unit {
                Text(unit)
                    .font(.number(size * 0.42, weight: .light))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .combine)
    }
}

private enum GaugeTone {
    case good, watch, bad
    var color: Color {
        switch self {
        case .good: AppModule.health.tint.accent
        case .watch: Theme.warning
        case .bad: Theme.danger
        }
    }
}

private struct GaugeFact: Identifiable {
    let label: String
    let value: String
    /// 0…1 for a thin bar under the fact; nil = no bar.
    let fill: Double?
    var id: String { label }
}

/// Battery and disk: a ring with what is left, a verdict in words and one plain sentence, then two facts with
/// bars. Numbers to decode («87 % максимальной ёмкости», «3 % износа») stay in «Подробнее».
private struct GaugeCard: View {
    let id: String
    let model: HealthModel
    let symbol: String
    let title: String
    /// What is left (0…1); nil shows the card's symbol in the ring instead.
    let gauge: Double?
    let gaugeCaption: String
    let tone: GaugeTone
    let verdict: String
    let explanation: String
    let facts: [GaugeFact]
    let details: [HealthRow]
    let note: String

    var body: some View {
        let open = model.expanded.contains(id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, tint: .health, size: 30)
                Text(title).font(.cardTitle).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }

            HStack(alignment: .center, spacing: 18) {
                ring
                VStack(alignment: .leading, spacing: 5) {
                    Text(verdict)
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .foregroundStyle(tone == .good ? Theme.text : tone.color)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text(explanation)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 16)
            .accessibilityElement(children: .combine)

            VStack(spacing: 12) {
                ForEach(facts) { fact in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(fact.label).foregroundStyle(Theme.textSecondary)
                            Spacer(minLength: 8)
                            Text(fact.value).foregroundStyle(Theme.text).monospacedDigit()
                        }
                        .font(.system(size: 12.5))
                        if let fill = fact.fill {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.text.opacity(0.08))
                                    Capsule().fill(AppModule.health.tint.accent.opacity(0.85))
                                        .frame(width: max(4, geo.size.width * min(1, max(0, fill))))
                                }
                            }
                            .frame(height: 5)
                            .accessibilityHidden(true)
                        } else {
                            // Same room as a bar, so the neighbouring card's rows line up.
                            Color.clear.frame(height: 5)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 18)

            Button { model.toggle(id) } label: {
                HStack(spacing: 5) {
                    Text(open ? "Скрыть" : "Подробнее")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppModule.health.tint.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
            .accessibilityValue(open ? "развёрнуто" : "свёрнуто")

            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(details) { row in
                        FactRow(row: row)
                        Hairline()
                    }
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(radius: 16, shadow: false)
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Theme.text.opacity(0.08), lineWidth: 8)
            if let gauge {
                Circle()
                    .trim(from: 0, to: min(1, max(0.005, gauge)))
                    .stroke(tone.color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(Int((gauge * 100).rounded()))\(Fmt.nbsp)%")
                        .font(.number(19, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                    Text(gaugeCaption)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            } else {
                Image(systemName: tone == .good ? "checkmark" : "exclamationmark")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(tone.color)
            }
        }
        .frame(width: 84, height: 84)
        .accessibilityLabel(gauge.map { String(localized: "\(gaugeCaption) \(Int(($0 * 100).rounded())) процентов") } ?? verdict)
    }
}

/// Icon + title + status, one large figure with its caption, the main facts, then «Подробнее»:
/// more facts and a plain explanation of where the numbers come from.
private struct HealthCard: View {
    let id: String
    let model: HealthModel
    let symbol: String
    let title: String
    let status: HealthStatus?
    let metric: HealthMetric
    let rows: [HealthRow]
    let details: [HealthRow]
    let note: String

    var body: some View {
        let open = model.expanded.contains(id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, tint: .health, size: 30)
                Text(title)
                    .font(.cardTitle)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                if let status { StatusBadge(status: status) }
            }
            // A word («Нормальное») and a number («310 ГБ») take the same room: rows start level across a row.
            MetricText(metric: metric)
                .frame(height: 58, alignment: .bottomLeading)
                .padding(.top, 4)
            Text(metric.caption)
                .font(.caption12)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    Hairline()
                    FactRow(row: row)
                }
            }
            .padding(.top, 12)

            Button { model.toggle(id) } label: {
                HStack(spacing: 5) {
                    Text(open ? "Скрыть" : "Подробнее")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppModule.health.tint.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            .accessibilityValue(open ? "развёрнуто" : "свёрнуто")

            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(details) { row in
                        FactRow(row: row)
                        Hairline()
                    }
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(radius: 16, shadow: false)
    }
}

private struct FactRow: View {
    let row: HealthRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.label)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Text(row.value)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
        .font(.system(size: 12.5))
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Copy

enum HealthCopy {
    static let battery = String(localized: """
    Ёмкость — тот же процент, что в Системных настройках → Аккумулятор → Состояние аккумулятора. \
    Батарея со временем изнашивается, это нормально: Apple считает её исправной, пока она держит от 80 %. \
    Циклы — сколько раз она в сумме разрядилась на 100 %.
    """)

    static let drive = String(localized: """
    SSD изнашивается от записи. Ресурс — сколько записи осталось из того, что заложил производитель; \
    его сообщает сам диск. Даже когда ресурс кончится, диск обычно продолжает работать — но резервная копия \
    тогда особенно важна. На некоторых Mac диск этих данных не сообщает.
    """)

    static func smart(_ status: DriveHealth.SMARTStatus) -> String {
        switch status {
        case .verified: String(localized: "в порядке")
        case .failing: String(localized: "сбой")
        case .notSupported: String(localized: "не поддерживается")
        case .unknown: String(localized: "нет данных")
        }
    }

    static let space = String(localized: """
    Finder и «Об этом Mac» считают свободным и то место, которое macOS может освободить сама: локальные \
    снимки Time Machine, файлы iCloud, которые можно скачать снова, и временные кэши. Это место \
    освобождается автоматически, как только оно понадобится, — удалять его вручную не нужно. Локальные \
    снимки Time Machine хранятся около суток, и macOS удаляет их раньше, если место заканчивается.
    """)

    static let memory = String(localized: """
    Давление памяти показывает, хватает ли оперативной памяти: «нормальное» — хватает; «повышенное» — macOS \
    сжимает данные и пользуется свопом; «высокое» — памяти не хватает, программы могут подтормаживать. \
    Немного свопа — обычное дело. Значения сняты один раз, в момент проверки.
    """)

    static let rosetta = String(localized: """
    Они запускаются через Rosetta 2. Apple сохраняет Rosetta для любых программ до macOS 27 включительно, \
    а в следующих версиях — только для части старых игр. Проверьте, нет ли у разработчика версии для Apple silicon.
    """)

    static func intelCaption(intel: Int, total: Int) -> String {
        if intel == 0 {
            return total == 0 ? String(localized: "сторонних программ не найдено")
                              : String(localized: "все \(Fmt.apps(total)) работают на Apple silicon без Rosetta")
        }
        return String(localized: "\(Fmt.plural(intel, "программа", "программы", "программ")) из \(Fmt.integer(total)) — только для Intel")
    }

    static func summary(_ concerns: [MacHealthReport.Concern], checkedAt: Date) -> String {
        let time = checkedAt.formatted(Date.VerbatimFormatStyle(format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                                                                 timeZone: .current, calendar: Calendar(identifier: .gregorian)))
        let parts = concerns.map { c -> String in
            switch c {
            case .driveFailing: String(localized: "диск сообщает о сбое")
            case .driveSpareLow: String(localized: "у SSD кончается резерв")
            case .batteryService: String(localized: "аккумулятору нужно обслуживание")
            case .driveWornOut: String(localized: "SSD выработал расчётный ресурс")
            case .memoryPressureHigh: String(localized: "не хватает памяти")
            case .intelOnlyApps(let n): String(localized: "\(Fmt.integer(n)) \(Fmt.plural(n, "программа", "программы", "программ")) только для Intel")
            }
        }
        let head = parts.isEmpty ? String(localized: "Ничего тревожного") : parts.joined(separator: " · ").capitalizedFirst
        return String(localized: "\(head) · проверено в \(time)")
    }

    static func hours(_ h: Int) -> String {
        if h < 48 { return "\(Fmt.integer(h))\(Fmt.nbsp)" + String(localized: "ч") }
        return Fmt.days(h / 24)
    }

    static func uptime(since boot: Date, now: Date) -> String {
        let hours = max(0, Int(now.timeIntervalSince(boot) / 3600))
        return hours < 1 ? String(localized: "меньше часа") : self.hours(hours)
    }

    private static let dateTimeStyle = Date.VerbatimFormatStyle(
        format: "\(day: .defaultDigits) \(month: .abbreviated), \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        locale: Fmt.ru, timeZone: .current, calendar: Calendar(identifier: .gregorian))

    static func dateTime(_ date: Date) -> String { date.formatted(dateTimeStyle) }
}
