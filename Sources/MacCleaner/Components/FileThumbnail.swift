import SwiftUI
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Quick Look thumbnail of a file (photo, video frame, PDF page), falling back to its type icon.
struct FileThumbnail: View {
    let url: URL
    var size: CGFloat = 40
    @State private var image: NSImage?

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
                Image(nsImage: IconCache.typeIcon(for: url))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { image = await ThumbnailCache.thumbnail(for: url, side: size) }
    }
}

@MainActor
enum ThumbnailCache {
    private static var cache: [String: NSImage] = [:]
    private static var misses: Set<String> = []

    static func thumbnail(for url: URL, side: CGFloat) async -> NSImage? {
        let key = "\(url.path)#\(Int(side))"
        if let hit = cache[key] { return hit }
        if misses.contains(key) || !FileManager.default.fileExists(atPath: url.path) { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: 2, representationTypes: .thumbnail)
        let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        if let image { cache[key] = image } else { misses.insert(key) }
        return image
    }
}

extension IconCache {
    /// Finder icon when the file exists, else the generic icon of its type (keeps mock data readable).
    static func typeIcon(for url: URL) -> NSImage {
        if FileManager.default.fileExists(atPath: url.path) { return icon(for: url) }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}
