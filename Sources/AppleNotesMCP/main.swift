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

struct SpikeAppend: Tool {
    let repository: NotesRepository
    let sync: SyncCoordinator
    let name = "spike_append"
    let description = "Append a paragraph in place to a note titled \"MCP Test …\", read it back, then wait for iCloud upload. Spike tool."
    let inputSchema: JSONValue = [
        "type": "object",
        "properties": ["id": ["type": "string"], "text": ["type": "string"]],
        "required": ["id", "text"],
        "additionalProperties": false,
    ]

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let id = arguments["id"]?.stringValue, let text = arguments["text"]?.stringValue else {
            throw MCPError.invalidParams("id and text must be strings")
        }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let before = try await repository.cloudState(id: id)
            let outcome = try await repository.update(id: id, expectedVersion: nil) { blocks in
                blocks + [.paragraph(Paragraph(kind: .body, content: [.text(TextRun(text))]))]
            }
            let readBack = outcome.mismatch == nil
            let wrote = clock.now - start
            let report = try await sync.settle(id: id)
            return ToolResult(
                "readBack=\(readBack) write=\(wrote) nudge=\(report.nudge) synced=\(report.synced) total=\(report.total) "
                    + "cloud before=\(before.local)/\(before.synced) after=\(report.state.local)/\(report.state.synced)",
                isError: !(readBack && report.synced))
        } catch {
            return ToolResult(error.description, isError: true)
        }
    }
}

let repository = NotesRepository(writeGuardTitlePrefix: "MCP Test ")
let sync = SyncCoordinator(repository: repository)
let server = Server(
    info: ServerInfo(name: "apple-notes-mcp", version: "2.0.0-dev"),
    tools: [SpikeEcho(), SpikePeek(repository: repository), SpikeAppend(repository: repository, sync: sync)])
await StdioTransport.run(server)
