import Foundation

/// Newline-delimited JSON-RPC over stdin/stdout. Each request runs concurrently; one actor
/// serializes everything written to stdout. Returns when stdin closes and in-flight work is done.
public enum StdioTransport {
    public static func run(_ server: Server) async {
        let output = Output(wireLog: ProcessInfo.processInfo.environment["MCP_WIRE_LOG"])
        await withTaskGroup(of: Void.self) { group in
            do {
                for try await line in FileHandle.standardInput.bytes.lines where !line.isEmpty {
                    await output.log("<- " + line)
                    group.addTask {
                        if let reply = await server.handle(line) { await output.send(reply) }
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("stdin read failed: \(error)\n".utf8))
            }
        }
    }
}

private actor Output {
    let wireLog: FileHandle?

    init(wireLog path: String?) {
        guard let path else {
            wireLog = nil
            return
        }
        FileManager.default.createFile(atPath: path, contents: nil)
        wireLog = FileHandle(forWritingAtPath: path)
    }

    func send(_ line: String) {
        log("-> " + line)
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    /// Optional transcript of every message, used as evidence while the protocol layer is young.
    func log(_ entry: String) {
        wireLog?.write(Data((entry + "\n").utf8))
    }
}
