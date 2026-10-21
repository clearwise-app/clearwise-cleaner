import SwiftUI
import AppKit

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            SnapshotRunner.run(outputDirectory: URL(fileURLWithPath: args[i + 1]),
                               only: args.firstIndex(of: "--only").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil },
                               live: args.contains("--live"))
        } else {
            MacCleanerApp.main()
        }
    }
}

struct MacCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 720)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refreshSystemState()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// .app dropped on the Dock icon or opened with MacCleaner.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            _ = AppModel.shared.handleDrop(urls)
        }
    }
}
