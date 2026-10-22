import XCTest
import CleanerKit
@testable import JunkEngine

/// Docker is never touched as files: sizes come from `docker system df`, removal from `docker … prune`.
/// A fake `docker` records what would run; nothing here needs Docker on the Mac.
final class DockerTests: XCTestCase {
    private final class Fake: @unchecked Sendable {
        var calls: [[String]] = []
        var answers: [String: DockerTool.Output?] = [:]
        let lock = NSLock()
        var tool: DockerTool {
            DockerTool(path: "/fake/docker") { args, _ in
                self.lock.lock(); defer { self.lock.unlock() }
                self.calls.append(args)
                return self.answers[args.joined(separator: " ")] ?? DockerTool.Output(status: 0, text: "")
            }
        }
    }

    private let df = """
    {"Type":"Images","TotalCount":"12","Active":"3","Size":"8.5GB","Reclaimable":"2.5GB (29%)"}
    {"Type":"Containers","TotalCount":"4","Active":"1","Size":"300MB","Reclaimable":"100MB (33%)"}
    {"Type":"Local Volumes","TotalCount":"6","Active":"2","Size":"9GB","Reclaimable":"7GB (77%)"}
    {"Type":"Build Cache","TotalCount":"40","Active":"0","Size":"1.2GB","Reclaimable":"1.2GB"}
    """
    private let dangling = """
    {"Repository":"<none>","Tag":"<none>","Size":"300MB"}
    {"Repository":"<none>","Tag":"<none>","Size":"200MB"}
    """

    func testSizesAreDecimalAsDockerPrintsThem() {
        XCTAssertEqual(DockerCleanup.parseSize("1.234GB (45%)"), 1_234_000_000)
        XCTAssertEqual(DockerCleanup.parseSize("512MB"), 512_000_000)
        XCTAssertEqual(DockerCleanup.parseSize("12.5kB"), 12_500)
        XCTAssertEqual(DockerCleanup.parseSize("0B"), 0)
        XCTAssertNil(DockerCleanup.parseSize("n/a"))
        XCTAssertEqual(DockerCleanup.parseReclaimed("Deleted Images:\nuntagged: x\n\nTotal reclaimed space: 1.5GB\n"), 1_500_000_000)
        XCTAssertNil(DockerCleanup.parseReclaimed("Error response from daemon"))
    }

    func testSystemDFSkipsVolumes() throws {
        let usage = try XCTUnwrap(DockerCleanup.parseSystemDF(df))
        XCTAssertEqual(usage, .init(images: 2_500_000_000, dangling: 0, containers: 100_000_000, buildCache: 1_200_000_000))
        XCTAssertNil(DockerCleanup.parseSystemDF("Cannot connect to the Docker daemon"))
        XCTAssertEqual(DockerCleanup.parseDangling(dangling), 500_000_000)
    }

    func testScanSplitsImagesIntoDanglingAndUnusedAndSetsModes() throws {
        let fake = Fake()
        fake.answers["system df --format {{json .}}"] = DockerTool.Output(status: 0, text: df)
        fake.answers["images --filter dangling=true --format {{json .}}"] = DockerTool.Output(status: 0, text: dangling)
        let (category, status) = DockerCleanup.scan(fake.tool)
        XCTAssertEqual(status, .ready)
        let cat = try XCTUnwrap(category)
        XCTAssertEqual(cat.id, JunkCategoryID.docker)
        XCTAssertEqual(cat.risk, .review)
        let sizes = Dictionary(uniqueKeysWithValues: cat.items.map { (DockerCleanup.Kind(url: $0.url)!, $0.size) })
        XCTAssertEqual(sizes, [.unusedImages: 2_000_000_000, .danglingImages: 500_000_000,
                               .buildCache: 1_200_000_000, .stoppedContainers: 100_000_000])
        XCTAssertFalse(cat.isSelectedByDefault, "the gentle mode never touches Docker")
        XCTAssertEqual(Set(cat.autoSelected(in: .enhanced).map { DockerCleanup.Kind(url: $0.url)! }), [.buildCache, .danglingImages])
        XCTAssertEqual(cat.autoSelected(in: .maximum).count, 4)
        XCTAssertTrue(cat.autoSelected(in: .gentle).isEmpty)
    }

    func testEngineNotAnsweringMeansNotRunningNotEmpty() {
        let fake = Fake()
        fake.answers["system df --format {{json .}}"] = .some(nil)
        let (category, status) = DockerCleanup.scan(fake.tool)
        XCTAssertNil(category)
        XCTAssertEqual(status, .notRunning)
    }

