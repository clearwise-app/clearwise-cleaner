import Foundation
import AppKit

/// Subscription of the site edition: password-less sign-in, Mac activation and an offline-checkable token.
///
/// Flow: e-mail → 6-digit code → session token (Keychain) → /api/license/activate → signed token (Keychain).
/// The token is checked locally on every launch, so the app works offline until the token's `exp`
/// (LICENSE_OFFLINE_DAYS on the server). It is refreshed about once a day while online.
@MainActor @Observable
final class SiteLicense {
    enum Step: Equatable { case email, code(email: String), signedIn(email: String) }

    private(set) var step: Step = .email
    private(set) var license: LicensePayload?
    /// The account has no paid subscription (402): show the "Buy" buttons.
    private(set) var needsPurchase = false
    /// Every seat is taken (409): the Macs to free one from.
    private(set) var deviceLimit: [LicenseAPI.Device]?
    private(set) var isWorking = false
    var errorText: String?

    let trialEndsAt: Date
    @ObservationIgnored private let api = LicenseAPI()
    @ObservationIgnored private var sessionToken: String? {
        get { Keychain.string(for: "session") }
        set { Keychain.set(newValue, for: "session") }
    }

    private enum Keys {
        static let token = "license"
        static let email = "email"
        static let trialStart = "trial-start"
        /// Latest time the app has seen: winding the clock back doesn't stretch an offline token.
        static let clock = "clearwise.license.clock"
    }

    init() {
        let start: Date
        if let raw = Keychain.string(for: Keys.trialStart), let t = TimeInterval(raw) {
            start = Date(timeIntervalSince1970: t)
        } else {
            start = Date()
            Keychain.set(String(start.timeIntervalSince1970), for: Keys.trialStart)
        }
        trialEndsAt = start.addingTimeInterval(TimeInterval(LicenseConfig.trialDays) * 86_400)
        if let token = Keychain.string(for: Keys.token) { license = Self.checked(token) }
        if let email = Keychain.string(for: Keys.email), sessionToken != nil { step = .signedIn(email: email) }
    }

    var state: AccessState {
        if let license, license.expiresAt > Date() {
            return .subscribed(plan: license.plan, until: license.paidUntilDate)
        }
        let left = Calendar.current.dateComponents([.day], from: Date(), to: trialEndsAt).day ?? 0
        return Date() < trialEndsAt ? .trial(daysLeft: max(1, left + 1)) : .expired
    }

    // MARK: Sign-in

    func requestCode(email: String) async {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@") else { errorText = String(localized: "Введите адрес почты."); return }
        await run {
            let locale = AppLanguage.running
            try await self.api.requestCode(email: email, locale: locale)
            self.step = .code(email: email)
        }
    }

    func verify(code: String) async {
        guard case .code(let email) = step else { return }
        await run {
            self.sessionToken = try await self.api.verifyCode(email: email, code: code.trimmingCharacters(in: .whitespaces))
            Keychain.set(email, for: Keys.email)
            self.step = .signedIn(email: email)
            try await self.activate()
        }
    }

    func changeEmail() {
        step = .email
        errorText = nil
    }

    // MARK: License

    /// On launch and when the app becomes active: refreshes the token once a day, silently.
    func refreshIfDue() {
        guard sessionToken != nil, !isWorking else { return }
        if let license, Date().timeIntervalSince(license.issuedAt) < LicenseConfig.refreshInterval { return }
        Task { await refresh() }
    }

    /// "Проверить подписку": after buying in the browser, or on demand.
    func refresh() async {
        guard sessionToken != nil else { return }
        await run { try await self.activate() }
    }

    private func activate() async throws {
        guard let session = sessionToken else { return }
        do {
            switch try await api.activate(sessionToken: session) {
            case .license(let token):
                guard let payload = Self.checked(token) else { throw LicenseAPI.Failure.server(0) }
                Keychain.set(token, for: Keys.token)
                license = payload
                needsPurchase = false
                deviceLimit = nil
            case .noSubscription:
                Keychain.set(nil, for: Keys.token)
                license = nil
                needsPurchase = true
                deviceLimit = nil
            case .deviceLimit(let devices):
                deviceLimit = devices
            }
        } catch LicenseAPI.Failure.unauthorized {
            // Session revoked or expired: sign in again; a still-valid token keeps working offline meanwhile.
            sessionToken = nil
            step = .email
            throw LicenseAPI.Failure.unauthorized
        }
    }

    /// Frees another Mac's seat (from the device-limit list) and activates this one.
    func free(_ device: LicenseAPI.Device) async {
        guard let session = sessionToken else { return }
        await run {
            try await self.api.deactivate(sessionToken: session, deviceID: device.deviceId)
            try await self.activate()
        }
    }

    /// Signs out on this Mac and frees its seat.
    func signOut() async {
        if let session = sessionToken {
            try? await api.deactivate(sessionToken: session)
            try? await api.logout(sessionToken: session)
        }
        sessionToken = nil
        Keychain.set(nil, for: Keys.token)
        Keychain.set(nil, for: Keys.email)
        license = nil
        needsPurchase = false
        deviceLimit = nil
        step = .email
    }

    /// Checkout happens on the account page (Paddle overlay); the user then comes back and presses «Проверить».
    func openCheckout(plan: String) {
        var components = URLComponents(url: LicenseConfig.accountPage, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "plan", value: plan)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    func openAccountPage() { NSWorkspace.shared.open(LicenseConfig.accountPage) }

    // MARK: Helpers

    private func run(_ work: @escaping @MainActor () async throws -> Void) async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do { try await work() } catch let failure as LicenseAPI.Failure {
            errorText = switch failure {
            case .invalidCode: String(localized: "Неверный или устаревший код.")
            case .unauthorized: String(localized: "Сеанс истёк — войдите ещё раз.")
            case .rateLimited: String(localized: "Слишком много попыток. Подождите несколько минут.")
            case .offline: String(localized: "Нет связи с сервером. Проверьте интернет.")
            case .server: String(localized: "Сервер не ответил. Попробуйте позже.")
            }
        } catch {
            errorText = String(localized: "Сервер не ответил. Попробуйте позже.")
        }
    }

    /// Verifies the token and guards against a clock moved back to keep an expired token alive.
    private static func checked(_ token: String) -> LicensePayload? {
        let defaults = UserDefaults.standard
        let now = Date()
        let latest = defaults.double(forKey: Keys.clock)
        if latest > 0, now.timeIntervalSince1970 < latest - 86_400 { return nil }
        defaults.set(max(latest, now.timeIntervalSince1970), forKey: Keys.clock)
        return LicenseVerifier.verify(token, now: now)
    }
}
