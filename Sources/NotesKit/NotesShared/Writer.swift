import CoreData
import Foundation
import NotesSharedShim

/// Brings a note's body to a target [Block] with the fewest in-place edits.
///
/// Reads during an edit come from a local mirror kept in lockstep with Notes' mergeable
/// string, because `-[ICTTMergeableString attributedString]` is a cached snapshot until
/// `endEditing` (verified 2026-10-12). The whole edit first runs on the mirror alone and is
/// checked against the target; only then is it replayed on the real note. Every write
/// (create, append, edit, full update) goes through `apply`, so they all share one path:
/// unchanged paragraphs are untouched, changed paragraphs are edited character by
/// character, and only the attributes Markdown shows are set. Hidden formatting (color,
/// font, alignment) on text that did not change survives every edit.
@MainActor
final class Writer {
    let note: NSManagedObject
    let mergeable: AnyObject
    let context: NSManagedObjectContext
    let original: NSAttributedString
    private(set) var working: NSMutableAttributedString
    /// When true, edits change only the mirror: no note data, no attachments.
    private var dryRun = false
    /// Tables created during a dry run, keyed by their placeholder id, for verification.
    private var pendingTables: [String: [[String]]] = [:]
    /// Real table attachments made before the editing session opens, in insertion order.
    /// Creating one inside beginEditing/endEditing leaves the saved body truncated.
    private var preparedTables: [NSObject] = []

    static let styleKey = NSAttributedString.Key("TTStyle")
    static let hintsKey = NSAttributedString.Key("TTHints")
    static let strikeKey = NSAttributedString.Key("TTStrikethrough")
    static let underlineKey = NSAttributedString.Key("TTUnderline")
    static let emphasisKey = NSAttributedString.Key("TTEmphasis")
    static let linkKey = NSAttributedString.Key("NSLink")
    static let timestampKey = NSAttributedString.Key("TTTimestamp")
    /// Notes' highlight color index used when new text gets highlighted.
    static let defaultEmphasis = 1

    init(note: NSManagedObject, context: NSManagedObjectContext) throws(NotesError) {
        guard let document = try send(note, "document"), let mergeable = try send(document, "mergeableString") else {
            throw .frameworkChanged("note has no editable document")
        }
        guard let string = try send(mergeable, "attributedString") as? NSAttributedString else {
            throw .frameworkChanged("mergeable string has no attributed string")
        }
        self.note = note
        self.mergeable = mergeable
        self.context = context
        self.original = NSAttributedString(attributedString: string)
        self.working = NSMutableAttributedString(attributedString: string)
    }

    var current: NSAttributedString {
        get throws(NotesError) { working }
    }

    // MARK: Apply

    func apply(_ target: [Block]) throws(NotesError) {
        let old = try Reader(context: context).blocks(original)
        try checkAttachments(old: old, new: target)
        let attachmentAttributes = Self.attachmentAttributes(in: original)
        let script = Self.editScript(old: old, new: target)
        if script.isEmpty { return }

        // Rehearse on the mirror and check the result before touching the note.
        dryRun = true
        try run(script, attachments: attachmentAttributes)
        let rehearsed = try Reader(context: context, pendingTables: pendingTables).blocks(working)
        guard rehearsed == target else {
            let index = zip(rehearsed, target).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset ?? min(rehearsed.count, target.count)
            throw .failed("internal check failed before writing (line \(index + 1)); the note was not changed")
        }
        dryRun = false
        pendingTables = [:]
        working = NSMutableAttributedString(attributedString: original)
        for case .insert(_, let blocks) in script {
            for case .table(let table) in blocks { preparedTables.append(try makeTable(table)) }
        }
        preparedTables.reverse()  // consumed with popLast in script order

        try call(note, "beginEditing") { try NSShim.send(note, selector: "beginEditing") }
        try run(script, attachments: attachmentAttributes)
        // In-place edits do not touch the modification date by themselves (verified 2026-10-12).
        note.setValue(Date(), forKey: "modificationDate")
        try call(note, "endEditing") { try NSShim.send(note, selector: "endEditing") }
        try call(note, "saveNoteData") { try NSShim.send(note, selector: "saveNoteData") }
    }

