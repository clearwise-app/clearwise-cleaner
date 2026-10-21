import Foundation
import CleanerKit

/// All junk categories, as data. To add a category, add one rule here.
///
/// De-duplication: rules are resolved in descending `priority`; a path claimed by a higher-priority
/// rule is never offered again, and a lower-priority item that *contains* a claimed path is split into
/// its children (e.g. `~/Library/Caches/Google` → everything except `Google/Chrome`, which belongs to
/// "Кэш браузеров"). So every file appears in exactly one category.
enum JunkCatalog {

    /// Caches that hurt (re-sync, sign-outs, lost in-flight downloads) or belong to services that are
    /// always busy. Matched case-insensitively against the top-level name in ~/Library/Caches.
    static let protectedCacheNames: [NameMatch] = [
        .exact("CloudKit"), .prefix("com.apple.cloudkit"), .prefix("com.apple.cloudd"),
        .prefix("com.apple.bird"),               // iCloud Drive
        .prefix("com.apple.akd"),                // Apple ID authentication
        .prefix("com.apple.icloud"),             // iCloud helpers, mail, web
        .prefix("com.apple.Safari.SafeBrowsing"),
        .prefix("com.apple.nsurlsessiond"),      // background downloads in progress
        .prefix("com.apple.containermanagerd"),
        .prefix("com.apple.cache_delete"),       // the system's own purgeable-space bookkeeping
        .prefix("com.apple.HomeKit"), .prefix("com.apple.homed"),
        .prefix("com.apple.passd"), .exact("PassKit"),
        .exact("FamilyCircle"), .prefix("familycircled"),
        .prefix("com.apple.accountsd"), .prefix("com.apple.appleaccountd"), .prefix("com.apple.amsaccountsd"),
        .prefix("com.apple.findmy"), .prefix("com.apple.ScreenTimeAgent"),
    ]

    /// Ticked after a scan: `.safe` rules and the regenerable ones marked `selectedByDefault`. The user's own data
    /// (Trash, device backups, installers, Mail attachments, Xcode archives) and admin-only system logs stay unticked.
    static let all: [JunkRule] = [
        userCaches, userLogs, crashReports, systemLogs, browserCaches,
        derivedData, archives, deviceSupport, simulatorCaches, deviceLogs, packageCaches, cargoRegistry, jetbrainsCaches,
        temporaryFiles, installers, mailDownloads, iosBackups, brokenPreferences, brokenLaunchAgents, trash,
    ]

    // MARK: Caches & logs

    static var userCaches: JunkRule {
        var r = JunkRule(id: JunkCategoryID.userCaches, title: "Кэш приложений",
                         detail: "Временные данные программ из ~/Library/Caches. Приложения создадут их заново, когда понадобится.",
                         symbol: "internaldrive.fill", risk: .safe)
        r.priority = 0
        r.locations = [.home("Library/Caches")]
        // JetBrains keeps IDE Local History (the user's unsaved-change safety net) inside its cache folder,
        // so it is handled by its own rule that offers only the regenerable subfolders.
        r.excludedNames = protectedCacheNames + [.exact("JetBrains")]
        r.skipsActiveItems = true
        return r
    }

    static var userLogs: JunkRule {
        var r = JunkRule(id: JunkCategoryID.userLogs, title: "Журналы приложений",
                         detail: "Текстовые журналы программ из ~/Library/Logs. Нужны только для диагностики проблем.",
                         symbol: "doc.text.fill", risk: .safe, phase: "Журналы")
        r.priority = 0
        r.locations = [.home("Library/Logs")]
        r.skipsActiveItems = true
        return r
    }

    static var crashReports: JunkRule {
        var r = JunkRule(id: JunkCategoryID.crashReports, title: "Отчёты о сбоях",
                         detail: "Отчёты о падениях и зависаниях программ. Уже отправлены разработчикам или больше не нужны.",
                         symbol: "exclamationmark.triangle.fill", risk: .safe, phase: "Журналы")
        r.locations = [.home("Library/Logs/DiagnosticReports")]
        return r
    }

    static var systemLogs: JunkRule {
        var r = JunkRule(id: JunkCategoryID.systemLogs, title: "Системные журналы",
                         detail: "Архивные журналы и отчёты о сбоях из /Library/Logs и /var/log. Текущие журналы не трогаем; для удаления macOS может запросить пароль администратора.",
                         symbol: "doc.text.magnifyingglass", risk: .review, phase: "Системные журналы")
        r.collector = { SpecialCollectors.systemLogs($0) }
        return r
    }

