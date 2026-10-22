import Foundation

/// Sizes, counts and dates in the app's language (Russian or English), independent of the system locale,
/// so the UI always reads consistently ("12,4 ГБ", "342 объекта" / "12.4 GB", "342 items").
enum Fmt {
    /// Follows the app language (Settings → Язык): numbers, dates and units.
    static var ru: Locale { AppLanguage.locale }
    /// U+00A0, keeps "14 %" and "12,4 ГБ" from wrapping apart.
    static let nbsp = "\u{00A0}"
    private static var units: [String] {
        AppLanguage.isEnglish ? ["B", "KB", "MB", "GB", "TB", "PB"] : ["Б", "КБ", "МБ", "ГБ", "ТБ", "ПБ"]
    }

    static func size(_ bytes: Int64) -> String {
        let p = sizeParts(bytes)
        return "\(p.value)\(nbsp)\(p.unit)"
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

    /// Styles are built once; FormatStyle also caches its ICU formatter, so a row's body
    /// no longer pays for a NumberFormatter per call.
    private static let numberStyles: [FloatingPointFormatStyle<Double>] = (0...3).map {
        FloatingPointFormatStyle<Double>(locale: ru).precision(.fractionLength($0))
    }

    static func number(_ value: Double, digits: Int) -> String {
        let style = numberStyles.indices.contains(digits)
            ? numberStyles[digits]
            : FloatingPointFormatStyle<Double>(locale: ru).precision(.fractionLength(max(0, digits)))
        return value.formatted(style)
    }

    /// Percent of a 0…1 share with a non-breaking space: "14 %", "4,2 %" (digits: 1).
    /// A non-zero share too small for the precision reads "<1 %" / "<0,1 %", never "0 %".
    static func percent(_ fraction: Double, digits: Int = 0) -> String {
        let p = max(0, fraction * 100)
        let step = pow(10, -Double(digits))
        if p > 0 && p < step / 2 { return "<\(number(step, digits: digits))\(nbsp)%" }
        return "\(number(p, digits: digits))\(nbsp)%"
    }

    static func integer(_ n: Int) -> String { number(Double(n), digits: 0) }

    /// English forms by the Russian base form, so every `plural`/`verb` call site stays as it is.
    private static let english: [String: (one: String, other: String)] = [
        "год": ("year", "years"), "группа": ("group", "groups"), "день": ("day", "days"),
        "категория": ("category", "categories"), "копия": ("copy", "copies"),
        "лишняя копия": ("extra copy", "extra copies"), "месяц": ("month", "months"),
        "объект": ("item", "items"), "приложение": ("app", "apps"), "программа": ("app", "apps"),
        "файл": ("file", "files"), "этап": ("step", "steps"),
    ]
    private static let englishVerbs: [String: (one: String, other: String)] = [
        "не открывалось": ("has not been opened", "have not been opened"),
        "не открывался": ("has not been opened", "have not been opened"),
        "оставило": ("left", "left"),
    ]

    /// Plural by count: plural(5, "объект", "объекта", "объектов") → "объектов"; in English, "items".
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        if AppLanguage.isEnglish, let en = english[one] { return n == 1 ? en.one : en.other }
        let n10 = n % 10, n100 = n % 100
        if n10 == 1 && n100 != 11 { return one }
        if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
        return many
    }

    /// Verb agreement with a count: 1, 21, 101 → singular («оставило»), otherwise plural («оставили»).
    static func verb(_ n: Int, one: String, other: String) -> String {
        if AppLanguage.isEnglish, let en = englishVerbs[one] { return n == 1 ? en.one : en.other }
        return n % 10 == 1 && n % 100 != 11 ? one : other
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

    static func years(_ n: Int) -> String { "\(integer(n))\(nbsp)\(plural(n, "год", "года", "лет"))" }
    static func months(_ n: Int) -> String { "\(integer(n))\(nbsp)\(plural(n, "месяц", "месяца", "месяцев"))" }
    static func days(_ n: Int) -> String { "\(integer(n))\(nbsp)\(plural(n, "день", "дня", "дней"))" }

    /// "сегодня", "вчера", "2 дня назад", "21 день назад", "8 месяцев назад", "2 года назад".
    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return String(localized: "нет данных") }
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date, to: now)
        if let y = comps.year, y >= 1 { return String(localized: "\(years(y)) назад") }
        if let m = comps.month, m >= 1 { return String(localized: "\(months(m)) назад") }
        if let d = comps.day, d >= 2 { return String(localized: "\(days(d)) назад") }
        if let d = comps.day, d == 1 { return String(localized: "вчера") }
        return String(localized: "сегодня")
    }

    /// For the app list: "не открывалось 8 месяцев" when idle for 3+ months.
    static func idleHint(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return String(localized: "не открывалось") }
        let comps = Calendar.current.dateComponents([.year, .month], from: date, to: now)
        if let y = comps.year, y >= 1 { return String(localized: "не открывалось \(years(y))") }
        if let m = comps.month, m >= 3 { return String(localized: "не открывалось \(months(m))") }
        return nil
    }

    /// "19 мая 2025". Verbatim pattern rather than `.dateTime`, which appends "г." in Russian;
    /// `y`, not `yyyy`, is the calendar year.
    private static let dateStyle = Date.VerbatimFormatStyle(
        format: "\(day: .defaultDigits) \(month: .abbreviated) \(year: .defaultDigits)",
        locale: ru, timeZone: .current, calendar: Calendar(identifier: .gregorian))

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(dateStyle)
    }

    /// The name of a standard home folder in the app's language ("Загрузки" / "Downloads"), else the folder name.
    static func folderTitle(_ url: URL) -> String {
        switch url.lastPathComponent {
        case "Desktop": String(localized: "Рабочий стол")
        case "Documents": String(localized: "Документы")
        case "Downloads": String(localized: "Загрузки")
        case "Movies": String(localized: "Фильмы")
        case "Music": String(localized: "Музыка")
        case "Pictures": String(localized: "Изображения")
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