    /// The script runs from the end of the note backwards, so earlier line indexes stay valid.
    private func run(_ script: [Op], attachments: [String: [NSAttributedString.Key: Any]]) throws(NotesError) {
        for op in script {
            switch op {
            case .delete(let line, let block):
                try deleteLine(line)
                if case .table(let table) = block, !dryRun { try markAttachmentDeleted(table.id) }
            case .insert(let line, let blocks):
                try insertLines(blocks, at: line)
            case .modify(let line, let from, let to):
                try modifyParagraph(line: line, from: from, to: to, attachments: attachments)
            }
        }
    }

    /// Attachments are kept as opaque placeholders: an edit may move them but must not drop
    /// them or invent new ones. Tables are the exception, since they are rebuilt from Markdown.
    func checkAttachments(old: [Block], new: [Block]) throws(NotesError) {
        func ids(_ blocks: [Block]) -> [String: String] {
            var out: [String: String] = [:]
            for case .paragraph(let p) in blocks {
                for case .attachment(let ref) in p.content { out[ref.id] = ref.kind }
            }
            return out
        }
        let before = ids(old), after = ids(new)
        if let missing = before.first(where: { after[$0.key] == nil && $0.value != "table" }) {
            throw .refused("the edit would remove an attachment (\(missing.value), id \(missing.key)); keep its ![…](attachment:\(missing.key)) placeholder")
        }
        if let unknown = after.first(where: { before[$0.key] == nil }) {
            throw .refused("attachment:\(unknown.key) does not exist in this note; new attachments cannot be created from Markdown")
        }
    }

    // MARK: Edit script

    enum Op {
        case delete(line: Int, Block)
        case insert(line: Int, [Block])
        case modify(line: Int, from: Paragraph, to: Paragraph)
    }

