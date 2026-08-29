---
name: reminders
description: Manage Apple Reminders locally on macOS. Use when the user asks to create, find, list, edit, move, complete, reopen, or delete reminders or reminder lists, including dates, notes, priorities, recurrences, and alarms.
---

# Apple Reminders

Use the `reminders_*` MCP tools as the source of truth for Apple Reminders. All data stays in the user's local EventKit store and syncs through the accounts already configured in Reminders.

## Operating rules

1. Check `reminders_access_status` only when a tool reports an authorization problem. Do not request access unless the user explicitly asks to grant it.
2. For reads, prefer `reminders_search`; use `reminders_list_lists` when a list identifier is needed and `reminders_get` for exact details.
3. Before modifying or completing an existing reminder, resolve it to a stable `reminder_id`. If multiple reminders plausibly match, ask one short clarification question.
4. After a create or update, report the returned title, list, and due date. Do not claim success without a successful tool result.
5. Treat dates in the user's local time zone unless the user specifies another zone. Ask when a date or time is materially ambiguous.
6. Setting a due date does not necessarily create an explicit EventKit alarm. When the user explicitly asks to be notified, include an absolute alarm at the requested time.
7. Never delete a reminder or list without explicit user confirmation. Pass `confirm=true` only after confirmation. For a nonempty list, also disclose the reminder count and require confirmation before `confirm_nonempty=true`.
8. Do not expose unrelated reminder content. Return only the minimum needed for the user's request.

## Supported fields

- Reminder: title, notes, URL, text location, list, start/due date, time zone, priority, completion, recurrence, absolute/relative alarm, and enter/leave geofence alarm.
- List: enumerate, create, rename, and delete.

EventKit does not expose every Reminders UI feature. Do not promise tags, subtasks, sections, attachments, templates, Smart Lists, or collaboration management.
