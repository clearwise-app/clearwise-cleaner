import Foundation

/// The version an MCP client sees; kept with the app's.
public let serverVersion = "1.2.0"

/// A tool an MCP client can list and call. `inputSchema` is JSON Schema; `run` returns the text the
/// client shows the model (JSON, in this server) and whether it is an error.
public struct MCPTool: @unchecked Sendable {
    public let name: String
    public let description: String
    public let inputSchema: [String: Any]
    public let run: @Sendable ([String: Any]) async throws -> ToolOutput

    public init(name: String, description: String, inputSchema: [String: Any],
                run: @escaping @Sendable ([String: Any]) async throws -> ToolOutput) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.run = run
    }
}

public struct ToolOutput: Sendable, Equatable {
    public var text: String
    public var isError: Bool
    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// A JSON-RPC error the client gets instead of a result.
public struct RPCError: Error, Equatable {
    public let code: Int
    public let message: String
    public init(_ code: Int, _ message: String) {
        self.code = code
        self.message = message
    }
    public static func invalidParams(_ message: String) -> RPCError { RPCError(-32602, message) }
}

/// Model Context Protocol over newline-delimited JSON-RPC 2.0 (the stdio transport): one line in, zero or one
/// line out. Requests get a response; notifications (no id) none. Only `tools` is offered.
public struct MCPServer: @unchecked Sendable {
    public static let protocolVersion = "2025-06-18"
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public let name: String
    public let version: String
    public let instructions: String
    public let tools: [MCPTool]

    public init(name: String, version: String, instructions: String, tools: [MCPTool]) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
    }

    public func handle(_ line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        // A response to something we never sent, or a notification: nothing to answer.
        guard let method = message["method"] as? String else { return nil }
        guard let id = message["id"], !(id is NSNull) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        do {
            let result = try await dispatch(method, params)
            return encode(["jsonrpc": "2.0", "id": id, "result": result])
        } catch let error as RPCError {
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
        } catch {
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": "\(error)"]])
        }
    }

    func dispatch(_ method: String, _ params: [String: Any]) async throws -> Any {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? Self.protocolVersion
            return [
                "protocolVersion": Self.supportedVersions.contains(asked) ? asked : Self.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": name, "version": version],
                "instructions": instructions,
            ]
        case "ping":
            return [String: Any]()
        case "tools/list":
            return ["tools": tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema] }]
        case "tools/call":
            guard let toolName = params["name"] as? String else { throw RPCError.invalidParams("name is required") }
            guard let tool = tools.first(where: { $0.name == toolName }) else {
                throw RPCError.invalidParams("Unknown tool: \(toolName)")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let output: ToolOutput
            do {
                output = try await tool.run(arguments)
            } catch let error as RPCError {
                throw error
            } catch {
                output = ToolOutput(text: "\(error)", isError: true)
            }
            return ["content": [["type": "text", "text": output.text]], "isError": output.isError]
        default:
            throw RPCError(-32601, "Method not found: \(method)")
        }
    }

    private func encode(_ object: [String: Any]) -> String {
        // One line per message: no pretty printing here (strings keep their newlines escaped).
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Could not encode the response"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Small helpers for tool arguments and output

enum Args {
    static func string(_ args: [String: Any], _ key: String) -> String? {
        (args[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    /// JSON `true` only. A string "true" or a number is a client slip, and for `confirm` a slip must not remove files.
    static func bool(_ args: [String: Any], _ key: String) -> Bool {
        guard let n = args[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return false }
        return n.boolValue
    }
    /// Clamped to 0…10 000 000: months and megabytes are multiplied later, and a huge value must not trap.
    static func int(_ args: [String: Any], _ key: String, default value: Int) -> Int {
        let n: Int
        if let number = args[key] as? NSNumber { n = number.intValue }
        else if let s = args[key] as? String, let parsed = Int(s) { n = parsed }
        else { return value }
        return min(max(n, 0), 10_000_000)
    }
    static func strings(_ args: [String: Any], _ key: String) -> [String] {
        if let list = args[key] as? [String] { return list }
        if let one = args[key] as? String { return [one] }
        return []
    }
}

enum JSON {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ d: Date?) -> Any { d.map { iso.string(from: $0) } ?? NSNull() }

    /// Pretty JSON for the model to read; `nil` optionals become `null`.
    static func text(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 1 234 567 → "1,2 МБ"-style text the model can quote; decimal units like Finder.
    static func human(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: bytes)
    }

    static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var s: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { s["required"] = required }
        return s
    }
}
