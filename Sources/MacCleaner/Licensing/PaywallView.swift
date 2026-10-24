import SwiftUI
import StoreKit

/// Subscription sheet: shown when a cleanup is confirmed after the trial, and from Settings → «Подписка».
/// Scanning stays free; the subscription unlocks cleaning.
struct PaywallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AppGlyph(size: 44).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Подписка \(AppInfo.name)").font(.title2.bold())
                    AccessStatusText(state: model.access.state)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("Сканирование всегда бесплатно", systemImage: "magnifyingglass")
                Label("Подписка открывает очистку во всех разделах", systemImage: "sparkles")
                Label("Отменить можно в любой момент", systemImage: "xmark.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Divider()
            #if CLEARWISE_LITE
            if let store = model.access.store { StorePurchaseSection(store: store) }
            #else
            if let site = model.access.site { SitePurchaseSection(license: site) }
            #endif

            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .environment(\.locale, AppLanguage.locale)
    }
}

/// «Пробный период: осталось 5 дней» / «Подписка активна до 24 ноября 2026» / «Пробный период закончился».
struct AccessStatusText: View {
    let state: AccessState

    var body: some View {
        switch state {
        case .unlocked:
            Text("Без ограничений").foregroundStyle(.secondary)
        case .trial(let days):
            Text("Пробный период: осталось \(days) дн.").foregroundStyle(Theme.warning)
        case .subscribed(_, let until?):
            Text("Подписка активна до \(until.formatted(date: .long, time: .omitted))").foregroundStyle(Theme.success)
        case .subscribed(_, nil):
            Text("Подписка активна").foregroundStyle(Theme.success)
        case .expired:
            Text("Пробный период закончился — оформите подписку, чтобы очищать").foregroundStyle(Theme.warning)
        }
    }
}

#if !CLEARWISE_LITE
/// Site edition: sign in with e-mail, buy on the account page, come back and check.
private struct SitePurchaseSection: View {
    let license: SiteLicense
    @State private var email = ""
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch license.step {
            case .email:
                Text("Войдите по почте — пришлём код, пароль не нужен. Если подписка уже оформлена, она подключится сама.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("Почта", text: $email)
                        .textContentType(.emailAddress)
                        .onSubmit { Task { await license.requestCode(email: email) } }
                    Button("Получить код") { Task { await license.requestCode(email: email) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(license.isWorking || email.isEmpty)
                }
            case .code(let sentTo):
                Text("Код отправлен на \(sentTo).").font(.callout)
                HStack {
                    TextField("Код из письма", text: $code)
                        .textContentType(.oneTimeCode)
                        .onSubmit { Task { await license.verify(code: code) } }
                    Button("Войти") { Task { await license.verify(code: code) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(license.isWorking || code.count < 6)
                }
                Button("Другая почта") { license.changeEmail() }.buttonStyle(.link)
            case .signedIn(let account):
                signedIn(account)
            }

            if license.isWorking { ProgressView().controlSize(.small) }
            if let error = license.errorText {
                Text(error).font(.callout).foregroundStyle(Theme.warning)
            }
        }
    }

    @ViewBuilder private func signedIn(_ account: String) -> some View {
        Text("Аккаунт: \(account)").font(.callout).foregroundStyle(.secondary)
        if let devices = license.deviceLimit {
            Text("Подписка уже используется на максимальном числе Mac. Отвяжите один, чтобы подключить этот:")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            ForEach(devices) { device in
                HStack {
                    Text(device.deviceName.isEmpty ? "Mac" : device.deviceName)
                    Spacer()
                    Button("Отвязать") { Task { await license.free(device) } }.disabled(license.isWorking)
                }
            }
        } else if license.license == nil {
            Text("Оплата откроется в браузере. После неё вернитесь сюда и нажмите «Проверить подписку».")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("На месяц") { license.openCheckout(plan: "monthly") }
                Button("На год") { license.openCheckout(plan: "yearly") }.keyboardShortcut(.defaultAction)
            }
        }
        HStack {
            Button("Проверить подписку") { Task { await license.refresh() } }.disabled(license.isWorking)
            Button("Управлять в браузере") { license.openAccountPage() }
            Spacer()
            Button("Выйти на этом Mac") { Task { await license.signOut() } }.buttonStyle(.link)
        }
    }
}
#endif

#if CLEARWISE_LITE
/// App Store edition: StoreKit products, restore, manage. App Review wants the price, the period,
/// the terms and privacy links and «Восстановить покупки» on this screen (guideline 3.1.2).
private struct StorePurchaseSection: View {
    let store: StoreSubscription

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.active != nil {
                Button("Управлять подпиской") { store.openManageSubscriptions() }
            } else if store.products.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                ForEach(store.products, id: \.id) { product in
                    Button {
                        Task { await store.purchase(product) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(product.displayName).font(.headline)
                                if store.introEligible, let offer = product.subscription?.introductoryOffer,
                                   offer.paymentMode == .freeTrial {
                                    Text("Сначала бесплатно: \(offer.period.days) дн.").font(.caption)
                                }
                            }
                            Spacer()
                            Text(product.displayPrice).font(.headline)
                        }
                        .padding(.vertical, 4)
                    }
                    .disabled(store.isWorking)
                }
                Text("Подписка продлевается автоматически, пока вы её не отмените в настройках App Store не позже чем за сутки до конца периода.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Восстановить покупки") { Task { await store.restore() } }.disabled(store.isWorking)
                Spacer()
                Link("Условия", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Link("Конфиденциальность", destination: LicenseConfig.privacyURL)
            }
            .font(.caption)
            if let error = store.errorText {
                Text(error).font(.callout).foregroundStyle(Theme.warning)
            }
        }
    }
}
#endif

#if CLEARWISE_LITE
private extension Product.SubscriptionPeriod {
    var days: Int {
        switch unit {
        case .day: value
        case .week: value * 7
        case .month: value * 30
        case .year: value * 365
        @unknown default: value
        }
    }
}
#endif
