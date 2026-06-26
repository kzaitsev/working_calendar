import AppKit
import Foundation

@main
struct VerifyCalendarGridLayout {
    @MainActor
    static func main() throws {
        try verifyOvernightTimedEventSegmentsAcrossDays()
        try verifyReadOnlyProviderCalendarBlocksCoreMutations()
        try verifyProviderOutboxFailureClassification()
        try verifyProviderSyncStatusRespectsPersistedCooldown()
        try verifyProviderSyncStatusPrioritizesOutboxAttention()
        try verifyDeletingUnsentProviderCreateCancelsOutboxWrite()
        try verifyProviderAccountDeletionDoesNotCrossAccountPrefix()
        print("Calendar grid layout invariant passed.")
    }

    private static func verifyOvernightTimedEventSegmentsAcrossDays() throws {
        let firstDay = try localDate(year: 2026, month: 7, day: 1)
        let secondDay = try localDate(year: 2026, month: 7, day: 2)
        let days = [firstDay, secondDay]
        let overnight = event(
            id: "overnight",
            title: "Overnight incident",
            start: try localDate(year: 2026, month: 7, day: 1, hour: 23, minute: 30),
            end: try localDate(year: 2026, month: 7, day: 2, hour: 1, minute: 15)
        )
        let overlap = event(
            id: "overlap",
            title: "Follow-up bridge",
            start: try localDate(year: 2026, month: 7, day: 2, hour: 0, minute: 30),
            end: try localDate(year: 2026, month: 7, day: 2, hour: 2, minute: 0)
        )
        let later = event(
            id: "later",
            title: "Morning sync",
            start: try localDate(year: 2026, month: 7, day: 2, hour: 3, minute: 0),
            end: try localDate(year: 2026, month: 7, day: 2, hour: 4, minute: 0)
        )

        let layouts = CalendarTimedEventLayout.make(
            days: days,
            events: [overnight, overlap, later],
            hourHeight: 60
        )

        try expect(layouts.count == 4, "Expected overnight event to render as two day segments plus two same-day events")
        let firstDayOvernight = try requireLayout(layouts, eventID: "overnight", dayIndex: 0)
        try expect(firstDayOvernight.startMinute == 23 * 60 + 30, "Expected overnight segment to start at 23:30 on the first day")
        try expect(firstDayOvernight.endMinute == 24 * 60, "Expected first overnight segment to end at local day boundary")
        try expect(!firstDayOvernight.continuesFromPreviousDay, "First overnight segment should not continue from previous day")
        try expect(firstDayOvernight.continuesToNextDay, "First overnight segment should continue to next day")

        let secondDayOvernight = try requireLayout(layouts, eventID: "overnight", dayIndex: 1)
        try expect(secondDayOvernight.startMinute == 0, "Expected second overnight segment to start at day boundary")
        try expect(secondDayOvernight.endMinute == 75, "Expected second overnight segment to end at 01:15")
        try expect(secondDayOvernight.continuesFromPreviousDay, "Second overnight segment should continue from previous day")
        try expect(!secondDayOvernight.continuesToNextDay, "Second overnight segment should not continue to a third day")

        let overlapLayout = try requireLayout(layouts, eventID: "overlap", dayIndex: 1)
        try expect(secondDayOvernight.columnCount == 2, "Overnight continuation should share a two-column overlap cluster")
        try expect(overlapLayout.columnCount == 2, "Overlapping event should share a two-column overlap cluster")
        try expect(secondDayOvernight.columnIndex != overlapLayout.columnIndex, "Overlapping events should occupy distinct columns")

        let laterLayout = try requireLayout(layouts, eventID: "later", dayIndex: 1)
        try expect(laterLayout.columnCount == 1, "Non-overlapping later event should reset to a single-column cluster")

        let firstDaySpan = CalendarEventDaySpan(event: overnight, day: firstDay)
        let secondDaySpan = CalendarEventDaySpan(event: overnight, day: secondDay)
        try expect(!firstDaySpan.continuesFromPreviousDay && firstDaySpan.continuesToNextDay,
                   "Month/all-day chip span should mark the first overnight day as continuing forward")
        try expect(secondDaySpan.continuesFromPreviousDay && !secondDaySpan.continuesToNextDay,
                   "Month/all-day chip span should mark the second overnight day as continuing from the previous day")
    }

