import CoreData
import CoreGraphics
import CryptoKit
import Foundation
import NotesSharedShim

/// The only public door into the Notes data layer. Everything behind it runs on the main
/// actor, and only Sendable snapshots come out, so no Core Data object crosses a boundary.
/// 当 Apple 开放官方 Notes API 时，只需重新实现本类与 SyncCoordinator，快照类型和工具层不变。
@MainActor
public final class NotesRepository {
    private var readStore: ReadStore?
    private var writeContext: WriteContext?
    /// Notes deleted by this process. The store may show them in their old folder for minutes
    /// (Notes.app saves lazily in the background), so reads treat them as deleted until then.
    public internal(set) var deletedHere: Set<String> = []
    /// Folders deleted by this process, hidden for the same reason: after a recursive delete,
    /// the store kept listing the folders for minutes (seen 2026-10-14).
    var deletedFoldersHere: Set<String> = []
    /// New names of folders renamed by this process, until the store shows them. After a
    /// rename the store kept the old name for over two minutes (seen 2026-10-14), so the new
    /// name was "not found" and lists showed the old one. An entry ends when the store catches
    /// up, or after `renameOverlayLifetime`, so a later rename made in Notes is not hidden.
    var renamedFoldersHere: [String: (name: String, at: Date)] = [:]
    static let renameOverlayLifetime: TimeInterval = 10 * 60

    /// While set, writes only touch notes whose title starts with this prefix. Development
    /// builds and the checks set it to "MCP Test " so real notes are never written by accident.
    public var writeGuardTitlePrefix: String?

    public init(writeGuardTitlePrefix: String? = nil) {
        self.writeGuardTitlePrefix = writeGuardTitlePrefix
    }

    /// Opened on first use, so the server still answers discovery when access is missing.
    func store() throws(NotesError) -> ReadStore {
        if let readStore { return readStore }
        let opened = try ReadStore()
        readStore = opened
        return opened
    }

    private func writer() throws(NotesError) -> WriteContext {
        if let writeContext { return writeContext }
        let opened = try WriteContext()
        writeContext = opened
        return opened
    }

    public func note(id: String) throws(NotesError) -> NoteSnapshot {
        let store = try store()
        store.refresh()
        return try snapshot(of: store.note(id: id))
    }

    /// The note body as blocks, through the same mapping that Markdown rendering uses.
    public func blocks(id: String) throws(NotesError) -> [Block] {
        let store = try store()
        store.refresh()
        let note = try store.note(id: id)
        if (note.value(forKey: "isPasswordProtected") as? Bool) == true {
            throw .refused("note \(id) is locked; locked notes are not read")
        }
        guard let mergeable = try send(note, "mergeableString"),
            let attributed = try send(mergeable, "attributedString") as? NSAttributedString
        else { return [] }
        return try Reader(context: store.context).blocks(attributed)
    }

