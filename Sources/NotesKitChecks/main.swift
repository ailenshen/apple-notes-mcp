import Foundation
import NotesKit

// Runnable checks for NotesKit. `unit` needs no Notes access; `roundtrip` reads every note
// (read-only) and checks that render → parse gives back the same blocks.
// 当工具链带 XCTest 或 Swift Testing 宏时，把 unit 部分重构为正式测试。

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

let command = CommandLine.arguments.dropFirst().first ?? "unit"
switch command {
case "unit": unitChecks()
case "roundtrip": roundTrip()
case "render":
    let repository = NotesRepository()
    for id in CommandLine.arguments.dropFirst(2) {
        do { print(MarkdownRenderer.render(try repository.blocks(id: id))) } catch { print("error:", error) }
        print("-----")
    }
default: print("usage: NotesKitChecks unit|roundtrip|render <id>…")
}
exit(failures == 0 ? 0 : 1)
