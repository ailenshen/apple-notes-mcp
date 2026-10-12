import Foundation
import MCPCore
import NotesKit

/// Waits for the iCloud upload and describes the outcome of a write.
func writeReport(_ verb: String, _ outcome: WriteOutcome, notes: NotesContext) async throws -> ToolResult {
    var outcome = outcome
    var sync = try await notes.sync.settle(id: outcome.id)
    var rebuilt = false
    // A table edited in place that does not upload (it was edited in Notes itself during this
    // Notes session) is rebuilt, so the change still reaches other devices.
    let stuck = Set(sync.state.pendingTables).intersection(outcome.tablesEditedInPlace)
    if !sync.synced, sync.state.noteSynced, !stuck.isEmpty {
        let again = try await notes.repository.rebuildTables(id: outcome.id, tableIDs: stuck)
        outcome = WriteOutcome(id: again.id, version: again.version, title: again.title, mismatch: outcome.mismatch ?? again.mismatch)
        sync = try await notes.sync.settle(id: outcome.id)
        rebuilt = true
    }
    var cloud = sync.synced
        ? "uploaded to iCloud"
        : "saved on this Mac; iCloud has not taken it yet (Notes will upload it later)"
    if rebuilt {
        cloud += "; the edited table was rebuilt so iCloud would take it, which reset formatting inside its cells"
    }
    var text = "\(verb) \"\(outcome.title)\". id: \(ShortID.of(outcome.id)) | version: \(outcome.version) | \(cloud)."
    if let mismatch = outcome.mismatch {
        text += "\nWarning: the note does not read back exactly as written — \(mismatch). Read it again before further edits."
        return ToolResult(text, isError: true)
    }
    return ToolResult(text)
}

func writeResult(_ body: () async throws -> ToolResult) async throws -> ToolResult {
    do {
        return try await body()
    } catch let error as MCPError {
        throw error
    } catch let error as NotesError {
        return ToolResult(permissionHint(error), isError: true)
    }
}

/// Blank lines at the end of inserted Markdown would become empty paragraphs; drop them.
func trimmedBlocks(_ markdown: String) -> [Block] {
    var blocks = MarkdownParser.parse(markdown)
    while case .paragraph(let p)? = blocks.last, p.kind == .body, p.content.isEmpty, blocks.count > 0 { blocks.removeLast() }
    return blocks
}

struct CreateNoteTool: Tool {
    let notes: NotesContext
    let name = "create_note"
    let title: String? = "Create a note"
    let description = "Creates a note from Markdown; the first line is the title."
    let inputSchema = schema([
        "markdown": stringProperty("Markdown"),
        "folder": stringProperty("Path or id; default Notes"),
    ], required: ["markdown"])
    let annotations = ToolAnnotations()

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let blocks = trimmedBlocks(try args.string("markdown"))
        let folder = try args.optionalString("folder")
        guard !blocks.isEmpty else { throw MCPError.invalidParams("markdown must not be empty") }
        return try await writeResult {
            let folderID = try await folder.asyncMap { try await notes.repository.resolveFolder($0).id }
            let outcome = try await notes.repository.create(folderID: folderID, blocks: blocks)
            return try await writeReport("Created", outcome, notes: notes)
        }
    }
}

struct AppendToNoteTool: Tool {
    let notes: NotesContext
    let name = "append_to_note"
    let title: String? = "Add to a note"
    let description = "Adds Markdown at the end, at the start, or at the end of a heading's section."
    let inputSchema = schema([
        "id": stringProperty("Note id"),
        "markdown": stringProperty("Markdown to add"),
        "position": ["type": "string", "enum": ["end", "start"], "description": "end (default) or start"],
        "under_heading": stringProperty("Heading text; adds at the end of its section"),
        "version": stringProperty("From read_note; refused if the note changed since"),
    ], required: ["id", "markdown"])
    let annotations = ToolAnnotations()

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let ref = try args.string("id")
        let addition = trimmedBlocks(try args.string("markdown"))
        let atStart = try args.choice("position", ["end", "start"], default: "end") == "start"
        let heading = try args.optionalString("under_heading")
        let version = try args.optionalString("version")
        guard !addition.isEmpty else { throw MCPError.invalidParams("markdown must not be empty") }
        return try await writeResult {
            let id = try await notes.repository.resolveNoteID(ref)
            let outcome = try await notes.repository.update(id: id, expectedVersion: version) { blocks throws(NotesError) in
                var result = blocks
                result.insert(contentsOf: addition, at: try insertionIndex(in: blocks, heading: heading, atStart: atStart))
                return result
            }
            return try await writeReport("Updated", outcome, notes: notes)
        }
    }
}

