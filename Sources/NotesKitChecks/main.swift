import Foundation
import NotesKit

// Runnable checks for NotesKit. `unit` needs no Notes access; `roundtrip` reads every note
// (read-only) and checks that render → parse gives back the same blocks.
// 当工具链带 XCTest 或 Swift Testing 宏时，把 unit 部分重构为正式测试。

setvbuf(stdout, nil, _IONBF, 0)
var failures = 0

@MainActor
func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition {
        failures += 1
        print("FAIL", message())
    }
}

func text(_ s: String, _ marks: Marks = [], link: String? = nil) -> Inline { .text(TextRun(s, marks: marks, link: link)) }
func para(_ kind: ParagraphKind, _ content: [Inline], indent: Int = 0, quote: Int = 0) -> Block {
    .paragraph(Paragraph(kind: kind, indent: indent, quote: quote, content: content))
}

@MainActor
func unitChecks() {
    let cases: [[Block]] = [
        [para(.title, [text("MCP_Test 标题")]), para(.body, []), para(.body, [text("plain * star [x] \\ back ~tilde~~ <u>tag")])],
        [para(.body, [text("a", .bold), text("b", .italic), text("c", [.bold, .italic]), text("d", .italic), text("e")])],
        [para(.body, [text("x", [.italic, .bold]), text("y", .bold), text("z", [.highlight, .underline, .strike])])],
        [para(.body, [text("link", .bold, link: "https://e.com/a_(b)"), text(" tail")])],
        [para(.heading, [text("H")]), para(.subheading, [text("S")]), para(.bullet, [text("b")], indent: 1),
         para(.dash, [text("d")]), para(.numbered, [text("one")]), para(.numbered, [text("two")]),
         para(.checklist(done: false), [text("todo")]), para(.checklist(done: true), [text("done")])],
        [para(.body, [text("# not a heading")]), para(.body, [text("- not a list")]), para(.body, [text("12. not numbered")]),
         para(.body, [text("> not quote")]), para(.body, [text(" leading space")]), para(.body, [text("| not table")])],
        [para(.body, [text("quoted")], quote: 1), para(.dash, [text("quoted list")], indent: 2, quote: 2)],
        [para(.code, [text("let x = 1 // *raw*")]), para(.code, []), para(.code, [text("  indented")]), para(.body, [text("after")])],
        [.table(Table(id: "t", rows: [["a|b", "c\nd"], ["", "<br> \\"]])), para(.body, [text("after table")])],
        [para(.body, [text("\tTab start")]), .table(Table(id: "1", rows: [["a"]])), .table(Table(id: "2", rows: [["b"], ["c"]]))],
        [para(.body, [text("see "), .attachment(AttachmentRef(id: "A-1", kind: "image", label: "")),
                      .attachment(AttachmentRef(id: "B-2", kind: "note link", label: "Other [note] → X"))])],
    ]
    for blocks in cases {
        let markdown = MarkdownRenderer.render(blocks)
        let back = MarkdownParser.parse(markdown)
        expect(back == blocks, "round trip\n--- markdown\n\(markdown)\n--- want \(blocks)\n--- got  \(back)")
    }
    // What a model typically writes, read leniently.
    let lenient = MarkdownParser.parse("#### deep\r\n+ plus\r\n**bold *both* bold**\r\n```swift\r\ncode")
    expect(lenient == [para(.subheading, [text("deep")]), para(.dash, [text("plus")]),
        para(.body, [text("bold ", .bold), text("both", [.bold, .italic]), text(" bold", .bold)]),
        para(.code, [text("code")])], "lenient parse: \(lenient)")
    // Folder names may contain "/": paths escape it, and splitting respects that.
    let names = ["Areas", "产品/远程/兼职/接单"]
    expect(FolderPath.join(names) == "Areas/产品\\/远程\\/兼职\\/接单", "folder path escaping: \(FolderPath.join(names))")
    expect(FolderPath.split(FolderPath.join(names)) == names, "folder path split: \(FolderPath.split(FolderPath.join(names)))")
    expect(FolderPath.split(" Projects / Ideas ") == ["Projects", "Ideas"], "plain path split")
    // Short attachment ids: what read_note shows, and what a write maps back.
    let full = [para(.body, [text("pic "), .attachment(AttachmentRef(id: "4E847B23-CDE2-408A-9A26-4E8642E89BA3", kind: "image", label: "")),
                             .attachment(AttachmentRef(id: "10A0BC5E-7917-4E06-B07D-EEECA1E9E9F7", kind: "image", label: ""))])]
    let shown = MarkdownRenderer.render(full.mappingAttachmentIDs(ShortID.of))
    expect(shown.contains("attachment:4E847B23)") && !shown.contains("CDE2"), "short ids in Markdown: \(shown)")
    let written = MarkdownParser.parse(shown.replacingOccurrences(of: "pic ", with: "picture "))
    let expanded = written.expandingAttachmentIDs(from: full)
    expect(expanded.attachmentIDsForChecks == ["4E847B23-CDE2-408A-9A26-4E8642E89BA3", "10A0BC5E-7917-4E06-B07D-EEECA1E9E9F7"],
           "short ids expand back: \(expanded)")
    expect(MarkdownParser.parse("![image](attachment:FFFFFFFF)").expandingAttachmentIDs(from: full).attachmentIDsForChecks == ["FFFFFFFF"],
           "an unknown short id is left for the writer to refuse")
    // Export file names, links and destinations.
    expect(ExportFiles.name("a/b:c\nd") == "a-b-c d", "export name: \(ExportFiles.name("a/b:c\nd"))")
    expect(ExportFiles.name("") == "Untitled" && ExportFiles.name(" \u{FFFC} ") == "Untitled", "empty export name")
    expect(ExportFiles.name("..hidden") == "hidden", "leading dots: \(ExportFiles.name("..hidden"))")
    let long = ExportFiles.name(String(repeating: "档", count: 100))
    expect(long.utf8.count <= 200 && long.count == 66, "long Chinese name cut by bytes: \(long.count) chars, \(long.utf8.count) bytes")
    var used: Set<String> = ["attachments", "manifest.md"]
    let first = ExportFiles.unique("Note", extension: ".md", id: "4E847B23-CDE2-408A-9A26-4E8642E89BA3", in: &used)
    let second = ExportFiles.unique("note", extension: ".md", id: "10A0BC5E-7917-4E06-B07D-EEECA1E9E9F7", in: &used)
    let reserved = ExportFiles.unique("Attachments", id: "4E847B23-CDE2-408A-9A26-4E8642E89BA3", in: &used)
    expect(first == "Note.md" && second == "note (10A0BC5E).md" && reserved == "Attachments (4E847B23)",
           "unique names: \(first), \(second), \(reserved)")
    let link = ExportFiles.link(["attachments", "ID", "IMG 1 (a)档.jpeg"], depth: 2)
    expect(link == "../../attachments/ID/IMG%201%20%28a%29%E6%A1%A3.jpeg", "export link: \(link)")
    for refused in ["relative/path", "~/Library/Exports", "~/Documents", "/"] {
        expect((try? ExportFiles.destination(refused)) == nil, "export destination \(refused) should be refused")
    }
    expect((try? ExportFiles.destination("~/Documents/MCP Test export \(UUID().uuidString).zip")) != nil, "a new path under Documents is accepted")
    // Bold, italic and strikethrough never open after or close before a space; underline and
    // highlight keep their spaces; spaces inside a span stay marked.
    let edges = [para(.heading, [text("🌾"), text(" 草原 ", .bold), text("x"), text(" s ", .strike), text(" i", .italic),
                                 text(" u ", .underline), text("a b", .bold), text(" ", .bold)])]
    let edgeMarkdown = MarkdownRenderer.render(MarkdownParser.parse(MarkdownRenderer.render(edges)))
    expect(edgeMarkdown == "## 🌾 **草原** x ~~s~~  *i*<u> u </u>**a b** ", "edge spaces outside delimiters: \(edgeMarkdown)")
    let normalizedEdges = MarkdownParser.parse(edgeMarkdown)
    expect(MarkdownParser.parse(MarkdownRenderer.render(normalizedEdges)) == normalizedEdges, "normalized form round-trips")
    expect(MarkdownParser.parse("** 粗**") == [para(.body, [text(" "), text("粗", .bold)])], "a parsed edge space is not bold: \(MarkdownParser.parse("** 粗**"))")
    // Extracted descriptions skip separator lines.
    let extracted = DescriptionIndex.extract(fromPlainText: "酒\n\n⸻\n麦卡伦 12年 雪莉桶。饱满。", title: "酒")
    expect(extracted == "麦卡伦 12年 雪莉桶。", "description skips separators: \(extracted)")
    zipNameCheck()
    print(failures == 0 ? "unit: all passed" : "unit: \(failures) failed")
}

