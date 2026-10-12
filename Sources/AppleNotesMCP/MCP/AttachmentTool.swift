import AVFoundation
import Foundation
import ImageIO
import MCPCore
import NotesKit
import PDFKit
import UniformTypeIdentifiers

/// Hands an attachment to the model in MCP 2026-07-28's own content types where they fit:
/// images (and scan pages, drawings, video stills) as ImageContent, audio as AudioContent, PDFs
/// and other files as an EmbeddedResource. The text Notes already extracted (OCR, handwriting,
/// image labels) and text we can extract (PDF text, text files, table cells) always comes too,
/// so a client that drops a content type still gets something useful.
///
/// Measured with Claude Code 2.1.296 (2026-10-12):
/// - Images reach the model.
/// - Audio and embedded files are saved to a file, and the model gets its path. With the Read
///   tool, Claude then reads a PDF fully (text and page images).
/// - Audio cannot be heard, but an agent with tools can process the saved file.
/// 当客户端对 audio / resource 的处理有变化（例如直接把 PDF 或音频交给模型）时，按实测调整这里的取舍。
struct ReadAttachmentTool: Tool {
    let notes: NotesContext
    let name = "read_attachment"
    let title: String? = "Read an attachment"
    let description = "Opens an attachment from a ![…](attachment:id) placeholder: images, scans, PDFs, audio, video, tables, links and files."
    let inputSchema = schema([
        "id": stringProperty("Attachment id"),
        "text_only": ["type": "boolean", "description": "Only text, no images or files"],
    ], required: ["id"])
    let annotations = ToolAnnotations.readOnly

    /// Long edge for images sent to the model; larger images are scaled down by clients anyway.
    static let maxImageEdge = 1568
    static let maxScanPages = 10
    static let maxFileBytes = 20 * 1024 * 1024
    static let maxText = 20_000

    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        let args = Arguments(arguments)
        let id = try args.string("id")
        let textOnly = try args.bool("text_only", default: false)
        return try await writeResult {
            let info = try await notes.repository.attachment(id: id)
            var lines = ["\(info.kind)\(info.title.isEmpty ? "" : " \"\(info.title)\"") in note \"\(info.noteTitle)\" (\(info.noteID))"
                + (info.fileSize > 0 ? " | \(ByteCountFormatter.string(fromByteCount: Int64(info.fileSize), countStyle: .file))" : "")]
            var extra: [ContentBlock] = []
            func addText(_ label: String, _ text: String) {
                let cut = text.count > Self.maxText ? String(text.prefix(Self.maxText)) + "\n… (cut at \(Self.maxText) characters)" : text
                lines.append("\n\(label):\n\(cut)")
            }
            if let url = info.url { lines.append("URL: \(url)") }
            if let rows = info.tableRows {
                lines.append("\n" + MarkdownRenderer.render([.table(Table(id: info.id, rows: rows))]))
            }
            for (label, text) in info.extracted { addText(label, text) }

            let pages = info.pages.isEmpty ? [info] : Array(info.pages.prefix(Self.maxScanPages))
            if info.pages.count > Self.maxScanPages { lines.append("(showing the first \(Self.maxScanPages) of \(info.pages.count) pages)") }
            for (index, page) in pages.enumerated() {
                if !info.pages.isEmpty {
                    for (label, text) in page.extracted { addText("Page \(index + 1) — \(label)", text) }
                }
                guard let file = page.file else { continue }
                let type = UTType(filenameExtension: file.pathExtension) ?? UTType(page.uti)
                if type?.conforms(to: .image) == true {
                    if !textOnly, let jpeg = Self.scaledJPEG(file) { extra.append(.image(jpeg, mimeType: "image/jpeg")) }
                } else if type?.conforms(to: .pdf) == true {
                    if let document = PDFDocument(url: file) {
                        lines.append("PDF, \(document.pageCount) pages")
                        if let text = document.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { addText("Text in the PDF", text) }
                    }
                    if !textOnly, let data = Self.read(file) { extra.append(.resource(uri: "attachment:\(page.id)", mimeType: "application/pdf", data)) }
                } else if type?.conforms(to: .audio) == true {
                    if let seconds = await Self.duration(file) { lines.append("Audio, \(Self.clock(seconds))") }
                    if !textOnly, let data = Self.read(file) { extra.append(.audio(data, mimeType: type?.preferredMIMEType ?? "audio/mp4")) }
                } else if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
                    if let seconds = await Self.duration(file) { lines.append("Video, \(Self.clock(seconds)); a frame from it follows") }
                    if !textOnly, let frame = await Self.still(file) { extra.append(.image(frame, mimeType: "image/jpeg")) }
                } else if type?.conforms(to: .text) == true, let data = Self.read(file), let text = String(data: data, encoding: .utf8) {
                    addText("File \(page.fileName ?? file.lastPathComponent)", text)
                } else if let data = Self.read(file) {
                    lines.append("File \(page.fileName ?? file.lastPathComponent)")
                    if !textOnly { extra.append(.resource(uri: "attachment:\(page.id)", mimeType: type?.preferredMIMEType ?? "application/octet-stream", data)) }
                }
            }
            if extra.isEmpty && lines.count == 1 { lines.append("Nothing more can be read from this attachment.") }
            return ToolResult(lines.joined(separator: "\n"), extra: extra)
        }
    }

    static func read(_ file: URL) -> Data? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxFileBytes else { return nil }
        return try? Data(contentsOf: file)
    }

    /// The image scaled so its long edge is at most `maxImageEdge`, as JPEG. HEIC and other
    /// formats are converted, since clients accept JPEG everywhere.
    static func scaledJPEG(_ file: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImageEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return jpeg(image)
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    static func duration(_ file: URL) async -> Double? {
        guard let time = try? await AVURLAsset(url: file).load(.duration), time.isNumeric else { return nil }
        return time.seconds
    }

    static func still(_ file: URL) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxImageEdge, height: maxImageEdge)
        guard let (image, _) = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) else { return nil }
        return jpeg(image)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
