import Foundation
import MCPCore
import NotesKit

let version = "2.0.0-dev"

let instructions = """
    Apple Notes on this Mac. Start with overview to see folders, then overview with a folder or \
    search to find notes, then read_note. read_note returns Markdown and a version; pass the version \
    back when writing so a note edited in the meantime is not overwritten (update_note requires it).
    Prefer edit_note for small changes and append_to_note for additions; update_note rewrites the \
    whole note. One note paragraph is one Markdown line, and a blank line is an empty paragraph.
    Formatting: # title (the first line), ## heading, ### subheading, * bullet, - dash, 1. numbered, \
    - [ ] / - [x] checklist, > quote, ``` code, **bold**, *italic*, ~~strike~~, <u>underline</u>, \
    <mark>highlight</mark>, [text](url), tables as | a | b |. Underscores are plain text.
    Keep ![…](attachment:…) placeholders as they are: attachments cannot be added or removed here.
    When read_note says a note has no description, call describe_note with a one-line summary; \
    overview shows these (~ marks an automatic one).
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
        UpdateNoteTool(notes: notes), DeleteNoteTool(notes: notes),
    ])
await StdioTransport.run(server)
