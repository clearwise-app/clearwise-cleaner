import Foundation

/// Everything that ties the app to the subscription backend (server/) and to App Store Connect.
/// Fill in before a release; the placeholders keep the app in "trial only" mode.
enum LicenseConfig {
    /// The server from server/docker-compose.yml. Info.plist key `ClearwiseAPIBase` overrides it
    /// (handy for a staging server: `defaults write` does not reach Info.plist, so set it in build_app.sh).
    static let apiBase: URL = {
        if let s = Bundle.main.object(forInfoDictionaryKey: "ClearwiseAPIBase") as? String, let url = URL(string: s) { return url }
        return URL(string: "https://api.clearwise.app")!
    }()

    /// LICENSE_PUBLIC_KEY from the server's .env (`npm run keys`): base64 of the raw 32-byte Ed25519 key.
    /// Only the public half lives here; tokens signed by any other key are rejected.
    static let publicKey = "REPLACE_WITH_LICENSE_PUBLIC_KEY"

    /// Free days from the first launch on this Mac (site edition only; the App Store edition uses
    /// an introductory offer configured in App Store Connect instead, as guideline 3.1.1 asks).
    static let trialDays = 7

    /// How often a valid token is refreshed while online. The token itself lasts LICENSE_OFFLINE_DAYS.
    static let refreshInterval: TimeInterval = 24 * 3600

    /// Auto-renewable subscriptions of the App Store edition, one subscription group.
    /// Create them in App Store Connect with exactly these ids (docs/APP_STORE.md).
    static let storeProductIDs = ["app.clearwise.lite.pro.monthly", "app.clearwise.lite.pro.yearly"]

    static var accountPage: URL { apiBase.appending(path: "account") }
    static let termsURL = URL(string: "https://clearwise-app.github.io/terms.html")!
    static let privacyURL = URL(string: "https://clearwise-app.github.io/privacy.html")!
}
