import CoreData
import Foundation

/// The only public door into the Notes data layer. Everything behind it runs on the main
/// actor, and only Sendable snapshots come out, so no Core Data object crosses a boundary.
/// 当 Apple 开放官方 Notes API 时，只需重新实现本类与 SyncCoordinator，快照类型和工具层不变。
@MainActor
public final class NotesRepository {
    private var readStore: ReadStore?

    public init() {}

    /// Opened on first use, so the server still answers discovery when access is missing.
    private func store() throws(NotesError) -> ReadStore {
        if let readStore { return readStore }
        let opened = try ReadStore()
        readStore = opened
        return opened
    }

    public func note(id: String) throws(NotesError) -> NoteSnapshot {
        let store = try store()
        store.refresh()
        return try snapshot(of: store.note(id: id))
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
