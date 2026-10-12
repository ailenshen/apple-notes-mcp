# Apple Notes MCP Server

Let AI assistants read and edit your Apple Notes — with real Apple Notes formatting, edits made in place, tables, and iCloud sync.

[![apple-notes-mcp MCP server](https://glama.ai/mcp/servers/ailenshen/apple-notes-mcp/badges/score.svg)](https://glama.ai/mcp/servers/ailenshen/apple-notes-mcp)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/screenshot-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="assets/screenshot-light.png">
  <img alt="Apple Notes MCP" src="assets/screenshot-light.png">
</picture>

Version 2 is a native macOS app written in Swift. It works with Notes' own data layer instead of importing files or pasting HTML, so:

- **Edits happen in place.** Change one line, tick a checkbox, or rename a heading — the rest of the note is untouched, including colors and fonts Markdown cannot show. The note keeps its id, its folder, and its history.
- **Formatting is native.** Titles, headings, all four list types, checklists, quotes, code blocks, bold, italic, strikethrough, underline, highlight, links and tables become real Apple Notes styles.
- **Nothing pops up.** Notes is never brought to the front, and no dialogs are clicked for you.
- **Changes reach your other devices.** After each write the server makes sure iCloud has the change, and tells the assistant if it does not yet.
- **Permissions are granted once**, to the app "Apple Notes MCP", and survive updates.

**Requires:** macOS 26 (Tahoe) or later, and an MCP client that speaks MCP protocol version 2026-07-28. Verified with Claude Code 2.1.296. Node.js is only needed for `npx`.

> **Claude Desktop is not supported yet.** Claude Desktop 1.8555.2 still uses the older protocol (2025-11-25), and 2.0 speaks only the current one. Keep using version 1.x (`@latest`) there until Claude Desktop updates.

## Setup

### 1. Add it to your MCP client

**Claude Code:**

```bash
claude mcp add apple-notes -- npx -y @ailenshen/apple-notes-mcp@next
```

**Other clients** (JSON config):

```json
{
  "mcpServers": {
    "apple-notes": {
      "command": "npx",
      "args": ["-y", "@ailenshen/apple-notes-mcp@next"]
    }
  }
}
```

`@next` is the 2.0 beta. `@latest` is still version 1.x until 2.0 is final.

### 2. Grant two permissions

The first time a tool needs them, a setup window opens. You can also open it yourself:

```bash
npx -y @ailenshen/apple-notes-mcp@next setup
```

| Permission | Why |
|-----------|-----|
| **Full Disk Access** | To read your notes from Notes' database |
| **Automation → Notes** | To have Notes upload edits to iCloud, and to move deleted notes to Recently Deleted |

Both are granted to **Apple Notes MCP**, not to Terminal, Claude or Node — so they keep working whichever program starts the server, and after updates. If a switch is on but the setup window still shows it red, remove Apple Notes MCP from that list with "−" and add it again.

### 3. Talk to your assistant

- "What's in my Projects folder?"
- "Find my notes about the trip to Hainan"
- "In my shopping list, tick off milk and add eggs"
- "Add a 'Next steps' section to the meeting note"
- "Turn this table into a new note in Work"

## Tools

| Tool | What it does |
|------|-------------|
| `overview` | All folders with note counts; or one line per note (in a folder, or across folders by date) with its size and a short description; or the notes still missing a description, with the start of their text. Filters by modification date and sorts by date or title |
| `search` | Full-text search over titles and bodies, with the matching text and each note's size; filters by modification date and sorts by relevance, date or title |
| `read_note` | The note as Markdown, plus a version to pass back when writing; by id, or by exact title |
| `describe_note` | Saves one-line descriptions, for one note or many at once, shown by `overview` |
| `create_note` | A new note from Markdown |
| `append_to_note` | Adds Markdown at the end, at the start, or at the end of a heading's section |
| `edit_note` | Replaces one piece of text, like editing a file |
| `update_note` | Rewrites the whole note; unchanged lines keep their formatting |
| `delete_note` | Moves a note to Recently Deleted |
| `move_note` | Moves a note to another folder, keeping its id; also restores a note from Recently Deleted |
| `manage_folder` | Creates, renames or deletes a folder (only empty folders are deleted; folders cannot be moved yet) |

Writes are refused if the note changed after the assistant read it, so your own edits in Notes are never overwritten. Each note is backed up before a write (the last 20 copies, in `~/Library/Application Support/AppleNotesMCP/backups`).

### How notes look as Markdown

One note paragraph is one Markdown line, so reading a note and writing it back never shifts its structure.

| In Notes | In Markdown |
|---------|-------------|
| Title / Heading / Subheading | `# ` / `## ` / `### ` |
| Bulleted / dashed / numbered list | `* ` / `- ` / `1. ` (two spaces per indent level) |
| Checklist | `- [ ] ` / `- [x] ` |
| Block quote / monospaced | `> ` / ```` ``` ```` |
| Bold, italic, strikethrough | `**…**`, `*…*`, `~~…~~` |
| Underline, highlight | `<u>…</u>`, `<mark>…</mark>` |
| Link | `[text](url)` |
| Table | `\| a \| b \|` (cells are plain text; an edit usually changes only the cells that differ, keeping formatting made in Notes, but a table you also edited in Notes recently is rebuilt so iCloud gets the change) |
| Image, file, note link, hashtag | `![image](attachment:…)` — kept as is; cannot be added or removed |

Locked notes are skipped, and notes in Recently Deleted are read-only. Shared notes can be edited, unless they were shared with you read-only; edits merge with the other people's edits the way they do in Notes. Shared notes are not deleted from here, since that can remove them for everyone.

## How it works

- **Reading** opens Notes' database read-only through Notes' own framework (NotesShared) and turns each paragraph's style into Markdown. Search reads the plain text straight from the database and caches it.
- **Writing** compares the note with the wanted result and changes only what differs, character by character, through Notes' own editing objects. The whole edit is rehearsed on a copy and checked first; the note is only touched if the copy comes out right.
- **Syncing**: Notes does not upload edits made this way by itself, so after each write the server asks Notes to move the note into its own folder, which makes Notes save and upload it.

NotesShared is a private Apple framework. The server checks at startup that everything it relies on is still there, and reports a clear error instead of misbehaving if a macOS update changes it. If Apple ever offers an official Notes API, the server will move to it.

## Remote access

Version 2 talks only over stdio. To use it from another device, put it behind a bridge that forwards each HTTP request to stdio as-is. Version 2 keeps no session, so the bridge does not need one. This has been checked with a claude.ai custom connector through such a bridge. The built-in HTTP mode of version 1 was removed.

**Upgrading from 1.x:** a client that connected while 1.x was running keeps using the older protocol, and its calls fail until it reconnects. Restart the client, or reconnect the connector, once after upgrading.

## Development

```bash
swift build                              # debug build
swift run NotesKitChecks unit            # Markdown mapping checks
swift run NotesKitChecks roundtrip       # read-only: every note → Markdown → back
swift run NotesKitChecks writetest       # writes to a throwaway "MCP Test …" note
scripts/wire-smoke.sh                    # MCP protocol checks over stdio
python3 scripts/e2e.py                   # every tool, on a throwaway "MCP Test …" note
scripts/build-app.sh                     # universal, signed AppleNotesMCP.app in dist/
scripts/release.sh 2.0.0-beta.2          # bump, commit and tag; pushing the tag publishes
```

Set `APPLE_NOTES_MCP_WRITE_GUARD="MCP Test "` while developing: writes are then limited to notes whose title starts with that text.

## License

MIT
