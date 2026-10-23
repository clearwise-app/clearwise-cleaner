import SwiftUI

/// First-run flow over the whole window (the sidebar is covered, as during cleaning):
/// 1 value → 2 why access → 2a waiting / 2b without access → 3 access granted.
struct OnboardingView: View {
    let flow: AccessFlow

    var body: some View {
        GeometryReader { geo in
            let metrics = AccessMetrics(compact: geo.size.height < 860, inSheet: false)
            ZStack {
                ModuleBackground(tint: .smartCare)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    StepDots(active: flow.step == .welcome ? 0 : 1)
                        .padding(.top, metrics.compact ? 30 : 44)
                    Spacer(minLength: 8)
                    Group {
                        switch flow.step {
                        case .welcome:
                            WelcomeStep(metrics: metrics)
                        case .prime, .waiting, .withoutAccess:
                            AccessRequestStep(flow: flow, metrics: metrics)
                        case .granted:
                            GrantedStep(flow: flow, metrics: metrics)
                        }
                    }
                    .frame(width: 560)
                    .id(stepGroup)
                    .transition(Theme.motion(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)),
                                                         removal: .opacity.combined(with: .offset(x: -24)))))
                    Spacer(minLength: 8)
                    // Balances the dots so the column sits in the optical centre.
                    Color.clear.frame(height: metrics.compact ? 36 : 50)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .ignoresSafeArea()
        .environment(\.moduleTint, .smartCare)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Знакомство с \(AppInfo.name)")
    }

    /// 2, 2a and 2b are one screen (the card changes in place); 1 and 3 are separate screens.
    private var stepGroup: Int {
        switch flow.step {
        case .welcome: 0
        case .prime, .waiting, .withoutAccess: 1
        case .granted: 2
        }
    }
}

/// Two 6 pt step dots: welcome, then access.
private struct StepDots: View {
    let active: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<2) { i in
                Circle()
                    .fill(i == active ? Theme.text : Theme.textTertiary)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Шаг \(active + 1) из 2")
    }
}

/// Steps 2–3 as an in-window sheet over the app (sidebar pill, banners, notes, menu, Settings).
/// Esc or «Не сейчас» closes it; the app stays fully usable without access.
struct AccessSheet: View {
    let flow: AccessFlow
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let metrics = AccessMetrics(compact: geo.size.height < 780, inSheet: true)
            ZStack {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture { model.closeAccessFlow() }
                    .accessibilityHidden(true)

                Group {
                    if flow.step == .granted {
                        GrantedStep(flow: flow, metrics: metrics)
                    } else {
                        AccessRequestStep(flow: flow, metrics: metrics)
                    }
                }
                .frame(width: 560)
                .padding(.horizontal, 32)
                .padding(.vertical, metrics.compact ? 24 : 30)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(hex: 0x1B1922).opacity(0.97))
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(LinearGradient(colors: [ModuleTint.smartCare.accent.opacity(0.14), .clear],
                                                 startPoint: .top, endPoint: .center)))
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 1))
                        // One flattened layer casts the shadow while the card scales in, not three.
                        .compositingGroup()
                        .shadow(color: .black.opacity(0.55), radius: 40, y: 20)
                )
                .environment(\.moduleTint, .smartCare)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
                .accessibilityLabel("Полный доступ к диску")
                .accessibilityAction(.escape) { model.closeAccessFlow() }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }
}
