import Foundation
import MCPCore
import NotesKit

/// Everything the tools share. All members are Sendable; NotesKit isolates the rest.
struct NotesContext: Sendable {
    let repository: NotesRepository
    let sync: SyncCoordinator
    let search: FullTextSearch
    let index: DescriptionIndex

    /// A description is fresh while the note has not changed since it was written.
    func isFresh(_ description: NoteDescription?, modified: Date) -> Bool {
        guard let description else { return false }
        return modified.timeIntervalSince(description.noteModified) < 1
    }
}

func day(_ date: Date) -> String {
    date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
}

func minute(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: date)
}

/// Turns NotesKit failures into tool results the model can act on.
func notesResult(_ body: () async throws -> String) async throws -> ToolResult {
    do {
        return ToolResult(try await body())
    } catch let error as MCPError {
        throw error
    } catch let error as NotesError {
        return ToolResult(error.description, isError: true)
    }
}

struct OverviewTool: Tool {
    let notes: NotesContext
    let name = "overview"
    let title: String? = "Overview of notes"
    let description = """
        Without folder: every folder with its id, note count and how many notes have a description. \
        With folder (path or id): one line per note — id | title | last modified | description \
        (~ marks a description extracted automatically, ! one that is out of date).
        """
    let inputSchema = schema(["folder": stringProperty("Folder path such as \"Projects/Ideas\", or a folder id")])
    let annotations = ToolAnnotations.readOnly

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let folder = try Arguments(arguments).optionalString("folder")
        return try await notesResult {
            let descriptions = try await notes.index.all()
            if let folder {
                let resolved = try await notes.repository.resolveFolder(folder)
                let list = try await notes.repository.notes(inFolder: resolved.id)
                let needExtract = Set(list.filter { !notes.isFresh(descriptions[$0.id], modified: $0.modified) }.map(\.id))
                let bodies = try await notes.search.bodies(ids: needExtract)
                var lines = ["\(resolved.path) — \(list.count) notes", "id | title | modified | description"]
                for note in list {
                    let summary: String
                    if note.isLocked {
                        summary = "(locked)"
                    } else if let d = descriptions[note.id], notes.isFresh(d, modified: note.modified) {
                        summary = d.text
                    } else if let d = descriptions[note.id] {
                        summary = "! " + d.text
                    } else {
                        summary = "~ " + DescriptionIndex.extract(fromPlainText: bodies[note.id] ?? "", title: note.title)
                    }
                    lines.append("\(note.id) | \(note.isPinned ? "📌 " : "")\(note.title) | \(day(note.modified)) | \(summary)")
                }
                return lines.joined(separator: "\n")
            }
            let folders = try await notes.repository.folders()
            var lines = ["path | id | notes | described"]
            for f in folders {
                let list = try await notes.repository.notes(inFolder: f.id)
                let described = list.filter { notes.isFresh(descriptions[$0.id], modified: $0.modified) }.count
                lines.append("\(f.path) | \(f.id) | \(f.noteCount) | \(described)")
            }
            lines.append("\(folders.reduce(0) { $0 + $1.noteCount }) notes in \(folders.count) folders")
            return lines.joined(separator: "\n")
        }
    }
}

struct SearchTool: Tool {
    let notes: NotesContext
    let name = "search"
    let title: String? = "Search notes"
    let description = """
        Full-text search over titles and bodies. Words are separated by spaces; match "all" (default) \
        needs every word, "any" needs one. Returns id | title | folder | modified, with the matching text.
        """
    let inputSchema = schema([
        "query": stringProperty("Words to look for"),
        "match": ["type": "string", "enum": ["all", "any"], "description": "all (default) or any"],
        "folder": stringProperty("Only this folder (and its subfolders): path or id"),
        "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Default 20"],
    ], required: ["query"])
    let annotations = ToolAnnotations.readOnly

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let query = try args.string("query")
        let matchAll = try args.choice("match", ["all", "any"], default: "all") == "all"
        let folder = try args.optionalString("folder")
        let limit = try args.int("limit", default: 20, range: 1...100)
        return try await notesResult {
            let folderPath = try await folder.asyncMap { try await notes.repository.resolveFolder($0).path }
            let paths = try await notes.repository.folderPathsByPrimaryKey()
            let deleted = await notes.repository.deletedHere
            var (total, hits) = try await notes.search.search(query, matchAll: matchAll, folderPath: folderPath, limit: limit + deleted.count, folderPaths: paths)
            let before = hits.count
            hits = Array(hits.filter { !deleted.contains($0.id) }.prefix(limit))
            total -= before - hits.count
            if hits.isEmpty { return "No notes match \"\(query)\"." }
            var lines = ["\(total) notes match \"\(query)\"\(total > hits.count ? " (showing \(hits.count))" : ""):"]
            for hit in hits {
                lines.append("\(hit.id) | \(hit.title) | \(hit.folderPath) | \(day(hit.modified))")
                lines.append("  \(hit.snippet)")
            }
            return lines.joined(separator: "\n")
        }
    }
}

struct ReadNoteTool: Tool {
    let notes: NotesContext
    let name = "read_note"
    let title: String? = "Read a note"
    let description = """
        Returns the note as Markdown, one note paragraph per line, after a header with its version. \
        Pass the version back when you change the note.
        """
    let inputSchema = schema(["id": stringProperty("Note id from overview or search")], required: ["id"])
    let annotations = ToolAnnotations.readOnly

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let id = try Arguments(arguments).string("id")
        return try await notesResult {
            let note = try await notes.repository.note(id: id)
            let blocks = try await notes.repository.blocks(id: id)
            var header = "id: \(id) | version: \(NotesRepository.version(of: blocks)) | folder: \(note.folderPath) | modified: \(minute(note.modified))"
            if note.isShared { header += " | shared (read-only)" }
            if note.isInTrash { header += " | in Recently Deleted (read-only)" }
            var text = header + "\n---\n" + MarkdownRenderer.render(blocks)
            let description = try await notes.index.get(id)
            if !notes.isFresh(description, modified: note.modified) {
                text += "\n---\nThis note has \(description == nil ? "no description" : "an out-of-date description"). "
                    + "Call describe_note with a one-line summary so overview can show it."
            }
            return text
        }
    }
}

struct DescribeNoteTool: Tool {
    let notes: NotesContext
    let name = "describe_note"
    let title: String? = "Describe a note"
    let description = "Saves a one-line summary of a note (what it is about, in the note's language). Shown by overview."
    let inputSchema = schema([
        "id": stringProperty("Note id"),
        "description": stringProperty("One line, at most about 80 characters"),
    ], required: ["id", "description"])
    let annotations = ToolAnnotations(idempotent: true)

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let id = try args.string("id")
        let text = try args.string("description").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty else { throw MCPError.invalidParams("description must not be empty") }
        return try await notesResult {
            let note = try await notes.repository.note(id: id)
            try await notes.index.set(id, text: text, source: .agent, noteModified: note.modified)
            return "Saved the description of \"\(note.title)\"."
        }
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        switch self {
        case .some(let value): try await transform(value)
        case .none: nil
        }
    }
}
