# Apple Notes MCP Server

Let Claude read, search, create, update, and delete your Apple Notes — right from Claude Desktop.

I built this because I want Apple Notes to be my personal data hub, and I need it to work seamlessly with AI. This MCP server is the bridge.

**Requirements:** macOS 26 (Tahoe) or later.

## Why This One?

There are other Apple Notes MCP implementations (including Claude's built-in one). Here's what makes this one different:

**Native formatting support.** When you create a note, it goes through macOS's native Markdown import — so titles become real Titles, headings become real Headings, bold/italic/lists all render as native Apple Notes formatting, not plain text pasted into a note body.

The trade-off: Notes.app will briefly appear during note creation (~3 seconds), because we use `open -a Notes` to trigger the native import pipeline. It's the only way to get true native formatting without reverse-engineering Apple's private internal format.

**Fast reads via SQLite.** Listing and searching notes queries the NoteStore database directly — under 100ms, no AppleScript overhead.

## What Can It Do?

- **List notes** — browse all your notes or filter by folder
- **Search notes** — find notes by keyword
- **Read a note** — get the full content of any note (returned as Markdown)
- **Create a note** — write a new note from Markdown (with native formatting)
- **Update a note** — replace a note's content while preserving its folder
- **Delete a note** — move a note to Recently Deleted

## Setup

### 1. Install Node.js

You need [Node.js](https://nodejs.org/) 18+ installed. If you don't have it, download the LTS version from the link.

### 2. Configure Claude Desktop

Open the Claude Desktop config file:

```bash
open -e ~/Library/Application\ Support/Claude/claude_desktop_config.json
```

If the file doesn't exist, create it. Add the following:

```json
{
  "mcpServers": {
    "apple-notes": {
      "command": "npx",
      "args": ["-y", "@ailenshen/apple-notes-mcp@latest"]
    }
  }
}
```

That's it — no need to clone any code. `npx` will automatically download and run the server.

Save the file, then **restart Claude Desktop**.

### 3. Grant Permissions

You need to grant two permissions to **`node`** (not to Terminal or Claude Desktop):

1. **Full Disk Access** — System Settings → Privacy & Security → Full Disk Access → add and enable `node`
   - **Required for reading notes.** The server reads the Notes database (NoteStore.sqlite) directly, which macOS protects behind Full Disk Access.
   - Without this permission, list/search/read will fail.
2. **Accessibility** — System Settings → Privacy & Security → Accessibility → add and enable `node`
   - Required for creating notes. The server uses System Events to auto-click the Import confirmation dialog.
   - Without this permission, create will fail.

To find your `node` path, run `which node` in Terminal — typically `/usr/local/bin/node` or `/opt/homebrew/bin/node`.

## Usage Examples

Once configured, just talk to Claude naturally:

- "List all my notes in the Projects folder"
- "Search my notes for 'meeting agenda'"
- "Read my note titled 'Shopping List'"
- "Create a note in my Work folder with today's action items"
- "Update my 'Shopping List' note with these new items"
- "Delete the note called 'Old Draft'"

## How It Works

| Action | Method | Speed |
|--------|--------|-------|
| List / Search | SQLite (read-only) | < 100ms |
| Read | AppleScript → Markdown | ~1s |
| Create | Native Markdown import | ~3-4s |
| Update | Delete + Create | ~4-5s |
| Delete | AppleScript | ~1s |

- **Reading** is done through a read-only SQLite connection to the Notes database — fast and safe. Note content is converted from HTML to Markdown via [turndown](https://github.com/mixmark-io/turndown).
- **Creating** uses macOS's native Markdown import (`open -a Notes`), so formatting is preserved natively.
- **Updating** deletes the old note and creates a new one, automatically preserving the original folder.
- **Deleting** moves notes to Recently Deleted, just like doing it manually.

## Markdown Support

When creating notes, most Markdown works natively:

| Element | Support |
|---------|---------|
| Headings, **bold**, *italic*, lists, `inline code` | Fully supported |
| Block quotes | Content preserved, no indent style |
| Links | Text preserved, URL lost |
| Tables, footnotes | Not supported |

## Roadmap

- [x] **Publish to npm** — `npx @ailenshen/apple-notes-mcp` just works, zero setup beyond the config file.
- [ ] **Remote connection (Streamable HTTP + OAuth 2.1)** — Currently, this server runs locally via stdio. The next goal is to add an HTTP transport with OAuth so that Claude on iPhone/iPad can connect to your Mac's Apple Notes remotely. Your Mac becomes the bridge between mobile Claude and your notes.
- [x] **Update note** — delete + recreate with folder preservation.

## Vision

Apple Notes is the most natural place to keep personal knowledge on Apple devices — it syncs everywhere, it's fast, and it's private. But it's a walled garden with no API.

This project makes Apple Notes a first-class data source for AI. The long-term goal: wherever you're talking to Claude — on your Mac, on your phone, on the web — your Apple Notes are always accessible, readable, and writable.

## License

MIT
