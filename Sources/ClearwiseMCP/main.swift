import Foundation
import ClearwiseMCPCore

// clearwise-mcp: the Model Context Protocol server of Clearwise Cleaner, over stdio.
// Connect it to Claude Code, Claude Desktop, Cursor or any other MCP client; see skills/clearwise-cleaner/SKILL.md.

let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    clearwise-mcp \(serverVersion) — MCP server (stdio) for Clearwise Cleaner.

    Usage: clearwise-mcp            run the server (JSON-RPC over stdin/stdout)
           clearwise-mcp --tools    list the tools and exit

    Claude Code:   claude mcp add clearwise -- "\(CommandLine.arguments[0])"
    Full Disk Access is the host's (Terminal, Claude, Cursor): grant it there to see every cache.
    """)
    exit(0)
}
let server = MCPServer(name: "clearwise-cleaner", version: serverVersion,
                       instructions: CleanerTools.instructions, tools: CleanerTools.all())
if arguments.contains("--tools") {
    for tool in server.tools { print("\(tool.name)\t\(tool.description.split(separator: "\n").first ?? "")") }
    exit(0)
}

// stdout carries the protocol only; anything else goes to stderr.
setvbuf(stdout, nil, _IOLBF, 0)
let out = FileHandle.standardOutput
final class Reply: @unchecked Sendable { var text: String? }
while let line = readLine(strippingNewline: true) {
    let reply = Reply()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        reply.text = await server.handle(line)
        done.signal()
    }
    done.wait()
    if let text = reply.text {
        out.write(Data((text + "\n").utf8))
    }
}