    func testCleanRunsOnePruneCommandPerKindContainersFirstAndNeverVolumes() {
        let fake = Fake()
        for kind in DockerCleanup.Kind.allCases {
            fake.answers[kind.arguments.joined(separator: " ")] = DockerTool.Output(status: 0, text: "Total reclaimed space: 100MB")
        }
        let urls = [DockerCleanup.Kind.unusedImages.url, DockerCleanup.Kind.stoppedContainers.url,
                    URL(fileURLWithPath: "/tmp/not-docker"), URL(string: "docker-cleanup:///volumes")!]
        let result = DockerCleanup.clean(urls, tool: fake.tool)
        XCTAssertEqual(fake.calls, [["container", "prune", "--force"], ["image", "prune", "--all", "--force"]])
        XCTAssertEqual(Set(result.removed), [DockerCleanup.Kind.stoppedContainers.url, DockerCleanup.Kind.unusedImages.url])
        XCTAssertEqual(result.failed.count, 2, "a file and an unknown kind are refused, not passed to docker")
        XCTAssertEqual(result.freedBytes, 200_000_000)
        XCTAssertEqual(result.freedForGood, 200_000_000)
        XCTAssertEqual(result.deletedForGood.count, 2)
        XCTAssertTrue(fake.calls.allSatisfy { !$0.contains("volume") })
    }

    func testCleanWithoutDockerOrWithAFailingEngineFailsSoftly() {
        let none = DockerCleanup.clean([DockerCleanup.Kind.buildCache.url], tool: nil)
        XCTAssertEqual(none.failed.map(\.reason), [DockerCleanup.notFoundReason])
        let fake = Fake()
        fake.answers["builder prune --force"] = DockerTool.Output(status: 1, text: "")
        let failed = DockerCleanup.clean([DockerCleanup.Kind.buildCache.url], tool: fake.tool)
        XCTAssertTrue(failed.removed.isEmpty)
        XCTAssertEqual(failed.failed.count, 1)
    }

    func testJunkCleanerRoutesTheDockerCategoryToDockerAndRefusesForeignItems() async {
        let fake = Fake()
        fake.answers["builder prune --force"] = DockerTool.Output(status: 0, text: "Total reclaimed space: 1GB")
        let item = FileItem(url: DockerCleanup.Kind.buildCache.url, size: 1_000_000_000, isDirectory: false)
        let category = JunkCategory(id: JunkCategoryID.docker, title: "Docker", detail: "", symbol: "x", risk: .review, items: [item])
        let foreign = FileItem(url: URL(fileURLWithPath: "/tmp/keep"), size: 1, isDirectory: false)
        let result = await JunkCleaner.clean([item, foreign], in: category, docker: { fake.tool })
        XCTAssertEqual(result.removed, [item.url])
        XCTAssertEqual(result.failed.map(\.url), [foreign.url])
        XCTAssertEqual(fake.calls, [["builder", "prune", "--force"]])
    }
}

/// What each cleanup mode ticks, on a hand-built category.
final class CleanupModeTests: XCTestCase {
    func testModesNestAndNeverAutoWins() {
        let a = FileItem(url: URL(fileURLWithPath: "/a"), size: 1, isDirectory: false)
        let b = FileItem(url: URL(fileURLWithPath: "/b"), size: 1, isDirectory: false)
        let c = FileItem(url: URL(fileURLWithPath: "/c"), size: 1, isDirectory: false)
        let cat = JunkCategory(id: "x", title: "x", detail: "", symbol: "x", risk: .review, mode: .enhanced,
                               itemModes: [b.url: .maximum], neverAuto: [c.url], items: [a, b, c])
        XCTAssertEqual(cat.autoSelected(in: .gentle).map(\.url), [])
        XCTAssertEqual(cat.autoSelected(in: .enhanced).map(\.url), [a.url])
        XCTAssertEqual(cat.autoSelected(in: .maximum).map(\.url), [a.url, b.url])
        XCTAssertEqual(cat.gentlestMode, .enhanced)
        XCTAssertFalse(cat.isSelectedByDefault)
        XCTAssertTrue(JunkCategory(id: "s", title: "", detail: "", symbol: "", risk: .safe, items: [a]).isSelectedByDefault)
        XCTAssertNil(JunkCategory(id: "t", title: "", detail: "", symbol: "", risk: .review, items: [a]).gentlestMode)
        XCTAssertTrue(CleanupMode.gentle < .enhanced && CleanupMode.enhanced < .maximum)
    }
}
