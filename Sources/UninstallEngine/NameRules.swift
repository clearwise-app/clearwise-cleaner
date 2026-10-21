import Foundation

/// Pure string rules shared by the remnant matcher and the orphan finder:
/// normalisation, reverse-DNS detection, stoplists.
enum NameRules {
    /// Lowercased, letters and digits only ("Google Chrome" → "googlechrome").
    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// "Bartender 6" → "Bartender", "IntelliJIdea2024.1" → "IntelliJIdea". Returns nil if nothing was stripped.
    static func strippingTrailingVersion(_ s: String) -> String? {
        let stripped = s.replacingOccurrences(of: #"[\s._-]*v?\d+([._]\d+)*$"#, with: "", options: .regularExpression)
        let trimmed = stripped.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == s ? nil : trimmed
    }

    static func isUUID(_ s: String) -> Bool {
        s.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
                options: .regularExpression) != nil
    }

    static func containsUUID(_ s: String) -> Bool {
        s.range(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
                options: .regularExpression) != nil
    }

    /// Apple Team IDs are 10 alphanumerics with letters and digits, e.g. "6N38VWS5BX" (case-insensitive,
    /// because callers often compare lowercased names).
    static func isTeamID(_ s: String) -> Bool {
        s.count == 10 && s.range(of: #"^[A-Za-z0-9]{10}$"#, options: .regularExpression) != nil
            && s.contains(where: { $0.isLetter }) && s.contains(where: { $0.isNumber })
    }

    /// First components a reverse-DNS identifier can start with.
    static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "de", "ru", "co", "app", "dev", "me", "uk", "fr", "jp", "cn", "ch", "nl",
        "se", "no", "fi", "it", "es", "pl", "cz", "be", "at", "dk", "ca", "au", "us", "info", "biz", "tv",
        "ai", "so", "sh", "xyz", "cc", "eu", "in", "kr", "br", "mx", "ua", "by", "kz", "il", "tw", "hk",
        "sg", "nz", "za", "pt", "gr", "hu", "ro", "sk", "si", "lt", "lv", "ee", "is", "ie", "ly", "to",
        "fm", "gg", "im", "pro", "design", "studio", "tech", "cloud", "software", "games", "page", "codes",
        "works", "team", "inc", "ltd", "systems", "solutions", "live", "one", "run", "site", "space", "ag",
        "md", "am", "ge", "hr", "rs", "bg", "lu", "li", "vn", "th", "my", "id", "ph", "ar", "cl", "pe",
        "edu", "gov", "mobi", "name", "ws", "vc", "gl", "re", "nu", "ninja", "zone", "dk", "su",
    ]

