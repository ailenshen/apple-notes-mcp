import CoreData
import Foundation
import NotesSharedShim

/// Brings a Notes table to target rows in place (verified 2026-10-12).
///
/// A table lives in its attachment's own CRDT document, not in the note body, so this runs
/// outside the body's editing session. Columns are aligned by header and rows by content, so
/// only real insertions and removals add or drop rows and columns; every other cell is kept,
/// and only cells whose text differs are edited, character by character, through the cell's
/// own mergeable string. Formatting inside cells (bold made in Notes, for example) survives
/// on unchanged text, and edits from other devices merge cell by cell.
///
/// Persisting needs `setMergeableDataDirty:` before `writeMergeableData`: without the flag
/// the model writes nothing, and `+[ICTableAttachmentProvider saveAttachmentOnMainThread:]`
/// did not write either. Notes uploads the attachment by itself once its change count moves.
/// 当 Apple 开放表格编辑的官方 API 时，用它替换这里对 ICTable/CRTable 私有方法的调用。
@MainActor
final class TableEditor {
    let attachment: NSManagedObject
    private let model: AnyObject
    private let table: NSObject

    init(attachmentID: String, context: NSManagedObjectContext) throws(NotesError) {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ICAttachment")
        request.predicate = NSPredicate(format: "identifier == %@", attachmentID)
        request.fetchLimit = 1
        guard let found = try? context.fetch(request).first else { throw .notFound("table \(attachmentID)") }
        guard let model = try send(found, "attachmentModel"), let table = try send(model, "table") as? NSObject else {
            throw .frameworkChanged("table attachment \(attachmentID) has no table model")
        }
        attachment = found
        self.model = model
        self.table = table
    }

    var rowCount: Int { table.value(forKey: "rowCount") as? Int ?? 0 }
    var columnCount: Int { table.value(forKey: "columnCount") as? Int ?? 0 }

    func rows() throws(NotesError) -> [[String]] {
        try (0..<rowCount).map { row throws(NotesError) in
            try (0..<columnCount).map { column throws(NotesError) in try text(column: column, row: row) }
        }
    }

    func apply(_ target: [[String]]) throws(NotesError) {
        let width = target.map(\.count).max() ?? 0
        guard !target.isEmpty, width > 0 else { throw .refused("a table needs at least one cell") }
        let target = target.map { $0 + Array(repeating: "", count: width - $0.count) }

        // Columns: matched by header text when the column count changes, else kept in place.
        let current = try rows()
        if columnCount != width {
            let alignment = Self.align(current.first ?? [], target[0])
            for old in alignment.removed.reversed() { try sendIndex("removeColumnAtIndex:", old) }
            for new in alignment.inserted { try sendIndex("insertColumnAtIndex:", new) }
        }
        // Rows: matched by content; unmatched runs pair up as edited rows.
        let alignment = Self.align(try rows(), target)
        for old in alignment.removed.reversed() { try sendIndex("removeRowAtIndex:", old) }
        for new in alignment.inserted { try sendIndex("insertRowAtIndex:", new) }

        for row in 0..<target.count {
            for column in 0..<width where try text(column: column, row: row) != target[row][column] {
                try setText(target[row][column], column: column, row: row)
            }
        }
        guard try rows() == target else {
            throw .failed("internal check failed while editing a table; the note was not changed")
        }
        try call(model, "setMergeableDataDirty:") { try NSShim.send(model, selector: "setMergeableDataDirty:", boolean: true) }
        try call(model, "writeMergeableData") { try NSShim.send(model, selector: "writeMergeableData") }
        try call(attachment, "updateChangeCountWithReason:") {
            try NSShim.send(attachment, selector: "updateChangeCountWithReason:", object: "Edited table" as NSString)
        }
    }

    // MARK: Cells

    private func text(column: Int, row: Int) throws(NotesError) -> String {
        var cell: AnyObject?
        try call(table, "stringForColumnIndex:rowIndex:") {
            try NSShim.send(table, selector: "stringForColumnIndex:rowIndex:", unsignedInteger: UInt(column), unsignedInteger: UInt(row), result: &cell)
        }
        return (cell as? NSAttributedString)?.string ?? (cell as? String) ?? ""
    }

    /// Edits only the changed middle of the cell's text, so the rest keeps its formatting.
    /// Inserted text takes on the formatting of the text next to it, as typing would.
    private func setText(_ new: String, column: Int, row: Int) throws(NotesError) {
        let old = try text(column: column, row: row)
        guard !old.isEmpty, let cell = try mergeableString(column: column, row: row) else {
            try call(table, "setAttributedString:columnIndex:rowIndex:") {
                try NSShim.send(table, selector: "setAttributedString:columnIndex:rowIndex:", object: try Self.bodyText(new),
                                unsignedInteger: UInt(column), unsignedInteger: UInt(row))
            }
            return
        }
        let (prefix, oldMiddle, newMiddle) = Self.changedMiddle(old, new)
        try call(cell, "beginEditing") { try NSShim.send(cell, selector: "beginEditing") }
        do {
            if oldMiddle > 0 {
                try call(cell, "deleteCharactersInRange:") {
                    try NSShim.send(cell, selector: "deleteCharactersInRange:", range: NSRange(location: prefix, length: oldMiddle))
                }
            }
            if !newMiddle.isEmpty {
                try call(cell, "insertString:atIndex:") {
                    try NSShim.send(cell, selector: "insertString:atIndex:", string: newMiddle, index: UInt(prefix))
                }
            }
        } catch {
            try? call(cell, "endEditing") { try NSShim.send(cell, selector: "endEditing") }
            throw error
        }
        try call(cell, "endEditing") { try NSShim.send(cell, selector: "endEditing") }
    }

