import Foundation

/// A plain-value copy of a note. Core Data objects never leave NotesShared/; callers get these.
public struct NoteSnapshot: Sendable, Equatable {
    public var id: String
    public var title: String
    public var folder: String
    public var modified: Date
    public var text: String
}

public enum NotesError: Error, Sendable, Equatable, CustomStringConvertible {
    case noAccess(String)
    case frameworkChanged(String)
    case notFound(String)
    case refused(String)
    case conflict(String)
    case failed(String)

    public var description: String {
        switch self {
        case .noAccess(let m): "No access to Apple Notes data: \(m)"
        case .frameworkChanged(let m): m
        case .notFound(let id): "No note with id \(id)"
        case .refused(let m): m
        case .conflict(let m): m
        case .failed(let m): m
        }
    }
}

/// Upload state of one note: local edits are on iCloud once `synced` catches up with `local`.
public struct CloudState: Sendable, Equatable {
    public var local: Int
    public var synced: Int
    public var isSynced: Bool { synced >= local }
}

/// AppleScript ids (x-coredata URIs) of a note and its folder, used to nudge the upload.
struct SyncTarget: Sendable {
    var noteURI: String
    var folderURI: String
}

/// Result of a write: the note's id and new version, and a mismatch description when the
/// body read back differs from what was written.
public struct WriteOutcome: Sendable {
    public var id: String
    public var version: String
    public var title: String
    public var mismatch: String?

    public init(id: String, version: String, title: String, mismatch: String?) {
        self.id = id
        self.version = version
        self.title = title
        self.mismatch = mismatch
    }
}
