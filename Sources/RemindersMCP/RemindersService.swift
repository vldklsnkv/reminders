import CoreLocation
import EventKit
import Foundation

final class RemindersService {
    private let store = EKEventStore()

    func call(name: String, arguments: [String: Any]) throws -> [String: Any] {
        switch name {
        case "reminders_access_status": return accessStatus()
        case "reminders_request_access": return try requestAccess()
        case "reminders_list_lists": return try listLists()
        case "reminders_create_list": return try createList(arguments)
        case "reminders_update_list": return try updateList(arguments)
        case "reminders_delete_list": return try deleteList(arguments)
        case "reminders_search": return try search(arguments)
        case "reminders_get": return try get(arguments)
        case "reminders_create": return try create(arguments)
        case "reminders_update": return try update(arguments)
        case "reminders_complete": return try complete(arguments)
        case "reminders_delete": return try delete(arguments)
        default: throw RemindersError.invalidArgument("Unknown tool: \(name)")
        }
    }

    private func accessStatus() -> [String: Any] {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        return [
            "status": authorizationName(status),
            "can_read": hasFullAccess(status),
            "can_write": hasFullAccess(status)
        ]
    }

    private func requestAccess() throws -> [String: Any] {
        let current = EKEventStore.authorizationStatus(for: .reminder)
        if hasFullAccess(current) { return accessStatus() }

        var granted = false
        var requestError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        if #available(macOS 14.0, *) {
            store.requestFullAccessToReminders { allowed, error in
                granted = allowed
                requestError = error
                semaphore.signal()
            }
        } else {
            store.requestAccess(to: .reminder) { allowed, error in
                granted = allowed
                requestError = error
                semaphore.signal()
            }
        }
        guard semaphore.wait(timeout: .now() + 60) == .success else {
            throw RemindersError.timeout("Timed out waiting for the macOS permission dialog")
        }
        if let requestError { throw requestError }
        var payload = accessStatus()
        payload["granted"] = granted
        return payload
    }

    private func listLists() throws -> [String: Any] {
        try requireAccess()
        let calendars = store.calendars(for: .reminder)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return [
            "lists": calendars.map(serializeList),
            "count": calendars.count
        ]
    }

    private func createList(_ args: [String: Any]) throws -> [String: Any] {
        try requireAccess()
        let title = try requiredNonemptyString(args, "title")
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = title

        if let defaultCalendar = store.defaultCalendarForNewReminders(), let source = defaultCalendar.source {
            calendar.source = source
        } else if let source = store.sources.first(where: { $0.sourceType == .local }) ?? store.sources.first {
            calendar.source = source
        } else {
            throw RemindersError.notFound("No writable Reminders account/source is available")
        }
        try store.saveCalendar(calendar, commit: true)
        return ["list": serializeList(calendar), "created": true]
    }

    private func updateList(_ args: [String: Any]) throws -> [String: Any] {
        try requireAccess()
        let calendar = try list(id: requiredString(args, "list_id"))
        guard calendar.allowsContentModifications else {
            throw RemindersError.readOnly("The list is read-only")
        }
        calendar.title = try requiredNonemptyString(args, "title")
        try store.saveCalendar(calendar, commit: true)
        return ["list": serializeList(calendar), "updated": true]
    }

    private func deleteList(_ args: [String: Any]) throws -> [String: Any] {
        try requireAccess()
        guard args["confirm"] as? Bool == true else {
            throw RemindersError.confirmationRequired("Set confirm=true only after the user explicitly confirms deleting this list")
        }
        let calendar = try list(id: requiredString(args, "list_id"))
        guard calendar.allowsContentModifications else {
            throw RemindersError.readOnly("The list is read-only")
        }
        let reminders = try fetchReminders(calendars: [calendar])
        guard reminders.isEmpty || args["confirm_nonempty"] as? Bool == true else {
            throw RemindersError.confirmationRequired("The list contains \(reminders.count) reminders; confirm nonempty deletion with confirm_nonempty=true")
        }
        let snapshot = serializeList(calendar)
        try store.removeCalendar(calendar, commit: true)
        return ["deleted": true, "list": snapshot, "reminder_count": reminders.count]
    }

    private func search(_ args: [String: Any]) throws -> [String: Any] {
        try requireAccess()
        let calendars: [EKCalendar]?
        if let id = optionalString(args, "list_id") {
            calendars = [try list(id: id)]
        } else {
            calendars = nil
        }

        let completion = optionalString(args, "completion") ?? "incomplete"
        guard ["any", "incomplete", "completed"].contains(completion) else {
            throw RemindersError.invalidArgument("completion must be any, incomplete, or completed")
        }
        let query = optionalString(args, "query")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeZoneID = optionalString(args, "time_zone")
        let lowerBound = try optionalString(args, "due_from").map { try DateCodec.bound($0, timeZoneID: timeZoneID, upper: false) }
        let upperBound = try optionalString(args, "due_to").map { try DateCodec.bound($0, timeZoneID: timeZoneID, upper: true) }
        let limit = min(max(args["limit"] as? Int ?? 100, 1), 500)

        var reminders = try fetchReminders(calendars: calendars)
        reminders = reminders.filter { reminder in
            if completion == "completed" && !reminder.isCompleted { return false }
            if completion == "incomplete" && reminder.isCompleted { return false }
            if let query, !query.isEmpty {
                let haystack = [reminder.title, reminder.notes, reminder.location, reminder.url?.absoluteString]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                if haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return false }
            }
            if let lowerBound {
                guard let due = DateCodec.date(from: reminder.dueDateComponents), due >= lowerBound else { return false }
            }
            if let upperBound {
                guard let due = DateCodec.date(from: reminder.dueDateComponents), due <= upperBound else { return false }
            }
            return true
        }
        reminders.sort(by: reminderSort)
        let page = Array(reminders.prefix(limit))
        return [
            "reminders": page.map(serializeReminder),
            "count": page.count,
            "total_matching": reminders.count,
            "truncated": reminders.count > page.count
        ]
    }

    private func get(_ args: [String: Any]) throws -> [String: Any] {
        try requireAccess()
        return ["reminder": serializeReminder(try reminder(id: requiredString(args, "reminder_id")))]
    }

    private func create(_ args: [String: Any]) throws -> [String: Any] {
        try requireAccess()
        let reminder = EKReminder(eventStore: store)
        reminder.title = try requiredNonemptyString(args, "title")
        if let listID = optionalString(args, "list_id") {
            reminder.calendar = try list(id: listID)
        } else if let calendar = store.defaultCalendarForNewReminders() {
            reminder.calendar = calendar
        } else {
            throw RemindersError.notFound("No default Reminders list is available")
        }
        try applyWriteFields(args, to: reminder, creating: true)
        try store.save(reminder, commit: true)
        return ["reminder": serializeReminder(reminder), "created": true]
    }

    private func update(_ args: [String: Any]) throws -> [String: Any] {
        try requireAccess()
        let reminder = try reminder(id: requiredString(args, "reminder_id"))
        try applyWriteFields(args, to: reminder, creating: false)
        try store.save(reminder, commit: true)
        return ["reminder": serializeReminder(reminder), "updated": true]
    }

    private func complete(_ args: [String: Any]) throws -> [String: Any] {
        try requireAccess()
        guard let completed = args["completed"] as? Bool else {
            throw RemindersError.invalidArgument("completed must be a boolean")
        }
        let reminder = try reminder(id: requiredString(args, "reminder_id"))
        reminder.isCompleted = completed
        reminder.completionDate = completed ? Date() : nil
        try store.save(reminder, commit: true)
        return ["reminder": serializeReminder(reminder), "updated": true]
    }

    private func delete(_ args: [String: Any]) throws -> [String: Any] {
        try requireAccess()
        guard args["confirm"] as? Bool == true else {
            throw RemindersError.confirmationRequired("Set confirm=true only after the user explicitly confirms deleting this reminder")
        }
        let reminder = try reminder(id: requiredString(args, "reminder_id"))
        let snapshot = serializeReminder(reminder)
        try store.remove(reminder, commit: true)
        return ["deleted": true, "reminder": snapshot]
    }

    private func applyWriteFields(_ args: [String: Any], to reminder: EKReminder, creating: Bool) throws {
        if !creating, args.keys.contains("title") {
            reminder.title = try requiredNonemptyString(args, "title")
        }
        if args.keys.contains("notes") { reminder.notes = nullableString(args["notes"]) }
        if args.keys.contains("url") {
            if let value = nullableString(args["url"]) {
                guard let url = URL(string: value), url.scheme != nil else {
                    throw RemindersError.invalidArgument("url must be an absolute URL")
                }
                reminder.url = url
            } else {
                reminder.url = nil
            }
        }
        if args.keys.contains("location") { reminder.location = nullableString(args["location"]) }
        if !creating, args.keys.contains("list_id") {
            guard let id = nullableString(args["list_id"]) else {
                throw RemindersError.invalidArgument("list_id cannot be null")
            }
            reminder.calendar = try list(id: id)
        }

        let timeZoneID = nullableString(args["time_zone"])
        if args.keys.contains("time_zone") {
            if let timeZoneID {
                guard let zone = TimeZone(identifier: timeZoneID) else {
                    throw RemindersError.invalidArgument("Unknown IANA time zone: \(timeZoneID)")
                }
                reminder.timeZone = zone
            } else {
                reminder.timeZone = nil
            }
        }
        if args.keys.contains("start_at") {
            reminder.startDateComponents = try nullableString(args["start_at"]).map {
                try DateCodec.components($0, timeZoneID: timeZoneID)
            }
        }
        if args.keys.contains("due_at") {
            reminder.dueDateComponents = try nullableString(args["due_at"]).map {
                try DateCodec.components($0, timeZoneID: timeZoneID)
            }
        }
        if args.keys.contains("priority") {
            reminder.priority = try priorityValue(nullableString(args["priority"]))
        }
        if args.keys.contains("recurrence") {
            reminder.recurrenceRules?.forEach { reminder.removeRecurrenceRule($0) }
            if let recurrence = args["recurrence"] as? [String: Any] {
                reminder.addRecurrenceRule(try recurrenceRule(recurrence, timeZoneID: timeZoneID))
            } else if !(args["recurrence"] is NSNull) {
                throw RemindersError.invalidArgument("recurrence must be an object or null")
            }
        }
        if args.keys.contains("alarms") {
            reminder.alarms?.forEach { reminder.removeAlarm($0) }
            if let alarms = args["alarms"] as? [[String: Any]] {
                for alarm in alarms { reminder.addAlarm(try makeAlarm(alarm)) }
            } else if !(args["alarms"] is NSNull) {
                throw RemindersError.invalidArgument("alarms must be an array or null")
            }
        }
    }

    private func recurrenceRule(_ value: [String: Any], timeZoneID: String?) throws -> EKRecurrenceRule {
        let frequencyName = try requiredString(value, "frequency")
        let frequency: EKRecurrenceFrequency
        switch frequencyName {
        case "daily": frequency = .daily
        case "weekly": frequency = .weekly
        case "monthly": frequency = .monthly
        case "yearly": frequency = .yearly
        default: throw RemindersError.invalidArgument("Unsupported recurrence frequency")
        }
        let interval = value["interval"] as? Int ?? 1
        guard interval > 0 else { throw RemindersError.invalidArgument("recurrence interval must be positive") }

        let end: EKRecurrenceEnd?
        if let count = value["occurrence_count"] as? Int {
            guard count > 0 else { throw RemindersError.invalidArgument("occurrence_count must be positive") }
            end = EKRecurrenceEnd(occurrenceCount: count)
        } else if let endAt = optionalString(value, "end_at") {
            end = EKRecurrenceEnd(end: try DateCodec.instant(endAt, timeZoneID: timeZoneID))
        } else {
            end = nil
        }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: interval, end: end)
    }

    private func makeAlarm(_ value: [String: Any]) throws -> EKAlarm {
        switch try requiredString(value, "type") {
        case "absolute":
            return EKAlarm(absoluteDate: try DateCodec.instant(requiredString(value, "at"), timeZoneID: nil))
        case "relative":
            guard let offset = value["offset_seconds"] as? NSNumber else {
                throw RemindersError.invalidArgument("relative alarm requires offset_seconds")
            }
            return EKAlarm(relativeOffset: offset.doubleValue)
        case "location":
            guard let latitude = (value["latitude"] as? NSNumber)?.doubleValue,
                  let longitude = (value["longitude"] as? NSNumber)?.doubleValue else {
                throw RemindersError.invalidArgument("location alarm requires latitude and longitude")
            }
            let structured = EKStructuredLocation(title: optionalString(value, "title") ?? "Location")
            structured.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
            if let radius = (value["radius_meters"] as? NSNumber)?.doubleValue { structured.radius = radius }
            let alarm = EKAlarm()
            alarm.structuredLocation = structured
            switch optionalString(value, "proximity") ?? "enter" {
            case "enter": alarm.proximity = .enter
            case "leave": alarm.proximity = .leave
            default: throw RemindersError.invalidArgument("proximity must be enter or leave")
            }
            return alarm
        default:
            throw RemindersError.invalidArgument("alarm type must be absolute, relative, or location")
        }
    }

    private func fetchReminders(calendars: [EKCalendar]?) throws -> [EKReminder] {
        let predicate = store.predicateForReminders(in: calendars)
        var result: [EKReminder]?
        let semaphore = DispatchSemaphore(value: 0)
        store.fetchReminders(matching: predicate) { reminders in
            result = reminders
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw RemindersError.timeout("Timed out reading reminders")
        }
        return result ?? []
    }

    private func list(id: String) throws -> EKCalendar {
        guard let calendar = store.calendar(withIdentifier: id), calendar.allowedEntityTypes.contains(.reminder) else {
            throw RemindersError.notFound("Reminders list not found: \(id)")
        }
        return calendar
    }

    private func reminder(id: String) throws -> EKReminder {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw RemindersError.notFound("Reminder not found: \(id)")
        }
        return reminder
    }

    private func requireAccess() throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        guard hasFullAccess(status) else {
            throw RemindersError.accessDenied("Reminders full access is required; current status is \(authorizationName(status))")
        }
    }

    private func hasFullAccess(_ status: EKAuthorizationStatus) -> Bool {
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }

    private func authorizationName(_ status: EKAuthorizationStatus) -> String {
        if #available(macOS 14.0, *) {
            switch status {
            case .fullAccess: return "full_access"
            case .writeOnly: return "write_only"
            case .notDetermined: return "not_determined"
            case .restricted: return "restricted"
            case .denied: return "denied"
            case .authorized: return "authorized"
            @unknown default: return "unknown_\(status.rawValue)"
            }
        }
        switch status {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        default: return "unknown_\(status.rawValue)"
        }
    }

    private func serializeList(_ calendar: EKCalendar) -> [String: Any] {
        var payload: [String: Any] = [
            "id": calendar.calendarIdentifier,
            "title": calendar.title,
            "allows_modifications": calendar.allowsContentModifications,
            "type": calendarTypeName(calendar.type)
        ]
        if let source = calendar.source {
            payload["source"] = [
                "id": source.sourceIdentifier,
                "title": source.title,
                "type": sourceTypeName(source.sourceType)
            ]
        }
        return payload
    }

    private func serializeReminder(_ reminder: EKReminder) -> [String: Any] {
        var payload: [String: Any] = [
            "id": reminder.calendarItemIdentifier,
            "title": reminder.title ?? "",
            "list_id": reminder.calendar.calendarIdentifier,
            "list_title": reminder.calendar.title,
            "priority": priorityName(reminder.priority),
            "priority_value": reminder.priority,
            "completed": reminder.isCompleted,
            "allows_modifications": reminder.calendar.allowsContentModifications
        ]
        payload["notes"] = reminder.notes ?? NSNull()
        payload["url"] = reminder.url?.absoluteString ?? NSNull()
        payload["location"] = reminder.location ?? NSNull()
        payload["start"] = DateCodec.payload(reminder.startDateComponents)
        payload["due"] = DateCodec.payload(reminder.dueDateComponents)
        payload["completion_date"] = reminder.completionDate.map(DateCodec.format) ?? NSNull()
        payload["creation_date"] = reminder.creationDate.map(DateCodec.format) ?? NSNull()
        payload["last_modified_date"] = reminder.lastModifiedDate.map(DateCodec.format) ?? NSNull()
        payload["time_zone"] = reminder.timeZone?.identifier ?? NSNull()
        payload["recurrence"] = reminder.recurrenceRules?.map(serializeRecurrence) ?? []
        payload["alarms"] = reminder.alarms?.map(serializeAlarm) ?? []
        return payload
    }

    private func serializeRecurrence(_ rule: EKRecurrenceRule) -> [String: Any] {
        var payload: [String: Any] = [
            "frequency": recurrenceFrequencyName(rule.frequency),
            "interval": rule.interval
        ]
        if let end = rule.recurrenceEnd {
            payload["end_at"] = end.endDate.map(DateCodec.format) ?? NSNull()
            payload["occurrence_count"] = end.occurrenceCount
        }
        return payload
    }

    private func serializeAlarm(_ alarm: EKAlarm) -> [String: Any] {
        if let structured = alarm.structuredLocation, let geo = structured.geoLocation {
            return [
                "type": "location",
                "title": structured.title ?? "",
                "latitude": geo.coordinate.latitude,
                "longitude": geo.coordinate.longitude,
                "radius_meters": structured.radius,
                "proximity": alarm.proximity == .leave ? "leave" : "enter"
            ]
        }
        if let date = alarm.absoluteDate {
            return ["type": "absolute", "at": DateCodec.format(date)]
        }
        return ["type": "relative", "offset_seconds": alarm.relativeOffset]
    }

    private func reminderSort(_ lhs: EKReminder, _ rhs: EKReminder) -> Bool {
        let leftDate = DateCodec.date(from: lhs.dueDateComponents)
        let rightDate = DateCodec.date(from: rhs.dueDateComponents)
        switch (leftDate, rightDate) {
        case let (l?, r?) where l != r: return l < r
        case (_?, nil): return true
        case (nil, _?): return false
        default: return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func priorityValue(_ name: String?) throws -> Int {
        switch name ?? "none" {
        case "none": return 0
        case "high": return 1
        case "medium": return 5
        case "low": return 9
        default: throw RemindersError.invalidArgument("priority must be none, high, medium, or low")
        }
    }

    private func priorityName(_ value: Int) -> String {
        switch value {
        case 1...4: return "high"
        case 5: return "medium"
        case 6...9: return "low"
        default: return "none"
        }
    }

    private func recurrenceFrequencyName(_ frequency: EKRecurrenceFrequency) -> String {
        switch frequency {
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .yearly: return "yearly"
        @unknown default: return "unknown"
        }
    }

    private func calendarTypeName(_ type: EKCalendarType) -> String {
        switch type {
        case .local: return "local"
        case .calDAV: return "caldav"
        case .exchange: return "exchange"
        case .subscription: return "subscription"
        case .birthday: return "birthday"
        @unknown default: return "unknown"
        }
    }

    private func sourceTypeName(_ type: EKSourceType) -> String {
        switch type {
        case .local: return "local"
        case .calDAV: return "caldav"
        case .exchange: return "exchange"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        case .mobileMe: return "mobileme"
        @unknown default: return "unknown"
        }
    }
}

enum DateCodec {
    static func components(_ value: String, timeZoneID: String?) throws -> DateComponents {
        if isDateOnly(value) {
            let parts = value.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { throw RemindersError.invalidArgument("Invalid date: \(value)") }
            var result = DateComponents()
            result.calendar = Calendar(identifier: .gregorian)
            result.timeZone = try zone(timeZoneID)
            result.year = parts[0]
            result.month = parts[1]
            result.day = parts[2]
            return result
        }
        let date = try instant(value, timeZoneID: timeZoneID)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try zone(timeZoneID) ?? .current
        var result = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        result.calendar = calendar
        result.timeZone = calendar.timeZone
        return result
    }

    static func instant(_ value: String, timeZoneID: String?) throws -> Date {
        if isDateOnly(value) {
            let comps = try components(value, timeZoneID: timeZoneID)
            guard let date = comps.calendar?.date(from: comps) else {
                throw RemindersError.invalidArgument("Invalid date: \(value)")
            }
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        if let date = regular.date(from: value) { return date }
        throw RemindersError.invalidArgument("Expected ISO 8601 date-time or YYYY-MM-DD: \(value)")
    }

    static func bound(_ value: String, timeZoneID: String?, upper: Bool) throws -> Date {
        let base = try instant(value, timeZoneID: timeZoneID)
        guard upper, isDateOnly(value) else { return base }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try zone(timeZoneID) ?? .current
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: base) else { return base }
        return nextDay.addingTimeInterval(-0.001)
    }

    static func date(from components: DateComponents?) -> Date? {
        guard var components else { return nil }
        var calendar = components.calendar ?? Calendar(identifier: .gregorian)
        calendar.timeZone = components.timeZone ?? .current
        components.calendar = calendar
        return calendar.date(from: components)
    }

    static func payload(_ components: DateComponents?) -> Any {
        guard let components else { return NSNull() }
        var result: [String: Any] = [
            "is_all_day": components.hour == nil,
            "time_zone": components.timeZone?.identifier ?? TimeZone.current.identifier
        ]
        if components.hour == nil {
            result["value"] = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        } else if let date = date(from: components) {
            result["value"] = format(date)
        }
        return result
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func isDateOnly(_ value: String) -> Bool {
        value.count == 10 && value[value.index(value.startIndex, offsetBy: 4)] == "-" && value[value.index(value.startIndex, offsetBy: 7)] == "-"
    }

    private static func zone(_ identifier: String?) throws -> TimeZone? {
        guard let identifier else { return nil }
        guard let zone = TimeZone(identifier: identifier) else {
            throw RemindersError.invalidArgument("Unknown IANA time zone: \(identifier)")
        }
        return zone
    }
}

enum RemindersError: LocalizedError {
    case accessDenied(String)
    case confirmationRequired(String)
    case invalidArgument(String)
    case notFound(String)
    case readOnly(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied(let message),
             .confirmationRequired(let message),
             .invalidArgument(let message),
             .notFound(let message),
             .readOnly(let message),
             .timeout(let message): return message
        }
    }
}

private func requiredString(_ args: [String: Any], _ key: String) throws -> String {
    guard let value = args[key] as? String else {
        throw RemindersError.invalidArgument("\(key) is required and must be a string")
    }
    return value
}

private func requiredNonemptyString(_ args: [String: Any], _ key: String) throws -> String {
    let value = try requiredString(args, key).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw RemindersError.invalidArgument("\(key) cannot be empty") }
    return value
}

private func optionalString(_ args: [String: Any], _ key: String) -> String? {
    args[key] as? String
}

private func nullableString(_ value: Any?) -> String? {
    value is NSNull ? nil : value as? String
}
