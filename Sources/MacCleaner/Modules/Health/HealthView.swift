import SwiftUI
import HealthEngine

struct HealthView: View {
    let model: HealthModel

    var body: some View {
        if model.phase == .results, let report = model.report {
            HealthResults(model: model, report: report)
        } else {
            ModuleStage(module: .health,
                        state: model.phase == .checking ? .busy("Проверяем аккумулятор, диск и программы…")
                                                        : .idle(button: "Проверить", enabled: true),
                        onAction: model.startCheck)
        }
    }
}

// MARK: - Results

private struct HealthResults: View {
    let model: HealthModel
    let report: MacHealthReport

    private let columns = [GridItem(.flexible(), spacing: 14, alignment: .top),
                           GridItem(.flexible(), spacing: 14, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    // Intel-only apps are the one thing the user can act on: first when there are any.
                    let intelFirst = report.architectures.map { !$0.intelOnly.isEmpty } ?? false
                    if intelFirst, let a = report.architectures { IntelAppsCard(model: model, report: a) }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        if let b = report.battery { BatteryCard(model: model, battery: b) }
                        if let d = report.drive { DriveCard(model: model, drive: d) }
                        if let s = report.space { SpaceCard(model: model, space: s) }
                        if let v = report.vitals { MemoryCard(model: model, vitals: v) }
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
        HealthCard(id: "battery", model: model, symbol: "battery.100percent", title: "Аккумулятор",
                   status: battery.condition.map { $0 == .normal ? .ok : .warning("Нужно обслуживание") },
                   metric: metric, rows: rows, details: details, note: HealthCopy.battery)
    }

    private var metric: HealthMetric {
        if let p = battery.maximumCapacityPercent {
            return HealthMetric(value: Fmt.integer(p), unit: "%", caption: "максимальная ёмкость: сколько вмещает батарея по сравнению с новой. Не текущий заряд")
        }
        return HealthMetric(value: Fmt.integer(battery.cycleCount), unit: nil,
                            caption: Fmt.plural(battery.cycleCount, "цикл заряда", "цикла заряда", "циклов заряда"))
    }

    private var rows: [HealthRow] {
        var list: [HealthRow] = []
        let cycles = Fmt.integer(battery.cycleCount)
        list.append(HealthRow("Циклы заряда", battery.designCycleCount.map { "\(cycles) из \(Fmt.integer($0))" } ?? cycles))
        if let c = battery.condition {
            list.append(HealthRow("Состояние", c == .normal ? "Нормальное" : "Рекомендуется обслуживание"))
        }
        if let charge = battery.chargePercent {
            let source = battery.isCharging ? "заряжается" : (battery.isPluggedIn ? "от сети" : "от аккумулятора")
            list.append(HealthRow("Текущий заряд", "\(Fmt.percent(Double(charge) / 100)) · \(source)"))
        }
        return list
    }

    private var details: [HealthRow] {
        var list: [HealthRow] = []
        if let full = battery.fullChargeCapacity, let design = battery.designCapacity {
            list.append(HealthRow("Ёмкость по контроллеру", "\(Fmt.integer(full)) из \(Fmt.integer(design)) мА·ч"))
        }
        if let t = battery.temperatureCelsius {
            list.append(HealthRow("Температура", "\(Fmt.number(t, digits: 1))\(Fmt.nbsp)°C"))
        }
        return list
    }
}

private struct DriveCard: View {
    let model: HealthModel
    let drive: DriveHealth

    var body: some View {
        HealthCard(id: "drive", model: model, symbol: "internaldrive.fill", title: "Накопитель",
                   status: status, metric: metric, rows: rows, details: details, note: HealthCopy.drive)
    }

    private var status: HealthStatus? {
        if drive.smart == .failing { return .danger("Сбой SMART") }
        if drive.nvme?.spareBelowThreshold == true { return .danger("Мало резерва") }
        if let used = drive.nvme?.percentageUsed, used >= 100 { return .warning("Ресурс выработан") }
        return drive.smart == .verified ? .ok : nil
    }

    private var smartText: String {
        switch drive.smart {
        case .verified: "Проверен"
        case .failing: "Сбой — сделайте резервную копию"
        case .notSupported: "Не поддерживается"
        case .unknown: "Нет данных"
        }
    }

    private var metric: HealthMetric {
        if let used = drive.nvme?.percentageUsed {
            return HealthMetric(value: Fmt.integer(used), unit: "%", caption: "износ SSD: сколько ресурса записи израсходовано (у нового диска — 0\(Fmt.nbsp)%)")
        }
        return HealthMetric(value: smartText, unit: nil, caption: "самопроверка диска (SMART)", isWord: true)
    }

