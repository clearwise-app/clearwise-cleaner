import Foundation
import CleanerKit

public enum StartupAction: Sendable {
    /// `launchctl disable` + `bootout`: stops the job and keeps launchd from loading it again. Undo: `.enable`.
    case disable
    /// `launchctl enable` + `bootstrap`: clears the override and loads the job now.
    case enable
    /// `bootout`, then the plist goes to the Trash through `FileRemover`. The program itself stays.
    case remove
}

public struct StartupActionReport: Sendable {
    public struct Failure: Sendable, Equatable {
        public let id: String
        public let reason: String
    }

    public var succeeded: [String] = []
    public var failed: [Failure] = []
    /// What `FileRemover` did for `.remove` (the plists moved to the Trash).
    public var removal = RemovalResult()
}

/// Changes to startup items. Every change is explicit, per item, and re-checked right before it runs:
/// the plist must still be the real file (not a link) in its folder, with the same label, not Apple's,
/// not refused by `SafetyGuard`. Agents run in the user's GUI domain and need no password; daemons
/// (`/Library/LaunchDaemons`) are changed as root after one administrator prompt per batch.
public enum StartupActions {
    /// The reasons `refusal` and `changedOnDisk` give; one value each, so the screen and tests can compare.
    enum Reason {
        static let apple = String(localized: "Часть macOS — не трогаем", bundle: .module)
        static let managedInSettings = String(localized: "Управляется в Системных настройках → Объекты входа", bundle: .module)
        static let malformed = String(localized: "Файл повреждён — macOS его не загружает", bundle: .module)
        static let unusualLabel = String(localized: "Необычное имя службы", bundle: .module)
        static let alreadyDisabled = String(localized: "Уже выключено", bundle: .module)
        static let alreadyEnabled = String(localized: "Уже включено", bundle: .module)
        static let enableInSettings = String(localized: "Включается в Системных настройках → Объекты входа", bundle: .module)
        static let notApplied = String(localized: "macOS не применила изменение", bundle: .module)
        static let stale = String(localized: "Файл изменился после проверки — обновите список", bundle: .module)
        static let fileGone = String(localized: "Файла уже нет", bundle: .module)
        static let notAFile = String(localized: "Это ссылка, а не файл", bundle: .module)
        static let unexpectedOwner = String(localized: "Неожиданный владелец файла", bundle: .module)
    }

    /// Why `action` cannot be applied to `item`, or nil. Pure: the screen uses it to enable buttons.
    public static func refusal(_ action: StartupAction, for item: StartupItem) -> String? {
        if item.isApple { return Reason.apple }
        guard item.source != .backgroundTask, let plist = item.plist else {
            return Reason.managedInSettings
        }
        if let reason = SafetyGuard.refusalReason(for: plist) { return reason }
        switch action {
        case .disable:
            if item.isMalformed { return Reason.malformed }
            if !isValidLabel(item.label) { return Reason.unusualLabel }
            if item.disabledByOverride { return Reason.alreadyDisabled }
        case .enable:
            if item.isMalformed { return Reason.malformed }
            if !isValidLabel(item.label) { return Reason.unusualLabel }
            if !item.disabledByOverride && !item.disabledInPlist {
                return item.disabledInSettings ? Reason.enableInSettings : Reason.alreadyEnabled
            }
        case .remove:
            if !item.isMalformed && !isValidLabel(item.label) { return Reason.unusualLabel }
        }
        return nil
    }

