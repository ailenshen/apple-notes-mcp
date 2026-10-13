#!/usr/bin/env python3 -I
"""End-to-end check of the stdio server on a throwaway "MCP Test" note.

overview → search → create → search → read → describe → append → edit → update → delete,
then confirms the note sits in Recently Deleted and search no longer finds it. Then archives an
"MCP Test" folder tree: export to a directory and a .zip, refusals, and a recursive delete. Writes are fenced by
APPLE_NOTES_MCP_WRITE_GUARD, so only notes titled "MCP Test …" can be touched.
"""
import json, os, re, subprocess, sys, time, uuid

BIN = sys.argv[1] if len(sys.argv) > 1 else ".build/debug/AppleNotesMCP"
META = {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}
env = dict(os.environ, APPLE_NOTES_MCP_WRITE_GUARD="MCP Test ")
proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env)
counter = 0
failures = 0

def call(tool, **arguments):
    global counter
    counter += 1
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": counter, "method": "tools/call",
                                 "params": {"_meta": META, "name": tool, "arguments": arguments}}) + "\n")
    proc.stdin.flush()
    reply = json.loads(proc.stdout.readline())
    if "error" in reply:
        return True, f"JSON-RPC error {reply['error']}"
    result = reply["result"]
    return result.get("isError", False), result["content"][0]["text"]

def check(label, ok, detail=""):
    global failures
    print(("ok   " if ok else "FAIL ") + label + ("" if ok else f"\n     {detail}"))
    failures += not ok

err, text = call("overview")
check("overview lists the top folders as a tree", not err and "\nNotes (" in text and "notes in" in text, text[:300])
err, text = call("overview", depth=10)
check("overview depth shows every level", not err and "Showing" not in text.splitlines()[0], text[:300])

tag = uuid.uuid4().hex[:8]
title = f"MCP Test e2e {tag}"
err, text = call("create_note", markdown=f"# {title}\nFirst line with **bold** and zebra{tag}.\n\n## Tasks\n- [ ] one\nText after the list.\n\n## Notes\nEnd.")
check("create_note", not err and "uploaded to iCloud" in text, text)
# Results show 8-character id prefixes, and every tool accepts them.
note_id = re.search(r"id: ([0-9A-F]{8})\b", text).group(1) if not err else ""
short = note_id

err, text = call("search", query=f"zebra{tag}")
check("search finds the new note", not err and short in text, text)

err, text = call("read_note", title=title.upper())
check("read_note by title, ignoring case", not err and f"id: {short}" in text, text[:200])
err, text = call("read_note", id=note_id[:4])
check("a 4-character id prefix works (or names the candidates)", (not err and f"id: {short}" in text) or "matches several" in text, text[:200])
err, text = call("read_note", id="0000zz")
check("a missing id reads 'Not found: note …'", err and "Not found: note 0000zz" in text, text)
err, text = call("read_note", id=note_id, outline=True)
check("read_note outline lists headings with sizes, and no total", not err and "## Tasks — " in text and "## Notes — " in text
      and " chars" not in text.splitlines()[0], text)
err, text = call("read_note", id=note_id, section="tasks")
check("read_note reads one section", not err and "## Tasks" in text and "## Notes" not in text, text)
err, text = call("read_note", ids=[note_id, "MCP-missing-id"])
check("read_note reads several ids, reporting a missing one", not err and f"id: {short}" in text and "MCP-missing-id" in text, text[:300])
err, text = call("read_note", title=title + " missing")
check("read_note by a title nobody has is an error", err and "Not found: a note titled" in text, text)
err, text = call("read_note", id=note_id)
version = re.search(r"version: (\w+)", text).group(1) if not err else ""
check("read_note returns Markdown and flags a missing description", not err and "**bold**" in text and "needs description" in text, text)

import datetime
today = datetime.date.today().isoformat()
err, text = call("overview", modified_after=today, sort="modified", limit=500)
check("overview lists today's notes across folders, with sizes", not err and short in text and " chars" in text, text[:300])
check("a cross-folder list names folders on their own lines, not per note", not err and "\n[Notes]\n" in text and "| Notes |" not in text, text[:300])
err, text = call("overview", created_after=today)
check("overview created-date filter", not err and short in text and "created since" in text, text[:200])
err, text = call("overview", modified_before="2000-01-01")
check("overview date filter excludes newer notes", not err and short not in text, text[:200])
err, text = call("search", query=f"zebra{tag}", modified_after=today, sort="title")
check("search with a date filter and sort", not err and short in text and " chars" in text, text[:300])
err, text = call("search", query=f"zebra{tag}", modified_before=today)
check("search date filter excludes today's note", not err and "No notes match" in text, text[:200])
err, text = call("overview", undescribed=True, limit=200)
check("overview lists undescribed notes with their text", not err and short in text and "describe_note" in text, text[:300])
err, text = call("describe_note", descriptions=[{"id": note_id, "description": "End-to-end test note"},
                                                 {"id": "00000000-0000-0000-0000-000000000000", "description": "missing"}])
