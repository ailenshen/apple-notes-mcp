#!/usr/bin/env python3 -I
"""End-to-end check of the stdio server on a throwaway "MCP Test" note.

overview → search → create → search → read → describe → append → edit → update → delete,
then confirms the note sits in Recently Deleted and search no longer finds it. Writes are fenced by
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
check("overview lists folders as a tree", not err and "\nNotes (" in text and "notes in" in text, text[:300])

tag = uuid.uuid4().hex[:8]
title = f"MCP Test e2e {tag}"
err, text = call("create_note", markdown=f"# {title}\nFirst line with **bold** and zebra{tag}.\n\n## Tasks\n- [ ] one\n\n## Notes\nEnd.")
check("create_note", not err and "uploaded to iCloud" in text, text)
# Results show 8-character id prefixes, and every tool accepts them.
note_id = re.search(r"id: ([0-9A-F]{8})\b", text).group(1) if not err else ""
short = note_id

err, text = call("search", query=f"zebra{tag}")
check("search finds the new note", not err and short in text, text)

err, text = call("read_note", title=title.upper())
check("read_note by title, ignoring case", not err and f"id: {short}" in text, text[:200])
err, text = call("read_note", ids=[note_id, "MCP-missing-id"])
check("read_note reads several ids, reporting a missing one", not err and f"id: {short}" in text and "MCP-missing-id" in text, text[:300])
err, text = call("read_note", title=title + " missing")
check("read_note by a title nobody has", not err and "No note is titled" in text, text)
err, text = call("read_note", id=note_id)
version = re.search(r"version: (\w+)", text).group(1) if not err else ""
check("read_note returns Markdown and flags a missing description", not err and "**bold**" in text and "needs description" in text, text)

import datetime
today = datetime.date.today().isoformat()
err, text = call("overview", modified_after=today, sort="modified", limit=500)
check("overview lists today's notes across folders, with sizes", not err and short in text and " chars" in text, text[:300])
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
check("appended line sits in its section", "- [ ] one\n- [ ] two\n\n## Notes" in text, text)
version = re.search(r"version: (\w+)", text).group(1)

err, text = call("edit_note", id=note_id, replace=[{"old": "- [ ] one", "new": "- [x] one"}, {"old": "End.", "new": "The end."}],
                 insert="Added at the start.", at="start", version=version)
check("edit_note with two replacements and an insertion in one call", not err, text)
err, text = call("edit_note", id=note_id, replace=[{"old": "no such text", "new": "x"}])
check("edit_note reports a missing text", err and "Closest line" in text, text)
err, text = call("edit_note", id=note_id, rewrite=f"# {title}\nRewritten.")
check("edit_note rewrite needs a version", err and "version" in text, text)
err, text = call("edit_note", id=note_id, rewrite=f"# {title}\nRewritten.", version="000000000000")
check("edit_note refuses a stale version", err and "changed after you read it" in text, text)

err, text = call("read_note", id=note_id)
version = re.search(r"version: (\w+)", text).group(1)
check("all three changes landed (checklist done, text replaced, line added after the title)",
      "- [x] one" in text and "The end." in text and f"# {title}\nAdded at the start." in text, text)
err, text = call("edit_note", id=note_id, rewrite=f"# {title}\nRewritten body.\n| A | B |\n| --- | --- |\n| 1 | 2 |", version=version)
check("edit_note rewrite", not err, text)
err, text = call("read_note", id=note_id)
check("rewritten body reads back", "Rewritten body.\n| A | B |" in text, text)

folder = f"MCP Test e2e folder {tag}"
err, text = call("manage_folder", action="create", folder=folder)
check("manage_folder create", not err, text)
err, text = call("manage_folder", action="create", folder=folder)
check("manage_folder refuses a duplicate name", err and "already exists" in text, text)
err, text = call("move_note", id=note_id, folder=folder)
check("move_note into the new folder", not err and folder in text, text)
err, text = call("manage_folder", action="delete", folder=folder)
check("manage_folder refuses to delete a folder with notes", err and "not empty" in text, text)
err, text = call("manage_folder", action="rename", folder=folder, name=folder + " renamed")
check("manage_folder rename", not err, text)
err, text = call("move_note", id=note_id, folder="Notes")
check("move_note back to Notes", not err, text)
err, text = call("manage_folder", action="delete", folder=folder + " renamed")
check("manage_folder deletes the empty folder", not err, text)

err, text = call("delete_note", id="F19E73FE-16C9-4B0B-9FF0-7DDCB660F513")
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
proc.stdin.close()
proc.wait(timeout=10)
sys.exit(1 if failures else 0)
