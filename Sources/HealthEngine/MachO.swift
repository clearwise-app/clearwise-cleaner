import Foundation

/// CPU architectures a Mach-O file contains, read from its header only (thin or fat/universal).
public enum CPUArchitecture: Hashable, Sendable, Codable, Comparable {
    case arm64, x86_64, i386, powerPC, other(Int32)

    init(cpuType: Int32) {
        switch cpuType {
        case 0x0100_000C: self = .arm64     // CPU_TYPE_ARM64 (arm64 and arm64e)
        case 0x0100_0007: self = .x86_64    // CPU_TYPE_X86_64
        case 7: self = .i386
        case 18, 0x0100_0012: self = .powerPC
        default: self = .other(cpuType)
        }
    }

    public var isIntel: Bool { self == .x86_64 || self == .i386 }

    public var title: String {
        switch self {
        case .arm64: "arm64"
        case .x86_64: "x86_64"
        case .i386: "i386"
        case .powerPC: "PowerPC"
        case .other(let t): "cpu \(t)"
        }
    }
}

public enum MachO {
    static let fatMagic: UInt32 = 0xCAFE_BABE
    static let fatMagic64: UInt32 = 0xCAFE_BABF
    static let magic32: UInt32 = 0xFEED_FACE
    static let magic64: UInt32 = 0xFEED_FACF

    /// Bytes enough for any realistic fat header (8 + 20 × arch count).
    static let headerBytes = 4096

    public static func architectures(atPath path: String) -> Set<CPUArchitecture>? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headerBytes) else { return nil }
        return architectures(header: data)
    }

    /// Nil when the bytes are not a Mach-O (a script, a Java class file — which shares 0xCAFEBABE —, garbage).
    public static func architectures(header data: Data) -> Set<CPUArchitecture>? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return nil }
        func be32(_ o: Int) -> UInt32? {
            guard o + 4 <= bytes.count else { return nil }
            return UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3])
        }
        guard let magic = be32(0) else { return nil }

        switch magic {
        case fatMagic, fatMagic64:
            // Fat headers are always big-endian. Java class files start with the same magic followed by a
            // version ≥ 45, while real fat files have a handful of slices.
            guard let count = be32(4), count > 0, count < 32 else { return nil }
            let stride = magic == fatMagic ? 20 : 32
            var result = Set<CPUArchitecture>()
            for i in 0..<Int(count) {
                guard let cpu = be32(8 + i * stride) else { return nil }
                result.insert(CPUArchitecture(cpuType: Int32(bitPattern: cpu)))
            }
            return result
        case magic32, magic64:
            // Big-endian thin file (PowerPC era).
            return be32(4).map { [CPUArchitecture(cpuType: Int32(bitPattern: $0))] }
        case magic32.byteSwapped, magic64.byteSwapped:
            // Little-endian thin file: every Intel and Apple silicon binary.
            return be32(4).map { [CPUArchitecture(cpuType: Int32(bitPattern: $0.byteSwapped))] }
        default:
            return nil
        }
    }
}
