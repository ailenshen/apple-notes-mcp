import CoreData
import Foundation

// Moving notes and managing folders, through Notes' AppleScript (verified 2026-10-12):
// - `move note … to folder …` keeps the note's id and uploads it (it is also the sync nudge).
// - `make new folder`, `set name of folder` and `delete folder` (on an empty folder) behave.
// - `move folder` must never be used: it reports success, but Notes deletes the folder.
// The store can lag Notes by minutes while Notes is in the background (App Nap), so results are
// checked against Notes' own view: `exists folder id`, `name of folder id`, and the account's
// folder list. One exception: `folders of folder X` keeps listing subfolders Notes deleted, so
// emptiness is judged from the store for subfolders.
// 当 Apple 开放官方 Notes API（含文件夹移动）时，改用官方接口，并补上移动文件夹。

public struct MoveOutcome: Sendable {
    public var title: String
    public var from: String
    public var to: String
    public var restored: Bool
}

extension NotesRepository {
    // MARK: Moving notes

    /// Moves a note to another folder of the same account. A note in Recently Deleted is restored
    /// this way. Moving into or out of a shared folder changes who can see the note, so it
    /// needs `allowShared`.
    public func move(id: String, toFolder reference: String, allowShared: Bool) async throws(NotesError) -> MoveOutcome {
        // Resolve the folder first: resolving refreshes the store, which would invalidate a
        // note fetched before it.
        let target = try folderTarget(reference)
        let store = try store()
        let note = try store.note(id: id)
        let title = note.value(forKey: "title") as? String ?? ""
        if let prefix = writeGuardTitlePrefix, !title.hasPrefix(prefix) {
            throw .refused("refusing to move: only notes titled \"\(prefix)…\" may be changed while the write guard is on")
        }
        if (note.value(forKey: "markedForDeletion") as? Bool) == true { throw .refused("this note is deleted") }
        let noteURI = note.objectID.uriRepresentation().absoluteString
        let source = note.value(forKey: "folder") as? NSManagedObject
        let restoring = try isInTrashInNotes(noteURI: noteURI, note: note)
        if !restoring, let source, source.objectID.uriRepresentation().absoluteString == target.uri {
            throw .refused("the note is already in \(target.path)")
        }
        if !restoring, let source, let from = Self.accountID(of: source), let to = target.accountID, from != to {
            throw .refused("notes can only be moved within the same account; Notes would copy it to a new id")
        }
        let sharedSource = !restoring && (source.map(Self.isSharedFolder) ?? false)
        if sharedSource || target.isShared, !allowShared {
            throw .refused("this move changes who can see the note (a shared folder is involved); ask the user, then pass allow_shared: true")
        }
        try AppleScript.run("tell application \"Notes\" to move note id \"\(noteURI)\" to folder id \"\(target.uri)\"")
        for _ in 0..<20 {
            if try AppleScript.run("tell application \"Notes\" to (id of notes of folder id \"\(target.uri)\") contains \"\(noteURI)\"") == "true" {
                deletedHere.remove(id)
                let from = restoring ? "Recently Deleted" : source.map { Self.path(of: $0, multipleAccounts: hasMultipleAccounts) } ?? "?"
                return MoveOutcome(title: title, from: from, to: target.path, restored: restoring)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw .failed("Notes did not confirm the move within 5 seconds; check the note in Notes before trying again")
    }

    /// Whether Notes has the note in Recently Deleted, by Notes' own view (the store can lag).
    private func isInTrashInNotes(noteURI: String, note: NSManagedObject) throws(NotesError) -> Bool {
        if deletedHere.contains(note.value(forKey: "identifier") as? String ?? "") || Self.isTrash(note.value(forKey: "folder") as? NSManagedObject) { return true }
        let store = try store()
        let trashes = try fetch(store, "ICFolder", NSPredicate(format: "folderType == 1 AND markedForDeletion == NO"))
        for trash in trashes {
            let uri = trash.objectID.uriRepresentation().absoluteString
            if try AppleScript.run("tell application \"Notes\" to (id of notes of folder id \"\(uri)\") contains \"\(noteURI)\"") == "true" { return true }
        }
        return false
    }

    // MARK: Folders

    /// Creates a folder from a path such as "Projects/Ideas": the parent must exist (or be the
    /// account, for a top-level folder). Returns the new folder's path.
    public func createFolder(path: String) async throws(NotesError) -> String {
        let parts = FolderPath.split(path)
        guard let name = parts.last else { throw .refused("give the new folder's path, such as \"Projects/Ideas\"") }
        try checkFolderName(name)
        if let prefix = writeGuardTitlePrefix, !name.hasPrefix(prefix) {
            throw .refused("refusing to create: folder names must start with \"\(prefix)\" while the write guard is on")
        }
        let store = try store()
        store.refresh()
        let container: String
        let siblings: [NSManagedObject]
        if parts.count > 1 {
            let parent = try folderObject(FolderPath.join(Array(parts.dropLast())), in: store)
            if Self.isSharedFolder(parent) { throw .refused("folders are not created inside shared folders here") }
            container = "folder id \"\(parent.objectID.uriRepresentation().absoluteString)\""
            siblings = try children(of: parent, in: store)
        } else {
            guard let account = try defaultAccount(in: store) else { throw .failed("no Notes account found") }
            container = "account id \"\(account.objectID.uriRepresentation().absoluteString)\""
            siblings = try fetch(store, "ICFolder", NSPredicate(format: Self.visibleFolder + " AND parent == nil AND account == %@ AND folderType == 0", account))
        }
        if siblings.contains(where: { ($0.value(forKey: "title") as? String)?.lowercased() == name.lowercased() }) {
            throw .refused("a folder named \"\(name)\" already exists there")
        }
        guard let created = try AppleScript.run("tell application \"Notes\" to get id of (make new folder at \(container) with properties {name:\(AppleScript.quoted(name))})") else {
            throw .failed("Notes did not return the new folder")
        }
        try await waitForNotes("creating the folder") { () throws(NotesError) in
            try AppleScript.run("tell application \"Notes\" to name of folder id \"\(created)\"") == name
        }
        return FolderPath.join(parts)
    }

    public func renameFolder(_ reference: String, to name: String, allowShared: Bool) async throws(NotesError) -> (old: String, new: String) {
        try checkFolderName(name)
        let store = try store()
        store.refresh()
        let folder = try folderObject(reference, in: store)
        try guardChangeable(folder, allowShared: allowShared)
        let old = Self.path(of: folder, multipleAccounts: hasMultipleAccounts)
        if let prefix = writeGuardTitlePrefix, !name.hasPrefix(prefix) {
            throw .refused("refusing to rename: folder names must start with \"\(prefix)\" while the write guard is on")
        }
        let siblings: [NSManagedObject]
        if let parent = folder.value(forKey: "parent") as? NSManagedObject {
            siblings = try children(of: parent, in: store)
        } else {
            siblings = try fetch(store, "ICFolder", NSPredicate(format: Self.visibleFolder + " AND parent == nil AND account == %@ AND folderType == 0",
                                                                (folder.value(forKey: "account") as? NSManagedObject) ?? NSNull()))
        }
        if siblings.contains(where: { $0 != folder && ($0.value(forKey: "title") as? String)?.lowercased() == name.lowercased() }) {
            throw .refused("a folder named \"\(name)\" already exists there")
        }
        let uri = folder.objectID.uriRepresentation().absoluteString
        try AppleScript.run("tell application \"Notes\" to set name of folder id \"\(uri)\" to \(AppleScript.quoted(name))")
        try await waitForNotes("renaming the folder") { () throws(NotesError) in
            try AppleScript.run("tell application \"Notes\" to name of folder id \"\(uri)\"") == name
        }
        let new = FolderPath.join(Array(FolderPath.split(old).dropLast()) + [name])
        return (old, new)
    }

    /// Deletes an empty folder. A folder that still holds notes or subfolders is refused, so
    /// a single call can never send many notes to Recently Deleted.
    public func deleteFolder(_ reference: String) async throws(NotesError) -> String {
        let store = try store()
        store.refresh()
        let folder = try folderObject(reference, in: store)
        try guardChangeable(folder, allowShared: false)
        let path = Self.path(of: folder, multipleAccounts: hasMultipleAccounts)
        let uri = folder.objectID.uriRepresentation().absoluteString
        // Notes' own view decides: the store can lag behind notes just moved in or out.
        let liveNotes = Int(try AppleScript.run("tell application \"Notes\" to count notes of folder id \"\(uri)\"") ?? "") ?? 0
        // Subfolders from both views, kept only if Notes says they exist: the store can still
        // list one just deleted, and `folders of folder` keeps listing folders Notes deleted.
        let listed = try AppleScript.runList("tell application \"Notes\" to get id of folders of folder id \"\(uri)\"")
        let candidates = Set(listed + (try children(of: folder, in: store)).map { $0.objectID.uriRepresentation().absoluteString })
        var subfolders = 0
        for candidate in candidates where try AppleScript.run("tell application \"Notes\" to exists folder id \"\(candidate)\"") == "true" {
            subfolders += 1
        }
        if subfolders > 0 || liveNotes > 0 {
            throw .refused("\(path) is not empty (\(liveNotes) notes, \(subfolders) subfolders); move them out first, or delete the folder in Notes")
        }
        try AppleScript.run("tell application \"Notes\" to delete folder id \"\(uri)\"")
        let id = folder.value(forKey: "identifier") as? String ?? ""
        try await waitForNotes("deleting the folder") { () throws(NotesError) in
            try AppleScript.run("tell application \"Notes\" to exists folder id \"\(uri)\"") == "false"
        }
        deletedFoldersHere.insert(id)
        return path
    }

    /// Deletes a folder with everything in it, for archiving (2026-10-14). Every note goes to
    /// Recently Deleted, then the subfolders and the folder itself are deleted, deepest first.
    /// `expectedNotes` is the note count the caller saw (overview or export), so a call can
    /// never remove more than was looked at.
    ///
    /// Everything is checked before the first change. There must be no shared or locked notes
    /// and no shared or smart folders. Notes' own view must also agree with the store, which can
    /// lag by minutes, so only notes both of them show get deleted.
    ///
    /// Notes are deleted with one `delete note id` each, sent in a few scripts. Recently
    /// Deleted is read once before (deleting a note already there erases it for good) and
    /// polled after. Folders then go through `deleteFolder`, which refuses any folder Notes
    /// does not see as empty. `delete folder` is never sent for a folder that still holds
    /// anything, since what it does then is unverified. Nothing is retried.
    /// 当 Apple 开放官方 API（能整体删除文件夹并确认笔记进入"最近删除"）时，改用官方接口。
    public func deleteFolderTree(_ reference: String, expectedNotes: Int) async throws(NotesError) -> (path: String, notes: Int, folders: Int) {
        let store = try store()
        store.refresh()
        let root = try folderObject(reference, in: store)
        try guardChangeable(root, allowShared: false)
        let rootPath = Self.path(of: root, multipleAccounts: hasMultipleAccounts)
        let trash = try trashFolderURI(sameAccountAs: root)
        // The tree in breadth-first order, so reversed it lists every child before its parent.
        var tree = [root]
        var next = 0
        while next < tree.count {
            tree += try children(of: tree[next], in: store)
            next += 1
        }
        var problems: [String] = []
        var targets: [(id: String, uri: String)] = []
        for folder in tree {
            let path = Self.path(of: folder, multipleAccounts: hasMultipleAccounts)
            let uri = folder.objectID.uriRepresentation().absoluteString
            if folder.value(forKey: "smartFolderQueryJSON") != nil { problems.append("\(path) is a smart folder") }
            if folder != root, folder.value(forKey: "serverShareData") != nil { problems.append("\(path) is shared") }
            if let prefix = writeGuardTitlePrefix, (folder.value(forKey: "title") as? String)?.hasPrefix(prefix) != true {
                problems.append("\(path) is not named \"\(prefix)…\" (write guard)")
            }
            let notes = try fetch(store, "ICNote", NSPredicate(format: "markedForDeletion == NO AND folder == %@", folder))
                .filter { !deletedHere.contains($0.value(forKey: "identifier") as? String ?? "") }
            for note in notes {
                let title = note.value(forKey: "title") as? String ?? ""
                let label = "\"\(title)\" in \(path)"
                if (note.value(forKey: "isPasswordProtected") as? Bool) == true { problems.append("\(label) is locked") }
                if Self.isShared(note) { problems.append("\(label) is shared") }
                if let prefix = writeGuardTitlePrefix, !title.hasPrefix(prefix) { problems.append("\(label) is not titled \"\(prefix)…\" (write guard)") }
                targets.append((note.value(forKey: "identifier") as? String ?? "", note.objectID.uriRepresentation().absoluteString))
            }
            // Only what Notes and the store both show is deleted; while they differ, Notes has
            // changes it has not saved yet.
            let liveNotes = Set(try AppleScript.runList("tell application \"Notes\" to get id of notes of folder id \"\(uri)\""))
            var liveFolders: Set<String> = []
            for candidate in try AppleScript.runList("tell application \"Notes\" to get id of folders of folder id \"\(uri)\"")
            where try AppleScript.run("tell application \"Notes\" to exists folder id \"\(candidate)\"") == "true" {
                liveFolders.insert(candidate)
            }
            let storedFolders = Set(try children(of: folder, in: store).map { $0.objectID.uriRepresentation().absoluteString })
            if liveNotes != Set(notes.map { $0.objectID.uriRepresentation().absoluteString }) || liveFolders != storedFolders {
                throw .refused("Notes has changes in \(path) that it has not saved yet; try again in a minute. Nothing was deleted.")
            }
        }
        if !problems.isEmpty {
            let shown = problems.prefix(10).joined(separator: "; ") + (problems.count > 10 ? "; and \(problems.count - 10) more" : "")
            throw .refused("\(rootPath) cannot be deleted with its contents: \(shown). Move these out or change them in Notes first. Nothing was deleted.")
        }
        guard targets.count == expectedNotes else {
            throw .refused("\(rootPath) does not hold expected_notes notes (subfolders included). Look at it again with overview, then pass the count it shows. Nothing was deleted.")
        }
        // Captured now: deleteFolder refreshes the store, which turns these objects into faults.
        let folderIDs = tree.reversed().map { $0.value(forKey: "identifier") as? String ?? "" }

        func trashed() throws(NotesError) -> Set<String> {
            Set(try AppleScript.runList("tell application \"Notes\" to get id of notes of folder id \"\(trash)\""))
        }
        let wanted = Set(targets.map(\.uri))
        if !wanted.isDisjoint(with: try trashed()) {
            throw .refused("Notes already has some of these notes in Recently Deleted; deleting them again would erase them for good. Nothing was deleted.")
        }
        var sendError: NotesError?
        for start in stride(from: 0, to: targets.count, by: 50) {
            let lines = targets[start..<min(start + 50, targets.count)].map { "delete note id \"\($0.uri)\"" }
            do throws(NotesError) {
                try AppleScript.run("tell application \"Notes\"\n" + lines.joined(separator: "\n") + "\nend tell")
            } catch {
                sendError = error
                break
            }
        }
        // Notes moves them quickly; the wait grows with the count in case it is busy.
        let clock = ContinuousClock()
        let deadline = clock.now + (sendError == nil ? .seconds(5) + .milliseconds(100 * targets.count) : .seconds(5))
        var moved: Set<String> = []
        while !wanted.isEmpty {
            if let now = try? trashed() { moved = wanted.intersection(now) }
            if moved.count == wanted.count || clock.now >= deadline { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        deletedHere.formUnion(targets.filter { moved.contains($0.uri) }.map(\.id))
        if moved.count < wanted.count {
            throw .failed("moved \(moved.count) of \(wanted.count) notes to Recently Deleted; "
                + (sendError.map { "Notes reported: \($0). " } ?? "Notes did not confirm the rest in time. ")
                + "No folders were deleted. Check \(rootPath) in Notes before trying again.")
        }
        var deleted = 0
        for id in folderIDs {
            do throws(NotesError) {
                _ = try await deleteFolder(id)
                deleted += 1
            } catch {
                throw .failed("moved all \(wanted.count) notes to Recently Deleted and deleted \(deleted) of \(folderIDs.count) folders, then: \(error). Check \(rootPath) in Notes before trying again.")
            }
        }
        return (rootPath, wanted.count, deleted)
    }

    // MARK: Helpers

    /// A user folder by id or path, from the store.
    func folderObject(_ reference: String, in store: ReadStore) throws(NotesError) -> NSManagedObject {
        let resolved = try resolveFolder(reference)
        guard let folder = try fetch(store, "ICFolder", NSPredicate(format: "identifier == %@", resolved.id)).first else {
            throw .notFound("folder \"\(reference)\"")
        }
        return folder
    }

    /// Subfolders from the store, leaving out those this process deleted (the store lags).
    private func children(of folder: NSManagedObject, in store: ReadStore) throws(NotesError) -> [NSManagedObject] {
        try fetch(store, "ICFolder", NSPredicate(format: Self.visibleFolder + " AND parent == %@", folder))
            .filter { !deletedFoldersHere.contains($0.value(forKey: "identifier") as? String ?? "") }
    }

    private func defaultAccount(in store: ReadStore) throws(NotesError) -> NSManagedObject? {
        let defaultFolder = try fetch(store, "ICFolder", NSPredicate(format: "identifier == %@", "DefaultFolder-CloudKit")).first
        if let account = defaultFolder?.value(forKey: "account") as? NSManagedObject { return account }
        return try fetch(store, "ICAccount", NSPredicate(format: "markedForDeletion == NO")).first
    }

    /// Polls Notes' view until `done` holds (up to 5 s).
    private func waitForNotes(_ what: String, _ done: () throws(NotesError) -> Bool) async throws(NotesError) {
        for _ in 0..<20 {
            if try done() { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw .failed("Notes did not confirm \(what) within 5 seconds; check it in Notes before trying again")
    }

    /// A destination folder: from the store, or, for a folder Notes has not saved to the store
    /// yet (just created), from Notes' view by path.
    struct FolderTarget {
        var uri: String
        var path: String
        var accountID: String?
        var isShared: Bool
    }

    func folderTarget(_ reference: String) throws(NotesError) -> FolderTarget {
        let store = try store()
        do throws(NotesError) {
            let folder = try folderObject(reference, in: store)
            if Self.isTrash(folder) { throw .refused("use delete_note to move a note to Recently Deleted") }
            return FolderTarget(uri: folder.objectID.uriRepresentation().absoluteString, path: Self.path(of: folder, multipleAccounts: hasMultipleAccounts),
                                accountID: Self.accountID(of: folder), isShared: Self.isSharedFolder(folder))
        } catch .notFound {
            let parts = FolderPath.split(reference)
            guard !parts.isEmpty else { throw .notFound("folder \"\(reference)\"") }
            let specifier = parts.reversed().map { "folder \(AppleScript.quoted($0))" }.joined(separator: " of ") + " of default account"
            guard let uri = try? AppleScript.run("tell application \"Notes\" to get id of \(specifier)") else {
                throw .notFound("folder \"\(reference)\"; call overview to see folder paths")
            }
            // Only a folder Notes just created gets here; its parent (in the store) decides sharing.
            let parentShared = parts.count > 1 ? ((try? folderObject(FolderPath.join(Array(parts.dropLast())), in: store)).map(Self.isSharedFolder) ?? false) : false
            return FolderTarget(uri: uri, path: FolderPath.join(parts), accountID: nil, isShared: parentShared)
        }
    }

    private func checkFolderName(_ name: String) throws(NotesError) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw .refused("the folder name is empty") }
        guard !name.contains("/") else { throw .refused("folder names cannot contain \"/\", which separates folders in paths") }
        guard name.count <= 100 else { throw .refused("folder names are limited to 100 characters here") }
    }

    private func guardChangeable(_ folder: NSManagedObject, allowShared: Bool) throws(NotesError) {
        if folder.value(forKey: "identifier") as? String == "DefaultFolder-CloudKit" { throw .refused("the default Notes folder cannot be renamed or deleted") }
        if Self.isTrash(folder) { throw .refused("Recently Deleted cannot be changed") }
        if Self.isSharedFolder(folder), !allowShared {
            throw .refused("this folder is shared; renaming it changes it for everyone. Ask the user, then pass allow_shared: true (shared folders are never deleted here)")
        }
        if let prefix = writeGuardTitlePrefix, (folder.value(forKey: "title") as? String)?.hasPrefix(prefix) != true {
            throw .refused("refusing to change folder: only folders named \"\(prefix)…\" may be changed while the write guard is on")
        }
    }

    /// The account a folder belongs to, by identifier (the related objects are not always the same instance).
    static func accountID(of folder: NSManagedObject) -> String? {
        (folder.value(forKey: "account") as? NSObject)?.value(forKey: "identifier") as? String
    }

    /// Shared through iCloud, directly or through a parent folder.
    static func isSharedFolder(_ folder: NSManagedObject) -> Bool {
        var current: NSManagedObject? = folder
        while let f = current {
            if f.value(forKey: "serverShareData") != nil { return true }
            current = f.value(forKey: "parent") as? NSManagedObject
        }
        return false
    }
}
