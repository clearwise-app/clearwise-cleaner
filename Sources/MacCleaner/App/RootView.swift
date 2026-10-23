import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isSnapshot) private var isSnapshot
    @AppStorage(OnboardingKeys.done) private var onboardingDone = false
    /// The cleaning scene has finished fading in: the screens underneath are hidden and paused.
    @State private var overlayIn = false
    /// Bumped when the app comes back to the front and the module's screen changed while it was in the
    /// background: the content is built afresh, without animation. A transition that started in the instant
    /// before deactivation could otherwise stay half-way (the old screen over the new one, dead to clicks).
    @State private var contentEpoch = 0
    @State private var awayScreen: AwayScreen?

    private struct AwayScreen { let module: AppModule; let phase: ModulePhase? }
    private struct ContentKey: Hashable { let module: AppModule; let epoch: Int }

    /// Content under a modal layer is neither clickable nor visible to VoiceOver.
    private var blocked: Bool { model.isModalActive }
    private var fullScreenFlow: Bool { model.accessFlow?.mode == .onboarding }

    var body: some View {
        ZStack {
            ModuleBackground(tint: model.selection.tint)
                .id(model.selection)
                .transition(.opacity)
                .opacity(overlayIn ? 0 : 1)

            mainUI

            if model.isDropTargeted && model.selection != .diskMap && !blocked {
                DropOverlay()
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if let c = model.confirmation {
                ConfirmDialog(confirmation: c, onCancel: { model.dismissConfirmation() }) { forever in
                    model.dismissConfirmation()
                    // A permanent cleanup without the box (junk with the Trash) follows the Settings choice.
                    model.deletePermanentlyOnce = forever
                        || (c.permanent && UserDefaults.standard.bool(forKey: SettingsKeys.deletePermanently))
                    c.action()
                }
                .transition(Theme.motion(.opacity.combined(with: .scale(scale: 0.97))))
                .zIndex(10)
            }

            if let flow = model.accessFlow, flow.mode == .sheet {
                AccessSheet(flow: flow)
                    .transition(Theme.motion(.opacity.combined(with: .scale(scale: 0.97))))
                    .zIndex(15)
            }

            if let session = model.cleaning {
                CleaningOverlay(session: session)
                    // The scene's own animations never pause for "overlay is in" (only the screens below do),
                    // but they do stop while the window is in the background.
                    .environment(\.animationsPaused, controlActiveState == .inactive)
                    .transition(Theme.motion(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.03)),
                                                         removal: .opacity.combined(with: .scale(scale: 1.08)))))
                    .zIndex(20)
            }

            if let flow = model.accessFlow, flow.mode == .onboarding {
                OnboardingView(flow: flow)
                    .environment(\.animationsPaused, controlActiveState == .inactive)
                    .transition(.opacity)
                    .zIndex(30)
            }
        }
        // Decorative loops (the mesh included) stop when the window is in the background, fully covered by the
        // cleaning scene, or under the onboarding; the scene and the onboarding set their own value.
        .environment(\.animationsPaused, controlActiveState == .inactive || overlayIn || fullScreenFlow)
        // Nobody sees the window: state changes land at once instead of as transitions that may never finish.
        .transaction { t in
            guard !isSnapshot, !MainActor.assumeIsolated({ appWindowIsWatched }) else { return }
            t.animation = nil
            t.disablesAnimations = true
        }
        .onChange(of: controlActiveState) { _, state in
            if state == .inactive {
                awayScreen = AwayScreen(module: model.selection, phase: model.phase(of: model.selection))
            } else if let away = awayScreen {
                awayScreen = nil
                guard away.module == model.selection, away.phase != model.phase(of: model.selection) else { return }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { contentEpoch += 1 }
            }
        }
        .environment(\.moduleTint, model.selection.tint)
        .environment(\.hasFullDiskAccess, model.hasFullDiskAccess)
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls)
        } isTargeted: { targeted in
            withAnimation(Theme.quick) { model.isDropTargeted = targeted }
        }
        .task(id: model.cleaning != nil) {
            guard model.cleaning != nil else {
                overlayIn = false
                return
            }
            // Insertion runs ~0.45 s; after it the blurred screens are fully covered.
            try? await Task.sleep(for: .milliseconds(isSnapshot ? 0 : 500))
            guard !Task.isCancelled, model.cleaning != nil else { return }
            overlayIn = true
        }
        .onAppear {
            guard !isSnapshot else { return }
            model.startAccessFlowIfNeeded(onboardingDone: onboardingDone)
        }
        .preferredColorScheme(.dark)
        .environment(\.locale, AppLanguage.locale)
    }

    private var mainUI: some View {
        let covered = model.cleaning != nil
        return HStack(spacing: 0) {
            Sidebar()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Under «Хранилище» the module stays alive but out of reach (clicks, keyboard, VoiceOver).
                .disabled(model.storageExplorer != nil)
                .accessibilityHidden(model.storageExplorer != nil)
                .overlay {
                    if let explorer = model.storageExplorer {
                        StorageScreen(explorer: explorer)
                            .transition(Theme.motion(.opacity.combined(with: .scale(scale: 0.985))))
                    }
                }
                .overlay {
                    if let done = model.trashCompletion {
                        TrashCompletionScreen(completion: done)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) {
                    // Above the modules' footer (selection summary and the round button).
                    ToastHost()
                        .padding(.bottom, 116)
                }
        }
        .ignoresSafeArea()
        // Reduce Transparency: a flat dim instead of the blur.
        .blur(radius: covered && !reduceTransparency ? 24 : 0)
        .overlay {
            if covered && reduceTransparency {
                Color.black.opacity(0.6).ignoresSafeArea().transition(.opacity)
            }
        }
        // Once the scene is fully in, nothing underneath needs to be drawn (no per-frame blur of hidden UI).
        .opacity(overlayIn || fullScreenFlow ? 0 : 1)
        .disabled(blocked)
        .accessibilityHidden(blocked)
    }

    @ViewBuilder private var content: some View {
        Group {
            switch model.selection {
            case .smartCare: SmartCareView(model: model.smartCare)
            case .junk: JunkView(model: model.junk)
            case .uninstaller: UninstallerView(model: model.uninstaller)
            case .oldFiles: OldFilesView(model: model.oldFiles)
            case .duplicates: DuplicatesView(model: model.duplicates)
            case .diskMap: DiskMapView(model: model.diskMap)
            case .health: HealthView(model: model.health)
            case .startup: StartupView(model: model.startup)
            }
        }
        .id(ContentKey(module: model.selection, epoch: contentEpoch))
        .transition(Theme.motion(.opacity.combined(with: .offset(y: 8))))
    }
}

