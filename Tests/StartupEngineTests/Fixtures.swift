import Foundation
@testable import StartupEngine

/// Text in the shape `launchctl` and `sfltool dumpbtm` print on macOS 26 (names and paths are made up).
enum Samples {
    static let guiPrint = """
    gui/501 = {
    \ttype = user
    \thandle = 501
    \tservices = {
    \t\t   73581      - \tapplication.com.example.editor.2901876.2901881
    \t\t       0      0 \tcom.example.sync.agent
    \t\t     812      - \tcom.example.vpn.helper
    \t\t       0     78 \tcom.example.broken
    \t\t     930      - \tcom.example.notes.launcher
    \t\t       0      - \tcom.example.sync.helper
    \t}

    \tunmanaged processes = {
    \t\t0x1234 = 99
    \t}
    }
    """

    static let systemPrint = """
    system = {
    \ttype = system
    \tservices = {
    \t\t     163      - \tcom.apple.runningboardd
    \t\t     404      - \tcom.example.vpn.daemon
    \t}
    }
    """

    static let guiDisabled = """
    \tdisabled services = {
    \t\t"com.apple.Siri.agent" => enabled
    \t\t"com.example.updater" => disabled
    \t\t"com.example.legacy" => true
    \t\t"com.example.legacy2" => false
    \t}
    """

    static let systemDisabled = """
    \tdisabled services = {
    \t\t"com.apple.ftpd" => disabled
    \t}
    """

    static func btm(home: String) -> String {
        """
        ========================
         Records for UID -2 : FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE
        ========================

         ServiceManagement migrated: true
         LaunchServices registered: false

         Items:


        ========================
         Records for UID 501 : 24B434E3-9AA4-4A2D-BEE5-B0342329698C
        ========================

         ServiceManagement migrated: true
         LaunchServices registered: true

         Items:

         #1:
                         UUID: 9F6A4325-2A4D-4CA7-AD43-462AE0543CC1
                         Name: (null)
               Developer Name: (null)
                         Type: developer (0x20)
                        Flags: [  ] (0)
                  Disposition: [disabled, allowed, not notified] (0x2)
                   Identifier: Unknown Developer
                          URL: (null)
                   Generation: 1

         #2:
                         UUID: EB55BD5E-7319-45FF-8DDA-74C12A26E9C4
                         Name: Example Sync
               Developer Name: Example Inc.
              Team Identifier: ABCDE12345
                         Type: app (0x2)
                        Flags: [  ] (0)
                  Disposition: [disabled, allowed, not notified] (0x2)
                   Identifier: 2.com.example.sync
                          URL: file:///Applications/Example%20Sync.app/
                   Generation: 2
            Bundle Identifier: com.example.sync

         #3:
                         UUID: AEDBD8EE-B9E8-4052-94AC-5F1A705B837F
                         Name: SyncAgent
               Developer Name: Example Inc.
              Team Identifier: ABCDE12345
                         Type: legacy agent (0x10008)
                        Flags: [ legacy ] (0x1)
                  Disposition: [disabled, allowed, notified] (0xa)
                   Identifier: 8.com.example.sync.agent
                          URL: file://\(home)/Library/LaunchAgents/com.example.sync.agent.plist
              Executable Path: /Applications/Example Sync.app/Contents/MacOS/SyncAgent
                   Generation: 2
            Assoc. Bundle IDs: [ com.example.sync ]
            Parent Identifier: 2.com.example.sync

         #4:
                         UUID: 06BAA413-2559-46AC-9430-B5FB8DF5F66C
                         Name: Example Sync Helper
               Developer Name: Example Inc.
              Team Identifier: ABCDE12345
                         Type: agent (0x8)
                        Flags: [  ] (0)
                  Disposition: [enabled, allowed, notified] (0xb)
                   Identifier: 8.com.example.sync.helper
                          URL: Contents/Library/LaunchAgents/com.example.sync.helper.plist
                   Generation: 1
            Bundle Identifier: com.example.sync.helper
            Parent Identifier: 2.com.example.sync

         #5:
                         UUID: 9AF3545E-532D-48CB-B402-2511EF7BAD07
                         Name: Notes Widget
               Developer Name: (null)
                         Type: login item (0x4)
                        Flags: [  ] (0)
                  Disposition: [enabled, allowed, notified] (0xb)
                   Identifier: 4.com.example.notes.launcher
                          URL: Contents/Library/LoginItems/Notes%20Launcher.app
                   Generation: 1
            Bundle Identifier: com.example.notes.launcher
            Parent Identifier: 2.com.example.notes

         #6:
                         UUID: BFBCDBF3-A7A4-40D8-B53D-3F864DCD1364
                         Name: Example Notes
               Developer Name: (null)
                         Type: app (0x2)
                        Flags: [ sandboxed ] (0x40)
                  Disposition: [enabled, allowed, notified] (0xb)
                   Identifier: 2.com.example.notes
                          URL: file:///Applications/Example%20Notes.app/
                   Generation: 1
            Bundle Identifier: com.example.notes

         #7:
                         UUID: 7CD040A9-D70D-4F47-9848-F7761242AF6F
                         Name: Preview.appex
               Developer Name: (null)
                         Type: quicklook (0x800)
                        Flags: [ sandboxed ] (0x40)
                  Disposition: [enabled, allowed, not notified] (0x3)
                   Identifier: 2048.com.example.notes.preview
                          URL: Contents/PlugIns/Preview.appex
                   Generation: 0
            Parent Identifier: 2.com.example.notes

         #8:
                         UUID: 337410AC-E3C9-470F-94DA-18CB44C6B20D
                         Name: Mail Helper
               Developer Name: (null)
                         Type: login item (0x4)
                        Flags: [  ] (0)
                  Disposition: [enabled, allowed, notified] (0xb)
                   Identifier: 4.com.apple.mail.helper
                          URL: file:///System/Applications/Mail.app/Contents/Library/LoginItems/MailHelper.app/
                   Generation: 1
            Bundle Identifier: com.apple.mail.helper

        ========================
         Records for UID 502 : 11111111-2222-3333-4444-555555555555
        ========================

         Items:

         #1:
                         UUID: 00000000-0000-0000-0000-000000000001
                         Name: Someone Else
                         Type: login item (0x4)
                  Disposition: [enabled, allowed, notified] (0xb)
                   Identifier: 4.com.example.other.user
                          URL: file:///Applications/Other.app/
        """
    }
}

