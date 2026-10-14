import Foundation
import Synchronization

// Minimal MCP 2026-07-28 server: stateless, per-request `_meta`, no initialize handshake.
// Only server/discover, tools/list and tools/call are served; every other method is -32601.
//
// Legacy fallback (PR #10, owner's decision 2026-10-14): a client that opens with `initialize`
// gets that handshake (2024-11-05 to 2025-11-25), and afterwards its requests without `_meta`
// are served in the agreed version. It exists for Claude.app: in 2.37337.1, the latest release
// then, Cowork and Code sessions start servers from claude_desktop_config.json in a shared pool
// that never probes server/discover for them ("Era probe verdict: legacy (exec lane pinned — no
// sibling probe)") and always send initialize, whatever the app version. Only installed .mcpb
// extensions get the probe. Each legacy handshake is logged to stderr with the client's name.
// 当最新版 Claude.app 的 Cowork/Code 会话对 claude_desktop_config.json 里的服务器也先发 server/discover，
// 且 stderr 里的 "legacy initialize" 日志不再出现常用客户端时，删除兼容：initialize()、legacyVersion、
// dispatch 中的 legacy 分支、ContentBlock.json(forLegacy:)，以及 scripts/wire-smoke.sh 的 legacy 段。
// 检查方法：按 https://downloads.claude.ai/releases/darwin/universal/RELEASES.json 下载最新版，解开
// Contents/Resources/app.asar，看 "exec lane pinned" 是否还在，以及不在已安装扩展里的服务器是否仍判为 legacy。
// Source of truth: schema/2026-07-28/schema.ts and docs/specification/2026-07-28 in
// github.com/modelcontextprotocol/modelcontextprotocol (tag 2026-07-28).
// 当需要 progress、取消、resources 等能力时，在这里按规范逐项加入，不要预先实现。

public let protocolVersion = "2026-07-28"

/// Pre-2026 versions accepted through `initialize`, newest first.
public let legacyProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

/// A tool result. Business failures go here with `isError: true` so the model can self-correct.
public struct ToolResult: Sendable {
    public var text: String
    public var isError: Bool
    /// Content after the text: images, audio or files the client passes on to the model.
    public var extra: [ContentBlock]
    public init(_ text: String, isError: Bool = false, extra: [ContentBlock] = []) {
        self.text = text
        self.isError = isError
        self.extra = extra
    }
}

/// The non-text content blocks of MCP 2026-07-28 (`ImageContent`, `AudioContent`,
/// `EmbeddedResource` with a blob).
public enum ContentBlock: Sendable {
    case image(Data, mimeType: String)
    case audio(Data, mimeType: String)
    /// A file embedded in the result, e.g. a PDF.
    case resource(uri: String, mimeType: String, Data)

    /// The block for a client of an older protocol: audio content arrived in 2025-03-26, so a
    /// 2024-11-05 client gets a line of text instead of a block it may reject with the whole result.
    func json(forLegacy version: String) -> JSONValue {
        if case .audio(_, let mime) = self, version < "2025-03-26" {
            return ["type": "text", "text": .string("(An audio file, \(mime), is left out: this client's MCP version, \(version), cannot receive audio.)")]
        }
        return json
    }

    var json: JSONValue {
        switch self {
        case .image(let data, let mime): ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mime)]
        case .audio(let data, let mime): ["type": "audio", "data": .string(data.base64EncodedString()), "mimeType": .string(mime)]
        case .resource(let uri, let mime, let data):
            ["type": "resource", "resource": ["uri": .string(uri), "mimeType": .string(mime), "blob": .string(data.base64EncodedString())]]
        }
    }
}

/// A JSON-RPC level failure, for problems with the request itself rather than the tool's work.
public struct MCPError: Error, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public static func invalidParams(_ message: String) -> MCPError { .init(code: -32602, message: message) }
}

public protocol Tool: Sendable {
    var name: String { get }
    /// Display name for clients.
    var title: String? { get }
    var description: String { get }
    var inputSchema: JSONValue { get }
    /// Behaviour hints (readOnlyHint, destructiveHint, idempotentHint, openWorldHint).
    var annotations: ToolAnnotations { get }
    /// Throw `MCPError.invalidParams` for arguments that do not fit the schema; any other
    /// thrown error is reported to the model as an `isError` result.
    func call(_ arguments: [String: JSONValue]) async throws -> ToolResult
}