/// «Корзина очищена» over the content area after `requestEmptyTrash()`.
private struct TrashCompletionScreen: View {
    let completion: TrashCompletion
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            ModuleBackground(tint: completion.tint)
            CompletionView(tint: completion.tint, result: completion.result, title: String(localized: "Корзина очищена"),
                           permanent: true, noun: .items,
                           onGrantAccess: { model.dismissTrashCompletion(); model.presentAccessSheet() },
                           onRetry: { model.dismissTrashCompletion(); model.requestEmptyTrash() },
                           onDone: { model.dismissTrashCompletion() })
        }
        .environment(\.moduleTint, completion.tint)
    }
}

// MARK: - Toasts

private struct ToastHost: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .id(toast.id)
                    .transition(Theme.motion(.opacity.combined(with: .move(edge: .bottom))))
            }
        }
        .animation(Theme.spring, value: model.toast?.id)
    }
}

struct ToastView: View {
    let toast: Toast
    @Environment(AppModel.self) private var model

    private var color: Color {
        switch toast.kind {
        case .success: Theme.success
        case .info: Theme.textSecondary
        case .warning: Theme.warning
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(toast.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) {
                    model.dismissToast()
                    action()
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            }
            IconButton(symbol: "xmark", help: String(localized: "Закрыть"), size: 22) { model.dismissToast() }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: 620)
        .background(PopoverSurface(radius: 16))
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 16) {
                IconTile(symbol: "xmark.app.fill", tint: .uninstaller, size: 72)
                Text("Отпустите, чтобы удалить приложение")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Покажем само приложение и все его следы — ничего не удалится без подтверждения.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(48)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                    .foregroundStyle(ModuleTint.uninstaller.accent.opacity(0.8))
            )
        }
    }
}
