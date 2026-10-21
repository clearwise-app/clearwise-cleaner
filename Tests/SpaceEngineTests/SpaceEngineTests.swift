import XCTest
import CleanerKit
@testable import SpaceEngine

// MARK: - FileKind

final class FileKindTests: XCTestCase {
    func testClassification() {
        let cases: [(String, FileKind)] = [
            ("report.pdf", .document), ("a.docx", .document), ("notes.txt", .document), ("t.xlsx", .document), ("deck.key", .document),
            ("a.zip", .archive), ("a.tar.gz", .archive), ("a.7z", .archive), ("a.rar", .archive),
            ("ubuntu.iso", .diskImage), ("Setup.dmg", .diskImage), ("vm.vmdk", .diskImage),
            ("app.pkg", .installer), ("x.mpkg", .installer), ("setup.exe", .installer), ("a.deb", .installer),
            ("movie.mp4", .video), ("clip.MOV", .video), ("film.mkv", .video), ("a.avi", .video),
            ("song.mp3", .audio), ("a.wav", .audio), ("a.flac", .audio), ("a.m4a", .audio),
            ("photo.jpg", .image), ("a.PNG", .image), ("a.heic", .image), ("a.psd", .image),
            ("main.swift", .code), ("a.py", .code), ("a.json", .code), ("index.html", .code), ("P.xcodeproj", .code),
            ("noext", .other), ("data.zzzunknown", .other), ("Some.app", .other),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(FileKind.classify(URL(fileURLWithPath: "/tmp/\(name)")), expected, name)
        }
    }

    func testTitlesAndSymbols() {
        XCTAssertEqual(FileKind.allCases.count, 9)
        XCTAssertEqual(FileKind.document.title, "Документы")
        XCTAssertEqual(FileKind.diskImage.title, "Образы дисков")
        XCTAssertEqual(FileKind.code.title, "Код и проекты")
        XCTAssertEqual(FileKind.other.title, "Другое")
        XCTAssertEqual(Set(FileKind.allCases.map(\.title)).count, 9)
        XCTAssertTrue(FileKind.allCases.allSatisfy { !$0.symbol.isEmpty })
    }
}

// MARK: - Old & large files

final class FileAnalyzerTests: FixtureTestCase {
    func testOldFilesHonorDatesAndSize() async throws {
        try makeFile("old_big.bin", blocks: 300, daysOld: 400)
        try makeFile("old_bigger.mp4", blocks: 500, daysOld: 200)
        try makeFile("recent_big.bin", blocks: 600)
        try makeFile("old_small.bin", blocks: 10, daysOld: 400)
        try makeFile("almost.bin", blocks: 300, daysOld: 170)

        let result = await FileAnalyzer().oldFiles(options(days: 180), progress: nil)
        XCTAssertEqual(names(result), ["old_bigger.mp4", "old_big.bin"], "sorted by size desc, recent/small excluded")
        XCTAssertEqual(result[0].kind, .video)
        XCTAssertEqual(result[1].kind, .other)

        let last = try XCTUnwrap(result[1].item.lastUsed)
        XCTAssertEqual(last.timeIntervalSinceNow, -400 * 86_400, accuracy: 120)
        XCTAssertNotNil(result[1].item.modified)
        XCTAssertGreaterThanOrEqual(result[1].item.size, bytes(300))

        let shorter = await FileAnalyzer().oldFiles(options(days: 100), progress: nil)
        XCTAssertEqual(Set(names(shorter)), ["old_big.bin", "old_bigger.mp4", "almost.bin"])
        let longer = await FileAnalyzer().oldFiles(options(days: 900), progress: nil)
        XCTAssertTrue(longer.isEmpty)
    }

    func testSizeThreshold() async throws {
        try makeFile("a.bin", blocks: 99, daysOld: 400)
        try makeFile("b.bin", blocks: 101, daysOld: 400)
        let result = await FileAnalyzer().oldFiles(options(minBlocks: 100), progress: nil)
        XCTAssertEqual(names(result), ["b.bin"])
    }

