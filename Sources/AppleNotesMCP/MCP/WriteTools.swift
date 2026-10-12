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
    var text = "\(verb) \"\(outcome.title)\". id: \(outcome.id) | version: \(outcome.version) | \(cloud)."
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
    let description = "Creates a note from Markdown. The first line becomes the title (start with \"# Title\")."
    let inputSchema = schema([
        "markdown": stringProperty("Note body as Markdown"),
        "folder": stringProperty("Folder path or id; default is the iCloud Notes folder"),
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
    let description = """
        Adds Markdown to a note without touching the rest. position "end" (default) or "start" (just \
        below the title). under_heading puts it at the end of that heading's section instead.
        """
    let inputSchema = schema([
        "id": stringProperty("Note id"),
        "markdown": stringProperty("Markdown to add"),
        "position": ["type": "string", "enum": ["end", "start"], "description": "end (default) or start"],
        "under_heading": stringProperty("Text of a heading in the note; the Markdown goes at the end of its section"),
        "version": stringProperty("Version from read_note; the write is refused if the note changed since"),
    ], required: ["id", "markdown"])
    let annotations = ToolAnnotations()

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let id = try args.string("id")
        let addition = trimmedBlocks(try args.string("markdown"))
        let atStart = try args.choice("position", ["end", "start"], default: "end") == "start"
        let heading = try args.optionalString("under_heading")
        let version = try args.optionalString("version")
        guard !addition.isEmpty else { throw MCPError.invalidParams("markdown must not be empty") }
        return try await writeResult {
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
    let description = """
        Replaces old_text with new_text in the note's Markdown (as read_note shows it), like editing a \
        file. old_text must appear exactly once unless replace_all is true. Only the changed characters \
        are rewritten, so the rest of the note keeps its formatting.
        """
    let inputSchema = schema([
        "id": stringProperty("Note id"),
        "old_text": stringProperty("Exact Markdown to replace, copied from read_note"),
        "new_text": stringProperty("Replacement Markdown"),
        "replace_all": ["type": "boolean", "description": "Replace every occurrence (default false)"],
        "version": stringProperty("Version from read_note; the write is refused if the note changed since"),
    ], required: ["id", "old_text", "new_text"])
    let annotations = ToolAnnotations(destructive: true)

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let id = try args.string("id")
        let old = try args.string("old_text")
        let new = try args.string("new_text")
        let all = try args.bool("replace_all", default: false)
        let version = try args.optionalString("version")
        guard !old.isEmpty else { throw MCPError.invalidParams("old_text must not be empty") }
        return try await writeResult {
            let outcome = try await notes.repository.update(id: id, expectedVersion: version) { blocks throws(NotesError) in
                let markdown = MarkdownRenderer.render(blocks)
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
    let description = """
        Replaces the whole note with new Markdown. Unchanged lines are kept as they are, so formatting \
        Markdown cannot show (colors, fonts) survives on them. Requires the version from read_note. \
        Keep ![…](attachment:…) placeholders.
        """
    let inputSchema = schema([
        "id": stringProperty("Note id"),
        "markdown": stringProperty("The complete new note as Markdown"),
        "version": stringProperty("Version from read_note"),
    ], required: ["id", "markdown", "version"])
    let annotations = ToolAnnotations(destructive: true, idempotent: true)

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let id = try args.string("id")
        let blocks = trimmedBlocks(try args.string("markdown"))
        let version = try args.string("version")
        guard !blocks.isEmpty else { throw MCPError.invalidParams("markdown must not be empty; use delete_note to remove a note") }
        return try await writeResult {
            let outcome = try await notes.repository.update(id: id, expectedVersion: version) { _ throws(NotesError) in blocks }
            return try await writeReport("Updated", outcome, notes: notes)
        }
    }
}

struct DeleteNoteTool: Tool {
    let notes: NotesContext
    let name = "delete_note"
    let title: String? = "Delete a note"
    let description = "Moves a note to Recently Deleted, where it can be restored in Notes for 30 days."
    let inputSchema = schema(["id": stringProperty("Note id")], required: ["id"])
    let annotations = ToolAnnotations(destructive: true, idempotent: false)

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let id = try Arguments(arguments).string("id")
        return try await writeResult {
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
    let description = """
        Moves a note to another folder (path or id) of the same account; the note keeps its id. \
        A note in Recently Deleted is restored this way. Moving into or out of a shared folder changes \
        who can see the note: ask the user first, then pass allow_shared: true.
        """
    let inputSchema = schema([
        "id": stringProperty("Note id"),
        "folder": stringProperty("Destination folder path such as \"Projects/Ideas\", or a folder id"),
        "allow_shared": ["type": "boolean", "description": "The user agreed to a move into or out of a shared folder"],
    ], required: ["id", "folder"])
    let annotations = ToolAnnotations(idempotent: false)

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let id = try args.string("id"), folder = try args.string("folder")
        let allowShared = try args.bool("allow_shared", default: false)
        return try await writeResult {
            let moved = try await notes.repository.move(id: id, toFolder: folder, allowShared: allowShared)
            let sync = try await notes.sync.settle(id: id)
            let verb = moved.restored ? "Restored" : "Moved"
            return ToolResult("\(verb) \"\(moved.title)\" from \(moved.from) to \(moved.to). id: \(id) | "
                + (sync.synced ? "uploaded to iCloud." : "saved on this Mac; iCloud has not taken it yet (Notes will upload it later)."))
        }
    }
}

struct ManageFolderTool: Tool {
    let notes: NotesContext
    let name = "manage_folder"
    let title: String? = "Create, rename or delete a folder"
    let description = """
        action create: folder is the new folder's path, such as "Projects/Ideas" (the parent must exist; \
        a single name makes a top-level folder). action rename: folder (path or id) gets the new name. \
        action delete: removes an empty folder; folders that still hold notes or subfolders are refused, \
        so move their notes first. Folders cannot be moved here. Renaming a shared folder changes it for \
        everyone: ask the user first, then pass allow_shared: true.
        """
    let inputSchema = schema([
        "action": ["type": "string", "enum": ["create", "rename", "delete"], "description": "create, rename or delete"],
        "folder": stringProperty("For create, the new folder's path; otherwise the folder's path or id"),
        "name": stringProperty("For rename: the new name"),
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
