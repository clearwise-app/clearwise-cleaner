import Foundation
import CleanerKit

// CONTRACT (used by the UI — keep these signatures):
//   public actor JunkScanner { public init(); public func scan(progress: ProgressHandler?) async -> [JunkCategory] }
//   public enum JunkCleaner { public static func clean(_ items: [FileItem], in category: JunkCategory) async -> RemovalResult }
// STUB — to be replaced by the JunkEngine implementation.

public actor JunkScanner {
    public init() {}

    /// Scans all junk categories. Returns only categories with at least one item, sorted by size desc.
    public func scan(progress: ProgressHandler? = nil) async -> [JunkCategory] {
        progress?(ScanProgress(phase: "Готово", fraction: 1))
        return []
    }
}

public enum JunkCleaner {
    /// Removes the selected items of a category (Trash category is emptied permanently, everything else goes to Trash).
    public static func clean(_ items: [FileItem], in category: JunkCategory) async -> RemovalResult {
        await FileRemover.moveToTrash(items.map(\.url), knownSizes: Dictionary(uniqueKeysWithValues: items.map { ($0.url, $0.size) }))
    }
}