    @MainActor
    private static func verifyReadOnlyProviderCalendarBlocksCoreMutations() throws {
        resetCalendarStorage()
        defer { resetCalendarStorage() }

        let accountID = "provider-caldav-readonly-capability-fixture"
        let account = CalendarProviderAccount(
            id: accountID,
            kind: .calDAV,
            title: "Read-only CalDAV",
            endpointURLString: "https://caldav.example.com/dav",
            username: "me@example.com",
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: try localDate(year: 2026, month: 7, day: 1),
            updatedAt: try localDate(year: 2026, month: 7, day: 1)
        )
        UserDefaults.standard.set(try JSONEncoder().encode([account]), forKey: "calendarProviderAccounts")

        let calendarID = "local-calendar-caldav-\(account.id)-readonly"
        let remoteObjectURL = "https://caldav.example.com/dav/calendars/me/readonly/event.ics"
        let model = AppModel()
        let importSummary = try model.localCalendarStore.importICSText(
            readOnlyProviderICS(calendarID: calendarID, remoteObjectURL: remoteObjectURL)
        )
        try expect(importSummary.eventsImported == 1, "Expected read-only provider fixture to import one event")

        let originalEvent = try requireLocalEvent(model, externalUID: "readonly-provider-capability@example.com")
        let visibleEvent = try requireVisibleEvent(model, externalIdentifier: originalEvent.externalUID)
        try expect(!model.canEdit(visibleEvent), "AppModel should report read-only provider events as not editable")
        var backendInfo = model.backendInfo(forCalendarID: calendarID)
        try expect(backendInfo.sourceTitle == "Read-only CalDAV", "Event backend info should expose the provider account title")
        try expect(backendInfo.sourceKind == .calDAV, "Event backend info should expose the provider kind")
        try expect(!backendInfo.allowsEventWrite, "Event backend info should expose read-only event-write capability")
        try expect(!backendInfo.allowsResponses, "Event backend info should expose read-only response capability")
        try expect(backendInfo.capabilityText == "Read-only", "Read-only provider event details should use a read-only capability label")
        try expect(backendInfo.pendingOutboxCount == 0 && backendInfo.attentionOutboxCount == 0,
                   "Fresh provider event details should start with no remote update attention")

        model.moveLocalEvent(visibleEvent, dayDelta: 1, minuteDelta: 30)
        var blockedEvent = try requireLocalEvent(model, externalUID: originalEvent.externalUID)
        try expect(blockedEvent.startDate == originalEvent.startDate,
                   "Direct move calls should not mutate read-only provider events locally")
        try expect(model.providerStore.providerOutboxCount(accountID: account.id) == 0,
                   "Direct move calls should not enqueue provider writes for read-only calendars")

        model.resizeLocalEvent(visibleEvent, endMinuteDelta: 45)
        blockedEvent = try requireLocalEvent(model, externalUID: originalEvent.externalUID)
        try expect(blockedEvent.endDate == originalEvent.endDate,
                   "Direct resize calls should not mutate read-only provider events locally")
        try expect(model.providerStore.providerOutboxCount(accountID: account.id) == 0,
                   "Direct resize calls should not enqueue provider writes for read-only calendars")

        guard var draft = model.localCalendarStore.draft(for: visibleEvent) else {
            throw CalendarGridLayoutInvariantError("Expected a local draft for imported read-only provider event")
        }
        draft.title = "Should not save"
        model.saveLocalEvent(draft)
        blockedEvent = try requireLocalEvent(model, externalUID: originalEvent.externalUID)
        try expect(blockedEvent.title == originalEvent.title,
                   "Direct save calls should not mutate read-only provider events locally")
        try expect(model.providerStore.providerOutboxCount(accountID: account.id) == 0,
                   "Direct save calls should not enqueue provider writes for read-only calendars")

        let outboxItem = ProviderOutboxItem.write(
            event: originalEvent,
            accountID: account.id,
            now: try localDate(year: 2026, month: 7, day: 1)
        )
        model.providerStore.enqueueProviderOutboxItem(outboxItem)
        model.providerStore.recordProviderOutboxBlocked(
            id: outboxItem.id,
            error: "Read-only provider rejected fixture write",
            at: try localDate(year: 2026, month: 7, day: 1)
        )
        backendInfo = model.backendInfo(forCalendarID: calendarID)
        try expect(backendInfo.pendingOutboxCount == 1,
                   "Event backend info should expose provider remote updates for the event source")
        try expect(backendInfo.attentionOutboxCount == 1,
                   "Event backend info should expose provider remote updates that need attention")
    }

