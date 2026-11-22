# Apple Notes MCP maintenance reference

## Open source and releases

- **GitHub**: https://github.com/ailenshen/apple-notes-mcp
- **npm**: `@ailenshen/apple-notes-mcp`: stable versions go to `latest`, pre-releases to `next`. Users install `npx -y …@latest`, which re-checks the registry on every server start, so a stable release reaches every user (1.x users included) on their next start.
- **License**: MIT

> **Contribution language**: All git commit messages, PR titles, PR descriptions, and GitHub issue content must be written in **English**.

> **Writing style**: Keep descriptions plain and easy to understand — explain what changed and why in everyday language, not technical jargon. Prefer short sentences over complex ones.

> **Issue actions require confirmation**: Any action on GitHub issues — replying, closing, reopening, labeling, etc. — must be explicitly confirmed by the user before execution.

### Release process

```bash
scripts/release.sh 2.0.0-beta.2   # updates npm/package.json, commits, tags v2.0.0-beta.2
git push && git push --tags       # .github/workflows/publish.yml takes over from here
```

- The package lives in `npm/`. A plain `npm version` there does not create a tag, which is why `release.sh` exists.
- The workflow, on macOS:
  1. Checks that the tag matches the version.
  2. Imports the signing certificate into a temporary keychain.
  3. Runs `scripts/build-app.sh` to build the universal app and sign it.
  4. Copies the app, README and LICENSE into `npm/`.
  5. Publishes (`next` when the version contains `-`).
- It never publishes an unsigned or ad-hoc build: that would make every user grant permissions again.
- npm Trusted Publishing (OIDC) is bound to `ailenshen/apple-notes-mcp` + **`publish.yml`**. Renaming the workflow file means updating the Trusted Publisher settings on npmjs.com.
- GitHub secrets: `SIGNING_CERTIFICATE_P12` (base64 of the p12) and `SIGNING_CERTIFICATE_PASSWORD`.

### Signing identity (top-level secret)

- A self-signed certificate, `Apple Notes MCP Signing`, valid for 10 years. The user generates and keeps the private key; Claude never touches it.
- The DR is `identifier "com.ailenshen.apple-notes-mcp" and certificate leaf = H"…"`. Builds with the same certificate share one identity, so permissions carry across upgrades.
- If the private key leaks, anyone can impersonate the app and inherit every user's Full Disk Access.
- The certificate cannot be replaced: a new one would make every user grant permissions again.
- Neither the bundle id nor the app name can be changed, for the same reason.
- When there is an Apple Developer account, move to Developer ID signing plus notarization, keeping the same bundle id. TCC entries keyed by csreq will have to be granted once more.

---

## Local development

```bash
swift build
swift run NotesKitChecks unit          # Markdown mapping (no Notes access needed)
swift run NotesKitChecks roundtrip     # read-only: every note → Markdown → back, must be 100% identical
swift run NotesKitChecks writetest     # write-side round trip on a throwaway "MCP Test …" note
swift run NotesKitChecks export <folder> <new dir>   # read-only: export a real folder, compare copied files with the originals
scripts/wire-smoke.sh                  # minimal MCP protocol checks
python3 scripts/e2e.py                 # every tool, on an MCP Test note
scripts/build-app.sh                   # dist/AppleNotesMCP.app (ad-hoc signed and warns when there is no certificate)
```

- Only Command Line Tools are installed here (no Xcode):
  - `swift test`, the SwiftUI macros (`@State`, `@Observable`) and `--arch` universal builds are unavailable.
  - So the checks are an executable (NotesKitChecks), the UI uses ObservableObject, and the universal binary is two triple builds plus lipo.
  - Once Xcode or a toolchain with the macro plugins is available, refactor to Swift Testing / `@Observable` / a single universal build.
- During development, set `APPLE_NOTES_MCP_WRITE_GUARD="MCP Test "` so writes only touch test notes. NotesKitChecks and e2e set it themselves.
- Test notes always have titles starting with `MCP Test `. When finished, move them to Recently Deleted. **Never** empty Recently Deleted.
- To test with a real client without changing the user's config, run `claude -p --mcp-config <temporary json> --strict-mcp-config …`. The `MCP_WIRE_LOG=<file>` environment variable records every message.

