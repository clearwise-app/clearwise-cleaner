import Foundation
import XCTest
import CleanerKit
@testable import SpaceEngine

/// Temp-dir fixtures. Everything lives under a unique folder that is removed in `tearDown`.
class FixtureTestCase: XCTestCase {
    var root: URL!
    let fm = FileManager.default
    static let block = 4096
    /// Size in bytes of `n` fixture blocks.
    func bytes(_ n: Int) -> Int64 { Int64(n * Self.block) }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("SpaceEngineTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Restore permissions possibly dropped by a test, then clean up.
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let u as URL in e { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path) }
        }
        try? fm.removeItem(at: root)
    }

    @discardableResult
    func makeFile(_ relative: String, blocks: Int = 1, daysOld: Int? = nil) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Non-zero, non-repeating-by-path content so identical sizes are not accidental duplicates.
        var bytes = [UInt8](repeating: 0, count: blocks * Self.block)
        var seed = UInt64(truncatingIfNeeded: relative.hashValue)
        for i in stride(from: 0, to: bytes.count, by: 97) { seed = seed &* 6364136223846793005 &+ 1442695040888963407; bytes[i] = UInt8(truncatingIfNeeded: seed >> 33) }
        try Data(bytes).write(to: url)
        if let daysOld { try age(url, days: daysOld) }
        return url
    }

    func age(_ url: URL, days: Int) throws {
        let date = Date().addingTimeInterval(-Double(days) * 86_400)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func options(days: Int = 180, minBlocks: Int = 100) -> OldFilesOptions {
        var o = OldFilesOptions(roots: [root], unusedForDays: days, minSize: Int64(minBlocks * Self.block))
        o.useSpotlight = false
        return o
    }

    func names(_ files: [AnalyzedFile]) -> [String] { files.map { $0.item.url.lastPathComponent } }
}
