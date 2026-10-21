import SwiftUI
import CleanerKit

/// Calm "done" state with honest numbers: what went to the Trash still takes space until the Trash is emptied,
/// so the headline says «В Корзине X»; only permanent deletion says «Удалено навсегда». Refusals are listed in
/// human words (`FailureCopy`) with one action per kind of problem.
struct CompletionView: View {
    let tint: ModuleTint
    let result: RemovalResult
    var title: String = "Готово"
    /// Items were deleted permanently (emptying the Trash).
    var permanent = false
    /// How counts are spelled: «14 копий», «3 файла», «1 приложение».
    var noun: Fmt.Noun = .items
    /// «Дать доступ и повторить» on access refusals: open the Full Disk Access flow, then retry. Hidden when nil.
    var onGrantAccess: (() -> Void)? = nil
    /// «Повторить» on refusals that may pass a second time (app was running, password cancelled). Hidden when nil.
    var onRetry: (() -> Void)? = nil
    /// Secondary «Очистить Корзину…» (should ask for confirmation first). Hidden when nil or `permanent`.
    var onEmptyTrash: (() -> Void)? = nil
    var onDone: () -> Void

    @State private var showFailures = false
    @Environment(\.isSnapshot) private var isSnapshot

    private var allFailed: Bool { result.removed.isEmpty && !result.failed.isEmpty }
    private var lines: [FailureCopy.Line] { result.failed.map(FailureCopy.describe) }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 760
            VStack(spacing: 0) {
                Spacer(minLength: 12)
                SuccessMark(tint: tint, failed: allFailed, scale: compact ? 0.72 : 1)
                    .padding(.bottom, compact ? 12 : 26)

                Text(allFailed ? "Не удалось убрать выбранное" : title)
                    .font(.pageTitle)
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)

                if result.freedBytes > 0 && !allFailed {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(permanent ? "Удалено навсегда" : "В Корзине")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(Theme.textSecondary)
                        BigSize(bytes: result.freedBytes, size: compact ? 50 : 60)
                    }
                    .accessibilityElement(children: .combine)
                    .padding(.top, 6)
                }

                VStack(spacing: 4) {
                    Text(subtitle)
                        .foregroundStyle(Theme.textSecondary)
                    if !permanent && !result.removed.isEmpty {
                        Text("Место освободится, когда вы очистите Корзину.")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

                if !result.failed.isEmpty {
                    failures(compact: compact).padding(.top, compact ? 14 : 20)
                }

                HStack(spacing: 10) {
                    if !permanent && !result.removed.isEmpty {
                        Button("Открыть Корзину") { Finder.openTrash() }
                            .buttonStyle(PillButtonStyle(kind: .secondary, large: true))
                        if let onEmptyTrash {
                            Button("Очистить Корзину…", action: onEmptyTrash)
                                .buttonStyle(PillButtonStyle(kind: .secondary, large: true))
                                .help("Удалить содержимое Корзины навсегда и освободить место")
                        }
                    }
                    Button("Готово", action: onDone)
                        .buttonStyle(PillButtonStyle(kind: .primary(tint), large: true))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, compact ? 20 : 28)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 40)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            if allFailed { showFailures = true }
            guard !isSnapshot else { return }
            AccessibilityNotification.Announcement(announcement).post()
        }
    }

    // MARK: Copy

    private var subtitle: String {
        let n = result.removed.count
        if allFailed {
            if result.failed.contains(where: { $0.reason == "Приложение запущено" }) {
                return "Приложение всё ещё запущено и не закрылось. Закройте его и попробуйте снова."
            }
            if lines.allSatisfy({ $0.action == .grantAccess }) {
                return "macOS не дала MacCleaner доступ к этим файлам. Дайте полный доступ к диску и повторите."
            }
            return "Файлы остались на месте. Что помешало и что можно сделать — ниже."
        }
        if permanent { return "Место на диске освобождено · \(Fmt.count(n, noun))" }
        return "\(Fmt.count(n, noun).capitalizedFirst) можно вернуть из Корзины."
    }

    private var announcement: String {
        var parts: [String] = []
        if allFailed {
            parts.append("Не удалось убрать выбранное")
        } else {
            parts.append(title)
            if result.freedBytes > 0 {
                parts.append(permanent ? "Удалено навсегда \(Fmt.size(result.freedBytes))"
                                       : "В Корзине \(Fmt.size(result.freedBytes))")
            }
        }
        if !result.failed.isEmpty { parts.append("Пропущено: \(Fmt.count(result.failed.count, noun))") }
        return parts.joined(separator: ". ")
    }

    // MARK: Failures

    private func failures(compact: Bool) -> some View {
        let expanded = showFailures || isSnapshot
        let lines = self.lines
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Theme.spring) { showFailures.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)
                    Text("Пропущено: \(Fmt.count(result.failed.count, noun))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "развёрнуто" : "свёрнуто")
            .accessibilityHint("Показывает, что не удалось убрать и почему")

            if expanded {
                Divider().overlay(Theme.hairline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(zip(result.failed, lines).enumerated()), id: \.offset) { _, pair in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Fmt.path(pair.0.url))
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(pair.1.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(compact ? 104 : 170, CGFloat(result.failed.count) * 44 + 24))
                .transition(.opacity)
            }

            actions(for: lines)
        }
        .frame(width: 520)
        .glass(radius: 14, shadow: false)
    }

    /// One button per kind of problem present; a button whose closure is missing stays hidden.
    @ViewBuilder private func actions(for lines: [FailureCopy.Line]) -> some View {
        let kinds = Set(lines.map(\.action))
        let grant = kinds.contains(.grantAccess) ? onGrantAccess : nil
        let retry = kinds.contains(.retry) ? onRetry : nil
        let reveal = result.failed.enumerated()
            .filter { lines[$0.offset].action == .revealInFinder }
            .map(\.element.url)
        if grant != nil || retry != nil || !reveal.isEmpty {
            Divider().overlay(Theme.hairline)
            HStack(spacing: 8) {
                if let grant {
                    Button("Дать доступ и повторить", action: grant)
                        .buttonStyle(PillButtonStyle(kind: .primary(tint)))
                }
                if !reveal.isEmpty {
                    Button("Показать в Finder") { Finder.reveal(reveal) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                if let retry {
                    Button("Повторить", action: retry)
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}

/// The big check (or warning) mark with a soft halo and sparse sparks. Also used by onboarding.
struct SuccessMark: View {
    let tint: ModuleTint
    var failed = false
    /// 1 = 280×220 pt; compact screens use ~0.7.
    var scale: CGFloat = 1

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
        .scaleEffect(scale)
        .frame(width: 280 * scale, height: 220 * scale)
        .accessibilityHidden(true)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
