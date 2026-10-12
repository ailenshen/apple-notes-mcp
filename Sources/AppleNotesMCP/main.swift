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
    Apple Notes on this Mac. Start with overview to see folders, then overview with a folder or \
    search to find notes, then read_note (by id, or by exact title when the user names a note). read_note returns Markdown and a version; pass the version \
    back when writing so a note edited in the meantime is not overwritten (update_note requires it).
    Prefer edit_note for small changes and append_to_note for additions; update_note rewrites the \
    whole note. One note paragraph is one Markdown line, and a blank line is an empty paragraph.
    Formatting: # title (the first line), ## heading, ### subheading, * bullet, - dash, 1. numbered, \
    - [ ] / - [x] checklist, > quote, ``` code, **bold**, *italic*, ~~strike~~, <u>underline</u>, \
    <mark>highlight</mark>, [text](url), tables as | a | b |. Underscores are plain text.
    Keep ![…](attachment:…) placeholders as they are: attachments cannot be added or removed here.
    When read_note says a note has no description, call describe_note with a one-line summary; \
    overview shows these (~ marks an automatic one). When asked to describe many notes, use overview \
    with undescribed: true and pass all the summaries to describe_note in one call.
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
        CreateNoteTool(notes: notes), AppendToNoteTool(notes: notes), EditNoteTool(notes: notes),
        UpdateNoteTool(notes: notes), DeleteNoteTool(notes: notes), MoveNoteTool(notes: notes), ManageFolderTool(notes: notes),
    ])
await StdioTransport.run(server)
