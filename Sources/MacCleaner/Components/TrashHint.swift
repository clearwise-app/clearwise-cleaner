import SwiftUI
import SpaceEngine

/// «В Корзине 797 МБ — это место ещё занято»: cleanups move files to the Trash (so they can be put back),
/// and the space comes back only when it is emptied. One tap away from «Очистить Корзину…».
/// Renders nothing while the Trash is (almost) empty or the disk has not been measured yet.
struct TrashHint: View {
    @Environment(AppModel.self) private var app

    private static let minimumBytes: Int64 = 1_000_000

    var body: some View {
        if let bytes = app.storage.breakdown?.bytes(.trash), bytes >= Self.minimumBytes {
            HStack(spacing: 14) {
                IconTile(symbol: "trash.fill", tint: .junk, size: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("В Корзине \(Fmt.size(bytes)) — это место ещё занято")
                        .font(.cardTitle)
                        .foregroundStyle(Theme.text)
                    Text("Очистка переносит файлы в Корзину, чтобы их можно было вернуть. Место освободится, когда вы её очистите.")
                        .font(.caption12)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                Button("Открыть") { Finder.openTrash() }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .help("Посмотреть, что лежит в Корзине")
                Button("Очистить Корзину…") { app.requestEmptyTrash() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .help("Удалить содержимое Корзины навсегда и освободить место")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .glass(radius: 14)
            .frame(maxWidth: 760)
        }
    }
}
