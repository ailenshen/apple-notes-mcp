import MCPCore

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
