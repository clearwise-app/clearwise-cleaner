import Foundation

/// Where each browser keeps *cache only*. History, cookies, passwords, bookmarks, extensions and
/// profile databases are never listed here — only folders the browser rebuilds by itself.
struct BrowserCacheSpec: Sendable {
    let name: String
    /// Home-relative folders that are pure cache; each one is a single item.
    var cacheFolders: [String] = []
    /// Home-relative cache folders of sandboxed apps: the folder itself is kept, its children become items.
    var containerCacheFolders: [String] = []
    /// Home-relative Chromium "User Data" folder, whose profiles hold some regenerable caches.
    var userDataFolder: String? = nil
    /// Opera keeps its default profile directly in the user data folder.
    var userDataIsProfile = false

    /// Regenerable cache folders inside a Chromium profile (`Default`, `Profile 1`…).
    static let chromiumProfileCaches = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"]
    /// Regenerable shader caches at the top of a Chromium user data folder.
    static let chromiumUserDataCaches = ["GrShaderCache", "GraphiteDawnCache", "ShaderCache", "GPUPersistentCache"]

    static let all: [BrowserCacheSpec] = [
        BrowserCacheSpec(name: "Safari",
                         cacheFolders: ["Library/Caches/com.apple.Safari"],
                         containerCacheFolders: ["Library/Containers/com.apple.Safari/Data/Library/Caches"]),
        BrowserCacheSpec(name: "Google Chrome",
                         cacheFolders: ["Library/Caches/Google/Chrome"],
                         userDataFolder: "Library/Application Support/Google/Chrome"),
        BrowserCacheSpec(name: "Brave",
                         cacheFolders: ["Library/Caches/BraveSoftware/Brave-Browser"],
                         userDataFolder: "Library/Application Support/BraveSoftware/Brave-Browser"),
        BrowserCacheSpec(name: "Microsoft Edge",
                         cacheFolders: ["Library/Caches/Microsoft Edge"],
                         userDataFolder: "Library/Application Support/Microsoft Edge"),
        BrowserCacheSpec(name: "Arc",
                         cacheFolders: ["Library/Caches/Arc", "Library/Caches/company.thebrowser.Browser"],
                         userDataFolder: "Library/Application Support/Arc/User Data"),
        BrowserCacheSpec(name: "Vivaldi",
                         cacheFolders: ["Library/Caches/com.vivaldi.Vivaldi"],
                         userDataFolder: "Library/Application Support/Vivaldi"),
        BrowserCacheSpec(name: "Opera",
                         cacheFolders: ["Library/Caches/com.operasoftware.Opera"],
                         userDataFolder: "Library/Application Support/com.operasoftware.Opera",
                         userDataIsProfile: true),
        BrowserCacheSpec(name: String(localized: "Яндекс Браузер", bundle: .module),
                         cacheFolders: ["Library/Caches/Yandex/YandexBrowser"],
                         userDataFolder: "Library/Application Support/Yandex/YandexBrowser"),
        BrowserCacheSpec(name: "Firefox",
                         cacheFolders: ["Library/Caches/Firefox"]),
    ]

    /// Label of a browser's plain cache folder («Google Chrome · кэш»).
    static func cacheNote(_ name: String) -> String { String(localized: "\(name) · кэш", bundle: .module) }

    func candidates(in env: JunkEnvironment) -> [JunkCandidate] {
        var result: [JunkCandidate] = []
        for folder in cacheFolders {
            let url = env.homePath(folder)
            if FS.exists(url) { result.append(JunkCandidate(url, note: Self.cacheNote(name))) }
        }
        for folder in containerCacheFolders {
            for child in FS.children(of: env.homePath(folder)) {
                result.append(JunkCandidate(child, note: "\(name) · \(child.lastPathComponent)"))
            }
        }
        if let userDataFolder {
            let root = env.homePath(userDataFolder)
            for dir in Self.chromiumUserDataCaches {
                let url = root.appendingPathComponent(dir)
                if FS.exists(url) { result.append(JunkCandidate(url, note: "\(name) · \(dir)")) }
            }
            for profile in profiles(in: root) {
                for dir in Self.chromiumProfileCaches {
                    let url = profile.appendingPathComponent(dir)
                    if FS.exists(url) {
                        let profileName = profile == root ? "Default" : profile.lastPathComponent
                        result.append(JunkCandidate(url, note: "\(name) · \(profileName) · \(dir)"))
                    }
                }
            }
        }
        return result
    }

    private func profiles(in root: URL) -> [URL] {
        var result = userDataIsProfile ? [root] : []
        for child in FS.children(of: root) where FS.isDirectory(child) {
            let n = child.lastPathComponent
            if n == "Default" || n == "Guest Profile" || n.hasPrefix("Profile ") { result.append(child) }
        }
        return result
    }
}