### Permissions

The app requests them as itself, `Apple Notes MCP`:

- **Full Disk Access**: reading NoteStore.sqlite.
- **Automation → Notes**: the sync nudge and deletes.

A plain `swift build` debug binary is not an app bundle, so it does not re-launch and runs with the permissions of whichever program started it.

---

## Architecture

```
MCP client ──stdio──> npm/bin/apple-notes-mcp ──exec──> AppleNotesMCP.app/Contents/MacOS/AppleNotesMCP
                                                 └─ re-launches itself with "parent not responsible" (Bootstrap/Responsibility)
  MCPCore           minimal hand-written 2026-07-28 server: discover / tools/list / tools/call, per-request _meta checks
  AppleNotesMCP     9 tools (MCP/*Tools.swift), setup window (Onboarding), entry mode selection (main.swift)
  NotesKit
    NotesRepository  @MainActor, the only public entry point; only Sendable snapshots come out
      ReadStore      read-only Core Data (NotesShared's model), stalenessInterval = 0
      WriteContext   Notes' own ICNoteContext, created on first write
      Reader         attributed string → [Block]
      Writer         [Block] → minimal in-place edits (mirror + dry run + read back)
    Markdown/        Block / Render / Parse (exact inverses of each other)
    Sync/            SyncCoordinator: AppleScript move nudge + poll cloudState
    Search/          FullTextSearch: plain text straight from ZICNOTEDATA, cached
    Index/           DescriptionIndex: ~/Library/Application Support/AppleNotesMCP/index.sqlite
  NotesSharedShim    ObjC: catches ObjC exceptions, typed objc_msgSend, ic_convert… replacement
```

### Directory layout

```
Package.swift            zero external dependencies
Sources/MCPCore/         protocol layer (does not depend on NotesKit)
Sources/AppleNotesMCP/   executable: Bootstrap/ MCP/ Onboarding/ main.swift
Sources/NotesKit/        Model/ NotesShared/ Markdown/ Search/ Index/ Sync/ System/
Sources/NotesSharedShim/ Objective-C adapter
Sources/NotesKitChecks/  runnable checks
Resources/               Info.plist, AppIcon.icns (generated by scripts/make-icon.swift)
scripts/                 build-app.sh, release.sh, wire-smoke.sh, e2e.py, make-icon.swift
npm/                     package.json + bin/apple-notes-mcp (the app is copied in when publishing)
```

Changes to the directory layout, data model or tool interface must be confirmed with the user first.

---

## Key decisions and findings

All verified on macOS 27.0.1.

### Protocol: hand-written MCP 2026-07-28, no official Swift SDK

