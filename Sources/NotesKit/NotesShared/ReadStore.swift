import CoreData
import Foundation

/// Read-only view of NoteStore.sqlite through Notes' own Core Data model.
/// Opened with NSReadOnlyPersistentStoreOption, so this path can never write.
@MainActor
final class ReadStore {
    static let storeURL = URL(
        fileURLWithPath: NSHomeDirectory() + "/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")

    let context: NSManagedObjectContext

    init() throws(NotesError) {
        try Loader.load()
        let container = try Loader.cls("ICPersistentContainer")
        guard let model = try send(container, "managedObjectModel") as? NSManagedObjectModel,
            var options = try send(container, "standardStoreOptions") as? [String: Any]
        else { throw .frameworkChanged("ICPersistentContainer returned no model or store options") }
        try Loader.check(model: model)
        options[NSMigratePersistentStoresAutomaticallyOption] = false
        options[NSInferMappingModelAutomaticallyOption] = false
        options[NSReadOnlyPersistentStoreOption] = true
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store: NSPersistentStore
        do {
            store = try coordinator.addPersistentStore(
                type: .sqlite, configuration: nil, at: Self.storeURL, options: options)
        } catch {
            throw .noAccess("\(error.localizedDescription) (grant Full Disk Access)")
        }
        guard store.isReadOnly else { throw .failed("store opened read-write; refusing to continue") }
        context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
    }

    /// Drops cached objects so the next fetch sees what Notes (or our writer) saved since.
    func refresh() {
        context.reset()
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
}
