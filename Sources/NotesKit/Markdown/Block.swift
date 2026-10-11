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
    /// Joins neighbouring text runs that look the same, so hidden attributes that split
    /// runs (font, timestamps) do not show up as separate runs.
    func coalesced() -> [Inline] {
        var out: [Inline] = []
        for item in self {
            if case .text(let next) = item, case .text(let last)? = out.last, last.marks == next.marks,
                last.link == next.link
            {
                out[out.count - 1] = .text(TextRun(last.text + next.text, marks: last.marks, link: last.link))
            } else if case .text(let next) = item, next.text.isEmpty {
                continue
            } else {
                out.append(item)
            }
        }
        return out
    }
}
