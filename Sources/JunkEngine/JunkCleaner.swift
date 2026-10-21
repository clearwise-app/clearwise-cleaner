import Foundation
import CleanerKit

public enum JunkCleaner {
    /// Removes the selected items of a category (Trash category is emptied permanently, everything else goes to Trash).
    /// Items that are not part of `category` are refused, so a UI bug cannot widen what gets removed.
    public static func clean(_ items: [FileItem], in category: JunkCategory) async -> RemovalResult {
        let known = Set(category.items.map { FS.key($0.url) })
        var result = RemovalResult()
        var accepted: [FileItem] = []
        for item in items {
            if known.contains(FS.key(item.url)) {
                accepted.append(item)
            } else {
                result.failed.append(RemovalFailure(url: item.url, reason: "Не входит в категорию «\(category.title)»"))
            }
        }
        guard !accepted.isEmpty else { return result }
        let sizes = Dictionary(accepted.map { ($0.url, $0.size) }, uniquingKeysWith: { first, _ in first })

        switch category.id {
        case JunkCategoryID.trash:
            result.merge(await FileRemover.deletePermanentlyFromTrash(accepted.map(\.url), knownSizes: sizes))
        case JunkCategoryID.systemLogs:
            // Root-owned logs need the admin prompt; anything the user owns goes the normal way.
            let userOwned = accepted.filter { FileManager.default.isDeletableFile(atPath: $0.url.path) }.map(\.url)
            let rootOwned = accepted.filter { !FileManager.default.isDeletableFile(atPath: $0.url.path) }.map(\.url)
            if !userOwned.isEmpty { result.merge(await FileRemover.moveToTrash(userOwned, knownSizes: sizes)) }
            if !rootOwned.isEmpty { result.merge(await FileRemover.moveToTrashAsAdmin(rootOwned, knownSizes: sizes)) }
        default:
            result.merge(await FileRemover.moveToTrash(accepted.map(\.url), knownSizes: sizes))
        }
        return result
    }
}
