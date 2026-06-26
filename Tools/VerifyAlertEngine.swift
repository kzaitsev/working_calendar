import AppKit
import Foundation

@main
struct VerifyAlertEngine {
    @MainActor
    static func main() throws {
        try verifyAlertStatePrunesExactEventIDs()
        print("Alert engine invariant passed.")
    }

    @MainActor
    private static func verifyAlertStatePrunesExactEventIDs() throws {
        let engine = AlertEngine()
        let rule = AlertRule(
            name: "Exact event id pruning",
            priority: .critical,
            condition: RuleConditionGroup(mode: .all),
            leadMinutes: 10,
            repeatEverySeconds: 10,
            repeatCount: 1,
            stickyOverlay: true,
            systemNotification: true,
            playSound: false,
            speak: false,
            bounceDock: false
        )
        let now = try date("2026-07-01T12:00:00Z")
        let event1 = event(
            id: "event-1",
            title: "Prefix sibling",
            start: try date("2026-07-01T12:06:00Z"),
            end: try date("2026-07-01T12:36:00Z")
        )
        let event10 = event(
            id: "event-10",
            title: "Prefix target",
            start: try date("2026-07-01T12:05:00Z"),
            end: try date("2026-07-01T12:35:00Z")
        )

        let firstAlerts = engine.evaluate(events: [event10], rules: [rule], now: now)
        try expect(firstAlerts.map(\.event.id) == ["event-10"],
                   "Expected first alert to fire for event-10")

        let siblingAlerts = engine.evaluate(
            events: [event1],
            rules: [rule],
            now: now.addingTimeInterval(60)
        )
        try expect(siblingAlerts.map(\.event.id) == ["event-1"],
                   "Expected sibling alert to fire for event-1")

        let returningAlerts = engine.evaluate(
            events: [event10],
            rules: [rule],
            now: now.addingTimeInterval(120)
        )
        try expect(returningAlerts.map(\.event.id) == ["event-10"],
                   "Alert state pruning should use exact event ids, not string prefixes")
    }

    private static func event(id: String, title: String, start: Date, end: Date) -> CalendarEvent {
        CalendarEvent(
            id: id,
            eventIdentifier: id,
            calendarItemIdentifier: id,
            externalIdentifier: id,
            sequence: 0,
            title: title,
            startDate: start,
            endDate: end,
            occurrenceStartDate: start,
            isAllDay: false,
            availability: .busy,
            status: .confirmed,
            privacy: .public,
            importance: .normal,
            categories: [],
            reminderOffsets: [],
            timeZoneIdentifier: "UTC",
            isRecurring: false,
            isDetached: false,
            calendarID: "local-calendar-alert-fixture",
            calendarTitle: "Alert Fixture",
            sourceTitle: "Working Calendar",
            calendarColor: .systemBlue,
            location: nil,
            notes: nil,
            url: nil,
            responseStatus: .notInvited,
            responseStatusIsExplicit: false,
            attendeeCount: 0,
            organizer: nil,
            participants: []
        )
    }

    private static func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            throw AlertEngineInvariantError("Invalid date fixture: \(value)")
        }
        return date
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw AlertEngineInvariantError(message)
        }
    }
}

private struct AlertEngineInvariantError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
