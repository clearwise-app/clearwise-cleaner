import SwiftUI
import CleanerKit

/// MacCleaner → Настройки… (⌘,): access status, one cleaning preference, about.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.confirmEmptyTrash) private var confirmEmptyTrash = true

    var body: some View {
        Form {
            Section("Доступ") {
                accessRow
            }

            Section("Очистка") {
                Toggle(isOn: $confirmEmptyTrash) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Показывать предупреждение перед очисткой Корзины")
                        Text("Очистка Корзины удаляет файлы навсегда — их нельзя вернуть.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Удаление файлов") {
                    Text("Всегда сначала в Корзину")
                        .foregroundStyle(.secondary)
                }
            }

            Section("О программе") {
                HStack(spacing: 12) {
                    AppGlyph(size: 40)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacCleaner").font(.headline)
                        Text(versionText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                Label("Работает без интернета и ничего никуда не отправляет.", systemImage: "wifi.slash")
                Label("Личные файлы никогда не отмечаются сами.", systemImage: "hand.raised.fill")
                Label("Всё удалённое сначала попадает в Корзину — его можно вернуть.", systemImage: "arrow.uturn.backward")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.locale, Locale(identifier: "ru_RU"))
    }

    @ViewBuilder private var accessRow: some View {
        let granted = model.hasFullDiskAccess
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 20))
                .foregroundStyle(granted ? Theme.success : Theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(granted ? "Полный доступ к диску включён" : "Нет полного доступа к диску")
                    .font(.headline)
                Text(granted
                     ? "MacCleaner видит все файлы, которые нужны для сканирования. Отключить доступ можно в Системных настройках."
                     : "Без него macOS скрывает кэши Safari и Mail, контейнеры приложений и резервные копии — MacCleaner найдёт не всё.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        HStack {
            if granted {
                Button("Открыть Системные настройки") { Permissions.openFullDiskAccessSettings() }
            } else {
                Button("Как дать доступ…") {
                    // The steps live in the main window: close Settings and show them there.
                    dismiss()
                    model.presentAccessSheet()
                }
                .keyboardShortcut(.defaultAction)
                Button("Показать MacCleaner в Finder") { Permissions.revealAppInFinder() }
            }
            Spacer()
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (version, build) {
        case let (v?, b?): return "Версия \(v) (\(b))"
        case let (v?, nil): return "Версия \(v)"
        default: return "Сборка для разработки"
        }
    }
}
