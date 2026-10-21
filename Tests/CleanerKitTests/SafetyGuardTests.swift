import XCTest
@testable import CleanerKit

final class SafetyGuardTests: XCTestCase {
    private let home = SafetyGuard.home

    private func blocked(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(SafetyGuard.isProtected(URL(fileURLWithPath: path)), "should be protected: \(path)", file: file, line: line)
    }

    private func allowed(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(SafetyGuard.isProtected(URL(fileURLWithPath: path)), "should be allowed: \(path)", file: file, line: line)
    }

    func testSensitiveFoldersThemselvesAreProtected() {
        for sub in ["Library/Keychains", "Library/Mail", "Library/Messages", "Library/Photos", "Library/Safari",
                    "Library/Application Support/com.apple.TCC", "Library/Application Support/AddressBook",
                    "Library/Mobile Documents", "Library/CloudStorage"] {
            blocked(home.path + "/" + sub)
            blocked(home.path + "/" + sub + "/")
            blocked(home.path + "/" + sub + "/inner/file")
        }
    }

    func testCaseInsensitiveBypassIsBlocked() {
        blocked(home.path + "/documents")
        blocked(home.path + "/library")
        blocked(home.path + "/LIBRARY/Keychains")
        blocked("/Applications/safari.app")
        blocked("/system/library/foo")
    }

    func testPrivatePathsBothSpellings() {
        blocked("/private/etc/sudoers")
        blocked("/etc/sudoers")
        blocked("/var/vm/sleepimage")
        blocked("/private/var/db/receipts")
        blocked("/var/db/receipts")
        allowed("/private/var/db/receipts/com.vendor.app.bom")
    }

    func testAppleDataAndMediaLibraries() {
        blocked(home.path + "/Library/Group Containers/group.com.apple.notes")
        blocked(home.path + "/Library/Group Containers/2BUA8C4S2C.com.apple.iwork")
        blocked(home.path + "/Pictures/Photos Library.photoslibrary")
        blocked(home.path + "/Music/Music/Music Library.musiclibrary/x")
        allowed(home.path + "/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram")
    }

    func testOrdinaryJunkIsAllowed() {
        allowed(home.path + "/Library/Caches/com.google.Chrome")
        allowed(home.path + "/Library/Application Support/MobileSync/Backup/00008110-ABC")
        blocked(home.path + "/Library/Application Support/MobileSync/Backup")
        allowed("/Applications/Telegram.app")
        allowed("/Library/LaunchDaemons/com.vendor.helper.plist")
        blocked("/Library/LaunchDaemons")
        blocked(home.path)
        blocked("/Users")
    }

    func testTrashCheckResolvesSymlinks() throws {
        let trash = home.appendingPathComponent(".Trash")
        XCTAssertTrue(SafetyGuard.isInsideTrash(trash.appendingPathComponent("old.dmg")))
        XCTAssertFalse(SafetyGuard.isInsideTrash(trash))
        XCTAssertFalse(SafetyGuard.isInsideTrash(home.appendingPathComponent("Documents/x")))

        // A symlink planted in a temp "trash-like" dir must be resolved before deciding.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let link = tmp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home)
        XCTAssertFalse(SafetyGuard.isInsideTrash(link.appendingPathComponent("Documents")))
    }

    func testDedupeNestedKeepsOrderAndIsFast() {
        let urls = ["/a/b/c", "/a/bc", "/a/b", "/x/y"].map { URL(fileURLWithPath: $0) }
        XCTAssertEqual(FileRemover.dedupeNested(urls).map(\.path), ["/a/bc", "/a/b", "/x/y"])

        let many = (0..<20_000).map { URL(fileURLWithPath: "/tmp/root/dir\($0 % 500)/file\($0)") }
            + (0..<500).map { URL(fileURLWithPath: "/tmp/root/dir\($0)") }
        let start = Date()
        XCTAssertEqual(FileRemover.dedupeNested(many).count, 500)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testPermanentDeleteRefusesOutsideTrash() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: file)
        let result = await FileRemover.deletePermanentlyFromTrash([file])
        XCTAssertEqual(result.removed.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRemovalReportsProgressForEveryItem() async throws {
        final class Box: @unchecked Sendable { var steps: [RemovalStep] = []; let lock = NSLock() }
        let box = Box()
        let urls = [URL(fileURLWithPath: "/tmp/not-in-trash-a"), URL(fileURLWithPath: "/tmp/not-in-trash-b")]
        _ = await FileRemover.deletePermanentlyFromTrash(urls) { step in
            box.lock.lock(); box.steps.append(step); box.lock.unlock()
        }
        XCTAssertEqual(box.steps.map(\.done), [false, true, false, true])
        XCTAssertEqual(box.steps.filter(\.done).map(\.bytes), [0, 0])
    }
}
