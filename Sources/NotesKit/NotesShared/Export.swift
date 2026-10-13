import Foundation
import UniformTypeIdentifiers

// Exporting a folder with its subfolders to disk, for archiving (2026-10-14). The output:
// - one Markdown file per note, in the same folder layout;
// - each attachment's original file under attachments/<id>/, linked from the Markdown by
//   relative path so the archive reads offline;
// - manifest.md, listing every note.
// Locked notes cannot be read (their body is encrypted), so they are listed in the manifest as
// not exported, never skipped silently. A destination ending in .zip is zipped with ditto,
// because claude.ai, the reference client, has no shell to do it.
// 当 Apple 开放官方导出 API（含锁定笔记与原始格式）时，改用官方导出。

public struct ExportOutcome: Sendable {
    /// The folder's path in Notes.
    public var path: String
    public var destination: String
    /// Every note in the tree, locked ones included: the count a recursive delete expects.
    public var notes: Int
    public var folders: Int
    public var locked: Int
    /// Notes that could not be read, as "title: reason".
    public var failed: [String]
    public var files: Int
    public var missingFiles: Int
}

extension NotesRepository {
    public func export(folder reference: String, to destination: String) async throws(NotesError) -> ExportOutcome {
        let target = try ExportFiles.destination(destination)
        let zip = target.pathExtension.lowercased() == "zip"
        let root = try resolveFolder(reference)
        let all = try folders()
        // The tree by parent links, not by path: two folders may share a path.
        var tree = [root]
        var next = 0
        while next < tree.count {
            let parent = tree[next].id
            tree += all.filter { $0.parentID == parent }
            next += 1
        }
        let notes = try notes(inFolders: Set(tree.map(\.id)))

        let files = FileManager.default
        let work: URL
        var scratch: URL?
        defer { if let scratch { try? files.removeItem(at: scratch) } }
        do {
            if zip {
                try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temporary = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target.deletingLastPathComponent(), create: true)
                scratch = temporary
                work = temporary.appendingPathComponent(target.deletingPathExtension().lastPathComponent, isDirectory: true)
            } else {
                work = target
            }
            try files.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            throw .failed("could not create \(target.path): \(error.localizedDescription)")
        }

