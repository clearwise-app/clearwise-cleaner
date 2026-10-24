import Foundation
import StoreKit
import AppKit

/// Subscription of the App Store edition (StoreKit 2). No server: the App Store signs every transaction
/// and `Transaction.currentEntitlements` holds the active one, offline too. The free week is an
/// introductory offer set on the products in App Store Connect.
@MainActor @Observable
final class StoreSubscription {
    private(set) var products: [Product] = []
    private(set) var active: Transaction?
    /// Whether the user can still take the introductory offer (the free week).
    private(set) var introEligible = false
    private(set) var isWorking = false
    private(set) var loaded = false
    var errorText: String?

    @ObservationIgnored private var updates: Task<Void, Never>?

    init() {
        // Renewals, refunds, Ask to Buy approvals and purchases made on another Mac arrive here.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refreshEntitlements()
            }
        }
    }

    var state: AccessState {
        // Until the first entitlement check finishes (a split second) nothing is locked.
        guard let active else { return loaded ? .expired : .unlocked }
        let plan = active.productID.hasSuffix("monthly") ? "monthly" : "yearly"
        return .subscribed(plan: plan, until: active.expirationDate)
    }

    func load() async {
        do {
            products = try await Product.products(for: LicenseConfig.storeProductIDs).sorted { $0.price < $1.price }
            if let first = products.first, let subscription = first.subscription {
                introEligible = await subscription.isEligibleForIntroOffer
            }
        } catch {
            errorText = String(localized: "Не удалось загрузить цены из App Store.")
        }
        await refreshEntitlements()
    }

    func refreshEntitlements() async {
        var latest: Transaction?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.productType == .autoRenewable,
                  transaction.revocationDate == nil else { continue }
            if latest == nil || (transaction.expirationDate ?? .distantFuture) > (latest?.expirationDate ?? .distantPast) {
                latest = transaction
            }
        }
        active = latest
        loaded = true
    }

    func purchase(_ product: Product) async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let transaction) = verification { await transaction.finish() }
                await refreshEntitlements()
            case .pending, .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            errorText = String(localized: "Покупка не прошла. Попробуйте ещё раз.")
        }
    }

    /// «Восстановить покупки» — required by App Review for subscriptions.
    func restore() async {
        isWorking = true
        defer { isWorking = false }
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    func openManageSubscriptions() {
        NSWorkspace.shared.open(URL(string: "https://apps.apple.com/account/subscriptions")!)
    }
}
