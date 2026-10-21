import Foundation
import CleanerKit

/// Turns raw removal failures into human Russian text plus a suggested action.
/// Owned by the shared-components workstream; modules only call `describe(_:)`.
enum FailureCopy {
    enum Action: Equatable { case grantAccess, revealInFinder, retry, none }

    struct Line: Equatable {
        let text: String
        let action: Action
    }

    static func describe(_ failure: RemovalFailure) -> Line {
        let r = failure.reason
        let lower = r.lowercased()
        if r == "Приложение запущено" {
            return Line(text: "Приложение запущено — закройте его и повторите", action: .retry)
        }
        if lower.contains("отменено") {
            return Line(text: "Пароль администратора не введён", action: .retry)
        }
        if lower.contains("permission") || lower.contains("not permitted") || lower.contains("нет прав")
            || lower.contains("нет доступа") || lower.contains("полный доступ") || lower.contains("не разрешена") || lower.contains("don’t have permission") || lower.contains("don't have permission") {
            return Line(text: "Нет доступа — дайте \(AppInfo.name) полный доступ к диску", action: .grantAccess)
        }
        if lower.contains("locked") || lower.contains("защищ") && lower.contains("finder") {
            return Line(text: "Файл защищён в Finder (Свойства → Защита)", action: .revealInFinder)
        }
        if lower.contains("doesn’t exist") || lower.contains("doesn't exist") || lower.contains("no such file") {
            return Line(text: "Файл уже удалён", action: .none)
        }
        if SafetyGuard.isProtected(failure.url) {
            return Line(text: "Защищённая папка — \(AppInfo.name) её не трогает", action: .none)
        }
        return Line(text: r, action: .revealInFinder)
    }
}