    @MainActor
    private static func verifyProviderOutboxFailureClassification() throws {
        resetCalendarStorage()
        defer { resetCalendarStorage() }

        let model = AppModel()
        let url = try requireURL("https://calendar.example.com/events/fixture")

        try expect(
            model.providerOutboxFailureKind(for: CalDAVClientError.preconditionFailed(url)) == .conflict,
            "CalDAV precondition failures should block on remote conflict"
        )
        try expect(
            model.providerOutboxFailureKind(for: GoogleCalendarClientError.remoteConflict(url)) == .conflict,
            "Google remote conflict failures should block on remote conflict"
        )
        try expect(
            model.providerOutboxFailureKind(for: MicrosoftGraphCalendarClientError.remoteConflict(url)) == .conflict,
            "Microsoft remote conflict failures should block on remote conflict"
        )
        try expect(
            model.providerOutboxFailureKind(for: CalDAVClientError.httpStatus(409, url)) == .conflict,
            "CalDAV HTTP 409 failures should block on remote conflict"
        )
        try expect(
            model.providerOutboxFailureKind(for: GoogleCalendarClientError.httpStatus(409, url, "conflict")) == .conflict,
            "Google HTTP 409 failures should block on remote conflict"
        )
        try expect(
            model.providerOutboxFailureKind(for: MicrosoftGraphCalendarClientError.httpStatus(409, url, "conflict")) == .conflict,
            "Microsoft HTTP 409 failures should block on remote conflict"
        )
        try expect(
            model.providerOutboxFailureKind(for: CalDAVClientError.httpStatus(403, url)) == .blocked,
            "CalDAV permission failures should be blocked instead of retried blindly"
        )
        try expect(
            model.providerOutboxFailureKind(for: GoogleCalendarClientError.missingRefreshToken) == .blocked,
            "Google missing refresh tokens should be blocked until reconnect"
        )
        try expect(
            model.providerOutboxFailureKind(for: MicrosoftGraphCalendarClientError.unsupportedAdditionalOccurrences) == .blocked,
            "Microsoft provider limitations should be blocked until the event is changed"
        )
        try expect(
            model.providerOutboxFailureKind(for: URLError(.timedOut)) == .retryable,
            "Transient network failures should remain retryable"
        )
    }

    @MainActor
    private static func verifyProviderSyncStatusRespectsPersistedCooldown() throws {
        resetCalendarStorage()
        defer { resetCalendarStorage() }

        let now = try localDate(year: 2026, month: 7, day: 1, hour: 9)
        let initialAccount = providerAccount(
            id: "provider-sync-status-initial",
            title: "Initial Google",
            now: now,
            syncNotBefore: nil
        )
        UserDefaults.standard.set(try JSONEncoder().encode([initialAccount]), forKey: "calendarProviderAccounts")
        let initialModel = AppModel()
        try expect(initialModel.providerSidebarSyncText(now: now) == "Initial sync pending",
                   "First provider sync without cooldown should remain labelled as initial pending")
        try expect(initialModel.providerSettingsSummaryText(now: now).contains("initial sync pending"),
                   "Settings summary should keep initial sync wording before the first automatic pass")

        resetCalendarStorage()
        let coolingDownAccount = providerAccount(
            id: "provider-sync-status-cooldown",
            title: "Cooling Google",
            now: now,
            syncNotBefore: now.addingTimeInterval(10 * 60)
        )
        UserDefaults.standard.set(try JSONEncoder().encode([coolingDownAccount]), forKey: "calendarProviderAccounts")
        let coolingDownModel = AppModel()
        try expect(coolingDownModel.providerSidebarSyncText(now: now)?.hasPrefix("Next sync ") == true,
                   "Persisted provider cooldown should show the next eligible sync instead of initial pending")
        try expect(coolingDownModel.providerSettingsSummaryText(now: now).contains("next"),
                   "Settings summary should reflect persisted provider cooldown after app restart")
    }

