import SwiftUI

enum AppModule: String, CaseIterable, Identifiable {
    case smartCare, junk, uninstaller, oldFiles, diskMap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartCare: "Умная очистка"
        case .junk: "Системный мусор"
        case .uninstaller: "Деинсталлятор"
        case .oldFiles: "Старые и большие файлы"
        case .diskMap: "Карта диска"
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
        case .diskMap: "Посмотрите, что занимает место, и уберите лишнее."
        }
    }

    var symbol: String {
        switch self {
        case .smartCare: "sparkles"
        case .junk: "bubbles.and.sparkles.fill"
        case .uninstaller: "xmark.app.fill"
        case .oldFiles: "archivebox.fill"
        case .diskMap: "chart.pie.fill"
        }
    }

    var tint: ModuleTint {
        switch self {
        case .smartCare: .smartCare
        case .junk: .junk
        case .uninstaller: .uninstaller
        case .oldFiles: .oldFiles
        case .diskMap: .diskMap
        }
    }
}

/// Lifecycle shared by every scanning module.
enum ModulePhase: Equatable {
    case idle, scanning, results, cleaning, done
}
