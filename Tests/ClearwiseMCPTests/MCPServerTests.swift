import XCTest
import CleanerKit
import JunkEngine
@testable import ClearwiseMCPCore

final class MCPServerTests: XCTestCase {
    private func server(_ tools: [MCPTool] = []) -> MCPServer {
        MCPServer(name: "test", version: "0", instructions: "hi", tools: tools)
    }

    private func json(_ line: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(line).data(using: .utf8)!
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testInitializeAnswersWithToolsCapabilityAndASupportedVersion() async throws {
        let reply = try json(await server().handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#))
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "test")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual(reply["id"] as? Int, 1)
        let unknown = try json(await server().handle(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        XCTAssertEqual(((unknown["result"] as? [String: Any])?["protocolVersion"]) as? String, MCPServer.protocolVersion)
    }

    func testNotificationsAndResponsesGetNoReplyAndGarbageGetsAParseError() async throws {
        let s = server()
        let none = await s.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(none)
        let blank = await s.handle("   ")
        XCTAssertNil(blank)
        let response = await s.handle(#"{"jsonrpc":"2.0","id":5,"result":{}}"#)
        XCTAssertNil(response, "a response to a request we never sent")
        let bad = try json(await s.handle("{not json"))
        XCTAssertEqual((bad["error"] as? [String: Any])?["code"] as? Int, -32700)
    }

    func testUnknownMethodAndUnknownTool() async throws {
        let s = server()
        let method = try json(await s.handle(#"{"jsonrpc":"2.0","id":"a","method":"resources/list"}"#))
        XCTAssertEqual((method["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual(method["id"] as? String, "a")
        let tool = try json(await s.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nope"}}"#))
        XCTAssertEqual((tool["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testToolsListAndCallCarryTheToolOutput() async throws {
        let echo = MCPTool(name: "echo", description: "says it back", inputSchema: JSON.schema(["text": ["type": "string"]])) { args in
            ToolOutput(text: "you said \(args["text"] as? String ?? "")")
        }
        let failing = MCPTool(name: "boom", description: "fails", inputSchema: JSON.schema([:])) { _ in
            ToolOutput(text: "no", isError: true)
        }
        let s = server([echo, failing])
        let list = try json(await s.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["echo", "boom"])
        XCTAssertEqual((tools[0]["inputSchema"] as? [String: Any])?["type"] as? String, "object")

        let call = try json(await s.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#))
        let result = try XCTUnwrap(call["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "you said hi")
        XCTAssertEqual(result["isError"] as? Bool, false)
        let ping = await s.handle(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        XCTAssertFalse(try XCTUnwrap(ping).contains("\n"), "one line per message")

        let failed = try json(await s.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"boom"}}"#))
        XCTAssertEqual(((failed["result"] as? [String: Any])?["isError"]) as? Bool, true)
    }
}

final class CleanerToolsTests: XCTestCase {
    private func item(_ path: String, _ size: Int64 = 10) -> FileItem {
        FileItem(url: URL(fileURLWithPath: path), size: size, isDirectory: false)
    }

    func testEveryToolHasAnObjectSchemaAndTheRemovingOnesTakeConfirm() {
        let tools = CleanerTools.all()
        XCTAssertEqual(Set(tools.map(\.name)), ["scan_junk", "clean_junk", "disk_usage", "list_apps", "app_footprint",
                                                "uninstall_app", "find_leftovers", "remove_leftovers", "old_files",
                                                "large_files", "duplicates", "trash_files", "mac_health",
                                                "startup_items", "set_startup_item", "empty_trash"])
        for tool in tools {
            XCTAssertEqual(tool.inputSchema["type"] as? String, "object", tool.name)
            let properties = tool.inputSchema["properties"] as? [String: Any] ?? [:]
            let removes = tool.description.contains("DRY RUN")
            XCTAssertEqual(properties["confirm"] != nil, removes, "\(tool.name): removing tools take confirm, the rest do not")
        }
    }

    func testSelectionByPathCategoryAndModeRespectsNeverAuto() {
        let home = NSHomeDirectory()
        let a = item("\(home)/Library/Caches/a"), b = item("\(home)/Library/Caches/b")
        let newest = item("\(home)/Backup/new"), older = item("\(home)/Backup/old")
        let docker = FileItem(url: DockerCleanup.Kind.buildCache.url, size: 5, isDirectory: false)
        let caches = JunkCategory(id: "user-caches", title: "", detail: "", symbol: "", risk: .safe, items: [a, b])
        let backups = JunkCategory(id: "ios-backups", title: "", detail: "", symbol: "", risk: .caution,
                                   itemModes: [newest.url: .maximum, older.url: .maximum], neverAuto: [newest.url], items: [newest, older])
        let dockerCat = JunkCategory(id: "docker", title: "", detail: "", symbol: "", risk: .review,
                                     itemModes: [docker.url: .enhanced], items: [docker])
        let all = [caches, backups, dockerCat]

        let byPath = CleanerTools.select(from: all, paths: ["~/Library/Caches/A", "/nowhere", "docker-cleanup:///build-cache"], categoryIDs: [], mode: nil)
        XCTAssertEqual(byPath.picks.map { $0.category.id }, ["user-caches", "docker"])
        XCTAssertEqual(byPath.picks[0].items, [a], "paths match case-insensitively and with ~")
        XCTAssertEqual(byPath.unknown, ["/nowhere"])

        let byCategory = CleanerTools.select(from: all, paths: [], categoryIDs: ["ios-backups"], mode: nil)
        XCTAssertEqual(byCategory.picks.map { $0.items }, [[older]], "a whole category still skips the newest backup")
        let explicit = CleanerTools.select(from: all, paths: [newest.url.path], categoryIDs: ["ios-backups"], mode: nil)
        XCTAssertEqual(explicit.picks[0].items, [newest, older], "named by path, the newest backup is included")

        XCTAssertEqual(CleanerTools.select(from: all, paths: [], categoryIDs: [], mode: .gentle).picks.map { $0.category.id }, ["user-caches"])
        XCTAssertEqual(CleanerTools.select(from: all, paths: [], categoryIDs: [], mode: .enhanced).picks.map { $0.category.id }, ["user-caches", "docker"])
        let maximum = CleanerTools.select(from: all, paths: [], categoryIDs: [], mode: .maximum)
        XCTAssertEqual(maximum.picks.map { $0.category.id }, ["user-caches", "ios-backups", "docker"])
        XCTAssertEqual(maximum.picks[1].items, [older])
        XCTAssertEqual(CleanerTools.destination(for: backups), "trash")
        XCTAssertEqual(CleanerTools.destination(for: dockerCat), "docker")
        XCTAssertEqual(CleanerTools.destination(for: JunkCategory(id: "trash", title: "", detail: "", symbol: "", risk: .review, items: [])), "permanent")
    }

    func testCleanJunkIsADryRunWithoutConfirmAndTouchesNothing() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("cache.bin")
        try Data(repeating: 1, count: 2048).write(to: file)
        let state = CleanerState()
        await state.preload(junk: [JunkCategory(id: "user-caches", title: "Кэш", detail: "", symbol: "", risk: .safe,
                                                items: [FileItem(url: file, size: 2048, isDirectory: false)])])
        let tool = try XCTUnwrap(CleanerTools.all(state: state).first { $0.name == "clean_junk" })

        let dry = try await tool.run(["items": [file.path]])
        XCTAssertFalse(dry.isError)
        XCTAssertTrue(dry.text.contains("\"dry_run\" : true"))
        XCTAssertTrue(dry.text.contains("\"destination\" : \"trash\""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        do {
            _ = try await tool.run([:])
            XCTFail("needs mode, categories or items")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, -32602)
        }
    }
}
