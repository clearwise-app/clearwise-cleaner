import SwiftUI
import CleanerKit

/// Celebratory but calm "done" state with honest numbers and any refusals listed.
struct CompletionView: View {
    let tint: ModuleTint
    let result: RemovalResult
    var title: String = "Готово"
    /// Items were deleted permanently (emptying the Trash).
    var permanent = false
    var onDone: () -> Void

    @State private var showFailures = false
    @Environment(\.isSnapshot) private var isSnapshot

    private var allFailed: Bool { result.removed.isEmpty && !result.failed.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            SuccessMark(tint: tint, failed: allFailed)
                .padding(.bottom, 26)

            Text(allFailed ? "Не удалось удалить" : title)
                .font(.pageTitle)
                .foregroundStyle(Theme.text)

            if result.freedBytes > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("Освобождено")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Theme.textSecondary)
                    BigSize(bytes: result.freedBytes, size: 60)
                }
                .padding(.top, 6)
            }

            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)

            if !result.failed.isEmpty {
                failures.padding(.top, 20)
            }

            HStack(spacing: 10) {
                if !permanent && !result.removed.isEmpty {
                    Button("Открыть Корзину") { Finder.openTrash() }
                        .buttonStyle(PillButtonStyle(kind: .secondary, large: true))
                }
                Button("Готово", action: onDone)
                    .buttonStyle(PillButtonStyle(kind: .primary(tint), large: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 28)
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var subtitle: String {
        let n = result.removed.count
        if allFailed {
            if result.failed.contains(where: { $0.reason.contains("запущено") }) {
                return "Приложение всё ещё запущено и не закрылось. Закройте его и попробуйте снова."
            }
            return "macOS не разрешила удалить выбранные объекты. Подробности ниже."
        }
        if permanent { return "\(Fmt.items(n).capitalizedFirst) удалено безвозвратно." }
        return "\(Fmt.items(n).capitalizedFirst) в Корзине. Их можно вернуть, пока Корзина не очищена."
    }

    private var failures: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Theme.spring) { showFailures.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    Text("Пропущено: \(Fmt.items(result.failed.count))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(showFailures || isSnapshot ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showFailures || isSnapshot {
                Divider().overlay(Theme.hairline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(result.failed, id: \.self) { f in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Fmt.path(f.url))
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(f.reason)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(170, CGFloat(result.failed.count) * 44 + 24))
                .transition(.opacity)
            }
        }
        .frame(width: 520)
        .glass(radius: 14, shadow: false)
    }
}

private struct SuccessMark: View {
    let tint: ModuleTint
    let failed: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [tint.accent.opacity(0.45), .clear], center: .center, startRadius: 10, endRadius: 150))
                .frame(width: 300, height: 300)
            Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1).frame(width: 200, height: 200)
            Circle().strokeBorder(.white.opacity(0.05), lineWidth: 1).frame(width: 250, height: 250)
            // Confetti-like sparks, deliberately sparse.
            ForEach(0..<9) { i in
                let a = Double(i) / 9 * 2 * .pi + 0.3
                let r: CGFloat = i % 2 == 0 ? 112 : 132
                Circle()
                    .fill(i % 3 == 0 ? tint.accent : (i % 3 == 1 ? tint.accent2 : .white))
                    .frame(width: i % 2 == 0 ? 6 : 4, height: i % 2 == 0 ? 6 : 4)
                    .offset(x: cos(a) * r, y: sin(a) * r)
                    .opacity(failed ? 0 : 0.85)
            }
            ZStack {
                Circle().fill(failed ? AnyShapeStyle(LinearGradient(colors: [Theme.warning, Theme.danger], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(tint.gradient))
                Circle().fill(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center))
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
                Image(systemName: failed ? "exclamationmark" : "checkmark")
                    .font(.system(size: 60, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            }
            .frame(width: 140, height: 140)
            .shadow(color: tint.accent2.opacity(0.6), radius: 30, y: 14)
        }
        .frame(width: 280, height: 220)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
