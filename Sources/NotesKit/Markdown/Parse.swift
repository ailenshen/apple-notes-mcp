import Foundation

// Markdown → [Block]. The exact inverse of Render.swift for everything it emits, and lenient
// with what a model typically writes (`+` bullets, `####` headings, `\r\n`, unclosed fences).

public enum MarkdownParser {
    public static func parse(_ markdown: String) -> [Block] {
        var lines = markdown.components(separatedBy: "\n")
        // Strip CR only from a CRLF document; a lone CR inside note text is content.
        if lines.count > 1, lines.dropLast().allSatisfy({ $0.hasSuffix("\r") }) {
            lines = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        }
        var blocks: [Block] = []
        var i = 0
        while i < lines.count {
            let (quote, indent, rest) = splitPrefix(lines[i])
            if rest.hasPrefix("```") {
                let prefix = MarkdownRenderer.linePrefix(quote: quote, indent: indent)
                i += 1
                while i < lines.count {
                    let body = lines[i].hasPrefix(prefix) ? String(lines[i].dropFirst(prefix.count)) : lines[i]
                    i += 1
                    if body.hasPrefix("```") { break }
                    blocks.append(.paragraph(Paragraph(kind: .code, indent: indent, quote: quote, content: body.isEmpty ? [] : [.text(TextRun(body))])))
                }
                continue
            }
            if quote == 0, indent == 0, rest.hasPrefix("|"), i + 1 < lines.count, isSeparatorRow(lines[i + 1]) {
                var rows = [splitRow(rest)]
                i += 2
                // A row followed by a separator row starts the next table: adjacent Notes
                // tables have no line between them.
                while i < lines.count, lines[i].hasPrefix("|"), !(i + 1 < lines.count && isSeparatorRow(lines[i + 1])) {
                    rows.append(splitRow(Substring(lines[i])))
                    i += 1
                }
                let width = rows.map(\.count).max() ?? 0
                blocks.append(.table(Table(id: "", rows: rows.map { $0 + Array(repeating: "", count: width - $0.count) })))
                continue
            }
            blocks.append(.paragraph(parseParagraph(quote: quote, indent: indent, rest: rest)))
            i += 1
        }
        return blocks
    }

    static func splitPrefix(_ line: String) -> (quote: Int, indent: Int, rest: Substring) {
        var rest = Substring(line)
        var quote = 0
        while rest.hasPrefix(">") {
            quote += 1
            rest = rest.dropFirst()
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        }
        var indent = 0
        while true {
            if rest.hasPrefix("  ") { rest = rest.dropFirst(2); indent += 1 }
            else if rest.hasPrefix("\t") { rest = rest.dropFirst(); indent += 1 }
            else { break }
        }
        if rest.hasPrefix(" ") { rest = rest.dropFirst() }  // a stray odd space is not content
        return (quote, indent, rest)
    }

    static func parseParagraph(quote: Int, indent: Int, rest: Substring) -> Paragraph {
        let markers: [(String, ParagraphKind)] = [
            ("- [ ] ", .checklist(done: false)), ("- [x] ", .checklist(done: true)), ("- [X] ", .checklist(done: true)),
            ("### ", .subheading), ("## ", .heading), ("# ", .title),
            ("- ", .dash), ("* ", .bullet), ("+ ", .dash),
        ]
        var kind = ParagraphKind.body
        var text = rest
        if let (marker, k) = markers.first(where: { rest.hasPrefix($0.0) }) {
            kind = k
            text = rest.dropFirst(marker.count)
        } else if rest.hasPrefix("#") {
            // `####` and deeper have no Notes style; they become subheadings.
            let hashes = rest.prefix(while: { $0 == "#" })
            if rest.dropFirst(hashes.count).hasPrefix(" ") {
                kind = .subheading
                text = rest.dropFirst(hashes.count + 1)
            }
        } else {
            let digits = rest.prefix(while: \.isASCIIDigit)
            if !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(". ") {
                kind = .numbered
                text = rest.dropFirst(digits.count + 2)
            }
        }
        return Paragraph(kind: kind, indent: indent, quote: quote, content: parseInline(String(text)))
    }

    // MARK: Inline

