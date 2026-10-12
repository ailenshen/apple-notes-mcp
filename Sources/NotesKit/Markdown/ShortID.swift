import Foundation

/// Ids as the model sees them: the first 8 characters of a UUID. A full UUID costs the model
/// about 20 tokens, and lists repeat it on every line; 8 hex characters identify one of a few
/// thousand notes with a negligible chance of a clash, and tools refuse a prefix that does
/// clash (naming the full ids) instead of guessing.
/// 当客户端普遍按需加载结果、或模型分词对 UUID 变得便宜时，可以回到完整 id。
public enum ShortID {
    public static let length = 8

    public static func of(_ id: String) -> String {
        isUUID(id) ? String(id.prefix(length)) : id
    }

    static func isUUID(_ id: String) -> Bool { id.count == 36 && UUID(uuidString: id) != nil }
}

extension Array where Element == Block {
    /// The same blocks with every attachment id passed through `transform`.
    public func mappingAttachmentIDs(_ transform: (String) -> String) -> [Block] {
        map { block in
            guard case .paragraph(var p) = block else { return block }
            p.content = p.content.map { inline in
                guard case .attachment(var ref) = inline else { return inline }
                ref.id = transform(ref.id)
                return .attachment(ref)
            }
            return .paragraph(p)
        }
    }

    /// Attachment ids in this order, including those shown shortened.
    public var attachmentIDsForChecks: [String] { attachmentIDs }

    var attachmentIDs: [String] {
        flatMap { block -> [String] in
            guard case .paragraph(let p) = block else { return [] }
            return p.content.compactMap { if case .attachment(let ref) = $0 { ref.id } else { nil } }
        }
    }

    /// Expands shortened attachment ids (as written by the model) to the full ids of the
    /// attachments in `current`. Ids that match none, or several, are left as they are, so the
    /// writer's attachment check reports them.
    public func expandingAttachmentIDs(from current: [Block]) -> [Block] {
        let known = Set(current.attachmentIDs)
        return mappingAttachmentIDs { id in
            if known.contains(id) { return id }
            let matches = known.filter { $0.lowercased().hasPrefix(id.lowercased()) }
            return matches.count == 1 ? matches.first! : id
        }
    }
}