    static var browserCaches: JunkRule {
        var r = JunkRule(id: JunkCategoryID.browserCaches, title: "Кэш браузеров",
                         detail: "Только кэш страниц и графики Safari, Chrome, Firefox и других браузеров. История, пароли, cookies и профили не затрагиваются.",
                         symbol: "globe", risk: .safe)
        r.priority = 2
        r.collector = { env in BrowserCacheSpec.all.flatMap { $0.candidates(in: env) } }
        // Same protected names as app caches: Safari's container keeps a CloudKit cache (bookmark/tab sync)
        // next to its page cache, and clearing it forces a full iCloud re-sync.
        r.excludedNames = protectedCacheNames
        return r
    }

    // MARK: Developer

    static var derivedData: JunkRule {
        var r = JunkRule(id: JunkCategoryID.xcodeDerivedData, title: "Xcode: DerivedData",
                         detail: "Промежуточные файлы сборки и индексы Xcode. Пересоздаются при следующей сборке проекта.",
                         symbol: "hammer.fill", risk: .safe, phase: "Файлы разработчика")
        r.priority = 2
        r.locations = [.home("Library/Developer/Xcode/DerivedData")]
        return r
    }

    static var archives: JunkRule {
        var r = JunkRule(id: JunkCategoryID.xcodeArchives, title: "Xcode: архивы",
                         detail: "Архивы сборок (.xcarchive). Нужны для разбора отчётов о сбоях выпущенных версий — проверьте перед удалением.",
                         symbol: "archivebox.fill", risk: .review, phase: "Файлы разработчика")
        r.priority = 2
        r.locations = [.home("Library/Developer/Xcode/Archives", .grandchildren)]
        r.wantsLastUsed = true
        return r
    }

    static var deviceSupport: JunkRule {
        var r = JunkRule(id: JunkCategoryID.xcodeDeviceSupport, title: "Xcode: поддержка устройств",
                         detail: "Отладочные символы для iPhone, iPad, Apple Watch и др. Xcode скачает их снова при подключении устройства.",
                         symbol: "iphone", risk: .review, phase: "Файлы разработчика")
        r.priority = 2
        r.locations = ["iOS", "iPadOS", "watchOS", "tvOS", "visionOS", "xrOS", "macOS"].map {
            .home("Library/Developer/Xcode/\($0) DeviceSupport")
        }
        r.selectedByDefault = true
        return r
    }

    static var simulatorCaches: JunkRule {
        var r = JunkRule(id: JunkCategoryID.simulatorCaches, title: "Кэш симуляторов",
                         detail: "Кэши CoreSimulator. Сами симуляторы и их данные остаются, кэш создаётся заново.",
                         symbol: "ipad.and.iphone", risk: .safe, phase: "Файлы разработчика")
        r.priority = 2
        r.locations = [.home("Library/Developer/CoreSimulator/Caches")]
        return r
    }

    static var deviceLogs: JunkRule {
        var r = JunkRule(id: JunkCategoryID.deviceLogs, title: "Журналы устройств Xcode",
                         detail: "Журналы и отчёты о сбоях, скопированные Xcode с подключённых устройств.",
                         symbol: "list.bullet.rectangle.fill", risk: .safe, phase: "Файлы разработчика")
        r.priority = 2
        r.locations = [.home("Library/Developer/Xcode/iOS Device Logs"), .home("Library/Developer/Xcode/watchOS Device Logs")]
        return r
    }

    static var packageCaches: JunkRule {
        var r = JunkRule(id: JunkCategoryID.packageCaches, title: "Кэш пакетных менеджеров",
                         detail: "Скачанные пакеты npm, Yarn, pnpm, Bun, pip, Homebrew, Gradle, CocoaPods, SwiftPM и кэш сборки Go. Загрузятся снова при необходимости.",
                         symbol: "shippingbox.fill", risk: .safe, phase: "Файлы разработчика")
        r.priority = 2
        r.locations = [
            .home(".npm/_cacache", .itself),
            .home("Library/Caches/Yarn", .itself),
            .home(".yarn/berry/cache", .itself),
            .home("Library/Caches/pnpm", .itself),
            .home(".bun/install/cache", .itself),
            .home("Library/Caches/pip", .itself),
            .home("Library/Caches/pypoetry", .itself),
            .home("Library/Caches/Homebrew"),        // each bottle/download separately
            .home(".gradle/caches"),
            .home("Library/Caches/CocoaPods", .itself),
            .home("Library/Caches/org.swift.swiftpm", .itself),
            .home("Library/Caches/go-build", .itself),
        ]
        return r
    }

    static var cargoRegistry: JunkRule {
        var r = JunkRule(id: JunkCategoryID.cargoRegistry, title: "Cargo: кэш реестра",
                         detail: "Скачанные и распакованные крейты Rust из ~/.cargo/registry. Загрузятся снова, но без сети сборка не пройдёт.",
                         symbol: "cube.box.fill", risk: .review, phase: "Файлы разработчика")
        r.priority = 2
        r.locations = [.home(".cargo/registry/cache"), .home(".cargo/registry/src")]
        r.selectedByDefault = true
        return r
    }

