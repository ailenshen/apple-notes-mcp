import Foundation
import MCPCore
import Synchronization
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

/// Titles in lists are cut to keep each line short; the id identifies the note anyway.
/// A note's title is its first line, which Notes keeps up to about 80 characters.
func listTitle(_ title: String, limit: Int = 40) -> String {
    title.count > limit ? String(title.prefix(limit - 1)) + "…" : title
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
        return ToolResult(permissionHint(error), isError: true)
    }
}

/// Missing permissions open the setup window once per process and say so in the result.
func permissionHint(_ error: NotesError) -> String {
    guard case .noAccess = error else { return error.description }
    if PermissionPrompt.shown.testAndSet() { return error.description }
    Onboarding.openFromServer()
    return error.description + ". The Apple Notes MCP setup window has been opened on this Mac: grant the permission there, then try again."
}

enum PermissionPrompt {
    static let shown = OnceFlag()
}

/// A flag that reports whether it was already set, safely across threads.
final class OnceFlag: Sendable {
    private let value = Mutex(false)
    func testAndSet() -> Bool {
        value.withLock { set in
            defer { set = true }
            return set
        }
    }
}

struct OverviewTool: Tool {
    let notes: NotesContext
    let name = "overview"
    let title: String? = "Overview of notes"
    let description = """
        Without folder: every folder with its id, note count and how many notes have a description. \
        With folder (path or id): one line per note — id | title | last modified | description \
        (~ marks a description extracted automatically, ! one that is out of date). \
        With undescribed: true (with or without folder): only notes lacking a current description, \
        each with the start of its text, so you can write descriptions for many notes at once \
        with describe_note.
        """
    let inputSchema = schema([
        "folder": stringProperty("Folder path such as \"Projects/Ideas\", or a folder id"),
        "undescribed": ["type": "boolean", "description": "List only notes without a current description, with the start of their text"],
        "limit": ["type": "integer", "minimum": 1, "maximum": 200, "description": "With undescribed: at most this many notes (default 50)"],
    ])
    let annotations = ToolAnnotations.readOnly

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let folder = try args.optionalString("folder")
        let undescribed = try args.bool("undescribed", default: false)
        let limit = try args.int("limit", default: 50, range: 1...200)
        return try await notesResult {
            let descriptions = try await notes.index.all()
            if undescribed { return try await undescribedNotes(folder: folder, limit: limit, descriptions: descriptions) }
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
                    lines.append("\(note.id) | \(note.isPinned ? "📌 " : "")\(listTitle(note.title)) | \(day(note.modified)) | \(summary)")
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

    /// The material for writing descriptions in bulk: notes without a current description, each
    /// with the start of its text. The calling model writes them; the server never generates any.
    /// 当主流客户端声明 sampling 能力时，可考虑由服务器在后台请求客户端模型生成描述。
    private func undescribedNotes(folder: String?, limit: Int, descriptions: [String: NoteDescription]) async throws -> String {
        let scope: [FolderSnapshot]
        if let folder {
            let resolved = try await notes.repository.resolveFolder(folder)
            scope = try await notes.repository.folders().filter { $0.id == resolved.id || $0.path.hasPrefix(resolved.path + "/") }
        } else {
            scope = try await notes.repository.folders()
        }
        var pending: [NoteSnapshot] = []
        for f in scope {
            pending += try await notes.repository.notes(inFolder: f.id)
                .filter { !$0.isLocked && !notes.isFresh(descriptions[$0.id], modified: $0.modified) }
        }
        let where_ = folder.map { " in \($0)" } ?? ""
        if pending.isEmpty { return "Every note\(where_) has a current description." }
        pending.sort { $0.modified > $1.modified }
        let shown = Array(pending.prefix(limit))
        let bodies = try await notes.search.bodies(ids: Set(shown.map(\.id)))
        var lines = ["\(pending.count) notes\(where_) have no current description\(pending.count > shown.count ? " (showing the \(shown.count) most recently modified)" : ""):"]
        for note in shown {
            lines.append("\(note.id) | \(listTitle(note.title)) | \(note.folderPath) | \(day(note.modified))")
            lines.append("  " + Self.opening(of: bodies[note.id] ?? "", title: note.title))
        }
        lines.append("Write one line per note with describe_note, several notes per call.")
        return lines.joined(separator: "\n")
    }

    /// The first ~300 characters after the title, on one line.
    static func opening(of text: String, title: String) -> String {
        var lines = text.replacingOccurrences(of: "\u{FFFC}", with: "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.first == title { lines.removeFirst() }
        let joined = lines.joined(separator: " ¶ ")
        if joined.isEmpty { return "(title only)" }
        return joined.count > 300 ? String(joined.prefix(299)) + "…" : joined
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
                lines.append("\(hit.id) | \(listTitle(hit.title)) | \(hit.folderPath) | \(day(hit.modified))")
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
        Pass the version back when you change the note. Give id, or title when the user names a note: \
        an exact title (ignoring case) reads it directly, and several notes with that title are listed.
        """
    let inputSchema = schema([
        "id": stringProperty("Note id from overview or search"),
        "title": stringProperty("The note's exact title, instead of id"),
    ])
    let annotations = ToolAnnotations.readOnly

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let givenID = try args.optionalString("id"), givenTitle = try args.optionalString("title")
        guard (givenID == nil) != (givenTitle == nil) else { throw MCPError.invalidParams("give either id or title") }
        return try await notesResult {
            var id = givenID ?? ""
            if let givenTitle {
                let matches = try await notes.repository.notes(titled: givenTitle)
                if matches.isEmpty { return "No note is titled \"\(givenTitle)\". Use search to find it." }
                if matches.count > 1 {
                    return (["\(matches.count) notes are titled \"\(givenTitle)\"; read one by id:"]
                        + matches.map { "\($0.id) | \($0.folderPath) | \(day($0.modified))" }).joined(separator: "\n")
                }
                id = matches[0].id
            }
            let note = try await notes.repository.note(id: id)
            let blocks = try await notes.repository.blocks(id: id)
            var header = "id: \(id) | version: \(NotesRepository.version(of: blocks)) | folder: \(note.folderPath) | modified: \(minute(note.modified))"
            if note.isShared { header += note.isSharedReadOnly ? " | shared with you read-only" : " | shared" }
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
    let title: String? = "Describe notes"
    let description = """
        Saves one-line summaries of notes (what each is about, in the note's language), shown by overview. \
        Pass one or many; overview with undescribed: true lists notes that need one.
        """
    let inputSchema = schema([
        "descriptions": [
            "type": "array", "minItems": 1, "maxItems": 200,
            "items": schema([
                "id": stringProperty("Note id"),
                "description": stringProperty("One line, at most about 80 characters"),
            ], required: ["id", "description"]),
        ],
    ], required: ["descriptions"])
    let annotations = ToolAnnotations(idempotent: true)

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        guard case .array(let items)? = arguments["descriptions"], !items.isEmpty, items.count <= 200 else {
            throw MCPError.invalidParams("descriptions must be a list of 1 to 200 {id, description} objects")
        }
        var wanted: [(id: String, text: String)] = []
        for item in items {
            let args = Arguments(item.objectValue ?? [:])
            let text = try args.string("description").trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard !text.isEmpty else { throw MCPError.invalidParams("a description must not be empty") }
            wanted.append((try args.string("id"), text))
        }
        return try await notesResult {
            var saved: [String] = []
            var failed: [String] = []
            for (id, text) in wanted {
                do {
                    let note = try await notes.repository.note(id: id)
                    try await notes.index.set(id, text: text, source: .agent, noteModified: note.modified)
                    saved.append(note.title)
                } catch let error as NotesError {
                    guard case .notFound = error else { throw error }
                    failed.append("\(id): \(error)")
                }
            }
            var lines = [saved.count == 1 ? "Saved the description of \"\(saved[0])\"." : "Saved \(saved.count) descriptions."]
            if !failed.isEmpty { lines.append("Not saved:"); lines += failed.map { "  " + $0 } }
            return lines.joined(separator: "\n")
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
