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
    case failed(String)

    public var description: String {
        switch self {
        case .noAccess(let m): "No access to Apple Notes data: \(m)"
        case .frameworkChanged(let m): m
        case .notFound(let id): "No note with id \(id)"
        case .refused(let m): m
        case .failed(let m): m
        }
    }
}
