import CoreData
import Foundation

/// What an attachment holds, as plain values: the file on disk (if any) and the text Notes
/// already extracted from it (OCR, handwriting, image labels, link details).
public struct AttachmentInfo: Sendable {
    public var id: String
    public var kind: String
    public var uti: String
    public var title: String
    public var noteID: String
    public var noteTitle: String
    public var fileSize: Int
    /// The original file, or for drawings and Paper documents the image or PDF Notes renders.
    public var file: URL?
    public var fileName: String?
    public var url: String?
    /// Labeled text Notes extracted, e.g. ("Text in the image", "…").
    public var extracted: [(label: String, text: String)]
    /// Pages of a scanned document, in order.
    public var pages: [AttachmentInfo]
    /// For a table: its rows.
    public var tableRows: [[String]]?
}

extension NotesRepository {
    /// Looks up an attachment by the id shown in read_note's `![…](attachment:<id>)`.
    public func attachment(id: String) throws(NotesError) -> AttachmentInfo {
        let store = try store()
        store.refresh()
        guard let attachment = try fetch(store, "ICAttachment", NSPredicate(format: "identifier == %@", id)).first else {
            if try !fetch(store, "ICInlineAttachment", NSPredicate(format: "identifier == %@", id)).isEmpty {
                throw .refused("attachment:\(id) is an inline item (hashtag, note link or calculation); its text is already in read_note")
            }
            throw .notFound("attachment \(id)")
        }
        if (attachment.value(forKey: "markedForDeletion") as? Bool) == true { throw .notFound("attachment \(id) (deleted)") }
        guard let note = attachment.value(forKey: "note") as? NSManagedObject else { throw .notFound("the note of attachment \(id)") }
        if (note.value(forKey: "isPasswordProtected") as? Bool) == true { throw .refused("attachments of locked notes are not read") }
        return try info(attachment, note: note, context: store.context)
    }

    private func info(_ attachment: NSManagedObject, note: NSManagedObject, context: NSManagedObjectContext) throws(NotesError) -> AttachmentInfo {
        let uti = attachment.value(forKey: "typeUTI") as? String ?? ""
        let kind = AttachmentKind.of(uti: uti)
        func string(_ key: String) -> String? {
            guard let value = (try? send(attachment, key)) as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var file: URL?
        var fileName: String?
        if let media = attachment.value(forKey: "media") as? NSManagedObject {
            file = (try? send(media, "mediaURL")) as? URL
            fileName = media.value(forKey: "filename") as? String
        }
        if file.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
            // Drawings and Paper documents have no media file; Notes keeps a rendered copy.
            for key in ["fallbackPDFURL", "fallbackImageURL"] {
                if let url = (try? send(attachment, key)) as? URL, FileManager.default.fileExists(atPath: url.path) {
                    file = url
                    break
                }
            }
        }
        var extracted: [(String, String)] = []
        // Notes' own recognition, which can be wrong (seen 2026-10-12: Latin gibberish for an
        // image of Chinese labels), so it is labeled as Notes' guess.
        if let text = string("ocrSummary") { extracted.append(("Text Notes recognized (may be inaccurate)", text)) }
        if let text = string("handwritingSummary") { extracted.append(("Handwriting Notes recognized (may be inaccurate)", text)) }
        if let text = string("imageClassificationSummary") { extracted.append(("What Notes thinks the image shows (may be inaccurate)", text)) }
        if let text = attachment.value(forKey: "summary") as? String, !text.isEmpty { extracted.append(("Summary", text)) }
        var pages: [AttachmentInfo] = []
        if let subs = attachment.value(forKey: "subAttachments") as? Set<NSManagedObject> {
            let ordered = subs.filter { ($0.value(forKey: "markedForDeletion") as? Bool) != true }
                .sorted { ($0.value(forKey: "creationDate") as? Date ?? .distantPast) < ($1.value(forKey: "creationDate") as? Date ?? .distantPast) }
            pages = try ordered.map { sub throws(NotesError) in try info(sub, note: note, context: context) }
        }
        var rows: [[String]]?
        if uti == "com.apple.notes.table" {
            try Loader.startSharedContext()
            rows = try? TableEditor(attachmentID: attachment.value(forKey: "identifier") as? String ?? "", context: context).rows()
        }
        return AttachmentInfo(
            id: attachment.value(forKey: "identifier") as? String ?? "", kind: kind, uti: uti,
            title: string("title") ?? string("userTitle") ?? fileName ?? "",
            noteID: note.value(forKey: "identifier") as? String ?? "", noteTitle: note.value(forKey: "title") as? String ?? "",
            fileSize: (attachment.value(forKey: "fileSize") as? Int) ?? 0, file: file, fileName: fileName,
            url: (attachment.value(forKey: "urlString") as? String).flatMap { $0.isEmpty ? nil : $0 },
            extracted: extracted, pages: pages, tableRows: rows)
    }
}
