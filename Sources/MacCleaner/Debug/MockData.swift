#if DEBUG
// Snapshot / mock tooling: compiled out of release builds (it can render real scan results to disk).
import Foundation
import CleanerKit
import SpaceEngine
import HealthEngine

/// Realistic sample data for `--snapshot` renders. Never used by the real app flow.
enum MockData {
    static let home = SafetyGuard.home
    static let now = Date()

    static func h(_ path: String) -> URL { home.appendingPathComponent(path) }
    static func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }
    static let KB: Int64 = 1_000, MB: Int64 = 1_000_000, GB: Int64 = 1_000_000_000

    // MARK: Junk

    static var junk: [JunkCategory] {
        func items(_ list: [(String, Int64)], dir: Bool = true) -> [FileItem] {
            list.map { FileItem(url: $0.0.hasPrefix("/") ? URL(fileURLWithPath: $0.0) : h($0.0), size: $0.1, isDirectory: dir) }
        }
        return [
            JunkCategory(id: "xcode-derived-data", title: "Xcode: DerivedData",
                         detail: "Промежуточные файлы сборки. Xcode пересоздаст их при следующей сборке проекта.",
                         symbol: "hammer.fill", risk: .safe,
                         items: items([("Library/Developer/Xcode/DerivedData/MacCleaner-dkqhzfxbtwy", 2_840 * MB),
                                       ("Library/Developer/Xcode/DerivedData/Weatherly-abgxkrvnqp", 1_960 * MB),
                                       ("Library/Developer/Xcode/DerivedData/ModuleCache.noindex", 1_120 * MB),
                                       ("Library/Developer/Xcode/DerivedData/SwiftUIPlayground-ftbz", 410 * MB)])),
            JunkCategory(id: "user-caches", title: "Кэш приложений",
                         detail: "Временные данные приложений. Они создаются заново при следующем запуске.",
                         symbol: "internaldrive.fill", risk: .safe,
                         items: items([("Library/Caches/com.spotify.client", 1_210 * MB),
                                       ("Library/Caches/com.tinyspeck.slackmacgap", 412 * MB),
                                       ("Library/Caches/ru.keepcoder.Telegram", 236 * MB),
                                       ("Library/Caches/com.microsoft.VSCode.ShipIt", 182 * MB),
                                       ("Library/Caches/Homebrew", 96 * MB),
                                       ("Library/Caches/com.figma.Desktop", 74 * MB),
                                       ("Library/Caches/com.apple.python", 21 * MB)])),
            JunkCategory(id: "dev-package-caches", title: "Кэш пакетных менеджеров",
                         detail: "Скачанные пакеты npm, pip, Homebrew и CocoaPods. При необходимости загрузятся снова.",
                         symbol: "shippingbox.fill", risk: .safe,
                         items: items([(".npm/_cacache", 1_380 * MB), ("Library/Caches/pip", 512 * MB),
                                       ("Library/Caches/CocoaPods", 244 * MB)])),
            JunkCategory(id: "browser-caches", title: "Кэш браузеров",
                         detail: "Сохранённые копии страниц и картинок. Вкладки, история и пароли не затрагиваются.",
                         symbol: "globe", risk: .safe,
                         items: items([("Library/Caches/Google/Chrome/Default/Cache", 1_140 * MB),
                                       ("Library/Caches/Google/Chrome/Default/Code Cache", 388 * MB),
                                       ("Library/Containers/com.apple.Safari/Data/Library/Caches", 214 * MB)])),
            JunkCategory(id: "electron-app-caches", title: "Кэш программ на Electron",
                         detail: "Кэш страниц, скриптов и графики Slack, Discord, VS Code, Notion, Figma и других программ на движке Chromium. Переписка, входы в аккаунты и офлайн-данные не затрагиваются, запущенные программы пропускаются.",
                         symbol: "atom", risk: .safe,
                         items: items(electronCaches.map { ($0.0, $0.1) })),
            JunkCategory(id: "user-logs", title: "Журналы приложений",
                         detail: "Текстовые отчёты о работе программ. Нужны только разработчикам при поиске ошибок.",
                         symbol: "doc.text.fill", risk: .safe,
                         items: items([("Library/Logs/JetBrains", 148 * MB), ("Library/Logs/DiagnosticReports", 64 * MB),
                                       ("Library/Logs/zoom.us", 31 * MB)])),
            JunkCategory(id: "old-installers", title: "Установщики",
                         detail: "Образы и пакеты, из которых вы уже установили программы. Проверьте, не нужны ли они.",
                         symbol: "shippingbox.and.arrow.backward.fill", risk: .review,
                         items: items([("Downloads/Docker.dmg", 1_820 * MB), ("Downloads/Figma-124.3.dmg", 232 * MB),
                                       ("Downloads/googlechrome.dmg", 214 * MB)], dir: false)),
            JunkCategory(id: "ios-backups", title: "Резервные копии iPhone и iPad",
                         detail: "Локальные копии устройств. Удаляйте, только если есть копия в iCloud или она устарела.",
                         symbol: "iphone", risk: .caution,
                         items: items([("Library/Application Support/MobileSync/Backup/00008110-001A2C3E0E78801E", 12_400 * MB)])),
            JunkCategory(id: "trash", title: "Корзина",
                         detail: "Файлы, которые вы уже удалили. Очистка Корзины необратима.",
                         symbol: "trash.fill", risk: .review,
                         items: items([(".Trash/Старые скриншоты", 512 * MB), (".Trash/presentation-draft.key", 228 * MB)])),
        ]
    }

    /// Path, size and the scanner's label for the Electron caches demo.
    static let electronCaches: [(String, Int64, String)] = [
        ("Library/Application Support/Slack/Cache", 1_240 * MB, "Slack · Cache"),
        ("Library/Application Support/discord/Cache", 612 * MB, "Discord · Cache"),
        ("Library/Application Support/Notion/Partitions/notion/Cache", 402 * MB, "Notion · notion · Cache"),
        ("Library/Application Support/Slack/Code Cache", 318 * MB, "Slack · Code Cache"),
        ("Library/Application Support/Code/CachedExtensionVSIXs", 286 * MB, "Visual Studio Code · CachedExtensionVSIXs"),
        ("Library/Application Support/Code/CachedData", 141 * MB, "Visual Studio Code · CachedData"),
        ("Library/Application Support/Figma/GPUCache", 48 * MB, "Figma · GPUCache"),
    ]

    static var junkNotes: [URL: String] {
        Dictionary(uniqueKeysWithValues: electronCaches.map { (h($0.0), $0.2) })
    }

    // MARK: Apps

    static var apps: [InstalledApp] {
        func app(_ path: String, _ name: String, _ id: String, _ v: String, _ size: Int64, _ used: Double?,
                 store: Bool = false, system: Bool = false) -> InstalledApp {
            InstalledApp(url: URL(fileURLWithPath: path), name: name, bundleID: id, version: v, teamID: nil, size: size,
                         lastUsed: used.map(daysAgo), isSystemApp: system, isAppStore: store)
        }
        return [
            app("/Applications/Xcode.app", "Xcode", "com.apple.dt.Xcode", "26.1", 12_600 * MB, 2, store: true),
            app("/Applications/Xcode-beta.app", "Xcode-beta", "com.apple.dt.Xcode", "27.0 beta 3", 11_900 * MB, 250),
            app("/Applications/GarageBand.app", "GarageBand", "com.apple.garageband10", "10.4.12", 2_300 * MB, 410, store: true),
            app("/Applications/iMovie.app", "iMovie", "com.apple.iMovieApp", "10.4.3", 3_100 * MB, 300, store: true),
            app("/Applications/Google Chrome.app", "Google Chrome", "com.google.Chrome", "131.0.6778.86", 1_420 * MB, 0.2),
            app("/Applications/Visual Studio Code.app", "Visual Studio Code", "com.microsoft.VSCode", "1.95.3", 612 * MB, 21),
            app("/Applications/Claude.app", "Claude", "com.anthropic.claudefordesktop", "1.2.4", 548 * MB, 0.1),
            app("/Applications/Telegram.app", "Telegram", "ru.keepcoder.Telegram", "11.4", 286 * MB, 3, store: true),
            app("/Applications/Keynote Creator Studio.app", "Keynote", "com.apple.iWork.Keynote", "14.3", 732 * MB, 95, store: true),
            app("/Applications/Numbers Creator Studio.app", "Numbers", "com.apple.iWork.Numbers", "14.3", 604 * MB, 260, store: true),
            app("/Applications/Pages Creator Studio.app", "Pages", "com.apple.iWork.Pages", "14.3", 640 * MB, 31, store: true),
            app("/Applications/TokenWatchMac.app", "TokenWatch", "com.example.tokenwatch", "2.0.1", 38 * MB, 190),
            app("/Applications/Safari.app", "Safari", "com.apple.Safari", "26.1", 14 * MB, 1, system: true),
        ]
    }

    static func remnants(forChrome _: Void = ()) -> [AppRemnant] {
        func r(_ path: String, _ size: Int64, _ kind: RemnantKind, _ c: MatchConfidence, admin: Bool = false, dir: Bool = true) -> AppRemnant {
            AppRemnant(item: FileItem(url: path.hasPrefix("/") ? URL(fileURLWithPath: path) : h(path), size: size, isDirectory: dir),
                       kind: kind, confidence: c, requiresAdmin: admin)
        }
        return [
            r("Library/Application Support/Google/Chrome", 2_310 * MB, .applicationSupport, .high),
            r("Library/Application Support/Google/GoogleUpdater", 31 * MB, .applicationSupport, .medium),
            r("Library/Caches/Google/Chrome", 642 * MB, .caches, .high),
            r("Library/Caches/com.google.Chrome", 18 * MB, .caches, .high),
            r("Library/Preferences/com.google.Chrome.plist", 24 * KB, .preferences, .high, dir: false),
            r("Library/Saved Application State/com.google.Chrome.savedState", 412 * KB, .savedState, .high),
            r("Library/HTTPStorages/com.google.Chrome", 1_200 * KB, .httpStorages, .high),
            r("Library/LaunchAgents/com.google.keystone.agent.plist", 4 * KB, .launchAgents, .medium, dir: false),
            r("/Library/LaunchDaemons/com.google.keystone.daemon.plist", 4 * KB, .launchDaemons, .medium, admin: true, dir: false),
            r("/Library/Google/GoogleSoftwareUpdate", 9 * MB, .other, .medium, admin: true),
            r("Library/Application Support/CrashReporter/Chrome_Helper_A3F2.plist", 8 * KB, .crashReports, .low, dir: false),
        ]
    }

    static var orphans: [OrphanGroup] {
        func r(_ path: String, _ size: Int64, _ kind: RemnantKind, _ c: MatchConfidence = .high) -> AppRemnant {
            AppRemnant(item: FileItem(url: h(path), size: size, isDirectory: true), kind: kind, confidence: c, requiresAdmin: false)
        }
        return [
            OrphanGroup(id: "com.docker.docker", displayName: "Docker", remnants: [
                r("Library/Group Containers/group.com.docker", 3_380 * MB, .groupContainers),
                r("Library/Containers/com.docker.docker", 41 * MB, .containers),
                r("Library/Preferences/com.docker.docker.plist", 8 * KB, .preferences),
                r("Library/Application Support/Docker Desktop", 12 * MB, .applicationSupport, .medium),
            ]),
            OrphanGroup(id: "com.spotify.client", displayName: "Spotify", remnants: [
                r("Library/Application Support/Spotify", 840 * MB, .applicationSupport),
                r("Library/Caches/com.spotify.client", 296 * MB, .caches),
                r("Library/Preferences/com.spotify.client.plist", 12 * KB, .preferences),
                r("Library/Saved Application State/com.spotify.client.savedState", 220 * KB, .savedState),
            ]),
            OrphanGroup(id: "com.tinyspeck.slackmacgap", displayName: "Slack", remnants: [
                r("Library/Application Support/Slack", 612 * MB, .applicationSupport),
                r("Library/Caches/com.tinyspeck.slackmacgap.ShipIt", 188 * MB, .caches),
                r("Library/Preferences/com.tinyspeck.slackmacgap.plist", 16 * KB, .preferences),
            ]),
            OrphanGroup(id: "us.zoom.xos", displayName: "zoom.us", remnants: [
                r("Library/Application Support/zoom.us", 386 * MB, .applicationSupport),
                r("Library/Logs/zoom.us", 31 * MB, .logs),
                r("Library/Preferences/us.zoom.xos.plist", 8 * KB, .preferences),
            ]),
            OrphanGroup(id: "notion.id", displayName: "Notion", remnants: [
                r("Library/Application Support/Notion", 302 * MB, .applicationSupport),
                r("Library/Caches/notion.id.ShipIt", 64 * MB, .caches, .medium),
            ]),
            OrphanGroup(id: "com.readdle.smartemail-Mac", displayName: "Spark", remnants: [
                r("Library/Containers/com.readdle.smartemail-Mac", 148 * MB, .containers),
                r("Library/Group Containers/3L68KQB4HG.group.com.readdle.smartemail", 96 * MB, .groupContainers, .medium),
            ]),
        ]
    }

    /// Confident leftovers for the batch-uninstall scenes (Xcode-beta, GarageBand, iMovie…), keyed by bundle.
    static func batchRemnants(for app: InstalledApp) -> [AppRemnant] {
        func r(_ path: String, _ size: Int64, _ kind: RemnantKind) -> AppRemnant {
            AppRemnant(item: FileItem(url: h(path), size: size, isDirectory: true), kind: kind, confidence: .high, requiresAdmin: false)
        }
        let id = app.bundleID ?? app.name
        switch app.name {
        case "Xcode-beta":
            return [r("Library/Developer/Xcode/UserData/Previews", 1_840 * MB, .applicationSupport),
                    r("Library/Caches/\(id)", 412 * MB, .caches),
                    r("Library/Saved Application State/\(id).savedState", 2 * MB, .savedState)]
        case "GarageBand":
            return [r("Library/Containers/\(id)", 864 * MB, .containers),
                    r("Library/Application Support/GarageBand", 1_120 * MB, .applicationSupport)]
        case "iMovie":
            return [r("Library/Containers/\(id)", 238 * MB, .containers),
                    r("Library/Caches/\(id)", 96 * MB, .caches)]
        default:
            return [r("Library/Caches/\(id)", 24 * MB, .caches)]
        }
    }

    // MARK: Old files

    static var oldFiles: [AnalyzedFile] {
        func f(_ path: String, _ size: Int64, _ kind: FileKind, used: Double?, modified: Double) -> AnalyzedFile {
            AnalyzedFile(item: FileItem(url: h(path), size: size, isDirectory: false, lastUsed: used.map(daysAgo),
                                        modified: daysAgo(modified)), kind: kind)
        }
        return [
            f("Downloads/ubuntu-24.04.1-desktop-arm64.iso", 4_710 * MB, .diskImage, used: 420, modified: 430),
            f("Movies/Отпуск 2023/Горы — исходник.mov", 4_120 * MB, .video, used: 610, modified: 620),
            f("Downloads/Xcode_15.4.xip", 3_240 * MB, .archive, used: 380, modified: 390),
            f("Documents/Архив/backup-2022.tar.gz", 1_930 * MB, .archive, used: nil, modified: 700),
            f("Music/Подкаст/episode-12-raw.wav", 1_210 * MB, .audio, used: 300, modified: 305),
            f("Movies/Screen Recording 2024-02-11.mov", 960 * MB, .video, used: 250, modified: 251),
            f("Documents/Проекты/Старый сайт.zip", 862 * MB, .archive, used: 540, modified: 545),
            f("Downloads/AcrobatReader_Installer.pkg", 612 * MB, .installer, used: 360, modified: 361),
            f("Desktop/Презентация Q3 2023.key", 344 * MB, .document, used: 400, modified: 402),
            f("Downloads/Figma-124.3.dmg", 232 * MB, .diskImage, used: 200, modified: 201),
            f("Pictures/Экспорт/Панорама-Эльбрус.tiff", 188 * MB, .image, used: 480, modified: 482),
            f("Documents/Отчёты/Годовой отчёт 2022.pdf", 64 * MB, .document, used: 640, modified: 650),
            f("Developer/legacy-app/node_modules.zip", 410 * MB, .code, used: 520, modified: 530),
        ]
    }

    // MARK: Duplicates

    /// Groups as the engine returns them: biggest waste first, oldest copy first inside a group.
    static var duplicates: [[AnalyzedFile]] {
        func g(_ size: Int64, _ kind: FileKind, _ copies: [(String, Double)]) -> [AnalyzedFile] {
            copies.sorted { $0.1 > $1.1 }.map { path, days in
                AnalyzedFile(item: FileItem(url: h(path), size: size, isDirectory: false, lastUsed: nil,
                                            modified: daysAgo(days)), kind: kind)
            }
        }
        let groups: [[AnalyzedFile]] = [
            // Oldest copy is in Downloads → the copy filed in Movies is kept.
            g(3_840 * MB, .video, [("Downloads/Свадьба Ани и Миши — финал.mp4", 520),
                                   ("Movies/Свадьба/Свадьба Ани и Миши — финал.mp4", 498),
                                   ("Desktop/Свадьба Ани и Миши — финал.mp4", 31)]),
            g(4_710 * MB, .diskImage, [("Documents/Образы/ubuntu-24.04.1-desktop-arm64.iso", 410),
                                       ("Downloads/ubuntu-24.04.1-desktop-arm64.iso", 120)]),
            g(2_130 * MB, .archive, [("Downloads/Отпуск в Грузии — все фото.zip", 300),
                                     ("Documents/Архив/Отпуск в Грузии — все фото.zip", 290)]),
            g(1_210 * MB, .audio, [("Music/Подкаст/Выпуск 12 — исходник.wav", 305),
                                   ("Desktop/Подкаст копия/Выпуск 12 — исходник.wav", 200)]),
            g(344 * MB, .document, [("Documents/Работа/Презентация Q3 2023.key", 402),
                                    ("Desktop/Презентация Q3 2023.key", 380),
                                    ("Downloads/Презентация Q3 2023 (1).key", 379)]),
            // Both copies in Downloads → simply the oldest stays.
            g(232 * MB, .diskImage, [("Downloads/Figma-124.3.dmg", 201),
                                     ("Downloads/Figma-124.3 (1).dmg", 160)]),
            g(18_400 * KB, .image, [("Pictures/Байкал 2024/DSC_0142.jpg", 140),
                                    ("Downloads/Telegram Desktop/DSC_0142.jpg", 138),
                                    ("Desktop/На печать/Байкал — обложка.jpg", 12)]),
            g(12_600 * KB, .document, [("Documents/Учёба/Курсовая — финальная версия.docx", 260),
                                       ("Desktop/Курсовая — финальная версия.docx", 255),
                                       ("Downloads/Курсовая — финальная версия (2).docx", 254)]),
            g(4_200 * KB, .document, [("Documents/Договоры/Договор аренды 2024.pdf", 330),
                                      ("Downloads/Договор аренды 2024.pdf", 331)]),
            g(2_400 * KB, .document, [("Documents/Сканы/Скан диплома.pdf", 700),
                                      ("Desktop/Скан диплома.pdf", 690)]),
        ]
        return groups.sorted {
            ($0.first!.item.size * Int64($0.count - 1)) > ($1.first!.item.size * Int64($1.count - 1))
        }
    }

    // MARK: Disk map

    static var diskTree: DirectoryNode {
        func file(_ name: String, _ size: Int64, in parent: URL) -> DirectoryNode {
            DirectoryNode(url: parent.appendingPathComponent(name), size: size, isDirectory: false, children: [])
        }
        func dir(_ name: String, in parent: URL, _ build: (URL) -> [DirectoryNode]) -> DirectoryNode {
            let url = parent.appendingPathComponent(name)
            let kids = build(url)
            return DirectoryNode(url: url, size: kids.reduce(0) { $0 + $1.size }, isDirectory: true, children: kids)
        }
        func smalls(_ prefix: String, _ count: Int, _ size: Int64, in parent: URL) -> [DirectoryNode] {
            (1...count).map { file("\(prefix)-\($0)", size + Int64($0) * size / 7, in: parent) }
        }
        let kids: [DirectoryNode] = [
            dir("Library", in: home) { u in [
                dir("Developer", in: u) { u in [
                    dir("Xcode", in: u) { u in [
                        dir("iOS DeviceSupport", in: u) { u in [file("18.1 (22B83)", 4_800 * MB, in: u), file("17.5.1 (21F90)", 4_100 * MB, in: u)] },
                        dir("DerivedData", in: u) { u in [file("MacCleaner-dkqhz", 2_840 * MB, in: u), file("Weatherly-abgxk", 1_960 * MB, in: u), file("ModuleCache.noindex", 1_120 * MB, in: u)] },
                        dir("Archives", in: u) { u in [file("2024-05-12", 1_700 * MB, in: u), file("2023-11-02", 1_300 * MB, in: u)] },
                    ] },
                    dir("CoreSimulator", in: u) { u in [file("Devices", 3_600 * MB, in: u), file("Caches", 700 * MB, in: u)] },
                ] },
                dir("Application Support", in: u) { u in [
                    dir("Google", in: u) { u in [file("Chrome", 2_310 * MB, in: u), file("GoogleUpdater", 31 * MB, in: u)] },
                    dir("MobileSync", in: u) { u in [file("Backup", 12_400 * MB, in: u)] },
                    dir("Code", in: u) { u in [file("User", 820 * MB, in: u), file("CachedExtensionVSIXs", 410 * MB, in: u)] },
                    dir("Slack", in: u) { u in [file("Cache", 612 * MB, in: u)] },
                ] + smalls("support", 8, 40 * MB, in: u) },
                dir("Containers", in: u) { u in [file("com.apple.Safari", 1_400 * MB, in: u), file("com.docker.docker", 2_600 * MB, in: u)] + smalls("container", 10, 30 * MB, in: u) },
                dir("Caches", in: u) { u in [file("com.spotify.client", 1_210 * MB, in: u), file("Google", 1_530 * MB, in: u), file("Homebrew", 96 * MB, in: u)] + smalls("cache", 12, 12 * MB, in: u) },
                dir("Group Containers", in: u) { u in [file("group.com.docker", 3_380 * MB, in: u), file("6N38VWS5BX.ru.keepcoder.Telegram", 1_900 * MB, in: u)] },
            ] },
            dir("Movies", in: home) { u in [
                dir("Final Cut Pro", in: u) { u in [file("Проект 2024.fcpbundle", 14_200 * MB, in: u), file("Ролик для канала.fcpbundle", 4_100 * MB, in: u)] },
                dir("Отпуск 2023", in: u) { u in [file("Горы — исходник.mov", 4_120 * MB, in: u), file("Море.mov", 3_300 * MB, in: u), file("Город.mov", 1_600 * MB, in: u)] },
                file("Screen Recording 2024-02-11.mov", 960 * MB, in: u),
            ] },
            dir("Downloads", in: home) { u in [
                file("ubuntu-24.04.1-desktop-arm64.iso", 4_710 * MB, in: u), file("Xcode_15.4.xip", 3_240 * MB, in: u),
                file("Docker.dmg", 1_820 * MB, in: u), file("AcrobatReader_Installer.pkg", 612 * MB, in: u),
                dir("Telegram Desktop", in: u) { u in smalls("video", 6, 140 * MB, in: u) },
            ] + smalls("download", 14, 18 * MB, in: u) },
            dir("Pictures", in: home) { u in [file("Photos Library.photoslibrary", 13_400 * MB, in: u), file("Экспорт", 1_100 * MB, in: u)] },
            dir("Documents", in: home) { u in [
                dir("Проекты", in: u) { u in [file("Старый сайт.zip", 862 * MB, in: u), file("Дизайн", 2_400 * MB, in: u), file("Клиенты", 1_700 * MB, in: u)] },
                dir("Архив", in: u) { u in [file("backup-2022.tar.gz", 1_930 * MB, in: u), file("Сканы", 640 * MB, in: u)] },
            ] + smalls("doc", 16, 9 * MB, in: u) },
            dir("Developer", in: home) { u in [file("maccleaner", 1_200 * MB, in: u), file("weatherly", 2_900 * MB, in: u), file("legacy-app", 3_400 * MB, in: u)] },
            dir("Music", in: home) { u in [file("Music", 3_900 * MB, in: u), file("Подкаст", 1_700 * MB, in: u)] },
            dir("Desktop", in: home) { u in [file("Презентация Q3 2023.key", 344 * MB, in: u)] + smalls("screenshot", 9, 6 * MB, in: u) },
        ] + smalls(".config", 6, 30 * MB, in: home)
            + [DirectoryNode(url: home, size: 2_400 * MB, isDirectory: false, children: [], isAggregate: true)]
        return DirectoryNode(url: home, size: kids.reduce(0) { $0 + $1.size }, isDirectory: true, children: kids)
    }

    // MARK: Storage breakdown (sidebar disk widget)

    /// A 494 GB disk with 182.6 GB free, split like a typical developer's Mac.
    static var storage: StorageBreakdown {
        StorageBreakdown.compose(
            volumeName: "Macintosh HD", total: 494_380_000_000, free: 182_600_000_000,
            measured: [.apps: 58_400 * MB, .appData: 46_200 * MB, .media: 41_300 * MB, .developer: 38_700 * MB,
                       .documents: 29_800 * MB, .iCloud: 14_600 * MB, .music: 9_100 * MB, .trash: 2_400 * MB],
            measuredAt: now, duration: 2.6, fullDiskAccess: true)
    }

    static let failures: [RemovalFailure] = [
        RemovalFailure(url: URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"), reason: "Системная или пользовательская папка"),
        RemovalFailure(url: h("Library/Caches/com.apple.Safari"), reason: "Операция не разрешена: нужен полный доступ к диску"),
    ]

    /// One refusal per `FailureCopy` action, worded like the real engine/Foundation errors.
    static let actionableFailures: [RemovalFailure] = [
        RemovalFailure(url: h("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/Скан.pdf"),
                       reason: "“Скан.pdf” couldn’t be moved to the Trash because you don’t have permission to access it."),
        RemovalFailure(url: h("Desktop/Скан диплома.pdf"), reason: "“Скан диплома.pdf” couldn’t be moved to the Trash because it’s locked."),
        RemovalFailure(url: URL(fileURLWithPath: "/Applications/Spotify.app"), reason: "Приложение запущено"),
    ]

    /// Top-level items of a pretend ~/.Trash (snapshots only; the real Trash is never listed here).
    static var trashItems: [TrashItem] {
        [("Старые скриншоты", 512 * MB), ("presentation-draft.key", 228 * MB), ("Docker.dmg", 1_820 * MB),
         ("IMG_4021.MOV", 3_410 * MB), ("node_modules", 640 * MB), ("Отчёт 2024.pdf", 12 * MB)]
            .map { TrashItem(url: h(".Trash/\($0.0)"), size: $0.1) }
            .sorted { $0.size > $1.size }
    }

    // MARK: Mac health

    /// A three-year-old MacBook: worn but healthy battery, a few local snapshots, three Intel-only apps.
    static var health: MacHealthReport {
        func app(_ name: String, _ version: String, _ archs: Set<CPUArchitecture>) -> AppArchitecture {
            AppArchitecture(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, version: version, architectures: archs)
        }
        let universal: [AppArchitecture] = ["Google Chrome", "Telegram", "Zoom", "Figma", "Spotify", "Slack", "Docker",
                                            "Visual Studio Code", "Notion", "1Password", "Raycast", "VLC"]
            .map { app($0, "1.0", [.arm64, .x86_64]) }
        let native: [AppArchitecture] = ["Xcode", "Pixelmator Pro", "Final Cut Pro", "Things", "Bear", "Keynote", "Pages",
                                         "Numbers", "Logic Pro", "Affinity Photo 2", "Tot", "Rectangle", "Ice", "IINA"]
            .map { app($0, "2.0", [.arm64]) }
        let intel = [app("ScanSnap Manager", "6.3", [.x86_64]), app("Legacy MIDI Patchbay", "2.4.1", [.x86_64]),
                     app("Tax Helper 2019", "19.0.3", [.x86_64, .i386])]
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let snapshots = [9, 10, 11].reversed().map { hour in
            let date = calendar.date(byAdding: .minute, value: hour * 60 + 14, to: today) ?? now
            let stamp = date.formatted(Date.VerbatimFormatStyle(
                format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                timeZone: .current, calendar: Calendar(identifier: .gregorian)))
            return LocalSnapshot(name: "com.apple.TimeMachine.\(stamp).local", date: date)
        }
        return MacHealthReport(
            battery: BatteryHealth(cycleCount: 412, designCycleCount: 1000, maximumCapacityPercent: 87, condition: .normal,
                                   fullChargeCapacity: 4_311, designCapacity: 4_966, chargePercent: 64,
                                   isCharging: false, isPluggedIn: false, temperatureCelsius: 29.4),
            drive: DriveHealth(model: "APPLE SSD AP0512Q", smart: .verified, containerTotal: 494_380_000_000,
                               containerFree: 160_900_000_000,
                               nvme: NVMeHealth(percentageUsed: 3, bytesWritten: 41_870 * GB, bytesRead: 63_200 * GB,
                                                availableSpare: 100, availableSpareThreshold: 99, powerOnHours: 3_874,
                                                mediaErrors: 0, unsafeShutdowns: 11, temperatureCelsius: 38)),
            space: SpaceReport(total: 494_380_000_000, freeNow: 160_900_000_000, availableWithPurgeable: 182_600_000_000,
                               snapshots: snapshots),
            architectures: ArchitectureReport(apps: (universal + native + intel).sorted { $0.name < $1.name }),
            vitals: SystemVitals(physicalMemory: 16 * 1_073_741_824, memoryPressure: .normal, swapUsed: 1_240 * MB,
                                 bootTime: now.addingTimeInterval(-6 * 86_400 - 5 * 3600)),
            measuredAt: calendar.date(byAdding: .minute, value: 12 * 60 + 5, to: today) ?? now)  // fixed, not the real clock
    }
}
#endif
