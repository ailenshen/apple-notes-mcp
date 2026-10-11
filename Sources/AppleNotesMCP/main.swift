import Foundation
import MCPCore
import NotesKit

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

struct SpikePeek: Tool {
    let repository: NotesRepository
    let name = "spike_peek"
    let description = "Return a note's title, folder, modification date and first line by id. Spike tool."
    let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "id": ["type": "string"],
            "provoke_objc_exception": ["type": "boolean"],
        ],
        "required": ["id"],
        "additionalProperties": false,
    ]

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let id = arguments["id"]?.stringValue else { throw MCPError.invalidParams("id must be a string") }
        do {
            if arguments["provoke_objc_exception"] == true { try await repository.provokeObjCException() }
            let note = try await repository.note(id: id)
            let firstLine = note.text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().first ?? ""
            return ToolResult("\(note.title) | \(note.folder) | \(note.modified.ISO8601Format()) | \(firstLine)")
        } catch {
            return ToolResult(error.description, isError: true)
        }
    }
}

let repository = NotesRepository()
let server = Server(
    info: ServerInfo(name: "apple-notes-mcp", version: "2.0.0-dev"),
    tools: [SpikeEcho(), SpikePeek(repository: repository)])
await StdioTransport.run(server)