        do throws(NotesError) {
            var report = ExportReport(path: root.path)
            // Directory names per folder, relative to the export root.
            var directories: [String: [String]] = [root.id: []]
            var used: [String: Set<String>] = ["": ["attachments", "manifest.md"]]
            for folder in tree.dropFirst() {
                let parent = directories[folder.parentID ?? ""] ?? []
                let name = ExportFiles.unique(ExportFiles.name(folder.name), id: folder.id, in: &used[parent.joined(separator: "/"), default: []])
                directories[folder.id] = parent + [name]
                try ExportFiles.createDirectory(work.appendingPathComponent((parent + [name]).joined(separator: "/"), isDirectory: true))
            }
            // Oldest first within a folder, so the older of two same-titled notes keeps the plain name.
            let order = Dictionary(uniqueKeysWithValues: tree.enumerated().map { ($0.element.id, $0.offset) })
            let sorted = notes.sorted { (order[$0.folderID] ?? 0, $0.created) < (order[$1.folderID] ?? 0, $1.created) }
            for note in sorted {
                let directory = directories[note.folderID] ?? []
                let file = ExportFiles.unique(ExportFiles.name(note.title), extension: ".md", id: note.id, in: &used[directory.joined(separator: "/"), default: []])
                let relative = (directory + [file]).joined(separator: "/")
                if note.isLocked {
                    report.add(note, file: nil, attachments: 0, missing: 0, status: "locked — not exported")
                    report.locked += 1
                    continue
                }
                let blocks: [Block]
                do throws(NotesError) {
                    blocks = try self.blocks(id: note.id)
                } catch {
                    report.add(note, file: nil, attachments: 0, missing: 0, status: "failed: \(error)")
                    report.failed.append("\(note.title): \(error)")
                    continue
                }
                var links: [String: String] = [:]
                var count = 0, missing = 0
                for ref in blocks.attachmentRefs where links[ref.id] == nil {
                    switch ref.kind {
                    case "note link", "hashtag", "calculation", "inline":
                        links[ref.id] = MarkdownRenderer.escapeText(ref.label)
                    case "table":
                        continue
                    case "link card":
                        if !ref.label.isEmpty { links[ref.id] = "[" + MarkdownRenderer.escapeText(ref.label) + "](" + MarkdownRenderer.escapeURL(ref.label) + ")" }
                    default:
                        count += 1
                        do throws(NotesError) {
                            let copied = try copyAttachment(ref, into: work, depth: directory.count)
                            links[ref.id] = copied.markdown
                            report.files += copied.files
                            if copied.missing > 0 {
                                missing += 1
                                report.problems.append("\(relative): \(ref.kind) attachment \(ref.id): "
                                    + (copied.total == 1 ? "its file is not on this Mac (Notes may not have downloaded it)" : "\(copied.missing) of its \(copied.total) files are not on this Mac"))
                            }
                        } catch {
                            missing += 1
                            report.problems.append("\(relative): \(ref.kind) attachment \(ref.id): \(error)")
                        }
                    }
                }
                report.missingFiles += missing
                let url = work.appendingPathComponent(relative)
                do {
                    try Data((MarkdownRenderer.render(blocks) { links[$0.id] } + "\n").utf8).write(to: url)
                    try files.setAttributes([.creationDate: note.created, .modificationDate: note.modified], ofItemAtPath: url.path)
                } catch {
                    throw .failed("could not write \(relative): \(error.localizedDescription)")
                }
                report.add(note, file: relative, attachments: count, missing: missing, status: "exported")
            }
            do {
                try Data(report.manifest(folders: tree.count).utf8).write(to: work.appendingPathComponent("manifest.md"))
            } catch {
                throw .failed("could not write the manifest: \(error.localizedDescription)")
            }
            if zip { try await ExportFiles.zip(work, to: target) }
            return ExportOutcome(path: root.path, destination: target.path, notes: notes.count, folders: tree.count, locked: report.locked,
                                 failed: report.failed, files: report.files, missingFiles: report.missingFiles)
        } catch {
            // Only what this call created is removed: the destination did not exist before.
            try? files.removeItem(at: target)
            throw error
        }
    }

    /// Copies an attachment's original file (or a scan's pages) to attachments/<id>/ and returns
    /// the Markdown that links them from a note `depth` folders below the export root.
    private func copyAttachment(_ ref: AttachmentRef, into root: URL, depth: Int) throws(NotesError) -> (markdown: String?, files: Int, missing: Int, total: Int) {
        let info = try attachment(id: ref.id)
        let label = ref.label.isEmpty ? ref.kind : ref.kind + ": " + ref.label
        // A scan's files are its pages; drawings come with the PDF or image Notes renders.
        let sources: [(file: URL?, name: String, label: String)] = info.pages.isEmpty
            ? [(info.file, ExportFiles.name(info.fileName ?? info.file?.lastPathComponent ?? ref.kind), label)]
            : info.pages.enumerated().map { index, page in
                (page.file, String(format: "page-%02d", index + 1) + (page.file.map { "." + $0.pathExtension } ?? ""), "\(label) page \(index + 1)")
            }
        let directory = root.appendingPathComponent("attachments/\(ref.id)", isDirectory: true)
        var parts: [String] = []
        var copied = 0, missing = 0
        for source in sources {
            guard let file = source.file, FileManager.default.fileExists(atPath: file.path) else {
                missing += 1
                continue
            }
            try ExportFiles.createDirectory(directory)
            do {
                try FileManager.default.copyItem(at: file, to: directory.appendingPathComponent(source.name))
            } catch {
                throw .failed("could not copy \(file.lastPathComponent): \(error.localizedDescription)")
            }
            copied += 1
            let link = ExportFiles.link(["attachments", ref.id, source.name], depth: depth)
            let image = UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true
            parts.append((image ? "!" : "") + "[" + MarkdownRenderer.escapeText(source.label) + "](" + link + ")")
        }
        return (parts.isEmpty ? nil : parts.joined(separator: " "), copied, missing, sources.count)
    }
}

