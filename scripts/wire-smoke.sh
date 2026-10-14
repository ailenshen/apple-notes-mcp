#!/bin/sh
# Minimal wire-contract check for the MCP 2026-07-28 stdio server.
# Pipes hand-written JSON-RPC lines into the binary and checks each reply.
# 当官方 conformance 支持 stdio（modelcontextprotocol/conformance#258）时，改用官方测试并删除本脚本。
set -eu
BIN="${1:-.build/debug/AppleNotesMCP}"
exec python3 -I - "$BIN" <<'EOF'
import json, subprocess, sys

META = {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities": {},
}
cases = [
    # (description, request, check(reply) -> error string or None)
    ("discover", {"id": 1, "method": "server/discover", "params": {"_meta": META}},
     lambda r: None if r["result"]["supportedVersions"] == ["2026-07-28"]
        and r["result"]["resultType"] == "complete"
        and isinstance(r["result"]["ttlMs"], int) and r["result"]["cacheScope"] in ("public", "private")
        and r["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] else r),
    ("discover without clientInfo is served", {"id": "s", "method": "server/discover", "params": {"_meta": META}},
     lambda r: None if r["id"] == "s" and "result" in r else r),
    ("tools/list", {"id": 2, "method": "tools/list", "params": {"_meta": META}},
     lambda r: None if any(t["name"] == "read_note" for t in r["result"]["tools"])
        and "ttlMs" in r["result"] and "cacheScope" in r["result"] else r),
    ("tools/call with bad arguments -> -32602", {"id": 3, "method": "tools/call",
        "params": {"_meta": META, "name": "read_note", "arguments": {"id": 5}}},
     lambda r: None if r["error"]["code"] == -32602 else r),
    ("unknown tool -> -32602", {"id": 4, "method": "tools/call", "params": {"_meta": META, "name": "nope"}},
     lambda r: None if r["error"]["code"] == -32602 else r),
    ("missing _meta -> -32602", {"id": 5, "method": "server/discover", "params": {}},
     lambda r: None if r["error"]["code"] == -32602 and r["id"] == 5 else r),
    ("missing capabilities -> -32602", {"id": 6, "method": "server/discover",
        "params": {"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}}},
     lambda r: None if r["error"]["code"] == -32602 else r),
    ("wrong version -> -32022", {"id": 7, "method": "server/discover",
        "params": {"_meta": dict(META, **{"io.modelcontextprotocol/protocolVersion": "2025-11-25"})}},
     lambda r: None if r["error"]["code"] == -32022 and r["error"]["data"] == {"supported": ["2026-07-28"], "requested": "2025-11-25"} else r),
    ("unknown method -> -32601", {"id": 9, "method": "ping", "params": {"_meta": META}},
     lambda r: None if r["error"]["code"] == -32601 else r),
]
lines = [json.dumps(dict(jsonrpc="2.0", **req), ensure_ascii=False) for _, req, _ in cases]
lines.insert(1, json.dumps({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 99}}))
lines.append("{not json")
proc = subprocess.run([sys.argv[1]], input="\n".join(lines) + "\n", capture_output=True, text=True, timeout=20)
replies = [json.loads(l) for l in proc.stdout.splitlines()]
by_id = {json.dumps(r.get("id")): r for r in replies}
failed = 0
for desc, req, check in cases:
    reply = by_id.get(json.dumps(req["id"]))
    problem = "no reply" if reply is None else check(reply)
    print(("ok   " if problem is None else "FAIL ") + desc + ("" if problem is None else f": {problem}"))
    failed += problem is not None
parse = [r for r in replies if "id" not in r]
ok = len(parse) == 1 and parse[0]["error"]["code"] == -32700
print(("ok   " if ok else "FAIL ") + "parse error -> -32700 without id")
failed += not ok
ok = len(replies) == len(cases) + 1
print(("ok   " if ok else "FAIL ") + f"notification gets no reply ({len(replies)} replies)")
failed += not ok

# Legacy clients open with initialize and then send requests without _meta. They wait for each
# reply before sending the next request, so drive this process one line at a time.
legacy = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def ask(req):
    legacy.stdin.write(json.dumps(dict(jsonrpc="2.0", **req)) + "\n")
    legacy.stdin.flush()
    return json.loads(legacy.stdout.readline()) if "id" in req else None
legacy_cases = [
    ("legacy: initialize echoes a known version", {"id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}},
     lambda r: None if r["result"]["protocolVersion"] == "2025-06-18" and "tools" in r["result"]["capabilities"]
        and r["result"]["serverInfo"]["name"] == "apple-notes-mcp" else r),
    ("legacy: initialized notification", {"method": "notifications/initialized"}, None),
    ("legacy: ping", {"id": 2, "method": "ping"}, lambda r: None if r["result"] == {} else r),
    ("legacy: tools/list without _meta, without 2026-07-28 fields", {"id": 3, "method": "tools/list"},
     lambda r: None if any(t["name"] == "read_note" for t in r["result"]["tools"]) and set(r["result"]) == {"tools"} else r),
    ("legacy: bad arguments -> -32602", {"id": 4, "method": "tools/call", "params": {"name": "read_note", "arguments": {"id": 5}}},
     lambda r: None if r["error"]["code"] == -32602 else r),
    ("legacy: request with _meta still gets 2026-07-28 rules", {"id": 5, "method": "server/discover", "params": {"_meta": META}},
     lambda r: None if r["result"]["resultType"] == "complete" else r),
]
for desc, req, check in legacy_cases:
    reply = ask(req)
    problem = None if check is None else check(reply)
    print(("ok   " if problem is None else "FAIL ") + desc + ("" if problem is None else f": {problem}"))
    failed += problem is not None
legacy.stdin.close()
legacy.wait(timeout=20)
legacy_unknown = subprocess.run([sys.argv[1]], input=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {"protocolVersion": "1999-01-01"}}) + "\n", capture_output=True, text=True, timeout=20)
r = json.loads(legacy_unknown.stdout)
ok = r["result"]["protocolVersion"] == "2025-11-25"
print(("ok   " if ok else "FAIL ") + "legacy: unknown version gets the newest legacy one")
failed += not ok
# The stderr line is the evidence for removing the fallback one day (see Server.swift).
ok = "legacy initialize: unnamed client asked for 1999-01-01, got 2025-11-25" in legacy_unknown.stderr
print(("ok   " if ok else "FAIL ") + "legacy: the handshake is logged to stderr" + ("" if ok else f": {legacy_unknown.stderr!r}"))
failed += not ok
sys.exit(1 if failed else 0)
EOF
