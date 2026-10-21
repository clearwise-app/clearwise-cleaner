import SwiftUI
import CleanerKit

/// Full-window cleaning scene: broom in a glass disc wrapped by the progress ring, a live status line
/// and the list of stages. Shown by `RootView` while `AppModel.cleaning` is set.
struct CleaningOverlay: View {
    let session: CleaningSession
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var frozen: Bool { isSnapshot || session.frozenTime != nil }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 760 || geo.size.width < 1180
            ZStack {
                backdrop

                VStack(spacing: 0) {
                    header
                        .padding(.top, compact ? 26 : 36)

                    Spacer(minLength: 8)

                    HStack(alignment: .center, spacing: compact ? 36 : 64) {
                        VStack(spacing: 0) {
                            dial(diameter: compact ? 236 : 280)
                                .padding(.bottom, compact ? -6 : 0)
                            CleaningStatus(session: session, compact: compact)
                        }
                        .frame(width: compact ? 410 : 480)

                        StageList(session: session, compact: compact, frozen: frozen)
                            .frame(width: 350)
                    }

                    Spacer(minLength: 8)

                    footer
                        .frame(height: 44)
                        .padding(.bottom, compact ? 22 : 34)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        // Swallow clicks and drops meant for the screens underneath.
        .onTapGesture {}
        // VoiceOver stays inside the scene while it is up.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(session.title)
        .onChange(of: session.currentStageID) { _, id in
            guard let id, !isSnapshot, !session.finished, session.stages.indices.contains(id) else { return }
            announce("\(session.activity) — \(session.stages[id].title)")
        }
        .onChange(of: session.finished) { _, finished in
            guard finished, !isSnapshot else { return }
            announce(session.stopped
                     ? "Остановлено. Убрано \(Fmt.size(session.freedBytes)) из \(Fmt.size(session.totalBytes))"
                     : "Готово. Убрано \(Fmt.size(session.freedBytes))")
        }
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    private var backdrop: some View {
        ZStack {
            // Opaque: the blurred screens underneath only show while the scene fades in and out.
            ModuleBackground(tint: session.tint)
            RadialGradient(colors: [session.tint.accent.opacity(0.16), .clear],
                           center: .init(x: 0.4, y: 0.5), startRadius: 40, endRadius: 520)
            Color.black.opacity(0.16)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 10) {
            IconTile(symbol: session.symbol, tint: session.tint, size: 26)
            Text(session.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, 16)
        .frame(height: 38)
        .background(Capsule().fill(.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
    }

    private func dial(diameter: CGFloat) -> some View {
        let fraction = session.fraction
        return BroomDial(tint: session.tint,
                         fraction: fraction,
                         clock: BroomClock(startedAt: session.startedAt,
                                           frozenTime: session.frozenTime ?? (isSnapshot ? 1.0 : nil),
                                           finishElapsed: session.finishElapsed),
                         diameter: diameter,
                         reduceMotion: reduceMotion)
            .accessibilityRepresentation {
                ProgressView(value: fraction) { Text(session.title) }
            }
    }

    @ViewBuilder private var footer: some View {
        if session.finished {
            Color.clear
        } else if session.cancelRequested {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Остановим после текущей группы файлов…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        } else if session.canCancel {
            Button {
                withAnimation(Theme.quick) { session.requestCancel() }
            } label: {
                Label("Остановить", systemImage: "stop.fill")
            }
            .buttonStyle(PillButtonStyle(kind: .secondary, large: true))
            .keyboardShortcut(.cancelAction)
        } else {
            Color.clear
        }
    }
}

// MARK: - Status

private struct CleaningStatus: View {
    let session: CleaningSession
    let compact: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(Int((session.fraction * 100).rounded(.down)))")
                    .font(.number(compact ? 50 : 58, weight: .thin))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("%")
                    .font(.number(compact ? 22 : 26, weight: .light))
                    .foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(Theme.text)
            .animation(.easeOut(duration: 0.25), value: Int(session.fraction * 100))
            // The dial already reports progress to VoiceOver.
            .accessibilityHidden(true)

            headline
                .padding(.top, compact ? 0 : 2)

            Text(detail)
                .font(session.awaitingAdmin && !session.finished ? .system(size: 12.5) : .system(size: 11.5, design: .monospaced))
                .foregroundStyle(session.awaitingAdmin && !session.finished ? Theme.textSecondary : Theme.textTertiary)
                .multilineTextAlignment(.center)
                // The admin explanation is prose and may wrap; paths stay one line, cut in the middle.
                .lineLimit(session.awaitingAdmin && !session.finished ? 2 : 1)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: compact ? 400 : 440)
                .padding(.top, 6)

            totals
                .padding(.top, compact ? 10 : 12)
        }
    }

    @ViewBuilder private var headline: some View {
        Group {
            if session.finished {
                Text(session.stopped ? "Остановлено"
                     : session.freedBytes < session.processedBytes ? "Готово" : "Готово — всё убрано")
                    .foregroundStyle(Theme.text)
            } else if session.awaitingAdmin {
                HStack(spacing: 7) {
                    Image(systemName: "lock.fill").foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)
                    Text("Введите пароль администратора").foregroundStyle(Theme.text)
                }
            } else if let stage = session.currentStage {
                Text("\(session.activity) — \(Text(stage.title).foregroundStyle(Theme.text))")
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("Подготовка…").foregroundStyle(Theme.textSecondary)
            }
        }
        .font(.system(size: compact ? 15 : 16, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: compact ? 420 : 470)
    }

    private var detail: String {
        if session.finished { return " " }
        if session.awaitingAdmin { return "macOS спрашивает пароль, чтобы удалить системные компоненты" }
        return session.currentURL.map { Fmt.path($0) } ?? " "
    }

    private var totals: some View {
        let freed = Text(Fmt.size(session.freedBytes)).foregroundStyle(Theme.text).fontWeight(.semibold)
        let ofTotal = session.totalBytes > 0 ? " из \(Fmt.size(session.totalBytes))" : ""
        let items = "\(Fmt.integer(min(session.processedItems, session.totalItems))) из \(Fmt.integer(session.totalItems))"
        return Text("Убрано \(freed)\(ofTotal)  ·  \(items)")
            .foregroundStyle(Theme.textSecondary)
        .font(.system(size: 13, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Capsule().fill(.white.opacity(0.07)))
    }
}

// MARK: - Stages

private struct StageList: View {
    let session: CleaningSession
    let compact: Bool
    let frozen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var maxRows: Int { compact ? 6 : 7 }

    /// A window of rows that follows the active stage, so long lists never need scrolling.
    private var window: (rows: ArraySlice<CleaningStage>, hiddenAbove: Int, hiddenBelow: Int) {
        let all = session.stages
        guard all.count > maxRows else { return (all[...], 0, 0) }
        let rows = maxRows - 1 // one line for the "ещё" hint
        let focus = session.currentStageID ?? all.firstIndex { $0.state != .done } ?? all.count - 1
        let start = max(0, min(focus - 1, all.count - rows))
        let end = start + rows
        return (all[start..<end], start, all.count - end)
    }

    var body: some View {
        let w = window
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ЭТАПЫ")
                    .font(.label11)
                    .kerning(0.6)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("\(session.doneStages) из \(session.stages.count)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if w.hiddenAbove > 0 {
                moreLine("Выполнено: ещё \(w.hiddenAbove) \(Fmt.plural(w.hiddenAbove, "этап", "этапа", "этапов"))",
                         symbol: "checkmark")
            }
            VStack(spacing: 2) {
                ForEach(w.rows) { stage in
                    StageRow(stage: stage, tint: session.tint, current: stage.id == session.currentStageID && !session.finished,
                             frozen: frozen)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, 6)
            if w.hiddenBelow > 0 {
                moreLine("И ещё \(w.hiddenBelow) \(Fmt.plural(w.hiddenBelow, "этап", "этапа", "этапов"))", symbol: "ellipsis")
            }
        }
        .padding(.bottom, 8)
        .glass(radius: 20)
        .animation(Theme.spring, value: session.currentStageID)
    }

    private func moreLine(_ text: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            Text(text).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 18)
        .frame(height: 26)
    }
}

private struct StageRow: View {
    let stage: CleaningStage
    let tint: ModuleTint
    let current: Bool
    let frozen: Bool

    var body: some View {
        HStack(spacing: 11) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                Text(stage.title)
                    .font(.system(size: 13, weight: current ? .semibold : .medium))
                    .foregroundStyle(stage.state == .waiting && !current ? Theme.textSecondary : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if current && stage.itemCount > 0 {
                    ProgressTrack(value: stage.fraction, tint: tint)
                        .frame(height: 3)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 6)
            Text(sizeText)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(stage.state == .done ? Theme.textSecondary : Theme.textTertiary)
                .lineLimit(1)
                .fixedSize()
            indicator
                .frame(width: 18, height: 18)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(current ? Color.white.opacity(0.09) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(current ? tint.accent.opacity(0.35) : .clear, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stage.title)
        .accessibilityValue(stage.state == .done ? "выполнено" : current ? "выполняется" : "ожидает")
    }

    private var sizeText: String {
        if stage.itemCount == 0 { return "" }
        if stage.totalBytes == 0 { return Fmt.items(stage.itemCount) }
        return Fmt.size(stage.state == .done ? stage.freedBytes : stage.totalBytes)
    }

    @ViewBuilder private var icon: some View {
        if let url = stage.iconURL {
            Image(nsImage: IconCache.icon(for: url))
                .resizable()
                .frame(width: 28, height: 28)
                .opacity(stage.state == .waiting && !current ? 0.6 : 1)
        } else {
            IconTile(symbol: stage.symbol, tint: tint, size: 28, muted: stage.state == .waiting && !current)
        }
    }

    @ViewBuilder private var indicator: some View {
        if stage.state == .done {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white, Theme.success)
                .transition(.scale.combined(with: .opacity))
        } else if current {
            Spinner(tint: tint, frozen: frozen)
        } else {
            Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1.5)
                .padding(1.5)
        }
    }
}

private struct ProgressTrack: View {
    let value: Double
    let tint: ModuleTint

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule().fill(tint.horizontal)
                    .frame(width: max(3, geo.size.width * min(1, value)))
                    .shadow(color: tint.accent.opacity(0.6), radius: 3)
            }
        }
        .animation(.easeOut(duration: 0.3), value: value)
    }
}

private struct Spinner: View {
    let tint: ModuleTint
    let frozen: Bool
    @State private var turn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(0.14), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(tint.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .padding(1.1)
                .rotationEffect(.degrees(turn ? 360 : 0) + .degrees(-60))
        }
        .onAppear {
            // Reduce Motion: a still arc; the stage's progress bar still shows activity.
            guard !frozen, !reduceMotion else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turn = true }
        }
    }
}
