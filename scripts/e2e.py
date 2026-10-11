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

def call(name, **arguments):
    global counter
    counter += 1
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": counter, "method": "tools/call",
                                 "params": {"_meta": META, "name": name, "arguments": arguments}}) + "\n")
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
check("overview lists folders", not err and "DefaultFolder-CloudKit" in text, text[:300])

tag = uuid.uuid4().hex[:8]
title = f"MCP Test e2e {tag}"
err, text = call("create_note", markdown=f"# {title}\nFirst line with **bold** and zebra{tag}.\n\n## Tasks\n- [ ] one\n\n## Notes\nEnd.")
check("create_note", not err and "uploaded to iCloud" in text, text)
note_id = re.search(r"id: ([0-9A-F-]{36})", text).group(1) if not err else ""

err, text = call("search", query=f"zebra{tag}")
check("search finds the new note", not err and note_id in text, text)

err, text = call("read_note", id=note_id)
version = re.search(r"version: (\w+)", text).group(1) if not err else ""
check("read_note returns Markdown and asks for a description", not err and "**bold**" in text and "describe_note" in text, text)

err, text = call("describe_note", id=note_id, description="End-to-end test note")
check("describe_note", not err, text)
err, text = call("overview", folder="Notes")
check("overview shows the description", not err and "End-to-end test note" in text, text[:400])

err, text = call("append_to_note", id=note_id, markdown="- [ ] two", under_heading="Tasks", version=version)
check("append_to_note under a heading", not err, text)
err, text = call("read_note", id=note_id)
check("appended line sits in its section", "- [ ] one\n- [ ] two\n\n## Notes" in text, text)
version = re.search(r"version: (\w+)", text).group(1)

err, text = call("edit_note", id=note_id, old_text="- [ ] one", new_text="- [x] one", version=version)
check("edit_note", not err, text)
err, text = call("edit_note", id=note_id, old_text="no such text", new_text="x")
check("edit_note reports a missing old_text", err and "Closest line" in text, text)
err, text = call("update_note", id=note_id, markdown=f"# {title}\nRewritten.", version="000000000000")
check("update_note refuses a stale version", err and "changed after you read it" in text, text)

err, text = call("read_note", id=note_id)
version = re.search(r"version: (\w+)", text).group(1)
check("checklist item is done", "- [x] one" in text, text)
err, text = call("update_note", id=note_id, markdown=f"# {title}\nRewritten body.\n| A | B |\n| --- | --- |\n| 1 | 2 |", version=version)
check("update_note", not err, text)
err, text = call("read_note", id=note_id)
check("rewritten body reads back", "Rewritten body.\n| A | B |" in text, text)

err, text = call("delete_note", id="F19E73FE-16C9-4B0B-9FF0-7DDCB660F513")
check("write guard refuses a real note", err and "write guard" in text, text)
err, text = call("delete_note", id=note_id)
check("delete_note", not err and "Recently Deleted" in text, text)
err, text = call("delete_note", id=note_id)
check("second delete is refused, not purged", err, text)

err, text = call("read_note", id=note_id)
check("the note is in Recently Deleted", "in Recently Deleted" in text, text[:200])
err, text = call("search", query=f"zebra{tag}")
check("search no longer finds it", "No notes match" in text, text)
proc.stdin.close()
proc.wait(timeout=10)
sys.exit(1 if failures else 0)
