import CoreData
import Foundation
import NotesSharedShim

/// Note attributed string → [Block]. Only what Markdown can show is read; everything else
/// (color, font, alignment, timestamps) is left for in-place edits to preserve.
@MainActor
struct Reader {
    let context: NSManagedObjectContext
    /// Tables that exist only in a writer's dry run, by placeholder id.
    var pendingTables: [String: [[String]]] = [:]

    init(context: NSManagedObjectContext, pendingTables: [String: [[String]]] = [:]) {
        self.context = context
        self.pendingTables = pendingTables
    }

    static let attachmentKey = NSAttributedString.Key("NSAttachment")

    func blocks(_ attributed: NSAttributedString) throws(NotesError) -> [Block] {
        let string = attributed.string as NSString
        var blocks: [Block] = []
        var start = 0
        while start <= string.length {
            let newline = string.range(of: "\n", range: NSRange(location: start, length: string.length - start))
            let end = newline.location == NSNotFound ? string.length : newline.location
            let range = NSRange(location: start, length: end - start)
            // A paragraph's style sits on its characters and its closing newline. A last line
            // with neither has no style of its own, so it reads as body.
            blocks.append(try block(attributed, range: range, styleAt: end < string.length ? end : nil))
            if newline.location == NSNotFound { break }
            start = end + 1
        }
        return blocks
    }

    private func block(_ attributed: NSAttributedString, range: NSRange, styleAt fallback: Int?) throws(NotesError) -> Block {
        let styleIndex = range.length > 0 ? range.location : fallback
        let style = styleIndex.map { attributed.attribute(NSAttributedString.Key("TTStyle"), at: $0, effectiveRange: nil) as? NSObject } ?? nil
        let kind = Self.kind(style)
        let indent = (style?.value(forKey: "indent") as? Int) ?? 0
        let quote = (style?.value(forKey: "blockQuoteLevel") as? Int) ?? 0

        // A paragraph holding only a table attachment is a table block.
        if range.length == 1, let attachment = attributed.attribute(Self.attachmentKey, at: range.location, effectiveRange: nil) as? NSObject,
            attachment.value(forKey: "attachmentUTI") as? String == "com.apple.notes.table",
            let rows = try tableRows(attachment)
        {
            return .table(Table(id: attachment.value(forKey: "attachmentIdentifier") as? String ?? "", rows: rows))
        }

        if kind == .code {
            let text = (attributed.string as NSString).substring(with: range)
            return .paragraph(Paragraph(kind: .code, indent: indent, quote: quote, content: text.isEmpty ? [] : [.text(TextRun(text))]))
        }

        var content: [Inline] = []
        var failure: NotesError?
        attributed.enumerateAttributes(in: range) { attributes, run, stop in
            if let attachment = attributes[Self.attachmentKey] as? NSObject {
                do throws(NotesError) {
                    content.append(.attachment(try attachmentRef(attachment)))
                } catch {
                    failure = error
                    stop.pointee = true
                }
                return
            }
            let hints = (attributes[NSAttributedString.Key("TTHints")] as? Int) ?? 0
            var marks: Marks = []
            if hints & 1 != 0 { marks.insert(.bold) }
            if hints & 2 != 0 { marks.insert(.italic) }
            if ((attributes[NSAttributedString.Key("TTStrikethrough")] as? Int) ?? 0) != 0 { marks.insert(.strike) }
            if ((attributes[NSAttributedString.Key("TTUnderline")] as? Int) ?? 0) != 0 { marks.insert(.underline) }
            if ((attributes[NSAttributedString.Key("TTEmphasis")] as? Int) ?? 0) != 0 { marks.insert(.highlight) }
            let link = (attributes[NSAttributedString.Key("NSLink")] as? URL)?.absoluteString
                ?? attributes[NSAttributedString.Key("NSLink")] as? String
            let text = (attributed.string as NSString).substring(with: run)
            content.append(.text(TextRun(text, marks: marks, link: link)))
        }
        if let failure { throw failure }
        return .paragraph(Paragraph(kind: kind, indent: indent, quote: quote, content: content.normalized()))
    }

    static func kind(_ style: NSObject?) -> ParagraphKind {
        switch (style?.value(forKey: "style") as? Int) ?? 3 {
        case 0: .title
        case 1: .heading
        case 2: .subheading
        case 4: .code
        case 100: .bullet
        case 101: .dash
        case 102: .numbered
        case 103: .checklist(done: ((style?.value(forKey: "todo") as? NSObject)?.value(forKey: "done") as? Bool) ?? false)
        default: .body
        }
    }