    @MainActor
    private static func verifyProviderSyncStatusPrioritizesOutboxAttention() throws {
        resetCalendarStorage()
        defer { resetCalendarStorage() }

        let now = try localDate(year: 2026, month: 7, day: 1, hour: 9)
        let account = providerAccount(
            id: "provider-sync-status-attention",
            title: "Attention Google",
            now: now,
            syncNotBefore: now.addingTimeInterval(30 * 60)
        )
        UserDefaults.standard.set(try JSONEncoder().encode([account]), forKey: "calendarProviderAccounts")

        let providerStore = CalendarProviderStore()
        let event = localProviderEvent(
            id: "provider-sync-status-attention-event",
            title: "Provider status attention fixture",
            calendarID: "local-calendar-google-provider-sync-status-attention-primary",
            now: now
        )
        providerStore.enqueueProviderOutboxItem(.write(event: event, accountID: account.id, now: now))
        guard let queuedItem = providerStore.providerOutbox.first else {
            throw CalendarGridLayoutInvariantError("Expected queued provider outbox fixture")
        }
        providerStore.recordProviderOutboxBlocked(
            id: queuedItem.id,
            error: "provider cannot save this recurrence",
            at: now.addingTimeInterval(10)
        )

        let model = AppModel()
        try expect(model.providerSidebarSyncText(now: now) == "1 remote update need attention",
                   "Provider sidebar status should prioritize blocked/conflicted outbox items over next sync time")
        let settingsSummary = model.providerSettingsSummaryText(now: now)
        try expect(settingsSummary.contains("1 remote update need attention"),
                   "Settings summary should surface provider-blocked outbox items as needing attention")
        try expect(!settingsSummary.contains("pending"),
                   "Settings summary should not describe provider-blocked items as ordinary pending updates")
    }

    @MainActor
    private static func verifyProviderAccountDeletionDoesNotCrossAccountPrefix() throws {
        resetCalendarStorage()
        defer { resetCalendarStorage() }

        let now = try localDate(year: 2026, month: 7, day: 1, hour: 9)
        let shortAccount = providerAccount(
            id: "account",
            title: "Short Google",
            now: now,
            syncNotBefore: nil
        )
        let longAccount = providerAccount(
            id: "account-extra",
            title: "Long Google",
            now: now,
            syncNotBefore: nil
        )
        UserDefaults.standard.set(try JSONEncoder().encode([shortAccount, longAccount]), forKey: "calendarProviderAccounts")

        let model = AppModel()
        let shortCalendarID = "local-calendar-google-account-primary"
        let longCalendarID = "local-calendar-google-account-extra-primary"
        let importSummary = try model.localCalendarStore.importICSText("""
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Provider Account Delete Fixture//EN
        CALSCALE:GREGORIAN
        BEGIN:VEVENT
        UID:provider-delete-short@example.com
        DTSTAMP:20260701T090000Z
        DTSTART:20260701T100000Z
        DTEND:20260701T103000Z
        SUMMARY:Short account event
        X-WORKING-CALENDAR-ID:\(shortCalendarID)
        X-WORKING-CALENDAR-TITLE:Short account calendar
        X-WORKING-CALENDAR-COLOR:#2563EB
        X-WORKING-REMOTE-OBJECT-URL:google://account/primary/event-short
        END:VEVENT
        BEGIN:VEVENT
        UID:provider-delete-long@example.com
        DTSTAMP:20260701T090000Z
        DTSTART:20260701T110000Z
        DTEND:20260701T113000Z
        SUMMARY:Long account event
        X-WORKING-CALENDAR-ID:\(longCalendarID)
        X-WORKING-CALENDAR-TITLE:Long account calendar
        X-WORKING-CALENDAR-COLOR:#7C3AED
        X-WORKING-REMOTE-OBJECT-URL:google://account-extra/primary/event-long
        END:VEVENT
        END:VCALENDAR
        """)

        try expect(importSummary.eventsImported == 2,
                   "Expected overlapping provider-account fixture events to import")
        model.deleteProviderAccount(shortAccount)
        try expect(!model.localCalendarStore.calendars.contains { $0.id == shortCalendarID },
                   "Deleting the short account should remove its own provider calendar")
        try expect(model.localCalendarStore.calendars.contains { $0.id == longCalendarID },
                   "Deleting the short account should preserve a longer account-id namespace")
        try expect(model.localCalendarStore.events.contains { $0.calendarID == longCalendarID },
                   "Deleting the short account should preserve events from the longer account-id namespace")
        try expect(!model.localCalendarStore.events.contains { $0.calendarID == shortCalendarID },
                   "Deleting the short account should remove its own provider events")
    }

