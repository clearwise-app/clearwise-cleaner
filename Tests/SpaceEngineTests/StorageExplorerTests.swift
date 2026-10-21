import XCTest
import CleanerKit
@testable import SpaceEngine

final class StorageExplorerTests: FixtureTestCase {
    private func makeRoots() throws -> StorageRoots {
        try makeFile("Applications/Big.app/Contents/MacOS/Big", blocks: 30)
        try makeFile("Applications/Small.app/Contents/Info.plist", blocks: 2)
        try makeFile("home/Documents/report.pdf", blocks: 5)
        try makeFile("home/Downloads/setup.dmg", blocks: 7)
        try makeFile("home/Library/Developer/Xcode/x.o", blocks: 19)
        try makeFile("home/Library/Mobile Documents/doc.pages", blocks: 23)
        try makeFile("home/Library/Caches/com.app/cache.db", blocks: 29)
        try makeFile("home/Library/Application Support/App/data", blocks: 6)
        try makeFile("home/Library/Containers/com.other/Data/secret", blocks: 31)
        try makeFile("home/Library/loose.plist", blocks: 1)
        let home = root.appendingPathComponent("home")
        return StorageRoots(home: home, applications: [root.appendingPathComponent("Applications")],
                            systemDeveloper: [], volume: root)
    }

    private func names(_ urls: [URL]) -> Set<String> { Set(urls.map(\.lastPathComponent)) }

    func testAppDataOpensLibraryWithoutOtherCategoriesAndContainers() throws {
        let explorer = StorageExplorer(roots: try makeRoots(), fullDiskAccess: false)
        XCTAssertEqual(names(explorer.topLevel(of: .appData)), ["Caches", "Application Support", "loose.plist"])
    }

    func testContainersListedWithFullDiskAccess() throws {
        let explorer = StorageExplorer(roots: try makeRoots(), fullDiskAccess: true)
        XCTAssertTrue(names(explorer.topLevel(of: .appData)).contains("Containers"))
    }

    func testAppsAreListedOneByOneAndAreNotOpenable() async throws {
        let explorer = StorageExplorer(roots: try makeRoots(), fullDiskAccess: true)
        let entries = await explorer.measure(explorer.topLevel(of: .apps))
        XCTAssertEqual(entries.map(\.url.lastPathComponent), ["Big.app", "Small.app"], "biggest first")
        XCTAssertEqual(entries.first?.bytes, bytes(30))
        XCTAssertFalse(entries.contains { $0.isFolder }, "app bundles are packages, not folders to open")
    }

    func testCategoryWithSeveralFoldersListsTheFolders() async throws {
        let explorer = StorageExplorer(roots: try makeRoots(), fullDiskAccess: true)
        let entries = await explorer.measure(explorer.topLevel(of: .documents))
        // Desktop does not exist; empty or missing folders are dropped.
        XCTAssertEqual(entries.map(\.url.lastPathComponent), ["Downloads", "Documents"])
        XCTAssertTrue(entries.allSatisfy(\.isFolder))
        let inside = await explorer.measure(explorer.children(of: entries[0].url))
        XCTAssertEqual(inside.map(\.url.lastPathComponent), ["setup.dmg"])
        XCTAssertEqual(inside.first?.bytes, bytes(7))
    }

    func testUncountedHomeItemsAreHiddenFoldersAndLooseFiles() throws {
        let roots = try makeRoots()
        try makeFile("home/.claude/projects/a.jsonl", blocks: 3)
        try makeFile("home/.zsh_history", blocks: 1)
        try makeFile("home/.npm/_cacache/x", blocks: 2)     // «Разработка»
        try makeFile("home/.Trash/old.zip", blocks: 2)      // «Корзина»
        try makeFile("home/Projects/app/main.swift")        // visible folder: «Документы»
        try makeFile("home/notes.txt")                      // loose file: counted nowhere else
        let items = StorageExplorer(roots: roots, fullDiskAccess: true).uncountedHomeItems()
        XCTAssertEqual(names(items), [".claude", ".zsh_history", "notes.txt"])
    }

    func testVolumeSpaceUsedReadsTheStartupVolume() {
        XCTAssertGreaterThan(StorageExplorer.volumeSpaceUsed("/") ?? 0, 0)
        XCTAssertNil(StorageExplorer.volumeSpaceUsed("/definitely/not/here"))
    }

    func testSystemHasNoFolders() throws {
        XCTAssertTrue(StorageExplorer(roots: try makeRoots(), fullDiskAccess: true).topLevel(of: .system).isEmpty)
    }
}
