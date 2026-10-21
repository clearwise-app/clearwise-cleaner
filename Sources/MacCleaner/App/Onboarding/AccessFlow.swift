import SwiftUI
import AppKit
import CleanerKit

/// UserDefaults keys of the first-run flow. `done` is also read through `@AppStorage` by RootView.
enum OnboardingKeys {
    /// The first-run flow ended: access was granted, or the user confirmed «Продолжить без доступа».
    static let done = "onboarding.done.v1"
    /// The user was sent to System Settings and the app may be relaunched by macOS («Выйти и открыть снова»)
    /// or by «Перезапустить» in step 2a. On the next launch the flow resumes (step 3 if access arrived).
    static let awaitingGrant = "onboarding.awaitingGrant"
}

/// State of the Full Disk Access flow (ux-audit §1): the first-run onboarding (steps 1–3, full window)
/// or the access sheet (steps 2–3) opened from the sidebar pill, banners, notes, menus and Settings.
@MainActor @Observable
final class AccessFlow {
    enum Mode: Equatable {
        /// First launch: full-window flow starting at «Освободим место — бережно».
        case onboarding
        /// In-window sheet over the app (Esc / «Не сейчас» closes it).
        case sheet
    }

    enum Step: Equatable {
        /// 1. Value first; no request yet.
        case welcome
        /// 2. One short screen saying why, then «Открыть настройки».
        case prime
        /// 2a. Settings are open; access is checked every second.
        case waiting
        /// 2b. What is lost without access (replaces the card in place).
        case withoutAccess
        /// 3. Access granted.
        case granted
    }

    let mode: Mode
    private(set) var step: Step
    /// Step to go back to from 2b («Назад»).
    private(set) var stepBeforeWithout: Step = .prime
    /// 20 s in 2a without access: offer the relaunch.
    var showsRelaunch = false

    /// False in snapshots: no polling, no System Settings, no UserDefaults.
    @ObservationIgnored let live: Bool
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored weak var app: AppModel?

    static let pollInterval: Duration = .seconds(1)
    static let relaunchHintAfter: TimeInterval = 20
    /// The loop gives up after 10 minutes; activation of the app still re-checks.
    static let pollLimit: TimeInterval = 600

    init(mode: Mode, step: Step, live: Bool) {
        self.mode = mode
        self.step = step
        self.live = live
    }

    /// Steps 2, 2a and 2b still want access; a grant noticed now moves the flow to step 3.
    var awaitsGrant: Bool { step == .prime || step == .waiting || step == .withoutAccess }

    // MARK: Navigation

    func go(_ next: Step) {
        guard next != step else { return }
        if next == .withoutAccess { stepBeforeWithout = step == .withoutAccess ? .prime : step }
        if step == .waiting && next != .waiting && next != .withoutAccess && next != .granted { stopWaiting() }
        withAnimation(Theme.spring) { step = next }
        if next == .waiting { startWaiting() }
        if next == .granted {
            // The relaunch flag stays until the flow closes: macOS often grants access and then asks to
            // «Выйти и открыть снова» right away, and the new instance must still show «Доступ открыт».
            stopPolling()
            if live { AccessibilityNotification.Announcement("Полный доступ к диску включён").post() }
        }
    }

    func back() { go(stepBeforeWithout) }

    /// «Открыть настройки» / «Открыть настройки ещё раз».
    func openSettings() {
        if live { Permissions.openFullDiskAccessSettings() }
        go(.waiting)
    }

    /// Access arrived (poll, app activation, or relaunch).
    func didGrant() {
        guard step != .granted else { return }
        go(.granted)
        guard live else { return }
        // The user started this, so bringing the window forward is expected, not intrusive.
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
    }

    // MARK: Waiting (2a)

    private func startWaiting() {
        showsRelaunch = false
        guard live else { return }
        UserDefaults.standard.set(true, forKey: OnboardingKeys.awaitingGrant)
        pollTask?.cancel()
        let started = Date()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                let elapsed = Date().timeIntervalSince(started)
                if elapsed > Self.pollLimit { return }
                let granted = await Task.detached(priority: .utility) { Permissions.hasFullDiskAccess }.value
                guard !Task.isCancelled else { return }
                if granted {
                    self.app?.applyAccess(granted: true)
                    return
                }
                if elapsed >= Self.relaunchHintAfter && !self.showsRelaunch {
                    withAnimation(Theme.spring) { self.showsRelaunch = true }
                }
            }
        }
    }

    private func stopWaiting() {
        stopPolling()
        if live { UserDefaults.standard.removeObject(forKey: OnboardingKeys.awaitingGrant) }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The flow is closing: stop polling and forget the relaunch flag.
    func tearDown() { stopWaiting() }

    /// «Перезапустить»: a new instance resumes the flow (see `OnboardingKeys.awaitingGrant`).
    func relaunch() {
        guard live else { return }
        UserDefaults.standard.set(true, forKey: OnboardingKeys.awaitingGrant)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            DispatchQueue.main.async {
                if error == nil { NSApp.terminate(nil) } else { NSSound.beep() }
            }
        }
    }
}