    /// "com.foo.bar" style identifier (≥ 3 components, known TLD first).
    static func isReverseDNS(_ s: String) -> Bool {
        let comps = s.split(separator: ".", omittingEmptySubsequences: false)
        guard comps.count >= 3, comps.allSatisfy({ !$0.isEmpty }) else { return false }
        guard topLevelDomains.contains(comps[0].lowercased()) else { return false }
        return comps.allSatisfy { c in c.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
    }

    /// Apple-owned identifiers, including legacy ones that do not start with com.apple
    /// (Shortcuts still uses the Workflow app's `is.workflow.*`).
    static let appleIDPrefixes = ["com.apple.", "is.workflow.", "systemgroup.com.apple.", "apple."]

    static func isAppleID(_ lowercasedID: String) -> Bool {
        lowercasedID == "com.apple" || appleIDPrefixes.contains { lowercasedID.hasPrefix($0) }
    }

    /// Strips "group." and "<TEAMID>." prefixes. Returns (core id, team id if any).
    static func stripGroupPrefixes(_ id: String) -> (core: String, team: String?) {
        var core = id
        var team: String?
        if let dot = core.firstIndex(of: "."), isTeamID(String(core[..<dot])) {
            team = String(core[..<dot])
            core = String(core[core.index(after: dot)...])
        }
        if core.lowercased().hasPrefix("group.") { core = String(core.dropFirst(6)) }
        if core.lowercased().hasPrefix("groups.") { core = String(core.dropFirst(7)) }
        return (core, team)
    }

    /// Helper-ish suffixes that do not change which app an identifier belongs to.
    static let helperSuffixes: [String] = [
        ".helper", ".agent", ".daemon", ".xpc", ".updater", ".launcher", ".loginitem", ".login-item",
        ".shipit", ".crashpad", ".crashreporter", ".plist", "-setapp", ".setapp", ".mas", ".appstore",
        ".extension", ".widget", ".widgets",
    ]

    static func strippingHelperSuffixes(_ id: String) -> String {
        var s = id
        var changed = true
        while changed {
            changed = false
            for suffix in helperSuffixes where s.lowercased().hasSuffix(suffix) && s.count > suffix.count + 3 {
                s = String(s.dropLast(suffix.count))
                changed = true
            }
        }
        return s
    }

    /// Words that are never enough on their own to tie a file to an app.
    static let genericNames: Set<String> = [
        "helper", "helpers", "update", "updater", "updates", "google", "microsoft", "apple", "adobe", "setup",
        "install", "installer", "launcher", "agent", "daemon", "service", "services", "settings",
        "preferences", "config", "configuration", "cache", "caches", "data", "logs", "support", "plugin",
        "plugins", "extension", "extensions", "client", "desktop", "application", "applications", "default",
        "shared", "common", "temp", "tmp", "utility", "utilities", "tools", "manager", "player", "browser",
        "editor", "viewer", "studio", "music", "photos", "video", "videos", "camera", "notes", "mail",
        "calendar", "reminders", "contacts", "messages", "maps", "books", "files", "finder", "terminal",
        "preview", "safari", "system", "library", "documents", "downloads", "pictures", "movies", "public",
        "desktop", "crashreporter", "crashpad", "diagnosticreports", "webkit", "cookies", "containers",
        "electron", "chromium", "framework", "frameworks", "resources", "macos", "native", "mac", "macapp",
        "store", "appstore", "local", "global", "user", "users", "share", "sync", "backup", "backups",
        "network", "server", "monitor", "assistant", "recorder", "converter", "cleaner", "uninstaller",
        "launch", "login", "loginitems", "keychain", "license", "licenses", "account", "accounts", "main",
        "core", "base", "beta", "test", "tests", "debug", "release", "nightly", "preview", "stable",
        "jetbrains", "mozilla", "autodesk", "oracle", "java", "python", "node", "nodejs", "github", "gitlab",
        "docker", "homebrew", "openai", "anthropic", "facebook", "meta", "amazon", "yandex", "mailru",
        "xcode", "developer", "simulator", "coresimulator", "icloud", "siri", "spotlight", "dock",
        "audio", "sound", "media", "image", "images", "office", "teams", "drive", "cloud", "online",
    ]

    /// Suffix words that may follow the app name in a folder name ("SpotifyHelper", "Slack-Crashpad").
    static let nameSuffixWords: [String] = [
        "helper", "helpers", "updater", "update", "agent", "launcher", "crashpad", "crashreporter", "crashes",
        "shipit", "beta", "nightly", "canary", "dev", "insiders", "data", "cache", "caches", "logs", "log",
        "support", "files", "temp", "tmp", "backup", "backups", "pro", "lite", "free", "setapp", "mas",
        "desktop", "app", "mac", "macos", "osx", "settings", "prefs", "preferences", "service", "daemon",
    ]

    /// Generic trailing components of bundle IDs ("com.spotify.client" → the name is "spotify").
    static let genericIDComponents: Set<String> = [
        "client", "app", "mac", "macos", "osx", "desktop", "helper", "agent", "main", "application",
        "launcher", "daemon", "service", "beta", "release", "x", "macapp", "installer", "updater",
        "loginitem", "pro", "free", "lite", "mas", "setapp", "stable", "electron", "nativeapp",
    ]

    /// Dot-folders in ~ owned by CLI tools rather than by GUI apps of the same name.
    static let cliDotFolders: Set<String> = [
        "claude", "codex", "cache", "config", "local", "ssh", "gnupg", "npm", "nvm", "cargo", "rustup",
        "gradle", "m2", "kube", "aws", "azure", "gcloud", "zsh_sessions", "oh-my-zsh", "pyenv", "rbenv",
        "copilot", "swiftpm", "trash", "cups", "git", "bundle", "gem", "yarn", "pnpm", "bun", "deno", "conda",
        "android", "expo", "terraform", "vagrant", "minikube", "colima", "lima", "orbstack",
    ]

    /// Plain-named (non reverse-DNS) folders in Library locations that belong to macOS itself.
    static let appleFolderNames: Set<String> = Set([
        "AddressBook", "Animoji", "CallHistoryDB", "CallHistoryTransactions", "CloudDocs", "CrashReporter",
        "DifferentialPrivacy", "FaceTime", "FileProvider", "Knowledge", "Music", "SESStorage", "iCloud",
        "icdd", "locationaccessstored", "networkserviceproxy", "homeenergyd", "Dock", "Assistant", "Baseband",
        "CoreSimulator", "DiagnosticReports", "PrivacyPreservingMeasurement", "SiriTTSService", "CloudKit",
        "FamilyCircle", "GameKit", "GeoServices", "PassKit", "familycircled", "mbuseragent", "App Store",
        "Apple", "BTServer", "GarageBand", "Logic", "ProApps", "Script Editor", "iLifeMediaBrowser",
        "ColorSync", "Desktop Pictures", "WindowServer", "Xsan", "hidfw-crashlogs", "MobileSync", "Xcode",
        "Developer", "SyncServices", "Spotlight", "Safari", "Photos", "Mail", "Messages", "Calendars",
        "Containers", "Accounts", "Keychains", "Metadata", "Preferences", "Caches", "Logs", "Cookies",
        "WebKit", "HTTPStorages", "Group Containers", "Application Scripts", "Saved Application State",
        "AppleMediaServices", "Audio", "ScreenTime", "Siri", "Wallpaper", "Weather", "Stocks", "Home",
        "News", "Podcasts", "TV", "Books", "Maps", "Notes", "Reminders", "Shortcuts", "Freeform", "Journal",
        "Passwords", "Image Capture", "iTunes", "iPod", "Firmware", "Installer", "SoftwareUpdate",
        "DiskImages", "Bluetooth", "com.apple", "Quick Look", "QuickLook", "Mobile Documents", "CloudStorage",
        "IdentityServices", "PersonalizationPortrait", "Trial", "Biome", "Sharing", "StatusKit", "Daemon Containers",
        "Autosave Information", "Calendar", "Contacts", "Fonts", "Input Methods", "Keyboard Layouts",
        "Spelling", "Sounds", "Voices", "Speech", "Screen Savers", "ColorPickers", "Compositions",
        "Favorites", "Printers", "Services", "PreferencePanes", "Internet Plug-Ins", "Frameworks",
        "Extensions", "Filesystems", "Graphics", "Modem Scripts", "OpenDirectory", "DirectoryService",
        "SystemConfiguration", "Logging", "Managed Preferences", "Security", "Updates", "Receipts",
        "Mozilla", "MCXTools", "LKDC-setup", "Ubiquity", "AppleIntelligence", "GenerativeModels",
        "Translation", "Feedback Assistant", "Family", "Accessibility", "Default.store",
    ].map { $0.lowercased() })
}
