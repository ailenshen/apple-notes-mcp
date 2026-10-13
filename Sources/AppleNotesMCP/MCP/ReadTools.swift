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
    let description = "Folders with note counts. With folder, dates or sort: notes as id | title | date | size | description. undescribed: true lists notes needing a description."
    let inputSchema = schema([
        "folder": stringProperty("Path, such as \"Projects/Ideas\", or id"),
        "modified_after": stringProperty("YYYY-MM-DD, inclusive"),
        "modified_before": stringProperty("YYYY-MM-DD, exclusive"),
        "created_after": stringProperty("YYYY-MM-DD, inclusive"),
        "created_before": stringProperty("YYYY-MM-DD, exclusive"),
        "sort": sortProperty("Newest first by modified (default) or created, or by title"),
        "undescribed": ["type": "boolean", "description": "Only notes needing a description, with their opening text"],
        "depth": ["type": "integer", "minimum": 1, "maximum": 10, "description": "Folder levels shown without other arguments (default 1)"],
        "limit": ["type": "integer", "minimum": 1, "maximum": 500, "description": "Default 30 (50 with undescribed)"],
    ])
    let annotations = ToolAnnotations.readOnly

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let folder = try args.optionalString("folder")
        let undescribed = try args.bool("undescribed", default: false)
        let window = try args.dateWindow(), createdWindow = try args.dateWindow("created")
        let order = try args.order()
        let limit = try args.int("limit", default: undescribed ? 50 : 30, range: 1...500)
        let depth = try args.int("depth", default: 1, range: 1...10)
        return try await notesResult {
            let descriptions = try await notes.index.all()
            if folder != nil || undescribed || !window.isEmpty || !createdWindow.isEmpty || order != nil {
                // Listing a folder in its natural order groups notes by subfolder.
                let group = folder != nil && order == nil && window.isEmpty && createdWindow.isEmpty
                return try await noteList(folder: folder, window: window, created: createdWindow, order: order ?? (createdWindow.isEmpty ? .modified : .created), group: group, undescribed: undescribed,
                                          limit: limit, descriptions: descriptions)
            }
            let folders = try await notes.repository.folders()
            var described: [String: Int] = [:]
            for note in try await notes.repository.notes(inFolders: nil) where notes.isFresh(descriptions[note.id], modified: note.modified) {
                described[note.folderID, default: 0] += 1
            }
            return folderTree(folders, described: described, depth: depth)
        }
    }

    /// Folders as an indented tree down to `depth`, "name (notes, described)". A folder at the
    /// depth limit says how many subfolders and notes it hides, so the next call can go deeper.
    /// Depth comes from the parent chain, never from splitting paths: names may contain "/".
    /// Ids are shown only for folders whose path is not unique.
    private func folderTree(_ folders: [FolderSnapshot], described: [String: Int], depth: Int) -> String {
        let paths = Dictionary(grouping: folders, by: \.path)
        func isInside(_ f: FolderSnapshot, _ parent: FolderSnapshot) -> Bool {
            f.names.count > parent.names.count && Array(f.names.prefix(parent.names.count)) == parent.names
        }
        let total = folders.reduce(0) { $0 + $1.noteCount }, totalDescribed = described.values.reduce(0, +)
        let deeper = folders.contains { $0.names.count > depth }
        var lines = ["\(total) notes in \(folders.count) folders, \(totalDescribed) described."
            + (deeper ? " Showing \(depth) level\(depth == 1 ? "" : "s"); pass depth for more, or a folder to list its notes." : "")
            + " Refer to a folder by its path, such as Parent/Child."]
        for f in folders where f.names.count <= depth {
            var counts = "\(f.noteCount)"
            if let d = described[f.id], d > 0 { counts += ", \(d) described" }
            if f.names.count == depth {
                let hidden = folders.filter { isInside($0, f) }
                if !hidden.isEmpty {
                    counts += "; \(hidden.count) subfolder\(hidden.count == 1 ? "" : "s"), \(f.noteCount + hidden.reduce(0) { $0 + $1.noteCount }) in all"
                }
            }
            let id = (paths[f.path]?.count ?? 0) > 1 ? " [id \(ShortID.of(f.id))]" : ""
            lines.append(String(repeating: "  ", count: f.names.count - 1) + "\(f.name) (\(counts))\(id)")
        }
        return lines.joined(separator: "\n")
    }

    /// One line per note in scope, filtered and ordered. With `undescribed`, only notes lacking a
    /// current description, each followed by the start of its text: the material for writing
    /// descriptions in bulk. The calling model writes them; the server never generates any.
    /// 当主流客户端声明 sampling 能力时，可考虑由服务器在后台请求客户端模型生成描述。
    private func noteList(
        folder: String?, window: DateWindow, created: DateWindow, order: NoteOrder, group: Bool, undescribed: Bool, limit: Int,
        descriptions: [String: NoteDescription]
    ) async throws -> String {
        var scope: Set<String>?
        var scopeName = "all folders"
        var subfolderLine: String?
        var rootNames: [String] = []
        let all = try await notes.repository.folders()
        if let folder {
            let resolved = try await notes.repository.resolveFolder(folder)
            rootNames = resolved.names
            let inside = all.filter { $0.names.count > resolved.names.count && Array($0.names.prefix(resolved.names.count)) == resolved.names }
            scope = Set([resolved.id] + inside.map(\.id))
            scopeName = resolved.path
            let direct = inside.filter { $0.names.count == resolved.names.count + 1 }
            if !direct.isEmpty { subfolderLine = "Subfolders: " + direct.map { "\($0.name) (\($0.noteCount))" }.joined(separator: ", ") }
        }
        var list = try await notes.repository.notes(inFolders: scope)
        list = list.filter { window.contains($0.modified) && created.contains($0.created) }
        if undescribed { list = list.filter { !$0.isLocked && !notes.isFresh(descriptions[$0.id], modified: $0.modified) } }
        switch order {
        case .modified: list.sort { $0.modified > $1.modified }
        case .created: list.sort { $0.created > $1.created }
        case .title: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        // Truncate by the sort first, so grouping never drops a folder's newest notes.
        let shown = Array(list.prefix(limit))
        let ids = Set(shown.map(\.id))
        let bodies = try await notes.search.bodies(ids: ids)
        let attachments = try await notes.search.attachmentKinds(noteIDs: ids)
        // Across all folders the folder is always shown; within a folder, only once there are subfolders.
        let what = undescribed ? "notes without a current description" : "notes"
        let range = [window.label("modified"), created.label("created")].filter { !$0.isEmpty }.joined(separator: ", ")
        var lines = ["\(scopeName)\(range.isEmpty ? "" : " " + range) — \(list.count) \(what)\(list.count > shown.count ? ", showing \(shown.count)" : "")"]
        if let subfolderLine { lines.append(subfolderLine) }
        if list.isEmpty { return lines.joined(separator: "\n") }
        let dateName = order == .created ? "created" : "modified"
        let folderNames = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.names) })
        var items: [(folder: [String], lines: [String])] = []
        for note in shown {
            let text = bodies[note.id] ?? ""
            let date = day(order == .created ? note.created : note.modified)
            var line = "\(ShortID.of(note.id)) | \(note.isPinned ? "📌 " : "")\(listTitle(note.title)) | "
                + "\(date) | \(note.isLocked ? "locked" : sizeLabel(characters: text.count, attachments: attachments[note.id] ?? [:]))"
            if undescribed {
                items.append((folderNames[note.folderID] ?? [], [line, "  " + Self.opening(of: text, title: note.title)]))
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
            items.append((folderNames[note.folderID] ?? [], [line]))
        }
        let sections = FolderSections.render(items, root: folder == nil ? nil : rootNames, rootPath: scopeName, group: group)
        if let legend = sections.legend { lines.append(legend) }
        lines.append("id | title | \(dateName) | size" + (undescribed ? "" : " | description"))
        lines += sections.lines
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

/// Note lines with each folder named once, on a "[folder]" line above its notes. Within a
/// listed folder (`root`), paths are relative to it and "[.]" is the folder itself; across all
/// folders, paths are full. With `group`, notes are gathered by folder, folders ordered by
/// their first (best or newest) note and each folder keeping its notes' order; otherwise the
/// order is kept and a folder line appears whenever the folder changes. Items come already
/// sorted and truncated, so grouping never hides a folder's top notes.
enum FolderSections {
    static func render(
        _ items: [(folder: [String], lines: [String])], root: [String]?, rootPath: String, group: Bool
    ) -> (legend: String?, lines: [String]) {
        let folders = items.map(\.folder)
        let show = root == nil || Set(folders).count > 1
        guard show else { return (nil, items.flatMap(\.lines)) }
        var ordered = items
        if group {
            var order: [[String]] = []
            for f in folders where !order.contains(f) { order.append(f) }
            ordered = order.flatMap { f in items.filter { $0.folder == f } }
        }
        func label(_ names: [String]) -> String {
            guard let root, names.count >= root.count, Array(names.prefix(root.count)) == root else { return FolderPath.join(names) }
            let relative = Array(names.dropFirst(root.count))
            return relative.isEmpty ? "." : FolderPath.join(relative)
        }
        var lines: [String] = []
        var last: [String]?
        for item in ordered {
            if item.folder != last {
                lines.append("[\(label(item.folder))]")
                last = item.folder
            }
            lines += item.lines
        }
        let legend = root == nil ? "[folder] heads the notes below it." : "[folder] heads the notes below it, relative to \(rootPath); [.] is \(rootPath) itself."
        return (legend, lines)
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
    func label(_ field: String) -> String {
        switch (from, until) {
        case (let f?, let u?):
            day(f) == day(u.addingTimeInterval(-1)) ? "\(field) on \(day(f))" : "\(field) \(day(f)) to \(day(u.addingTimeInterval(-1)))"
        case (let f?, nil): "\(field) since \(day(f))"
        case (nil, let u?): "\(field) before \(day(u))"
        case (nil, nil): ""
        }
    }
}

struct SearchTool: Tool {
    let notes: NotesContext
    let name = "search"
    let title: String? = "Search notes"
    let description = "Full-text search over titles and bodies, best matches first."
    let inputSchema = schema([
        "query": stringProperty("Words"),
        "match": ["type": "string", "enum": ["all", "any"], "description": "Every word (all, default) or any"],
        "folder": stringProperty("Path or id; includes subfolders"),
        "modified_after": stringProperty("YYYY-MM-DD, inclusive"),
        "modified_before": stringProperty("YYYY-MM-DD, exclusive"),
        "created_after": stringProperty("YYYY-MM-DD, inclusive"),
        "created_before": stringProperty("YYYY-MM-DD, exclusive"),
        "sort": sortProperty("Instead of best match: newest modified or created first, or title"),
        "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Default 10"],
    ], required: ["query"])
    let annotations = ToolAnnotations.readOnly

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let query = try args.string("query")
        let matchAll = try args.choice("match", ["all", "any"], default: "all") == "all"
        let folder = try args.optionalString("folder")
        let limit = try args.int("limit", default: 10, range: 1...100)
        let window = try args.dateWindow(), createdWindow = try args.dateWindow("created")
        let order = try args.order()
        return try await notesResult {
            let resolved = try await folder.asyncMap { try await notes.repository.resolveFolder($0) }
            let folderPath = resolved?.path
            let namesByPath = Dictionary((try await notes.repository.folders()).map { ($0.path, $0.names) }, uniquingKeysWith: { a, _ in a })
            let paths = try await notes.repository.folderPathsByPrimaryKey()
            let deleted = await notes.repository.deletedHere
            var (total, hits) = try await notes.search.search(query, matchAll: matchAll, folderPath: folderPath, limit: limit + deleted.count, folderPaths: paths,
                                                            modified: window, created: createdWindow, order: order)
            let before = hits.count
            hits = Array(hits.filter { !deleted.contains($0.id) }.prefix(limit))
            total -= before - hits.count
            let ranges = [window.label("modified"), createdWindow.label("created")].filter { !$0.isEmpty }
            let scope = ranges.isEmpty ? "" : " (\(ranges.joined(separator: ", ")))"
            if hits.isEmpty { return "No notes match \"\(query)\"\(scope)." }
            let attachments = try await notes.search.attachmentKinds(noteIDs: Set(hits.map(\.id)))
            var lines = ["\(total) notes match \"\(query)\"\(scope)\(folderPath.map { " in \($0)" } ?? "")\(total > hits.count ? ", showing \(hits.count)" : ""):"]
            var items: [(folder: [String], lines: [String])] = []
            for hit in hits {
                let date = day(order == .created ? hit.created : hit.modified)
                items.append((namesByPath[hit.folderPath] ?? FolderPath.split(hit.folderPath), [
                    "\(ShortID.of(hit.id)) | \(listTitle(hit.title)) | \(date) | \(sizeLabel(characters: hit.length, attachments: attachments[hit.id] ?? [:]))",
                    "  \(hit.snippet)",
                ]))
            }
            // Ranked by relevance, folders are grouped by their best hit; with an explicit sort,
            // the order is kept.
            let sections = FolderSections.render(items, root: resolved?.names, rootPath: folderPath ?? "", group: order == nil)
            if let legend = sections.legend { lines.append(legend) }
            lines += sections.lines
            return lines.joined(separator: "\n")
        }
    }
}

