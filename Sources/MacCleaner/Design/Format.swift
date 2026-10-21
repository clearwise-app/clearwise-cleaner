import Foundation

/// Russian formatting for sizes, counts and dates. Independent of the system locale,
/// so the UI always reads consistently ("12,4 ГБ", "342 объекта").
enum Fmt {
    private static let units = ["Б", "КБ", "МБ", "ГБ", "ТБ", "ПБ"]

    static func size(_ bytes: Int64) -> String {
        let p = sizeParts(bytes)
        return "\(p.value) \(p.unit)"
    }

    /// Decimal units like Finder: 1 КБ = 1000 Б.
    static func sizeParts(_ bytes: Int64) -> (value: String, unit: String) {
        let b = Double(max(0, bytes))
        if b < 1000 { return ("\(Int(b))", units[0]) }
        var value = b
        var idx = 0
        while value >= 1000, idx < units.count - 1 {
            value /= 1000
            idx += 1
        }
        // Avoid "1000 МБ" after rounding.
        if value >= 999.5, idx < units.count - 1 {
            value /= 1000
            idx += 1
        }
        var digits = (idx <= 1 || value >= 100) ? 0 : 1
        // "12 ГБ", not "12,0 ГБ".
        if digits == 1, abs(value - value.rounded()) < 0.05 { digits = 0 }
        return (number(value, digits: digits), units[idx])
    }

    static func number(_ value: Double, digits: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.numberStyle = .decimal
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }

    static func integer(_ n: Int) -> String { number(Double(n), digits: 0) }

    /// Russian plural: plural(5, "объект", "объекта", "объектов") → "объектов".
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n10 = n % 10, n100 = n % 100
        if n10 == 1 && n100 != 11 { return one }
        if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
        return many
    }

    /// Verb agreement with a count: 1, 21, 101 → singular («оставило»), otherwise plural («оставили»).
    static func verb(_ n: Int, one: String, other: String) -> String {
        n % 10 == 1 && n % 100 != 11 ? one : other
    }

    /// Noun for a counted thing, chosen per module («объект», «файл», «копия», «приложение»).
    enum Noun { case items, files, copies, apps }
    static func count(_ n: Int, _ noun: Noun) -> String {
        switch noun {
        case .items: items(n)
        case .files: files(n)
        case .copies: copies(n)
        case .apps: apps(n)
        }
    }

    static func items(_ n: Int) -> String { "\(integer(n)) \(plural(n, "объект", "объекта", "объектов"))" }
    static func files(_ n: Int) -> String { "\(integer(n)) \(plural(n, "файл", "файла", "файлов"))" }
    static func apps(_ n: Int) -> String { "\(integer(n)) \(plural(n, "приложение", "приложения", "приложений"))" }
    static func copies(_ n: Int) -> String { "\(integer(n)) \(plural(n, "копия", "копии", "копий"))" }
    static func groups(_ n: Int) -> String { "\(integer(n)) \(plural(n, "группа", "группы", "групп"))" }
    static func categories(_ n: Int) -> String { "\(integer(n)) \(plural(n, "категория", "категории", "категорий"))" }

    /// Months since a date, nil if unknown.
    static func monthsSince(_ date: Date?, now: Date = Date()) -> Int? {
        guard let date else { return nil }
        return Calendar.current.dateComponents([.month], from: date, to: now).month
    }

    /// "сегодня", "3 дн. назад", "8 мес. назад", "2 г. назад".
    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "нет данных" }
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date, to: now)
        if let y = comps.year, y >= 1 { return "\(y) \(plural(y, "год", "года", "лет")) назад" }
        if let m = comps.month, m >= 1 { return "\(m) мес. назад" }
        if let d = comps.day, d >= 2 { return "\(d) дн. назад" }
        if let d = comps.day, d == 1 { return "вчера" }
        return "сегодня"
    }

    /// For the app list: "не открывалось 8 мес." when idle for 3+ months.
    static func idleHint(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return "не открывалось" }
        let comps = Calendar.current.dateComponents([.year, .month], from: date, to: now)
        if let y = comps.year, y >= 1 { return "не открывалось \(y) \(plural(y, "год", "года", "лет"))" }
        if let m = comps.month, m >= 3 { return "не открывалось \(m) мес." }
        return nil
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM yyyy"
        return f.string(from: date)
    }

    /// Russian name of a standard home folder ("Загрузки"), else the folder name.
    static func folderTitle(_ url: URL) -> String {
        switch url.lastPathComponent {
        case "Desktop": "Рабочий стол"
        case "Documents": "Документы"
        case "Downloads": "Загрузки"
        case "Movies": "Фильмы"
        case "Music": "Музыка"
        case "Pictures": "Изображения"
        default: url.lastPathComponent
        }
    }

    /// "~/Library/Caches/com.foo" — shorter but still a full, unambiguous path.
    static func path(_ url: URL) -> String {
        let p = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }
}
