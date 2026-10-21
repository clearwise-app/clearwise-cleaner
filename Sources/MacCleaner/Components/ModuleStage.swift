import SwiftUI
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
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var options: Options

    @Environment(AppModel.self) private var model

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
                    FDABanner()
                        .padding(.horizontal, 40)
                        .padding(.top, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
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
                           enabled: buttonEnabled, action: onAction, onStop: onStop)

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
         @ViewBuilder options: () -> Options) {
        self.init(module: module, title: title, subtitle: subtitle, state: state, onAction: onAction, onStop: onStop,
                  accessory: { EmptyView() }, options: options)
    }
}

extension ModuleStage where Accessory == EmptyView, Options == EmptyView {
    init(module: AppModule, title: String? = nil, subtitle: String? = nil, state: State,
         onAction: @escaping () -> Void = {}, onStop: (() -> Void)? = nil) {
        self.init(module: module, title: title, subtitle: subtitle, state: state, onAction: onAction, onStop: onStop,
                  accessory: { EmptyView() }, options: { EmptyView() })
    }
}

// MARK: - Banners & capsules

struct FDABanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: "lock.shield.fill", tint: .oldFiles, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Нужен полный доступ к диску")
                    .font(.cardTitle)
                    .foregroundStyle(Theme.text)
                Text("Без него macOS скрывает часть кэшей, контейнеров и почтовых файлов — результаты будут неполными.")
                    .font(.caption12)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Открыть настройки") { Permissions.openFullDiskAccessSettings() }
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

struct DiskCapsule: View {
    let disk: DiskUsage?

    var body: some View {
        if let disk {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(disk.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                        Spacer(minLength: 6)
                        Text("свободно \(Fmt.size(disk.available)) из \(Fmt.size(disk.total))")
                            .font(.system(size: 11.5, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    UsageBar(fraction: disk.fraction)
                        .frame(height: 5)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(width: 320)
            .glass(radius: 14, shadow: false)
        }
    }
}

struct UsageBar: View {
    let fraction: Double
    var tint: LinearGradient = LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.7)], startPoint: .leading, endPoint: .trailing)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.13))
                Capsule()
                    .fill(fraction > 0.9 ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(tint))
                    .frame(width: max(4, geo.size.width * min(1, fraction)))
            }
        }
    }
}

// MARK: - Results scaffolding

/// Header of a results screen: small module label, huge number, one-line caption.
struct ResultsHeader<Trailing: View>: View {
    let module: AppModule
    let bytes: Int64
    let caption: String
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
            }
            Spacer()
            trailing.padding(.bottom, 6)
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.top, 30)
    }
}

/// Bottom area of review screens: selection summary on the left, the round primary action in the center.
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
            ScanButton(mode: .action(title), tint: tint, diameter: 80, enabled: enabled, action: action)
        }
        .padding(.horizontal, Theme.Space.page)
        .frame(height: 118)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.28)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }
}

struct SelectionSummary: View {
    let bytes: Int64
    let count: Int
    var label = "Выбрано"

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SizeText(bytes: bytes, font: .number(24, weight: .light))
                Text(count == 0 ? "ничего" : Fmt.items(count))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
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