/// Where appended blocks go: the end of a heading's section, just below the title, or the end.
func insertionIndex(in blocks: [Block], heading: String?, atStart: Bool) throws(NotesError) -> Int {
    func level(_ block: Block) -> Int? {
        guard case .paragraph(let p) = block else { return nil }
        switch p.kind {
        case .title: return 1
        case .heading: return 2
        case .subheading: return 3
        default: return nil
        }
    }
    if let heading {
        let wanted = heading.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        let matches = blocks.indices.filter { i in
            guard level(blocks[i]) != nil, case .paragraph(let p) = blocks[i] else { return false }
            return p.plainText.trimmingCharacters(in: .whitespaces).lowercased() == wanted
        }
        guard let found = matches.first else { throw .notFound("heading \"\(heading)\" in this note") }
        guard matches.count == 1 else { throw .refused("\(matches.count) headings are called \"\(heading)\"; use edit_note instead") }
        let own = level(blocks[found])!
        var end = blocks.index(after: found)
        while end < blocks.count, (level(blocks[end]) ?? Int.max) > own { end += 1 }
        // Keep trailing empty lines of the section after the insertion.
        while end > found + 1, case .paragraph(let p) = blocks[end - 1], p.kind == .body, p.content.isEmpty { end -= 1 }
        return end
    }
    if atStart {
        if case .paragraph(let p)? = blocks.first, p.kind == .title || !p.content.isEmpty { return 1 }
        return 0
    }
    var end = blocks.count
    while end > 1, case .paragraph(let p) = blocks[end - 1], p.kind == .body, p.content.isEmpty { end -= 1 }
    return end
}

struct EditNoteTool: Tool {
    let notes: NotesContext
    let name = "edit_note"
    let title: String? = "Edit part of a note"
    let description = "Replaces old_text with new_text, like editing a file. Unchanged text keeps its formatting."
    let inputSchema = schema([
        "id": stringProperty("Note id"),
        "old_text": stringProperty("Exact Markdown from read_note; must be unique unless replace_all"),
        "new_text": stringProperty("Markdown"),
        "replace_all": ["type": "boolean", "description": "Replace every occurrence"],
        "version": stringProperty("From read_note; refused if the note changed since"),
    ], required: ["id", "old_text", "new_text"])
    let annotations = ToolAnnotations(destructive: true)

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let ref = try args.string("id")
        let old = try args.string("old_text")
        let new = try args.string("new_text")
        let all = try args.bool("replace_all", default: false)
        let version = try args.optionalString("version")
        guard !old.isEmpty else { throw MCPError.invalidParams("old_text must not be empty") }
        return try await writeResult {
            let id = try await notes.repository.resolveNoteID(ref)
            let outcome = try await notes.repository.update(id: id, expectedVersion: version) { blocks throws(NotesError) in
                // The same text read_note shows, short attachment ids included.
                let markdown = MarkdownRenderer.render(blocks.mappingAttachmentIDs(ShortID.of))
                let count = markdown.components(separatedBy: old).count - 1
                if count == 0 { throw .notFound("old_text in the note. Closest line: \"\(closestLine(to: old, in: markdown))\"") }
                if count > 1, !all { throw .refused("old_text appears \(count) times; add more context or set replace_all") }
                return MarkdownParser.parse(markdown.replacingOccurrences(of: old, with: new))
            }
            return try await writeReport("Updated", outcome, notes: notes)
        }
    }
}

/// The line sharing the longest prefix with the first line of `needle`, to help the model
/// fix a near miss.
func closestLine(to needle: String, in markdown: String) -> String {
    let target = needle.components(separatedBy: "\n").first ?? needle
    var best = ("", 0)
    for line in markdown.components(separatedBy: "\n") {
        let shared = zip(line, target).prefix(while: { $0 == $1 }).count
        let contains = (1...max(1, target.count)).reversed().first { line.contains(target.prefix($0)) } ?? 0
        let score = max(shared, contains)
        if score > best.1 { best = (line, score) }
    }
    return best.0
}

