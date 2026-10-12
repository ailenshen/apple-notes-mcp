import Foundation

/// Plain names for attachment types, as shown in lists and placeholders.
public enum AttachmentKind {
    public static func of(uti: String) -> String {
        switch uti {
        case "com.apple.notes.table": return "table"
        case "public.url": return "link"
        case "com.adobe.pdf", "com.apple.paper.doc.pdf": return "PDF"
        case "com.apple.notes.gallery": return "scan"
        case "com.apple.drawing", "com.apple.drawing.2", "com.apple.paper": return "drawing"
        default:
            if uti.hasPrefix("public.") && ["png", "jpeg", "heic", "gif", "tiff", "image", "webp"].contains(where: uti.hasSuffix) { return "image" }
            if uti.contains("audio") { return "audio" }
            if uti.contains("movie") || uti == "public.mpeg-4" || uti.contains("video") { return "video" }
            return "file"
        }
    }

    /// "3 images, 1 table", in a fixed order.
    public static func summary(_ counts: [String: Int]) -> String {
        let order = ["image", "scan", "drawing", "table", "PDF", "audio", "video", "link", "file"]
        return order.compactMap { kind in
            guard let n = counts[kind], n > 0 else { return nil }
            return n == 1 ? "1 \(kind)" : "\(n) \(kind == "PDF" ? "PDFs" : kind + "s")"
        }.joined(separator: ", ")
    }
}