/// Collects the manifest rows while exporting.
private struct ExportReport {
    var path: String
    var rows: [[String]] = []
    var problems: [String] = []
    var failed: [String] = []
    var locked = 0
    var files = 0
    var missingFiles = 0

    init(path: String) { self.path = path }

    mutating func add(_ note: NoteSnapshot, file: String?, attachments: Int, missing: Int, status: String) {
        rows.append([file ?? "—", note.title, note.id, ExportFiles.date(note.created), ExportFiles.date(note.modified),
                     missing > 0 ? "\(attachments) (\(missing) missing)" : "\(attachments)", status])
    }

    func manifest(folders: Int) -> String {
        let exported = rows.count - locked - failed.count
        var summary = "\(rows.count) notes in \(folders) folder\(folders == 1 ? "" : "s"): \(exported) exported"
        if locked > 0 { summary += ", \(locked) locked (not exported: Notes keeps them encrypted)" }
        if !failed.isEmpty { summary += ", \(failed.count) could not be read" }
        summary += ". \(files) attachment files copied" + (missingFiles > 0 ? ", \(missingFiles) attachments missing" : "") + "."
        var lines = [
            "# \(path)", "",
            "Exported from Apple Notes on \(ExportFiles.date(Date())). \(summary)",
            "Each note is a Markdown file in the same folder layout. Attachments are in attachments/<id>/, in their original format.", "",
            "| File | Title | Id | Created | Modified | Attachments | Status |",
            "| --- | --- | --- | --- | --- | --- | --- |",
        ]
        lines += rows.sorted { $0[0].localizedStandardCompare($1[0]) == .orderedAscending }
            .map { "| " + $0.map(MarkdownRenderer.escapeCell).joined(separator: " | ") + " |" }
        if !problems.isEmpty {
            lines += ["", "## Problems", ""] + problems.map { "- " + $0 }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// File-system side of the export: names, links, the destination check and the zip.
public enum ExportFiles {
    /// A file or folder name from a title: "/" and ":" become "-", control characters become
    /// spaces, leading dots go (no hidden files), and the name is cut to `maxBytes` of UTF-8,
    /// since APFS allows 255 bytes and a Chinese character takes 3.
    public static func name(_ title: String, maxBytes: Int = 200) -> String {
        var name = String(String.UnicodeScalarView(title.unicodeScalars.map { scalar -> Unicode.Scalar in
            if scalar == "/" || scalar == ":" { return "-" }
            if CharacterSet.controlCharacters.contains(scalar) || scalar == "\u{FFFC}" { return " " }
            return scalar
        }))
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name = String(name.dropFirst()).trimmingCharacters(in: .whitespaces) }
        while name.utf8.count > maxBytes { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Untitled" : name
    }

    /// `name` + `extension`, or with the short id added when the folder already has that name.
    /// Names are compared as APFS does by default: ignoring case and Unicode normalization.
    public static func unique(_ name: String, extension ext: String = "", id: String, in used: inout Set<String>) -> String {
        func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }
        var candidate = name + ext
        if used.contains(key(candidate)) { candidate = "\(name) (\(ShortID.of(id)))\(ext)" }
        if used.contains(key(candidate)) { candidate = "\(name) (\(id))\(ext)" }
        used.insert(key(candidate))
        return candidate
    }

    /// A relative link from a note `depth` folders below the export root, percent-encoded so
    /// spaces and brackets cannot break the Markdown.
    public static func link(_ components: [String], depth: Int) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return (Array(repeating: "..", count: depth) + components.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 })
            .joined(separator: "/")
    }

