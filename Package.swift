// swift-tools-version:6.2
// Apple Notes MCP 2.0. Zero external dependencies on purpose: MCPCore is a
// minimal, self-written MCP 2026-07-28 server.
// 当官方 Swift SDK 稳定支持 2026-07-28 时，评估把 MCPCore 迁移到官方实现；
// 只需保留 Tool 协议与分发接口，上层工具代码不变。
import PackageDescription

let package = Package(
    name: "AppleNotesMCP",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "MCPCore"),
        .executableTarget(name: "AppleNotesMCP", dependencies: ["MCPCore"]),
    ]
)
