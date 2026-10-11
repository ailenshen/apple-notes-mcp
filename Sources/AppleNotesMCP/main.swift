import Foundation
import MCPCore

// Spike stage (gates G0–G2): only `spike_*` tools, removed once the gates pass.

struct SpikeEcho: Tool {
    let name = "spike_echo"
    let description = "Echo the given text back. Spike tool for protocol testing."
    let inputSchema: JSONValue = [
        "type": "object",
        "properties": ["text": ["type": "string"]],
        "required": ["text"],
        "additionalProperties": false,
    ]

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let text = arguments["text"]?.stringValue else { throw MCPError.invalidParams("text must be a string") }
        return ToolResult(text)
    }
}

let server = Server(
    info: ServerInfo(name: "apple-notes-mcp", version: "2.0.0-dev"),
    tools: [SpikeEcho()])
await StdioTransport.run(server)
