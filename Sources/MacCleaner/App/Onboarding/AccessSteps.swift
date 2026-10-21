import SwiftUI
import AppKit
import CleanerKit

// Steps of the Full Disk Access flow (ux-audit §1), shared by the first-run onboarding (full window)
// and the access sheet. Copy follows the audit word for word.

/// Sizes that change between the roomy window, the 1100×720 minimum and the sheet.
struct AccessMetrics {
    let compact: Bool
    let inSheet: Bool

    var icon: CGFloat { inSheet ? 56 : (compact ? 64 : 88) }
    var titleFont: Font { inSheet ? .system(size: 24, weight: .bold) : .pageTitle }
    var subtitleFont: Font { inSheet || compact ? .system(size: 14) : .pageSubtitle }
    var gap: CGFloat { compact || inSheet ? Theme.Space.m : Theme.Space.l }
    var buttonsTop: CGFloat { compact || inSheet ? Theme.Space.l : Theme.Space.xl }
    var textWidth: CGFloat { 520 }
}

// MARK: - Step 1

struct WelcomeStep: View {
    let metrics: AccessMetrics
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            StepHeader(symbol: "sparkles", title: "Освободим место — бережно",
                       subtitle: "MacCleaner находит кэши, остатки приложений, дубликаты и забытые файлы. Что удалить, решаете вы.",
                       metrics: metrics)

            VStack(alignment: .leading, spacing: Theme.Space.m) {
                promise("arrow.uturn.backward", "Всё удалённое сначала попадает в Корзину — его можно вернуть.")
                promise("hand.raised.fill", "Личные файлы никогда не отмечаются сами.")
                promise("wifi.slash", "MacCleaner работает без интернета и ничего никуда не отправляет.")
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.top, metrics.compact ? Theme.Space.l : Theme.Space.xl)