struct UpdateNoteTool: Tool {
    let notes: NotesContext
    let name = "update_note"
    let title: String? = "Rewrite a note"
    let description = "Rewrites the whole note. Unchanged lines keep their formatting."
    let inputSchema = schema([
        "id": stringProperty("Note id"),
        "markdown": stringProperty("The whole note as Markdown"),
        "version": stringProperty("From read_note"),
    ], required: ["id", "markdown", "version"])
    let annotations = ToolAnnotations(destructive: true, idempotent: true)

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let ref = try args.string("id")
        let blocks = trimmedBlocks(try args.string("markdown"))
        let version = try args.string("version")
        guard !blocks.isEmpty else { throw MCPError.invalidParams("markdown must not be empty; use delete_note to remove a note") }
        return try await writeResult {
            let id = try await notes.repository.resolveNoteID(ref)
            let outcome = try await notes.repository.update(id: id, expectedVersion: version) { _ throws(NotesError) in blocks }
            return try await writeReport("Updated", outcome, notes: notes)
        }
    }
}

struct DeleteNoteTool: Tool {
    let notes: NotesContext
    let name = "delete_note"
    let title: String? = "Delete a note"
    let description = "Moves a note to Recently Deleted."
    let inputSchema = schema(["id": stringProperty("Note id")], required: ["id"])
    let annotations = ToolAnnotations(destructive: true, idempotent: false)

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let ref = try Arguments(arguments).string("id")
        return try await writeResult {
            let id = try await notes.repository.resolveNoteID(ref)
            let note = try await notes.repository.note(id: id)
            try await notes.repository.delete(id: id)
            return ToolResult("Moved \"\(note.title)\" to Recently Deleted.")
        }
    }
}

struct MoveNoteTool: Tool {
    let notes: NotesContext
    let name = "move_note"
    let title: String? = "Move a note"
    let description = "Moves a note to another folder, or restores it from Recently Deleted. Shared folders need allow_shared, after asking the user."
    let inputSchema = schema([
        "id": stringProperty("Note id"),
        "folder": stringProperty("Path or id"),
        "allow_shared": ["type": "boolean", "description": "The user agreed to changing who can see the note"],
    ], required: ["id", "folder"])
    let annotations = ToolAnnotations(idempotent: false)

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let ref = try args.string("id"), folder = try args.string("folder")
        let allowShared = try args.bool("allow_shared", default: false)
        return try await writeResult {
            let id = try await notes.repository.resolveNoteID(ref)
            let moved = try await notes.repository.move(id: id, toFolder: folder, allowShared: allowShared)
            let sync = try await notes.sync.settle(id: id)
            let verb = moved.restored ? "Restored" : "Moved"
            return ToolResult("\(verb) \"\(moved.title)\" from \(moved.from) to \(moved.to). id: \(ShortID.of(id)) | "
                + (sync.synced ? "uploaded to iCloud." : "saved on this Mac; iCloud has not taken it yet (Notes will upload it later)."))
        }
    }
}

struct ManageFolderTool: Tool {
    let notes: NotesContext
    let name = "manage_folder"
    let title: String? = "Create, rename or delete a folder"
    let description = "Creates a folder (folder = its new path), renames one, or deletes an empty one. Renaming a shared folder needs allow_shared, after asking the user."
    let inputSchema = schema([
        "action": ["type": "string", "enum": ["create", "rename", "delete"], "description": "create, rename or delete"],
        "folder": stringProperty("Path or id (for create, the new path)"),
        "name": stringProperty("New name, for rename"),
        "allow_shared": ["type": "boolean", "description": "The user agreed to renaming a shared folder"],
    ], required: ["action", "folder"])
    let annotations = ToolAnnotations(destructive: true, idempotent: false)

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let action = try args.choice("action", ["create", "rename", "delete"], default: "")
        guard !action.isEmpty else { throw MCPError.invalidParams("action must be create, rename or delete") }
        let folder = try args.string("folder")
        return try await writeResult {
            switch action {
            case "create":
                let path = try await notes.repository.createFolder(path: folder)
                return ToolResult("Created the folder \(path).")
            case "rename":
                guard let name = try args.optionalString("name") else { throw MCPError.invalidParams("rename needs name") }
                let renamed = try await notes.repository.renameFolder(folder, to: name, allowShared: try args.bool("allow_shared", default: false))
                return ToolResult("Renamed \(renamed.old) to \(renamed.new).")
            case "delete":
                let path = try await notes.repository.deleteFolder(folder)
                return ToolResult("Deleted the empty folder \(path).")
            default:
                throw MCPError.invalidParams("action must be create, rename or delete")
            }
        }
    }
}