    /// The destination as an absolute URL. It must not exist yet, so an export never writes
    /// into or over anything already there. Nothing goes inside ~/Library: this app has Full
    /// Disk Access, and a manipulated model must not be able to plant files in places such as
    /// LaunchAgents.
    public static func destination(_ raw: String) throws(NotesError) -> URL {
        let expanded = (raw.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw .refused("to must be an absolute path, such as ~/Documents/Archive/Work.zip") }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        guard url.path != "/", !FileManager.default.fileExists(atPath: url.path) else {
            throw .refused("\(url.path) already exists; export to a new directory or .zip path")
        }
        // Resolve links in the part that exists, so a symlink cannot lead into ~/Library.
        var existing = url.deletingLastPathComponent()
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) { existing = existing.deletingLastPathComponent() }
        let rest = url.path.dropFirst(existing.path.count).split(separator: "/").map(String.init)
        let resolved = rest.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
        let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library").resolvingSymlinksInPath().path.lowercased()
        for path in [url.path.lowercased(), resolved.path.lowercased()] where path == library || path.hasPrefix(library + "/") {
            throw .refused("exports cannot go inside ~/Library; choose a folder such as ~/Documents/Archive")
        }
        return url
    }

    static func createDirectory(_ url: URL) throws(NotesError) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw .failed("could not create \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Local time with its offset, such as 2026-10-14T09:30:00+08:00, so dates stay exact as evidence.
    static func date(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    /// Zips `directory` (keeping its name as the top folder) with ditto, which ships with macOS.
    /// Its output never reaches stdout, which carries the MCP messages.
    static func zip(_ directory: URL, to archive: URL) async throws(NotesError) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", directory.path, archive.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32
        do {
            status = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            throw .failed("could not start ditto to make the zip: \(error.localizedDescription)")
        }
        guard status == 0 else { throw .failed("ditto could not make the zip (exit status \(status))") }
        try markNamesAsUTF8(archive)
    }

    /// Sets the "names are UTF-8" flag (general purpose bit 11) on every entry. ditto writes
    /// UTF-8 names without the flag, so Windows, Python and unzip read Chinese names as garbage
    /// (seen 2026-10-14), and /usr/bin/zip on macOS is built without Unicode support. Only that
    /// flag changes; the flags are outside every checksum. Zip64 archives are handled, since
    /// an archive with videos can pass 4 GB.
    /// 当 macOS 自带的 ditto 或 zip 能自己写这个标志（或 Foundation 提供 zip API）时，删掉这段补丁。
    public static func markNamesAsUTF8(_ archive: URL) throws(NotesError) {
        func fail(_ why: String) -> NotesError { .failed("could not mark the file names in the zip as UTF-8 (\(why)); nothing was exported") }
        let file: FileHandle
        do { file = try FileHandle(forUpdating: archive) } catch { throw fail(error.localizedDescription) }
        defer { try? file.close() }
        func read(at offset: UInt64, _ count: Int) throws(NotesError) -> [UInt8] {
            do {
                try file.seek(toOffset: offset)
                let data = try file.read(upToCount: count) ?? Data()
                guard data.count == count else { throw fail("the archive ends early") }
                return [UInt8](data)
            } catch let error as NotesError {
                throw error
            } catch {
                throw fail(error.localizedDescription)
            }
        }
        func write(_ bytes: [UInt8], at offset: UInt64) throws(NotesError) {
            do {
                try file.seek(toOffset: offset)
                try file.write(contentsOf: Data(bytes))
            } catch {
                throw fail(error.localizedDescription)
            }
        }
        func number(_ bytes: [UInt8], _ at: Int, _ width: Int) -> UInt64 {
            (0..<width).reduce(UInt64(0)) { $0 | UInt64(bytes[at + $1]) << (8 * UInt64($1)) }
        }

        // End of central directory: the last 22 bytes, or further back if there is a comment.
        let size: UInt64
        do { size = try file.seekToEnd() } catch { throw fail(error.localizedDescription) }
        guard size >= 22 else { throw fail("too short for a zip") }
        let tailLength = Int(min(size, 22 + 65_535))
        let tail = try read(at: size - UInt64(tailLength), tailLength)
        guard let end = stride(from: tailLength - 22, through: 0, by: -1).first(where: { number(tail, $0, 4) == 0x0605_4b50 }) else {
            throw fail("no end of central directory")
        }
        var entries = number(tail, end + 10, 2), directorySize = number(tail, end + 12, 4), directoryOffset = number(tail, end + 16, 4)
        if entries == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // Zip64: the locator sits just before the end record and points at the zip64 record.
            guard end >= 20, number(tail, end - 20, 4) == 0x0706_4b50 else { throw fail("no zip64 locator") }
            let record = try read(at: number(tail, end - 12, 8), 56)
            guard number(record, 0, 4) == 0x0606_4b50 else { throw fail("no zip64 end record") }
            entries = number(record, 32, 8)
            directorySize = number(record, 40, 8)
            directoryOffset = number(record, 48, 8)
        }
        guard directorySize < 512 * 1024 * 1024 else { throw fail("central directory too large") }
        var directory = try read(at: directoryOffset, Int(directorySize))

        var position = 0
        var localHeaders: [UInt64] = []
        for _ in 0..<entries {
            guard position + 46 <= directory.count, number(directory, position, 4) == 0x0201_4b50 else { throw fail("bad central directory") }
            let nameLength = Int(number(directory, position + 28, 2)), extraLength = Int(number(directory, position + 30, 2))
            let commentLength = Int(number(directory, position + 32, 2))
            guard position + 46 + nameLength + extraLength + commentLength <= directory.count else { throw fail("bad central directory") }
            let name = Array(directory[(position + 46)..<(position + 46 + nameLength)])
            if String(validating: name, as: UTF8.self) != nil {
                directory[position + 9] |= 0x08  // bit 11 of the little-endian flags at +8
                var local = number(directory, position + 42, 4)
                if local == 0xFFFF_FFFF {
                    // The zip64 extra field lists, in order, only the sizes and offset that overflowed.
                    var extra = position + 46 + nameLength
                    let extraEnd = extra + extraLength
                    var found = false
                    while extra + 4 <= extraEnd {
                        let id = number(directory, extra, 2), length = Int(number(directory, extra + 2, 2))
                        if id == 0x0001 {
                            var field = extra + 4
                            if number(directory, position + 24, 4) == 0xFFFF_FFFF { field += 8 }
                            if number(directory, position + 20, 4) == 0xFFFF_FFFF { field += 8 }
                            guard field + 8 <= extra + 4 + length else { throw fail("bad zip64 extra field") }
                            local = number(directory, field, 8)
                            found = true
                            break
                        }
                        extra += 4 + length
                    }
                    guard found else { throw fail("no zip64 offset for an entry") }
                }
                localHeaders.append(local)
            }
            position += 46 + nameLength + extraLength + commentLength
        }
        for offset in localHeaders {
            var header = try read(at: offset, 8)
            guard number(header, 0, 4) == 0x0403_4b50 else { throw fail("bad local header") }
            header[7] |= 0x08
            try write([header[6], header[7]], at: offset + 6)
        }
        try write(directory, at: directoryOffset)
    }
}

extension Array where Element == Block {
    /// Every attachment placed in paragraphs, in order. Tables that stand alone are blocks of
    /// their own and render as Markdown tables.
    var attachmentRefs: [AttachmentRef] {
        flatMap { block -> [AttachmentRef] in
            guard case .paragraph(let p) = block else { return [] }
            return p.content.compactMap { if case .attachment(let ref) = $0 { ref } else { nil } }
        }
    }
}