    private func mergeableString(column: Int, row: Int) throws(NotesError) -> AnyObject? {
        var columnID: AnyObject?, rowID: AnyObject?, cell: AnyObject?
        try call(table, "identifierForColumnAtIndex:") {
            try NSShim.send(table, selector: "identifierForColumnAtIndex:", unsignedInteger: UInt(column), result: &columnID)
        }
        try call(table, "identifierForRowAtIndex:") {
            try NSShim.send(table, selector: "identifierForRowAtIndex:", unsignedInteger: UInt(row), result: &rowID)
        }
        guard let columnID, let rowID else { return nil }
        try call(table, "mergeableStringForColumnID:rowID:") {
            try NSShim.send(table, selector: "mergeableStringForColumnID:rowID:", object: columnID, object: rowID, result: &cell)
        }
        return cell
    }

    private func sendIndex(_ selector: String, _ index: Int) throws(NotesError) {
        try call(table, selector) { try NSShim.send(table, selector: selector, unsignedInteger: UInt(index)) }
    }

    /// New cell text carries a body paragraph style, like cells Notes creates.
    static func bodyText(_ text: String) throws(NotesError) -> NSAttributedString {
        let style = try Writer.paragraphStyle(kind: .body, indent: 0, quote: 0, basedOn: nil)
        return NSAttributedString(string: text, attributes: [Writer.styleKey: style])
    }

    /// The changed middle between two strings, in UTF-16 offsets, never splitting a character:
    /// (common prefix length, length of the old middle, the new middle).
    static func changedMiddle(_ old: String, _ new: String) -> (Int, Int, String) {
        let a = Array(old), b = Array(new)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        let prefix = String(a[..<p]).utf16.count
        let oldMiddle = String(a[p..<(a.count - s)]).utf16.count
        return (prefix, oldMiddle, String(b[p..<(b.count - s)]))
    }

    // MARK: Checks only

    /// Makes the cell whose text is `text` bold, as Notes' Format menu would, and saves the table.
    func diagnosticBold(_ text: String) throws(NotesError) {
        let (column, row) = try find(text)
        guard let cell = try mergeableString(column: column, row: row),
            let string = try send(cell, "attributedString") as? NSAttributedString, string.length > 0
        else { throw .notFound("cell \(text)") }
        var attributes = string.attributes(at: 0, effectiveRange: nil)
        attributes[Writer.hintsKey] = 1
        try call(cell, "beginEditing") { try NSShim.send(cell, selector: "beginEditing") }
        try call(cell, "setAttributes:range:") {
            try NSShim.send(cell, selector: "setAttributes:range:", attributes: attributes, range: NSRange(location: 0, length: string.length))
        }
        try call(cell, "endEditing") { try NSShim.send(cell, selector: "endEditing") }
        try call(model, "setMergeableDataDirty:") { try NSShim.send(model, selector: "setMergeableDataDirty:", boolean: true) }
        try call(model, "writeMergeableData") { try NSShim.send(model, selector: "writeMergeableData") }
    }

    /// TTHints on the first character of the cell whose text starts with `prefix`.
    func diagnosticHints(_ prefix: String) throws(NotesError) -> Int? {
        let (column, row) = try find(prefix)
        guard let cell = try mergeableString(column: column, row: row),
            let string = try send(cell, "attributedString") as? NSAttributedString, string.length > 0
        else { return nil }
        return string.attribute(Writer.hintsKey, at: 0, effectiveRange: nil) as? Int
    }

    private func find(_ prefix: String) throws(NotesError) -> (Int, Int) {
        for row in 0..<rowCount {
            for column in 0..<columnCount where try text(column: column, row: row).hasPrefix(prefix) { return (column, row) }
        }
        throw .notFound("cell \(prefix)")
    }

    // MARK: Alignment

    /// LCS alignment of two sequences. Old items outside the LCS are removed and new ones
    /// inserted, except that inside each unmatched run old and new items pair up one to one
    /// (they become edited items), so an edited row is changed rather than removed and re-added.
    /// Indexes: `removed` in old positions (ascending), `inserted` in new positions (ascending),
    /// meant to be applied as all removals from the end, then all insertions from the start.
    static func align<T: Equatable>(_ old: [T], _ new: [T]) -> (removed: [Int], inserted: [Int]) {
        var lcs = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                lcs[i][j] = old[i] == new[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var removed: [Int] = [], inserted: [Int] = []
        var i = 0, j = 0, runOld: [Int] = [], runNew: [Int] = []
        func closeRun() {
            let paired = min(runOld.count, runNew.count)
            removed += runOld.dropFirst(paired)
            inserted += runNew.dropFirst(paired)
            runOld = []
            runNew = []
        }
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, old[i] == new[j] {
                closeRun()
                i += 1
                j += 1
            } else if j < new.count, i == old.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                runNew.append(j)
                j += 1
            } else {
                runOld.append(i)
                i += 1
            }
        }
        closeRun()
        return (removed, inserted)
    }
}
