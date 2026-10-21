import Foundation
import Darwin

/// Fast recursive sizing with `fts(3)`: one `stat` per entry, no Foundation object per file.
/// Counts allocated blocks of regular files and symlinks (like `FileSizer`, symlinks are not followed
/// and directories themselves are not counted) and stays on one volume.
enum TreeSizer {
    struct Measurement: Sendable {
        var size: Int64 = 0
        var isDirectory = false
        /// Newest modification date of the item or anything inside it.
        var newestModification: Date?
        /// Newest of modification and status-change times — "was anything touched lately?".
        /// Uses ctime too, because extracted or copied files keep an old mtime.
        var newestActivity: Date?
        /// Own modification date of the top-level item.
        var modification: Date?
        /// The tree contains a UNIX socket (some process is likely listening on it).
        var containsSocket = false
        var exists = false
    }

    static func measure(_ url: URL) -> Measurement {
        var m = Measurement()
        url.withUnsafeFileSystemRepresentation { rep in
            guard let rep, let path = strdup(rep) else { return }
            defer { free(path) }
            var argv: [UnsafeMutablePointer<CChar>?] = [path, nil]
            guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
            defer { fts_close(fts) }
            var newest: Int = 0
            var activity: Int = 0
            while let ent = fts_read(fts) {
                let info = Int32(ent.pointee.fts_info)
                let isRoot = ent.pointee.fts_level == 0
                guard let st = ent.pointee.fts_statp else { continue }
                switch info {
                case FTS_D:
                    let t = st.pointee.st_mtimespec.tv_sec
                    newest = max(newest, t)
                    activity = max(activity, t, st.pointee.st_ctimespec.tv_sec)
                    if isRoot {
                        m.exists = true
                        m.isDirectory = true
                        m.modification = Date(timeIntervalSince1970: TimeInterval(t))
                    }
                case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                    let t = st.pointee.st_mtimespec.tv_sec
                    newest = max(newest, t)
                    activity = max(activity, t, st.pointee.st_ctimespec.tv_sec)
                    m.size += Int64(st.pointee.st_blocks) * 512
                    if (st.pointee.st_mode & S_IFMT) == S_IFSOCK { m.containsSocket = true }
                    if isRoot {
                        m.exists = true
                        m.modification = Date(timeIntervalSince1970: TimeInterval(t))
                    }
                default:
                    // FTS_DP (post-order), FTS_DNR / FTS_ERR / FTS_NS (unreadable — skipped silently).
                    break
                }
            }
            if newest > 0 { m.newestModification = Date(timeIntervalSince1970: TimeInterval(newest)) }
            if activity > 0 { m.newestActivity = Date(timeIntervalSince1970: TimeInterval(activity)) }
        }
        return m
    }
}
