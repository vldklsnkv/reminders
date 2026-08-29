# Reminders for Codex

Local Apple Reminders management for Codex on macOS, implemented with EventKit and a native Swift MCP server.

## Capabilities

- Find and inspect reminders and lists.
- Create, edit, move, complete, reopen, and delete reminders.
- Manage notes, URLs, locations, dates, priorities, recurrence, and alarms.
- Create, rename, and safely delete lists.

Deletion tools require explicit confirmation. The server does not use a network service and does not export reminder data.

## Development

```bash
swift build -c release
./scripts/test-mcp
```
