#if DEBUG
import Foundation
import StartupEngine

extension MockData {
    /// «Автозапуск» demo: a typical Mac with updaters, sync tools and a couple of leftovers.
    static var startupItems: [StartupItem] {
        let agents = h("Library/LaunchAgents")
        func app(_ name: String) -> URL { URL(fileURLWithPath: "/Applications/\(name).app") }
        func dev(_ name: String, _ team: String) -> Signer { .developerID(name: name, team: team) }
        let items: [StartupItem] = [
            StartupItem(id: "btm:4.com.getdropbox.dropbox.helper", source: .backgroundTask, group: .loginItems,
                        label: "com.getdropbox.dropbox.helper", plist: nil,
                        program: "/Applications/Dropbox.app/Contents/Library/LoginItems/DropboxHelper.app/Contents/MacOS/DropboxHelper",
                        ownerName: "Dropbox", ownerBundleID: "com.getdropbox.dropbox", ownerAppURL: app("Dropbox"),
                        signer: dev("Dropbox, Inc.", "G7HH3F8CAK"), state: .running(pid: 812)),
            StartupItem(id: "btm:2.com.raycast.macos", source: .backgroundTask, group: .loginItems,
                        label: "com.raycast.macos", plist: nil, program: "/Applications/Raycast.app/Contents/MacOS/Raycast",
                        ownerName: "Raycast", ownerBundleID: "com.raycast.macos", ownerAppURL: app("Raycast"),
                        signer: dev("Raycast Technologies Inc.", "SY64MV22J9"), disabledInSettings: true),
            StartupItem(id: agents.appendingPathComponent("com.google.GoogleUpdater.wake.plist").path, source: .userAgent,
                        group: .agents, label: "com.google.GoogleUpdater.wake",
                        plist: agents.appendingPathComponent("com.google.GoogleUpdater.wake.plist"),
                        program: h("Library/Application Support/Google/GoogleUpdater/Current/GoogleUpdater.app/Contents/MacOS/GoogleUpdater").path,
                        interval: 3600, ownerName: "Google Chrome", ownerBundleID: "com.google.Chrome",
                        ownerAppURL: app("Google Chrome"), signer: dev("Google LLC", "EQHXZ8M8AV"), state: .loaded),
            StartupItem(id: "/Library/LaunchAgents/com.adobe.ccxprocess.plist", source: .globalAgent, group: .agents,
                        label: "com.adobe.ccxprocess", plist: URL(fileURLWithPath: "/Library/LaunchAgents/com.adobe.ccxprocess.plist"),
                        program: "/Applications/Utilities/Adobe Creative Cloud Experience/CCXProcess/CCXProcess.app/Contents/MacOS/CCXProcess",
                        runAtLoad: true, ownerName: "Adobe Creative Cloud", ownerBundleID: "com.adobe.acc.AdobeCreativeCloud",
                        ownerAppURL: app("Adobe Creative Cloud"), signer: dev("Adobe Inc.", "JQ525L2MZD"), state: .running(pid: 1408)),
            StartupItem(id: agents.appendingPathComponent("us.zoom.updater.login.check.plist").path, source: .userAgent,
                        group: .agents, label: "us.zoom.updater.login.check",
                        plist: agents.appendingPathComponent("us.zoom.updater.login.check.plist"),
                        program: "/Applications/zoom.us.app/Contents/Frameworks/ZoomUpdater.app/Contents/MacOS/ZoomUpdater",
                        runAtLoad: true, ownerName: "zoom.us", ownerBundleID: "us.zoom.xos", ownerAppURL: app("zoom.us"),
                        signer: dev("Zoom Video Communications, Inc.", "BJ4HAAB9B3"), state: .notLoaded, disabledByOverride: true),
            StartupItem(id: agents.appendingPathComponent("com.spotify.webhelper.plist").path, source: .userAgent,
                        group: .agents, label: "com.spotify.webhelper",
                        plist: agents.appendingPathComponent("com.spotify.webhelper.plist"),
                        program: h("Library/Application Support/Spotify/SpotifyWebHelper").path, runAtLoad: true,
                        programMissing: true, state: .notLoaded),
            StartupItem(id: agents.appendingPathComponent("com.google.keystone.agent.plist").path, source: .userAgent,
                        group: .agents, label: "com.google.keystone.agent",
                        plist: agents.appendingPathComponent("com.google.keystone.agent.plist"), program: nil,
                        isMalformed: true, state: .notLoaded),
            StartupItem(id: "/Library/LaunchAgents/com.apple.FolderActionsDispatcher.plist", source: .globalAgent, group: .agents,
                        label: "com.apple.FolderActionsDispatcher",
                        plist: URL(fileURLWithPath: "/Library/LaunchAgents/com.apple.FolderActionsDispatcher.plist"),
                        program: "/System/Library/CoreServices/FolderActionsDispatcher.app/Contents/MacOS/FolderActionsDispatcher",
                        signer: .apple, state: .loaded, isApple: true),
            StartupItem(id: "/Library/LaunchDaemons/com.docker.vmnetd.plist", source: .daemon, group: .daemons,
                        label: "com.docker.vmnetd", plist: URL(fileURLWithPath: "/Library/LaunchDaemons/com.docker.vmnetd.plist"),
                        program: "/Library/PrivilegedHelperTools/com.docker.vmnetd", keepAlive: true,
                        ownerName: "Docker", ownerBundleID: "com.docker.docker", ownerAppURL: app("Docker"),
                        signer: dev("Docker Inc", "9BNSXJN65R"), state: .running(pid: 402)),
            StartupItem(id: "/Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist", source: .daemon, group: .daemons,
                        label: "com.microsoft.autoupdate.helper",
                        plist: URL(fileURLWithPath: "/Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist"),
                        program: "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/Microsoft Update Assistant.app/Contents/MacOS/Microsoft Update Assistant",
                        ownerName: "Microsoft AutoUpdate", ownerBundleID: "com.microsoft.autoupdate2",
                        signer: dev("Microsoft Corporation", "UBF8T346G9"), state: .loaded),
        ]
        return items
    }
}
#endif