- swift-sdk 0.12.1 only reaches 2025-11-25 and pulls in swift-nio.
- The server speaks 2026-07-28, plus a legacy `initialize` fallback (2024-11-05 to 2025-11-25; PR #10 by prausch, merged 2026-10-14 by the owner's decision). After the handshake, requests without `_meta` are served in that version: no `server/discover`, no `resultType`/`_meta`/`ttlMs`, and audio becomes a line of text for 2024-11-05. Each handshake logs `legacy initialize: <client> asked for …` to stderr.
  - Why: Claude.app's Cowork and Code sessions always send `initialize` for servers from claude_desktop_config.json, whatever the app version (next bullet).
  - Remove it when the latest Claude.app probes those servers with `server/discover` too, and the stderr log no longer shows common clients. Server.swift's header lists what to delete and how to check the app.
- Real client behavior: Claude Code probes with `server/discover` first, and every request carries `_meta.protocolVersion`.
- claude.ai connectors via frpc support it (verified 2026-10-12). The owner says current Claude Desktop supports it too (2026-10-14). The Desktop on this Mac is a stale 1.8555.2 from May 2026 (its updater last ran 2026-05-24), and it does not; it has not been verified on an up-to-date Desktop.
- Claude.app 2.37337.1 (latest, 2026-10-13; read from its app.asar): Cowork and Code sessions start local servers through a shared pool. A server from claude_desktop_config.json is not an installed extension, so its lane is `exec` and the verdict is legacy with no probe ("Era probe verdict: legacy (exec lane pinned — no sibling probe)"): the client connects with `prior: {kind: 'legacy'}` and sends `initialize`. Only installed .mcpb extensions of type node on the built-in Node get a `server/discover` probe (2 s probe, 4 s deadline), and feature flag 1942337209 forces legacy everywhere. So updating Claude.app does not fix the `initialize is not supported` error (PR #10); the ordinary chat path was not traced.
- When the official SDK is stable on 2026-07-28, consider migrating; the Tool protocol and dispatch interface can stay.
- The official conformance tool cannot test stdio yet (conformance#258). For now `scripts/wire-smoke.sh` covers the core wire contract; once it supports stdio, switch to the official tests.

### Concurrency: Swift 6 strict throughout, zero `@unchecked`/`nonisolated(unsafe)`

- NotesShared and Core Data live behind `@MainActor` and never leave it.
- Tools are Sendable and only `await` the repository.

### Reading: NotesShared read-only store

- `dlopen` NotesShared; direct linking is refused.
- Notes' own model is opened with `NSReadOnlyPersistentStoreOption`.
- On startup the Loader checks the classes, methods and model fields it needs; when something is missing it reports "NotesShared changed in this macOS version" instead of crashing.
- `TTHints` is a bit mask: 1 bold, 2 italic. Other keys: TTStrikethrough, TTUnderline, TTEmphasis (highlight, values 1/2/4/5 are colors; new highlights use 1), TTColor, ICTTFont, TTTimestamp.
- Table cells read 0×0 until `+[ICNoteContext startSharedContextWithOptions:]` has run once in the process. After that they can be read from the read-only context, which is why the read path starts it lazily on the first table.
- Inline attachments (note links, hashtags, calculation results) are entity ICInlineAttachment, with fields `altText` and `tokenContentIdentifier`.
- The read-only round trip over all 1193 notes has 0 differences.
- A folder is listed only if Notes would show it: `markedForDeletion == NO AND needsInitialFetchFromCloud == NO` (`+[ICFolder predicateForVisibleObjects]`, 2026-10-13). Folders still "needing initial fetch" are placeholders for records Notes never downloaded (no parent, no notes), and they showed up as stray top-level folders.

### Writing: Writer applies minimal edits in place

- Every write goes through `apply(target blocks)`:
  1. A block-level LCS.
  2. Changed paragraphs get a character-level LCS.
  3. Only the attributes Markdown manages are set; hidden attributes (color, font, alignment) on unchanged text are kept.
- During editing, `mergeableString.attributedString` is a **cached snapshot**. The writer therefore keeps its own mirror, rehearses the whole edit on it, checks the result against the target, and only then replays it on the real note.
- **Never load NotesEditor.framework**: once it is loaded, mid-note inserts save a truncated body (the text is short while the attribute runs cover the full length).
  - Table creation only needs `-[NSMutableAttributedString ic_convertParagraphStyleToBodyInRange:]`, which NotesSharedShim supplies itself. It must also *add* a body style where there is none, or the table cells overlap.
- When a write fails, roll back the context and refresh the note right away: Notes' autosave would otherwise persist half a write.
- In-place edits do not update `modificationDate`, so the writer sets it itself.
- The version token is a content hash of the Markdown. It is passed back explicitly, because the protocol is stateless and the store's modification time is unreliable.
- After writing, the body is read back and compared. The original is backed up first (`backups/<id>/`, latest 20).
  - A difference is a warning in a normal result, not `isError` (2026-10-14): the write happened, and a client that takes the result as failed may retry and create the note twice.
- Tables are edited in place (`TableEditor`, verified 2026-10-12): columns are aligned by header, rows by content, and only differing cells are changed, character by character, through each cell's mergeable string. Cell formatting made in Notes survives, and the attachment keeps its id.
  - Persisting needs `setMergeableDataDirty:YES` before `writeMergeableData`, then `updateChangeCountWithReason:` on the attachment. `+[ICTableAttachmentProvider saveAttachmentOnMainThread:]` writes nothing.
  - The sync check waits for the note's table attachments too. Usually an in-place table edit uploads together with the note (matrix 2026-10-12: never shown in Notes, or open in Notes the whole time).
  - **Exception**: once the table has been edited in Notes itself during the current Notes session (even just bolding a word), Notes keeps a stale in-memory copy of the table's sync state, and our in-place edits do not upload (still pending after 5 minutes; one did go up much later). Nothing safe from outside fixed it:
    - change counts, `postEditorExtensionDidSaveNotification` and the move nudge had no effect;
    - swapping the `ICCloudState` row corrupted the attachment's sync state. Never write `ICCloudState` rows or relationships.
  - So the write tools fall back (owner's choice, 2026-10-12): when the note has uploaded but a table this write edited in place is still pending 8 s later, `rebuildTables` replaces it with a new attachment of the same content. That one uploads; only then is cell formatting lost, and the result says so.
  - To reproduce by hand: create an MCP Test note with a table, show it in Notes, bold a cell in Notes, click away, then edit_note a cell. writetest cannot cover this, because it never shows its note in Notes.
  - After a failed write, `refresh` on the attachment reloads its table model, which drops in-memory cell edits.
  - Only tables that are added or removed are created or marked for deletion.

### Token budget (2026-10-12)

- claude.ai appears to load every connector's full tool definitions up front: anthropics/claude-ai-mcp#401 says "Load tools when needed" does not defer them. So definitions stay short and **stable**, and per-request "dynamic" descriptions are avoided, since a change breaks the client's prompt cache.
- Most tokens are in results:
  - A UUID costs about 20 tokens, so results show 8-character prefixes (`ShortID`).
  - Every tool accepts a prefix: `resolveNoteID`, `resolveAttachmentID`, and short folder ids in `resolveFolder`. A clashing prefix is refused with the full ids.
  - Attachment ids in Markdown are shortened by `read_note` / `edit_note`, and `update()` expands them back from the note's current attachments.
- The folder tree is indented names with counts. Ids appear only for duplicate paths (8.4k → 2.0k characters).
- Lists default to 30 notes and search to 10. `overview()` shows one folder level by default (`depth` for more); a folder's note list names its direct subfolders.
- `read_note` has `outline` (headings with section sizes) and `section` (one heading's part, subsections included).
- Folder names may contain "/": paths write it as `\/` (`FolderPath`), tree depth comes from the parent chain, and lookups also accept the unescaped form or the leaf name. Id prefixes resolve from 4 characters.
- `read_note` takes `ids`, so a Project that points at a folder reads it in one call.
- Writing is one `edit_note` (replace pairs, insert at end/start/heading, or rewrite), replacing append/edit/update. Benchmarked 2026-10-12: about 280 tokens less per turn, and three changes asked for in one sentence go in one call (input tokens −30%).
- `bench.py`, beta.4 vs this change, input tokens:
  - overview 21.5k → 16.6k;
  - reading a whole folder: 7 → 3 turns;
  - the write workflow 76.6k → 61.5k.

### Moving notes and folders (2026-10-12)

- These go through AppleScript in `Organizer.swift`:
  - `move note … to folder id` keeps the id and uploads;
  - `make new folder at account|folder`;
  - `set name of folder id`;
  - `delete folder id` (only on empty folders).
- **Never use `move folder`.** It reports success, but Notes deletes the folder (the store has `markedForDeletion=1`, and the UI no longer shows it). Moving folders is not offered. It would need NotesShared (the parent relationship plus subfolder-order mergeable data) and its own sync check.
- The store can lag Notes by minutes in the background, so results are verified in Notes' view:
  - `exists folder id`, `name of folder id`, and whether the trash contains the note;
  - but `folders of folder X` keeps listing deleted subfolders, so subfolders count only when `exists folder id` confirms them.
- A path just created and not yet in the store is resolved through Notes by path (`folder "B" of folder "A" of default account`).
- After a rename, the store kept the old name for over two minutes while Notes was in the background (2026-10-14), so the new name was "not found" and lists and exports showed the old one. Folders this process renamed carry their new name in `renamedFoldersHere`; `title(of:)` applies it everywhere a folder name or path is built, until the store catches up or 10 minutes pass.
- Moving into or out of a shared folder needs `allow_shared` (it changes who can see the note). Renaming a shared folder needs it too; shared folders are never deleted.
- An account is compared by identifier: `value(forKey: "account")` on two folders of the same account can return different objects.

### Archiving a folder: export, then recursive delete (2026-10-14)

- The owner archived two work folders (328 notes, 116 files, ~45 subfolders) on 2026-10-13. It took about 375 calls plus reading the store directly. Now it takes two calls, both modes of `manage_folder` (owner's choice). Measured: they add ~340 characters (~80 tokens) to the tool definitions on every claude.ai turn; a separate export tool would add ~450 more (estimated, not measured).
- `action: "export"`, `to`: a new directory, or a `.zip` path (zipped with `/usr/bin/ditto`, since claude.ai has no shell). Code: `NotesShared/Export.swift`.
  - ditto writes UTF-8 names without the zip's UTF-8 flag, so Windows, Python and unzip showed Chinese names as garbage, and `/usr/bin/zip` is built without Unicode support. `markNamesAsUTF8` sets the flag on every entry afterwards (zip64 included; checked on a Python-made zip64, since ditto writes zip64 only past 4 GB).
  - Layout: one `.md` per note in the same folder layout; `attachments/<full id>/<original file>` at the root; `manifest.md` lists every note (dates with time zone, attachments, status).
  - Attachment placeholders become relative, percent-encoded links (`../attachments/<id>/IMG%201.jpeg`), so the archive reads offline. Scans are `page-NN` files; link cards become `[url](url)`; hashtags, note links and calculations become their text.
  - Locked notes are listed as not exported. A missing file (not downloaded) keeps its placeholder and is listed under Problems.
  - The destination must not exist and must not be inside `~/Library`: the app has Full Disk Access, and a manipulated model must not plant files in places such as LaunchAgents.
  - Each `.md` gets the note's created and modified dates as file dates.
  - Exporting 18 notes with 20 images took 0.2 s; every copied file matched its original byte for byte (`NotesKitChecks export`).
- `action: "delete"`, `recursive: true`, `expected_notes: N` (`deleteFolderTree` in `Organizer.swift`).
  - Everything is checked before the first change: shared or locked notes, shared or smart folders, the write guard, the count, and Notes' view (AppleScript) agreeing with the store for every folder.
  - Notes are deleted with `delete note id` lines, 50 per script. Recently Deleted is read once before and polled after. Folders then go through `deleteFolder`, deepest first.
  - `delete folder` is never sent to a non-empty folder: what it does then is unverified, and `move folder` already showed that Notes' folder commands can report success while doing something else.
- AppleScript list results (`id of notes of folder …`) have no `stringValue`; use `AppleScript.runList`. Before 2026-10-14, `deleteFolder` read such a list with `run`, so it never saw subfolders that only Notes knew about.
- After a delete, the store kept listing deleted folders for over a minute. Folders this process deleted are hidden (`deletedFoldersHere`), as notes are (`deletedHere`).

### Attachments (2026-10-12)

- `read_attachment` finds the file through NotesShared:
  - `ICMedia.mediaURL`;
  - for drawings and Paper documents, `fallbackPDFURL` / `fallbackImageURL`;
  - scans are `subAttachments`.
- It also returns Notes' own `ocrSummary` / `handwritingSummary` / `imageClassificationSummary`, labeled as possibly inaccurate. One OCR summary was unrelated to the image.
- Content types, as measured with Claude Code 2.1.296:
  - Images (scaled to 1568 px JPEG) reach the model.
  - Audio and EmbeddedResource blobs are saved to a file, and the model gets the path. With Read, Claude reads a saved PDF fully.
  - Audio cannot be heard by the model.
- PDF text (PDFKit) is also returned, and must stay. Through the claude.ai connector (2026-10-12), the PDF arrives only as a saved file. Read could not render it (no pdftoppm), so the extracted text was what let Claude read the PDF. claude.ai is the reference client (owner's decision); images do reach the model through it.
- Caps: 20 MB per file, 10 scan pages, 20k characters of text.

### Shared notes (2026-10-12)

- These were verified on "MCP Test Share", a note the owner shares: append and an in-place table edit both upload, and the share data and folder are unchanged after the move nudge.
- Writes are refused only for `isSharedReadOnly` notes (shared with the user without edit rights).
- `delete_note` refuses shared notes, because as owner it can remove the note for every participant.

### Concurrent edits (G6, 2026-10-12)

- The AI appended 4 times while the user was typing in the same note in Notes. Both sides' content was all kept and merged by the CRDT, and Notes showed no error.
- If the user types during a write, the read-back sees the extra content, so the tool returns a warning ("read it again"). That is the intended conservative behavior.

### Sync: AppleScript move nudge

- Notes does not upload in-place edits by itself.
- `move note id … to folder id <its own folder>` makes Notes save and upload: 5–10 s, silent, and folder and id stay the same.
- Address the folder by id: after a move, `container of note` returns missing value.
- When Apple opens an official API whose writes sync automatically, delete the nudge.

### Deleting: AppleScript, but verified through Notes.app's own view

- `delete` on a note already in Recently Deleted **erases it permanently**.
- The store can lag Notes.app by minutes while Notes is in the background (App Nap).
- `exists note id` stays true for a note in Recently Deleted.
- `+[ICNote deleteNote:]` marks the note for permanent deletion; do not use it.
- So before and after deleting, check whether `(id of notes of folder id <trash>) contains <id>`.
- Never retry automatically. Notes deleted in this process are hidden in `deletedHere`.

### Search: plain text straight from the store

- `ZICNOTEDATA.ZDATA` is gzip + protobuf; only `document(2) → note(3) → note_text(2)` is taken.
- Cached by modification time and data length. Used only for searching and fallback descriptions.
- When Apple opens an official full-text search API, move to it and drop the private format parsing.

### Permissions and identity

- macOS charges a child process's permissions to the parent responsible for it. When frpc starts the server, frpc gets charged, and an ad-hoc build of frpc loses them on every recompile.
- The app re-launches itself through `responsibility_spawnattrs_setdisclaim` + `posix_spawn` (with stdio inherited), which makes it its own responsible process.
  - Verified with `/usr/bin/log show`: AUTHREQ_ATTRIBUTION has no `responsible` field, meaning the app is responsible for itself.
  - When macOS provides a public API for this, switch to it.
- LaunchServices `open` does not pass stdio along, so it is only used for the setup window.

### Descriptions: AI-written first, extracted otherwise

- Priority: written by the calling AI via `describe_note` (many at once, from `overview` with `undescribed: true`), then extracted (first heading or first sentence). The owner decided on 2026-10-12 against generating descriptions on the Mac. Claude Code and claude.ai do not declare `sampling`, so the server cannot ask the client's model either.
- A description goes stale when the note's modification time changes.
- When clients declare `sampling`, background generation through the client's model becomes possible.

---


## Markdown mapping (shared by read and write)

- One paragraph per line; an empty paragraph is an empty line.
- `# ## ###` for title / heading / subheading. `####` and below fall back to subheading.
- `* - 1. - [ ] - [x]` for the four list types; two spaces per indent level. `>` repeated for nested quotes.
- Consecutive monospace paragraphs become one ``` code block.
- Inline: `**` `*` `~~` `<u>` `<mark>` `[](url)`. The nesting order is fixed: mark ⊃ u ⊃ ~~ ⊃ * ⊃ **. `_` is not escaped.
- Tables use GFM: `|` is escaped and line breaks inside a cell become `<br>`. Adjacent tables split automatically wherever a separator row appears.
  - New tables are made with `addTableAttachmentWithText:`, which takes tab-separated text, so cells holding a line break or a tab are set again right after through `TableEditor` (before 2026-10-14, `5<br>箱` read back as `5 箱`).
- Bold, italic and strikethrough never cover whitespace at the edge of their span: Reader and Parse both produce this form (`normalized()` in Block.swift), so `## 🌾 **草原**`, never `## 🌾** 草原**`, which other Markdown readers show with literal asterisks.
- Attachments are written `![kind: label](attachment:<id>)` and cannot be added or removed.
- Escape rules: body lines that start with `# * - 1. > | space Tab` get a leading backslash. Inline, `\ * [ ] ~~ <u> <mark>` are escaped.
- A CR is only stripped when the whole document is CRLF; a lone `\r` inside a note is content.

---