struct ReadNoteTool: Tool {
    let notes: NotesContext
    let name = "read_note"
    let title: String? = "Read a note"
    let description = "Notes as Markdown, with the version to pass back when writing. By id, several ids, or exact title; a long note can be read by section, or as an outline first."
    let inputSchema = schema([
        "id": stringProperty("Note id"),
        "ids": ["type": "array", "items": ["type": "string"], "maxItems": 20, "description": "Several note ids, read in one call"],
        "title": stringProperty("Exact title, instead of id"),
        "section": stringProperty("Only this heading's section"),
        "outline": ["type": "boolean", "description": "Only the headings, with each section's size"],
    ])
    let annotations = ToolAnnotations.readOnly

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let givenID = try args.optionalString("id"), givenTitle = try args.optionalString("title")
        var givenIDs: [String] = []
        if case .array(let items)? = arguments["ids"] { givenIDs = items.compactMap(\.stringValue) }
        guard [givenID != nil, givenTitle != nil, !givenIDs.isEmpty].filter({ $0 }).count == 1 else {
            throw MCPError.invalidParams("give one of id, ids or title")
        }
        guard givenIDs.count <= 20 else { throw MCPError.invalidParams("ids takes at most 20 notes") }
        let section = try args.optionalString("section")
        let outline = try args.bool("outline", default: false)
        if section != nil && outline { throw MCPError.invalidParams("give section or outline, not both") }
        return try await notesResult {
            var refs = givenID.map { [$0] } ?? givenIDs
            if let givenTitle {
                let matches = try await notes.repository.notes(titled: givenTitle)
                if matches.isEmpty { throw NotesError.notFound("a note titled \"\(givenTitle)\"; use search to find it") }
                if matches.count > 1 {
                    return (["\(matches.count) notes are titled \"\(givenTitle)\"; read one by id:"]
                        + matches.map { "\(ShortID.of($0.id)) | \($0.folderPath) | \(day($0.modified))" }).joined(separator: "\n")
                }
                refs = [matches[0].id]
            }
            var parts: [String] = []
            for ref in refs {
                do {
                    parts.append(try await render(try await notes.repository.resolveNoteID(ref), section: section, outline: outline))
                } catch let error as NotesError where refs.count > 1 {
                    parts.append("\(ref): \(error)")
                }
            }
            return parts.joined(separator: "\n\n")
        }
    }

    /// Header (id, version, folder, date, flags), then the Markdown. Attachment ids are
    /// shortened; writes map them back.
    private func render(_ id: String, section: String?, outline: Bool) async throws -> String {
        let note = try await notes.repository.note(id: id)
        let blocks = try await notes.repository.blocks(id: id)
        var header = "id: \(ShortID.of(id)) | version: \(NotesRepository.version(of: blocks)) | folder: \(note.folderPath) | modified: \(minute(note.modified))"
        if note.isShared { header += note.isSharedReadOnly ? " | shared with you read-only" : " | shared" }
        if note.isInTrash { header += " | in Recently Deleted (read-only)" }
        if !notes.isFresh(try await notes.index.get(id), modified: note.modified) { header += " | needs description" }
        let shown = blocks.mappingAttachmentIDs(ShortID.of)
        if outline {
            // Sizes are of each section as read_note would return it (Markdown). No total: the
            // one overview and search show counts plain text, and two different totals for
            // one note read as a contradiction (seen 2026-10-14: 472 vs 658).
            var lines = [header, "---"]
            let firstHeading = shown.indices.first { headingLevel(shown[$0]).map { $0 > 1 } ?? false } ?? shown.count
            let intro = MarkdownRenderer.render(Array(shown[..<firstHeading])).count
            if intro > 0 { lines.append("(before the first heading) — \(intro) chars") }
            for i in shown.indices where (headingLevel(shown[i]) ?? 1) > 1 {
                guard case .paragraph(let p) = shown[i] else { continue }
                let range = try sectionRange(in: shown, heading: p.plainText)
                lines.append(String(repeating: "#", count: headingLevel(shown[i])!) + " \(p.plainText) — \(MarkdownRenderer.render(Array(shown[range])).count) chars")
            }
            return lines.joined(separator: "\n")
        }
        if let section {
            let range = try sectionRange(in: shown, heading: section)
            return header + " | section only\n---\n" + MarkdownRenderer.render(Array(shown[range]))
        }
        return header + "\n---\n" + MarkdownRenderer.render(shown)
    }
}

struct DescribeNoteTool: Tool {
    let notes: NotesContext
    let name = "describe_note"
    let title: String? = "Describe notes"
    let description = "Saves one-line summaries of notes, shown by overview. Several at once."
    let inputSchema = schema([
        "descriptions": [
            "type": "array", "minItems": 1, "maxItems": 200,
            "items": schema([
                "id": stringProperty("Note id"),
                "description": stringProperty("One line, under 80 characters"),
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
                    let fullID = try await notes.repository.resolveNoteID(id)
                    let note = try await notes.repository.note(id: fullID)
                    try await notes.index.set(fullID, text: text, source: .agent, noteModified: note.modified)
                    saved.append(note.title)
                } catch let error as NotesError {
                    if case .notFound = error {} else if case .refused = error {} else { throw error }
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
