import Foundation

// Intermediate model between a note's attributed string and Markdown. It holds only what
// Markdown shows; hidden formatting (color, font, alignment, edit timestamps) stays in the
// note and is kept by editing in place, never by round-tripping through this model.

public enum Block: Sendable, Equatable {
    case paragraph(Paragraph)
    case table(Table)
}

public struct Paragraph: Sendable, Equatable {
    public var kind: ParagraphKind
    public var indent: Int
    public var quote: Int
    public var content: [Inline]

    public init(kind: ParagraphKind, indent: Int = 0, quote: Int = 0, content: [Inline]) {
        self.kind = kind
        self.indent = indent
        self.quote = quote
        self.content = content
    }

    public var plainText: String {
        content.map {
            switch $0 {
            case .text(let run): run.text
            case .attachment: "\u{FFFC}"
            }
        }.joined()
    }
}

/// Notes paragraph styles: 0 title, 1 heading, 2 subheading, 3 body, 4 monospace,
/// 100 bullet, 101 dash, 102 numbered, 103 checklist.
public enum ParagraphKind: Sendable, Equatable {
    case title, heading, subheading, body, code, bullet, dash, numbered
    case checklist(done: Bool)
}

public struct Marks: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let bold = Marks(rawValue: 1)
    public static let italic = Marks(rawValue: 2)
    public static let strike = Marks(rawValue: 4)
    public static let underline = Marks(rawValue: 8)
    public static let highlight = Marks(rawValue: 16)
}

public struct TextRun: Sendable, Equatable {
    public var text: String
    public var marks: Marks
    public var link: String?

    public init(_ text: String, marks: Marks = [], link: String? = nil) {
        self.text = text
        self.marks = marks
        self.link = link
    }
}

public enum Inline: Sendable, Equatable {
    case text(TextRun)
    case attachment(AttachmentRef)
}

/// An attachment kept as an opaque placeholder. Identity is the id; kind and label are
/// display information for the model, so equality looks at the id only.
public struct AttachmentRef: Sendable, Equatable {
    public var id: String
    public var kind: String
    public var label: String

    public init(id: String, kind: String, label: String) {
        self.id = id
        self.kind = kind
        self.label = label
    }

    public static func == (a: AttachmentRef, b: AttachmentRef) -> Bool { a.id == b.id }
}

/// A Notes table. Cells are plain text: Markdown tables cannot carry cell formatting.
public struct Table: Sendable, Equatable {
    public var id: String
    public var rows: [[String]]

    public init(id: String, rows: [[String]]) {
        self.id = id
        self.rows = rows
    }

    /// Identity is positional in Markdown (no table ids are printed), so compare content.
    public static func == (a: Table, b: Table) -> Bool { a.rows == b.rows }
}

extension Array where Element == Inline {
    /// The form both Reader and MarkdownParser produce. Neighbouring text runs that look the
    /// same are joined, so hidden attributes that split runs (font, timestamps) do not show up
    /// as separate runs. Bold, italic and strikethrough are taken off whitespace at the edges of
    /// each span that carries them, because Markdown cannot open `**`, `*` or `~~` before a space or close one after it: `## 🌾** 草原**`
    /// shows literal asterisks in every other Markdown reader, exported files included (seen
    /// 2026-10-14). On a space these marks hardly show. Underline and highlight are HTML tags,
    /// which allow spaces, so they keep them.
    /// 当需要兼顾 CommonMark 对标点的 flanking 规则（例如 `字**「粗」**字` 同样不被识别）时，在这里一并处理。
    func normalized() -> [Inline] {
        var units: [InlineUnit] = []
        for item in self {
            switch item {
            case .text(let run): units += run.text.map { .character($0, run.marks, run.link) }
            case .attachment(let ref): units.append(.attachment(ref))
            }
        }
        func carries(_ i: Int, _ mark: Marks) -> Bool {
            if case .character(_, let marks, _) = units[i] { return marks.contains(mark) }
            return false
        }
        for mark in [Marks.bold, .italic, .strike] {
            var start = 0
            while start < units.count {
                guard carries(start, mark) else {
                    start += 1
                    continue
                }
                var end = start
                while end + 1 < units.count, carries(end + 1, mark) { end += 1 }
                func lift(_ i: Int) -> Bool {
                    guard case .character(let c, var marks, let link) = units[i], c.isWhitespace else { return false }
                    marks.remove(mark)
                    units[i] = .character(c, marks, link)
                    return true
                }
                var first = start
                while first <= end, lift(first) { first += 1 }
                var last = end
                while last > first, lift(last) { last -= 1 }
                start = end + 1
            }
        }
        // Rebuilt run by run (not character by character), so long paragraphs stay linear.
        var out: [Inline] = []
        var run: TextRun?
        for unit in units {
            switch unit {
            case .character(let c, let marks, let link):
                if run?.marks == marks, run?.link == link {
                    run?.text.append(c)
                } else {
                    if let run { out.append(.text(run)) }
                    run = TextRun(String(c), marks: marks, link: link)
                }
            case .attachment(let ref):
                if let run { out.append(.text(run)) }
                run = nil
                out.append(.attachment(ref))
            }
        }
        if let run { out.append(.text(run)) }
        return out
    }
}

/// One character of a paragraph with its marks and link, or an attachment (see `normalized`).
private enum InlineUnit {
    case character(Character, Marks, String?)
    case attachment(AttachmentRef)
}
