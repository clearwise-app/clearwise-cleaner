import SwiftUI
import SpaceEngine
import CleanerKit

/// The idle → scanning screen every module shares: hero, title, subtitle, options and the round button
/// that turns into a progress ring. Keeping one view for both states makes the morph seamless.
struct ModuleStage<Accessory: View, Options: View>: View {
    enum State: Equatable {
        case idle(button: String, enabled: Bool)
        case progress(ScanProgress)
        case busy(String)

        static func == (l: State, r: State) -> Bool {
            switch (l, r) {
            case let (.idle(a, b), .idle(c, d)): a == c && b == d
            case let (.progress(a), .progress(b)): a.fraction == b.fraction && a.phase == b.phase && a.currentPath == b.currentPath
            case let (.busy(a), .busy(b)): a == b
            default: false
            }
        }
    }

    let module: AppModule
    var title: String? = nil
    var subtitle: String? = nil
    let state: State
    var onAction: () -> Void = {}
    var onStop: (() -> Void)? = nil
    var dimsOptionsWhileWorking = true
    /// «Как дать доступ» in the Full Disk Access banner. Nil: opens System Settings directly.
    var onGrantAccess: (() -> Void)? = nil
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var options: Options

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isWorking: Bool { if case .idle = state { false } else { true } }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 760
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    accessory
                }
                .frame(height: 40)
                .padding(.top, 14)
                .padding(.horizontal, 28)

                if model.showsFDABanner && !isWorking {
                    FDABanner(onGrantAccess: onGrantAccess)
                        .padding(.horizontal, 40)
                        .padding(.top, 4)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }

                Spacer(minLength: 4)

                HeroIllustration(spec: module.hero, tint: module.tint, size: compact ? 168 : 212, active: isWorking)
                    .padding(.bottom, compact ? 4 : 10)

                Text(title ?? module.title)
                    .font(.pageTitle)
                    .foregroundStyle(Theme.text)
                Text(subtitle ?? module.subtitle)
                    .font(.pageSubtitle)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)

                options
                    .padding(.top, compact ? 16 : 24)
                    .disabled(isWorking && dimsOptionsWhileWorking)
                    .opacity(isWorking && dimsOptionsWhileWorking ? 0.35 : 1)

                Spacer(minLength: 8)

                ScanButton(mode: buttonMode, tint: module.tint, diameter: compact ? 96 : 106,
                           enabled: buttonEnabled, action: onAction, onStop: onStop, isDefaultAction: true)

                status
                    .frame(height: 46, alignment: .top)
                    .padding(.top, 6)
                    .padding(.bottom, compact ? 12 : 26)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var buttonMode: ScanButton.Mode {
        switch state {
        case .idle(let title, _): .action(title)
        case .progress(let p): .progress(p.fraction)
        case .busy: .busy
        }
    }

    private var buttonEnabled: Bool {
        if case .idle(_, let enabled) = state { return enabled }
        return true
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .idle:
            Color.clear
        case .progress(let p):
            VStack(spacing: 4) {
                Text(p.phase.isEmpty ? "Сканирование…" : p.phase)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .contentTransition(.opacity)
                Text(p.currentPath.map { Fmt.path(URL(fileURLWithPath: $0)) } ?? " ")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520)
            }
        case .busy(let text):
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
        }
    }
}

extension ModuleStage where Accessory == EmptyView {
    init(module: AppModule, title: String? = nil, subtitle: String? = nil, state: State,
         onAction: @escaping () -> Void = {}, onStop: (() -> Void)? = nil,
         onGrantAccess: (() -> Void)? = nil,
         @ViewBuilder options: () -> Options) {
        self.init(module: module, title: title, subtitle: subtitle, state: state, onAction: onAction, onStop: onStop,
                  onGrantAccess: onGrantAccess, accessory: { EmptyView() }, options: options)
    }
}

extension ModuleStage where Accessory == EmptyView, Options == EmptyView {
    init(module: AppModule, title: String? = nil, subtitle: String? = nil, state: State,
         onAction: @escaping () -> Void = {}, onStop: (() -> Void)? = nil,
         onGrantAccess: (() -> Void)? = nil) {
        self.init(module: module, title: title, subtitle: subtitle, state: state, onAction: onAction, onStop: onStop,
                  onGrantAccess: onGrantAccess, accessory: { EmptyView() }, options: { EmptyView() })
    }
}

/// Opens the Full Disk Access flow when the app provides one, else System Settings (today's behaviour).
@MainActor
private func grantAccess(_ handler: (() -> Void)?) {
    if let handler { handler() } else { Permissions.openFullDiskAccessSettings() }
}

// MARK: - Banners & capsules

struct FDABanner: View {
    /// «Как дать доступ»: the in-app access flow. Nil opens System Settings directly.
    var onGrantAccess: (() -> Void)? = nil
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: "lock.shield.fill", tint: .oldFiles, size: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Часть файлов скрыта от \(AppInfo.name)")
                    .font(.cardTitle)
                    .foregroundStyle(Theme.text)
                Text("Без полного доступа macOS не показывает кэши Safari и Mail и контейнеры приложений — найдём не всё.")
                    .font(.caption12)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button("Как дать доступ") { grantAccess(onGrantAccess) }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            IconButton(symbol: "xmark", help: "Скрыть", size: 22) {
                withAnimation(Theme.spring) { model.fdaBannerDismissed = true }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glass(radius: 14)
        .frame(maxWidth: 700)
    }
}

