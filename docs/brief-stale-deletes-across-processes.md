# Brief: other clients see deleted notes and folders as still there

Found while using the claude.ai connector on 2026-10-14/15 (macOS 27.0.1, server 2.0.2). No code was changed for this brief.

## What happened

- 22:57–22:58: `scripts/e2e.py` created `MCP Test e2e tree 9b8a1fd2` (one subfolder, three notes) and deleted it with `manage_folder delete recursive`. All of its checks passed.
- At 22:59, 23:08 and 23:17, a different server process (the claude.ai connector) still showed the tree as live:
  - `overview` listed `MCP Test e2e tree 9b8a1fd2 (2)` and its subfolder `(1)`.
  - `read_note` gave each note's folder as the old folder, not Recently Deleted.
- Notes.app already agreed it was gone:
  - `delete_note` on one of the notes refused with "already in Recently Deleted".
  - `manage_folder delete` on the folder failed with AppleScript error -1728 ("Can't get folder id …").
- By 02:27 the next morning, every view was correct.

Why it matters: a read-only agent took the stale tree as real and reported it as a problem in the user's Notes. The weekly review routine reads Notes the same way, through the connector.

## Why the tests did not catch it

The last checks in e2e.py run `overview` in the same process that did the deletes. That process hides what it deleted itself (`deletedHere`, `deletedFoldersHere` in NotesRepository.swift), so the checks pass. Every other process reads the store directly and still sees the old state.

The e2e comment says the store lists deleted folders "for minutes". Here it was at least 19 minutes (22:58 to 23:17).

## A second e2e problem: it depends on a real folder named 「清单」

`scripts/e2e.py` tests the write guard with `manage_folder delete folder="清单"`. The owner removed that folder on 2026-10-15. `deleteFolderTree` looks the folder up before the write guard runs, so the next run will get "not found" instead of "write guard", and the check "write guard refuses a real folder tree" will fail. Pick a real folder from `overview` at run time instead, the way the `delete_note` guard check already picks any real note.

## Questions to answer

1. Why does the store keep showing deleted folders as live (`markedForDeletion == NO`), and trashed notes in their old folder, for this long? Does Notes write these changes only on some trigger, such as going idle or syncing? Could the server prompt Notes to write them?
2. Can every process hide recent deletes, not only the one that made them? For example:
   - record deletes in the shared `index.sqlite`;
   - or check recently changed items with Notes.app, the way `delete_note` already does.
3. Add an e2e check that reads from a second, fresh server process after the delete, so the test covers what other clients see.