    /// Subfolders of `~/Library/Caches/JetBrains/<IDE>/` that the IDE rebuilds by itself. Everything else
    /// there (notably `LocalHistory`, which holds the user's file history) is never offered.
    static let jetBrainsRegenerableFolders = ["caches", "index", "tmp", "log", "jcef_cache"]

    static var jetbrainsCaches: JunkRule {
        var r = JunkRule(id: JunkCategoryID.jetbrainsCaches, title: "JetBrains: кэш и индексы",
                         detail: "Кэши, индексы и временные файлы IntelliJ IDEA, PyCharm, WebStorm, Android Studio и других IDE. Они пересоздаются при следующем запуске, но индексация проекта займёт время. История изменений (Local History) не затрагивается.",
                         symbol: "curlybraces", risk: .review, phase: "Файлы разработчика")
        r.priority = 2
        r.collector = { SpecialCollectors.jetBrainsCaches($0) }
        r.skipsActiveItems = true
        r.selectedByDefault = true
        return r
    }

    // MARK: Temporary & user files

    static var temporaryFiles: JunkRule {
        var r = JunkRule(id: JunkCategoryID.temporaryFiles, title: "Временные файлы",
                         detail: "Файлы во временной папке пользователя, которые никто не менял больше 3 дней.",
                         symbol: "hourglass", risk: .safe)
        r.priority = 0
        r.locations = [.temporary()]
        r.excludedNames = [.prefix("com.apple.")]
        r.minimumAge = 3 * 24 * 3600
        r.skipsSockets = true
        r.requiresUserDeletable = true
        return r
    }

    static var installers: JunkRule {
        var r = JunkRule(id: JunkCategoryID.installers, title: "Установщики",
                         detail: "Образы и пакеты установки (.dmg, .pkg, .iso, .xip) в Загрузках и на Рабочем столе. Это ваши файлы — по умолчанию не выбраны.",
                         symbol: "opticaldiscdrive.fill", risk: .review, phase: "Установщики")
        r.collector = { SpecialCollectors.installers($0) }
        r.wantsLastUsed = true
        return r
    }

    static var mailDownloads: JunkRule {
        var r = JunkRule(id: JunkCategoryID.mailDownloads, title: "Вложения Mail",
                         detail: "Копии вложений, которые вы открывали из Mail. Сами письма и вложения в них не удаляются.",
                         symbol: "paperclip", risk: .review)
        r.locations = [.home("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")]
        r.wantsLastUsed = true
        return r
    }

    static var iosBackups: JunkRule {
        var r = JunkRule(id: JunkCategoryID.iosBackups, title: "Резервные копии iPhone и iPad",
                         detail: "Локальные резервные копии устройств. Удалённую копию нельзя вернуть — оставьте хотя бы самую свежую.",
                         symbol: "externaldrive.fill.badge.timemachine", risk: .caution, phase: "Резервные копии")
        r.collector = { SpecialCollectors.iosBackups($0) }
        r.sortsNewestFirst = true
        return r
    }

    // MARK: Broken items

    static var brokenPreferences: JunkRule {
        var r = JunkRule(id: JunkCategoryID.brokenPreferences, title: "Повреждённые настройки",
                         detail: "Файлы настроек (.plist), которые не читаются. Приложение создаст новые с настройками по умолчанию.",
                         symbol: "slider.horizontal.3", risk: .review, phase: "Проверка настроек")
        r.collector = { SpecialCollectors.brokenPreferences($0) }
        r.keepsEmptyItems = true
        r.selectedByDefault = true
        return r
    }

    static var brokenLaunchAgents: JunkRule {
        var r = JunkRule(id: JunkCategoryID.brokenLaunchAgents, title: "Неработающие агенты запуска",
                         detail: "Агенты автозапуска из ~/Library/LaunchAgents, чья программа уже удалена. Они только засоряют журнал ошибками.",
                         symbol: "bolt.slash.fill", risk: .review, phase: "Проверка автозапуска")
        r.collector = { SpecialCollectors.brokenLaunchAgents($0) }
        r.keepsEmptyItems = true
        r.selectedByDefault = true
        return r
    }

    static var trash: JunkRule {
        var r = JunkRule(id: JunkCategoryID.trash, title: "Корзина",
                         detail: "Файлы в Корзине будут удалены безвозвратно — проверьте, что там нет нужного.",
                         symbol: "trash.fill", risk: .review)
        r.locations = [.home(".Trash", includeHidden: true)]
        r.keepsEmptyItems = true
        return r
    }
}