public struct ToolAnnotations: Sendable {
    public var readOnly: Bool
    public var destructive: Bool
    public var idempotent: Bool

    public init(readOnly: Bool = false, destructive: Bool = false, idempotent: Bool = false) {
        self.readOnly = readOnly
        self.destructive = destructive
        self.idempotent = idempotent
    }

    public static let readOnly = ToolAnnotations(readOnly: true, idempotent: true)

    var json: JSONValue {
        var hints: [String: JSONValue] = ["readOnlyHint": .bool(readOnly), "openWorldHint": false]
        if !readOnly {
            hints["destructiveHint"] = .bool(destructive)
            hints["idempotentHint"] = .bool(idempotent)
        }
        return .object(hints)
    }
}

extension Tool {
    public var title: String? { nil }
    public var annotations: ToolAnnotations { ToolAnnotations() }
}

public struct ServerInfo: Sendable {
    public var name: String
    public var version: String
    public var instructions: String?
    public init(name: String, version: String, instructions: String? = nil) {
        self.name = name
        self.version = version
        self.instructions = instructions
    }
}

public final class Server: Sendable {
    let info: ServerInfo
    let tools: [any Tool]
    /// Freshness hint for discover and tools/list. The tool set only changes with a new build,
    /// and a new build means a new stdio process.
    let ttlMs = 3_600_000
    /// The version agreed through `initialize`, set once a legacy client connects. A stdio
    /// process serves exactly one client, so this is per-connection state.
    let legacyVersion = Mutex<String?>(nil)

    public init(info: ServerInfo, tools: [any Tool]) {
        self.info = info
        self.tools = tools
    }