    /// Ids of every readable note (not deleted, not locked), newest first.
    public func noteIDs() throws(NotesError) -> [String] {
        let store = try store()
        store.refresh()
        let request = NSFetchRequest<NSManagedObject>(entityName: "ICNote")
        request.predicate = NSPredicate(format: "markedForDeletion == NO AND isPasswordProtected == NO")
        request.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: false)]
        do {
            return try store.context.fetch(request).compactMap { $0.value(forKey: "identifier") as? String }
        } catch {
            throw .failed("listing notes failed: \(error.localizedDescription)")
        }
    }

    /// Readable notes whose title equals `title`, ignoring case and surrounding spaces,
    /// newest first. Notes in Recently Deleted are left out.
    public func notes(titled title: String) throws(NotesError) -> [NoteSnapshot] {
        let store = try store()
        store.refresh()
        let wanted = title.trimmingCharacters(in: .whitespaces)
        let found = try fetch(store, "ICNote", NSPredicate(format: "title ==[c] %@ AND markedForDeletion == NO", wanted))
        return try found.map { note throws(NotesError) in try snapshot(of: note, includeText: false) }
            .filter { !$0.isInTrash && !$0.isLocked }
            .sorted { $0.modified > $1.modified }
    }

    /// The full id of a note given its id or an id prefix (as lists show it).
    public func resolveNoteID(_ reference: String) throws(NotesError) -> String {
        try resolveID(reference, entities: ["ICNote"], what: "note")
    }

    /// The full id of an attachment given its id or an id prefix.
    public func resolveAttachmentID(_ reference: String) throws(NotesError) -> String {
        try resolveID(reference, entities: ["ICAttachment", "ICInlineAttachment"], what: "attachment")
    }

    private func resolveID(_ reference: String, entities: [String], what: String) throws(NotesError) -> String {
        let wanted = reference.trimmingCharacters(in: .whitespaces)
        let store = try store()
        var matches: [String] = []
        for entity in entities {
            if try !fetch(store, entity, NSPredicate(format: "identifier == %@", wanted)).isEmpty { return wanted }
            guard wanted.count >= 4 else { continue }
            matches += try fetch(store, entity, NSPredicate(format: "identifier BEGINSWITH[c] %@", wanted))
                .compactMap { $0.value(forKey: "identifier") as? String }
        }
        switch Set(matches).count {
        case 1: return matches[0]
        case 0: throw .notFound("\(what) \(reference)")
        default: throw .refused("\(reference) matches several \(what)s: \(Set(matches).sorted().joined(separator: ", ")); use the full id")
        }
    }

    public func cloudState(id: String) throws(NotesError) -> CloudState {
        let store = try store()
        store.refresh()
        let note = try store.note(id: id)
        guard let state = try send(note, "cloudState") as? NSObject else {
            throw .frameworkChanged("ICNote has no cloudState")
        }
        func versions(_ state: NSObject?) -> (Int, Int) {
            ((state?.value(forKey: "currentLocalVersion") as? Int) ?? 0, (state?.value(forKey: "latestVersionSyncedToCloud") as? Int) ?? 0)
        }
        var pendingTables: [String] = []
        for case let attachment as NSManagedObject in (note.value(forKey: "attachments") as? Set<NSManagedObject>) ?? []
        where attachment.value(forKey: "typeUTI") as? String == "com.apple.notes.table"
            && (attachment.value(forKey: "markedForDeletion") as? Bool) != true
        {
            let (local, synced) = versions(try send(attachment, "cloudState") as? NSObject)
            if synced < local, let tableID = attachment.value(forKey: "identifier") as? String { pendingTables.append(tableID) }
        }
        let (local, synced) = versions(state)
        return CloudState(local: local, synced: synced, pendingTables: pendingTables)
    }

    func syncTarget(id: String) throws(NotesError) -> SyncTarget {
        let store = try store()
        store.refresh()
        let note = try store.note(id: id)
        guard let folder = note.value(forKey: "folder") as? NSManagedObject else { throw .failed("note \(id) has no folder") }
        return SyncTarget(
            noteURI: note.objectID.uriRepresentation().absoluteString,
            folderURI: folder.objectID.uriRepresentation().absoluteString)
    }

    // MARK: Writing

    /// Reads the note through Notes' write context, checks the version the caller last saw,
    /// lets `transform` produce the new body, and applies it in place. Before writing, the
    /// note's stored data is backed up; after writing, the body is read back and compared.
    public func update(
        id: String, expectedVersion: String?, _ transform: ([Block]) throws(NotesError) -> [Block]
    ) throws(NotesError) -> WriteOutcome {
        let writer = try writer()
        let note = try writer.note(id: id)
        writer.context.refresh(note, mergeChanges: false)
        try guardWritable(note)
        let edit = try Writer(note: note, context: writer.context)
        let currentBlocks = try Reader(context: writer.context).blocks(try edit.current)
        let currentVersion = Self.version(of: currentBlocks)
        if let expectedVersion, expectedVersion != currentVersion {
            throw .conflict("the note changed after you read it (version \(currentVersion), you had \(expectedVersion)); read it again")
        }
        // The model sees attachment ids shortened (see ShortID); map them back first.
        let target = try transform(currentBlocks).expandingAttachmentIDs(from: currentBlocks)
        if let prefix = writeGuardTitlePrefix, !Self.firstLine(target).hasPrefix(prefix) {
            throw .refused("refusing to write: the title must keep starting with \"\(prefix)\" while the write guard is on")
        }
        try backup(note, id: id)
        do {
            try edit.apply(target)
            try writer.save()
        } catch {
            // Drop in-memory edits right away so Notes' autosave cannot persist half a write.
            writer.context.rollback()
            writer.context.refresh(note, mergeChanges: false)
            // Refreshing reloads each table's model, dropping in-memory cell edits (verified).
            for attachment in edit.editedTables { writer.context.refresh(attachment, mergeChanges: false) }
            throw error
        }
        var outcome = try verify(id: id, target: target)
        outcome.tablesEditedInPlace = edit.editedTables.compactMap { $0.value(forKey: "identifier") as? String }
        return outcome
    }

    /// Rebuilds the given tables of a note with the same content: new table attachments
    /// replace them, and the old ones are marked for deletion.
    ///
    /// This is the fallback when a table edited in place does not upload. That happens after
    /// the table was edited in Notes itself during this Notes session (verified 2026-10-12):
    /// Notes keeps its own in-memory copy of the table's sync state, so it does not see that our
    /// version still needs uploading. A new attachment has no such copy, so it uploads like any
    /// new table. Formatting inside the rebuilt cells is lost.
    /// 当找到让 Notes 重新读取表格同步状态的安全方法（或官方 API）时，删除这个兜底重建。
    public func rebuildTables(id: String, tableIDs: Set<String>) throws(NotesError) -> WriteOutcome {
        let writer = try writer()
        let note = try writer.note(id: id)
        writer.context.refresh(note, mergeChanges: false)
        try guardWritable(note)
        let edit = try Writer(note: note, context: writer.context)
        let blocks = try Reader(context: writer.context).blocks(try edit.current)
        try backup(note, id: id)
        do {
            try edit.rebuild(tables: tableIDs, in: blocks)
            try writer.save()
        } catch {
            writer.context.rollback()
            writer.context.refresh(note, mergeChanges: false)
            throw error
        }
        return try verify(id: id, target: blocks)
    }

    /// Creates a note in a folder (default: the iCloud "Notes" folder) with the given body.
    public func create(folderID: String?, blocks: [Block]) throws(NotesError) -> WriteOutcome {
        if let prefix = writeGuardTitlePrefix, !Self.firstLine(blocks).hasPrefix(prefix) {
            throw .refused("refusing to create: the title must start with \"\(prefix)\" while the write guard is on")
        }
        let writer = try writer()
        let folder = try writer.folder(id: folderID ?? "DefaultFolder-CloudKit")
        var created: AnyObject?
        let noteClass = try Loader.cls("ICNote")
        try call(noteClass, "newEmptyNoteInFolder:") {
            try NSShim.send(noteClass, selector: "newEmptyNoteInFolder:", object: folder, result: &created)
        }
        guard let note = created as? NSManagedObject, let id = note.value(forKey: "identifier") as? String else {
            throw .frameworkChanged("newEmptyNoteInFolder: returned no note")
        }
        do {
            let edit = try Writer(note: note, context: writer.context)
                try edit.apply(blocks)
            try writer.save()
        } catch {
            writer.context.rollback()
            throw error
        }
        return try verify(id: id, target: blocks)
    }

    /// Reads the note back through the read-only store and compares it with what was written.
    private func verify(id: String, target: [Block]) throws(NotesError) -> WriteOutcome {
        let written = try blocks(id: id)
        let title = try note(id: id).title
        if written == target {
            return WriteOutcome(id: id, version: Self.version(of: written), title: title, mismatch: nil)
        }
        let index = zip(written, target).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset
            ?? min(written.count, target.count)
        let got = index < written.count ? MarkdownRenderer.render([written[index]]) : "(nothing)"
        let wanted = index < target.count ? MarkdownRenderer.render([target[index]]) : "(nothing)"
        return WriteOutcome(
            id: id, version: Self.version(of: written), title: title,
            mismatch: "line \(index + 1) reads back as \"\(got)\" instead of \"\(wanted)\"")
    }

    private func guardWritable(_ note: NSManagedObject) throws(NotesError) {
        if deletedHere.contains(note.value(forKey: "identifier") as? String ?? "") { throw .refused("this note was moved to Recently Deleted") }
        if (note.value(forKey: "isPasswordProtected") as? Bool) == true { throw .refused("locked notes cannot be changed") }
        if (note.value(forKey: "markedForDeletion") as? Bool) == true { throw .refused("this note is deleted") }
        if Self.isTrash(note.value(forKey: "folder") as? NSManagedObject) { throw .refused("this note is in Recently Deleted; restore it in Notes first") }
        // Shared notes are edited like any other: edits are character-level CRDT changes that
        // merge with other participants' edits (verified 2026-10-12 on a note the owner shares).
        if Self.isSharedReadOnly(note) { throw .refused("this note is shared with you read-only") }
        if let prefix = writeGuardTitlePrefix, (note.value(forKey: "title") as? String)?.hasPrefix(prefix) != true {
            throw .refused("refusing to write: only notes titled \"\(prefix)…\" may be written while the write guard is on")
        }
    }

    /// Keeps the last 20 copies of the note's stored body, so any write can be undone by hand.
    private func backup(_ note: NSManagedObject, id: String) throws(NotesError) {
        guard let data = (note.value(forKey: "noteData") as? NSManagedObject)?.value(forKey: "data") as? Data else { return }
        let directory = Self.supportDirectory.appendingPathComponent("backups/\(id)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try data.write(to: directory.appendingPathComponent("\(stamp).bin"))
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "bin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for old in files.dropLast(20) { try FileManager.default.removeItem(at: old) }
        } catch {
            throw .failed("could not back up the note before writing: \(error.localizedDescription)")
        }
    }

    nonisolated public static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AppleNotesMCP", isDirectory: true)

    /// A short content hash of the note as Markdown. Passed back by the caller on write so a
    /// note edited in between is not overwritten. Content-only on purpose: modification
    /// dates in the store lag Notes.app and are not updated by in-place edits.
    nonisolated public static func version(of blocks: [Block]) -> String {
        let digest = SHA256.hash(data: Data(MarkdownRenderer.render(blocks).utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func firstLine(_ blocks: [Block]) -> String {
        guard case .paragraph(let p)? = blocks.first else { return "" }
        return p.plainText
    }

    // MARK: Diagnostics (used by NotesKitChecks)

    /// Colors every occurrence of `text` red, to give a check some hidden formatting to protect.
    public func diagnosticColor(id: String, text: String) throws(NotesError) {
        let writer = try writer()
        let note = try writer.note(id: id)
        try guardWritable(note)
        let edit = try Writer(note: note, context: writer.context)
        let string = try edit.current
        let found = (string.string as NSString).range(of: text)
        guard found.location != NSNotFound else { throw .notFound("text \(text)") }
        try call(note, "beginEditing") { try NSShim.send(note, selector: "beginEditing") }
        let red = CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        try edit.update(found) { $0[NSAttributedString.Key("TTColor")] = red }
        try call(note, "edited:range:changeInLength:") {
            try NSShim.send(note, selector: "edited:range:changeInLength:", unsignedInteger: 1, range: found, integer: 0)
        }
        try call(note, "endEditing") { try NSShim.send(note, selector: "endEditing") }
        try call(note, "saveNoteData") { try NSShim.send(note, selector: "saveNoteData") }
        try writer.save()
    }

    /// Attribute keys on the first character of `text`, read through the read-only store.
    public func diagnosticAttributeKeys(id: String, text: String) throws(NotesError) -> [String] {
        let store = try store()
        store.refresh()
        guard let mergeable = try send(store.note(id: id), "mergeableString"),
            let string = try send(mergeable, "attributedString") as? NSAttributedString
        else { return [] }
        let found = (string.string as NSString).range(of: text)
        guard found.location != NSNotFound else { throw .notFound("text \(text)") }
        return string.attributes(at: found.location, effectiveRange: nil).keys.map(\.rawValue).sorted()
    }

    /// The id of the note's first table attachment.
    public func diagnosticTableID(id: String) throws(NotesError) -> String? {
        for case .table(let table) in try blocks(id: id) { return table.id }
        return nil
    }

    /// Makes one table cell bold through Notes' write context, as editing in Notes would.
    public func diagnosticBoldTableCell(tableID: String, text: String) throws(NotesError) {
        let writer = try writer()
        try TableEditor(attachmentID: tableID, context: writer.context).diagnosticBold(text)
        try writer.save()
    }

    /// TTHints of a table cell, read through the read-only store.
    public func diagnosticTableCellHints(tableID: String, text: String) throws(NotesError) -> Int? {
        let store = try store()
        store.refresh()
        try Loader.startSharedContext()
        return try TableEditor(attachmentID: tableID, context: store.context).diagnosticHints(text)
    }

    public func modificationDate(id: String) throws(NotesError) -> Date { try note(id: id).modified }

    private func snapshot(of note: NSManagedObject, includeText: Bool = true) throws(NotesError) -> NoteSnapshot {
        var text = ""
        if includeText, (note.value(forKey: "isPasswordProtected") as? Bool) != true, let mergeable = try send(note, "mergeableString"),
            let attributed = try send(mergeable, "attributedString") as? NSAttributedString
        {
            text = attributed.string
        }
        let folder = note.value(forKey: "folder") as? NSManagedObject
        return NoteSnapshot(
            id: note.value(forKey: "identifier") as? String ?? "",
            title: note.value(forKey: "title") as? String ?? "",
            folder: folder.map { title(of: $0) } ?? "",
            folderID: folder?.value(forKey: "identifier") as? String ?? "",
            folderPath: folder.map { self.path(of: $0) } ?? "",
            modified: note.value(forKey: "modificationDate") as? Date ?? .distantPast,
            created: note.value(forKey: "creationDate") as? Date ?? .distantPast,
            isPinned: (note.value(forKey: "isPinned") as? Bool) ?? false,
            isLocked: (note.value(forKey: "isPasswordProtected") as? Bool) ?? false,
            isShared: Self.isShared(note),
            isSharedReadOnly: Self.isSharedReadOnly(note),
            isInTrash: Self.isTrash(folder) || deletedHere.contains(note.value(forKey: "identifier") as? String ?? ""),
            text: text)
    }

    // MARK: Folders

    var hasMultipleAccounts = false

    /// Folders Notes shows, as in `+[ICFolder predicateForVisibleObjects]`. A folder that
    /// "needs initial fetch from cloud" is a placeholder Notes made for a record it never
    /// downloaded (no parent, no notes; usually a folder deleted elsewhere), and Notes hides it.
    /// Notes' predicate also requires `owner.didChooseToMigrate`, which only matters for
    /// accounts never upgraded to the iCloud format; those are not supported here anyway.
    /// 当需要支持未迁移的旧账户时，改为直接调用 Notes 的 predicateForVisibleObjects。
    static let visibleFolder = "markedForDeletion == NO AND needsInitialFetchFromCloud == NO"

    /// User folders as a flat list in path order.
    public func folders() throws(NotesError) -> [FolderSnapshot] {
        let store = try store()
        store.refresh()
        let accounts = try fetch(store, "ICAccount", NSPredicate(format: "markedForDeletion == NO"))
        hasMultipleAccounts = accounts.count > 1
        let folders = try fetch(store, "ICFolder", NSPredicate(format: Self.visibleFolder + " AND folderType != 1 AND smartFolderQueryJSON == nil"))
        let notes = try fetch(store, "ICNote", NSPredicate(format: "markedForDeletion == NO"))
        var counts: [NSManagedObjectID: Int] = [:]
        for note in notes where !deletedHere.contains(note.value(forKey: "identifier") as? String ?? "") {
            if let folder = note.value(forKey: "folder") as? NSManagedObject { counts[folder.objectID, default: 0] += 1 }
        }
        return folders.filter { !deletedFoldersHere.contains($0.value(forKey: "identifier") as? String ?? "") }.map { folder in
            let names = self.names(of: folder)
            return FolderSnapshot(
                id: folder.value(forKey: "identifier") as? String ?? "",
                path: FolderPath.join(names),
                noteCount: counts[folder.objectID] ?? 0,
                name: title(of: folder),
                names: names,
                parentID: (folder.value(forKey: "parent") as? NSManagedObject)?.value(forKey: "identifier") as? String)
        }.sorted { a, b in
            for (p, q) in zip(a.names, b.names) where p != q { return p.localizedStandardCompare(q) == .orderedAscending }
            return a.names.count < b.names.count
        }
    }

    /// Notes in one folder, pinned first, then newest first. Text is not loaded.
    public func notes(inFolder folderID: String) throws(NotesError) -> [NoteSnapshot] {
        let store = try store()
        store.refresh()
        _ = try folders()
        let notes = try fetch(store, "ICNote", NSPredicate(format: "markedForDeletion == NO AND folder.identifier == %@", folderID))
        return try notes.map { note throws(NotesError) in try snapshot(of: note, includeText: false) }
            .filter { !deletedHere.contains($0.id) }
            .sorted { ($0.isPinned ? 1 : 0, $0.modified) > ($1.isPinned ? 1 : 0, $1.modified) }
    }

    /// Notes in any of these folders (all user folders when nil), in one fetch. Text is not loaded.
    public func notes(inFolders folderIDs: Set<String>?) throws(NotesError) -> [NoteSnapshot] {
        let store = try store()
        store.refresh()
        _ = try folders()
        let predicate = folderIDs.map { NSPredicate(format: "markedForDeletion == NO AND folder.identifier IN %@", Array($0)) }
            ?? NSPredicate(format: "markedForDeletion == NO AND folder.folderType != 1")
        return try fetch(store, "ICNote", predicate).map { note throws(NotesError) in try snapshot(of: note, includeText: false) }
            .filter { !deletedHere.contains($0.id) && !$0.isInTrash }
    }

    /// User folder paths keyed by store primary key, for the SQL-based search.
    public func folderPathsByPrimaryKey() throws(NotesError) -> [Int64: String] {
        let store = try store()
        store.refresh()
        let folders = try fetch(store, "ICFolder", NSPredicate(format: Self.visibleFolder + " AND folderType != 1 AND smartFolderQueryJSON == nil"))
        var out: [Int64: String] = [:]
        for folder in folders {
            let last = folder.objectID.uriRepresentation().lastPathComponent
            if last.hasPrefix("p"), let pk = Int64(last.dropFirst()) {
                out[pk] = self.path(of: folder)
            }
        }
        return out
    }

    /// Finds a folder by id or by path ("Parent/Child", case-insensitive).
    public func resolveFolder(_ reference: String) throws(NotesError) -> FolderSnapshot {
        let all = try folders()
        if let byID = all.first(where: { $0.id == reference }) { return byID }
        let byPrefix = all.filter { ShortID.of($0.id) == reference }
        if byPrefix.count == 1 { return byPrefix[0] }
        let wanted = reference.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
        // As written in lists ("A/B\\/C"), or with a "/" inside a name left unescaped.
        let exact = all.filter { $0.path.lowercased() == wanted || $0.names.joined(separator: "/").lowercased() == wanted }
        if exact.count == 1 { return exact[0] }
        let byLeaf = all.filter { f in
            let raw = f.names.joined(separator: "/").lowercased()
            return f.name.lowercased() == wanted || f.path.lowercased().hasSuffix("/" + wanted) || raw.hasSuffix("/" + wanted)
        }
        if byLeaf.count == 1 { return byLeaf[0] }
        if byLeaf.isEmpty { throw .notFound("folder \"\(reference)\"; call overview to see folders") }
        throw .refused("folder \"\(reference)\" is ambiguous: " + byLeaf.map { "\($0.path) (id \(ShortID.of($0.id)))" }.joined(separator: ", "))
    }

    func path(of folder: NSManagedObject) -> String {
        FolderPath.join(names(of: folder))
    }

    func names(of folder: NSManagedObject) -> [String] {
        var parts: [String] = []
        var current: NSManagedObject? = folder
        while let f = current {
            parts.insert(title(of: f), at: 0)
            current = f.value(forKey: "parent") as? NSManagedObject
        }
        if hasMultipleAccounts, let account = (folder.value(forKey: "account") as? NSManagedObject)?.value(forKey: "name") as? String {
            parts.insert(account, at: 0)
        }
        return parts
    }

    /// A folder's name as Notes shows it: the store's, unless this process renamed the folder
    /// and the store has not caught up yet.
    func title(of folder: NSManagedObject) -> String {
        let stored = folder.value(forKey: "title") as? String ?? ""
        guard let id = folder.value(forKey: "identifier") as? String, let renamed = renamedFoldersHere[id] else { return stored }
        if stored == renamed.name || Date().timeIntervalSince(renamed.at) > Self.renameOverlayLifetime {
            renamedFoldersHere[id] = nil
            return stored
        }
        return renamed.name
    }

    static func isTrash(_ folder: NSManagedObject?) -> Bool {
        (folder?.value(forKey: "folderType") as? Int) == 1
    }

    /// Shared through iCloud, directly or through a shared folder. Shared notes are read-only
    /// here: in-place edits on them are not verified.
    /// 当验证过共享笔记的原地修改与同步后，放开共享笔记的写入。
    /// Shared with the current user without edit permission (directly or through a folder).
    static func isSharedReadOnly(_ note: NSManagedObject) -> Bool {
        (note.value(forKey: "isSharedReadOnly") as? Bool) == true
    }

    static func isShared(_ note: NSManagedObject) -> Bool {
        if note.value(forKey: "serverShareData") != nil { return true }
        var folder = note.value(forKey: "folder") as? NSManagedObject
        while let f = folder {
            if f.value(forKey: "serverShareData") != nil { return true }
            folder = f.value(forKey: "parent") as? NSManagedObject
        }
        return false
    }

    func fetch(_ store: ReadStore, _ entity: String, _ predicate: NSPredicate) throws(NotesError) -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = predicate
        do {
            return try store.context.fetch(request)
        } catch {
            throw .failed("listing \(entity) failed: \(error.localizedDescription)")
        }
    }

    // MARK: Deleting

    /// Moves a note to Recently Deleted through Notes itself. Both checks ask Notes.app, not
    /// the store: the store can lag Notes.app by minutes while it is in the background, and
    /// deleting a note that is already in Recently Deleted erases it for good. `exists note id`
    /// is no help either; it stays true for notes in Recently Deleted (verified 2026-10-12).
    public func delete(id: String) async throws(NotesError) {
        let snapshot = try note(id: id)
        if snapshot.isInTrash { throw .refused("the note is already in Recently Deleted; deleting it again would erase it for good") }
        // Deleting a note you share removes it for every participant, so that stays a choice
        // made in Notes. 当能区分"仅自己移除"与"为所有人删除"并让用户确认时，再开放。
        if snapshot.isShared { throw .refused("shared notes are not deleted here: deleting a shared note can remove it for everyone it is shared with; delete it in Notes") }
        if let prefix = writeGuardTitlePrefix, !snapshot.title.hasPrefix(prefix) {
            throw .refused("refusing to delete: only notes titled \"\(prefix)…\" may be changed while the write guard is on")
        }
        let target = try syncTarget(id: id)
        let trash = try trashFolderURI(forNote: id)
        func inTrash() throws(NotesError) -> Bool {
            try AppleScript.run("tell application \"Notes\" to (id of notes of folder id \"\(trash)\") contains \"\(target.noteURI)\"") == "true"
        }
        if try inTrash() { throw .refused("Notes already has this note in Recently Deleted; deleting it again would erase it for good") }
        try AppleScript.run("tell application \"Notes\" to delete note id \"\(target.noteURI)\"")
        for _ in 0..<20 {
            if try inTrash() {
                deletedHere.insert(id)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw .failed("Notes did not confirm the delete within 5 seconds; check Recently Deleted before trying again")
    }

    /// The Recently Deleted folder of the note's account, as an AppleScript id.
    private func trashFolderURI(forNote id: String) throws(NotesError) -> String {
        let note = try store().note(id: id)
        return try trashFolderURI(sameAccountAs: note.value(forKey: "folder") as? NSManagedObject)
    }

    /// The Recently Deleted folder of a folder's account, as an AppleScript id. Accounts are
    /// compared by identifier: the related objects are not always the same instance.
    func trashFolderURI(sameAccountAs folder: NSManagedObject?) throws(NotesError) -> String {
        let account = folder.flatMap(Self.accountID(of:))
        let trash = try fetch(try store(), "ICFolder", NSPredicate(format: "folderType == 1 AND markedForDeletion == NO"))
            .first { account == nil || Self.accountID(of: $0) == account }
        guard let trash else { throw .failed("cannot find the Recently Deleted folder") }
        return trash.objectID.uriRepresentation().absoluteString
    }
}
