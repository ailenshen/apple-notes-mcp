import Foundation

/// Runs AppleScript in-process. NSAppleScript is not thread-safe, hence the main actor.
/// Needs Automation → Notes permission for the responsible process.
@MainActor
enum AppleScript {
    /// An AppleScript string literal for `text`.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    @discardableResult
    static func run(_ source: String) throws(NotesError) -> String? {
        try execute(source).stringValue
    }

    /// A script whose result is a list, such as `id of notes of folder id …`, item by item.
    /// A list result has no `stringValue` (it is nil, checked 2026-10-14), so `run` cannot read it.
    static func runList(_ source: String) throws(NotesError) -> [String] {
        let result = try execute(source)
        guard result.descriptorType == typeAEList else { return result.stringValue.map { [$0] } ?? [] }
        guard result.numberOfItems > 0 else { return [] }
        return (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
    }

    private static func execute(_ source: String) throws(NotesError) -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw .failed("invalid AppleScript") }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let info {
            let number = info[NSAppleScript.errorNumber] as? Int ?? 0
            let message = info[NSAppleScript.errorMessage] as? String ?? "unknown error"
            if number == -1743 {
                throw .noAccess("Automation permission for Notes was denied (\(message))")
            }
            throw .failed("AppleScript error \(number): \(message)")
        }
        return result
    }
}
