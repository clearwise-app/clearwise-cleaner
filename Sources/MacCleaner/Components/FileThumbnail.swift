import SwiftUI
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Quick Look thumbnail of a file (photo, video frame, PDF page), falling back to its type icon.
/// `body` only reads caches; the disk check and the thumbnail run in `.task`.
struct FileThumbnail: View {
    let url: URL
    var size: CGFloat = 40
    @State private var image: NSImage?
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            } else {
                Image(nsImage: icon ?? IconCache.cachedIcon(for: url) ?? IconCache.genericIcon(for: url))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: url) {
            let path = url.path
            let exists = await Task.detached(priority: .utility) { FileManager.default.fileExists(atPath: path) }.value
            guard !Task.isCancelled else { return }
            // Missing files (mock data, already removed) keep the generic icon of their type.
            icon = exists ? IconCache.icon(for: url) : nil
            image = exists ? await ThumbnailCache.thumbnail(for: url, side: size) : nil
        }
    }
}

/// Finder icon of a file. Shows the cached or generic type icon at once and fetches the real one
/// in `.task`, so scrolling a long list never calls NSWorkspace from `body`.
struct FileIcon: View {
    let url: URL
    var size: CGFloat = 22
    @State private var icon: NSImage?

    var body: some View {
        Image(nsImage: icon ?? IconCache.cachedIcon(for: url) ?? IconCache.genericIcon(for: url))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .task(id: url) { icon = IconCache.icon(for: url) }
    }
}

@MainActor
enum ThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 300
        return c
    }()
    private static var misses: Set<String> = []

    /// Callers check that the file exists; a failed render is remembered as a miss.
    static func thumbnail(for url: URL, side: CGFloat) async -> NSImage? {
        let key = "\(url.path)#\(Int(side))"
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if misses.contains(key) { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: 2, representationTypes: .thumbnail)
        let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        if let image { cache.setObject(image, forKey: key as NSString) } else { misses.insert(key) }
        return image
    }
}

extension IconCache {
    /// Finder icon when the file exists, else the generic icon of its type (keeps mock data readable).
    /// Touches the disk: call it from `.task`, not from `body` (FileThumbnail and FileIcon do).
    static func typeIcon(for url: URL) -> NSImage {
        if FileManager.default.fileExists(atPath: url.path) { return icon(for: url) }
        return genericIcon(for: url)
    }
}