            Group {
                if model.hasFullDiskAccess {
                    // Access is already there: step 2 is skipped.
                    Button("Начать") { model.finishOnboarding() }
                } else {
                    Button("Продолжить") { model.accessFlow?.go(.prime) }
                }
            }
            .buttonStyle(PillButtonStyle(kind: .primary(.smartCare), large: true))
            .keyboardShortcut(.defaultAction)
            .padding(.top, metrics.buttonsTop)
        }
    }

    private func promise(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ModuleTint.smartCare.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.themeSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Steps 2, 2a, 2b

struct AccessRequestStep: View {
    let flow: AccessFlow
    let metrics: AccessMetrics
    @Environment(AppModel.self) private var model

    private var waiting: Bool { flow.step == .waiting }

    var body: some View {
        VStack(spacing: 0) {
            StepHeader(symbol: "lock.shield.fill", title: "Разрешите доступ ко всему диску",
                       subtitle: "macOS скрывает от программ часть файлов — почту, кэши Safari, контейнеры приложений, резервные копии. Чтобы найти весь мусор, MacCleaner нужен полный доступ к диску. Его даёте вы в Системных настройках — там же его можно отключить в любой момент.",
                       metrics: metrics)

            Group {
                if flow.step == .withoutAccess {
                    WithoutAccessCard(metrics: metrics)
                        .transition(Theme.motion(.opacity.combined(with: .scale(scale: 0.98, anchor: .top))))
                } else {
                    HowToCard(waiting: waiting, metrics: metrics)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: 560)
            .padding(.top, metrics.gap + 6)

            if flow.step == .withoutAccess {
                HStack(spacing: 10) {
                    Button("Продолжить без доступа") { leaveWithoutAccess() }
                        .buttonStyle(PillButtonStyle(kind: .primary(.smartCare), large: true))
                        .keyboardShortcut(.defaultAction)
                    Button("Назад") { flow.back() }
                        .buttonStyle(PillButtonStyle(kind: .quiet, large: true))
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.top, metrics.buttonsTop)
            } else {
                // After 20 s the relaunch offer says the same thing more specifically.
                if !(waiting && flow.showsRelaunch) {
                    Text("macOS может попросить пароль администратора или перезапустить MacCleaner — это нормально.")
                        .font(.caption12)
                        .foregroundStyle(.themeTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Theme.Space.m)
                }

                if waiting {
                    WaitingStatus(flow: flow)
                        .padding(.top, Theme.Space.m)
                        .transition(.opacity)
                }

                HStack(spacing: 10) {
                    if waiting {
                        Button("Открыть настройки ещё раз") { flow.openSettings() }
                            .buttonStyle(PillButtonStyle(kind: .secondary, large: true))
                    } else {
                        Button("Открыть настройки") { flow.openSettings() }
                            .buttonStyle(PillButtonStyle(kind: .primary(.smartCare), large: true))
                            .keyboardShortcut(.defaultAction)
                    }
                    if flow.mode == .sheet {
                        Button("Не сейчас") { model.closeAccessFlow() }
                            .buttonStyle(PillButtonStyle(kind: .quiet, large: true))
                            .keyboardShortcut(.cancelAction)
                    } else {
                        Button("Продолжить без доступа") { flow.go(.withoutAccess) }
                            .buttonStyle(PillButtonStyle(kind: .quiet, large: true))
                    }
                }
                .padding(.top, waiting ? Theme.Space.m : metrics.buttonsTop)

                Text("Доступ нужен, только чтобы видеть файлы. Удаляет MacCleaner лишь то, что вы выбрали.")
                    .font(.caption12)
                    .foregroundStyle(.themeTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Space.m)
            }
        }
    }

    private func leaveWithoutAccess() {
        if flow.mode == .onboarding { model.finishOnboarding() } else { model.closeAccessFlow() }
    }
}

/// «Как включить»: three numbered steps; the draggable app icon sits under step 2.
private struct HowToCard: View {
    let waiting: Bool
    let metrics: AccessMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Как включить")
                .font(.cardTitle)
                .foregroundStyle(Theme.text)
            row(1, done: waiting, "Нажмите «Открыть настройки» — откроется раздел «Полный доступ к диску».")
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                row(2, done: false, "Включите переключатель рядом с MacCleaner. Если его нет в списке — нажмите «+» или перетащите значок ниже.")
                AppIconDragRow()
                    .padding(.leading, 34)
            }
            row(3, done: false, "Вернитесь сюда — MacCleaner заметит доступ сам.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(metrics.compact || metrics.inSheet ? 16 : 18)
        .glass(radius: Theme.Radius.card, shadow: false)
        .accessibilityElement(children: .contain)
    }

    private func row(_ n: Int, done: Bool, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ZStack {
                Circle().fill(ModuleTint.smartCare.gradient)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy))
                } else {
                    Text("\(n)").font(.system(size: 12, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
            .accessibilityHidden(true)
            Text(text)
                .font(.body13)
                .foregroundStyle(Theme.text.opacity(done ? 0.7 : 0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Шаг \(n). \(text)")
    }
}

/// The app's own icon, draggable into the Full Disk Access list when macOS did not add MacCleaner there.
private struct AppIconDragRow: View {
    var body: some View {
        HStack(spacing: 12) {
            AppIconDragTile()
            VStack(alignment: .leading, spacing: 3) {
                Text("Нет в списке? Перетащите этот значок в окно настроек.")
                    .font(.caption12)
                    .foregroundStyle(.themeSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Показать в Finder") { Permissions.revealAppInFinder() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ModuleTint.smartCare.accent)
                    .pointerStyle(.link)
            }
        }
    }
}

struct AppIconDragTile: View {
    @State private var hover = false

    private var bundleURL: URL { Bundle.main.bundleURL }
    private var isAppBundle: Bool { bundleURL.pathExtension == "app" }

    var body: some View {
        Group {
            if isAppBundle {
                Image(nsImage: NSWorkspace.shared.icon(forFile: bundleURL.path))
                    .resizable()
                    .interpolation(.high)
            } else {
                // `swift run` / debug builds have no bundle: show the app's glyph.
                AppGlyph(size: 46)
            }
        }
        .frame(width: 46, height: 46)
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(hover ? 0.5 : 0.28), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .frame(width: 56, height: 56)
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(contentsOf: bundleURL) ?? NSItemProvider() }
        .onHover { hover = $0 }
        .pointerStyle(.grabIdle)
        .help("Перетащите в список «Полный доступ к диску»")
        .accessibilityElement()
        .accessibilityLabel("Значок MacCleaner")
        .accessibilityHint("Перетащите в список «Полный доступ к диску» в Системных настройках")
        .accessibilityAction(named: "Показать в Finder") { Permissions.revealAppInFinder() }
    }
}

/// 2a: spinner line instead of the main button; after 20 s, the relaunch offer.
private struct WaitingStatus: View {
    let flow: AccessFlow

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Ждём, когда вы включите MacCleaner в настройках…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
            .accessibilityElement(children: .combine)

            if flow.showsRelaunch {
                HStack(spacing: 10) {
                    Text("Уже включили? macOS иногда применяет доступ только после перезапуска.")
                        .font(.caption12)
                        .foregroundStyle(.themeSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Перезапустить MacCleaner") { flow.relaunch() }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .fixedSize()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glass(radius: 12, shadow: false)
                .transition(.opacity)
            }
        }
    }
}

/// 2b: what is lost without access, in place of the «Как включить» card.
private struct WithoutAccessCard: View {
    let metrics: AccessMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Продолжить без полного доступа?")
                .font(.cardTitle)
                .foregroundStyle(Theme.text)
            point("eye.slash.fill", "Кэши Safari и Mail, часть контейнеров приложений и резервные копии останутся невидимы — найдём меньше мусора.")
            point("folder.badge.questionmark", "При первом сканировании macOS отдельно спросит доступ к Рабочему столу, Документам и Загрузкам.")
            point("forward.fill", "Часть файлов при очистке может быть пропущена.")
            Text("Включить доступ можно в любой момент — кнопкой «Дать доступ» внизу боковой панели или в меню MacCleaner → «Полный доступ к диску…».")
                .font(.caption12)
                .foregroundStyle(.themeTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(metrics.compact || metrics.inSheet ? 16 : 18)
        .glass(radius: Theme.Radius.card, shadow: false)
        .accessibilityElement(children: .contain)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.warning)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text)
                .font(.body13)
                .foregroundStyle(Theme.text.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Step 3

struct GrantedStep: View {
    let flow: AccessFlow
    let metrics: AccessMetrics
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            SuccessMark(tint: .smartCare, scale: metrics.inSheet ? 0.55 : (metrics.compact ? 0.62 : 0.85))
                .scaleEffect(shown || reduceMotion || isSnapshot ? 1 : 0.9)
                .opacity(shown || isSnapshot ? 1 : 0)
                .padding(.bottom, metrics.gap)

            Text("Доступ открыт")
                .font(metrics.titleFont)
                .foregroundStyle(Theme.text)
            Text("Теперь MacCleaner видит весь диск, и macOS не будет спрашивать разрешение на каждую папку.")
                .font(metrics.subtitleFont)
                .foregroundStyle(.themeSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: metrics.textWidth)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Space.s)

            HStack(spacing: 10) {
                Button("Начать умную очистку") { model.accessFlowStartSmartCare() }
                    .buttonStyle(PillButtonStyle(kind: .primary(.smartCare), large: true))
                    .keyboardShortcut(.defaultAction)
                Button(flow.mode == .sheet ? "Готово" : "Осмотреться самому") { model.closeAccessFlow() }
                    .buttonStyle(PillButtonStyle(kind: .quiet, large: true))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, metrics.buttonsTop)
        }
        .onAppear {
            guard !shown else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.3) : Theme.spring) { shown = true }
        }
    }
}

// MARK: - Pieces

struct StepHeader: View {
    let symbol: String
    let title: String
    let subtitle: String
    let metrics: AccessMetrics

    var body: some View {
        VStack(spacing: 0) {
            IconTile(symbol: symbol, tint: .smartCare, size: metrics.icon)
                .accessibilityHidden(true)
                .padding(.bottom, metrics.compact || metrics.inSheet ? Theme.Space.m + 2 : Theme.Space.l)
            Text(title)
                .font(metrics.titleFont)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(metrics.subtitleFont)
                .foregroundStyle(.themeSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: metrics.textWidth)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Space.s + 2)
        }
    }
}
