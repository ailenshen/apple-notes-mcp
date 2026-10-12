import Foundation
import MCPCore
import NotesKit

/// Typed access to tool arguments. Shape problems (missing, wrong type, unknown value) are
/// JSON-RPC invalid-params errors; everything about the notes themselves is a tool result.
struct Arguments {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) { self.values = values }

    func string(_ key: String) throws -> String {
        guard let value = values[key]?.stringValue else { throw MCPError.invalidParams("\(key) must be a string") }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        switch values[key] {
        case nil, .null?: return nil
        case .string(let s)?: return s.isEmpty ? nil : s
        default: throw MCPError.invalidParams("\(key) must be a string")
        }
    }

    func bool(_ key: String, default fallback: Bool) throws -> Bool {
        switch values[key] {
        case nil, .null?: return fallback
        case .bool(let b)?: return b
        default: throw MCPError.invalidParams("\(key) must be true or false")
        }
    }

    func int(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        let value: Int
        switch values[key] {
        case nil, .null?: return fallback
        case .int(let i)?: value = i
        case .double(let d)? where d == d.rounded(): value = Int(d)
        default: throw MCPError.invalidParams("\(key) must be an integer")
        }
        guard range.contains(value) else { throw MCPError.invalidParams("\(key) must be between \(range.lowerBound) and \(range.upperBound)") }
        return value
    }

    /// A date as YYYY-MM-DD (start of that day, local time) or an ISO 8601 date-time.
    func optionalDate(_ key: String) throws -> Date? {
        guard let text = try optionalString(key) else { return nil }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = .current
        day.locale = Locale(identifier: "en_US_POSIX")
        if let date = day.date(from: text) { return date }
        let full = ISO8601DateFormatter()
        if let date = full.date(from: text) { return date }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: text) { return date }
        throw MCPError.invalidParams("\(key) must be a date like 2026-10-01 or 2026-10-01T09:00:00+08:00")
    }

    /// `<field>_after` / `<field>_before`, for field "modified" or "created".
    func dateWindow(_ field: String = "modified") throws -> DateWindow {
        let window = DateWindow(from: try optionalDate("\(field)_after"), until: try optionalDate("\(field)_before"))
        if let from = window.from, let until = window.until, from >= until {
            throw MCPError.invalidParams("\(field)_after must be earlier than \(field)_before")
        }
        return window
    }

    func order() throws -> NoteOrder? {
        guard let value = try optionalString("sort") else { return nil }
        guard let order = NoteOrder(rawValue: value) else {
            throw MCPError.invalidParams("sort must be one of \(NoteOrder.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return order
    }

    func choice(_ key: String, _ allowed: [String], default fallback: String) throws -> String {
        guard let value = try optionalString(key) else { return fallback }
        guard allowed.contains(value) else { throw MCPError.invalidParams("\(key) must be one of \(allowed.joined(separator: ", "))") }
        return value
    }
}

/// Builds a JSON Schema object for tool inputs.
func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
    ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }),
     "additionalProperties": false]
}

func stringProperty(_ description: String) -> JSONValue { ["type": "string", "description": .string(description)] }