/// «Последняя уборка · 3 дня назад · 1,2 ГБ» (Smart Care, top right). Nothing until the first cleanup;
/// the disk itself is shown once, in the sidebar.
struct LastCleanupChip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let last = app.lastCleanup {
            // Re-reads «… назад» once a minute while visible.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ModuleTint.smartCare.accent)
                    Text("Последняя уборка")
                        .foregroundStyle(Theme.textSecondary)
                    Text(Self.ago(last.date, now: context.date))
                        .foregroundStyle(Theme.text)
                    Text("·").foregroundStyle(.themeTertiary)
                    Text(Fmt.size(last.bytes))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 14)
                .frame(height: 34)
                .glass(radius: 17, shadow: false)
                .accessibilityElement(children: .combine)
            }
            .help("Убрано в Корзину или удалено \(last.date.formatted(date: .long, time: .shortened))")
        }
    }

    /// «только что», «5 минут назад», «вчера», «3 дня назад».
    static func ago(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "только что" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateTimeStyle = .named
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }
}

/// One line for results headers when Full Disk Access is missing: the list may be incomplete.
/// Renders nothing while the app has access.
struct PartialAccessNote: View {
    /// «Дать доступ»: the in-app access flow. Nil opens System Settings directly.
    var onGrantAccess: (() -> Void)? = nil
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.hasFullDiskAccess {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                Text("Результаты неполные — нет полного доступа к диску")
                    .foregroundStyle(Theme.textSecondary)
                Text("·")
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                Button("Дать доступ") { grantAccess(onGrantAccess) }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.text)
                    .pointerStyle(.link)
                    .help("Открыть настройки полного доступа к диску")
            }
            .font(.system(size: 12))
            .lineLimit(1)
        }
    }
}

/// Header of a results screen: small module label, huge number, one-line caption, and — without
/// Full Disk Access — the `PartialAccessNote`.
struct ResultsHeader<Trailing: View>: View {
    let module: AppModule
    let bytes: Int64
    let caption: String
    /// Show `PartialAccessNote` under the caption when access is missing.
    var showsAccessNote = true
    var onGrantAccess: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: module.symbol).font(.system(size: 11, weight: .bold))
                    Text(module.title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.8)
                }
                .foregroundStyle(module.tint.accent)
                BigSize(bytes: bytes, size: 58)
                    .padding(.top, 2)
                Text(caption)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                if showsAccessNote {
                    PartialAccessNote(onGrantAccess: onGrantAccess)
                        .padding(.top, 6)
                }
            }
            Spacer()
            trailing.padding(.bottom, 6)
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.top, 30)
    }
}

/// Bottom area of review screens: selection summary on the left, the round primary action in the center,
/// where it all goes on the right. Prefer the standard init (`selectedBytes:selectedCount:noun:permanent:`):
/// «Выбрано 12,4 ГБ · 342 объекта» on the left, «↩ Всё попадёт в Корзину» or the permanent warning on the right.
struct ActionFooter<Leading: View, Trailing: View>: View {
    let title: String
    let tint: ModuleTint
    var enabled = true
    let action: () -> Void
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ZStack {
            HStack {
                leading
                Spacer()
                trailing
            }
            // Return never starts a destructive confirmation from the review footer.
            ScanButton(mode: .action(title), tint: tint, diameter: 80, enabled: enabled, action: action,
                       isDefaultAction: false)
        }
        .padding(.horizontal, Theme.Space.page)
        .frame(height: 118)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.28)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }
}

extension ActionFooter where Leading == SelectionSummary, Trailing == FooterNote {
    init(title: String, tint: ModuleTint, enabled: Bool = true,
         selectedBytes: Int64, selectedCount: Int, noun: Fmt.Noun = .items, permanent: Bool = false,
         action: @escaping () -> Void) {
        self.init(title: title, tint: tint, enabled: enabled, action: action) {
            SelectionSummary(bytes: selectedBytes, count: selectedCount, noun: noun)
        } trailing: {
            FooterNote(permanent: permanent)
        }
    }
}

/// «Выбрано» over «12,4 ГБ · 342 объекта».
struct SelectionSummary: View {
    let bytes: Int64
    let count: Int
    var label = "Выбрано"
    var noun: (Int) -> String = Fmt.items

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if count == 0 {
                    Text("ничего")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    SizeText(bytes: bytes, font: .number(24, weight: .light))
                    Text("· \(noun(count))")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension SelectionSummary {
    init(bytes: Int64, count: Int, label: String = "Выбрано", noun: Fmt.Noun) {
        self.init(bytes: bytes, count: count, label: label, noun: { Fmt.count($0, noun) })
    }
}

/// Right side of `ActionFooter`: where the selection goes.
struct FooterNote: View {
    /// Emptying the Trash is part of the action: warn instead of promising the Trash.
    var permanent = false
    /// Overrides the standard text.
    var text: String? = nil

    var body: some View {
        Label(text ?? ConfirmCopy.footerNote(permanent: permanent),
              systemImage: permanent ? "exclamationmark.triangle.fill" : "arrow.uturn.backward")
            .font(.system(size: 12))
            .foregroundStyle(permanent ? Theme.warning : Theme.textTertiary)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var tint: ModuleTint
    var actionTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 14) {
            IconTile(symbol: symbol, tint: tint, size: 64)
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(message)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .padding(.top, 4)
            }
        }
        .padding(30)
    }
}