    static func parseInline(_ source: String) -> [Inline] {
        let chars = Array(source)
        var out: [Inline] = []
        var buffer = ""
        var marks: Marks = []
        var stars: [Marks] = []  // open italic/bold, innermost last
        func flush() {
            if !buffer.isEmpty { out.append(.text(TextRun(buffer, marks: marks))) }
            buffer = ""
        }
        func has(_ token: String, at i: Int) -> Bool {
            let t = Array(token)
            return i + t.count <= chars.count && Array(chars[i..<(i + t.count)]) == t
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                buffer.append(chars[i + 1])
                i += 2
                continue
            }
            if let (token, mark, opening) = [("<mark>", Marks.highlight, true), ("</mark>", .highlight, false),
                ("<u>", .underline, true), ("</u>", .underline, false)].first(where: { has($0.0, at: i) })
            {
                flush()
                if opening { marks.insert(mark) } else { marks.remove(mark) }
                i += token.count
                continue
            }
            if has("~~", at: i) {
                flush()
                marks.formSymmetricDifference(.strike)
                i += 2
                continue
            }
            if c == "*" {
                let count = chars[i...].prefix(while: { $0 == "*" }).count
                if let plan = starPlan(count: count, open: stars) {
                    flush()
                    for _ in 0..<plan.closes { marks.remove(stars.removeLast()) }
                    for mark in plan.opens {
                        marks.insert(mark)
                        stars.append(mark)
                    }
                } else {
                    buffer += String(repeating: "*", count: count)
                }
                i += count
                continue
            }
            if c == "!", has("![", at: i), let (label, target, end) = bracketLink(chars, from: i + 1),
                target.hasPrefix("attachment:")
            {
                flush()
                let parts = label.split(separator: ":", maxSplits: 1)
                let kind = parts.first.map { String($0) } ?? ""
                let display = parts.count > 1 ? String(parts[1].dropFirst(parts[1].hasPrefix(" ") ? 1 : 0)) : ""
                out.append(.attachment(AttachmentRef(id: String(target.dropFirst("attachment:".count)), kind: kind, label: display)))
                i = end
                continue
            }
            if c == "[", let (label, target, end) = bracketLink(chars, from: i) {
                flush()
                out.append(.text(TextRun(label, marks: marks, link: target)))
                i = end
                continue
            }
            buffer.append(c)
            i += 1
        }
        flush()
        return out.normalized()
    }

    /// Reads `[label](target)` starting at an opening bracket, honouring backslash escapes.
    /// Returns nil when the text is not a complete link, so it stays literal.
    static func bracketLink(_ chars: [Character], from start: Int) -> (String, String, Int)? {
        guard chars[start] == "[" else { return nil }
        var label = ""
        var i = start + 1
        while i < chars.count, chars[i] != "]" {
            if chars[i] == "\\", i + 1 < chars.count { i += 1 }
            label.append(chars[i])
            i += 1
        }
        guard i + 1 < chars.count, chars[i] == "]", chars[i + 1] == "(" else { return nil }
        var target = ""
        i += 2
        while i < chars.count, chars[i] != ")" {
            if chars[i] == "\\", i + 1 < chars.count { i += 1 }
            target.append(chars[i])
            i += 1
        }
        guard i < chars.count else { return nil }
        return (label, target, i + 1)
    }

    /// Splits a run of `*` into closes (from the innermost open mark) and then opens in the
    /// renderer's canonical order (italic outside bold). Fewest closes wins. A mark may be
    /// closed and reopened only when an outer mark closes with it, as the renderer does.
    static func starPlan(count: Int, open: [Marks]) -> (closes: Int, opens: [Marks])? {
        let width: (Marks) -> Int = { $0 == .bold ? 2 : 1 }
        var closedWidth = 0
        for closes in 0...open.count {
            if closes > 0 { closedWidth += width(open[open.count - closes]) }
            if closedWidth > count { return nil }
            let stillOpen = Set(open.prefix(open.count - closes).map(\.rawValue))
            let closed = open.suffix(closes)
            let remaining = count - closedWidth
            let candidates: [[Marks]] = [[], [.italic], [.bold], [.italic, .bold]]
            for opens in candidates where opens.reduce(0, { $0 + width($1) }) == remaining {
                if opens.contains(where: { stillOpen.contains($0.rawValue) }) { continue }
                let reopened = opens.filter { closed.contains($0) }
                if !reopened.isEmpty, !closed.contains(where: { !opens.contains($0) }) { continue }
                return (closes, opens)
            }
        }
        return nil
    }

    // MARK: Tables

    static func isSeparatorRow(_ line: String) -> Bool {
        let cells = splitRow(Substring(line))
        return !cells.isEmpty && cells.allSatisfy { cell in
            let t = cell.trimmingCharacters(in: .whitespaces)
            return t.count >= 3 && t.allSatisfy { "-:".contains($0) }
        }
    }

    static func splitRow(_ line: Substring) -> [String] {
        var cells: [String] = []
        var cell = ""
        let chars = Array(line)
        var i = chars.first == "|" ? 1 : 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                cell.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "|" {
                cells.append(cell)
                cell = ""
            } else if chars[i...].starts(with: "<br>") {
                cell.append("\n")
                i += 4
                continue
            } else {
                cell.append(c)
            }
            i += 1
        }
        if !cell.trimmingCharacters(in: .whitespaces).isEmpty { cells.append(cell) }
        return cells.map { c in
            var s = Substring(c)
            if s.hasPrefix(" ") { s = s.dropFirst() }
            if s.hasSuffix(" ") { s = s.dropLast() }
            return String(s)
        }
    }
}
