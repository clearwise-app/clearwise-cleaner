import Foundation

/// What the user may do right now. Scanning is always free; cleaning needs `canClean`.
enum AccessState: Equatable {
    /// Snapshots and tests: no licensing at all.
    case unlocked
    case trial(daysLeft: Int)
    case subscribed(plan: String, until: Date?)
    /// Trial over and no subscription (or it lapsed).
    case expired

    var canClean: Bool {
        if case .expired = self { return false }
        return true
    }

    var isSubscribed: Bool {
        if case .subscribed = self { return true }
        return false
    }
}
