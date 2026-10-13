import Foundation

// [Block] → Markdown. One note paragraph is one Markdown line, so the model can edit the
// text and write it back without the structure shifting. Parse.swift is the exact inverse
// for everything rendered here; keep the two files in step.

public enum MarkdownRenderer {
    /// Canonical nesting, outermost first. A fixed order keeps delimiters from clumping
    /// ambiguously when neighbouring runs differ in marks.
    static let markOrder: [(Marks, open: String, close: String)] = [
        (.highlight, "<mark>", "</mark>"),
        (.underline, "<u>", "</u>"),
        (.strike, "~~", "~~"),
        (.italic, "*", "*"),
        (.bold, "**", "**"),
    ]

    /// `attachment` may give the Markdown for an attachment instead of its placeholder; the export
    /// uses it to link original files. Such output is for reading, and does not parse back.
    public static func render(_ blocks: [Block], attachment: ((AttachmentRef) -> String?)? = nil) -> String {
        var lines: [String] = []
        var numbering: [Int: Int] = [:]  // indent → last number, for consecutive numbered items
        var index = 0
        while index < blocks.count {
            switch blocks[index] {
            case .table(let table):
                numbering.removeAll()
                lines += renderTable(table)
                index += 1
            case .paragraph(let p) where p.kind == .code:
                numbering.removeAll()
                // Consecutive monospace paragraphs at the same level share one fence.
                let prefix = linePrefix(quote: p.quote, indent: p.indent)
                lines.append(prefix + "```")
                while index < blocks.count, case .paragraph(let c) = blocks[index], c.kind == .code,
                    c.quote == p.quote, c.indent == p.indent
                {
                    lines.append(prefix + c.plainText)
                    index += 1
                }
                lines.append(prefix + "```")
            case .paragraph(let p):
                var marker: String
                switch p.kind {
                case .title: marker = "# "
                case .heading: marker = "## "
                case .subheading: marker = "### "
                case .body, .code: marker = ""
                case .bullet: marker = "* "
                case .dash: marker = "- "
                case .checklist(let done): marker = done ? "- [x] " : "- [ ] "
                case .numbered:
                    let n = (numbering[p.indent] ?? 0) + 1
                    marker = "\(n). "
                }
                switch p.kind {
                case .numbered:
                    numbering = numbering.filter { $0.key <= p.indent }
                    numbering[p.indent] = Int(marker.prefix(while: \.isASCIIDigit))
                case .bullet, .dash, .checklist:
                    numbering = numbering.filter { $0.key < p.indent }
                default:
                    numbering.removeAll()
                }
                var text = renderInline(p.content, attachment: attachment)
                if p.kind == .body, needsLineEscape(text) { text = "\\" + text }
                lines.append(linePrefix(quote: p.quote, indent: p.indent) + marker + text)
                index += 1
            }
        }
        return lines.joined(separator: "\n")
    }

    static func linePrefix(quote: Int, indent: Int) -> String {
        String(repeating: "> ", count: quote) + String(repeating: "  ", count: indent)
    }

    /// A body line that would otherwise be read as a heading, list, quote, fence, table
    /// or indentation gets a leading backslash.
    static func needsLineEscape(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if "#>| \t".contains(first) { return true }
        if text.hasPrefix("* ") || text.hasPrefix("- ") || text.hasPrefix("```") { return true }
        let digits = text.prefix(while: \.isASCIIDigit)
        return !digits.isEmpty && text.dropFirst(digits.count).hasPrefix(". ")
    }

    static func renderInline(_ content: [Inline], attachment: ((AttachmentRef) -> String?)? = nil) -> String {
        var out = ""
        var open: [Marks] = []  // in canonical order
        func transition(to marks: Marks) {
            var keep = 0
            while keep < open.count, marks.contains(open[keep]) { keep += 1 }
            for mark in open[keep...].reversed() { out += markOrder.first { $0.0 == mark }!.close }
            open.removeSubrange(keep...)
            for (mark, opener, _) in markOrder where marks.contains(mark) && !open.contains(mark) {
                out += opener
                open.append(mark)
            }
        }
        for item in content {
            switch item {
            case .text(let run):
                transition(to: run.marks)
                let text = escapeText(run.text)
                if let link = run.link {
                    out += "[" + text + "](" + escapeURL(link) + ")"
                } else {
                    out += text
                }
            case .attachment(let ref):
                transition(to: [])
                if let replacement = attachment?(ref) {
                    out += replacement
                    continue
                }
                out += "![" + escapeText(ref.label.isEmpty ? ref.kind : ref.kind + ": " + ref.label) + "](attachment:" + ref.id + ")"
            }
        }
        transition(to: [])
        return out
    }

    /// Escapes only what the parser would otherwise treat as syntax. `_` is left alone so
    /// identifiers like MCP_Test stay readable.
    static func escapeText(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        for (i, c) in chars.enumerated() {
            switch c {
            case "\\", "*", "[", "]":
                out += "\\" + String(c)
            case "~" where i == 0 || i == chars.count - 1 || chars[i - 1] == "~" || chars[i + 1] == "~":
                out += "\\~"
            case "<":
                let rest = String(chars[i...])
                if ["<u>", "</u>", "<mark>", "</mark>"].contains(where: rest.hasPrefix) { out += "\\<" } else { out += "<" }
            default:
                out.append(c)
            }
        }
        return out
    }

    static func escapeURL(_ url: String) -> String {
        url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ")", with: "\\)")
    }

    static func renderTable(_ table: Table) -> [String] {
        guard let header = table.rows.first else { return ["|  |", "| --- |"] }
        func row(_ cells: [String]) -> String {
            "| " + cells.map(escapeCell).joined(separator: " | ") + " |"
        }
        return [row(header), "|" + String(repeating: " --- |", count: header.count)] + table.rows.dropFirst().map(row)
    }

    static func escapeCell(_ cell: String) -> String {
        if cell.isEmpty { return "" }
        return cell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "<br>", with: "\\<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}

extension ParagraphKind {
    var isChecklist: Bool {
        if case .checklist = self { return true }
        return false
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
