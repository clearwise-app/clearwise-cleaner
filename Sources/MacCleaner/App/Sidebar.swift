import SwiftUI
import CleanerKit

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights.
            Color.clear.frame(height: 44)

            HStack(spacing: 10) {
                AppGlyph(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("MacCleaner").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                    Text("Чисто и безопасно").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 22)

            item(.smartCare)
            section("Очистка")
            item(.junk)
            section("Приложения")
            item(.uninstaller)
            section("Файлы")
            item(.oldFiles)
            item(.diskMap)

            Spacer(minLength: 12)

            if let disk = model.disk {
                SidebarDisk(disk: disk).padding(.horizontal, 14).padding(.bottom, 10)
            }
            FDAPill().padding(.horizontal, 14).padding(.bottom, 16)
        }
        .frame(width: Theme.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(
            ZStack {
                Color.black.opacity(0.34)
                LinearGradient(colors: [.white.opacity(0.04), .clear], startPoint: .top, endPoint: .bottom)
            }
        )
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.hairline).frame(width: 1)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 6)
    }

    private func item(_ module: AppModule) -> some View {
        SidebarItem(module: module, selected: model.selection == module, badge: badge(for: module)) {
            model.select(module)
        }
        .padding(.horizontal, 10)
    }

    private func badge(for module: AppModule) -> String? {
        switch module {
        case .smartCare:
            return model.smartCare.phase == .scanning ? "…" : nil
        case .junk:
            if model.junk.phase == .scanning { return "\(Int(model.junk.progress.fraction * 100))%" }
            return model.junk.phase == .results && model.junk.totalSize > 0 ? Fmt.size(model.junk.totalSize) : nil
        case .uninstaller:
            return model.appsState == .loaded ? "\(model.apps.filter { !$0.isSystemApp }.count)" : nil
        case .oldFiles:
            return model.oldFiles.phase == .results && model.oldFiles.totalSize > 0 ? Fmt.size(model.oldFiles.totalSize) : nil
        case .diskMap:
            return nil
        }
    }
}

private struct SidebarItem: View {
    let module: AppModule
    let selected: Bool
    let badge: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                IconTile(symbol: module.symbol, tint: module.tint, size: 26)
                Text(module.sidebarTitle)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.82))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .fixedSize()
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(selected ? 0.13 : (hover ? 0.06 : 0)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(selected ? 0.1 : 0), lineWidth: 0.75)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Theme.quick, value: hover)
    }
}

private struct SidebarDisk: View {
    let disk: DiskUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Text(disk.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            UsageBar(fraction: disk.fraction).frame(height: 4)
            Text("\(Fmt.size(disk.available)) свободно из \(Fmt.size(disk.total))")
                .font(.system(size: 11, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
    }
}

private struct FDAPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            if model.hasFullDiskAccess { model.refreshSystemState() } else { Permissions.openFullDiskAccessSettings() }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.hasFullDiskAccess ? Theme.success : Theme.warning)
                    .frame(width: 7, height: 7)
                    .shadow(color: (model.hasFullDiskAccess ? Theme.success : Theme.warning).opacity(0.8), radius: 4)
                Text(model.hasFullDiskAccess ? "Полный доступ к диску" : "Доступ к диску")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !model.hasFullDiskAccess {
                    Text("Настроить")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(.white.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(model.hasFullDiskAccess ? "MacCleaner видит все файлы, которые нужны для сканирования." : "Откройте Настройки → Конфиденциальность → Полный доступ к диску и включите MacCleaner.")
    }
}

/// The app's own mark: violet→magenta rounded square with sparkles.
struct AppGlyph: View {
    var size: CGFloat = 30

    var body: some View {
        IconTile(symbol: "sparkles", tint: .smartCare, size: size)
    }
}
