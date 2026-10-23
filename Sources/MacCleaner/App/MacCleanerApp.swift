import SwiftUI
import AppKit

@main
enum Entry {
    static func main() {
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            SnapshotRunner.run(outputDirectory: URL(fileURLWithPath: args[i + 1]),
                               only: args.firstIndex(of: "--only").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil },
                               live: args.contains("--live"))
            return
        }
        #endif
        MacCleanerApp.main()
    }
}

struct MacCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 720)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refreshSystemState()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 800)
        .commands { CleanerCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// The main window: restores the selected module per window (`@SceneStorage`).
private struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("selectedModule") private var storedModule = AppModule.smartCare.rawValue

    var body: some View {
        RootView()
            .onAppear {
                if let module = AppModule(rawValue: storedModule), module != model.selection {
                    model.selection = module
                }
            }
            .onChange(of: model.selection) { _, module in storedModule = module.rawValue }
    }
}

/// Menus: «Разделы» (⌘1…⌘6), «Очистка» (⌘R, ⌘⌫, ⌘F) and «Полный доступ к диску…» in the app menu.
/// Every item is disabled while a confirmation, the cleaning scene or the access flow is up.
struct CleanerCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .appSettings) {
            Button("Полный доступ к диску…") { model.presentAccessSheet() }
                .disabled(model.isModalActive)
        }

        CommandMenu("Разделы") {
            ForEach(Array(AppModule.allCases.enumerated()), id: \.element) { index, module in
                Button(module.title) { model.select(module) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .disabled(model.isModalActive)
            }
        }

        CommandMenu("Очистка") {
            Button("Сканировать заново") { model.rescanCurrent() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.canRescan)
            Button(model.primaryActionTitle) { model.primaryActionCurrent() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.canPerformPrimaryAction)
            Divider()
            Button("Найти") { model.requestSearchFocus() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model.isModalActive)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A cleanup in progress is not cut short: half of it would sit in the Trash with no screen saying so.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard AppModel.shared.cleaning != nil else { return .terminateNow }
            NSSound.beep()
            return .terminateCancel
        }
    }

    /// .app dropped on the Dock icon or opened with MacCleaner.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            _ = AppModel.shared.handleDrop(urls)
        }
    }
}
