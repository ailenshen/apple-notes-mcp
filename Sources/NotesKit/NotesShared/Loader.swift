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
        "ICNote": ["identifier", "title", "folder", "modificationDate", "markedForDeletion", "isPasswordProtected"],
        "ICInlineAttachment": ["identifier", "altText", "tokenContentIdentifier"],
        "ICAttachment": ["identifier"],
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
    @MainActor private static var sharedContextStarted = false

    /// Starts Notes' shared note context once per process. Writes need it, and so does
    /// reading table cells: without it ICTable reports 0×0 even in the read-only store.
    /// 当能不启动共享上下文就读出表格（或有官方 API）时，读路径去掉这一步，保持读路径不碰 Notes 内部机制。
    @MainActor static func startSharedContext() throws(NotesError) {
        try load()
        if sharedContextStarted { return }
        let noteContext = try cls("ICNoteContext")
        try call(noteContext, "startSharedContextWithOptions:") {
            try NSShim.send(noteContext, selector: "startSharedContextWithOptions:", unsignedInteger: 0)
        }
        sharedContextStarted = true
    }

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
