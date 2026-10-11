import CoreData
import Foundation
import NotesSharedShim

// Loads Apple's private NotesShared framework at runtime. Linking it directly is refused
// ("not an allowed client"), so every class is looked up by name.
// 当 Apple 开放官方 Notes API 时，整个 NotesShared 目录重构为官方 API，删除 dlopen 与私有类查找。

enum Loader {
    static let frameworkPath = "/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared"

    /// Classes and selectors this build relies on. Checked before first use so a macOS
    /// update that changes them yields a clear error instead of a crash.
    static let required: [(class: String, classMethods: [String], instanceMethods: [String])] = [
        ("ICPersistentContainer", ["managedObjectModel", "standardStoreOptions"], []),
        ("ICNote", [], ["mergeableString"]),
    ]

    /// Core Data properties are generated at runtime, so they are checked against the
    /// model's entities rather than with respondsToSelector.
    static let requiredProperties: [String: [String]] = [
        "ICNote": ["identifier", "title", "folder", "modificationDate"],
        "ICFolder": ["identifier", "title"],
    ]

    static func check(model: NSManagedObjectModel) throws(NotesError) {
        var missing: [String] = []
        for (entity, keys) in requiredProperties.sorted(by: { $0.key < $1.key }) {
            guard let description = model.entitiesByName[entity] else {
                missing.append(entity)
                continue
            }
            missing += keys.filter { description.propertiesByName[$0] == nil }.map { "\(entity).\($0)" }
        }
        guard missing.isEmpty else {
            throw .frameworkChanged("Notes data model changed in this macOS version; missing " + missing.joined(separator: ", "))
        }
    }

    @MainActor private static var loaded = false

    @MainActor static func load() throws(NotesError) {
        if loaded { return }
        guard dlopen(frameworkPath, RTLD_NOW) != nil else {
            throw .frameworkChanged("cannot load NotesShared: \(String(cString: dlerror()))")
        }
        var missing: [String] = []
        for entry in required {
            guard let cls = NSClassFromString(entry.class) else {
                missing.append(entry.class)
                continue
            }
            for sel in entry.classMethods where !(cls as AnyObject).responds(to: Selector(sel)) {
                missing.append("+[\(entry.class) \(sel)]")
            }
            for sel in entry.instanceMethods where !cls.instancesRespond(to: Selector(sel)) {
                missing.append("-[\(entry.class) \(sel)]")
            }
        }
        guard missing.isEmpty else {
            throw .frameworkChanged("NotesShared changed in this macOS version; missing " + missing.joined(separator: ", "))
        }
        loaded = true
    }

    static func cls(_ name: String) throws(NotesError) -> AnyObject {
        guard let c = NSClassFromString(name) else { throw .frameworkChanged("missing class \(name)") }
        return c
    }
}

/// Sends a no-argument message that returns an object, catching Objective-C exceptions.
/// Only for selectors whose return type is an object; scalars go through KVC or the shim.
func send(_ target: AnyObject, _ selector: String) throws(NotesError) -> AnyObject? {
    var result: AnyObject?
    do {
        try NSShim.perform {
            result = target.perform(Selector(selector))?.takeUnretainedValue()
        }
    } catch {
        throw .frameworkChanged("\(selector) failed: \(error.localizedDescription)")
    }
    return result
}
