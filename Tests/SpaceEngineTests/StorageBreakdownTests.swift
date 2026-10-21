import XCTest
import CleanerKit
@testable import SpaceEngine

final class StorageBreakdownTests: FixtureTestCase {
    private let GB: Int64 = 1_000_000_000

    /// A fake home with one file per category; apps live outside it, like /Applications.
    private func makeFakeMac() throws -> StorageRoots {
        try makeFile("Applications/Big.app/Contents/MacOS/Big", blocks: 30)
        try makeFile("Applications/Big.app/Contents/Resources/a.car", blocks: 10)
        try makeFile("home/Applications/Mine.app/Contents/Info.plist", blocks: 2)
        try makeFile("home/Documents/report.pdf", blocks: 5)
        try makeFile("home/Desktop/note.txt", blocks: 1)
        try makeFile("home/Downloads/setup.dmg", blocks: 7)
        try makeFile("home/Projects/app/main.swift", blocks: 3)          // other visible folder → Документы
        try makeFile("home/Pictures/photo.jpg", blocks: 11)
        try makeFile("home/Movies/clip.mov", blocks: 13)
        try makeFile("home/Music/song.mp3", blocks: 17)
        try makeFile("home/Library/Developer/Xcode/DerivedData/x.o", blocks: 19)
        try makeFile("home/.npm/_cacache/blob", blocks: 4)
        try makeFile("SystemDeveloper/CoreSimulator/runtime.dmg", blocks: 12)  // like /Library/Developer
        try makeFile("home/Library/Mobile Documents/com~apple~CloudDocs/doc.pages", blocks: 23)
        try makeFile("home/Library/Caches/com.app/cache.db", blocks: 29)
        try makeFile("home/Library/Application Support/App/data", blocks: 6)
        try makeFile("home/Library/Containers/com.other/Data/secret", blocks: 31)
        try makeFile("home/Library/Group Containers/group.x/db", blocks: 8)
        try makeFile("home/.Trash/old.zip", blocks: 9)
        try makeFile("home/.zsh_history", blocks: 1)                       // loose hidden file: not a category
        let home = root.appendingPathComponent("home")
        return StorageRoots(home: home, applications: [root.appendingPathComponent("Applications"),
                                                       home.appendingPathComponent("Applications")],
                            systemDeveloper: [root.appendingPathComponent("SystemDeveloper")], volume: root)
    }

    private func analyze(_ roots: StorageRoots, fda: Bool, total: Int64 = 1_000 * 1_000_000_000,
                         free: Int64 = 400 * 1_000_000_000) async -> StorageBreakdown {
        await StorageAnalyzer(roots: roots, fullDiskAccess: fda, capacity: (total, free)).breakdown()
    }

    func testCategoriesWithFullDiskAccess() async throws {
        let b = await analyze(try makeFakeMac(), fda: true)
        XCTAssertEqual(b.bytes(.apps), bytes(42))
        XCTAssertEqual(b.bytes(.documents), bytes(16))
        XCTAssertEqual(b.bytes(.media), bytes(24))
        XCTAssertEqual(b.bytes(.music), bytes(17))
        XCTAssertEqual(b.bytes(.developer), bytes(35))
        XCTAssertEqual(b.bytes(.iCloud), bytes(23))
        // Library minus Developer and Mobile Documents, containers included.
        XCTAssertEqual(b.bytes(.appData), bytes(29 + 6 + 31 + 8))
        XCTAssertEqual(b.bytes(.trash), bytes(9))
        XCTAssertTrue(b.fullDiskAccess)
    }

    func testWithoutFullDiskAccessContainersAreNotEntered() async throws {
        let b = await analyze(try makeFakeMac(), fda: false)
        XCTAssertEqual(b.bytes(.appData), bytes(29 + 6), "Containers / Group Containers must stay closed")
        XCTAssertEqual(b.bytes(.developer), bytes(35))
        XCTAssertFalse(b.fullDiskAccess)
    }

