import Foundation
import UniformTypeIdentifiers

/// Coarse content category used to group files in the "old & large files" screen.
public enum FileKind: String, CaseIterable, Sendable {
    case document, archive, diskImage, installer, video, audio, image, code, other

    public var title: String {
        switch self {
        case .document: String(localized: "Документы", bundle: .module)
        case .archive: String(localized: "Архивы", bundle: .module)
        case .diskImage: String(localized: "Образы дисков", bundle: .module)
        case .installer: String(localized: "Установщики", bundle: .module)
        case .video: String(localized: "Видео", bundle: .module)
        case .audio: String(localized: "Аудио", bundle: .module)
        case .image: String(localized: "Изображения", bundle: .module)
        case .code: String(localized: "Код и проекты", bundle: .module)
        case .other: String(localized: "Другое", bundle: .module)
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .document: "doc.text.fill"
        case .archive: "archivebox.fill"
        case .diskImage: "externaldrive.fill"
        case .installer: "shippingbox.fill"
        case .video: "film.fill"
        case .audio: "music.note"
        case .image: "photo.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .other: "doc.fill"
        }
    }
}

// MARK: - Classification

extension FileKind {
    /// Classifies by file name / extension: UTType conformance first, curated extension lists as fallback.
    public static func classify(_ url: URL) -> FileKind {
        classify(pathExtension: url.pathExtension)
    }

    public static func classify(pathExtension rawExt: String) -> FileKind {
        let ext = rawExt.lowercased()
        guard !ext.isEmpty else { return .other }
        if let cached = cache.value(for: ext) { return cached }
        let kind = compute(ext)
        cache.set(kind, for: ext)
        return kind
    }

    private static func compute(_ ext: String) -> FileKind {
        // Explicit lists win where UTType is ambiguous or too coarse (pkg/dmg/xcodeproj/…).
        if installerExts.contains(ext) { return .installer }
        if diskImageExts.contains(ext) { return .diskImage }
        if let packageKind = packageKinds[ext] { return packageKind }
        if ambiguousExts.contains(ext) { return .other }

        if let type = UTType(filenameExtension: ext), !type.isDynamic {
            if type.conforms(to: .diskImage) { return .diskImage }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .archive) { return .archive }
            if codeExts.contains(ext) || type.conforms(to: .sourceCode) || type.conforms(to: .script) { return .code }
            if type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
                || type.conforms(to: .text) || type.conforms(to: .rtf) || type.conforms(to: .compositeContent) {
                return .document
            }
        }
        // Extension fallback for types the system does not know.
        if archiveExts.contains(ext) { return .archive }
        if videoExts.contains(ext) { return .video }
        if audioExts.contains(ext) { return .audio }
        if imageExts.contains(ext) { return .image }
        if codeExts.contains(ext) { return .code }
        if documentExts.contains(ext) { return .document }
        return .other
    }

    /// Extensions the system maps to something misleading (".bin" is "MacBinary archive" to UTType).
    static let ambiguousExts: Set<String> = ["bin", "dat", "tmp", "part", "crdownload", "download"]
    static let installerExts: Set<String> = ["pkg", "mpkg", "msi", "exe", "deb", "rpm", "apk", "ipa", "appimage"]
    static let diskImageExts: Set<String> = ["dmg", "iso", "img", "cdr", "sparseimage", "sparsebundle", "vmdk", "vdi", "vhd", "vhdx", "qcow2", "toast"]
    static let archiveExts: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz", "lzma", "cab", "sit", "sitx", "z", "jar", "war"]
    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "wmv", "flv", "webm", "mpg", "mpeg", "mts", "m2ts", "3gp", "vob", "ogv", "braw", "mxf"]
    static let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "wma", "alac", "caf", "mid", "midi"]
    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "raf", "psd", "ai", "svg", "icns"]
    static let documentExts: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "odt", "ods", "odp", "rtf", "txt", "md", "epub", "djvu", "fb2", "mobi", "csv", "tex"]
    static let codeExts: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "rs", "go", "py", "rb", "js", "jsx", "mjs", "ts", "tsx",
        "java", "kt", "kts", "cs", "php", "pl", "sh", "zsh", "bash", "lua", "dart", "scala", "sql",
        "json", "yaml", "yml", "toml", "xml", "html", "htm", "css", "scss", "ipynb", "gradle",
    ]
    /// Packages (bundles) shown as a single item: the kind describes what is inside.
    static let packageKinds: [String: FileKind] = [
        "xcodeproj": .code, "xcworkspace": .code, "playground": .code, "swiftpm": .code, "xcarchive": .code,
        "fcpbundle": .video, "imovielibrary": .video, "photoslibrary": .image, "photolibrary": .image,
        "logicx": .audio, "band": .audio, "musiclibrary": .audio,
        "app": .other,
    ]

    private static let cache = KindCache()

    private final class KindCache: @unchecked Sendable {
        private var storage: [String: FileKind] = [:]
        private let lock = NSLock()
        func value(for key: String) -> FileKind? { lock.lock(); defer { lock.unlock() }; return storage[key] }
        func set(_ kind: FileKind, for key: String) { lock.lock(); storage[key] = kind; lock.unlock() }
    }
}
