import Foundation

/// One place that answers "may the user clean now?" for both editions:
/// the site edition asks `SiteLicense` (our server), the App Store edition (`CLEARWISE_LITE`) asks StoreKit.
@MainActor @Observable
final class AccessModel {
    #if CLEARWISE_LITE
    let store: StoreSubscription?
    #else
    let site: SiteLicense?
    #endif
    var isPaywallPresented = false
    private let live: Bool

    /// `live: false` for snapshots and tests: everything unlocked, no Keychain, no network.
    init(live: Bool) {
        self.live = live
        #if CLEARWISE_LITE
        store = live ? StoreSubscription() : nil
        #else
        site = live ? SiteLicense() : nil
        #endif
    }

    var state: AccessState {
        guard live else { return .unlocked }
        #if CLEARWISE_LITE
        return store?.state ?? .unlocked
        #else
        return site?.state ?? .unlocked
        #endif
    }

    var canClean: Bool { state.canClean }

    /// Launch: load products or refresh the token.
    func start() {
        guard live else { return }
        #if CLEARWISE_LITE
        Task { await store?.load() }
        #else
        site?.refreshIfDue()
        #endif
    }

    /// App became active: picks up a purchase made in the browser or on another device.
    func refreshIfDue() {
        guard live else { return }
        #if CLEARWISE_LITE
        Task { await store?.refreshEntitlements() }
        #else
        site?.refreshIfDue()
        #endif
    }

    /// Runs a cleanup when allowed, otherwise shows the paywall instead.
    func requireAccess(_ action: () -> Void) {
        if canClean { action() } else { isPaywallPresented = true }
    }
}