    func testSkipsHiddenNodeModulesGitAndSymlinks() async throws {
        try makeFile(".hidden.bin", blocks: 300, daysOld: 400)
        try makeFile(".hiddendir/inside.bin", blocks: 300, daysOld: 400)
        try makeFile("proj/node_modules/pkg/huge.bin", blocks: 300, daysOld: 400)
        try makeFile("proj/.git/objects/huge.pack", blocks: 300, daysOld: 400)
        try makeFile("proj/src/visible.bin", blocks: 300, daysOld: 400)
        let outside = fm.temporaryDirectory.appendingPathComponent("SpaceEngineOutside-\(UUID().uuidString)")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        let target = outside.appendingPathComponent("target.bin")
        try Data(count: 300 * Self.block).write(to: target)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -400 * 86_400)], ofItemAtPath: target.path)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.bin"), withDestinationURL: target)
        try fm.createSymbolicLink(at: root.appendingPathComponent("linkdir"), withDestinationURL: outside)

        let result = await FileAnalyzer().oldFiles(options(), progress: nil)
        XCTAssertEqual(names(result), ["visible.bin"])
    }

    func testPackagesAreOneItemAndLibrariesAreSkipped() async throws {
        for i in 0..<3 { try makeFile("Big.app/Contents/Resources/f\(i).bin", blocks: 150) }
        try makeFile("Big.app/Contents/.hidden", blocks: 50)
        try age(root.appendingPathComponent("Big.app"), days: 400)
        for i in 0..<3 { try makeFile("My.xcodeproj/p\(i).bin", blocks: 150) }
        try age(root.appendingPathComponent("My.xcodeproj"), days: 400)
        try makeFile("Photos Library.photoslibrary/originals/a.heic", blocks: 500)
        try age(root.appendingPathComponent("Photos Library.photoslibrary"), days: 400)
        try makeFile("Music.musiclibrary/Tracks/a.m4a", blocks: 500)
        try age(root.appendingPathComponent("Music.musiclibrary"), days: 400)

        let result = await FileAnalyzer().oldFiles(options(), progress: nil)
        XCTAssertEqual(Set(names(result)), ["Big.app", "My.xcodeproj"], "packages as single items, libraries skipped")
        let app = try XCTUnwrap(result.first { $0.item.url.lastPathComponent == "Big.app" })
        XCTAssertTrue(app.item.isDirectory)
        XCTAssertGreaterThanOrEqual(app.item.size, bytes(500), "whole package incl. hidden files")
        XCTAssertEqual(result.first { $0.item.url.lastPathComponent == "My.xcodeproj" }?.kind, .code)

        // Large files treat packages the same way and skip libraries too.
        let large = await FileAnalyzer().largeFiles(roots: [root], minSize: bytes(100), progress: nil)
        XCTAssertEqual(Set(names(large)), ["Big.app", "My.xcodeproj"])
    }

    func testLargeFilesAnyAgeSortedBySize() async throws {
        try makeFile("new_mid.bin", blocks: 200)
        try makeFile("old_huge.bin", blocks: 900, daysOld: 999)
        try makeFile("small.bin", blocks: 5)
        try makeFile("sub/dir/biggish.bin", blocks: 400, daysOld: 3)
        let result = await FileAnalyzer().largeFiles(roots: [root], minSize: bytes(100), progress: nil)
        XCTAssertEqual(names(result), ["old_huge.bin", "biggish.bin", "new_mid.bin"])
        XCTAssertEqual(result, result.sorted { $0.item.size > $1.item.size })
    }

    func testOverlappingRootsDoNotDuplicate() async throws {
        try makeFile("sub/x.bin", blocks: 300, daysOld: 400)
        var o = options()
        o.roots = [root, root.appendingPathComponent("sub")]
        let result = await FileAnalyzer().oldFiles(o, progress: nil)
        XCTAssertEqual(names(result), ["x.bin"])
    }

    func testMissingRootIsIgnoredAndProgressIsReported() async throws {
        try makeFile("x.bin", blocks: 300, daysOld: 400)
        var o = options()
        o.roots = [root, root.appendingPathComponent("does-not-exist")]
        let phases = PhaseLog()
        let result = await FileAnalyzer().oldFiles(o) { phases.add($0) }
        XCTAssertEqual(names(result), ["x.bin"])
        XCTAssertFalse(phases.all.isEmpty)
        XCTAssertEqual(phases.all.last?.fraction, 1)
    }

    func testCancellationReturnsPromptly() async throws {
        for i in 0..<50 { try makeFile("d\(i % 5)/f\(i).bin", blocks: 2, daysOld: 400) }
        let task = Task { await FileAnalyzer().oldFiles(self.options(minBlocks: 1), progress: nil) }
        task.cancel()
        _ = await task.value   // must finish (partial result is fine)
    }

    func testDuplicates() async throws {
        let payload = Data((0..<(200 * Self.block)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        func write(_ rel: String, _ data: Data, days: Int) throws {
            let u = root.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: u)
            try age(u, days: days)
        }
        try write("a/orig.bin", payload, days: 30)
        try write("b/copy.bin", payload, days: 5)
        try write("c/copy2.bin", payload, days: 1)
        // same size, same first 64 KB, different tail -> not a duplicate
        var tail = payload; tail[tail.count - 1] ^= 0xFF
        try write("d/tail.bin", tail, days: 1)
        // same size, different head
        var head = payload; head[0] ^= 0xFF
        try write("e/head.bin", head, days: 1)
        // hard link of orig: must not count as a duplicate
        try fm.linkItem(at: root.appendingPathComponent("a/orig.bin"), to: root.appendingPathComponent("a/hardlink.bin"))
        // another pair
        let other = Data(repeating: 0x42, count: 150 * Self.block)
        try write("f/o1.bin", other, days: 1)
        try write("g/o2.bin", other, days: 2)

        let groups = await FileAnalyzer().duplicates(roots: [root], minSize: bytes(100), progress: nil)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].count, 3, "biggest wasted space first")
        XCTAssertEqual(Set(groups[0].map { $0.item.url.lastPathComponent }).count, 3)
        XCTAssertEqual(groups[0].first?.item.url.lastPathComponent, "orig.bin", "oldest first")
        XCTAssertFalse(groups[0].contains { $0.item.url.lastPathComponent == "tail.bin" || $0.item.url.lastPathComponent == "head.bin" })
        XCTAssertEqual(Set(groups[1].map { $0.item.url.lastPathComponent }), ["o1.bin", "o2.bin"])
    }
}

