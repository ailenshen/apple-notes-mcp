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

/// Heading level of a block: 1 title, 2 heading, 3 subheading, nil otherwise.
func headingLevel(_ block: Block) -> Int? {
    guard case .paragraph(let p) = block else { return nil }
    switch p.kind {
    case .title: return 1
    case .heading: return 2
    case .subheading: return 3
    default: return nil
    }
}

/// The blocks of a heading's section: the heading itself, then everything up to the next
/// heading of the same or a higher level. Matching ignores case and leading "#".
func sectionRange(in blocks: [Block], heading: String) throws(NotesError) -> Range<Int> {
    let wanted = heading.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
    let matches = blocks.indices.filter { i in
        guard headingLevel(blocks[i]) != nil, case .paragraph(let p) = blocks[i] else { return false }
        return p.plainText.trimmingCharacters(in: .whitespaces).lowercased() == wanted
    }
    guard let found = matches.first else {
        let headings = blocks.compactMap { b -> String? in
            guard headingLevel(b) ?? 1 > 1, case .paragraph(let p) = b else { return nil }
            return p.plainText
        }
        throw .notFound("heading \"\(heading)\" in this note" + (headings.isEmpty ? " (it has no headings)" : "; headings: " + headings.joined(separator: " | ")))
    }
    guard matches.count == 1 else { throw .refused("\(matches.count) headings are called \"\(heading)\"; use replace instead") }
    let own = headingLevel(blocks[found])!
    var end = blocks.index(after: found)
    while end < blocks.count, (headingLevel(blocks[end]) ?? Int.max) > own { end += 1 }
    return found..<end
}

/// Where inserted blocks go: under a heading, just below the title, or at the end.
/// Under a heading, list items join the section's last list of the same kind, so a new
/// checklist item stays with the checklist even when text follows it; anything else goes at
/// the end of the section.
func insertionIndex(in blocks: [Block], heading: String?, atStart: Bool, inserting: [Block] = []) throws(NotesError) -> Int {
    if let heading {
        let section = try sectionRange(in: blocks, heading: heading)
        if case .paragraph(let first)? = inserting.first, let kind = listKind(first.kind),
            let last = section.dropFirst().last(where: { i in
                if case .paragraph(let p) = blocks[i] { return listKind(p.kind) == kind } else { return false }
            })
        {
            return last + 1
        }
        var end = section.upperBound
        // Keep trailing empty lines of the section after the insertion.
        while end > section.lowerBound + 1, case .paragraph(let p) = blocks[end - 1], p.kind == .body, p.content.isEmpty { end -= 1 }
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

/// Lists that read as one when adjacent: checklist items whether done or not, and each
/// bullet style on its own.
private func listKind(_ kind: ParagraphKind) -> String? {
    switch kind {
    case .checklist: "checklist"
    case .bullet: "bullet"
    case .dash: "dash"
    case .numbered: "numbered"
    default: nil
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

/// Every change to an existing note, in one tool: exact replacements, an insertion, or a whole
/// rewrite. Several changes go in one call, which saves a round trip per change (benchmarked
/// 2026-10-12: three changes asked for in one sentence cost 30% fewer input tokens than with
/// separate append/edit/update tools, whose definitions also cost ~280 tokens more per turn).
struct EditNoteTool: Tool {
    let notes: NotesContext
    let name = "edit_note"
    let title: String? = "Edit a note"
    let description = """
        Changes a note in one call: replace (exact text pairs from read_note, applied in order), insert \
        (Markdown at the end, the start, or under a heading), or rewrite (the whole note). Unchanged text \
        keeps its formatting.
        """
    let inputSchema = schema([
        "id": stringProperty("Note id"),
        "version": stringProperty("From read_note; required for rewrite"),
        "replace": [
            "type": "array",
            "items": schema(["old": stringProperty("Exact Markdown, unique unless all"), "new": stringProperty("Markdown"),
                             "all": ["type": "boolean"]], required: ["old", "new"]),
        ],
        "insert": stringProperty("Markdown to add"),
        "at": stringProperty("end (default), start, or a heading's text (list items join that section's list)"),
        "rewrite": stringProperty("The whole note as Markdown"),
    ], required: ["id"])
    let annotations = ToolAnnotations(destructive: true)

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let ref = try args.string("id")
        let version = try args.optionalString("version")
        var pairs: [(old: String, new: String, all: Bool)] = []
        if case .array(let items)? = arguments["replace"] {
            for item in items {
                let a = Arguments(item.objectValue ?? [:])
                let old = try a.string("old")
                guard !old.isEmpty else { throw MCPError.invalidParams("replace.old must not be empty") }
                pairs.append((old, try a.string("new"), try a.bool("all", default: false)))
            }
        }
        let insert = try args.optionalString("insert").map(trimmedBlocks)
        let at = try args.optionalString("at") ?? "end"
        let rewrite = try args.optionalString("rewrite").map(trimmedBlocks)
        if rewrite != nil, !pairs.isEmpty || insert != nil { throw MCPError.invalidParams("rewrite cannot be combined with replace or insert") }
        if rewrite == nil, pairs.isEmpty, insert == nil { throw MCPError.invalidParams("give replace, insert or rewrite") }
        if rewrite != nil, version == nil { throw MCPError.invalidParams("rewrite needs the version from read_note") }
        if let rewrite, rewrite.isEmpty { throw MCPError.invalidParams("rewrite must not be empty; use delete_note") }
        return try await writeResult {
            let id = try await notes.repository.resolveNoteID(ref)
            let outcome = try await notes.repository.update(id: id, expectedVersion: version) { blocks throws(NotesError) in
                if let rewrite { return rewrite }
                var result = blocks
                if !pairs.isEmpty {
                    var markdown = MarkdownRenderer.render(blocks.mappingAttachmentIDs(ShortID.of))
                    for (old, new, all) in pairs {
                        let count = markdown.components(separatedBy: old).count - 1
                        if count == 0 { throw .notFound("\"\(old)\" in the note. Closest line: \"\(closestLine(to: old, in: markdown))\"") }
                        if count > 1, !all { throw .refused("\"\(old)\" appears \(count) times; add context or set all") }
                        markdown = markdown.replacingOccurrences(of: old, with: new)
                    }
                    result = MarkdownParser.parse(markdown)
                }
                if let insert {
                    let heading = at == "end" || at == "start" ? nil : at
                    result.insert(contentsOf: insert, at: try insertionIndex(in: result, heading: heading, atStart: at == "start", inserting: insert))
                }
                return result
            }
            return try await writeReport("Updated", outcome, notes: notes)
        }
    }
}
