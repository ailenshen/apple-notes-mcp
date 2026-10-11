import Foundation

// Full-text search over note titles and bodies. Body text is read straight from
// ZICNOTEDATA.ZDATA (gzip + protobuf, field document(2) → note(3) → note_text(2)), which is
// ~50× faster than loading every note through NotesShared. Formatting is ignored on purpose:
// this text is only searched, never shown or written back. Cached by modification time and
// data length, so repeat searches only decode notes that changed.
// 当 Apple 开放官方全文检索接口时，重构过去并删除这里的私有格式解析。

public struct SearchHit: Sendable {
    public var id: String
    public var title: String
    public var folderPath: String
    public var modified: Date
    public var snippet: String
}

public actor FullTextSearch {
    private var database: SQLiteDatabase?
    private var cache: [String: (key: String, text: String)] = [:]

    public init() {}

    /// - Parameters:
    ///   - folderPaths: user folders by Core Data primary key; notes elsewhere (trash) are skipped.
    ///   - folderPath: limit to this folder and its subfolders.
    public func search(
        _ query: String, matchAll: Bool, folderPath: String?, limit: Int, folderPaths: [Int64: String]
    ) throws(NotesError) -> (total: Int, hits: [SearchHit]) {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { throw .refused("the search query is empty") }
        let db = try open()
        struct Row { var id: String; var title: String; var folder: Int64; var modified: Double; var key: String; var dataPK: Int64 }
        var rows: [Row] = []
        try db.query("""
            SELECT n.ZIDENTIFIER, n.ZTITLE1, n.ZFOLDER, n.ZMODIFICATIONDATE1, length(d.ZDATA), d.Z_PK
            FROM ZICCLOUDSYNCINGOBJECT n LEFT JOIN ZICNOTEDATA d ON d.Z_PK = n.ZNOTEDATA
            WHERE n.Z_ENT = (SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ICNote')
              AND IFNULL(n.ZMARKEDFORDELETION, 0) = 0 AND IFNULL(n.ZISPASSWORDPROTECTED, 0) = 0
            """) { r throws(NotesError) in
            guard let id = r.text(0) else { return }
            rows.append(Row(id: id, title: r.text(1) ?? "", folder: r.int(2), modified: r.double(3),
                            key: "\(r.double(3))|\(r.int(4))", dataPK: r.int(5)))
        }
        var hits: [(hit: SearchHit, score: Int)] = []
        for row in rows {
            guard let path = folderPaths[row.folder] else { continue }
            if let folderPath, path != folderPath, !path.hasPrefix(folderPath + "/") { continue }
            let text = try body(row.id, key: row.key, dataPK: row.dataPK, db: db)
            let haystack = row.title + "\n" + text
            let found = terms.filter { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            guard matchAll ? found.count == terms.count : !found.isEmpty else { continue }
            let inTitle = terms.filter { row.title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.count
            hits.append((
                SearchHit(id: row.id, title: row.title, folderPath: path, modified: Date(timeIntervalSinceReferenceDate: row.modified),
                          snippet: Self.snippet(text, terms: found)),
                found.count * 10 + inTitle * 100))
        }
        hits.sort { ($0.score, $0.hit.modified) > ($1.score, $1.hit.modified) }
        return (hits.count, Array(hits.prefix(limit).map(\.hit)))
    }

    /// Plain text of every readable note, for building fallback descriptions.
    public func bodies(ids: Set<String>) throws(NotesError) -> [String: String] {
        let db = try open()
        var out: [String: String] = [:]
        var rows: [(String, String, Int64)] = []
        try db.query("""
            SELECT n.ZIDENTIFIER, n.ZMODIFICATIONDATE1, length(d.ZDATA), d.Z_PK
            FROM ZICCLOUDSYNCINGOBJECT n LEFT JOIN ZICNOTEDATA d ON d.Z_PK = n.ZNOTEDATA
            WHERE n.Z_ENT = (SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ICNote') AND IFNULL(n.ZISPASSWORDPROTECTED, 0) = 0
            """) { r throws(NotesError) in
            if let id = r.text(0), ids.contains(id) { rows.append((id, "\(r.double(1))|\(r.int(2))", r.int(3))) }
        }
        for (id, key, pk) in rows { out[id] = try body(id, key: key, dataPK: pk, db: db) }
        return out
    }

    private func open() throws(NotesError) -> SQLiteDatabase {
        if let database { return database }
        let opened = try SQLiteDatabase(path: ReadStore.storeURL.path, readOnly: true)
        database = opened
        return opened
    }

    private func body(_ id: String, key: String, dataPK: Int64, db: SQLiteDatabase) throws(NotesError) -> String {
        if let cached = cache[id], cached.key == key { return cached.text }
        var blob: Data?
        try db.query("SELECT ZDATA FROM ZICNOTEDATA WHERE Z_PK = ?", [.int(dataPK)]) { r throws(NotesError) in blob = r.data(0) }
        let text = blob.flatMap(NoteBodyDecoder.plainText) ?? ""
        cache[id] = (key, text)
        return text
    }

    static func snippet(_ text: String, terms: [String]) -> String {
        let flat = text.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\n", with: " ⏎ ")
        guard let first = terms.compactMap({ flat.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) })
            .min(by: { $0.lowerBound < $1.lowerBound })
        else { return String(flat.prefix(80)) }
        let start = flat.index(first.lowerBound, offsetBy: -30, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(first.upperBound, offsetBy: 50, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }
}

/// Decodes the plain text out of a stored note body.
enum NoteBodyDecoder {
    static func plainText(_ stored: Data) -> String? {
        guard let raw = gunzip(stored),
            let document = field(2, in: raw), let note = field(3, in: document), let text = field(2, in: note)
        else { return nil }
        return String(decoding: text, as: UTF8.self)
    }

    /// First length-delimited field with this number in a protobuf message.
    static func field(_ number: Int, in message: Data) -> Data? {
        let bytes = [UInt8](message)
        var i = 0
        func varint() -> Int? {
            var result = 0, shift = 0
            while i < bytes.count {
                let b = bytes[i]
                i += 1
                result |= Int(b & 0x7f) << shift
                if b < 0x80 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < bytes.count {
            guard let key = varint() else { return nil }
            switch key & 7 {
            case 0: guard varint() != nil else { return nil }
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let length = varint(), i + length <= bytes.count else { return nil }
                if key >> 3 == number { return Data(bytes[i..<(i + length)]) }
                i += length
            default: return nil
            }
        }
        return nil
    }

    /// gzip → raw DEFLATE body → inflate. Foundation's `.zlib` decompresses raw DEFLATE.
    static func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 { i += 2 + Int(b[i]) + Int(b[i + 1]) << 8 }
        if flags & 8 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 16 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 2 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        return try? (Data(b[i..<(b.count - 8)]) as NSData).decompressed(using: .zlib) as Data
    }
}
