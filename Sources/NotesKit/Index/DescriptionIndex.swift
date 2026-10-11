import Foundation

// One-line descriptions of notes, for `overview`. Derived data: deleting the file only loses
// descriptions the model wrote. Sources, best first: written by the model (describe_note),
// generated on-device by Apple's model (where available), or extracted from the note.
// 当 Apple 端侧模型在多数机器上可用时，补上 apple_fm 来源的后台生成，并调整优先级。

public struct NoteDescription: Sendable {
    public enum Source: String, Sendable { case agent, appleFM = "apple_fm", extractive }
    public var text: String
    public var source: Source
    /// The note's modification date when the description was written.
    public var noteModified: Date
}

public actor DescriptionIndex {
    private let path: String
    private var database: SQLiteDatabase?

    public init(path: String = NotesRepository.supportDirectory.appendingPathComponent("index.sqlite").path) {
        self.path = path
    }

    private func open() throws(NotesError) -> SQLiteDatabase {
        if let database { return database }
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        } catch {
            throw .failed("cannot create \(path): \(error.localizedDescription)")
        }
        let opened = try SQLiteDatabase(path: path, readOnly: false)
        try opened.query("""
            CREATE TABLE IF NOT EXISTS note_descriptions (
              identifier TEXT PRIMARY KEY, description TEXT NOT NULL, source TEXT NOT NULL,
              note_modified REAL NOT NULL, updated_at REAL NOT NULL)
            """)
        database = opened
        return opened
    }

    public func set(_ id: String, text: String, source: NoteDescription.Source, noteModified: Date) throws(NotesError) {
        try open().query(
            "INSERT OR REPLACE INTO note_descriptions VALUES (?, ?, ?, ?, ?)",
            [.text(id), .text(text), .text(source.rawValue), .real(noteModified.timeIntervalSinceReferenceDate),
             .real(Date().timeIntervalSinceReferenceDate)])
    }

    public func all() throws(NotesError) -> [String: NoteDescription] {
        var out: [String: NoteDescription] = [:]
        try open().query("SELECT identifier, description, source, note_modified FROM note_descriptions") { r throws(NotesError) in
            guard let id = r.text(0), let text = r.text(1) else { return }
            out[id] = NoteDescription(
                text: text, source: NoteDescription.Source(rawValue: r.text(2) ?? "") ?? .extractive,
                noteModified: Date(timeIntervalSinceReferenceDate: r.double(3)))
        }
        return out
    }

    public func get(_ id: String) throws(NotesError) -> NoteDescription? { try all()[id] }

    /// Fallback: the first heading under the title, else the first sentence of the body.
    public static func extract(fromPlainText text: String, title: String) -> String {
        let lines = text.replacingOccurrences(of: "\u{FFFC}", with: "").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let body = lines.first == title ? Array(lines.dropFirst()) : lines
        guard let first = body.first else { return "" }
        let sentenceEnd = first.firstIndex(where: { "。！？.!?".contains($0) }).map { first.index(after: $0) } ?? first.endIndex
        let sentence = String(first[..<sentenceEnd])
        return sentence.count > 80 ? String(sentence.prefix(79)) + "…" : sentence
    }
}