    private var rows: [HealthRow] {
        var list = [HealthRow("SMART", smartText)]
        if let written = drive.nvme?.bytesWritten { list.append(HealthRow("Записано за всё время", Fmt.size(written))) }
        if let total = drive.containerTotal, let free = drive.containerFree {
            list.append(HealthRow("Занято", "\(Fmt.size(max(0, total - free))) из \(Fmt.size(total))"))
        }
        return list
    }

    private var details: [HealthRow] {
        var list: [HealthRow] = []
        if let m = drive.model { list.append(HealthRow("Модель", m)) }
        guard let n = drive.nvme else { return list }
        if let read = n.bytesRead { list.append(HealthRow("Прочитано за всё время", Fmt.size(read))) }
        if let spare = n.availableSpare { list.append(HealthRow("Резервные блоки", Fmt.percent(Double(spare) / 100))) }
        if let h = n.powerOnHours { list.append(HealthRow("Наработка", HealthCopy.hours(h))) }
        if let t = n.temperatureCelsius { list.append(HealthRow("Температура", "\(Fmt.integer(t))\(Fmt.nbsp)°C")) }
        if let e = n.mediaErrors { list.append(HealthRow("Ошибки носителя", Fmt.integer(e))) }
        if let u = n.unsafeShutdowns { list.append(HealthRow("Внезапные выключения", Fmt.integer(u))) }
        return list
    }
}

private struct SpaceCard: View {
    let model: HealthModel
    let space: SpaceReport

    var body: some View {
        let parts = Fmt.sizeParts(space.freeNow)
        HealthCard(id: "space", model: model, symbol: "externaldrive.fill.badge.timemachine", title: "Свободное место",
                   status: nil,
                   metric: HealthMetric(value: parts.value, unit: parts.unit, caption: "свободно прямо сейчас"),
                   rows: rows, details: details, note: HealthCopy.space)
    }

    private var rows: [HealthRow] {
        [
            HealthRow("Finder показывает свободным", Fmt.size(space.availableWithPurgeable)),
            HealthRow("Из них освободит macOS", Fmt.size(space.purgeable)),
            HealthRow("Снимки Time Machine на диске", space.snapshots.isEmpty ? "нет" : Fmt.integer(space.snapshots.count)),
        ]
    }

    private var details: [HealthRow] {
        space.snapshots.prefix(12).map { s in
            HealthRow(s.date.map(HealthCopy.dateTime) ?? "Снимок", s.date == nil ? s.name : "Time Machine")
        }
    }
}

private struct MemoryCard: View {
    let model: HealthModel
    let vitals: SystemVitals

    var body: some View {
        HealthCard(id: "memory", model: model, symbol: "memorychip.fill", title: "Память",
                   status: status,
                   metric: HealthMetric(value: pressureWord, unit: nil,
                                        caption: "давление памяти — как в Мониторе системы", isWord: true),
                   rows: rows, details: [], note: HealthCopy.memory)
    }

    private var status: HealthStatus? {
        switch vitals.memoryPressure {
        case .normal: .ok
        case .warning: .warning("Повышенное")
        case .critical: .danger("Высокое")
        case .unknown: nil
        }
    }

    private var pressureWord: String {
        switch vitals.memoryPressure {
        case .normal: "Нормальное"
        case .warning: "Повышенное"
        case .critical: "Высокое"
        case .unknown: "Нет данных"
        }
    }

    private var rows: [HealthRow] {
        // RAM is sold and shown by Apple in binary gigabytes: 16 ГБ, not 17,2.
        let ram = Double(vitals.physicalMemory) / 1_073_741_824
        var list = [HealthRow("Оперативная память", "\(Fmt.number(ram, digits: ram.rounded() == ram ? 0 : 1))\(Fmt.nbsp)ГБ")]
        if let swap = vitals.swapUsed { list.append(HealthRow("Своп на диске", swap > 0 ? Fmt.size(swap) : "не используется")) }
        if let boot = vitals.bootTime { list.append(HealthRow("Без перезагрузки", HealthCopy.uptime(since: boot, now: Date()))) }
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
                StatusBadge(status: intel.isEmpty ? .ok : .warning("Проверьте"))
            }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                MetricText(metric: HealthMetric(value: Fmt.integer(intel.count), unit: nil, caption: ""))
                Text(HealthCopy.intelCaption(intel: intel.count, total: report.apps.count))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 10)

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
                .padding(.top, 12)
        }
        .padding(18)
        .glass(radius: 16, shadow: false)
    }
}

