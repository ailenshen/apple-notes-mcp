#!/usr/bin/env python3
"""Compares two server builds on the same everyday tasks, through real Claude Code sessions.

Each task runs in a fresh `claude -p` session that sees only this server's tools (no built-in
tools, no other MCP servers), and the usage Claude Code reports is collected: tokens, cost,
turns and time. The write task only touches a note it creates, titled "MCP Test Bench".

Usage:
  python3 scripts/bench.py --find "MCP Test Visual" --reps 2 \
      v1='npx -y @ailenshen/apple-notes-mcp@1.4.1' v2='npx -y @ailenshen/apple-notes-mcp@next'

`--find` names an existing note for the search-and-read task.
当 Claude Code 提供可复现的 token 计数接口（不依赖模型行为）时，把 baseline 改为直接计数。
"""
import argparse, json, os, shlex, statistics, subprocess, sys, tempfile, time

TASKS = {
    # Tool definitions are the only thing that differs, so this measures their fixed cost.
    "baseline": "Reply with the single word OK. Do not call any tools.",
    "overview": "How many notes do I have in total, and which three folders hold the most notes? Answer in one line.",
    "find": "Find my note titled '{find}' and list the kinds of formatting it uses (headings, lists, tables and so on). Be brief.",
    # The Claude Projects pattern: instructions point at one folder to read.
    "folder": "My folder '{folder}' is relevant here: read all of its notes, then summarize what the folder covers in one short paragraph.",
    "write": (
        "Create a note titled 'MCP Test Bench' containing: a heading 'Tasks' with checklist items milk, eggs "
        "and bread; a heading 'Notes' with one bullet 'first'; and a table with header Item | Qty and one row "
        "Milk | 1. Then, as separate edits: tick 'eggs', add a bullet 'second' under Notes, and change Milk's "
        "quantity to 2. Read the note back and say in one line whether all three edits are there. Finally "
        "delete the note."
    ),
}


def run(command: str, prompt: str, workdir: str) -> dict:
    config = {"mcpServers": {"notes": {"command": shlex.split(command)[0], "args": shlex.split(command)[1:],
                                       "env": {"APPLE_NOTES_MCP_WRITE_GUARD": "MCP Test "}}}}
    path = os.path.join(workdir, "mcp.json")
    with open(path, "w") as f:
        json.dump(config, f)
    started = time.time()
    out = subprocess.run(
        ["claude", "-p", prompt, "--mcp-config", path, "--strict-mcp-config", "--tools", "",
         "--allowedTools", "mcp__notes__*", "--output-format", "json"],
        cwd=workdir, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=900)
    try:
        data = json.loads(out.stdout)
    except json.JSONDecodeError:
        return {"error": (out.stdout + out.stderr)[-500:], "seconds": time.time() - started}
    usage = data.get("usage", {})
    return {
        "input": usage.get("input_tokens", 0) + usage.get("cache_creation_input_tokens", 0)
        + usage.get("cache_read_input_tokens", 0),
        "output": usage.get("output_tokens", 0),
        "cost": data.get("total_cost_usd", 0.0),
        "turns": data.get("num_turns", 0),
        "seconds": data.get("duration_ms", 0) / 1000,
        "is_error": data.get("is_error", False),
        "result": data.get("result", ""),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("servers", nargs="+", help="name='command' pairs")
    parser.add_argument("--find", default="MCP Test Visual")
    parser.add_argument("--folder", default="Projects")
    parser.add_argument("--reps", type=int, default=2)
    parser.add_argument("--tasks", default=",".join(TASKS))
    parser.add_argument("--out", default="bench-results.json")
    args = parser.parse_args()
    servers = dict(s.split("=", 1) for s in args.servers)
    results = []
    with tempfile.TemporaryDirectory() as workdir:
        for task in args.tasks.split(","):
            for rep in range(args.reps):
                for name, command in servers.items():  # interleaved, so drift hits both alike
                    r = run(command, TASKS[task].format(find=args.find, folder=args.folder), workdir)
                    r.update(server=name, task=task, rep=rep)
                    results.append(r)
                    print(json.dumps({k: v for k, v in r.items() if k != "result"}), flush=True)
    with open(args.out, "w") as f:
        json.dump(results, f, ensure_ascii=False, indent=1)

    print(f"\n{'task':<10}{'server':<8}{'input tok':>11}{'output tok':>12}{'cost $':>9}{'turns':>7}{'sec':>7}")
    for task in args.tasks.split(","):
        for name in servers:
            rows = [r for r in results if r["task"] == task and r["server"] == name and "error" not in r]
            if not rows:
                print(f"{task:<10}{name:<8}  (failed)")
                continue
            m = lambda k: statistics.mean(r[k] for r in rows)
            print(f"{task:<10}{name:<8}{m('input'):>11.0f}{m('output'):>12.0f}{m('cost'):>9.3f}{m('turns'):>7.1f}{m('seconds'):>7.1f}")


if __name__ == "__main__":
    sys.exit(main())
