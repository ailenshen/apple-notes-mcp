import CoreData
import Foundation
import NotesSharedShim

/// The only public door into the Notes data layer. Everything behind it runs on the main
/// actor, and only Sendable snapshots come out, so no Core Data object crosses a boundary.
/// 当 Apple 开放官方 Notes API 时，只需重新实现本类与 SyncCoordinator，快照类型和工具层不变。
@MainActor
public final class NotesRepository {
    private var readStore: ReadStore?
    private var writeContext: WriteContext?

    public init() {}

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

    /// Spike gate G2: appends one paragraph in place to a test note, then reads it back
    /// through the read-only store. Refuses any note whose title does not start with "MCP Test ".
    public func spikeAppend(id: String, text: String) throws(NotesError) -> Bool {
        let writer = try writer()
        let note = try writer.note(id: id)
        guard (note.value(forKey: "title") as? String)?.hasPrefix("MCP Test ") == true else {
            throw .refused("refusing to write: spike writes only touch notes titled \"MCP Test …\"")
        }
        guard let document = try send(note, "document"), let mergeable = try send(document, "mergeableString"),
            let current = try send(note, "attributedString") as? NSAttributedString
        else { throw .frameworkChanged("note has no editable document") }
        let length = current.length
        let insertion = "\n" + text
        let inserted = (insertion as NSString).length
        // Copy every attribute of the last character except attachments; copying only the
        // paragraph style drops font attributes and the new text looks different.
        var attributes = length > 0 ? current.attributes(at: length - 1, effectiveRange: nil) : [:]
        attributes[NSAttributedString.Key("NSAttachment")] = nil
        try call(note, "beginEditing") { try NSShim.send(note, selector: "beginEditing") }
        try call(mergeable, "insertString:atIndex:") {
            try NSShim.send(mergeable, selector: "insertString:atIndex:", string: insertion, index: UInt(length))
        }
        try call(mergeable, "setAttributes:range:") {
            try NSShim.send(
                mergeable, selector: "setAttributes:range:", attributes: attributes,
                range: NSRange(location: length, length: inserted))
        }
        try call(note, "edited:range:changeInLength:") {
            try NSShim.send(
                note, selector: "edited:range:changeInLength:", unsignedInteger: 1,
                range: NSRange(location: 0, length: length + inserted), integer: inserted)
        }
        try call(note, "endEditing") { try NSShim.send(note, selector: "endEditing") }
        try call(note, "saveNoteData") { try NSShim.send(note, selector: "saveNoteData") }
        try writer.save()
        return try self.note(id: id).text.hasSuffix(insertion)
    }

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