check("describe_note saves one and reports the missing one", not err and "Saved the description" in text and "Not saved" in text, text)
err, text = call("overview", folder="Notes")
check("overview shows the description", not err and "End-to-end test note" in text, text[:400])

err, text = call("edit_note", id=note_id, insert="- [ ] two", at="Tasks", version=version)
check("edit_note insert under a heading", not err, text)
err, text = call("read_note", id=note_id)
check("an inserted list item joins the section's list, before the text after it",
      "- [ ] one\n- [ ] two\nText after the list.\n\n## Notes" in text, text)
version = re.search(r"version: (\w+)", text).group(1)

err, text = call("edit_note", id=note_id, replace=[{"old": "- [ ] one", "new": "- [x] one"}, {"old": "End.", "new": "The end."}],
                 insert="Added at the start.", at="start", version=version)
check("edit_note with two replacements and an insertion in one call", not err, text)
err, text = call("edit_note", id=note_id, replace=[{"old": "no such text", "new": "x"}])
check("edit_note reports a missing text without pointing at an unrelated line", err and "Not found" in text and "Closest line" not in text, text)
err, text = call("edit_note", id=note_id, replace=[{"old": "- [ ] one", "new": "x"}])
check("edit_note points at the closest line for a near miss", err and 'Closest line: "- [' in text, text)
err, text = call("edit_note", id=note_id, rewrite=f"# {title}\nRewritten.")
check("edit_note rewrite needs a version", err and "version" in text, text)
err, text = call("edit_note", id=note_id, rewrite=f"# {title}\nRewritten.", version="000000000000")
check("edit_note refuses a stale version", err and "changed after you read it" in text, text)

err, text = call("read_note", id=note_id)
version = re.search(r"version: (\w+)", text).group(1)
check("all three changes landed (checklist done, text replaced, line added after the title)",
      "- [x] one" in text and "The end." in text and f"# {title}\nAdded at the start." in text, text)
err, text = call("edit_note", id=note_id, rewrite=f"# {title}\nRewritten body.\n| A | B |\n| --- | --- |\n| 1 | 2<br>two |", version=version)
check("edit_note rewrite, with a new table holding a line break in a cell", not err and "Warning" not in text, text)
err, text = call("read_note", id=note_id)
check("rewritten body reads back, the cell's line break included", "Rewritten body.\n| A | B |\n| --- | --- |\n| 1 | 2<br>two |" in text, text)

folder = f"MCP Test e2e folder {tag}"
err, text = call("manage_folder", action="create", folder=folder)
check("manage_folder create", not err, text)
err, text = call("manage_folder", action="create", folder=folder)
check("manage_folder refuses a duplicate name", err and "already exists" in text, text)
err, text = call("move_note", id=note_id, folder=folder)
check("move_note into the new folder", not err and folder in text, text)
err, text = call("manage_folder", action="delete", folder=folder)
check("manage_folder refuses to delete a folder with notes, pointing at recursive", err and "not empty" in text and "recursive: true" in text, text)
err, text = call("manage_folder", action="create", folder=f"{folder} missing/MCP Test child")
check("manage_folder create says to create a missing parent first", err and "create it first" in text, text)
err, text = call("manage_folder", action="rename", folder=folder, name=folder + " renamed")
check("manage_folder rename", not err, text)
# The store keeps the old name for minutes while Notes is in the background; this process
# shows the new one right away.
err, text = call("overview", folder=folder + " renamed")
check("the new name works right after the rename", not err and text.startswith(folder + " renamed"), text[:200])
err, text = call("overview", depth=10)
check("overview shows the new name, not the old one", f"{folder} renamed (" in text and f"{folder} (" not in text, text[:400])
err, text = call("move_note", id=note_id, folder="Notes")
check("move_note back to Notes", not err, text)
err, text = call("manage_folder", action="delete", folder=folder + " renamed")
check("manage_folder deletes the empty folder", not err, text)

