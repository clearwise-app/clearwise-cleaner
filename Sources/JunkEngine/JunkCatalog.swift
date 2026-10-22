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

    /// What each cleanup mode ticks after a scan:
    /// - gentle: `.safe` rules (caches, logs, temporary files);
    /// - enhanced: also what is downloaded or rebuilt again (device support, Cargo, JetBrains) and system logs;
    /// - maximum: also old installers and Xcode archives, Mail attachments, broken settings, older device backups.
    /// No mode ticks the Trash or the newest backup of a device.
    static let all: [JunkRule] = [
        userCaches, userLogs, crashReports, systemLogs, browserCaches, chromiumAppCaches,
        derivedData, archives, deviceSupport, simulatorCaches, deviceLogs, packageCaches, cargoRegistry, jetbrainsCaches,
        temporaryFiles, installers, mailDownloads, iosBackups, deviceFirmware, brokenPreferences, brokenLaunchAgents, trash,
    ]

    // MARK: Caches & logs

    static var userCaches: JunkRule {
        var r = JunkRule(id: JunkCategoryID.userCaches, title: String(localized: "Кэш приложений", bundle: .module),
                         detail: String(localized: "Временные данные программ из ~/Library/Caches и их общих контейнеров. Приложения создадут их заново, когда понадобится.", bundle: .module),
                         symbol: "internaldrive.fill", risk: .safe)
        r.priority = 0
        r.locations = [.home("Library/Caches")]
        r.collector = { SpecialCollectors.groupContainerCaches($0) }
        // JetBrains keeps IDE Local History (the user's unsaved-change safety net) inside its cache folder,
        // so it is handled by its own rule that offers only the regenerable subfolders.
        r.excludedNames = protectedCacheNames + [.exact("JetBrains")]
        r.skipsActiveItems = true
        return r
    }

    static var userLogs: JunkRule {
        var r = JunkRule(id: JunkCategoryID.userLogs, title: String(localized: "Журналы приложений", bundle: .module),
                         detail: String(localized: "Текстовые журналы программ из ~/Library/Logs. Нужны только для диагностики проблем.", bundle: .module),
                         symbol: "doc.text.fill", risk: .safe, phase: String(localized: "Журналы", bundle: .module))
        r.priority = 0
        r.locations = [.home("Library/Logs")]
        r.skipsActiveItems = true
        return r
    }

    static var crashReports: JunkRule {
        var r = JunkRule(id: JunkCategoryID.crashReports, title: String(localized: "Отчёты о сбоях", bundle: .module),
                         detail: String(localized: "Отчёты о падениях и зависаниях программ. Уже отправлены разработчикам или больше не нужны.", bundle: .module),
                         symbol: "exclamationmark.triangle.fill", risk: .safe, phase: String(localized: "Журналы", bundle: .module))
        r.locations = [.home("Library/Logs/DiagnosticReports")]
        return r
    }

    static var systemLogs: JunkRule {
        var r = JunkRule(id: JunkCategoryID.systemLogs, title: String(localized: "Системные журналы", bundle: .module),
                         detail: String(localized: "Архивные журналы и отчёты о сбоях из /Library/Logs и /var/log. Текущие журналы не трогаем; для удаления macOS может запросить пароль администратора.", bundle: .module),
                         symbol: "doc.text.magnifyingglass", risk: .review)
        r.collector = { SpecialCollectors.systemLogs($0) }
        r.mode = .enhanced   // the administrator password
        return r
    }

    static var browserCaches: JunkRule {
        var r = JunkRule(id: JunkCategoryID.browserCaches, title: String(localized: "Кэш браузеров", bundle: .module),
                         detail: String(localized: "Только кэш страниц и графики Safari, Chrome, Firefox и других браузеров. История, пароли, cookies и профили не затрагиваются.", bundle: .module),
                         symbol: "globe", risk: .safe)
        r.priority = 2
        r.collector = { env in BrowserCacheSpec.all.flatMap { $0.candidates(in: env) } }
        // Same protected names as app caches: Safari's container keeps a CloudKit cache (bookmark/tab sync)
        // next to its page cache, and clearing it forces a full iCloud re-sync.
        r.excludedNames = protectedCacheNames
        return r
    }

    static var chromiumAppCaches: JunkRule {
        var r = JunkRule(id: JunkCategoryID.chromiumAppCaches, title: String(localized: "Кэш программ на Electron", bundle: .module),
                         detail: String(localized: "Кэш страниц, скриптов и графики Slack, Discord, VS Code, Notion, Figma и других программ на движке Chromium. Переписка, входы в аккаунты и офлайн-данные не затрагиваются, запущенные программы пропускаются.", bundle: .module),
                         symbol: "atom", risk: .safe, phase: String(localized: "Кэш программ", bundle: .module))
        // Below browsers (priority 2), which own their user data folders; nothing else claims Application Support.
        r.collector = { ChromiumAppCaches.candidates($0) }
        r.skipsActiveItems = true
        return r
    }

    // MARK: Developer

    static var derivedData: JunkRule {
        var r = JunkRule(id: JunkCategoryID.xcodeDerivedData, title: "Xcode: DerivedData",
                         detail: String(localized: "Промежуточные файлы сборки и индексы Xcode. Пересоздаются при следующей сборке проекта.", bundle: .module),
                         symbol: "hammer.fill", risk: .safe, phase: developerPhase)
        r.priority = 2
        r.locations = [.home("Library/Developer/Xcode/DerivedData")]
        return r
    }

    static var archives: JunkRule {
        var r = JunkRule(id: JunkCategoryID.xcodeArchives, title: String(localized: "Xcode: архивы", bundle: .module),
                         detail: String(localized: "Архивы сборок (.xcarchive). Нужны для разбора отчётов о сбоях выпущенных версий — проверьте перед удалением.", bundle: .module),
                         symbol: "archivebox.fill", risk: .review, phase: developerPhase)
        r.priority = 2
        r.locations = [.home("Library/Developer/Xcode/Archives", .grandchildren)]
        r.wantsLastUsed = true
        r.itemMode = { item, env in olderThan(item, days: 180, env: env) ? .maximum : nil }
        return r
    }

    static var deviceSupport: JunkRule {
        var r = JunkRule(id: JunkCategoryID.xcodeDeviceSupport, title: String(localized: "Xcode: поддержка устройств", bundle: .module),
                         detail: String(localized: "Отладочные символы для iPhone, iPad, Apple Watch и др. Xcode скачает их снова при подключении устройства.", bundle: .module),
                         symbol: "iphone", risk: .review, phase: developerPhase)
        r.priority = 2
        r.locations = ["iOS", "iPadOS", "watchOS", "tvOS", "visionOS", "xrOS", "macOS"].map {
            .home("Library/Developer/Xcode/\($0) DeviceSupport")
        }
        r.mode = .enhanced
        return r
    }

    static var simulatorCaches: JunkRule {
        var r = JunkRule(id: JunkCategoryID.simulatorCaches, title: String(localized: "Кэш симуляторов", bundle: .module),
                         detail: String(localized: "Кэши CoreSimulator. Сами симуляторы и их данные остаются, кэш создаётся заново.", bundle: .module),
                         symbol: "ipad.and.iphone", risk: .safe, phase: developerPhase)
        r.priority = 2
        r.locations = [.home("Library/Developer/CoreSimulator/Caches")]
        return r
    }

    static var deviceLogs: JunkRule {
        var r = JunkRule(id: JunkCategoryID.deviceLogs, title: String(localized: "Журналы устройств Xcode", bundle: .module),
                         detail: String(localized: "Журналы и отчёты о сбоях, скопированные Xcode с подключённых устройств.", bundle: .module),
                         symbol: "list.bullet.rectangle.fill", risk: .safe, phase: developerPhase)
        r.priority = 2
        r.locations = [.home("Library/Developer/Xcode/iOS Device Logs"), .home("Library/Developer/Xcode/watchOS Device Logs")]
        return r
    }

    static var packageCaches: JunkRule {
        var r = JunkRule(id: JunkCategoryID.packageCaches, title: String(localized: "Кэш пакетных менеджеров", bundle: .module),
                         detail: String(localized: "Скачанные пакеты npm, Yarn, pnpm, Bun, pip, uv, Homebrew, Gradle, CocoaPods, SwiftPM, кэш сборки Go и браузеры Playwright. Загрузятся снова при необходимости.", bundle: .module),
                         symbol: "shippingbox.fill", risk: .safe, phase: developerPhase)
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
            .home(".cache/uv", .itself),
            .home("Library/Caches/ms-playwright", .itself),   // browsers Playwright downloads for tests
        ]
        return r
    }

    static var cargoRegistry: JunkRule {
        var r = JunkRule(id: JunkCategoryID.cargoRegistry, title: String(localized: "Cargo: кэш реестра", bundle: .module),
                         detail: String(localized: "Скачанные и распакованные крейты Rust из ~/.cargo/registry. Загрузятся снова, но без сети сборка не пройдёт.", bundle: .module),
                         symbol: "cube.box.fill", risk: .review, phase: developerPhase)
        r.priority = 2
        r.locations = [.home(".cargo/registry/cache"), .home(".cargo/registry/src")]
        r.mode = .enhanced
        return r
    }

    /// Subfolders of `~/Library/Caches/JetBrains/<IDE>/` that the IDE rebuilds by itself. Everything else
    /// there (notably `LocalHistory`, which holds the user's file history) is never offered.
    static let jetBrainsRegenerableFolders = ["caches", "index", "tmp", "log", "jcef_cache"]

    static var jetbrainsCaches: JunkRule {
        var r = JunkRule(id: JunkCategoryID.jetbrainsCaches, title: String(localized: "JetBrains: кэш и индексы", bundle: .module),
                         detail: String(localized: "Кэши, индексы и временные файлы IntelliJ IDEA, PyCharm, WebStorm, Android Studio и других IDE. Они пересоздаются при следующем запуске, но индексация проекта займёт время. История изменений (Local History) не затрагивается.", bundle: .module),
                         symbol: "curlybraces", risk: .review, phase: developerPhase)
        r.priority = 2
        r.collector = { SpecialCollectors.jetBrainsCaches($0) }
        r.skipsActiveItems = true
        r.mode = .enhanced
        return r
    }

    // MARK: Temporary & user files

    static var temporaryFiles: JunkRule {
        var r = JunkRule(id: JunkCategoryID.temporaryFiles, title: String(localized: "Временные файлы", bundle: .module),
                         detail: String(localized: "Файлы во временной папке пользователя, которые никто не менял больше 3 дней.", bundle: .module),
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
        var r = JunkRule(id: JunkCategoryID.installers, title: String(localized: "Установщики", bundle: .module),
                         detail: String(localized: "Образы и пакеты установки (.dmg, .pkg, .iso, .xip) в Загрузках и на Рабочем столе. Это ваши файлы: сами отмечаются только в режиме «Максимальная» и только те, что не открывались больше месяца.", bundle: .module),
                         symbol: "opticaldiscdrive.fill", risk: .review)
        r.collector = { SpecialCollectors.installers($0) }
        r.wantsLastUsed = true
        r.itemMode = { item, env in olderThan(item, days: 30, env: env) ? .maximum : nil }
        return r
    }

    static var mailDownloads: JunkRule {
        var r = JunkRule(id: JunkCategoryID.mailDownloads, title: String(localized: "Вложения Mail", bundle: .module),
                         detail: String(localized: "Копии вложений, которые вы открывали из Mail. Сами письма и вложения в них не удаляются.", bundle: .module),
                         symbol: "paperclip", risk: .review)
        r.locations = [.home("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")]
        r.wantsLastUsed = true
        r.mode = .maximum
        return r
    }

    static var iosBackups: JunkRule {
        var r = JunkRule(id: JunkCategoryID.iosBackups, title: String(localized: "Резервные копии iPhone и iPad", bundle: .module),
                         detail: String(localized: "Локальные резервные копии устройств. Удалённую копию нельзя вернуть — оставьте хотя бы самую свежую.", bundle: .module),
                         symbol: "externaldrive.fill.badge.timemachine", risk: .caution, phase: String(localized: "Резервные копии", bundle: .module))
        r.collector = { SpecialCollectors.iosBackups($0) }
        r.sortsNewestFirst = true
        // Older copies only: the newest backup of each device is marked `neverAuto` by the collector.
        r.itemMode = { _, _ in .maximum }
        return r
    }

    static var deviceFirmware: JunkRule {
        var r = JunkRule(id: JunkCategoryID.deviceFirmware, title: String(localized: "Прошивки iPhone и iPad", bundle: .module),
                         detail: String(localized: "Файлы обновлений iOS (.ipsw), которые Finder скачал для подключённых устройств, — по 5–8 ГБ каждый. При следующем обновлении скачаются снова.", bundle: .module),
                         symbol: "arrow.down.app.fill", risk: .review, phase: String(localized: "Прошивки", bundle: .module))
        r.collector = { env in
            ["iPhone", "iPad", "iPod", "Apple TV"].flatMap { device in
                FS.children(of: env.homePath("Library/iTunes/\(device) Software Updates"))
                    .filter { $0.pathExtension.lowercased() == "ipsw" }
                    .map { JunkCandidate($0) }
            }
        }
        r.mode = .enhanced
        return r
    }

    // MARK: Broken items

    static var brokenPreferences: JunkRule {
        var r = JunkRule(id: JunkCategoryID.brokenPreferences, title: String(localized: "Повреждённые настройки", bundle: .module),
                         detail: String(localized: "Файлы настроек (.plist), которые не читаются. Приложение создаст новые с настройками по умолчанию.", bundle: .module),
                         symbol: "slider.horizontal.3", risk: .review, phase: String(localized: "Проверка настроек", bundle: .module))
        r.collector = { SpecialCollectors.brokenPreferences($0) }
        r.keepsEmptyItems = true
        r.mode = .maximum
        return r
    }

    static var brokenLaunchAgents: JunkRule {
        var r = JunkRule(id: JunkCategoryID.brokenLaunchAgents, title: String(localized: "Неработающие агенты запуска", bundle: .module),
                         detail: String(localized: "Агенты автозапуска из ~/Library/LaunchAgents, чья программа уже удалена. Они только засоряют журнал ошибками.", bundle: .module),
                         symbol: "bolt.slash.fill", risk: .review, phase: String(localized: "Проверка автозапуска", bundle: .module))
        r.collector = { SpecialCollectors.brokenLaunchAgents($0) }
        r.keepsEmptyItems = true
        r.mode = .maximum
        return r
    }

    static var trash: JunkRule {
        var r = JunkRule(id: JunkCategoryID.trash, title: String(localized: "Корзина", bundle: .module),
                         detail: String(localized: "Файлы в Корзине будут удалены безвозвратно — проверьте, что там нет нужного.", bundle: .module),
                         symbol: "trash.fill", risk: .review)
        r.locations = [.home(".Trash", includeHidden: true)]
        r.keepsEmptyItems = true
        return r
    }

    /// Progress label shared by the developer rules.
    static var developerPhase: String { String(localized: "Файлы разработчика", bundle: .module) }

    /// Not opened (or, without that, not changed) for `days`.
    static func olderThan(_ item: FileItem, days: Double, env: JunkEnvironment) -> Bool {
        guard let date = item.lastUsed ?? item.modified else { return false }
        return env.now.timeIntervalSince(date) > days * 86_400
    }
}