final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ScanProgress] = []
    func add(_ p: ScanProgress) { lock.lock(); items.append(p); lock.unlock() }
    var all: [ScanProgress] { lock.lock(); defer { lock.unlock() }; return items }
}

// MARK: - SpaceMapper

final class SpaceMapperTests: FixtureTestCase {
    private func checkInvariants(_ node: DirectoryNode, file: StaticString = #filePath, line: UInt = #line) {
        if !node.children.isEmpty {
            XCTAssertEqual(node.children.reduce(0) { $0 + $1.size }, node.size, "children must sum to parent: \(node.url.path)", file: file, line: line)
            // "Прочее" (if any) is always last; the real children before it are sorted by size desc.
            let real = node.children.filter { !SpaceMapper.isOtherBucket($0, in: node) }.map(\.size)
            XCTAssertEqual(real, real.sorted(by: >), "sorted desc", file: file, line: line)
        }
        node.children.forEach { checkInvariants($0, file: file, line: line) }
    }

    func testSizesSumAndMatchFileSizer() async throws {
        try makeFile("a/one.bin", blocks: 100)
        try makeFile("a/b/two.bin", blocks: 80)
        try makeFile("a/b/c/three.bin", blocks: 60)
        try makeFile("d/four.bin", blocks: 50)
        try makeFile("top.bin", blocks: 40)
        try makeFile(".hidden/secret.bin", blocks: 30)

        let node = await SpaceMapper().map(root, depth: 5, progress: nil)
        XCTAssertEqual(node.size, FileSizer.allocatedSize(of: root))
        XCTAssertEqual(node.size, bytes(360))
        XCTAssertTrue(node.isDirectory)
        XCTAssertEqual(node.children.map(\.name), ["a", "d", "top.bin", ".hidden"])
        checkInvariants(node)
        let a = try XCTUnwrap(node.children.first)
        XCTAssertEqual(a.size, bytes(240))
        XCTAssertEqual(a.children.map(\.name), ["b", "one.bin"])
        XCTAssertEqual(a.children[0].children.map(\.name), ["two.bin", "c"])
    }

    func testDepthLimitKeepsFullSizes() async throws {
        try makeFile("a/b/c/d/deep.bin", blocks: 100)
        try makeFile("a/x.bin", blocks: 100)

        let node = await SpaceMapper().map(root, depth: 2, progress: nil)
        XCTAssertEqual(node.size, bytes(200))
        let a = try XCTUnwrap(node.children.first)                  // level 1
        XCTAssertEqual(a.name, "a")
        let b = try XCTUnwrap(a.children.first { $0.name == "b" })  // level 2 (last kept level)
        XCTAssertEqual(b.size, bytes(100), "size below the depth limit is still counted")
        XCTAssertTrue(b.children.isEmpty, "no children beyond depth")
        checkInvariants(node)

        let flat = await SpaceMapper().map(root, depth: 0, progress: nil)
        XCTAssertEqual(flat.size, bytes(200))
        XCTAssertTrue(flat.children.isEmpty)
    }

