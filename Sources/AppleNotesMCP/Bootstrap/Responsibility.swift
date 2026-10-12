import Darwin
import Foundation

// macOS charges a child process's privacy permissions (Full Disk Access, Automation) to the
// process responsible for it: Claude Code, a terminal, or frpc under launchd. Re-launching
// ourselves with responsibility disclaimed makes this app its own responsible process, so the
// permissions are granted to "Apple Notes MCP" once and survive changes to whatever starts it.
// The child inherits stdin/stdout, so the MCP connection is unaffected. LaunchServices `open`
// would also give the app its own identity but does not pass the pipes, so it is only used for
// the onboarding window.
// 当 macOS 提供公开的"让子进程自行承担权限"接口时，改用公开接口替换私有的 responsibility SPI。

enum Responsibility {
    static let marker = "APPLE_NOTES_MCP_DISCLAIMED"

    /// Re-executes the current binary with responsibility disclaimed and mirrors its exit.
    /// Returns only when re-launching is not needed or not possible; then the caller runs
    /// in this process.
    static func relaunchIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        // Only the app bundle has a stable identity worth holding permissions; a bare
        // development binary keeps the parent's permissions.
        guard environment[marker] == nil, Bundle.main.bundleIdentifier == "com.ailenshen.apple-notes-mcp" else { return }
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            log("responsibility SPI unavailable; permissions stay with the parent process")
            return
        }
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        let disclaim = unsafeBitCast(symbol, to: Disclaim.self)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        guard disclaim(&attributes, 1) == 0 else {
            log("could not disclaim responsibility; permissions stay with the parent process")
            return
        }
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        var env = environment.map { "\($0.key)=\($0.value)" } + ["\(marker)=1"]
        var argv = CommandLine.arguments
        argv[0] = path
        var pid: pid_t = 0
        let status = withCStrings(argv) { cArgs in
            withCStrings(env) { cEnv in posix_spawn(&pid, path, nil, &attributes, cArgs, cEnv) }
        }
        env.removeAll()
        guard status == 0 else {
            log("re-launch failed (\(status)); permissions stay with the parent process")
            return
        }
        let forwarding = forwardSignals(to: pid)
        var result: Int32 = 0
        withExtendedLifetime(forwarding) {
            while waitpid(pid, &result, 0) == -1 && errno == EINTR {}
        }
        // Mirror the child's exit status or terminating signal.
        if result & 0x7f == 0 { exit((result >> 8) & 0xff) }
        signal(result & 0x7f, SIG_DFL)
        kill(getpid(), result & 0x7f)
        exit(1)
    }

    /// Passes termination signals on to the child; keep the result alive while waiting.
    private static func forwardSignals(to child: pid_t) -> [DispatchSourceSignal] {
        [SIGTERM, SIGINT, SIGHUP].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { kill(child, sig) }
            source.resume()
            return source
        }
    }

    private static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { body(UnsafePointer($0.baseAddress!)) }
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("apple-notes-mcp: \(message)\n".utf8))
    }
}