    @MainActor
    private static func verifyDeletingUnsentProviderCreateCancelsOutboxWrite() throws {
        resetCalendarStorage()
        defer { resetCalendarStorage() }

        let now = try localDate(year: 2026, month: 7, day: 1, hour: 9)
        let account = providerAccount(
            id: "provider-unsent-create-delete",
            title: "Unsent Create Google",
            now: now,
            syncNotBefore: nil
        )
        UserDefaults.standard.set(try JSONEncoder().encode([account]), forKey: "calendarProviderAccounts")

        let model = AppModel()
        let calendarID = "local-calendar-google-\(account.id)-primary"
        let seedRemoteObjectURL = "google://\(account.id)/primary/seed"
        _ = try model.localCalendarStore.importICSText(providerCalendarSeedICS(
            calendarID: calendarID,
            remoteObjectURL: seedRemoteObjectURL
        ))
        try expect(model.localCalendarStore.calendar(withID: calendarID) != nil,
                   "Expected provider calendar seed import to create the provider calendar")
        try expect(
            model.localCalendarStore.removeProviderEvents(
                remoteObjectURLs: [seedRemoteObjectURL],
                calendarIDs: [calendarID]
            ) == 1,
            "Expected provider calendar seed event to be removable before testing unsent creates"
        )

        var draft = model.draftForLocalEvent(
            start: now.addingTimeInterval(3600),
            end: now.addingTimeInterval(5400)
        )
        draft.calendarID = calendarID
        draft.title = "Unsent provider create"
        model.saveLocalEvent(draft)

        try expect(model.providerStore.providerOutboxCount(accountID: account.id) == 1,
                   "Saving a new provider event before sync should queue one remote create")
        let savedEvents = model.calendarEvents(
            from: now,
            to: now.addingTimeInterval(3 * 3600),
            includeAllDay: true
        ).filter { $0.title == "Unsent provider create" }
        guard savedEvents.count == 1, let savedEvent = savedEvents.first else {
            throw CalendarGridLayoutInvariantError("Expected one unsent provider create visible event, got \(savedEvents.count)")
        }

        model.remove(savedEvent, scope: .thisEvent)
        try expect(model.localCalendarStore.events.isEmpty,
                   "Deleting an unsent provider create should remove the local event")
        try expect(model.providerStore.providerOutboxCount(accountID: account.id) == 0,
                   "Deleting an unsent provider create should cancel the queued remote create")
        try expect(!model.providerStore.hasProviderOutboxItems(accountID: account.id),
                   "Deleting an unsent provider create should not leave provider sync paused")
    }

