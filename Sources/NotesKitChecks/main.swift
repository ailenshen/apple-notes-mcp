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
    print(failures == 0 ? "unit: all passed" : "unit: \(failures) failed")
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
    await step("removing an attachment-free table and full replace") {
        let replacement = MarkdownParser.parse("""
            # \(title) replaced
            Completely new body.
            - [ ] fresh task
            | A | B | C |
            | --- | --- | --- |
            | 1 | 2 | 3 |
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
case "create":
    // Reads Markdown from stdin and creates a note with it (write guard on).
    let markdown = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    do {
        let outcome = try NotesRepository(writeGuardTitlePrefix: "MCP Test ").create(folderID: nil, blocks: MarkdownParser.parse(markdown))
        print(outcome.id, outcome.mismatch ?? "exact")
        let report = try await SyncCoordinator(repository: NotesRepository()).settle(id: outcome.id)
        print("synced:", report.synced)
    } catch { print("error:", error) }
default: print("usage: NotesKitChecks unit|roundtrip|render <id>…|writetest|create < markdown")
}
exit(failures == 0 ? 0 : 1)
