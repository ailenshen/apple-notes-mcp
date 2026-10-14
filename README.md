# Apple Notes MCP Server

English | [简体中文](README.zh-CN.md)

Let Claude read and edit your Apple Notes — with **native formatting**, tables, attachments, and iCloud sync.

[![apple-notes-mcp MCP server](https://glama.ai/mcp/servers/ailenshen/apple-notes-mcp/badges/score.svg)](https://glama.ai/mcp/servers/ailenshen/apple-notes-mcp)

Claude edits your notes the way you would: change one line or tick a checkbox, and the rest of the note stays exactly as it was — colors, fonts and all. Titles, headings, lists, checklists, tables and highlights are real Apple Notes styles. Claude can also look at the images, scans and PDFs in your notes, and keep your folders tidy.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/screenshot-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="assets/screenshot-light.png">
  <img alt="Apple Notes MCP" src="assets/screenshot-light.png">
</picture>

**Requires:** macOS 26 (Tahoe) or later, [Node.js](https://nodejs.org/) 24+, and an MCP client. Clients that speak MCP 2026-07-28 (Claude Code 2.1.296 or later, an up-to-date Claude Desktop, claude.ai) use it directly; older clients, including Cowork and Code sessions in Claude.app, fall back to the `initialize` handshake (2024-11-05 through 2025-11-25)

## Setup

### 1. Add to Claude

**Claude Code** — run in Terminal:

```bash
claude mcp add apple-notes -- npx -y @ailenshen/apple-notes-mcp@latest
```

**Claude Desktop** — add to `~/Library/Application Support/Claude/claude_desktop_config.json`, then restart Claude:

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

**claude.ai** (web and mobile) — see [Remote Access](#remote-access).

`@latest` makes it update itself: each time Claude starts the server, npx checks for a new version and fetches it.

### 2. Grant permissions

A setup window opens the first time it's needed (or run `npx -y @ailenshen/apple-notes-mcp@latest setup`). Turn on two switches for **Apple Notes MCP**:

| Permission | Why |
|-----------|-----|
| **Full Disk Access** | Read your notes |
| **Automation → Notes** | Sync changes to iCloud, move and delete notes |

You only do this once — permissions stay through updates.

### 3. Start using it

Just talk to Claude:

- "What did I change in my notes this week?"
- "In my shopping list, tick off milk and add eggs"
- "Add a 'Next steps' section to the meeting note"
- "What's in the photo in my receipts note?"
- "Move the Hainan trip notes into Travel"
- "Write a one-line description for every note in Work"
- "Archive the Old Projects folder to ~/Documents/Archive/old-projects.zip, then delete it"

## What Can It Do?

| Tool | Description |
|------|-------------|
| `overview` | Folders, or notes with their size and a one-line description; filter by date, sort by date or title |
| `search` | Full-text search, with the matching text |
| `read_note` | Read a note as Markdown — by id or title, several at once, or just one section |
| `read_attachment` | Look at an image, scan, PDF, video, table or file in a note |
| `create_note` | New note from Markdown |
| `edit_note` | Change text, add under a heading, or rewrite a note — several changes in one go |
| `describe_note` | Save one-line descriptions, many at once |
| `move_note` | Move a note to another folder, or restore it from Recently Deleted |
| `manage_folder` | Create, rename or delete a folder; export a folder to disk (Markdown + original attachments, optionally as a .zip), or delete it with everything in it |
| `delete_note` | Move to Recently Deleted |

Claude never overwrites your own edits: if a note changed after Claude read it, the write is refused. Every note is backed up before a change.

### Markdown in Notes

| In Notes | In Markdown |
|---------|-------------|
| Title / Heading / Subheading | `#` / `##` / `###` |
| Bulleted, dashed, numbered list | `*` / `-` / `1.` |
| Checklist | `- [ ]` / `- [x]` |
| Block quote, monospaced | `>`, ```` ``` ```` |
| Bold, italic, strikethrough | `**…**`, `*…*`, `~~…~~` |
| Underline, highlight | `<u>…</u>`, `<mark>…</mark>` |
| Link, table | `[text](url)`, `\| a \| b \|` |

## Remote Access

The server talks over stdio. To use it from claude.ai, put it behind a bridge that forwards HTTP requests to stdio, then add the URL as a custom connector.

## Upgrading from 1.x

Version 2 is a rewrite in Swift, and `@latest` installs it automatically. What changes:

- It needs macOS 26 (Tahoe). On an older Mac, use version 1: `npx -y @ailenshen/apple-notes-mcp@1`.
- Permissions now belong to the **Apple Notes MCP** app. The setup window opens once; turn on the two switches.
- Restart Claude, or reconnect the connector, once.
- The `--http` mode is gone; see [Remote Access](#remote-access). To keep it, stay on `@1`.

## How It Works

- **Reading** goes through Notes' own data framework, read-only.
- **Writing** changes only what differs, through Notes' own editing objects, so the rest of the note — including formatting Markdown can't show — is untouched.
- **Syncing**: after each change, Notes is asked to upload it to iCloud.
- Notes never comes to the front, and no dialogs pop up.

## Known Limitations

- Attachments can be read, not added or removed.
- Folders can't be moved yet.
- Locked notes can't be read; an export lists them as not exported. Shared notes can be edited, but not deleted.
- A table you just edited in Notes is rebuilt when Claude changes it, which resets formatting inside its cells.

## Vision

Apple Notes is the most natural place to keep personal knowledge on Apple devices — it syncs everywhere, it's fast, and it's private. But it's a walled garden with no API.

This project makes Apple Notes a first-class data source for AI. The long-term goal: wherever you're talking to AI — on your Mac, on your phone, on the web — your Apple Notes are always accessible, readable, and writable.

## License

MIT
