import Foundation
import CoreServices

public enum FileSizer {
    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    /// Allocated size on disk, recursive for folders and packages. Symlinks are not followed.
    public static func allocatedSize(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        if values.isDirectory != true { return fileSize(values) }

        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }
        )
        while let child = enumerator?.nextObject() as? URL {
            guard let v = try? child.resourceValues(forKeys: keys) else { continue }
            if v.isSymbolicLink == true || v.isDirectory == true { continue }
            total += fileSize(v)
        }
        return total
    }

    private static func fileSize(_ v: URLResourceValues) -> Int64 {
        Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
    }

    /// Builds a `FileItem` with size and dates filled in.
    public static func item(for url: URL) -> FileItem {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .contentAccessDateKey])
        let isDir = v?.isDirectory ?? false
        return FileItem(
            url: url,
            size: allocatedSize(of: url),
            isDirectory: isDir,
            lastUsed: FileMetadata.lastUsedDate(of: url) ?? v?.contentAccessDate,
            modified: v?.contentModificationDate
        )
    }
}

public enum FileMetadata {
    /// Spotlight "Last opened" date. Nil when Spotlight has no record (never opened via Launch Services).
    public static func lastUsedDate(of url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Spotlight "Date added" (useful fallback for files that were never opened).
    public static func dateAdded(of url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemDateAdded) as? Date
    }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
