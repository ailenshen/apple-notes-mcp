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

    /// While set, writes only touch notes whose title starts with this prefix. Development
    /// builds and the checks set it to "MCP Test " so real notes are never written by accident.
    public var writeGuardTitlePrefix: String?

    public init(writeGuardTitlePrefix: String? = nil) {
        self.writeGuardTitlePrefix = writeGuardTitlePrefix
    }

    /// Opened on first use, so the server still answers discovery when access is missing.
    private func store() throws(NotesError) -> ReadStore {
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

    public func cloudState(id: String) throws(NotesError) -> CloudState {
        let store = try store()
        store.refresh()
        guard let state = try send(store.note(id: id), "cloudState") as? NSObject else {
            throw .frameworkChanged("ICNote has no cloudState")
        }
        return CloudState(
            local: (state.value(forKey: "currentLocalVersion") as? Int) ?? 0,
            synced: (state.value(forKey: "latestVersionSyncedToCloud") as? Int) ?? 0)
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
        let target = try transform(currentBlocks)
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
            throw error
        }
        return try verify(id: id, target: target)
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
        if (note.value(forKey: "isPasswordProtected") as? Bool) == true { throw .refused("locked notes cannot be changed") }
        if (note.value(forKey: "markedForDeletion") as? Bool) == true { throw .refused("this note is deleted") }
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

    public static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AppleNotesMCP", isDirectory: true)

    /// A short content hash of the note as Markdown. Passed back by the caller on write so a
    /// note edited in between is not overwritten. Content-only on purpose: modification
    /// dates in the store lag Notes.app and are not updated by in-place edits.
    public static func version(of blocks: [Block]) -> String {
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

    public func modificationDate(id: String) throws(NotesError) -> Date { try note(id: id).modified }

    /// Debug hook for the spike gate: sends a selector that does not exist, to prove the
    /// shim turns the Objective-C exception into an error instead of killing the process.
    public func provokeObjCException() throws(NotesError) {
        _ = try send(NSObject(), "spikeSelectorThatDoesNotExist")
    }

    private func snapshot(of note: NSManagedObject) throws(NotesError) -> NoteSnapshot {
        let text: String
        if let mergeable = try send(note, "mergeableString"),
            let attributed = try send(mergeable, "attributedString") as? NSAttributedString
        {
            text = attributed.string
        } else {
            text = ""
        }
        let folder = (note.value(forKey: "folder") as? NSObject)?.value(forKey: "title") as? String
        return NoteSnapshot(
            id: note.value(forKey: "identifier") as? String ?? "",
            title: note.value(forKey: "title") as? String ?? "",
            folder: folder ?? "",
            modified: note.value(forKey: "modificationDate") as? Date ?? .distantPast,
            text: text)
    }
}