private struct IntelAppRow: View {
    let app: AppArchitecture
    @State private var hover = false

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
                Text([app.version.map { "Версия \($0)" }, "Intel (\(app.architectures.sorted().map(\.title).joined(separator: ", ")))"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption11)
                    .foregroundStyle(.themeTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            IconButton(symbol: "magnifyingglass", help: "Показать в Finder") { Finder.reveal(app.url) }
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
        case .ok: Badge(text: "Норма", color: RiskBadge.safeFill, symbol: "checkmark.circle.fill")
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
            MetricText(metric: metric)
                .padding(.top, 10)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
    static let battery = """
    Процент — тот же, что в Системных настройках → Аккумулятор → Состояние аккумулятора: его берём у macOS \
    и не пересчитываем. Миллиампер-часы — сырые данные контроллера батареи; macOS считает процент по своей \
    формуле, поэтому эти числа могут немного расходиться, а у новой батареи ёмкость бывает выше паспортной.
    """

    static let drive = """
    SMART — самопроверка диска: «Проверен» значит, что SSD не сообщает о неполадках. Износ и объём записи \
    сообщает сам SSD по стандарту NVMe; macOS передаёт эти счётчики с пометкой «могут меняться», поэтому \
    на некоторых Mac их нет. 100 % износа — это расчётный ресурс производителя, а не дата отказа.
    """

    static let space = """
    Finder и «Об этом Mac» считают свободным и то место, которое macOS может освободить сама: локальные \
    снимки Time Machine, файлы iCloud, которые можно скачать снова, и временные кэши. Это место \
    освобождается автоматически, как только оно понадобится, — удалять его вручную не нужно. Локальные \
    снимки Time Machine хранятся около суток, и macOS удаляет их раньше, если место заканчивается.
    """

    static let memory = """
    Давление памяти показывает, хватает ли оперативной памяти: «нормальное» — хватает; «повышенное» — macOS \
    сжимает данные и пользуется свопом; «высокое» — памяти не хватает, программы могут подтормаживать. \
    Немного свопа — обычное дело. Значения сняты один раз, в момент проверки.
    """

    static let rosetta = """
    Они запускаются через Rosetta 2. Apple сохраняет Rosetta для любых программ до macOS 27 включительно, \
    а в следующих версиях — только для части старых игр. Проверьте, нет ли у разработчика версии для Apple silicon.
    """

    static func intelCaption(intel: Int, total: Int) -> String {
        if intel == 0 {
            return total == 0 ? "сторонних программ не найдено"
                              : "все \(Fmt.apps(total)) работают на Apple silicon без Rosetta"
        }
        return "\(Fmt.plural(intel, "программа", "программы", "программ")) из \(Fmt.integer(total)) — только для Intel"
    }

    static func summary(_ concerns: [MacHealthReport.Concern], checkedAt: Date) -> String {
        let time = checkedAt.formatted(Date.VerbatimFormatStyle(format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                                                                 timeZone: .current, calendar: Calendar(identifier: .gregorian)))
        let parts = concerns.map { c -> String in
            switch c {
            case .driveFailing: "диск сообщает о сбое"
            case .driveSpareLow: "у SSD кончается резерв"
            case .batteryService: "аккумулятору нужно обслуживание"
            case .driveWornOut: "SSD выработал расчётный ресурс"
            case .memoryPressureHigh: "не хватает памяти"
            case .intelOnlyApps(let n): "\(Fmt.integer(n)) \(Fmt.plural(n, "программа", "программы", "программ")) только для Intel"
            }
        }
        let head = parts.isEmpty ? "Ничего тревожного" : parts.joined(separator: " · ").capitalizedFirst
        return "\(head) · проверено в \(time)"
    }

    static func hours(_ h: Int) -> String {
        if h < 48 { return "\(Fmt.integer(h))\(Fmt.nbsp)ч" }
        return Fmt.days(h / 24)
    }

    static func uptime(since boot: Date, now: Date) -> String {
        let hours = max(0, Int(now.timeIntervalSince(boot) / 3600))
        return hours < 1 ? "меньше часа" : self.hours(hours)
    }

    private static let dateTimeStyle = Date.VerbatimFormatStyle(
        format: "\(day: .defaultDigits) \(month: .abbreviated), \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        locale: Fmt.ru, timeZone: .current, calendar: Calendar(identifier: .gregorian))

    static func dateTime(_ date: Date) -> String { date.formatted(dateTimeStyle) }
}
