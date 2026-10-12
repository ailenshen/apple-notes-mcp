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

/// The local calendar day, as YYYY-MM-DD. (The ISO 8601 format style would give the UTC day.)
func day(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: date)
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
        With no arguments: every folder with its id, note count and how many notes have a description. \
        With folder (path or id; includes subfolders), a date filter or sort: one line per note — \
        id | title | [folder |] date | size | description (~ marks a description extracted \
        automatically, ! one that is out of date). Size is characters of text plus attachments, so you \
        can judge a note before reading it. Without folder, a date filter or sort lists notes from all \
        folders. undescribed: true lists only notes lacking a current description, each with the start \
        of its text, so you can write many descriptions at once with describe_note.
        """
    let inputSchema = schema([
        "folder": stringProperty("Folder path such as \"Projects/Ideas\", or a folder id"),
        "modified_after": stringProperty("Only notes modified on or after this date (YYYY-MM-DD, or ISO 8601 date-time)"),
        "modified_before": stringProperty("Only notes modified before this date (YYYY-MM-DD, or ISO 8601 date-time)"),
        "sort": sortProperty("modified (default, newest first), created (newest first) or title"),
        "undescribed": ["type": "boolean", "description": "Only notes without a current description, with the start of their text"],
        "limit": ["type": "integer", "minimum": 1, "maximum": 500, "description": "At most this many notes (default 100; 50 with undescribed)"],
    ])
    let annotations = ToolAnnotations.readOnly

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let folder = try args.optionalString("folder")
        let undescribed = try args.bool("undescribed", default: false)
        let window = try args.dateWindow()
        let order = try args.order()
        let limit = try args.int("limit", default: undescribed ? 50 : 100, range: 1...500)
        return try await notesResult {
            let descriptions = try await notes.index.all()
            if folder != nil || undescribed || !window.isEmpty || order != nil {
                return try await noteList(folder: folder, window: window, order: order ?? .modified, undescribed: undescribed,
                                          limit: limit, descriptions: descriptions)
            }
            let folders = try await notes.repository.folders()
            var described: [String: Int] = [:]
            for note in try await notes.repository.notes(inFolders: nil) where notes.isFresh(descriptions[note.id], modified: note.modified) {
                described[note.folderID, default: 0] += 1
            }
            var lines = ["path | id | notes | described"]
            for f in folders { lines.append("\(f.path) | \(f.id) | \(f.noteCount) | \(described[f.id] ?? 0)") }
            lines.append("\(folders.reduce(0) { $0 + $1.noteCount }) notes in \(folders.count) folders")
            return lines.joined(separator: "\n")
        }
    }

    /// One line per note in scope, filtered and ordered. With `undescribed`, only notes lacking a
    /// current description, each followed by the start of its text: the material for writing
    /// descriptions in bulk. The calling model writes them; the server never generates any.
    /// 当主流客户端声明 sampling 能力时，可考虑由服务器在后台请求客户端模型生成描述。
    private func noteList(
        folder: String?, window: DateWindow, order: NoteOrder, undescribed: Bool, limit: Int,
        descriptions: [String: NoteDescription]
    ) async throws -> String {
        var scope: Set<String>?
        var scopeName = "all folders"
        if let folder {
            let resolved = try await notes.repository.resolveFolder(folder)
            scope = Set(try await notes.repository.folders().filter { $0.id == resolved.id || $0.path.hasPrefix(resolved.path + "/") }.map(\.id))
            scopeName = resolved.path
        }
        var list = try await notes.repository.notes(inFolders: scope)
        list = list.filter { window.contains($0.modified) }
        if undescribed { list = list.filter { !$0.isLocked && !notes.isFresh(descriptions[$0.id], modified: $0.modified) } }
        switch order {
        case .modified: list.sort { $0.modified > $1.modified }
        case .created: list.sort { $0.created > $1.created }
        case .title: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        let shown = Array(list.prefix(limit))
        let ids = Set(shown.map(\.id))
        let bodies = try await notes.search.bodies(ids: ids)
        let attachments = try await notes.search.attachmentKinds(noteIDs: ids)
        let showFolder = Set(shown.map(\.folderID)).count > 1
        let what = undescribed ? "notes without a current description" : "notes"
        var lines = ["\(scopeName)\(window.isEmpty ? "" : " " + window.label) — \(list.count) \(what)\(list.count > shown.count ? ", showing \(shown.count)" : "")"]
        if list.isEmpty { return lines[0] }
        let dateName = order == .created ? "created" : "modified"
        lines.append("id | title | " + (showFolder ? "folder | " : "") + "\(dateName) | size" + (undescribed ? "" : " | description"))
        for note in shown {
            let text = bodies[note.id] ?? ""
            let date = day(order == .created ? note.created : note.modified)
            var line = "\(note.id) | \(note.isPinned ? "📌 " : "")\(listTitle(note.title)) | " + (showFolder ? "\(note.folderPath) | " : "")
                + "\(date) | \(note.isLocked ? "locked" : sizeLabel(characters: text.count, attachments: attachments[note.id] ?? [:]))"
            if undescribed {
                lines.append(line)
                lines.append("  " + Self.opening(of: text, title: note.title))
                continue
            }
            let summary: String
            if note.isLocked {
                summary = "(locked)"
            } else if let d = descriptions[note.id], notes.isFresh(d, modified: note.modified) {
                summary = d.text
            } else if let d = descriptions[note.id] {
                summary = "! " + d.text
            } else {
                summary = "~ " + DescriptionIndex.extract(fromPlainText: text, title: note.title)
            }
            line += " | \(summary)"
            lines.append(line)
        }
        if undescribed { lines.append("Write one line per note with describe_note, several notes per call.") }
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

/// "2.3k chars, 3 images, 1 table": enough to judge a note before reading it.
func sizeLabel(characters: Int, attachments: [String: Int]) -> String {
    let chars = characters < 1000 ? "\(characters) chars" : String(format: "%.1fk chars", Double(characters) / 1000)
    let extra = AttachmentKind.summary(attachments)
    return extra.isEmpty ? chars : chars + ", " + extra
}

func sortProperty(_ description: String) -> JSONValue {
    ["type": "string", "enum": .array(NoteOrder.allCases.map { .string($0.rawValue) }), "description": .string(description)]
}

extension DateWindow {
    var label: String {
        switch (from, until) {
        case (let f?, let u?):
            day(f) == day(u.addingTimeInterval(-1)) ? "modified on \(day(f))" : "modified \(day(f)) to \(day(u.addingTimeInterval(-1)))"
        case (let f?, nil): "modified since \(day(f))"
        case (nil, let u?): "modified before \(day(u))"
        case (nil, nil): ""
        }
    }
}

struct SearchTool: Tool {
    let notes: NotesContext
    let name = "search"
    let title: String? = "Search notes"
    let description = """
        Full-text search over titles and bodies. Words are separated by spaces; match "all" (default) \
        needs every word, "any" needs one. Returns id | title | folder | date | size, with the matching \
        text. Best matches come first unless sort is given; dates filter by modification date.
        """
    let inputSchema = schema([
        "query": stringProperty("Words to look for"),
        "match": ["type": "string", "enum": ["all", "any"], "description": "all (default) or any"],
        "folder": stringProperty("Only this folder (and its subfolders): path or id"),
        "modified_after": stringProperty("Only notes modified on or after this date (YYYY-MM-DD, or ISO 8601 date-time)"),
        "modified_before": stringProperty("Only notes modified before this date (YYYY-MM-DD, or ISO 8601 date-time)"),
        "sort": sortProperty("Instead of best match first: modified or created (newest first), or title"),
        "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Default 20"],
    ], required: ["query"])
    let annotations = ToolAnnotations.readOnly

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let query = try args.string("query")
        let matchAll = try args.choice("match", ["all", "any"], default: "all") == "all"
        let folder = try args.optionalString("folder")
        let limit = try args.int("limit", default: 20, range: 1...100)
        let window = try args.dateWindow()
        let order = try args.order()
        return try await notesResult {
            let folderPath = try await folder.asyncMap { try await notes.repository.resolveFolder($0).path }
            let paths = try await notes.repository.folderPathsByPrimaryKey()
            let deleted = await notes.repository.deletedHere
            var (total, hits) = try await notes.search.search(query, matchAll: matchAll, folderPath: folderPath, limit: limit + deleted.count, folderPaths: paths,
                                                            modified: window, order: order)
            let before = hits.count
            hits = Array(hits.filter { !deleted.contains($0.id) }.prefix(limit))
            total -= before - hits.count
            let scope = window.isEmpty ? "" : " (\(window.label))"
            if hits.isEmpty { return "No notes match \"\(query)\"\(scope)." }
            let attachments = try await notes.search.attachmentKinds(noteIDs: Set(hits.map(\.id)))
            var lines = ["\(total) notes match \"\(query)\"\(scope)\(total > hits.count ? ", showing \(hits.count)" : ""):"]
            for hit in hits {
                let date = day(order == .created ? hit.created : hit.modified)
                lines.append("\(hit.id) | \(listTitle(hit.title)) | \(hit.folderPath) | \(date) | \(sizeLabel(characters: hit.length, attachments: attachments[hit.id] ?? [:]))")
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