/// launchd and Launch Services stand-ins: canned `launchctl` output that the actions can change.
final class FakeSystem: @unchecked Sendable {
    private let lock = NSLock()
    var guiPrint = Samples.guiPrint
    var systemPrint = Samples.systemPrint
    var guiDisabled = Samples.guiDisabled
    var systemDisabled = Samples.systemDisabled
    var btm: String?
    var apps: [String: URL] = [:]
    var signers: [String: Signer] = [:]
    /// Every launchctl call the code made, as argument lists.
    private(set) var calls: [[String]] = []
    /// Labels `launchctl disable` was called for (the fake override database).
    private var overrides: [String: Bool] = [:]

    func environment(root: URL, uid: uid_t = getuid()) -> StartupEnvironment {
        StartupEnvironment(
            uid: uid,
            userAgents: root.appendingPathComponent("home/Library/LaunchAgents"),
            globalAgents: root.appendingPathComponent("Library/LaunchAgents"),
            daemons: root.appendingPathComponent("Library/LaunchDaemons"),
            appFolders: [root.appendingPathComponent("Applications")],
            run: { [self] tool, args, _ in self.run(tool, args) },
            appForBundleID: { [self] id in self.lock.withLock { self.apps[id] } },
            signer: { [self] path in self.lock.withLock { self.signers[path] ?? .unknown } })
    }

    private func run(_ tool: String, _ args: [String]) -> StartupEnvironment.Output? {
        lock.withLock {
            if tool.hasSuffix("sfltool") { return btm.map { .init(status: 0, text: $0) } }
            calls.append(args)
            switch args.first {
            case "print": return .init(status: 0, text: args[1] == "system" ? systemPrint : guiPrint)
            case "print-disabled":
                let base = args[1] == "system" ? systemDisabled : guiDisabled
                let extra = overrides.map { "\t\t\"\($0.key)\" => \($0.value ? "disabled" : "enabled")" }
                return .init(status: 0, text: base + "\n" + extra.joined(separator: "\n"))
            case "disable", "enable":
                let label = String(args[1].split(separator: "/").last ?? "")
                overrides[label] = args[0] == "disable"
                return .init(status: 0, text: "")
            default: return .init(status: 0, text: "")
            }
        }
    }
}
