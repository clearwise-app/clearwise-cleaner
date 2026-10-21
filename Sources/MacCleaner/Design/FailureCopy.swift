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

    /// `fullDiskAccess`: already granted, so a refusal comes from file ownership or a lock — asking for access
    /// again would send the user to a screen that says everything is granted.
    static func describe(_ failure: RemovalFailure, fullDiskAccess: Bool = false) -> Line {
        let r = failure.reason
        let lower = r.lowercased()
        if r == "Приложение запущено" {
            return Line(text: "Приложение запущено — закройте его и повторите", action: .retry)
        }
        if lower.contains("отменено") {
            return Line(text: "Пароль администратора не введён — повторите и введите его", action: .retry)
        }
        if lower.contains("администратора") {
            return Line(text: "macOS не подтвердила пароль администратора — повторите", action: .retry)
        }
        if lower.contains("permission") || lower.contains("not permitted") || lower.contains("нет прав")
            || lower.contains("нет доступа") || lower.contains("полный доступ") || lower.contains("не разрешена") || lower.contains("don’t have permission") || lower.contains("don't have permission") {
            if fullDiskAccess {
                return Line(text: "Защищён macOS — удалить нельзя, это нормально", action: .none)
            }
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

    /// One sentence under «Пропущено: N» that answers «do I need to do anything?».
    static func verdict(for lines: [Line], someRemoved: Bool) -> String {
        let actions = Set(lines.map(\.action))
        let rest = someRemoved ? " Остальное убрано." : ""
        if actions.contains(.grantAccess) { return "Без полного доступа к диску macOS их не отдаёт — кнопка ниже." }
        if actions.contains(.retry) { return "Их можно убрать ещё раз — кнопка ниже." }
        if actions == [.none] { return "Их защищает macOS, ничего делать не нужно." + rest }
        return "Причина у каждого файла — в списке." + rest
    }
}
