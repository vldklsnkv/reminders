import Foundation

enum ToolCatalog {
    static let definitions: [[String: Any]] = [
        tool(
            "reminders_access_status",
            "Return the current macOS authorization status for Apple Reminders. This does not prompt or read reminders.",
            properties: [:]
        ),
        tool(
            "reminders_request_access",
            "Request full read/write access to Apple Reminders. Call only when the user explicitly wants to grant access.",
            properties: [:]
        ),
        tool(
            "reminders_list_lists",
            "List writable and read-only Apple Reminders lists with stable identifiers.",
            properties: [:]
        ),
        tool(
            "reminders_create_list",
            "Create a new Apple Reminders list.",
            properties: [
                "title": string("List title")
            ],
            required: ["title"]
        ),
        tool(
            "reminders_update_list",
            "Rename an Apple Reminders list.",
            properties: [
                "list_id": string("Stable list identifier"),
                "title": string("New list title")
            ],
            required: ["list_id", "title"]
        ),
        tool(
            "reminders_delete_list",
            "Delete a Reminders list. Requires explicit confirmation; nonempty lists require a second explicit flag.",
            properties: [
                "list_id": string("Stable list identifier"),
                "confirm": boolean("Must be true after the user confirms deletion"),
                "confirm_nonempty": boolean("Must be true when the list contains reminders")
            ],
            required: ["list_id", "confirm"]
        ),
        tool(
            "reminders_search",
            "Search reminders and filter by list, completion state, due range, or free text. Returns stable reminder identifiers.",
            properties: [
                "query": string("Case-insensitive text matched against title, notes, location, and URL"),
                "list_id": string("Optional list identifier"),
                "completion": enumeration(["any", "incomplete", "completed"], "Completion filter; defaults to incomplete"),
                "due_from": string("Inclusive ISO 8601 lower bound or YYYY-MM-DD"),
                "due_to": string("Inclusive ISO 8601 upper bound or YYYY-MM-DD"),
                "time_zone": string("IANA time zone for date-only values, for example Asia/Tbilisi"),
                "limit": integer("Maximum results, 1 through 500")
            ]
        ),
        tool(
            "reminders_get",
            "Get one reminder by its stable identifier.",
            properties: ["reminder_id": string("Stable reminder identifier")],
            required: ["reminder_id"]
        ),
        tool(
            "reminders_create",
            "Create a reminder with title, notes, URL, list, dates, priority, recurrence, and time or location alarms.",
            properties: reminderWriteProperties(includeIdentifier: false),
            required: ["title"]
        ),
        tool(
            "reminders_update",
            "Edit a reminder. Omitted fields stay unchanged; null clears nullable fields. Changing list_id moves the reminder.",
            properties: reminderWriteProperties(includeIdentifier: true),
            required: ["reminder_id"]
        ),
        tool(
            "reminders_complete",
            "Mark one reminder complete or incomplete. Use only when the user asked for this state change.",
            properties: [
                "reminder_id": string("Stable reminder identifier"),
                "completed": boolean("True to complete, false to reopen")
            ],
            required: ["reminder_id", "completed"]
        ),
        tool(
            "reminders_delete",
            "Permanently delete one reminder. Requires explicit user confirmation and confirm=true.",
            properties: [
                "reminder_id": string("Stable reminder identifier"),
                "confirm": boolean("Must be true after the user confirms deletion")
            ],
            required: ["reminder_id", "confirm"]
        )
    ]

    private static func tool(
        _ name: String,
        _ description: String,
        properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false
        ]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }

    private static func reminderWriteProperties(includeIdentifier: Bool) -> [String: Any] {
        var result: [String: Any] = [
            "title": nullable(string("Reminder title")),
            "notes": nullable(string("Long-form notes/body")),
            "url": nullable(string("Associated URL")),
            "location": nullable(string("Human-readable location label")),
            "list_id": nullable(string("Destination list identifier")),
            "start_at": nullable(string("ISO 8601 date-time or YYYY-MM-DD")),
            "due_at": nullable(string("ISO 8601 date-time or YYYY-MM-DD")),
            "time_zone": nullable(string("IANA time zone, for example Asia/Tbilisi")),
            "priority": nullable(enumeration(["none", "high", "medium", "low"], "Reminder priority")),
            "recurrence": nullable([
                "type": "object",
                "description": "Simple recurrence rule; null clears recurrence",
                "properties": [
                    "frequency": enumeration(["daily", "weekly", "monthly", "yearly"], "Recurrence frequency"),
                    "interval": integer("Positive interval; defaults to 1"),
                    "end_at": string("Optional ISO 8601 end date"),
                    "occurrence_count": integer("Optional positive occurrence count")
                ],
                "required": ["frequency"],
                "additionalProperties": false
            ]),
            "alarms": nullable([
                "type": "array",
                "description": "Replacing list of alarms; null or [] clears alarms",
                "items": [
                    "type": "object",
                    "properties": [
                        "type": enumeration(["absolute", "relative", "location"], "Alarm type"),
                        "at": string("ISO 8601 time for an absolute alarm"),
                        "offset_seconds": number("Relative offset in seconds, normally negative"),
                        "title": string("Location name"),
                        "latitude": number("Location latitude"),
                        "longitude": number("Location longitude"),
                        "radius_meters": number("Geofence radius in meters"),
                        "proximity": enumeration(["enter", "leave"], "Trigger on entering or leaving")
                    ],
                    "required": ["type"],
                    "additionalProperties": false
                ]
            ])
        ]
        if includeIdentifier {
            result["reminder_id"] = string("Stable reminder identifier")
        }
        return result
    }

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func boolean(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    private static func number(_ description: String) -> [String: Any] {
        ["type": "number", "description": description]
    }

    private static func integer(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    private static func enumeration(_ values: [String], _ description: String) -> [String: Any] {
        ["type": "string", "enum": values, "description": description]
    }

    private static func nullable(_ schema: [String: Any]) -> [String: Any] {
        var copy = schema
        if let type = copy["type"] as? String {
            copy["type"] = [type, "null"]
        }
        return copy
    }
}