    private static func providerCalendarSeedICS(calendarID: String, remoteObjectURL: String) -> String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Provider Calendar Seed Fixture//EN
        CALSCALE:GREGORIAN
        BEGIN:VEVENT
        UID:provider-calendar-seed@example.com
        DTSTAMP:20260701T080000Z
        DTSTART:20260701T083000Z
        DTEND:20260701T084500Z
        SUMMARY:Provider calendar seed
        X-WORKING-CALENDAR-ID:\(calendarID)
        X-WORKING-CALENDAR-TITLE:Unsent Create Provider
        X-WORKING-CALENDAR-COLOR:#2563EB
        X-WORKING-CALENDAR-ALLOWS-EVENT-WRITE:TRUE
        X-WORKING-CALENDAR-ALLOWS-RESPONSES:TRUE
        X-WORKING-REMOTE-OBJECT-URL:\(remoteObjectURL)
        END:VEVENT
        END:VCALENDAR
        """
    }

    private static func requireLayout(
        _ layouts: [CalendarTimedEventLayout],
        eventID: String,
        dayIndex: Int
    ) throws -> CalendarTimedEventLayout {
        let matches = layouts.filter { $0.event.id == eventID && $0.dayIndex == dayIndex }
        guard matches.count == 1, let layout = matches.first else {
            throw CalendarGridLayoutInvariantError("Expected exactly one layout for \(eventID) on day \(dayIndex), got \(matches.count)")
        }
        return layout
    }

    private static func event(
        id: String,
        title: String,
        start: Date,
        end: Date
    ) -> CalendarEvent {
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
            timeZoneIdentifier: TimeZone.current.identifier,
            isRecurring: false,
            isDetached: false,
            calendarID: "local-calendar-fixture",
            calendarTitle: "Fixture",
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

    @MainActor
    private static func requireLocalEvent(_ model: AppModel, externalUID: String) throws -> LocalCalendarEvent {
        let matches = model.localCalendarStore.events.filter { $0.externalUID == externalUID }
        guard matches.count == 1, let event = matches.first else {
            throw CalendarGridLayoutInvariantError("Expected exactly one local event with UID \(externalUID), got \(matches.count)")
        }
        return event
    }

    @MainActor
    private static func requireVisibleEvent(_ model: AppModel, externalIdentifier: String) throws -> CalendarEvent {
        let events = model.calendarEvents(
            from: try localDate(year: 2026, month: 7, day: 1, hour: 8),
            to: try localDate(year: 2026, month: 7, day: 1, hour: 15),
            includeAllDay: true
        ).filter { $0.externalIdentifier == externalIdentifier }
        guard events.count == 1, let event = events.first else {
            throw CalendarGridLayoutInvariantError("Expected exactly one visible event with UID \(externalIdentifier), got \(events.count)")
        }
        return event
    }

    private static func readOnlyProviderICS(calendarID: String, remoteObjectURL: String) -> String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Read Only Capability Fixture//EN
        CALSCALE:GREGORIAN
        BEGIN:VEVENT
        UID:readonly-provider-capability@example.com
        DTSTAMP:20260701T080000Z
        DTSTART:20260701T090000Z
        DTEND:20260701T093000Z
        SUMMARY:Read-only provider fixture
        X-WORKING-CALENDAR-ID:\(calendarID)
        X-WORKING-CALENDAR-TITLE:Read-only Provider
        X-WORKING-CALENDAR-COLOR:#EF4444
        X-WORKING-CALENDAR-ALLOWS-EVENT-WRITE:FALSE
        X-WORKING-CALENDAR-ALLOWS-RESPONSES:FALSE
        X-WORKING-REMOTE-OBJECT-URL:\(remoteObjectURL)
        X-WORKING-REMOTE-ETAG:readonly-etag
        END:VEVENT
        END:VCALENDAR
        """
    }

    private static func providerAccount(id: String, title: String, now: Date, syncNotBefore: Date?) -> CalendarProviderAccount {
        CalendarProviderAccount(
            id: id,
            kind: .googleCalendar,
            title: title,
            endpointURLString: "https://www.googleapis.com/calendar/v3",
            username: nil,
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            syncNotBefore: syncNotBefore,
            lastError: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func localProviderEvent(
        id: String,
        title: String,
        calendarID: String,
        now: Date
    ) -> LocalCalendarEvent {
        LocalCalendarEvent(
            id: id,
            externalUID: "\(id)@example.com",
            remoteObjectURLString: "google://\(id)",
            remoteETag: "\"etag-\(id)\"",
            sequence: 1,
            calendarID: calendarID,
            title: title,
            startDate: now.addingTimeInterval(3600),
            endDate: now.addingTimeInterval(5400),
            isAllDay: false,
            availability: .busy,
            status: .confirmed,
            privacy: .public,
            importance: .normal,
            categories: [],
            reminderOffsets: [],
            timeZoneIdentifier: TimeZone.current.identifier,
            organizerName: "",
            organizerEmail: "",
            attendees: [],
            myResponseStatus: .notInvited,
            location: "",
            notes: "",
            urlString: "",
            createdAt: now,
            updatedAt: now
        )
    }

    private static func resetCalendarStorage() {
        UserDefaults.standard.removeObject(forKey: "localCalendars")
        UserDefaults.standard.removeObject(forKey: "localCalendarEvents")
        UserDefaults.standard.removeObject(forKey: "selectedLocalCalendarIDs")
        UserDefaults.standard.removeObject(forKey: "calendarProviderAccounts")
        UserDefaults.standard.removeObject(forKey: "calendarProviderOutbox")
    }

    private static func localDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0
    ) throws -> Date {
        var components = DateComponents()
        components.calendar = Calendar.current
        components.timeZone = TimeZone.current
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        guard let date = components.date else {
            throw CalendarGridLayoutInvariantError("Invalid date fixture \(year)-\(month)-\(day) \(hour):\(minute)")
        }
        return date
    }

    private static func requireURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else {
            throw CalendarGridLayoutInvariantError("Invalid URL fixture \(value)")
        }
        return url
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw CalendarGridLayoutInvariantError(message)
        }
    }
}

private struct CalendarGridLayoutInvariantError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
