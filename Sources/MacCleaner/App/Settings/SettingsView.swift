import SwiftUI
import CleanerKit

/// MacCleaner → Настройки… (⌘,): access status, cleaning preferences, about.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.confirmEmptyTrash) private var confirmEmptyTrash = true
    @AppStorage(SettingsKeys.deletePermanently) private var deletePermanently = false
    @AppStorage(SettingsKeys.cleanupMode) private var cleanupMode = CleanupMode.gentle.rawValue
    @State private var language = AppLanguage.chosen

    var body: some View {
        Form {
            Section("Доступ") {
                accessRow
            }

            Section("Язык / Language") {
                Picker("Язык интерфейса", selection: $language) {
                    Text("Как в системе").tag(AppLanguage.system)
                    Text("Русский").tag(AppLanguage.russian)
                    Text("English").tag(AppLanguage.english)
                }
                .pickerStyle(.segmented)
                .onChange(of: language) { _, new in AppLanguage.chosen = new }
                if language.resolved != AppLanguage.running {
                    HStack {
                        Text("Язык изменится после перезапуска приложения.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Перезапустить") { AppLanguage.relaunch() }
                    }
                }
            }

            Section("Режим очистки") {
                Picker("Что отмечать после сканирования", selection: $cleanupMode) {
                    ForEach(CleanupMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 4) {
                    Text((CleanupMode(rawValue: cleanupMode) ?? .gentle).summary)
                    Text("Режим только расставляет галочки — перед очисткой всё видно и можно поправить. Корзина, последняя копия каждого iPhone и тома Docker не отмечаются никогда.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
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
                Toggle(isOn: $deletePermanently) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Сразу удалять навсегда, минуя Корзину")
                        Text(deletePermanently
                             ? "Убранное удаляется сразу и освобождает место. Вернуть его будет нельзя. Остальное содержимое Корзины не трогается."
                             : "Всё убранное сначала попадает в Корзину — его можно вернуть, пока Корзина не очищена.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("О программе") {
                HStack(spacing: 12) {
                    AppGlyph(size: 40)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(AppInfo.name)").font(.headline)
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
        .environment(\.locale, AppLanguage.locale)
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
                     ? "\(AppInfo.name) видит все файлы, которые нужны для сканирования. Отключить доступ можно в Системных настройках."
                     : "Без него macOS скрывает кэши Safari и Mail, контейнеры приложений и резервные копии — \(AppInfo.name) найдёт не всё.")
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
                Button("Показать \(AppInfo.name) в Finder") { Permissions.revealAppInFinder() }
            }
            Spacer()
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (version, build) {
        case let (v?, b?): return String(localized: "Версия \(v) (\(b))")
        case let (v?, nil): return String(localized: "Версия \(v)")
        default: return String(localized: "Сборка для разработки")
        }
    }
}
