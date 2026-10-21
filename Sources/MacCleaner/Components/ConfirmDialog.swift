import SwiftUI

/// In-window confirmation for every destructive action: what, how many, how much, and where it goes.
struct ConfirmDialog: View {
    let confirmation: Confirmation
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(spacing: 0) {
                icon
                Text(confirmation.title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    BigSize(bytes: confirmation.bytes, size: 40, weight: .light)
                    Text(Fmt.items(confirmation.count))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, 10)

                Text(confirmation.message)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 8) {
                    if let warning = confirmation.warning {
                        note(symbol: "exclamationmark.triangle.fill", color: Theme.warning, text: warning)
                    }
                    if confirmation.needsAdmin {
                        note(symbol: "lock.fill", color: Theme.textSecondary,
                             text: "Для некоторых файлов macOS попросит пароль администратора.")
                    }
                }
                .padding(.top, (confirmation.warning != nil || confirmation.needsAdmin) ? 14 : 0)

                HStack(spacing: 10) {
                    Button("Отмена", action: onCancel)
                        .buttonStyle(PillButtonStyle(kind: .secondary, large: true))
                        .keyboardShortcut(.cancelAction)
                    Button(confirmation.confirmTitle, action: onConfirm)
                        .buttonStyle(PillButtonStyle(kind: confirmation.permanent ? .destructive : .primary(confirmation.tint), large: true))
                }
                .padding(.top, 24)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 28)
            .frame(width: 460)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(hex: 0x1B1922).opacity(0.97))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LinearGradient(colors: [confirmation.tint.accent.opacity(0.14), .clear], startPoint: .top, endPoint: .center)))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .shadow(color: .black.opacity(0.55), radius: 40, y: 20)
            )
        }
    }

    private var icon: some View {
        Group {
            if confirmation.permanent {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: 0xFF7A6B), Color(hex: 0xE5395B)], startPoint: .top, endPoint: .bottom))
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 58, height: 58)
                .shadow(color: Color(hex: 0xE5395B).opacity(0.5), radius: 14, y: 6)
            } else {
                IconTile(symbol: "trash.fill", tint: confirmation.tint, size: 58)
            }
        }
    }

    private func note(symbol: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                .frame(width: 14)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
    }
}
