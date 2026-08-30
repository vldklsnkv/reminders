# Reminders for Codex

Reminders is a local Codex plugin for managing Apple Reminders on macOS. It connects Codex to the system EventKit database through a native Swift MCP server, so reminder data stays on the Mac and continues to sync through the accounts already configured in the Reminders app.

## Capabilities

- Search reminders and inspect their complete supported fields.
- Create reminders in a selected list.
- Edit titles, notes, URLs, text locations, dates, time zones, and priorities.
- Complete, reopen, move, and safely delete reminders.
- Configure recurrence and absolute or relative alarms.
- Create, rename, list, and delete reminder lists.
- Work with location-based enter and leave alarms when supported by EventKit.

The plugin resolves existing reminders to stable EventKit identifiers before changing them. If more than one reminder matches a request, Codex asks for clarification rather than guessing.

## Requirements

- macOS 14 or newer;
- Swift 5.10 or newer to build from source;
- permission for the local server to access Apple Reminders.

The MCP server is configured in [`.mcp.json`](.mcp.json) and launched through `scripts/run-reminders-mcp`. It links directly against Apple's EventKit and CoreLocation frameworks and does not require a hosted backend.

After installing the plugin, start a new Codex task and ask naturally:

```text
Show my reminders due today.
Create a reminder tomorrow at 9:00 to send the report.
Move the overdue passport reminder to next week.
```

Codex uses the `reminders` skill to choose the appropriate local MCP tool and reports the confirmed title, list, and due date after a successful change.

## Safety and privacy

- Reminder content is read from and written to the local EventKit store.
- The server does not send reminder data to a network service or maintain a separate cloud database.
- Existing reminders are changed only after an unambiguous match is resolved.
- Deleting a reminder or list requires explicit confirmation.
- Deleting a non-empty list requires an additional confirmation that includes its reminder count.
- Read operations return only the information needed for the user's request rather than unrelated reminder content.

Dates are interpreted in the user's local time zone unless another time zone is specified. A due date does not always imply an alert, so requests that explicitly mention notification create an EventKit alarm when possible.

## EventKit limitations

The plugin exposes fields available through EventKit, but Apple does not make every Reminders UI feature available to third-party code. Tags, subtasks, sections, attachments, templates, Smart Lists, and collaboration management are not currently supported.

## Build and verify

```sh
swift build -c release
./scripts/test-mcp
```

The first access request is handled by macOS. If permission is denied or restricted, the plugin reports the authorization state instead of attempting to bypass it.

Reminders for Codex is released under the MIT License. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).