    func testSmallSiblingsAreAggregatedIntoOther() async throws {
        try makeFile("big.bin", blocks: 1000)
        for i in 0..<20 { try makeFile("tiny\(i).bin", blocks: 1) }   // 20 blocks = ~2 %, each ~0.1 %

        let node = await SpaceMapper().map(root, depth: 2, progress: nil)
        XCTAssertEqual(node.children.count, 2)
        XCTAssertEqual(node.children[0].name, "big.bin")
        let other = node.children[1]
        XCTAssertTrue(SpaceMapper.isOtherBucket(other, in: node))
        XCTAssertEqual(SpaceMapper.displayName(of: other, in: node), "Прочее")
        XCTAssertEqual(SpaceMapper.displayName(of: node.children[0], in: node), "big.bin")
        XCTAssertEqual(other.url, node.url)
        XCTAssertFalse(other.isDirectory)
        XCTAssertEqual(other.size, bytes(20))
        XCTAssertEqual(node.size, bytes(1020))
        checkInvariants(node)
    }

    func testChildrenAreCappedAt40() async throws {
        for i in 0..<60 { try makeFile("f\(i).bin", blocks: 10) }
        let node = await SpaceMapper().map(root, depth: 1, progress: nil)
        XCTAssertEqual(node.children.count, SpaceMapper.maxChildren + 1)
        XCTAssertTrue(SpaceMapper.isOtherBucket(try XCTUnwrap(node.children.last), in: node))
        XCTAssertEqual(node.children.last?.size, 20 * bytes(10))
        checkInvariants(node)
    }

    func testNoOtherNodeWhenNothingIsFolded() async throws {
        try makeFile("a.bin", blocks: 10)
        try makeFile("b.bin", blocks: 10)
        let node = await SpaceMapper().map(root, depth: 1, progress: nil)
        XCTAssertEqual(node.children.count, 2)
        XCTAssertFalse(node.children.contains { SpaceMapper.isOtherBucket($0, in: node) })
    }

    func testSymlinksAreNotFollowedAndUnreadableFoldersAreTolerated() async throws {
        try makeFile("real/x.bin", blocks: 100)
        let outside = fm.temporaryDirectory.appendingPathComponent("SpaceEngineOutside-\(UUID().uuidString)")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        try Data(count: 500 * Self.block).write(to: outside.appendingPathComponent("o.bin"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("dirlink"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("filelink"), withDestinationURL: outside.appendingPathComponent("o.bin"))
        try makeFile("locked/y.bin", blocks: 70)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.appendingPathComponent("locked").path)

        let node = await SpaceMapper().map(root, depth: 3, progress: nil)
        XCTAssertEqual(node.size, bytes(100), "symlinks ignored, locked folder contributes 0")
        XCTAssertFalse(node.children.contains { $0.name == "dirlink" || $0.name == "filelink" })
    }

    func testMapOfFileAndMissingPath() async throws {
        let f = try makeFile("single.bin", blocks: 7)
        let n = await SpaceMapper().map(f, depth: 3, progress: nil)
        XCTAssertEqual(n.size, bytes(7))
        XCTAssertFalse(n.isDirectory)
        let missing = await SpaceMapper().map(root.appendingPathComponent("nope"), depth: 3, progress: nil)
        XCTAssertEqual(missing.size, 0)
    }

    func testProgressEndsAtOne() async throws {
        for i in 0..<5 { try makeFile("d\(i)/f.bin", blocks: 5) }
        let log = PhaseLog()
        _ = await SpaceMapper().map(root, depth: 2) { log.add($0) }
        XCTAssertEqual(log.all.last?.fraction, 1)
    }
}

// MARK: - Safety-review regressions

final class HomeRootWalkTests: FixtureTestCase {
    private var home: URL { root.appendingPathComponent("home") }

    private func walkNames(root walkRoot: URL, home: URL) -> [String] {
        var found: [String] = []
        let o = FileWalker.Options(minAllocatedSize: bytes(10), includePackages: true, phase: "test", home: home)
        FileWalker.walk(root: walkRoot, options: o, monitor: WalkMonitor(totalUnits: 1, handler: nil)) {
            // The enumerator may report /private/var/… for /var/…, so cut at the fixture's "home/".
            let p = $0.url.path
            found.append(p.range(of: "/home/").map { String(p[$0.upperBound...]) } ?? p)
        }
        return found.sorted()
    }

