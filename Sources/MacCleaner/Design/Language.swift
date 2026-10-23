import AppKit
import Foundation

/// The app's language: Russian (the source) or English, chosen in Settings → Язык, or whatever macOS prefers.
/// Applied through `AppleLanguages`, the way macOS itself switches an app's language, so it takes effect
/// on the next launch; `relaunch()` does that.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, russian = "ru", english = "en"

    static let key = "settings.language.v1"
    var id: String { rawValue }

    static var chosen: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    /// The language the running app shows, "ru" or "en". English only when the main bundle carries it
    /// (the app: Contents/Resources/en.lproj); a bare build or a test host stays Russian.
    static let running: String = {
        guard Bundle.main.localizations.contains(where: { $0.hasPrefix("en") }) else { return "ru" }
        let preferred = Bundle.main.preferredLocalizations.first ?? "ru"
        return preferred.hasPrefix("en") ? "en" : "ru"
    }()

    static var isEnglish: Bool { running == "en" }

    /// Numbers, dates and units in the app's language.
    static var locale: Locale { Locale(identifier: isEnglish ? "en_US" : "ru_RU") }

    /// What macOS picks for the app without an override: the first of the user's languages the app has, Russian or
    /// English, and English when neither is listed — a German or Turkish Mac gets English, not Russian. Read from
    /// the global domain, so the app's own override (an explicit choice) does not mask the system's list.
    static var systemLanguage: String {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        for code in global ?? Locale.preferredLanguages {
            if code.hasPrefix("ru") { return "ru" }
            if code.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    /// What a choice would show, before the relaunch.
    var resolved: String {
        switch self {
        case .system: Self.systemLanguage
        case .russian: "ru"
        case .english: "en"
        }
    }

    /// Starts a new copy of the app and quits this one.
    @MainActor static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open -n \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
