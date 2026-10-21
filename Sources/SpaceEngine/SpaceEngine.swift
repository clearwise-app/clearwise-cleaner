import Foundation
import CleanerKit

// CONTRACT (used by the UI — keep these signatures):
//   public enum FileKind: String, CaseIterable, Sendable { … ; public var title: String; public var symbol: String }
//   public struct AnalyzedFile: Identifiable, Hashable, Sendable { public let item: FileItem; public let kind: FileKind; public var id: URL }
//   public struct OldFilesOptions: Sendable { public var roots: [URL]; public var unusedForDays: Int; public var minSize: Int64; public static var `default`: OldFilesOptions }
//   public actor FileAnalyzer {
//       public init()
//       public func oldFiles(_ options: OldFilesOptions, progress: ProgressHandler?) async -> [AnalyzedFile]
//       public func largeFiles(roots: [URL], minSize: Int64, progress: ProgressHandler?) async -> [AnalyzedFile]
//   }
//   public actor SpaceMapper { public init(); public func map(_ root: URL, depth: Int, progress: ProgressHandler?) async -> DirectoryNode }
// STUB — to be replaced by the SpaceEngine implementation.

public enum FileKind: String, CaseIterable, Sendable {
    case document, archive, diskImage, installer, video, audio, image, code, other
    public var title: String { rawValue }
    public var symbol: String { "doc" }
}

public struct AnalyzedFile: Identifiable, Hashable, Sendable {
    public let item: FileItem
    public let kind: FileKind
    public var id: URL { item.url }
    public init(item: FileItem, kind: FileKind) { self.item = item; self.kind = kind }
}

public struct OldFilesOptions: Sendable {
    public var roots: [URL]
    public var unusedForDays: Int
    public var minSize: Int64
    public init(roots: [URL], unusedForDays: Int, minSize: Int64) {
        self.roots = roots; self.unusedForDays = unusedForDays; self.minSize = minSize
    }
    public static var `default`: OldFilesOptions {
        let h = SafetyGuard.home
        return OldFilesOptions(roots: ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"].map { h.appendingPathComponent($0) },
                               unusedForDays: 180, minSize: 10 * 1024 * 1024)
    }
}

public actor FileAnalyzer {
    public init() {}
    public func oldFiles(_ options: OldFilesOptions, progress: ProgressHandler? = nil) async -> [AnalyzedFile] { [] }
    public func largeFiles(roots: [URL], minSize: Int64, progress: ProgressHandler? = nil) async -> [AnalyzedFile] { [] }
}

public actor SpaceMapper {
    public init() {}
    public func map(_ root: URL, depth: Int = 4, progress: ProgressHandler? = nil) async -> DirectoryNode {
        DirectoryNode(url: root, size: 0, isDirectory: true, children: [])
    }
}
