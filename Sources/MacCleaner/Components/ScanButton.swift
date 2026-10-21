import SwiftUI

/// The single round primary action. Morphs into a progress ring while work is running.
struct ScanButton: View {
    enum Mode: Equatable {
        case action(String)
        /// Determinate progress 0…1.
        case progress(Double)
        /// Indeterminate (e.g. moving files to Trash).
        case busy
    }

    let mode: Mode
    let tint: ModuleTint
    var diameter: CGFloat = 104
    var enabled = true
    var action: () -> Void = {}
    /// Shown as "Стоп" on hover while in progress.
    var onStop: (() -> Void)? = nil

    @State private var hover = false
    @State private var pressed = false
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isAction: Bool { if case .action = mode { true } else { false } }

    var body: some View {
        ZStack {
            // Soft halo
            Circle()
                .fill(RadialGradient(colors: [tint.accent2.opacity(isAction && enabled ? 0.45 : 0.25), .clear],
                                     center: .center, startRadius: diameter * 0.3, endRadius: diameter * 1.05))
                .frame(width: diameter * 2.1, height: diameter * 2.1)
                .allowsHitTesting(false)

            // Outer ring: idle hairline, or progress track
            Circle()
                .strokeBorder(.white.opacity(isAction ? 0.1 : 0.13), lineWidth: isAction ? 1 : 6)
                .frame(width: diameter + 26, height: diameter + 26)

            progressArc
                .frame(width: diameter + 20, height: diameter + 20)

            core
        }
        .frame(width: diameter + 30, height: diameter + 30)
        .animation(Theme.spring, value: mode)
        .animation(Theme.quick, value: hover)
    }

    @ViewBuilder private var progressArc: some View {
        switch mode {
        case .progress(let value):
            Circle()
                .trim(from: 0, to: max(0.004, min(1, value)))
                .stroke(AngularGradient(colors: [tint.accent, tint.accent2, tint.accent], center: .center),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.accent.opacity(0.8), radius: 8)
                .animation(.easeOut(duration: 0.35), value: value)
        case .busy:
            BusyArc(tint: tint, still: isSnapshot || reduceMotion)
        case .action:
            EmptyView()
        }
    }

    private var core: some View {
        Button {
            if isAction { action() } else { onStop?() }
        } label: {
            ZStack {
                Circle().fill(isAction ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.white.opacity(0.08)))
                Circle().fill(LinearGradient(colors: [.white.opacity(isAction ? 0.42 : 0.12), .clear],
                                             startPoint: .top, endPoint: .center))
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.1)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1.25)
                label
            }
            .frame(width: diameter, height: diameter)
            .shadow(color: isAction ? tint.accent2.opacity(0.6) : .clear, radius: 18, y: 8)
            .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
            .scaleEffect(hover && enabled ? 1.04 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled || (!isAction && onStop == nil))
        .opacity(enabled ? 1 : 0.45)
        .onHover { hover = $0 }
    }

    @ViewBuilder private var label: some View {
        switch mode {
        case .action(let title):
            Text(title)
                .font(.system(size: diameter > 90 ? 15 : 14, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(title.count > 12 && title.contains(" ") ? 2 : 1)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)
                .padding(.horizontal, 8)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        case .progress(let value):
            if hover, onStop != nil {
                stopLabel
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int((min(1, value)) * 100))")
                        .font(.number(diameter * 0.28, weight: .light))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("%").font(.number(diameter * 0.13, weight: .light)).foregroundStyle(Theme.textSecondary)
                }
                .foregroundStyle(.white)
            }
        case .busy:
            if hover, onStop != nil { stopLabel } else {
                Image(systemName: "trash.fill")
                    .font(.system(size: diameter * 0.24, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private var stopLabel: some View {
        VStack(spacing: 3) {
            Image(systemName: "stop.fill").font(.system(size: 14, weight: .bold))
            Text("Стоп").font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white)
    }
}

private struct BusyArc: View {
    let tint: ModuleTint
    let still: Bool
    @State private var turn = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(AngularGradient(colors: [tint.accent.opacity(0), tint.accent, tint.accent2], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(100)),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round))
            .rotationEffect(.degrees(turn ? 270 : -90))
            .shadow(color: tint.accent.opacity(0.7), radius: 8)
            .onAppear {
                guard !still else { return }
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { turn = true }
            }
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