    /// Finding 10: with the whole home as a root, ~/Documents, ~/Desktop… were skipped because
    /// `SafetyGuard.isProtected` ("do not remove this folder") was used as "do not enter".
    func testHomeAsRootDescendsIntoUserFoldersButNotProtectedAreas() throws {
        try makeFile("home/Documents/big-old-file.bin", blocks: 100, daysOld: 400)
        try makeFile("home/Desktop/sub/deep.bin", blocks: 100)
        try makeFile("home/Downloads/dl.bin", blocks: 100)
        try makeFile("home/Movies/m.bin", blocks: 100)
        try makeFile("home/Projects/p/src.bin", blocks: 100)
        // Protected areas and app data: never entered.
        try makeFile("home/Library/Keychains/login.keychain-db", blocks: 100)
        try makeFile("home/Library/Mail/V10/box.bin", blocks: 100)
        try makeFile("home/Library/Messages/chat.bin", blocks: 100)
        try makeFile("home/Library/Mobile Documents/com~apple~CloudDocs/icloud.bin", blocks: 100)
        try makeFile("home/Library/CloudStorage/Dropbox/d.bin", blocks: 100)
        try makeFile("home/Library/Application Support/AddressBook/ab.bin", blocks: 100)
        try makeFile("home/Library/Application Support/Other/o.bin", blocks: 100)
        try makeFile("home/Library/Containers/com.x/Data/c.bin", blocks: 100)

        XCTAssertEqual(walkNames(root: home, home: home), [
            "Desktop/sub/deep.bin", "Documents/big-old-file.bin", "Downloads/dl.bin", "Movies/m.bin", "Projects/p/src.bin",
        ])
    }

    func testOldFilesWithHomeRootFindsDocumentsFile() async throws {
        try makeFile("home/Documents/big-old-file.bin", blocks: 150, daysOld: 400)
        var o = options()
        o.roots = [home]
        let result = await FileAnalyzer().oldFiles(o, progress: nil)
        XCTAssertEqual(names(result), ["big-old-file.bin"])
        // Whatever the walk reports is never an exact protected folder.
        XCTAssertTrue(result.allSatisfy { !SafetyGuard.isProtected($0.item.url) })
    }

    func testExactFolderProtectionIsNotAreaProtection() {
        let h = SafetyGuard.home
        for name in ["Documents", "Desktop", "Downloads", "Movies", "Music", "Pictures"] {
            let folder = h.appendingPathComponent(name)
            XCTAssertTrue(SafetyGuard.isProtected(folder), "\(name) itself must not be removable")
            XCTAssertFalse(FileWalker.isInProtectedArea(folder), "\(name) must be walked")
            XCTAssertFalse(FileWalker.isInProtectedArea(folder.appendingPathComponent("sub/file.bin")))
        }
        for area in ["Library/Keychains", "Library/Mail/V10", "Library/Messages", "Library/Mobile Documents",
                     "Library/CloudStorage/Dropbox", "Library/Accounts", "Library/Calendars", "Library/Photos"] {
            XCTAssertTrue(FileWalker.isInProtectedArea(h.appendingPathComponent(area)), area)
        }
        XCTAssertTrue(FileWalker.isInProtectedArea(URL(fileURLWithPath: "/System/Library/CoreServices")))
        XCTAssertTrue(FileWalker.isInProtectedArea(URL(fileURLWithPath: "/usr/bin")))
        XCTAssertFalse(FileWalker.isInProtectedArea(URL(fileURLWithPath: "/usr/local/share")))
    }
}

final class DirectoryIdentityTests: FixtureTestCase {
    func testVisitedDirectoriesReportsRepeats() {
        let v = VisitedDirectories()
        let a = VisitedDirectories.Identity(device: 1, inode: 10)
        XCTAssertTrue(v.insert(a))
        XCTAssertFalse(v.insert(a), "same (device, inode) twice")
        XCTAssertTrue(v.insert(.init(device: 1, inode: 11)))
        XCTAssertTrue(v.insert(.init(device: 2, inode: 10)), "same inode on another device is a different directory")
    }

    func testTwoPathsToOneDirectoryShareIdentityAndCountOnce() throws {
        try makeFile("real/sub/x.bin", blocks: 3)
        // A symlinked parent gives a second path to the same directory (what a firmlink does at "/").
        try fm.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: root.appendingPathComponent("real"))
        let direct = try XCTUnwrap(VisitedDirectories.identity(of: root.appendingPathComponent("real/sub")))
        let viaAlias = try XCTUnwrap(VisitedDirectories.identity(of: root.appendingPathComponent("alias/sub")))
        XCTAssertEqual(direct, viaAlias)
        XCTAssertNotEqual(direct, VisitedDirectories.identity(of: root.appendingPathComponent("real")))

