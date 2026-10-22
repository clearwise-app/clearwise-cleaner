import SwiftUI

enum AppModule: String, CaseIterable, Identifiable {
    case smartCare, junk, uninstaller, oldFiles, duplicates, diskMap, health, startup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartCare: "Умная очистка"
        case .junk: "Системный мусор"
        case .uninstaller: "Деинсталлятор"
        case .oldFiles: "Старые и большие файлы"
        case .duplicates: "Дубликаты"
        case .diskMap: "Карта диска"
        case .health: "Здоровье Mac"
        case .startup: "Автозапуск"
        }
    }

    /// Short label for the sidebar where the full title is too long.
    var sidebarTitle: String {
        switch self {
        case .oldFiles: "Старые файлы"
        default: title
        }
    }

    var subtitle: String {
        switch self {
        case .smartCare: "Мусор, остатки удалённых приложений и забытые файлы — одним сканированием."
        case .junk: "Кэши, журналы и временные файлы, которые macOS и приложения создают заново."
        case .uninstaller: "Удаляйте приложения целиком — вместе с настройками, кэшами и службами."
        case .oldFiles: "Найдите крупные файлы и то, что вы давно не открывали."
        case .duplicates: "Найдите одинаковые файлы и оставьте по одной копии."
        case .diskMap: "Посмотрите, что занимает место, и уберите лишнее."
        case .health: "Аккумулятор, диск, свободное место и программы для Intel. Только проверка — ничего не удаляется."
        case .startup: "Что запускается вместе с Mac: объекты входа, фоновые агенты и системные службы."
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