    /// Handles one framed message and returns the reply line, or nil for notifications.
    public func handle(_ line: String) async -> String? {
        guard let data = line.data(using: .utf8),
            let message = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return encode(error: MCPError(code: -32700, message: "Parse error"), id: nil)
        }
        guard case .object(let object) = message,
            object["jsonrpc"] == "2.0",
            let method = object["method"]?.stringValue
        else {
            return encode(error: MCPError(code: -32600, message: "Invalid Request"), id: nil)
        }
        guard let id = object["id"] else { return nil }  // Notifications get no reply.
        switch id {
        case .string, .int: break
        default: return encode(error: MCPError(code: -32600, message: "Request id must be a string or integer"), id: nil)
        }
        do {
            let result = try await dispatch(method: method, params: object["params"]?.objectValue ?? [:])
            return encode(result: result, id: id)
        } catch let error as MCPError {
            return encode(error: error, id: id)
        } catch {
            return encode(error: MCPError(code: -32603, message: "Internal error: \(error)"), id: id)
        }
    }

    private func dispatch(method: String, params: [String: JSONValue]) async throws -> [String: JSONValue] {
        if method == "initialize" { return initialize(params) }
        // A legacy session sends no per-request `_meta` version; a request that does carry one
        // is answered under 2026-07-28 rules as usual.
        let session = params["_meta"]?["io.modelcontextprotocol/protocolVersion"] == nil ? legacyVersion.withLock { $0 } : nil
        let legacy = session != nil
        if legacy && method == "ping" { return [:] }
        guard ["server/discover", "tools/list", "tools/call"].contains(method), !(legacy && method == "server/discover")
        else {
            throw MCPError(code: -32601, message: "Method not found: \(method)")
        }
        if !legacy { try validateMeta(params["_meta"]) }
        let complete = legacy ? { $0 } : self.complete
        switch method {
        case "server/discover":
            var result: [String: JSONValue] = [
                "supportedVersions": [.string(protocolVersion)],
                "capabilities": ["tools": [:]],
                "ttlMs": .int(ttlMs),
                "cacheScope": "public",
            ]
            if let instructions = info.instructions { result["instructions"] = .string(instructions) }
            return complete(result)
        case "tools/list":
            if params["cursor"] != nil { throw MCPError.invalidParams("Invalid cursor") }
            let list: [JSONValue] = tools.map { tool in
                var entry: [String: JSONValue] = [
                    "name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.inputSchema,
                    "annotations": tool.annotations.json,
                ]
                if let title = tool.title { entry["title"] = .string(title) }
                return .object(entry)
            }
            // ttlMs and cacheScope are 2026-07-28 fields; a legacy client gets the plain list.
            return legacy ? ["tools": .array(list)] : complete(["tools": .array(list), "ttlMs": .int(ttlMs), "cacheScope": "public"])
        default:
            guard let name = params["name"]?.stringValue else { throw MCPError.invalidParams("Missing tool name") }
            guard let tool = tools.first(where: { $0.name == name }) else {
                throw MCPError.invalidParams("Unknown tool: \(name)")
            }
            let arguments: [String: JSONValue]
            switch params["arguments"] {
            case nil, .null?: arguments = [:]
            case .object(let o)?: arguments = o
            default: throw MCPError.invalidParams("Tool arguments must be an object")
            }
            let outcome: ToolResult
            do {
                outcome = try await tool.call(arguments)
            } catch let error as MCPError {
                throw error
            } catch {
                outcome = ToolResult("\(error)", isError: true)
            }
            return complete([
                "content": .array([["type": "text", "text": .string(outcome.text)]] + outcome.extra.map { block in
                    session.map(block.json(forLegacy:)) ?? block.json
                }),
                "isError": .bool(outcome.isError),
            ])
        }
    }

    /// Legacy handshake: echo the client's version when it is one we know, else offer the newest.
    private func initialize(_ params: [String: JSONValue]) -> [String: JSONValue] {
        let requested = params["protocolVersion"]?.stringValue ?? ""
        let version = legacyProtocolVersions.contains(requested) ? requested : legacyProtocolVersions[0]
        legacyVersion.withLock { $0 = version }
        // Evidence for removing the fallback one day: which clients still need it.
        let client = params["clientInfo"].map { "\($0["name"]?.stringValue ?? "?") \($0["version"]?.stringValue ?? "?")" } ?? "unnamed client"
        FileHandle.standardError.write(Data("legacy initialize: \(client) asked for \(requested.isEmpty ? "no version" : requested), got \(version)\n".utf8))
        var result: [String: JSONValue] = [
            "protocolVersion": .string(version),
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": .string(info.name), "version": .string(info.version)],
        ]
        if let instructions = info.instructions { result["instructions"] = .string(instructions) }
        return result
    }

    /// Every request must carry its protocol version and client capabilities (SEP-2575).
    /// A request without a version usually comes from a client still holding a session it opened
    /// with an older server at the same address (seen with claude.ai after upgrading from 1.x), so
    /// the message says how to recover. 当主流客户端都能在收到该错误后自动重新 discover 时，去掉这段提示。
    private func validateMeta(_ meta: JSONValue?) throws {
        let reconnect = "Requests need MCP \(protocolVersion) _meta, or an initialize handshake first. If the client connected to an older version of this server, reconnect it or restart the client."
        guard case .object(let meta)? = meta else { throw MCPError.invalidParams("Missing _meta. \(reconnect)") }
        guard let version = meta["io.modelcontextprotocol/protocolVersion"]?.stringValue else {
            throw MCPError.invalidParams("Missing _meta.io.modelcontextprotocol/protocolVersion. \(reconnect)")
        }
        guard meta["io.modelcontextprotocol/clientCapabilities"]?.objectValue != nil else {
            throw MCPError.invalidParams("Missing _meta.io.modelcontextprotocol/clientCapabilities")
        }
        guard version == protocolVersion else {
            throw MCPError(
                code: -32022, message: "Unsupported protocol version",
                data: ["supported": [.string(protocolVersion)], "requested": .string(version)])
        }
    }

    private func complete(_ fields: [String: JSONValue]) -> [String: JSONValue] {
        var result = fields
        result["resultType"] = "complete"
        result["_meta"] = [
            "io.modelcontextprotocol/serverInfo": ["name": .string(info.name), "version": .string(info.version)]
        ]
        return result
    }

    private func encode(result: [String: JSONValue], id: JSONValue) -> String {
        line(["jsonrpc": "2.0", "id": id, "result": .object(result)])
    }

    private func encode(error: MCPError, id: JSONValue?) -> String {
        var body: [String: JSONValue] = ["code": .int(error.code), "message": .string(error.message)]
        if let data = error.data { body["data"] = data }
        var envelope: [String: JSONValue] = ["jsonrpc": "2.0", "error": .object(body)]
        if let id { envelope["id"] = id }
        return line(envelope)
    }

    private func line(_ object: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding a JSONValue cannot fail; compact output never contains a raw newline.
        let data = (try? encoder.encode(JSONValue.object(object))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