        let v = VisitedDirectories()
        XCTAssertTrue(v.firstVisit(of: root.appendingPathComponent("real/sub")))
        XCTAssertFalse(v.firstVisit(of: root.appendingPathComponent("alias/sub")))
        XCTAssertTrue(v.firstVisit(of: root.appendingPathComponent("does-not-exist")), "unknown identity is not a repeat")
    }

    func testMapperStillCountsEveryDistinctFolderOnce() async throws {
        for i in 0..<6 { try makeFile("d\(i)/sub/f.bin", blocks: 5) }
        let node = await SpaceMapper().map(root, depth: 3, progress: nil)
        XCTAssertEqual(node.size, bytes(30))
    }

    func testFirmlinkMirrorIsSkippedOnlyWhenMappingRoot() {
        let mirror = URL(fileURLWithPath: "/System/Volumes")
        XCTAssertTrue(isFirmlinkMirror(mirror, scanRoot: URL(fileURLWithPath: "/")))
        XCTAssertFalse(isFirmlinkMirror(mirror, scanRoot: URL(fileURLWithPath: "/System")))
        XCTAssertFalse(isFirmlinkMirror(root.appendingPathComponent("System/Volumes"), scanRoot: URL(fileURLWithPath: "/")))
    }

    func testRealFirmlinkedDataVolumeHasSameIdentity() throws {
        let a = VisitedDirectories.identity(of: URL(fileURLWithPath: "/Users"))
        let b = VisitedDirectories.identity(of: URL(fileURLWithPath: "/System/Volumes/Data/Users"))
        try XCTSkipUnless(a != nil && b != nil, "no firmlinked data volume here")
        XCTAssertEqual(a, b, "/Users and /System/Volumes/Data/Users are one directory")
        let v = VisitedDirectories()
        XCTAssertTrue(v.firstVisit(of: URL(fileURLWithPath: "/Users")))
        XCTAssertFalse(v.firstVisit(of: URL(fileURLWithPath: "/System/Volumes/Data/Users")))
    }
}

// MARK: - Real disk (read-only, opt-in)

final class RealDiskTests: XCTestCase {
    func testRealDiskReport() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPACEENGINE_REALDISK"] == "1", "set SPACEENGINE_REALDISK=1")
        let fmt = { (b: Int64) in ByteFormat.string(b) }

        // Old files
        var o = OldFilesOptions.default   // 10 MB, 180 days, default roots
        o.minSize = 10 * 1024 * 1024
        let t0 = Date()
        let old = await FileAnalyzer().oldFiles(o, progress: nil)
        let dt = Date().timeIntervalSince(t0)
        print("REALDISK old files >=10MB, unused >=180d: count=\(old.count) total=\(fmt(old.reduce(0) { $0 + $1.item.size })) time=\(String(format: "%.2f", dt))s")
        for f in old.prefix(5) {
            let d = f.item.lastUsed.map { ISO8601DateFormatter().string(from: $0) } ?? "-"
            print("REALDISK   \(fmt(f.item.size))  \(f.kind.title)  last=\(d)  \(f.item.url.path)")
        }
        let byKind = Dictionary(grouping: old, by: \.kind).mapValues { $0.reduce(0) { $0 + $1.item.size } }
        print("REALDISK   by kind: " + byKind.sorted { $0.value > $1.value }.map { "\($0.key.title)=\(fmt($0.value))" }.joined(separator: ", "))

        // Space map
        let home = SafetyGuard.home
        let t1 = Date()
        // Optional trace of the current path (helps to find folders that block, e.g. offline mounts).
        let tracePath = ProcessInfo.processInfo.environment["SPACEENGINE_TRACE"]
        let node = await SpaceMapper().map(home, depth: 3) { p in
            if let tracePath, let path = p.currentPath { try? path.write(toFile: tracePath, atomically: false, encoding: .utf8) }
        }
        let dt1 = Date().timeIntervalSince(t1)
        print("REALDISK space map of \(home.path) depth=3: total=\(fmt(node.size)) time=\(String(format: "%.2f", dt1))s")
        for c in node.children {
            print("REALDISK   \(fmt(c.size))  \(SpaceMapper.displayName(of: c, in: node))  (children: \(c.children.count))")
        }
    }
}