    /// Applies `action` to the allowed items. Daemons share one administrator prompt; agents need none.
    public static func perform(_ action: StartupAction, on items: [StartupItem],
                               environment env: StartupEnvironment = .live) async -> StartupActionReport {
        var report = StartupActionReport()
        var ready: [StartupItem] = []
        for item in items {
            if let reason = refusal(action, for: item) ?? changedOnDisk(item, env) {
                report.failed.append(.init(id: item.id, reason: reason))
            } else {
                ready.append(item)
            }
        }
        guard !ready.isEmpty else { return report }
        let plan = StartupPlan(action: action, items: ready, uid: env.uid)

        if action == .remove {
            let ids = Dictionary(ready.compactMap { i in i.plist.map { ($0.standardizedFileURL.path, i.id) } },
                                 uniquingKeysWith: { a, _ in a })
            let removal = await Task.detached(priority: .userInitiated) { () -> RemovalResult in
                for args in plan.userCommands { _ = env.run(StartupScanner.launchctl, args, 15) }
                var result = RemovalResult()
                if !plan.userTrash.isEmpty { result.merge(await FileRemover.moveToTrash(plan.userTrash)) }
                if !plan.adminTrash.isEmpty {
                    result.merge(await FileRemover.moveToTrashAsAdmin(plan.adminTrash, rootPrelude: plan.adminCommands))
                }
                return result
            }.value
            report.removal = removal
            report.succeeded += removal.removed.compactMap { ids[$0.standardizedFileURL.path] }
            report.failed += removal.failed.map { .init(id: ids[$0.url.standardizedFileURL.path] ?? $0.url.path, reason: $0.reason) }
            return report
        }

        let adminError: String? = await Task.detached(priority: .userInitiated) { () -> String? in
            for args in plan.userCommands { _ = env.run(StartupScanner.launchctl, args, 15) }
            guard !plan.adminCommands.isEmpty else { return nil }
            let outcome = LaunchdRootCommand.run(plan.adminCommands)
            return outcome.ok ? nil : outcome.error
        }.value

        // launchctl exit codes are not reliable («already loaded», «not loaded»): the override database decides.
        let state = LaunchdState.read(env)
        for item in ready {
            let domain = item.source == .daemon ? state.system : state.gui
            let disabled = domain.overrides[item.label] ?? false
            // A daemon off only through `Disabled` in its plist has no override either way: without the password
            // nothing ran, so a cancelled prompt must not read as success.
            let promptFailed = item.source == .daemon && adminError != nil
            let ok = !promptFailed && (action == .disable ? disabled : !disabled)
            if ok {
                report.succeeded.append(item.id)
            } else {
                let reason = item.source == .daemon ? (adminError ?? Reason.notApplied) : Reason.notApplied
                report.failed.append(.init(id: item.id, reason: reason))
            }
        }
        return report
    }

    /// launchd labels are reverse-DNS-like; anything else is not passed to a shell or to launchctl.
    static func isValidLabel(_ label: String) -> Bool { LaunchdRootCommand.isValidLabel(label) }

    /// Re-checks the file right before acting: a regular file (not a link) directly in its folder, owned by
    /// the user (user agents) or root (the others), with the same label. Returns a reason, or nil when unchanged.
    static func changedOnDisk(_ item: StartupItem, _ env: StartupEnvironment) -> String? {
        let stale = Reason.stale
        guard let plist = item.plist, let folder = env.folder(for: item.source) else { return stale }
        let url = plist.standardizedFileURL
        guard url.deletingLastPathComponent().path == folder.standardizedFileURL.path else { return stale }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return Reason.fileGone }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return Reason.notAFile }
        let owner: uid_t = item.source == .userAgent ? env.uid : 0
        guard st.st_uid == owner else { return Reason.unexpectedOwner }
        if !item.isMalformed, LaunchdPlist.read(url)?.label != item.label { return stale }
        return nil
    }
}

/// Pure description of the commands an action runs, so tests can check them without launchd.
struct StartupPlan {
    /// `launchctl` argument lists run as the user (agents in `gui/<uid>`), in order.
    var userCommands: [[String]] = []
    /// Root launchd commands (daemons), run in one password prompt; one failure does not stop the rest.
    var adminCommands: [LaunchdRootCommand] = []
    /// What root runs, as text (tests).
    var adminShell: String? {
        let lines = adminCommands.compactMap(\.shellLine)
        return lines.isEmpty ? nil : lines.joined(separator: " ; ")
    }
    /// Plists the user may trash (user agents).
    var userTrash: [URL] = []
    /// Root-owned plists (global agents, daemons): `FileRemover.moveToTrashAsAdmin`, `adminCommands` first.
    var adminTrash: [URL] = []

    init(action: StartupAction, items: [StartupItem], uid: uid_t) {
        for item in items {
            guard let plist = item.plist else { continue }
            let label = item.label
            switch (action, item.source) {
            case (.disable, .userAgent), (.disable, .globalAgent):
                userCommands.append(["disable", "gui/\(uid)/\(label)"])
                userCommands.append(["bootout", "gui/\(uid)/\(label)"])
            case (.enable, .userAgent), (.enable, .globalAgent):
                userCommands.append(["enable", "gui/\(uid)/\(label)"])
                userCommands.append(["bootstrap", "gui/\(uid)", plist.path])
            case (.disable, .daemon):
                adminCommands += [.disable(label: label), .bootout(label: label)]
            case (.enable, .daemon):
                adminCommands += [.enable(label: label), .bootstrap(plist: plist)]
            case (.remove, .userAgent), (.remove, .globalAgent):
                if !item.isMalformed { userCommands.append(["bootout", "gui/\(uid)/\(label)"]) }
                if item.source == .userAgent { userTrash.append(plist) } else { adminTrash.append(plist) }
            case (.remove, .daemon):
                if !item.isMalformed { adminCommands.append(.bootout(label: label)) }
                adminTrash.append(plist)
            case (_, .backgroundTask):
                continue
            }
        }
    }
}
