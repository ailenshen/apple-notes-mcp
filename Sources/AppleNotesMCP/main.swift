import Foundation
import MCPCore
import NotesKit

let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0-dev"

enum Mode { case server, onboarding, selfCheck }

/// `--onboarding` / `setup` open the permission window, `--self-check` prints a diagnosis.
/// Without flags: an MCP client talks over a pipe or socket; anything else (double-click in
/// Finder, a terminal) gets the permission window.
let mode: Mode = {
    let args = CommandLine.arguments.dropFirst()
    if args.contains("--onboarding") || args.contains("setup") { return .onboarding }
    if args.contains("--self-check") { return .selfCheck }
    if args.contains("--stdio") { return .server }
    var info = stat()
    fstat(0, &info)
    let kind = info.st_mode & S_IFMT
    return kind == S_IFIFO || kind == S_IFSOCK ? .server : .onboarding
}()

Responsibility.relaunchIfNeeded()

switch mode {
case .onboarding:
    Onboarding.run()
    exit(0)
case .selfCheck:
    print("Apple Notes MCP \(version) (\(Bundle.main.bundleIdentifier ?? "development build"))")
    print("Full Disk Access:", Permissions.fullDiskAccess())
    print("Automation → Notes:", Permissions.automation(ask: false))
    do {
        let folders = try NotesRepository().folders()
        print("Notes data: OK, \(folders.reduce(0) { $0 + $1.noteCount }) notes in \(folders.count) folders")
    } catch {
        print("Notes data:", error)
    }
    exit(0)
case .server:
    break
}

let instructions = """
    Apple Notes on this Mac. Find notes with overview or search, then read_note. Pass read_note's \
    version back when writing. Make all changes to a note in one edit_note call.
    One note paragraph is one Markdown line. Formatting: # title, ## heading, ### subheading, \
    * - 1. lists, - [ ] / - [x] checklist, > quote, ``` code, **bold**, *italic*, ~~strike~~, \
    <u>underline</u>, <mark>highlight</mark>, [link](url), | tables |. Keep ![…](attachment:…) placeholders.
    To describe many notes: overview with undescribed: true, then one describe_note call.
    """

// While set (development and checks), writes only touch notes whose title starts with it.
let writeGuard = ProcessInfo.processInfo.environment["APPLE_NOTES_MCP_WRITE_GUARD"]
let repository = NotesRepository(writeGuardTitlePrefix: writeGuard)
let notes = NotesContext(
    repository: repository, sync: SyncCoordinator(repository: repository), search: FullTextSearch(), index: DescriptionIndex())

let server = Server(
    info: ServerInfo(name: "apple-notes-mcp", version: version, instructions: instructions),
    tools: [
        OverviewTool(notes: notes), SearchTool(notes: notes), ReadNoteTool(notes: notes), DescribeNoteTool(notes: notes),
        CreateNoteTool(notes: notes), EditNoteTool(notes: notes), DeleteNoteTool(notes: notes), MoveNoteTool(notes: notes),
        ManageFolderTool(notes: notes), ReadAttachmentTool(notes: notes),
    ])
await StdioTransport.run(server)
