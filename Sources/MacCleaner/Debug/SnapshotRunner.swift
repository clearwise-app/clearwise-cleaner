#if DEBUG
// Snapshot / mock tooling: compiled out of release builds (it can render real scan results to disk).
import SwiftUI
import AppKit
import CleanerKit

/// `MacCleaner --snapshot <dir> [--only <name-substring>]` renders every module's key states with mock
/// data into PNGs (1280×800 @2x) and exits. Views are hosted in an offscreen window and captured with
/// `cacheDisplay`, which keeps AppKit-backed controls, scroll views and shadows. No engine is ever called.
@MainActor
enum SnapshotRunner {
    struct Scene {
        let name: String
        var fullDiskAccess = true
        var size = NSSize(width: 1280, height: 800)
        /// Renders this instead of `RootView` (states that need closures only modules wire up).
        var content: (@MainActor (AppModel) -> AnyView)? = nil
        let configure: @MainActor (AppModel) async -> Void
    }

    nonisolated static func run(outputDirectory: URL, only: String?, live: Bool = false) {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.appearance = NSAppearance(named: .darkAqua)
            Task { @MainActor in
                try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                for scene in (live ? liveScenes : scenes) where only.map({ scene.name.contains($0) }) ?? true {
                    await render(scene, live: live, to: outputDirectory.appendingPathComponent(scene.name + ".png"))
                }
                exit(0)
            }
            app.run()
        }
    }

    private static func render(_ scene: Scene, live: Bool, to url: URL) async {
        let model = AppModel(probeSystem: live)
        if !live {
            model.hasFullDiskAccess = scene.fullDiskAccess
            model.disk = DiskUsage(name: "Macintosh HD", total: 494_380_000_000, available: 182_600_000_000)
            model.storage.apply(MockData.storage)
        }
        let started = Date()
        await scene.configure(model)
        if live { print("live scene \(scene.name): \(Int(Date().timeIntervalSince(started)))s") }

        let size = scene.size
        let root = (scene.content?(model) ?? AnyView(RootView()))
            .environment(model)
            .environment(\.isSnapshot, true)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            print("snapshot:", url.path)
        }
        window.orderOut(nil)
    }

    // MARK: Scenes

    static var scenes: [Scene] {
        [
            Scene(name: "01_smartcare_idle") { m in m.selection = .smartCare },
            Scene(name: "02_smartcare_scanning") { m in
                m.selection = .smartCare
                m.smartCare.phase = .scanning
                m.junk.phase = .scanning
                m.junk.progress = ScanProgress(phase: "Кэш браузеров", fraction: 0.64,
                                               currentPath: MockData.h("Library/Caches/Google/Chrome/Default/Cache/Cache_Data").path)
                m.oldFiles.phase = .scanning
                m.oldFiles.progress = ScanProgress(phase: "Загрузки", fraction: 0.38)
                m.uninstaller.applyOrphans(MockData.orphans)
            },
            Scene(name: "03_smartcare_results") { m in
                m.selection = .smartCare
                fillAll(m)
                m.smartCare.phase = .results
            },
            Scene(name: "03b_smartcare_junk_open") { m in
                m.selection = .smartCare
                fillAll(m)
                m.smartCare.phase = .results
                m.smartCare.expanded = .junk
                if let first = m.junk.categories.first { m.junk.expanded = [first.id] }
            },
            Scene(name: "03c_smartcare_leftovers_on") { m in
                m.selection = .smartCare
                fillAll(m)
                m.smartCare.phase = .results
                m.smartCare.setIncluded(.leftovers, true)
                m.smartCare.expanded = .leftovers
            },
            Scene(name: "03d_smartcare_oldfiles_open") { m in
                m.selection = .smartCare
                fillAll(m)
                m.smartCare.phase = .results
                m.smartCare.expanded = .oldFiles
            },
            Scene(name: "04_smartcare_done") { m in
                m.selection = .smartCare
                m.smartCare.phase = .done
                m.smartCare.result = RemovalResult(removed: Array(repeating: MockData.h("x"), count: 1_284),
                                                   failed: MockData.failures, freedBytes: 13_870_000_000)
            },
            Scene(name: "05_junk_idle_noFDA", fullDiskAccess: false) { m in m.selection = .junk },
            Scene(name: "06_junk_scanning") { m in
                m.selection = .junk
                m.junk.phase = .scanning
                m.junk.progress = ScanProgress(phase: "Xcode: DerivedData", fraction: 0.47,
                                               currentPath: MockData.h("Library/Developer/Xcode/DerivedData/MacCleaner-dkqhzfxbtwy/Build/Intermediates.noindex").path)
            },
            Scene(name: "07_junk_results") { m in
                m.selection = .junk
                m.junk.apply(MockData.junk)
                m.junk.expanded = ["user-caches"]
            },
            Scene(name: "07c_junk_electron") { m in
                m.selection = .junk
                m.junk.apply(MockData.junk)
                m.junk.notes = MockData.junkNotes
                m.junk.expanded = ["electron-app-caches"]
            },
            Scene(name: "08_junk_confirm") { m in
                m.selection = .junk
                m.junk.apply(MockData.junk)
                m.junk.requestClean()
            },
            Scene(name: "09_junk_done") { m in
                m.selection = .junk
                m.junk.phase = .done
                m.junk.result = RemovalResult(removed: Array(repeating: MockData.h("x"), count: 342),
                                              failed: [], freedBytes: 3_240_000_000)
            },
            Scene(name: "10_uninstaller_idle") { m in m.selection = .uninstaller },
            Scene(name: "11_uninstaller_app") { m in
                m.selection = .uninstaller
                loadApps(m)
                m.uninstaller.phase = .results
                selectChrome(m)
            },
            Scene(name: "12_uninstaller_batch") { m in
                m.selection = .uninstaller
                loadApps(m)
                m.uninstaller.phase = .results
                selectChrome(m)
                checkApps(m, ["Xcode-beta", "GarageBand", "iMovie"])
            },
            Scene(name: "12b_uninstaller_confirm") { m in
                m.selection = .uninstaller
                loadApps(m)
                m.uninstaller.phase = .results
                selectChrome(m)
                m.uninstaller.requestUninstall()
            },
            Scene(name: "13_uninstaller_leftovers") { m in
                m.selection = .uninstaller
                loadApps(m)
                m.uninstaller.phase = .results
                m.uninstaller.tab = .leftovers
                m.uninstaller.applyOrphans(MockData.orphans)
            },
            Scene(name: "14_uninstaller_done") { m in
                m.selection = .uninstaller
                m.uninstaller.phase = .done
                m.uninstaller.resultTitle = "«Google Chrome» удалено"
                m.uninstaller.result = RemovalResult(removed: Array(repeating: MockData.h("x"), count: 11),
                                                     failed: [], freedBytes: 4_431_000_000)
            },
            // Batch at the compact size: one app still being searched for leftovers, one running.
            Scene(name: "uninstaller_batch_summary", size: NSSize(width: 1100, height: 720)) { m in
                m.selection = .uninstaller
                loadApps(m)
                m.uninstaller.phase = .results
                selectChrome(m)
                checkApps(m, ["Xcode-beta", "GarageBand", "iMovie", "Google Chrome", "TokenWatch"], pending: ["TokenWatch"])
            },
            Scene(name: "orphans_empty") { m in
                m.selection = .uninstaller
                loadApps(m)
                m.uninstaller.phase = .results
                m.uninstaller.tab = .leftovers
                m.uninstaller.applyOrphans([])
            },
            Scene(name: "uninstaller_system_app") { m in
                m.selection = .uninstaller
                loadApps(m)
                m.uninstaller.phase = .results
                m.uninstaller.showSystemApps = true
                m.uninstaller.sort = .name
                m.uninstaller.selectedAppID = URL(fileURLWithPath: "/Applications/Safari.app")
                m.uninstaller.remnantsLoading = false
            },
            Scene(name: "15_oldfiles_idle") { m in m.selection = .oldFiles },
            Scene(name: "16_oldfiles_results") { m in
                m.selection = .oldFiles
                m.oldFiles.apply(MockData.oldFiles, mode: .old)
                m.oldFiles.selection = Set(MockData.oldFiles.prefix(3).map(\.id))
            },
            Scene(name: "17_diskmap_idle") { m in m.selection = .diskMap },
            Scene(name: "18_diskmap_scanning") { m in
                m.selection = .diskMap
                m.diskMap.phase = .scanning
                m.diskMap.progress = ScanProgress(phase: "Считаем размеры папок", fraction: 0.71,
                                                  currentPath: MockData.h("Library/Application Support/MobileSync").path)
            },
            Scene(name: "19_diskmap_results") { m in
                m.selection = .diskMap
                m.diskMap.apply(MockData.diskTree)
                m.diskMap.hoveredID = m.diskMap.root?.children.first { $0.name == "Movies" }?.id
            },
            Scene(name: "20_diskmap_zoom_collector") { m in
                m.selection = .diskMap
                m.diskMap.apply(MockData.diskTree)
                if let lib = m.diskMap.root?.children.first(where: { $0.name == "Library" }) {
                    m.diskMap.stack.append(lib)
                    if let dev = lib.children.first(where: { $0.name == "Developer" }) {
                        m.diskMap.collect(dev.children[0].children[1], parent: dev.children[0])
                        m.diskMap.collect(dev.children[1], parent: dev)
                    }
                }
                if let dl = m.diskMap.root?.children.first(where: { $0.name == "Downloads" }) {
                    m.diskMap.collect(dl.children[0], parent: dl)
                }
            },
            Scene(name: "dup_idle") { m in m.selection = .duplicates },
            Scene(name: "dup_scanning") { m in
                m.selection = .duplicates
                m.duplicates.phase = .scanning
                m.duplicates.progress = ScanProgress(phase: "Ищем файлы — Загрузки", fraction: 0.14,
                                                     currentPath: MockData.h("Downloads/Telegram Desktop/DSC_0142.jpg").path)
            },
            Scene(name: "dup_results") { m in
                m.selection = .duplicates
                m.duplicates.apply(MockData.duplicates)
            },
            Scene(name: "dup_rule_hint") { m in
                m.selection = .duplicates
                m.duplicates.apply(MockData.duplicates)
                // The user kept a second copy of the video, then tried to remove the last kept copy of the ISO.
                if let video = m.duplicates.groups.first(where: { $0.kind == .video }) {
                    m.duplicates.setRemove(false, video.files[2], in: video)
                }
                if let iso = m.duplicates.groups.first(where: { $0.kind == .diskImage }),
                   let kept = iso.files.first(where: { !m.duplicates.isMarked($0) }) {
                    m.duplicates.setRemove(true, kept, in: iso)
                }
            },
            Scene(name: "dup_confirm") { m in
                m.selection = .duplicates
                m.duplicates.apply(MockData.duplicates)
                m.duplicates.requestTrash()
            },
            Scene(name: "dup_done") { m in
                m.selection = .duplicates
                m.duplicates.phase = .done
                m.duplicates.result = RemovalResult(removed: Array(repeating: MockData.h("x"), count: 14),
                                                    failed: [RemovalFailure(url: MockData.h("Desktop/Скан диплома.pdf"),
                                                                            reason: "Операция не разрешена: файл заблокирован")],
                                                    freedBytes: 12_620_000_000)
            },
            Scene(name: "dup_compact_results", size: NSSize(width: 1100, height: 720)) { m in
                m.selection = .duplicates
                m.duplicates.apply(MockData.duplicates)
                m.duplicates.kindFilter = .document
            },
            Scene(name: "dup_compact_idle", size: NSSize(width: 1100, height: 720)) { m in m.selection = .duplicates },
            Scene(name: "21_compact_smartcare_results", size: NSSize(width: 1100, height: 720)) { m in
                m.selection = .smartCare
                fillAll(m)
                m.smartCare.phase = .results
            },
            Scene(name: "22_compact_oldfiles_idle", size: NSSize(width: 1100, height: 720)) { m in m.selection = .oldFiles },
            // Wave 2D: empty results of Старые файлы / Дубликаты, and a refused «+» in Карта диска.
            Scene(name: "oldfiles_empty") { m in
                m.selection = .oldFiles
                m.oldFiles.apply([], mode: .old)
            },
            Scene(name: "dup_empty") { m in
                m.selection = .duplicates
                m.duplicates.apply([])
            },
            Scene(name: "diskmap_refusal") { m in
                m.selection = .diskMap
                m.diskMap.apply(MockData.diskTree)
                m.diskMap.hoveredID = m.diskMap.root?.children.first { $0.name == "Library" }?.id
                // A protected folder, refused by the real SafetyGuard rule.
                m.diskMap.collect(CollectedItem(url: URL(fileURLWithPath: "/System/Library"), size: 9_000_000_000, isDirectory: true))
            },
            Scene(name: "23_compact_uninstaller", size: NSSize(width: 1100, height: 720)) { m in
                m.selection = .uninstaller
                loadApps(m)
                m.uninstaller.phase = .results
                selectChrome(m)
            },
            // Full-screen cleaning scene (fake progress, frozen animation — see MockCleaning).
            Scene(name: "clean_junk_25") { m in MockCleaning.junk(m, fraction: 0.25) },
            Scene(name: "clean_junk_70") { m in MockCleaning.junk(m, fraction: 0.7) },
            Scene(name: "clean_smartcare_45") { m in MockCleaning.junk(m, fraction: 0.45, module: .smartCare) },
            Scene(name: "clean_uninstall_50") { m in MockCleaning.uninstall(m, fraction: 0.5) },
            Scene(name: "clean_uninstall_admin") { m in MockCleaning.uninstallAdmin(m) },
            Scene(name: "clean_orphans_60") { m in MockCleaning.orphans(m, fraction: 0.6) },
            Scene(name: "clean_batch_40") { m in MockCleaning.batch(m, fraction: 0.4) },
            Scene(name: "clean_dup_55") { m in MockCleaning.duplicates(m, fraction: 0.55) },
            Scene(name: "clean_done_transition") { m in MockCleaning.done(m) },
            // Completion with refusals and one action per kind (closures wired here; modules wire them in wave 2).
            Scene(name: "done_failures_actions", content: completionScene(compact: false)) { _ in },
            Scene(name: "done_failures_compact", size: NSSize(width: 1100, height: 720),
                  content: completionScene(compact: true)) { _ in },
            Scene(name: "done_all_failed", content: completionScene(compact: false, allFailed: true)) { _ in },
            Scene(name: "done_permanent", content: completionScene(compact: false, permanent: true)) { _ in },
            // Full Disk Access granted, macOS still refuses a few files: no «Дать доступ», a plain «nothing to do».
            Scene(name: "done_protected", content: completionScene(compact: false, protectedFailures: true)) { _ in },
            Scene(name: "08b_junk_confirm_permanent") { m in
                m.selection = .junk
                m.junk.apply(MockData.junk)
                m.ask(.make(.deleteForever, title: "Очистить Корзину?", count: 37, bytes: 2_400_000_000, tint: .junk) {})
            },
            Scene(name: "16b_oldfiles_confirm") { m in
                m.selection = .oldFiles
                m.oldFiles.apply(MockData.oldFiles, mode: .old)
                m.ask(.make(.trash, count: 3, bytes: 8_420_000_000, noun: .files, tint: .oldFiles) {})
            },
            Scene(name: "07b_junk_results_noFDA", fullDiskAccess: false) { m in
                m.selection = .junk
                m.junk.apply(MockData.junk)
            },
            // Empty states: nothing found (Smart Care: «Mac в порядке»; Junk: «Мусора не найдено»), with and without access.
            Scene(name: "smartcare_empty") { m in
                m.selection = .smartCare
                m.smartCare.phase = .results
            },
            Scene(name: "smartcare_empty_noFDA", fullDiskAccess: false) { m in
                m.selection = .smartCare
                m.smartCare.phase = .results
            },
            Scene(name: "junk_empty") { m in
                m.selection = .junk
                m.junk.apply([])
            },
            Scene(name: "junk_empty_noFDA", fullDiskAccess: false) { m in
                m.selection = .junk
                m.junk.apply([])
            },
            // Trash in the selection: «Удалить навсегда» on the round button and in the confirmation.
            Scene(name: "junk_trash_selected") { m in
                m.selection = .junk
                m.junk.apply(MockData.junk)
                if let trash = m.junk.categories.first(where: { $0.id == "trash" }) { m.junk.toggle(trash) }
            },
            Scene(name: "junk_trash_confirm") { m in
                m.selection = .junk
                m.junk.apply(MockData.junk)
                if let trash = m.junk.categories.first(where: { $0.id == "trash" }) { m.junk.toggle(trash) }
                m.junk.requestClean()
            },
            Scene(name: "clean_compact_junk_40", size: NSSize(width: 1100, height: 720)) { m in MockCleaning.junk(m, fraction: 0.4) },
            Scene(name: "clean_compact_uninstall_admin", size: NSSize(width: 1100, height: 720)) { m in MockCleaning.uninstallAdmin(m) },
            // Sidebar disk widget: category segments, a hovered segment's tooltip, the full breakdown card.
            Scene(name: "storage_sidebar") { m in m.selection = .junk },
            Scene(name: "storage_hover_segment") { m in
                m.selection = .junk
                m.storage.debugHovered = .developer
            },
            Scene(name: "storage_popover") { m in
                m.selection = .junk
                m.storage.debugShowsDetails = true
                m.storage.debugHovered = .media
            },
            Scene(name: "storage_popover_noFDA", fullDiskAccess: false) { m in
                m.selection = .oldFiles
                var b = MockData.storage
                b.fullDiskAccess = false
                m.storage.apply(b)
                m.storage.debugShowsDetails = true
            },
            Scene(name: "storage_loading") { m in
                m.selection = .junk
                m.storage.apply(nil)
            },
        ] + accessScenes
    }

    /// The Settings window's content on the window background (the real window sizes itself to the form).
    private static var settingsScene: some View {
        SettingsView()
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark)
    }

    /// Wave 2A: first-run onboarding (steps 1, 2, 2a, 2b, 3 at both window sizes), the access sheet
    /// from the sidebar pill, toasts, Settings, emptying the Trash (mock items only — never the real Trash).
    static var accessScenes: [Scene] {
        let compact = NSSize(width: 1100, height: 720)
        func onboarding(_ name: String, _ step: AccessFlow.Step, size: NSSize = NSSize(width: 1280, height: 800),
                        access: Bool = false, relaunch: Bool = false) -> Scene {
            Scene(name: name, fullDiskAccess: access, size: size) { m in
                m.presentFlow(.onboarding, step: step)
                m.accessFlow?.showsRelaunch = relaunch
            }
        }
        return [
            onboarding("onb_1_welcome", .welcome),
            onboarding("onb_1_welcome_hasAccess", .welcome, access: true),
            onboarding("onb_2_prime", .prime),
            onboarding("onb_2a_waiting", .waiting),
            onboarding("onb_2a_waiting_relaunch", .waiting, relaunch: true),
            onboarding("onb_2b_without", .withoutAccess),
            onboarding("onb_3_granted", .granted, access: true),
            onboarding("onb_compact_1_welcome", .welcome, size: compact),
            onboarding("onb_compact_2_prime", .prime, size: compact),
            onboarding("onb_compact_2a_relaunch", .waiting, size: compact, relaunch: true),
            onboarding("onb_compact_2b_without", .withoutAccess, size: compact),
            onboarding("onb_compact_3_granted", .granted, size: compact, access: true),
            Scene(name: "access_sheet_pill", fullDiskAccess: false) { m in
                m.selection = .junk
                m.junk.apply(MockData.junk)
                m.presentAccessSheet()
            },
            Scene(name: "access_sheet_waiting_compact", fullDiskAccess: false, size: compact) { m in
                m.selection = .oldFiles
                m.presentAccessSheet()
                m.accessFlow?.go(.waiting)
                m.accessFlow?.showsRelaunch = true
            },
            Scene(name: "access_sheet_granted", fullDiskAccess: false) { m in
                m.selection = .junk
                m.presentAccessSheet()
                m.applyAccess(granted: true)
            },
            Scene(name: "toast_access_granted", fullDiskAccess: false) { m in
                m.selection = .junk
                m.junk.apply(MockData.junk)
                m.applyAccess(granted: true)
            },
            Scene(name: "toast_trash_unreadable", fullDiskAccess: false, size: compact) { m in
                m.selection = .duplicates
                m.duplicates.apply(MockData.duplicates)
                m.showToast(Toast(text: "Нет доступа к Корзине — macOS показывает её только с полным доступом к диску",
                                  symbol: "lock.shield.fill", kind: .warning, actionTitle: "Дать доступ", action: {}))
            },
            Scene(name: "sidebar_pill_noFDA", fullDiskAccess: false) { m in
                m.selection = .oldFiles
                var b = MockData.storage
                b.fullDiskAccess = false
                m.storage.apply(b)
                m.storage.debugShowsDetails = true
            },
            Scene(name: "settings_window", size: NSSize(width: 520, height: 600),
                  content: { _ in AnyView(settingsScene) }) { _ in },
            Scene(name: "settings_window_noFDA", fullDiskAccess: false, size: NSSize(width: 520, height: 600),
                  content: { _ in AnyView(settingsScene) }) { _ in },
            Scene(name: "empty_trash_confirm") { m in
                m.selection = .duplicates
                m.duplicates.phase = .done
                m.duplicates.result = RemovalResult(removed: Array(repeating: MockData.h("x"), count: 14),
                                                    failed: [], freedBytes: 12_620_000_000)
                m.confirmEmptyTrash(MockData.trashItems)
            },
            Scene(name: "empty_trash_cleaning", size: compact) { m in
                m.selection = .duplicates
                var plan = CleaningPlan(title: "Очистка Корзины", module: .duplicates)
                plan.symbol = "trash.fill"
                plan.addStage("Корзина", symbol: "trash.fill", items: MockData.trashItems.map { (url: $0.url, size: $0.size) })
                let session = CleaningSession(plan: plan)
                session.simulate(to: 0.6)
                session.canCancel = true
                session.frozenTime = MockCleaning.sweepTime
                m.cleaning = session
            },
            Scene(name: "empty_trash_done") { m in
                m.selection = .duplicates
                m.trashCompletion = TrashCompletion(
                    result: RemovalResult(removed: MockData.trashItems.map(\.url), failed: [],
                                          freedBytes: MockData.trashItems.reduce(0) { $0 + $1.size }),
                    tint: .duplicates)
            },
        ]
    }

    /// Real, read-only engine runs (`--snapshot <dir> --live`): checks that real data fits the layout.
    /// Nothing is ever removed — only scans are called.
    static var liveScenes: [Scene] {
        [
            Scene(name: "live_junk") { m in
                m.selection = .junk
                await m.junk.scan()
                if let first = m.junk.categories.first { m.junk.expanded = [first.id] }
            },
            Scene(name: "live_uninstaller") { m in
                m.selection = .uninstaller
                await m.uninstaller.loadApps()
                while m.uninstaller.remnantsLoading { try? await Task.sleep(for: .milliseconds(200)) }
            },
            Scene(name: "live_leftovers") { m in
                m.selection = .uninstaller
                await m.uninstaller.loadApps()
                m.uninstaller.tab = .leftovers
                await m.uninstaller.scanOrphans()
            },
            Scene(name: "live_oldfiles") { m in
                m.selection = .oldFiles
                await m.oldFiles.scan()
            },
            Scene(name: "live_duplicates") { m in
                m.selection = .duplicates
                // MACCLEANER_DUP_ROOT points the scan at a fixture folder (this Mac may simply have no duplicates).
                if let root = ProcessInfo.processInfo.environment["MACCLEANER_DUP_ROOT"] {
                    m.duplicates.roots = [URL(fileURLWithPath: root)]
                }
                await m.duplicates.scan()
                print("live duplicates: \(m.duplicates.groups.count) groups")
            },
            Scene(name: "live_diskmap") { m in
                m.selection = .diskMap
                await m.diskMap.scan()
            },
            Scene(name: "live_storage") { m in
                m.selection = .smartCare
                m.storage.refresh()
                while m.storage.isMeasuring { try? await Task.sleep(for: .milliseconds(100)) }
                m.storage.debugShowsDetails = true
                if let b = m.storage.breakdown {
                    print("live storage: \(b.volumeName) total \(Fmt.size(b.total)), used \(Fmt.size(b.used)), free \(Fmt.size(b.free)), FDA \(b.fullDiskAccess), \(String(format: "%.2f", b.duration)) s")
                    for c in b.categories {
                        print("  \(c.title): \(Fmt.size(c.bytes)) (\(StorageFmt.precisePercent(b.share(c.bytes))))")
                    }
                }
            },
        ]
    }

    private static func completionScene(compact: Bool, allFailed: Bool = false, permanent: Bool = false,
                                        protectedFailures: Bool = false) -> @MainActor (AppModel) -> AnyView {
        { _ in
            let refused = (1...8).map {
                RemovalFailure(url: MockData.h("Library/Caches/com.apple.cache\($0)"),
                               reason: "“cache\($0)” couldn’t be moved to the trash because you don’t have permission to access it.")
            }
            let result = protectedFailures
                ? RemovalResult(removed: Array(repeating: MockData.h("x"), count: 48), failed: refused,
                                freedBytes: 10_400_000_000)
                : allFailed
                ? RemovalResult(failed: Array(MockData.actionableFailures.prefix(2)))
                : RemovalResult(removed: Array(repeating: MockData.h("x"), count: permanent ? 37 : 14),
                                failed: permanent ? [] : MockData.actionableFailures,
                                freedBytes: permanent ? 2_400_000_000 : 12_620_000_000)
            return AnyView(
                ZStack {
                    ModuleBackground(tint: .duplicates)
                    CompletionView(tint: .duplicates, result: result, title: permanent ? "Корзина очищена" : "Перемещено в Корзину",
                                   permanent: permanent, noun: permanent ? .items : .copies,
                                   onGrantAccess: {}, onRetry: {}, onEmptyTrash: {}, onDone: {})
                }
                .preferredColorScheme(.dark)
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .environment(\.hasFullDiskAccess, protectedFailures)
            )
        }
    }

    private static func loadApps(_ m: AppModel) {
        m.apps = MockData.apps
        m.appsState = .loaded
    }

    private static func selectChrome(_ m: AppModel) {
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        m.uninstaller.selectedAppID = chrome
        let rem = MockData.remnants()
        m.uninstaller.remnants = rem.sorted { $0.item.size > $1.item.size }
        m.uninstaller.remnantSelection = Set(rem.filter { $0.confidence >= .medium }.map(\.id))
        m.uninstaller.remnantsLoading = false
        m.uninstaller.runningURLs = [chrome]
    }

    /// Checks apps by name for the batch scenes; `pending` ones are still being searched for leftovers.
    private static func checkApps(_ m: AppModel, _ names: [String], pending: Set<String> = []) {
        let picked = MockData.apps.filter { names.contains($0.name) }
        m.uninstaller.checkedApps = Set(picked.map(\.url))
        for a in picked where !pending.contains(a.name) {
            m.uninstaller.batchRemnants[a.url] = a.name == "Google Chrome"
                ? MockData.remnants().filter { $0.confidence >= .medium }
                : MockData.batchRemnants(for: a)
        }
    }

    private static func fillAll(_ m: AppModel) {
        m.junk.apply(MockData.junk)
        m.oldFiles.apply(MockData.oldFiles, mode: .old)
        loadApps(m)
        m.uninstaller.applyOrphans(MockData.orphans)
    }
}
#endif