    func testSystemIsTheRestAndEverythingAddsUp() async throws {
        let total = 1_000 * GB, free = 400 * GB
        let b = await analyze(try makeFakeMac(), fda: true, total: total, free: free)
        let known = b.categories.filter { $0.kind != .system }.map(\.bytes).reduce(0, +)
        XCTAssertEqual(b.bytes(.system), b.used - known)
        XCTAssertEqual(b.categories.map(\.bytes).reduce(0, +) + b.free, total)
        XCTAssertEqual(Set(b.categories.map(\.kind)), Set(StorageCategory.Kind.allCases))
        XCTAssertEqual(b.categories.first?.kind, .system, "biggest first")
        XCTAssertEqual(b.share(b.free), 0.4, accuracy: 1e-9)
    }

    func testComposeClampsWhenFoldersExceedUsed() {
        let b = StorageBreakdown.compose(volumeName: "X", total: 100, free: 40,
                                         measured: [.apps: 50, .media: 30, .system: 999])
        XCTAssertEqual(b.used, 60)
        XCTAssertGreaterThanOrEqual(b.bytes(.system), 0)
        XCTAssertLessThanOrEqual(b.categories.map(\.bytes).reduce(0, +), 60)
        XCTAssertEqual(b.bytes(.apps), 37)   // 50 × 60/80
        XCTAssertEqual(b.bytes(.media), 22)  // 30 × 60/80
        XCTAssertEqual(b.bytes(.system), 1)
    }

    func testComposeNeverNegativeAndFreeClamped() {
        let b = StorageBreakdown.compose(volumeName: "X", total: 100, free: 500, measured: [:])
        XCTAssertEqual(b.free, 100)
        XCTAssertEqual(b.used, 0)
        XCTAssertTrue(b.categories.allSatisfy { $0.bytes == 0 })
    }

    func testSymlinksAreNotFollowedAndRepeatsCountedOnce() async throws {
        let roots = try makeFakeMac()
        // A symlink into Movies from Documents, and a symlinked root folder.
        try fm.createSymbolicLink(at: roots.home.appendingPathComponent("Documents/movies-link"),
                                  withDestinationURL: roots.home.appendingPathComponent("Movies"))
        try fm.createSymbolicLink(at: roots.home.appendingPathComponent("Linked"),
                                  withDestinationURL: roots.home.appendingPathComponent("Music"))
        let b = await analyze(roots, fda: true)
        XCTAssertEqual(b.bytes(.documents), bytes(16))
        XCTAssertEqual(b.bytes(.media), bytes(24))
        XCTAssertEqual(b.bytes(.music), bytes(17))
    }

    func testMissingFoldersAreZero() async throws {
        let home = root.appendingPathComponent("empty-home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let b = await StorageAnalyzer(roots: StorageRoots(home: home, applications: [], systemDeveloper: [], volume: root),
                                      fullDiskAccess: true, capacity: (10 * GB, 4 * GB)).breakdown()
        XCTAssertEqual(b.bytes(.system), 6 * GB)
        XCTAssertTrue(b.categories.filter { $0.kind != .system }.allSatisfy { $0.bytes == 0 })
    }

    func testProgressReachesTheEnd() async throws {
        let roots = try makeFakeMac()
        let box = ProgressBox()
        _ = await StorageAnalyzer(roots: roots, fullDiskAccess: true, capacity: (10 * GB, 4 * GB))
            .breakdown { box.record($0.fraction) }
        XCTAssertEqual(box.last ?? 0, 1, accuracy: 1e-9)
    }

    func testCodableRoundTrip() throws {
        let b = StorageBreakdown.compose(volumeName: "Macintosh HD", total: 494 * GB, free: 183 * GB,
                                         measured: [.apps: 58 * GB, .media: 41 * GB], duration: 2.5)
        let data = try JSONEncoder().encode(b)
        XCTAssertEqual(try JSONDecoder().decode(StorageBreakdown.self, from: data), b)
    }

    func testTitlesAndSymbols() {
        XCTAssertEqual(StorageCategory.Kind.allCases.count, 9)
        XCTAssertEqual(Set(StorageCategory.Kind.allCases.map(\.title)).count, 9)
        XCTAssertEqual(StorageCategory.Kind.system.title, "Система и прочее")
        XCTAssertTrue(StorageCategory.Kind.allCases.allSatisfy { !$0.symbol.isEmpty && !$0.shortTitle.isEmpty })
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func record(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
    var last: Double? { lock.lock(); defer { lock.unlock() }; return values.last }
}
