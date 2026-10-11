import CoreData
import Foundation
import NotesSharedShim

/// Notes' own read-write Core Data context (ICNoteContext), created on the first write.
@MainActor
final class WriteContext {
    let context: NSManagedObjectContext

    init() throws(NotesError) {
        try Loader.startSharedContext()
        let noteContext = try Loader.cls("ICNoteContext")
        guard let shared = try send(noteContext, "sharedContext"),
            let container = try send(shared, "persistentContainer"),
            let viewContext = try send(container, "viewContext") as? NSManagedObjectContext
        else { throw .frameworkChanged("ICNoteContext gave no view context") }
        context = viewContext
    }

    func note(id: String) throws(NotesError) -> NSManagedObject {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ICNote")
        request.predicate = NSPredicate(format: "identifier == %@", id)
        request.fetchLimit = 1
        let found: NSManagedObject?
        do {
            found = try context.fetch(request).first
        } catch {
            throw .failed("fetch failed: \(error.localizedDescription)")
        }
        guard let found else { throw .notFound(id) }
        return found
    }

    func folder(id: String) throws(NotesError) -> NSManagedObject {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ICFolder")
        request.predicate = NSPredicate(format: "identifier == %@", id)
        request.fetchLimit = 1
        let found: NSManagedObject?
        do {
            found = try context.fetch(request).first
        } catch {
            throw .failed("fetching folder failed: \(error.localizedDescription)")
        }
        guard let found else { throw .notFound("folder \(id)") }
        return found
    }

    func save() throws(NotesError) {
        do {
            try context.save()
        } catch {
            throw .failed("saving the note failed: \(error.localizedDescription)")
        }
    }
}

/// Runs a typed shim send and maps its NSError to NotesError.
func call(_ target: AnyObject, _ selector: String, _ body: () throws -> Void) throws(NotesError) {
    do {
        try body()
    } catch {
        throw .frameworkChanged("\(selector) failed: \(error.localizedDescription)")
    }
}