# Any real note outside Recently Deleted will do; the write guard must stop the delete before Notes sees it.
real = next((m.group(1) for m in re.finditer(r"^([0-9A-F]{8}) \| (?!MCP Test)", call("overview", sort="modified", limit=50)[1], re.M)), None)
err, text = call("delete_note", id=real) if real else (True, "write guard (no real note to try)")
check("write guard refuses a real note", err and "write guard" in text, text)
err, text = call("delete_note", id=note_id)
check("delete_note", not err and "Recently Deleted" in text, text)
err, text = call("delete_note", id=note_id)
check("second delete is refused, not purged", err, text)
err, text = call("move_note", id=note_id, folder="Notes")
check("move_note restores from Recently Deleted", not err and "Restored" in text, text)
err, text = call("delete_note", id=note_id)
check("delete it again after restoring", not err, text)

err, text = call("read_note", id=note_id)
check("the note is in Recently Deleted", "in Recently Deleted" in text, text[:200])
err, text = call("search", query=f"zebra{tag}")
check("search no longer finds it", "No notes match" in text, text)

# Archiving a folder tree: export it (folder and zip), then delete it with its notes.
import shutil, tempfile, zipfile
tree = f"MCP Test e2e tree {tag}"
sub = f"{tree}/MCP Test sub {tag}"
check("create a folder tree", not call("manage_folder", action="create", folder=tree)[0] and not call("manage_folder", action="create", folder=sub)[0])
tree_notes = []
for i, where in enumerate([tree, tree, sub]):
    err, text = call("create_note", markdown=f"# MCP Test e2e tree note {i} {tag}\nArchive me, yak{tag}.")
    tree_notes.append(re.search(r"id: ([0-9A-F]{8})\b", text).group(1) if not err else "")
    check(f"tree note {i} moved into place", not err and not call("move_note", id=tree_notes[-1], folder=where)[0])
# Export and delete read the store, which can lag Notes by a while.
for _ in range(60):
    err, text = call("overview", folder=tree)
    if "— 3 notes" in text: break
    time.sleep(2)
check("the store shows the tree with 3 notes", "— 3 notes" in text, text)
out = tempfile.mkdtemp(prefix="mcp-e2e-export-")
err, text = call("manage_folder", action="export", folder=tree, to=f"{out}/tree")
manifest = open(f"{out}/tree/manifest.md").read() if os.path.exists(f"{out}/tree/manifest.md") else ""
check("export a folder tree to a directory", not err and "3 of 3 notes" in text and "expected_notes: 3" in text, text)
check("the export holds every note, subfolder included",
      manifest.count("| exported |") == 3 and os.path.exists(f"{out}/tree/MCP Test sub {tag}/MCP Test e2e tree note 2 {tag}.md"), manifest)
err, text = call("manage_folder", action="export", folder=tree, to=f"{out}/tree")
check("export refuses an existing destination", err and "already exists" in text, text)
err, text = call("manage_folder", action="export", folder=tree, to="~/Library/MCP Test export")
check("export refuses ~/Library", err and "Library" in text, text)
err, text = call("manage_folder", action="export", folder=tree, to=f"{out}/tree.zip")
names = zipfile.ZipFile(f"{out}/tree.zip").namelist() if not err else []
check("export to a .zip", not err and "tree/manifest.md" in names and any(n.endswith(f"note 2 {tag}.md") for n in names), text + str(names))
check("the zip leaves no temporary folder", sorted(os.listdir(out)) == ["tree", "tree.zip"], str(os.listdir(out)))
shutil.rmtree(out)

err, text = call("manage_folder", action="delete", folder=tree, recursive=True)
check("recursive delete needs expected_notes", err and "expected_notes" in text, text)
err, text = call("manage_folder", action="delete", folder=tree, recursive=True, expected_notes=2)
check("recursive delete refuses a wrong count", err and "expected_notes" in text and "Nothing was deleted" in text, text)
err, text = call("overview", folder=tree)
check("nothing moved after the refusal", "— 3 notes" in text, text)
err, text = call("manage_folder", action="delete", folder="清单", recursive=True, expected_notes=0)
check("write guard refuses a real folder tree", err and "write guard" in text, text)
started = time.time()
err, text = call("manage_folder", action="delete", folder=tree, recursive=True, expected_notes=3)
print(f"     (recursive delete of 3 notes and 2 folders took {time.time() - started:.1f}s)")
check("recursive delete moves the notes and removes both folders", not err and "Moved 3 notes" in text and "2 folders" in text, text)
check("every tree note is in Recently Deleted", all("in Recently Deleted" in call("read_note", id=n)[1] for n in tree_notes))
err, text = call("search", query=f"yak{tag}")
check("search no longer finds the tree notes", "No notes match" in text, text)
# The store lists deleted folders for minutes; this process hides the ones it deleted.
err, text = call("overview", depth=10)
check("the tree's folders are gone", tree not in text, text[:300])
proc.stdin.close()
proc.wait(timeout=10)
sys.exit(1 if failures else 0)
