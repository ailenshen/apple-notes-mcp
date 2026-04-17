---
name: Bug report
about: Report a bug
labels: bug
---

### Environment
- Claude Desktop:
- Node (`node -v`):

### How to reproduce

### Logs

```bash
ls ~/Library/Logs/Claude/mcp-server-*.log
tail -1000 ~/Library/Logs/Claude/mcp-server-apple-notes.log ~/Library/Logs/Claude/mcp.log
```

> Filename follows your `claude_desktop_config.json` key (e.g. `mcp-server-apple-notes-advanced.log`). HTTP mode: use your plist's `StandardErrorPath`.
>
> ⚠️ Logs contain note content — redact before attaching.
