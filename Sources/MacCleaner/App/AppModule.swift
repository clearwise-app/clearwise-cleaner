import SwiftUI

enum AppModule: String, CaseIterable, Identifiable {
    case smartCare, junk, uninstaller, oldFiles, duplicates, diskMap, health, startup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartCare: String(localized: "Умная очистка")
        case .junk: String(localized: "Системный мусор")
        case .uninstaller: String(localized: "Деинсталлятор")
        case .oldFiles: String(localized: "Старые и большие файлы")
        case .duplicates: String(localized: "Дубликаты")
        case .diskMap: String(localized: "Карта диска")
        case .health: String(localized: "Здоровье Mac")
        case .startup: String(localized: "Автозапуск")
        }
    }

    /// Short label for the sidebar where the full title is too long.
    var sidebarTitle: String {
        switch self {
        case .oldFiles: String(localized: "Старые файлы")
        default: title
        }
    }

    var subtitle: String {
        switch self {
        case .smartCare: String(localized: "Мусор, остатки удалённых приложений и забытые файлы — одним сканированием.")
        case .junk: String(localized: "Кэши, журналы и временные файлы, которые macOS и приложения создают заново.")
        case .uninstaller: String(localized: "Удаляйте приложения целиком — вместе с настройками, кэшами и службами.")
        case .oldFiles: String(localized: "Найдите крупные файлы и то, что вы давно не открывали.")
        case .duplicates: String(localized: "Найдите одинаковые файлы и оставьте по одной копии.")
        case .diskMap: String(localized: "Посмотрите, что занимает место, и уберите лишнее.")
        case .health: String(localized: "Аккумулятор, диск, свободное место и программы для Intel. Только проверка — ничего не удаляется.")
        case .startup: String(localized: "Что запускается вместе с Mac: объекты входа, фоновые агенты и системные службы.")
        }
    }

    var symbol: String {
        switch self {
        case .smartCare: "sparkles"
        case .junk: "bubbles.and.sparkles.fill"
        case .uninstaller: "xmark.app.fill"
        case .oldFiles: "archivebox.fill"
        case .duplicates: "doc.on.doc.fill"
        case .diskMap: "chart.pie.fill"
        case .health: "stethoscope"
        case .startup: "power.circle.fill"
        }
    }

    var tint: ModuleTint {
        switch self {
        case .smartCare: .smartCare
        case .junk: .junk
        case .uninstaller: .uninstaller
        case .oldFiles: .oldFiles
        case .duplicates: .duplicates
        case .diskMap: .diskMap
        case .health: .health
        case .startup: .startup
        }
    }
}

/// Lifecycle shared by every scanning module.
enum ModulePhase: Equatable {
    case idle, scanning, results, cleaning, done
}
