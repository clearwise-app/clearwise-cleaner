import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            ModuleBackground(tint: model.selection.tint)
                .id(model.selection)
                .transition(.opacity)

            HStack(spacing: 0) {
                Sidebar()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()
            .blur(radius: model.cleaning == nil ? 0 : 24)
            .allowsHitTesting(model.cleaning == nil)

            if model.isDropTargeted && model.selection != .diskMap && model.cleaning == nil {
                DropOverlay()
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if let c = model.confirmation {
                ConfirmDialog(confirmation: c, onCancel: { model.dismissConfirmation() }) {
                    model.dismissConfirmation()
                    c.action()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(10)
            }

            if let session = model.cleaning {
                CleaningOverlay(session: session)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.03)),
                                            removal: .opacity.combined(with: .scale(scale: 1.08))))
                    .zIndex(20)
            }
        }
        .environment(\.moduleTint, model.selection.tint)
        .dropDestination(for: URL.self) { urls, _ in
            model.cleaning == nil && model.handleDrop(urls)
        } isTargeted: { targeted in
            withAnimation(Theme.quick) { model.isDropTargeted = targeted }
        }
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: "ru_RU"))
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
            }
        }
        .id(model.selection)
        .transition(.opacity.combined(with: .offset(y: 8)))
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