/// A zip made by ditto, then marked: every entry must carry the UTF-8 flag, and the archive
/// must still extract with its Chinese names intact.
@MainActor
func zipNameCheck() {
    let files = FileManager.default
    let base = files.temporaryDirectory.appendingPathComponent("MCP Test zip \(UUID().uuidString)")
    defer { try? files.removeItem(at: base) }
    let source = base.appendingPathComponent("导出")
    let archive = base.appendingPathComponent("导出.zip")
    let extracted = base.appendingPathComponent("extracted")
    func ditto(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    do {
        try files.createDirectory(at: source.appendingPathComponent("子文件夹"), withIntermediateDirectories: true)
        try Data("内容".utf8).write(to: source.appendingPathComponent("子文件夹/笔记.md"))
        try Data("ascii".utf8).write(to: source.appendingPathComponent("manifest.md"))
        guard ditto(["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, archive.path]) == 0 else { return expect(false, "ditto failed") }
        try ExportFiles.markNamesAsUTF8(archive)
        let bytes = [UInt8](try Data(contentsOf: archive))
        func flags(_ signature: [UInt8], at offset: Int) -> [UInt8] {
            (0..<(bytes.count - 4)).filter { Array(bytes[$0..<($0 + 4)]) == signature }.map { bytes[$0 + offset] }
        }
        let central = flags([0x50, 0x4b, 0x01, 0x02], at: 9), local = flags([0x50, 0x4b, 0x03, 0x04], at: 7)
        expect(central.count == 4 && local.count == 4, "zip entries: \(central.count) central, \(local.count) local")
        expect((central + local).allSatisfy { $0 & 0x08 != 0 }, "every zip entry is marked UTF-8")
        guard ditto(["-x", "-k", archive.path, extracted.path]) == 0 else { return expect(false, "the marked zip does not extract") }
        let content = try? String(contentsOf: extracted.appendingPathComponent("导出/子文件夹/笔记.md"), encoding: .utf8)
        expect(content == "内容", "the marked zip extracts with its names")
    } catch {
        expect(false, "zip check: \(error)")
    }
}

/// Exports a real folder (read-only for Notes) and checks the output: every note is in the
/// manifest, every copied file is byte-identical to Notes' original, and every link in the
/// Markdown points at a file that exists. The tools cannot create attachments, so this is
/// where exporting originals is proven; e2e covers the rest.
@MainActor
func exportCheck(folder: String, destination: String) async {
    let repository = NotesRepository()
    let start = Date()
    let outcome: ExportOutcome
    do {
        outcome = try await repository.export(folder: folder, to: destination)
    } catch {
        print("export failed:", error)
        failures += 1
        return
    }
    print("export: \(outcome.notes) notes, \(outcome.folders) folders, \(outcome.locked) locked, \(outcome.failed.count) unreadable, "
        + "\(outcome.files) files, \(outcome.missingFiles) missing, \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
    let root = URL(fileURLWithPath: outcome.destination)
    let files = FileManager.default
    let manifest = (try? String(contentsOf: root.appendingPathComponent("manifest.md"), encoding: .utf8)) ?? ""
    let rows = manifest.components(separatedBy: "\n").filter { $0.hasPrefix("| ") && !$0.hasPrefix("| ---") }.count - 1
    expect(rows == outcome.notes, "manifest lists \(rows) notes, not \(outcome.notes)")
    // Copied files against the originals.
    var compared = 0
    let attachments = root.appendingPathComponent("attachments")
    for id in (try? files.contentsOfDirectory(atPath: attachments.path)) ?? [] {
        guard let info = try? repository.attachment(id: id) else {
            expect(false, "attachment \(id) not found in Notes")
            continue
        }
        let sources = info.pages.isEmpty ? [info.file] : info.pages.map(\.file)
        let copies = ((try? files.contentsOfDirectory(atPath: attachments.appendingPathComponent(id).path)) ?? []).sorted()
        for (index, copy) in copies.enumerated() {
            let source = info.pages.isEmpty ? sources.first ?? nil : (Int(copy.dropFirst(5).prefix(2)).flatMap { $0 - 1 < sources.count ? sources[$0 - 1] : nil })
            let copied = attachments.appendingPathComponent(id).appendingPathComponent(copy)
            guard let source, let a = try? Data(contentsOf: source), let b = try? Data(contentsOf: copied) else {
                expect(false, "attachment \(id) file \(index + 1): cannot compare")
                continue
            }
            expect(a == b, "attachment \(id) file \(copy) differs from \(source.path)")
            compared += 1
        }
    }
    // Links in the Markdown.
    var links = 0
    let pattern = try! NSRegularExpression(pattern: #"\]\(((?:\.\./)*attachments/[^)]+)\)"#)
    let markdownFiles = (files.subpaths(atPath: root.path) ?? []).filter { $0.hasSuffix(".md") && $0 != "manifest.md" }
    for path in markdownFiles {
        let file = root.appendingPathComponent(path)
        // Fenced code is the note's own text, links in it included.
        var fenced = false
        let text = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { line in
            if line.trimmingCharacters(in: CharacterSet(charactersIn: "> ")).hasPrefix("```") { fenced.toggle(); return false }
            return !fenced
        }.joined(separator: "\n")
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let target = String(text[Range(match.range(at: 1), in: text)!]).removingPercentEncoding ?? ""
            let resolved = file.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
            expect(files.fileExists(atPath: resolved.path), "\(path) links to a missing file: \(target)")
            links += 1
        }
    }
    print("export: \(compared) files identical to the originals, \(links) links checked")
}

@MainActor
func roundTrip() {
    let repository = NotesRepository()
    let start = Date()
    var notes = 0, failed = 0, readErrors = 0
    var features: [String: Int] = [:]
    var mismatchByKind: [String: Int] = [:]
    var examples: [String] = []
    do {
        for id in try repository.noteIDs() {
            let blocks: [Block]
            do {
                blocks = try repository.blocks(id: id)
            } catch {
                readErrors += 1
                if readErrors <= 3 { print("read error", id, error) }
                continue
            }
            notes += 1
            for block in blocks { note(features: &features, block) }
            let markdown = MarkdownRenderer.render(blocks)
            let back = MarkdownParser.parse(markdown)
            if back == blocks { continue }
            failed += 1
            let index = zip(blocks, back).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset ?? min(blocks.count, back.count)
            let original = index < blocks.count ? blocks[index] : nil
            mismatchByKind[original.map(describe) ?? "count \(blocks.count) vs \(back.count)", default: 0] += 1
            if examples.count < 12 {
                examples.append("\(id) block \(index)\n  want \(original.map { "\($0)" } ?? "-")\n  got  \(index < back.count ? "\(back[index])" : "-")")
            }
        }
    } catch {
        print("cannot list notes:", error)
        failures += 1
        return
    }
    print("roundtrip: \(notes) notes, \(failed) mismatched, \(readErrors) unreadable, \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
    for (k, v) in mismatchByKind.sorted(by: { $0.value > $1.value }) { print("  mismatch \(k): \(v)") }
    for (k, v) in features.sorted(by: { $0.key < $1.key }) { print("  feature \(k): \(v)") }
    examples.forEach { print($0) }
    if failed > 0 || readErrors > 0 { failures += 1 }
}

func describe(_ block: Block) -> String {
    switch block {
    case .table: "table"
    case .paragraph(let p): "\(p.kind)"
    }
}

func note(features: inout [String: Int], _ block: Block) {
    switch block {
    case .table(let t):
        features["table", default: 0] += 1
        if t.rows.joined().contains(where: { $0.contains("|") || $0.contains("\n") }) { features["table cell with | or newline", default: 0] += 1 }
    case .paragraph(let p):
        for item in p.content {
            switch item {
            case .attachment(let a): features["attachment \(a.kind)", default: 0] += 1
            case .text(let run):
                if run.marks.rawValue.nonzeroBitCount > 1 { features["run with several marks", default: 0] += 1 }
                if run.link != nil, !run.marks.isEmpty { features["link with marks", default: 0] += 1 }
                if run.text.contains("\u{2028}") || run.text.contains("\r") { features["line separator in text", default: 0] += 1 }
            }
        }
        if p.kind == .code, p.plainText.hasPrefix("```") { features["code line starting with fence", default: 0] += 1 }
    }
}

/// G5: write-side round trip on a fresh "MCP Test" note, then delete it.
@MainActor
func writeTest() async {
    let repository = NotesRepository(writeGuardTitlePrefix: "MCP Test ")
    let sync = SyncCoordinator(repository: repository)
    let title = "MCP Test G5 \(UUID().uuidString.prefix(8))"
    let markdown = """
        # \(title)
        Intro with **bold**, *italic*, ~~strike~~, <u>underline</u>, <mark>highlight</mark> and a [link](https://example.com/a_b).

        ## Lists
        * bullet
          * nested bullet
        - dash
        1. first
        2. second
        - [ ] open task
        - [x] done task
        > quoted line
        ```
        let code = "raw *text*"
        ```
        | Name | Score |
        | --- | --- |
        | Alice | 90 |
        ### Tail
        Colored words stay red. Near text here.
        """
    let target = MarkdownParser.parse(markdown)
    var id = ""
    func step(_ name: String, _ body: () async throws -> String?) async {
        do {
            if let problem = try await body() { expect(false, "\(name): \(problem)") } else { print("ok  ", name) }
        } catch {
            expect(false, "\(name): \(error)")
        }
    }
    await step("create reads back exactly") {
        let outcome = try repository.create(folderID: nil, blocks: target)
        id = outcome.id
        print("     created", id)
        return outcome.mismatch
    }
    guard !id.isEmpty else { return }
    await step("create uploads to iCloud") {
        let report = try await sync.settle(id: id)
        return report.synced ? nil : "not synced after \(report.total)"
    }
    await step("title comes from the first line") {
        let t = try repository.note(id: id).title
        return t == title ? nil : "title is \(t)"
    }
    await step("hidden color survives an edit nearby") {
        try repository.diagnosticColor(id: id, text: "Colored words")
        guard try repository.diagnosticAttributeKeys(id: id, text: "Colored words").contains("TTColor") else { return "color was not set" }
        let before = try repository.modificationDate(id: id)
        try await Task.sleep(for: .seconds(1.2))
        let outcome = try repository.update(id: id, expectedVersion: nil) { blocks throws(NotesError) in
            MarkdownParser.parse(MarkdownRenderer.render(blocks).replacingOccurrences(of: "Near text here.", with: "Near text **edited** here.")
                .replacingOccurrences(of: "stay red.", with: "stay red!"))
        }
        if let mismatch = outcome.mismatch { return mismatch }
        let keys = try repository.diagnosticAttributeKeys(id: id, text: "Colored words")
        if !keys.contains("TTColor") { return "color lost after edit; keys \(keys)" }
        let after = try repository.modificationDate(id: id)
        return after > before ? nil : "modification date did not move (\(before) → \(after))"
    }
    await step("stale version is refused") {
        do {
            _ = try repository.update(id: id, expectedVersion: "000000000000") { $0 }
            return "write with a wrong version was accepted"
        } catch NotesError.conflict {
            return nil
        }
    }
    await step("title rename and checklist toggle") {
        let current = try repository.blocks(id: id)
        let version = NotesRepository.version(of: current)
        let outcome = try repository.update(id: id, expectedVersion: version) { blocks throws(NotesError) in
            MarkdownParser.parse(MarkdownRenderer.render(blocks).replacingOccurrences(of: "# \(title)", with: "# \(title) renamed")
                .replacingOccurrences(of: "- [ ] open task", with: "- [x] open task"))
        }
        if let mismatch = outcome.mismatch { return mismatch }
        return outcome.title == "\(title) renamed" ? nil : "title is \(outcome.title)"
    }
    await step("table edited in place keeps cell formatting") {
        guard let tableID = try repository.diagnosticTableID(id: id) else { return "no table" }
        try repository.diagnosticBoldTableCell(tableID: tableID, text: "Alice")
        let outcome = try repository.update(id: id, expectedVersion: nil) { blocks throws(NotesError) in
            MarkdownParser.parse(MarkdownRenderer.render(blocks)
                .replacingOccurrences(of: "| Name | Score |\n| --- | --- |\n| Alice | 90 |",
                                      with: "| Name | Score | Grade |\n| --- | --- | --- |\n| Alice Smith | 95 | A |\n| Bob | 80 | B |"))
        }
        if let mismatch = outcome.mismatch { return mismatch }
        guard try repository.diagnosticTableID(id: id) == tableID else { return "the table was rebuilt instead of edited" }
        let hints = try repository.diagnosticTableCellHints(tableID: tableID, text: "Alice")
        return hints.map { $0 & 1 == 1 } == true ? nil : "bold lost in the edited cell (TTHints \(hints.map(String.init) ?? "none"))"
    }
    await step("table edit uploads to iCloud (note and table)") {
        let report = try await sync.settle(id: id)
        return report.synced ? nil : "not synced after \(report.total): \(report.state)"
    }
    await step("removing a table, and a full replace with a new table holding a line break in a cell") {
        let replacement = MarkdownParser.parse("""
            # \(title) replaced
            Completely new body.
            - [ ] fresh task
            | A | B | C |
            | --- | --- | --- |
            | 1 | 2<br>two | 3 |
            """)
        let outcome = try repository.update(id: id, expectedVersion: nil) { _ throws(NotesError) in replacement }
        return outcome.mismatch
    }
    await step("edits upload to iCloud") {
        let report = try await sync.settle(id: id)
        return report.synced ? nil : "not synced after \(report.total)"
    }
    print("     note left for inspection:", id)
}

let command = CommandLine.arguments.dropFirst().first ?? "unit"
switch command {
case "unit": unitChecks()
case "roundtrip": roundTrip()
case "writetest": await writeTest()
case "export":
    // export <folder> <new directory>: read-only for Notes; writes only the directory.
    let args = Array(CommandLine.arguments.dropFirst(2))
    if args.count == 2 { await exportCheck(folder: args[0], destination: args[1]) } else { print("usage: NotesKitChecks export <folder> <new directory>") }
case "markzip":
    // markzip <archive>: marks the names in an existing zip as UTF-8, to try zip64 archives
    // made by other tools (ditto writes zip64 only past 4 GB).
    if let path = CommandLine.arguments.dropFirst(2).first {
        do { try ExportFiles.markNamesAsUTF8(URL(fileURLWithPath: path)); print("marked") } catch { print("error:", error); failures += 1 }
    } else { print("usage: NotesKitChecks markzip <archive>") }
case "create":
    // Reads Markdown from stdin and creates a note with it (write guard on).
    let markdown = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    do {
        let outcome = try NotesRepository(writeGuardTitlePrefix: "MCP Test ").create(folderID: nil, blocks: MarkdownParser.parse(markdown))
        print(outcome.id, outcome.mismatch ?? "exact")
        let report = try await SyncCoordinator(repository: NotesRepository()).settle(id: outcome.id)
        print("synced:", report.synced)
    } catch { print("error:", error) }
default: print("usage: NotesKitChecks unit|roundtrip|render <id>…|writetest|export <folder> <dir>|markzip <archive>|create < markdown")
}
exit(failures == 0 ? 0 : 1)