    private func attachmentRef(_ attachment: NSObject) throws(NotesError) -> AttachmentRef {
        let id = attachment.value(forKey: "attachmentIdentifier") as? String ?? ""
        let uti = attachment.value(forKey: "attachmentUTI") as? String ?? ""
        if uti.hasPrefix("com.apple.notes.inlinetextattachment") {
            let inline = try fetch("ICInlineAttachment", id: id)
            let alt = (inline?.value(forKey: "altText") as? String ?? "").trimmingCharacters(in: .whitespaces)
            switch uti {
            case "com.apple.notes.inlinetextattachment.link":
                let token = inline?.value(forKey: "tokenContentIdentifier") as? String ?? ""
                return AttachmentRef(id: id, kind: "note link", label: Self.noteLinkLabel(alt, token: token))
            case "com.apple.notes.inlinetextattachment.hashtag": return AttachmentRef(id: id, kind: "hashtag", label: alt)
            case "com.apple.notes.inlinetextattachment.calculateresult": return AttachmentRef(id: id, kind: "calculation", label: alt)
            default: return AttachmentRef(id: id, kind: "inline", label: alt)
            }
        }
        let model = try fetch("ICAttachment", id: id)
        switch uti {
        case "com.apple.notes.table": return AttachmentRef(id: id, kind: "table", label: "")
        case "public.url":
            return AttachmentRef(id: id, kind: "link card", label: model?.value(forKey: "urlString") as? String ?? "")
        case let u where ["public.png", "public.jpeg", "public.heic", "public.tiff", "com.compuserve.gif", "public.image"].contains(u):
            return AttachmentRef(id: id, kind: "image", label: "")
        case let u where u.contains("audio"): return AttachmentRef(id: id, kind: "audio", label: model?.value(forKey: "title") as? String ?? "")
        case let u where u.contains("mpeg-4") || u.contains("movie") || u.contains("video"):
            return AttachmentRef(id: id, kind: "video", label: model?.value(forKey: "title") as? String ?? "")
        case let u where u.contains("pdf"): return AttachmentRef(id: id, kind: "pdf", label: model?.value(forKey: "title") as? String ?? "")
        default: return AttachmentRef(id: id, kind: "file", label: model?.value(forKey: "title") as? String ?? "")
        }
    }

    /// Note links carry `applenotes:note/<lowercased id>?…`; show the target id so the model
    /// can open it with read_note.
    static func noteLinkLabel(_ alt: String, token: String) -> String {
        guard let path = token.split(separator: "?").first, path.hasPrefix("applenotes:note/") else { return alt }
        return alt + " → " + ShortID.of(path.dropFirst("applenotes:note/".count).uppercased())
    }

    private func fetch(_ entity: String, id: String) throws(NotesError) -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "identifier == %@", id)
        request.fetchLimit = 1
        do {
            return try context.fetch(request).first
        } catch {
            throw .failed("fetching \(entity) \(id) failed: \(error.localizedDescription)")
        }
    }

    /// Reads cells through Notes' table model. Returns nil when the table cannot be read, so
    /// the caller shows it as an opaque attachment instead.
    private func tableRows(_ attachment: NSObject) throws(NotesError) -> [[String]]? {
        if let id = attachment.value(forKey: "attachmentIdentifier") as? String, let rows = pendingTables[id] { return rows }
        try Loader.startSharedContext()
        var model: AnyObject?
        do {
            try NSShim.send(attachment, selector: "attachmentInContext:", object: context, result: &model)
        } catch {
            throw .frameworkChanged("attachmentInContext: failed: \(error.localizedDescription)")
        }
        guard let model, let tableModel = try send(model, "attachmentModel"), let table = try send(tableModel, "table") as? NSObject,
            let rowCount = table.value(forKey: "rowCount") as? Int, let columnCount = table.value(forKey: "columnCount") as? Int,
            rowCount > 0, columnCount > 0
        else { return nil }
        var rows: [[String]] = []
        for row in 0..<rowCount {
            var cells: [String] = []
            for column in 0..<columnCount {
                var cell: AnyObject?
                do {
                    try NSShim.send(
                        table, selector: "stringForColumnIndex:rowIndex:", unsignedInteger: UInt(column),
                        unsignedInteger: UInt(row), result: &cell)
                } catch {
                    throw .frameworkChanged("reading a table cell failed: \(error.localizedDescription)")
                }
                cells.append((cell as? NSAttributedString)?.string ?? (cell as? String) ?? "")
            }
            rows.append(cells)
        }
        return rows
    }
}
