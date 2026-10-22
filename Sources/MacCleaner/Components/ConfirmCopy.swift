import SwiftUI

/// Verb policy for destructive actions, in one place:
/// «Очистить» — system junk; «Удалить» — apps and leftovers; «В Корзину» — user files;
/// «Удалить навсегда» — only emptying the Trash. The confirm button repeats the round button's verb.
enum ConfirmCopy {
    enum Verb {
        case clean, delete, trash, deleteForever

        /// Label of the round button and of the confirm button.
        var button: String {
            switch self {
            case .clean: "Очистить"
            case .delete: "Удалить"
            case .trash: "В Корзину"
            case .deleteForever: "Удалить навсегда"
            }
        }

        var permanent: Bool { self == .deleteForever }
    }

    /// «Переместить 3 файла в Корзину?», «Удалить 2 приложения?», «Удалить навсегда 1 объект?».
    static func title(_ verb: Verb, count: Int, noun: Fmt.Noun) -> String {
        let what = accusative(count, noun)
        return switch verb {
        case .trash: "Переместить \(what) в Корзину?"
        case .clean: "Очистить \(what)?"
        case .delete: "Удалить \(what)?"
        case .deleteForever: "Удалить навсегда \(what)?"
        }
    }

    /// Count in the accusative: only «копия» changes («1 копию»); the other nouns are inanimate masculine/neuter.
    static func accusative(_ n: Int, _ noun: Fmt.Noun) -> String {
        if noun == .copies, n % 10 == 1, n % 100 != 11 { return "\(Fmt.integer(n)) копию" }
        return Fmt.count(n, noun)
    }

    static let trashMessage = "Всё попадёт в Корзину — это можно вернуть, пока Корзина не очищена."
    static let foreverMessage = "Содержимое Корзины будет удалено навсегда. Это действие нельзя отменить."

    /// Footer hint next to the round button.
    static func footerNote(permanent: Bool) -> String {
        permanent ? "Корзина будет очищена навсегда" : "Всё попадёт в Корзину"
    }
}

extension Confirmation {
    /// A confirmation that follows the verb policy: title with the count, confirm button = `verb.button`,
    /// `permanent` only for `.deleteForever`.
    static func make(_ verb: ConfirmCopy.Verb, title: String? = nil, message: String? = nil,
                     count: Int, bytes: Int64, noun: Fmt.Noun = .items,
                     needsAdmin: Bool = false, warning: String? = nil, tint: ModuleTint,
                     action: @escaping @MainActor () -> Void) -> Confirmation {
        Confirmation(title: title ?? ConfirmCopy.title(verb, count: count, noun: noun),
                     message: message ?? (verb.permanent ? ConfirmCopy.foreverMessage : ConfirmCopy.trashMessage),
                     count: count, bytes: bytes, confirmTitle: verb.button,
                     permanent: verb.permanent, needsAdmin: needsAdmin, warning: warning, tint: tint,
                     noun: { Fmt.count($0, noun) }, action: action, offersPermanent: !verb.permanent)
    }
}