    /// Block-level diff (common prefix/suffix, then LCS on the middle). Unmatched runs pair
    /// up as in-place paragraph edits; the rest become deletes and inserts. Ops are ordered
    /// from the end of the note to the start.
    static func editScript(old: [Block], new: [Block]) -> [Op] {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
            old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
        { suffix += 1 }
        let a = Array(old[prefix..<(old.count - suffix)])
        let b = Array(new[prefix..<(new.count - suffix)])
        // LCS table over the middle part only; a huge rewrite skips it and pairs line by line.
        let useLCS = a.count * b.count <= 4_000_000
        var lcs = Array(repeating: Array(repeating: 0, count: useLCS ? b.count + 1 : 1), count: useLCS ? a.count + 1 : 1)
        if useLCS { for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        } }
        if !useLCS { return pairOps(prefix: prefix, a: a, b: b) }
        // Walk forward collecting hunks of unmatched (old, new) ranges.
        var hunks: [(Range<Int>, Range<Int>)] = []
        var i = 0, j = 0, hunkStart = (0, 0)
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                if hunkStart != (i, j) { hunks.append((hunkStart.0..<i, hunkStart.1..<j)) }
                i += 1
                j += 1
                hunkStart = (i, j)
            } else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                j += 1
            } else {
                i += 1
            }
        }
        if hunkStart != (a.count, b.count) { hunks.append((hunkStart.0..<a.count, hunkStart.1..<b.count)) }

        return hunks.reversed().flatMap { hunkOps(prefix: prefix, a: a, b: b, oldRange: $0.0, newRange: $0.1) }
    }

    static func pairOps(prefix: Int, a: [Block], b: [Block]) -> [Op] {
        hunkOps(prefix: prefix, a: a, b: b, oldRange: 0..<a.count, newRange: 0..<b.count)
    }

    static func hunkOps(prefix: Int, a: [Block], b: [Block], oldRange: Range<Int>, newRange: Range<Int>) -> [Op] {
        do {
            let paired = min(oldRange.count, newRange.count)
            var hunkOps: [Op] = []
            // Extra new blocks go in after the paired lines.
            if newRange.count > paired {
                let blocks = Array(b[(newRange.lowerBound + paired)...].prefix(newRange.count - paired))
                hunkOps.append(.insert(line: prefix + oldRange.upperBound, blocks))
            }
            for k in stride(from: oldRange.count - 1, through: paired, by: -1) {
                hunkOps.append(.delete(line: prefix + oldRange.lowerBound + k, a[oldRange.lowerBound + k]))
            }
            for k in stride(from: paired - 1, through: 0, by: -1) {
                let line = prefix + oldRange.lowerBound + k
                switch (a[oldRange.lowerBound + k], b[newRange.lowerBound + k]) {
                case (.paragraph(let from), .paragraph(let to)):
                    hunkOps.append(.modify(line: line, from: from, to: to))
                case (let from, let to):
                    hunkOps.append(.insert(line: line + 1, [to]))
                    hunkOps.append(.delete(line: line, from))
                }
            }
            return hunkOps
        }
    }

    // MARK: Line primitives

    /// Range of each line's text (newline excluded) in the current string.
    func lineRanges() throws(NotesError) -> [NSRange] {
        let string = try current.string as NSString
        var ranges: [NSRange] = []
        var start = 0
        while true {
            let newline = string.range(of: "\n", range: NSRange(location: start, length: string.length - start))
            if newline.location == NSNotFound {
                ranges.append(NSRange(location: start, length: string.length - start))
                return ranges
            }
            ranges.append(NSRange(location: start, length: newline.location - start))
            start = newline.location + 1
        }
    }

    func deleteLine(_ line: Int) throws(NotesError) {
        let lines = try lineRanges()
        let range: NSRange
        if lines.count == 1 {
            range = lines[0]
        } else if line < lines.count - 1 {
            range = NSRange(location: lines[line].location, length: lines[line + 1].location - lines[line].location)
        } else {
            let previousEnd = NSMaxRange(lines[line - 1])
            range = NSRange(location: previousEnd, length: NSMaxRange(lines[line]) - previousEnd)
        }
        try deleteCharacters(range)
    }

    func insertLines(_ blocks: [Block], at line: Int) throws(NotesError) {
        let lines = try lineRanges()
        let built = NSMutableAttributedString()
        if line < lines.count {
            // "a\nb\n" before the existing line; each newline carries its own line's style.
            for block in blocks {
                let (piece, style) = try attributedLine(block)
                built.append(piece)
                built.append(NSAttributedString(string: "\n", attributes: [Self.styleKey: style]))
            }
            try insert(built, at: lines[line].location)
        } else {
            // Appending after the last line: the joining newline belongs to that last line.
            let last = lines[lines.count - 1]
            var joinStyle: NSObject? = try styleOfLine(last)
            for block in blocks {
                let style: NSObject
                if let joinStyle { style = joinStyle } else { style = try Self.paragraphStyle(kind: .body, indent: 0, quote: 0, basedOn: nil) }
                built.append(NSAttributedString(string: "\n", attributes: [Self.styleKey: style]))
                let (piece, pieceStyle) = try attributedLine(block)
                built.append(piece)
                joinStyle = pieceStyle
            }
            try insert(built, at: NSMaxRange(last))
        }
    }

    /// The paragraph style a line carries: on its text, or on its newline when it is empty.
    func styleOfLine(_ range: NSRange) throws(NotesError) -> NSObject? {
        let string = try current
        if range.length > 0 { return string.attribute(Self.styleKey, at: range.location, effectiveRange: nil) as? NSObject }
        if NSMaxRange(range) < string.length { return string.attribute(Self.styleKey, at: NSMaxRange(range), effectiveRange: nil) as? NSObject }
        return nil
    }

    /// Edits one paragraph in place: a character diff for the text, then paragraph style,
    /// then the managed inline attributes over the paragraph.
    func modifyParagraph(line: Int, from: Paragraph, to: Paragraph, attachments: [String: [NSAttributedString.Key: Any]]) throws(NotesError) {
        let before = try lineRanges()[line]
        let existingStyle = try styleOfLine(before)
        let textChanged = Self.tokens(from) != Self.tokens(to)
        if textChanged {
            try editText(start: before.location, from: Self.tokens(from), to: Self.tokens(to), attachments: attachments)
        }
        let range = try lineRanges()[line]
        let hasNewline = try NSMaxRange(range) < current.length
        let styleRange = NSRange(location: range.location, length: range.length + (hasNewline ? 1 : 0))
        let styleChanged = from.kind != to.kind || from.indent != to.indent || from.quote != to.quote
        if styleRange.length > 0, styleChanged || textChanged || existingStyle == nil {
            let style: NSObject
            if !styleChanged, let existingStyle {
                style = existingStyle
            } else {
                style = try Self.paragraphStyle(kind: to.kind, indent: to.indent, quote: to.quote, basedOn: existingStyle)
            }
            try update(styleRange) { $0[Self.styleKey] = style }
        }
        if to.kind != .code, range.length > 0 { try applyMarks(to, at: range.location) }
    }

    // MARK: Text diff

    enum Token: Equatable {
        case unit(UInt16)
        case attachment(String)
    }

    static func tokens(_ paragraph: Paragraph) -> [Token] {
        var out: [Token] = []
        for item in paragraph.content {
            switch item {
            case .text(let run): out += run.text.utf16.map(Token.unit)
            case .attachment(let ref): out.append(.attachment(ref.id))
            }
        }
        return out
    }

    func editText(start: Int, from: [Token], to: [Token], attachments: [String: [NSAttributedString.Key: Any]]) throws(NotesError) {
        // Common prefix/suffix, then a character LCS on what is left. Paragraphs are short.
        var p = 0
        while p < from.count, p < to.count, from[p] == to[p] { p += 1 }
        var s = 0
        while s < from.count - p, s < to.count - p, from[from.count - 1 - s] == to[to.count - 1 - s] { s += 1 }
        let a = Array(from[p..<(from.count - s)]), b = Array(to[p..<(to.count - s)])
        var keep: [(Int, Int)] = []
        if !a.isEmpty, !b.isEmpty, a.count * b.count <= 4_000_000 {
            var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
            var i = 0, j = 0
            while i < a.count, j < b.count {
                if a[i] == b[j] { keep.append((i, j)); i += 1; j += 1 }
                else if lcs[i + 1][j] >= lcs[i][j + 1] { i += 1 }
                else { j += 1 }
            }
        }
        // Gaps between kept characters are replaced; apply them from the end.
        var gaps: [(old: Range<Int>, new: Range<Int>)] = []
        var lastOld = 0, lastNew = 0
        for (i, j) in keep + [(a.count, b.count)] {
            if i > lastOld || j > lastNew { gaps.append((lastOld..<i, lastNew..<j)) }
            lastOld = i + 1
            lastNew = j + 1
        }
        for gap in gaps.reversed() {
            let location = start + p + gap.old.lowerBound
            let inserted = Array(b[gap.new])
            // New characters take the attributes of their neighbour in the same paragraph,
            // so they match its font; managed attributes are set afterwards.
            let base = try neighbourAttributes(at: location, paragraphStart: start, removing: gap.old.count)
            if !gap.old.isEmpty { try deleteCharacters(NSRange(location: location, length: gap.old.count)) }
            if !inserted.isEmpty {
                let piece = NSMutableAttributedString()
                var units: [UInt16] = []
                func flushUnits() {
                    if !units.isEmpty { piece.append(NSAttributedString(string: String(utf16CodeUnits: units, count: units.count), attributes: base)) }
                    units = []
                }
                for token in inserted {
                    switch token {
                    case .unit(let u): units.append(u)
                    case .attachment(let id):
                        flushUnits()
                        piece.append(NSAttributedString(string: "\u{FFFC}", attributes: attachments[id] ?? base))
                    }
                }
                flushUnits()
                try insert(piece, at: location)
            }
        }
    }

    func neighbourAttributes(at location: Int, paragraphStart: Int, removing: Int) throws(NotesError) -> [NSAttributedString.Key: Any] {
        let string = try current
        guard string.length > 0 else { return [:] }
        let index: Int
        if location > paragraphStart { index = location - 1 }
        else if location + removing < string.length { index = location + removing }
        else if location < string.length { index = location }
        else { index = string.length - 1 }
        var attributes = Self.strip(string.attributes(at: index, effectiveRange: nil))
        attributes[Self.hintsKey] = nil
        attributes[Self.strikeKey] = nil
        attributes[Self.underlineKey] = nil
        attributes[Self.emphasisKey] = nil
        attributes[Self.linkKey] = nil
        return attributes
    }

    // MARK: Attributes

    /// Sets bold/italic/strike/underline/highlight/link over a paragraph to match `paragraph`,
    /// leaving every other attribute as it is.
    func applyMarks(_ paragraph: Paragraph, at start: Int) throws(NotesError) {
        var offset = start
        for item in paragraph.content {
            switch item {
            case .attachment:
                offset += 1
            case .text(let run):
                let length = (run.text as NSString).length
                try update(NSRange(location: offset, length: length)) { attributes in
                    Self.setMarks(run.marks, link: run.link, on: &attributes)
                }
                offset += length
            }
        }
    }

    static func setMarks(_ marks: Marks, link: String?, on attributes: inout [NSAttributedString.Key: Any]) {
        var hints = (attributes[hintsKey] as? Int) ?? 0
        hints = (hints & ~3) | (marks.contains(.bold) ? 1 : 0) | (marks.contains(.italic) ? 2 : 0)
        attributes[hintsKey] = hints == 0 ? nil : hints
        attributes[strikeKey] = marks.contains(.strike) ? 1 : nil
        attributes[underlineKey] = marks.contains(.underline) ? 1 : nil
        if marks.contains(.highlight) {
            if ((attributes[emphasisKey] as? Int) ?? 0) == 0 { attributes[emphasisKey] = defaultEmphasis }
        } else {
            attributes[emphasisKey] = nil
        }
        let currentLink = (attributes[linkKey] as? URL)?.absoluteString ?? attributes[linkKey] as? String
        if currentLink != link { attributes[linkKey] = link.flatMap { URL(string: $0) } ?? link }
    }

    /// Rewrites attributes over `range` one attribute run at a time, so keys the closure
    /// does not touch keep their per-run values.
    func update(_ range: NSRange, _ change: (inout [NSAttributedString.Key: Any]) -> Void) throws(NotesError) {
        let string = try current
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        string.enumerateAttributes(in: range) { attributes, run, _ in
            var updated = attributes
            change(&updated)
            if !NSDictionary(dictionary: updated).isEqual(to: attributes) { runs.append((run, updated)) }
        }
        for (run, attributes) in runs {
            if !dryRun {
                try call(mergeable, "setAttributes:range:") {
                    try NSShim.send(mergeable, selector: "setAttributes:range:", attributes: attributes, range: run)
                }
                try edited(.attributes, run, change: 0)
            }
            working.setAttributes(attributes, range: run)
        }
    }

    /// Attributes for a brand-new line: a fresh paragraph style plus the managed marks, and
    /// nothing hidden, so it looks like text typed into Notes. Returns the style too, for the
    /// newline that ends the line.
    func attributedLine(_ block: Block) throws(NotesError) -> (NSAttributedString, NSObject) {
        switch block {
        case .table(let table):
            let attachment = try createTable(table)
            let style = try Self.paragraphStyle(kind: .body, indent: 0, quote: 0, basedOn: nil)
            return (NSAttributedString(string: "\u{FFFC}", attributes: [Self.styleKey: style, Reader.attachmentKey: attachment]), style)
        case .paragraph(let p):
            let style = try Self.paragraphStyle(kind: p.kind, indent: p.indent, quote: p.quote, basedOn: nil)
            let line = NSMutableAttributedString()
            for item in p.content {
                switch item {
                case .text(let run):
                    var attributes: [NSAttributedString.Key: Any] = [Self.styleKey: style]
                    if p.kind != .code { Self.setMarks(run.marks, link: run.link, on: &attributes) }
                    line.append(NSAttributedString(string: run.text, attributes: attributes))
                case .attachment(let ref):
                    throw .refused("attachment:\(ref.id) cannot be placed in a new paragraph; keep it in its original paragraph")
                }
            }
            return (line, style)
        }
    }

    static func strip(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var out = attributes
        out[Reader.attachmentKey] = nil
        out[timestampKey] = nil
        return out
    }

    static func attachmentAttributes(in string: NSAttributedString) -> [String: [NSAttributedString.Key: Any]] {
        var out: [String: [NSAttributedString.Key: Any]] = [:]
        string.enumerateAttribute(Reader.attachmentKey, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let attachment = value as? NSObject, let id = attachment.value(forKey: "attachmentIdentifier") as? String else { return }
            var attributes = string.attributes(at: range.location, effectiveRange: nil)
            attributes[timestampKey] = nil
            out[id] = attributes
        }
        return out
    }

    static func styleCode(_ kind: ParagraphKind) -> UInt {
        switch kind {
        case .title: 0
        case .heading: 1
        case .subheading: 2
        case .body: 3
        case .code: 4
        case .bullet: 100
        case .dash: 101
        case .numbered: 102
        case .checklist: 103
        }
    }

    /// A paragraph style for `kind`, copied from `existing` when given so alignment and
    /// writing direction carry over.
    static func paragraphStyle(kind: ParagraphKind, indent: Int, quote: Int, basedOn existing: NSObject?) throws(NotesError) -> NSObject {
        let style: NSObject
        if let existing, let copy = existing.mutableCopy() as? NSObject {
            style = copy
        } else {
            guard let cls = NSClassFromString("ICTTParagraphStyle") as? NSObject.Type else {
                throw .frameworkChanged("missing class ICTTParagraphStyle")
            }
            style = cls.init()
        }
        try call(style, "setStyle:") { try NSShim.send(style, selector: "setStyle:", unsignedInteger: styleCode(kind)) }
        try call(style, "setIndent:") { try NSShim.send(style, selector: "setIndent:", unsignedInteger: UInt(indent)) }
        try call(style, "setBlockQuoteLevel:") { try NSShim.send(style, selector: "setBlockQuoteLevel:", unsignedInteger: UInt(quote)) }
        if case .checklist(let done) = kind {
            var todo: AnyObject?
            if let existingTodo = style.value(forKey: "todo") as? NSObject {
                try call(existingTodo, "todoWithDone:") {
                    try NSShim.send(existingTodo, selector: "todoWithDone:", boolean: done, result: &todo)
                }
            } else {
                try call(style, "initWithIdentifier:done:") {
                    try NSShim.allocClass("ICTTTodo", initSelector: "initWithIdentifier:done:", object: NSUUID(), boolean: done, result: &todo)
                }
            }
            style.setValue(todo, forKey: "todo")
        } else {
            style.setValue(nil, forKey: "todo")
        }
        return style
    }

    // MARK: Low-level edits

    /// NSTextStorage edit mask: attributes = 1, characters = 2.
    struct EditMask: OptionSet {
        let rawValue: UInt
        static let attributes = EditMask(rawValue: 1)
        static let characters = EditMask([EditMask(rawValue: 1), EditMask(rawValue: 2)])
    }

    /// Tells the note which range changed, with NSTextStorage semantics (range in the new
    /// string, length delta), so its cached text and the saved data stay in step.
    func edited(_ mask: EditMask, _ range: NSRange, change: Int) throws(NotesError) {
        try call(note, "edited:range:changeInLength:") {
            try NSShim.send(note, selector: "edited:range:changeInLength:", unsignedInteger: mask.rawValue, range: range, integer: change)
        }
    }

    func deleteCharacters(_ range: NSRange) throws(NotesError) {
        guard range.length > 0 else { return }
        if !dryRun {
            try call(mergeable, "deleteCharactersInRange:") {
                try NSShim.send(mergeable, selector: "deleteCharactersInRange:", range: range)
            }
            try edited(.characters, NSRange(location: range.location, length: 0), change: -range.length)
        }
        working.deleteCharacters(in: range)
    }


    func insert(_ string: NSAttributedString, at index: Int) throws(NotesError) {
        guard string.length > 0 else { return }
        if !dryRun {
            try call(mergeable, "insertAttributedString:atIndex:") {
                try NSShim.send(mergeable, selector: "insertAttributedString:atIndex:", object: string, index: UInt(index))
            }
            try edited(.characters, NSRange(location: index, length: string.length), change: string.length)
        }
        working.insert(string, at: index)
    }

    // MARK: Tables

    func createTable(_ table: Table) throws(NotesError) -> NSObject {
        guard let markerClass = NSClassFromString("ICTTAttachment") as? NSObject.Type else {
            throw .frameworkChanged("missing class ICTTAttachment")
        }
        if dryRun {
            let id = "pending-" + UUID().uuidString
            pendingTables[id] = table.rows
            let marker = markerClass.init()
            marker.setValue(id, forKey: "attachmentIdentifier")
            marker.setValue("com.apple.notes.table", forKey: "attachmentUTI")
            return marker
        }
        guard let prepared = preparedTables.popLast() else {
            throw .failed("internal error: no prepared table attachment")
        }
        return prepared
    }

    private func makeTable(_ table: Table) throws(NotesError) -> NSObject {
        guard let markerClass = NSClassFromString("ICTTAttachment") as? NSObject.Type else {
            throw .frameworkChanged("missing class ICTTAttachment")
        }
        Loader.prepareTableCreation()
        let text = table.rows.map { row in
            row.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t")
        }.joined(separator: "\n")
        var created: AnyObject?
        try call(note, "addTableAttachmentWithText:") {
            try NSShim.send(note, selector: "addTableAttachmentWithText:", object: NSAttributedString(string: text), result: &created)
        }
        guard let attachment = created as? NSObject, let id = attachment.value(forKey: "identifier") as? String else {
            throw .frameworkChanged("addTableAttachmentWithText: returned no attachment")
        }
        let marker = markerClass.init()
        marker.setValue(id, forKey: "attachmentIdentifier")
        marker.setValue("com.apple.notes.table", forKey: "attachmentUTI")
        return marker
    }

    /// A table rebuilt from Markdown replaces the old one; the old attachment is marked for
    /// deletion the way Notes does when a table is removed.
    /// 当找到持久化 ICTable 单元格修改的方法时，改为原地修改单元格，保留单元格内的格式。
    func markAttachmentDeleted(_ id: String) throws(NotesError) {
        guard !id.isEmpty else { return }
        let request = NSFetchRequest<NSManagedObject>(entityName: "ICAttachment")
        request.predicate = NSPredicate(format: "identifier == %@", id)
        request.fetchLimit = 1
        guard let attachment = try? context.fetch(request).first else { return }
        try call(attachment, "markForDeletion") { try NSShim.send(attachment, selector: "markForDeletion") }
    }
}
