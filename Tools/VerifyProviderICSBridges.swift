import AppKit
import Foundation

@main
struct VerifyProviderICSBridges {
    @MainActor
    static func main() throws {
        try verifyGoogleCancelledRecurringInstanceBridge()
        try verifyGoogleCancelledRecurringInstanceCancelsDetachedOverride()
        try verifyGoogleAllDayRecurringInstanceBridge()
        try verifyGoogleAllDayCancelledRecurringInstanceCancelsDetachedOverride()
        try verifyGoogleMeetingMetadataBridge()
        try verifyGoogleSpecialEventMetadataBridge()
        try verifyGoogleAttendeesOmittedMetadataBridge()
        try verifyGoogleSelfAttendeeResponseFallbackBridge()
        try verifyGoogleSelfMarkedIdentityDiscoveryBridge()
        try verifyGoogleMailtoIdentityNormalizationBridge()
        try verifyGoogleAliasIdentityBridge()
        try verifyGoogleResourceEmailRoomFallbackBridge()
        try verifyGoogleWorkingLocationBridge()
        try verifyGoogleNonVideoConferenceEntryPointBridge()
        try verifyGoogleAttachmentMeetingLinkBridge()
        try verifyGoogleSourceURLBridge()
        try verifyGoogleDescriptionMeetingLinkFallbackBridge()
        try verifyGoogleReadOnlyCalendarBridge()
        try verifyMicrosoftCancelledOccurrenceBridge()
        try verifyMicrosoftNestedExceptionKeepSetBridge()
        try verifyMicrosoftRemovedExceptionDeletesDetachedOverride()
        try verifyMicrosoftCancelledExceptionCancelsDetachedOverride()
        try verifyMicrosoftCancelledGeneratedOccurrenceCancelsByMasterRemoteURL()
        try verifyMicrosoftAllDayCancelledGeneratedOccurrenceCancelsByMasterRemoteURL()
        try verifyMicrosoftOccurrenceIDBridgeAcrossDST()
        try verifyMicrosoftAllDayOccurrenceBridge()
        try verifyMicrosoftMeetingMetadataBridge()
        try verifyMicrosoftBodyMeetingLinkFallbackBridge()
        try verifyMicrosoftAttachmentBridge()
        try verifyMicrosoftCurrentUserResponseFallbackBridge()
        try verifyMicrosoftMailtoIdentityNormalizationBridge()
        try verifyMicrosoftAliasIdentityBridge()
        try verifyMicrosoftShowAsMetadataBridge()
        try verifyMicrosoftReadOnlyCalendarBridge()
        print("Provider ICS bridge invariant passed.")
    }

    @MainActor
    private static func verifyGoogleAllDayRecurringInstanceBridge() throws {
        let account = providerAccount(kind: .googleCalendar, endpointURLString: "https://www.googleapis.com/calendar/v3")
        let calendar = GoogleCalendarInfo(
            id: "primary@example.com",
            summary: "Google All-day Fixture",
            backgroundColor: "#4285F4",
            accessRole: "owner",
            isPrimary: true,
            defaultReminderOffsets: []
        )
        let events: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-all-day-master-1",
            "status": "confirmed",
            "summary": "Google all-day recurring fixture",
            "iCalUID": "google-all-day-series@example.com",
            "updated": "2026-06-25T08:00:00Z",
            "start": { "date": "2026-07-01" },
            "end": { "date": "2026-07-02" },
            "recurrence": ["RRULE:FREQ=WEEKLY;COUNT=3"]
          },
          {
            "id": "google-all-day-master-1_20260708",
            "status": "cancelled",
            "recurringEventId": "google-all-day-master-1",
            "originalStartTime": { "date": "2026-07-08" }
          },
          {
            "id": "google-all-day-master-1_20260715",
            "status": "confirmed",
            "summary": "Google moved all-day occurrence",
            "iCalUID": "google-all-day-series@example.com",
            "recurringEventId": "google-all-day-master-1",
            "originalStartTime": { "date": "2026-07-15" },
            "updated": "2026-06-25T08:15:00Z",
            "start": { "date": "2026-07-16" },
            "end": { "date": "2026-07-17" }
          }
        ]
        """)

        let client = GoogleCalendarClient()
        let text = try client.annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("EXDATE;VALUE=DATE:20260708"), "Google cancelled all-day instance should become date-only EXDATE")
        try expect(text.contains("RECURRENCE-ID;VALUE=DATE:20260715"),
                   "Google moved all-day instance should become date-only RECURRENCE-ID")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Google all-day bridge")
        try expect(event.isAllDay, "Google all-day master should import as all-day")
        try expect(event.excludedOccurrenceStartDates.contains { sameLocalDay($0, "2026-07-08") },
                   "Google all-day EXDATE should import as an excluded all-day occurrence")
        let detached = try requireOnlyDetachedOccurrence(
            event.detachedOccurrences,
            context: "Google all-day detached occurrence"
        )
        try expect(detached.isAllDay, "Google all-day detached occurrence should stay all-day")
        try expect(sameLocalDay(detached.originalStartDate, "2026-07-15"),
                   "Google all-day detached occurrence should keep its original recurrence day")
        try expect(sameLocalDay(detached.startDate, "2026-07-16"),
                   "Google all-day detached occurrence should keep the moved day")
        try expect(detached.title == "Google moved all-day occurrence", "Google all-day detached occurrence should preserve exception details")

        let expanded = try expandedEvents(
            from: text,
            start: "2026-07-01T00:00:00Z",
            end: "2026-07-25T00:00:00Z"
        )
        let occurrences = expanded.filter { $0.externalIdentifier == event.externalUID }
        try expect(occurrences.count == 2,
                   "Google all-day recurrence should expand first plus moved occurrence after EXDATE, got \(occurrences.map { localDayString($0.startDate) })")
        try expect(occurrences.allSatisfy(\.isAllDay), "Google all-day recurrence expansion should remain all-day")
        try expect(occurrences.contains { sameLocalDay($0.startDate, "2026-07-01") },
                   "Google all-day recurrence should include the first occurrence")
        try expect(occurrences.contains { sameLocalDay($0.startDate, "2026-07-16") && $0.isDetached },
                   "Google all-day recurrence should include the moved detached occurrence")
        try expect(!occurrences.contains { sameLocalDay($0.startDate, "2026-07-08") },
                   "Google all-day recurrence should exclude the cancelled day")
        try expect(!occurrences.contains { sameLocalDay($0.startDate, "2026-07-15") },
                   "Google all-day recurrence should not keep the original day for a moved detached occurrence")
    }

    @MainActor
    private static func verifyGoogleAllDayCancelledRecurringInstanceCancelsDetachedOverride() throws {
        let account = providerAccount(kind: .googleCalendar, endpointURLString: "https://www.googleapis.com/calendar/v3")
        let calendar = GoogleCalendarInfo(
            id: "primary@example.com",
            summary: "Google All-day Cancelled Override Fixture",
            backgroundColor: "#4285F4",
            accessRole: "owner",
            isPrimary: true,
            defaultReminderOffsets: []
        )
        let events: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-all-day-cancel-detached-master",
            "status": "confirmed",
            "summary": "Google all-day cancel detached fixture",
            "iCalUID": "google-all-day-cancel-detached-series@example.com",
            "updated": "2026-06-25T08:00:00Z",
            "start": { "date": "2026-07-01" },
            "end": { "date": "2026-07-02" },
            "recurrence": ["RRULE:FREQ=WEEKLY;COUNT=3"]
          },
          {
            "id": "google-all-day-cancel-detached-master_20260708",
            "status": "confirmed",
            "summary": "Google moved all-day then cancelled occurrence",
            "iCalUID": "google-all-day-cancel-detached-series@example.com",
            "recurringEventId": "google-all-day-cancel-detached-master",
            "originalStartTime": { "date": "2026-07-08" },
            "updated": "2026-06-25T08:15:00Z",
            "start": { "date": "2026-07-09" },
            "end": { "date": "2026-07-10" }
          }
        ]
        """)
        let cancelledEvents: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-all-day-cancel-detached-master_20260708",
            "status": "cancelled",
            "recurringEventId": "google-all-day-cancel-detached-master",
            "originalStartTime": { "date": "2026-07-08" }
          }
        ]
        """)

        let client = GoogleCalendarClient()
        let text = try client.annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        let masterRemoteObjectURL = client.remoteObjectURLString(event: events[0], calendar: calendar, account: account)
        let cancellations = client.cancelledRemoteOccurrences(
            from: cancelledEvents,
            calendar: calendar,
            account: account
        )
        guard cancellations.count == 1, let cancellation = cancellations.first else {
            throw ProviderICSBridgeInvariantError("Google cancelled all-day recurring instance should produce one cancellation")
        }
        try expect(cancellation.masterRemoteObjectURLString == masterRemoteObjectURL,
                   "Google cancelled all-day recurring instance should target the master remote URL")
        try expect(sameLocalDay(cancellation.occurrenceStartDate, "2026-07-08"),
                   "Google cancelled all-day recurring instance should target the original all-day date")

        resetLocalCalendarStorage()
        defer { resetLocalCalendarStorage() }
        let store = LocalCalendarStore()
        _ = try store.importICSText(text)
        var importedEvent = try requireOnlyEvent(store.events, context: "Google all-day cancelled detached import")
        try expect(importedEvent.detachedOccurrences.count == 1,
                   "Google all-day fixture should start with a moved detached override")

        let cancelledCount = store.cancelProviderRemoteOccurrences(cancellations)
        try expect(cancelledCount == 1,
                   "Google cancelled all-day recurring instance should update the recurring series")
        importedEvent = try requireOnlyEvent(store.events, context: "Google all-day cancelled detached after cancellation")
        try expect(importedEvent.detachedOccurrences.isEmpty,
                   "Google cancelled all-day recurring instance should remove the moved detached override")
        try expect(importedEvent.excludedOccurrenceStartDates.contains { sameLocalDay($0, "2026-07-08") },
                   "Google cancelled all-day recurring instance should add a date-only EXDATE-equivalent exclusion")

        let occurrences = store.events(
            from: date("2026-07-01T00:00:00Z"),
            to: date("2026-07-25T00:00:00Z"),
            includeAllDay: true
        )
        try expect(occurrences.contains { sameLocalDay($0.startDate, "2026-07-01") },
                   "Google all-day cancellation should keep unaffected generated occurrences")
        try expect(occurrences.contains { sameLocalDay($0.startDate, "2026-07-15") },
                   "Google all-day cancellation should keep later generated occurrences")
        try expect(!occurrences.contains { sameLocalDay($0.startDate, "2026-07-08") },
                   "Google all-day cancellation should not restore the base all-day occurrence")
        try expect(!occurrences.contains { sameLocalDay($0.startDate, "2026-07-09") },
                   "Google all-day cancellation should remove the moved all-day detached occurrence")
    }

    @MainActor
    private static func verifyGoogleCancelledRecurringInstanceBridge() throws {
        let account = providerAccount(kind: .googleCalendar, endpointURLString: "https://www.googleapis.com/calendar/v3")
        let calendar = GoogleCalendarInfo(
            id: "primary@example.com",
            summary: "Google Fixture",
            backgroundColor: "#4285F4",
            accessRole: "owner",
            isPrimary: true,
            defaultReminderOffsets: []
        )
        let events: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-master-1",
            "status": "confirmed",
            "summary": "Google recurring fixture",
            "iCalUID": "google-series@example.com",
            "updated": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-06-25T09:00:00Z" },
            "end": { "dateTime": "2026-06-25T09:30:00Z" },
            "recurrence": ["RRULE:FREQ=WEEKLY;COUNT=3"]
          },
          {
            "id": "google-master-1_20260702T090000Z",
            "status": "cancelled",
            "recurringEventId": "google-master-1",
            "originalStartTime": { "dateTime": "2026-07-02T09:00:00Z" }
          },
          {
            "id": "google-master-1_20260709T090000Z",
            "status": "confirmed",
            "summary": "Google moved occurrence",
            "iCalUID": "google-series@example.com",
            "recurringEventId": "google-master-1",
            "originalStartTime": { "dateTime": "2026-07-09T09:00:00Z" },
            "updated": "2026-06-25T08:15:00Z",
            "start": { "dateTime": "2026-07-09T10:00:00Z" },
            "end": { "dateTime": "2026-07-09T10:30:00Z" }
          }
        ]
        """)

        let client = GoogleCalendarClient()
        let text = try client.annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("EXDATE:20260702T090000Z"), "Google cancelled recurring instance should become EXDATE")
        try expect(text.contains("RECURRENCE-ID:20260709T090000Z"),
                   "Google moved recurring instance should become a detached occurrence")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Google bridge")
        try expect(event.excludedOccurrenceStartDates.contains { sameInstant($0, "2026-07-02T09:00:00Z") },
                   "Google EXDATE should import as an excluded occurrence")
        let detached = try requireOnlyDetachedOccurrence(
            event.detachedOccurrences,
            context: "Google detached occurrence"
        )
        try expect(sameInstant(detached.originalStartDate, "2026-07-09T09:00:00Z"),
                   "Google detached occurrence should keep its original recurrence start")
        try expect(sameInstant(detached.startDate, "2026-07-09T10:00:00Z"),
                   "Google detached occurrence should keep the moved start")
        try expect(detached.title == "Google moved occurrence", "Google detached occurrence should preserve exception details")
        let keepRemoteObjectURLs = client.remoteObjectURLStringsForImportedEvents(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(keepRemoteObjectURLs.contains(client.remoteObjectURLString(event: events[0], calendar: calendar, account: account)),
                   "Google full refresh keep-set should include the recurring master URL")
        try expect(keepRemoteObjectURLs.contains(client.remoteObjectURLString(event: events[2], calendar: calendar, account: account)),
                   "Google full refresh keep-set should include moved recurring instance URLs")
        try expect(!keepRemoteObjectURLs.contains(client.remoteObjectURLString(event: events[1], calendar: calendar, account: account)),
                   "Google full refresh keep-set should not keep cancelled recurring instance URLs")
        try verifyFullRefreshPruneKeepsDetachedOccurrence(
            text: text,
            calendarIDPrefix: client.localCalendarID(for: account, googleCalendarID: calendar.id),
            keepingRemoteObjectURLs: keepRemoteObjectURLs,
            rangeStart: "2026-06-25T00:00:00Z",
            rangeEnd: "2026-07-30T00:00:00Z",
            context: "Google full-refresh recurring instance keep-set"
        )

        let expanded = try expandedEvents(
            from: text,
            start: "2026-06-25T00:00:00Z",
            end: "2026-07-30T00:00:00Z"
        )
        let googleSeriesOccurrences = expanded.filter { $0.externalIdentifier == event.externalUID }
        try expect(googleSeriesOccurrences.count == 2,
                   "Google recurrence should expand first plus moved occurrence after EXDATE, got \(googleSeriesOccurrences.map { isoString($0.startDate) })")
        try expect(googleSeriesOccurrences.contains { sameInstant($0.startDate, "2026-06-25T09:00:00Z") },
                   "Google recurrence should include the first occurrence")
        try expect(googleSeriesOccurrences.contains { sameInstant($0.startDate, "2026-07-09T10:00:00Z") },
                   "Google recurrence should include the moved detached occurrence")
        try expect(!googleSeriesOccurrences.contains { sameInstant($0.startDate, "2026-07-02T09:00:00Z") },
                   "Google recurrence should exclude the cancelled occurrence")
        try expect(!googleSeriesOccurrences.contains { sameInstant($0.startDate, "2026-07-09T09:00:00Z") },
                   "Google recurrence should not keep the original start for a moved detached occurrence")
    }

    @MainActor
    private static func verifyGoogleCancelledRecurringInstanceCancelsDetachedOverride() throws {
        let account = providerAccount(kind: .googleCalendar, endpointURLString: "https://www.googleapis.com/calendar/v3")
        let calendar = GoogleCalendarInfo(
            id: "primary@example.com",
            summary: "Google Cancelled Override Fixture",
            backgroundColor: "#4285F4",
            accessRole: "owner",
            isPrimary: true,
            defaultReminderOffsets: []
        )
        let events: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-cancel-detached-master",
            "status": "confirmed",
            "summary": "Google cancel detached fixture",
            "iCalUID": "google-cancel-detached-series@example.com",
            "updated": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-06-25T09:00:00Z" },
            "end": { "dateTime": "2026-06-25T09:30:00Z" },
            "recurrence": ["RRULE:FREQ=WEEKLY;COUNT=3"]
          },
          {
            "id": "google-cancel-detached-master_20260702T090000Z",
            "status": "confirmed",
            "summary": "Google moved then cancelled occurrence",
            "iCalUID": "google-cancel-detached-series@example.com",
            "recurringEventId": "google-cancel-detached-master",
            "originalStartTime": { "dateTime": "2026-07-02T09:00:00Z" },
            "updated": "2026-06-25T08:15:00Z",
            "start": { "dateTime": "2026-07-02T10:00:00Z" },
            "end": { "dateTime": "2026-07-02T10:30:00Z" }
          }
        ]
        """)
        let cancelledEvents: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-cancel-detached-master_20260702T090000Z",
            "status": "cancelled",
            "recurringEventId": "google-cancel-detached-master",
            "originalStartTime": { "dateTime": "2026-07-02T09:00:00Z" }
          }
        ]
        """)

        let client = GoogleCalendarClient()
        let text = try client.annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        let masterRemoteObjectURL = client.remoteObjectURLString(event: events[0], calendar: calendar, account: account)
        let cancellations = client.cancelledRemoteOccurrences(
            from: cancelledEvents,
            calendar: calendar,
            account: account
        )
        try expect(cancellations == Set([
            LocalProviderRemoteOccurrenceCancellation(
                masterRemoteObjectURLString: masterRemoteObjectURL,
                occurrenceStartDate: date("2026-07-02T09:00:00Z")
            )
        ]), "Google cancelled recurring instance should target the master remote URL and original start")

        resetLocalCalendarStorage()
        defer { resetLocalCalendarStorage() }
        let store = LocalCalendarStore()
        _ = try store.importICSText(text)
        var importedEvent = try requireOnlyEvent(store.events, context: "Google cancelled detached import")
        try expect(importedEvent.detachedOccurrences.count == 1,
                   "Google fixture should start with a moved detached override")

        let cancelledCount = store.cancelProviderRemoteOccurrences(cancellations)
        try expect(cancelledCount == 1,
                   "Google cancelled recurring instance should update the recurring series")
        importedEvent = try requireOnlyEvent(store.events, context: "Google cancelled detached after cancellation")
        try expect(importedEvent.detachedOccurrences.isEmpty,
                   "Google cancelled recurring instance should remove the moved detached override")
        try expect(importedEvent.excludedOccurrenceStartDates.contains { sameInstant($0, "2026-07-02T09:00:00Z") },
                   "Google cancelled recurring instance should add an EXDATE-equivalent exclusion")

        let occurrences = store.events(
            from: date("2026-06-25T00:00:00Z"),
            to: date("2026-07-30T00:00:00Z"),
            includeAllDay: true
        )
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-06-25T09:00:00Z") },
                   "Google cancellation should keep unaffected generated occurrences")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-07-09T09:00:00Z") },
                   "Google cancellation should keep later generated occurrences")
        try expect(!occurrences.contains { sameInstant($0.startDate, "2026-07-02T09:00:00Z") },
                   "Google cancellation should not restore the base occurrence")
        try expect(!occurrences.contains { sameInstant($0.startDate, "2026-07-02T10:00:00Z") },
                   "Google cancellation should remove the moved detached occurrence")
    }

    @MainActor
    private static func verifyMicrosoftAllDayOccurrenceBridge() throws {
        let account = providerAccount(kind: .microsoft365, endpointURLString: "https://graph.microsoft.com/v1.0")
        let calendar = MicrosoftGraphCalendarInfo(
            id: "graph-calendar-all-day",
            name: "Graph All-day Fixture",
            colorHex: "#2563EB",
            canEdit: true
        )
        let events: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-all-day-master-1",
            "subject": "Graph all-day recurring fixture",
            "isCancelled": false,
            "isAllDay": true,
            "iCalUId": "graph-all-day-series@example.com",
            "type": "seriesMaster",
            "lastModifiedDateTime": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-07-01T00:00:00", "timeZone": "New Zealand Standard Time" },
            "end": { "dateTime": "2026-07-02T00:00:00", "timeZone": "New Zealand Standard Time" },
            "recurrence": {
              "pattern": {
                "type": "weekly",
                "interval": 1,
                "daysOfWeek": ["wednesday"],
                "firstDayOfWeek": "monday"
              },
              "range": {
                "type": "numbered",
                "startDate": "2026-07-01",
                "numberOfOccurrences": 3
              }
            },
            "cancelledOccurrences": ["graph-all-day-master-1.2026-07-08"]
          },
          {
            "id": "graph-all-day-master-1-20260715-exception",
            "subject": "Graph moved all-day occurrence",
            "isCancelled": false,
            "isAllDay": true,
            "iCalUId": "graph-all-day-series@example.com",
            "type": "exception",
            "seriesMasterId": "graph-all-day-master-1",
            "originalStart": "2026-07-15T00:00:00.0000000",
            "occurrenceId": "graph-all-day-master-1.2026-07-15",
            "lastModifiedDateTime": "2026-06-25T08:15:00Z",
            "start": { "dateTime": "2026-07-16T00:00:00", "timeZone": "New Zealand Standard Time" },
            "end": { "dateTime": "2026-07-17T00:00:00", "timeZone": "New Zealand Standard Time" }
          }
        ]
        """)

        let client = MicrosoftGraphCalendarClient()
        let text = try client.annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("EXDATE;VALUE=DATE:20260708"), "Microsoft cancelled all-day occurrence should become date-only EXDATE")
        try expect(text.contains("RECURRENCE-ID;VALUE=DATE:20260715"),
                   "Microsoft moved all-day occurrence should become date-only RECURRENCE-ID")
        try expect(text.contains("COUNT=3"), "Microsoft all-day numbered recurrence should become a finite RRULE COUNT")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Microsoft all-day bridge")
        try expect(event.isAllDay, "Microsoft all-day master should import as all-day")
        try expect(event.excludedOccurrenceStartDates.contains { sameLocalDay($0, "2026-07-08") },
                   "Microsoft all-day EXDATE should import as an excluded all-day occurrence")
        let detached = try requireOnlyDetachedOccurrence(
            event.detachedOccurrences,
            context: "Microsoft all-day detached occurrence"
        )
        try expect(detached.isAllDay, "Microsoft all-day detached occurrence should stay all-day")
        try expect(sameLocalDay(detached.originalStartDate, "2026-07-15"),
                   "Microsoft all-day detached occurrence should keep its original recurrence day")
        try expect(sameLocalDay(detached.startDate, "2026-07-16"),
                   "Microsoft all-day detached occurrence should keep the moved day")
        try expect(detached.title == "Graph moved all-day occurrence", "Microsoft all-day detached occurrence should preserve exception details")

        let expanded = try expandedEvents(
            from: text,
            start: "2026-07-01T00:00:00Z",
            end: "2026-07-25T00:00:00Z"
        )
        let occurrences = expanded.filter { $0.externalIdentifier == event.externalUID }
        try expect(occurrences.count == 2,
                   "Microsoft all-day recurrence should expand first plus moved occurrence after EXDATE, got \(occurrences.map { localDayString($0.startDate) })")
        try expect(occurrences.allSatisfy(\.isAllDay), "Microsoft all-day recurrence expansion should remain all-day")
        try expect(occurrences.contains { sameLocalDay($0.startDate, "2026-07-01") },
                   "Microsoft all-day recurrence should include the first occurrence")
        try expect(occurrences.contains { sameLocalDay($0.startDate, "2026-07-16") && $0.isDetached },
                   "Microsoft all-day recurrence should include the moved detached occurrence")
        try expect(!occurrences.contains { sameLocalDay($0.startDate, "2026-07-08") },
                   "Microsoft all-day recurrence should exclude the cancelled day")
        try expect(!occurrences.contains { sameLocalDay($0.startDate, "2026-07-15") },
                   "Microsoft all-day recurrence should not keep the original day for a moved detached occurrence")
    }

    private static func verifyGoogleMeetingMetadataBridge() throws {
        let account = providerAccount(
            kind: .googleCalendar,
            endpointURLString: "https://www.googleapis.com/calendar/v3",
            identityEmail: "me@example.com"
        )
        let calendar = GoogleCalendarInfo(
            id: "me@example.com",
            summary: "Google Primary Fixture",
            backgroundColor: "#0B8043",
            accessRole: "owner",
            isPrimary: true,
            defaultReminderOffsets: [10]
        )
        let events: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-metadata-1",
            "etag": "\\"metadata-etag\\"",
            "status": "confirmed",
            "summary": "Google metadata fixture",
            "description": "Discuss provider bridge metadata",
            "location": "CY-Office-1st-Conference",
            "iCalUID": "google-metadata@example.com",
            "eventType": "outOfOffice",
            "visibility": "public",
            "colorId": "5",
            "guestsCanSeeOtherGuests": false,
            "guestsCanInviteOthers": false,
            "guestsCanModify": true,
            "extendedProperties": {
              "private": {
                "workingCalendar.categories": "[\\"Customer\\",\\"Launch\\"]",
                "workingCalendar.relatedEvents": "[{\\"relationType\\":\\"PARENT\\",\\"externalUID\\":\\"parent-google-metadata@example.com\\"},{\\"relationType\\":\\"SIBLING\\",\\"externalUID\\":\\"sibling-google-metadata@example.com\\"}]",
                "workingCalendar.geoCoordinate": "{\\"latitude\\":35.1855659,\\"longitude\\":33.3822764}"
              }
            },
            "attachments": [
              { "fileUrl": "https://drive.google.com/file/d/agenda-q3", "title": "Agenda, Q3.pdf", "mimeType": "application/pdf" }
            ],
            "htmlLink": "https://calendar.google.com/event?eid=metadata",
            "created": "2026-06-25T07:45:00Z",
            "updated": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-07-01T12:00:00+03:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-01T12:30:00+03:00", "timeZone": "Asia/Nicosia" },
            "organizer": { "email": "owner@example.com", "displayName": "Owner" },
            "attendees": [
              { "email": "me@example.com", "displayName": "Me", "responseStatus": "accepted", "self": true },
              { "email": "teammate@example.com", "displayName": "Team \\"Calendar\\"^Core", "responseStatus": "needsAction", "optional": true },
              { "email": "cy-office-1st-conference@resource.calendar.google.com", "displayName": "CY-Office-1st-Conference", "responseStatus": "accepted", "resource": true }
            ],
            "conferenceData": {
              "conferenceSolution": {
                "key": { "type": "hangoutsMeet" }
              },
              "entryPoints": [
                { "entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij" }
              ]
            },
            "reminders": { "useDefault": true }
          }
        ]
        """)

        let text = try GoogleCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("X-WORKING-MY-RESPONSE:accepted"), "Google bridge should preserve current user response")
        try expect(text.contains("URL:https://meet.google.com/abc-defg-hij"), "Google bridge should prefer the conference video URL")
        try expect(text.contains("ATTACH;VALUE=URI;FMTTYPE=application/pdf;X-FILENAME=\"Agenda, Q3.pdf\":https://drive.google.com/file/d/agenda-q3"),
                   "Google bridge should preserve provider attachments as iCalendar ATTACH properties")
        try expect(text.contains("RELATED-TO;RELTYPE=PARENT:parent-google-metadata@example.com"),
                   "Google bridge should preserve provider private related-event metadata as RELATED-TO")
        try expect(text.contains("GEO:35.1855659;33.3822764"),
                   "Google bridge should preserve provider private GEO metadata")
        try expect(text.contains("CUTYPE=RESOURCE"), "Google bridge should mark resource attendees")
        try expect(text.contains("PARTSTAT=NEEDS-ACTION;ROLE=OPT-PARTICIPANT;RSVP=TRUE;CN=\"Team ^'Calendar^'^^Core\""),
                   "Google bridge should preserve needsAction attendees as RSVP requests with RFC6868 parameter escaping")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Google metadata bridge")
        try expect(event.remoteETag == "\"metadata-etag\"", "Google metadata bridge should import remote ETag for safe write-back")
        try expect(event.myResponseStatus == .accepted, "Google metadata bridge should import my accepted response")
        try expect(event.organizerEmail == "owner@example.com", "Google metadata bridge should import organizer email")
        try expect(event.urlString == "https://meet.google.com/abc-defg-hij", "Google metadata bridge should import the Meet URL")
        try expect(event.location == "CY-Office-1st-Conference", "Google metadata bridge should import the physical location")
        try expect(event.reminderOffsets == [10], "Google metadata bridge should apply default calendar reminders")
        try expect(event.privacy == .public, "Google metadata bridge should import explicit public visibility as local public privacy")
        try expect(event.categories == ["Google color 5", "Google visibility public", "Google event type outOfOffice", "Google guest list hidden", "Google guests cannot invite", "Google guests can modify", "Google conference hangoutsMeet", "Customer", "Launch"],
                   "Google metadata bridge should preserve color, explicit public visibility, event type, guest permissions, conference metadata, and Working Calendar categories")
        try expect(event.attachments == [
            LocalEventAttachment(
                urlString: "https://drive.google.com/file/d/agenda-q3",
                formatType: "application/pdf",
                displayName: "Agenda, Q3.pdf"
            )
        ], "Google metadata bridge should import provider attachments as structured local attachments")
        try expect(event.relatedEvents == [
            LocalEventRelationship(relationType: "PARENT", externalUID: "parent-google-metadata@example.com"),
            LocalEventRelationship(relationType: "SIBLING", externalUID: "sibling-google-metadata@example.com")
        ], "Google metadata bridge should import provider private relationships as structured local relationships")
        try expect(event.geoCoordinate == LocalEventGeoCoordinate(latitude: 35.1855659, longitude: 33.3822764),
                   "Google metadata bridge should import provider private GEO coordinates")
        try expect(event.attendees.contains { $0.email == "me@example.com" && $0.isCurrentUser && $0.status == .accepted },
                   "Google metadata bridge should mark the current user attendee")
        try expect(event.attendees.contains { $0.email == "teammate@example.com" && $0.role == "optional" && $0.status == .pending && $0.rsvp },
                   "Google metadata bridge should preserve optional pending attendees that require a response")
        try expect(event.attendees.contains { $0.email.contains("@resource.calendar.google.com") && $0.isRoomLike },
                   "Google metadata bridge should preserve room/resource attendees")
    }

    private static func verifyGoogleSpecialEventMetadataBridge() throws {
        let account = providerAccount(kind: .googleCalendar, endpointURLString: "https://www.googleapis.com/calendar/v3")
        let calendar = GoogleCalendarInfo(
            id: "primary@example.com",
            summary: "Google Special Event Fixture",
            backgroundColor: "#4285F4",
            accessRole: "owner",
            isPrimary: true,
            defaultReminderOffsets: []
        )
        let events: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-out-of-office-1",
            "etag": "\\"out-of-office-etag\\"",
            "status": "confirmed",
            "summary": "Out of office",
            "iCalUID": "google-out-of-office@example.com",
            "eventType": "outOfOffice",
            "updated": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-07-01T09:00:00+03:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-01T17:00:00+03:00", "timeZone": "Asia/Nicosia" },
            "outOfOfficeProperties": {
              "autoDeclineMode": "declineAllConflictingInvitations",
              "declineMessage": "OOO until Monday"
            }
          },
          {
            "id": "google-focus-time-1",
            "etag": "\\"focus-time-etag\\"",
            "status": "confirmed",
            "summary": "Focus time",
            "iCalUID": "google-focus-time@example.com",
            "eventType": "focusTime",
            "updated": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-07-02T10:00:00+03:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-02T12:00:00+03:00", "timeZone": "Asia/Nicosia" },
            "focusTimeProperties": {
              "autoDeclineMode": "declineOnlyNewConflictingInvitations",
              "declineMessage": "Focus block",
              "chatStatus": "doNotDisturb"
            }
          }
        ]
        """)

        let text = try GoogleCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )

        let imported = try LocalCalendarICSCodec.import(text)
        let byTitle = Dictionary(uniqueKeysWithValues: imported.events.map { ($0.title, $0) })
        guard let outOfOfficeEvent = byTitle["Out of office"],
              let focusTimeEvent = byTitle["Focus time"] else {
            throw ProviderICSBridgeInvariantError("Google special-event bridge should import all fixture events")
        }

        try expect(outOfOfficeEvent.categories == [
            "Google event type outOfOffice",
            "Google out of office auto decline declineAllConflictingInvitations",
            "Google out of office decline message OOO until Monday"
        ], "Google out-of-office bridge should preserve native auto-decline metadata")
        try expect(focusTimeEvent.categories == [
            "Google event type focusTime",
            "Google focus time auto decline declineOnlyNewConflictingInvitations",
            "Google focus time decline message Focus block",
            "Google focus time chat status doNotDisturb"
        ], "Google focus-time bridge should preserve native focus metadata")
    }

    private static func verifyGoogleAttendeesOmittedMetadataBridge() throws {
        let account = providerAccount(kind: .googleCalendar, endpointURLString: "https://www.googleapis.com/calendar/v3")
        let calendar = GoogleCalendarInfo(
            id: "primary@example.com",
            summary: "Google Omitted Attendees Fixture",
            backgroundColor: "#4285F4",
            accessRole: "owner",
            isPrimary: true,
            defaultReminderOffsets: []
        )
        let events: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-attendees-omitted-1",
            "etag": "\\"attendees-omitted-etag\\"",
            "status": "confirmed",
            "summary": "Google attendees omitted fixture",
            "iCalUID": "google-attendees-omitted@example.com",
            "htmlLink": "https://calendar.google.com/event?eid=attendees-omitted",
            "created": "2026-06-25T08:10:00Z",
            "updated": "2026-06-25T08:11:00Z",
            "start": { "dateTime": "2026-07-01T15:00:00+03:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-01T15:30:00+03:00", "timeZone": "Asia/Nicosia" },
            "attendeesOmitted": true,
            "attendees": [
              { "email": "me@example.com", "displayName": "Me", "responseStatus": "accepted", "self": true }
            ]
          }
        ]
        """)

        let text = try GoogleCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("Google attendees omitted"),
                   "Google bridge should annotate events whose attendee list was omitted by the provider")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Google attendees omitted bridge")
        try expect(event.categories.contains("Google attendees omitted"),
                   "Google attendees omitted metadata should survive local import")
        try expect(event.attendees.count == 1 && event.attendees.first?.email == "me@example.com",
                   "Google attendees omitted bridge should preserve the attendees the provider did return")
    }

    private static func verifyGoogleSelfAttendeeResponseFallbackBridge() throws {
        let account = providerAccount(kind: .googleCalendar, endpointURLString: "https://www.googleapis.com/calendar/v3")
        let calendar = GoogleCalendarInfo(
            id: "opaque-google-calendar-id",
            summary: "Google Self Fixture",
            backgroundColor: "#4285F4",
            accessRole: "writer",
            isPrimary: false,
            defaultReminderOffsets: []
        )
        let events: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-self-fallback-1",
            "etag": "\\"self-fallback-etag\\"",
            "status": "confirmed",
            "summary": "Google self fallback fixture",
            "iCalUID": "google-self-fallback@example.com",
            "updated": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-07-01T13:00:00+03:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-01T13:30:00+03:00", "timeZone": "Asia/Nicosia" },
            "attendees": [
              { "email": "me@example.com", "displayName": "Me", "responseStatus": "tentative", "self": true },
              { "email": "teammate@example.com", "displayName": "Teammate", "responseStatus": "accepted" }
            ]
          }
        ]
        """)

        let text = try GoogleCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("X-WORKING-MY-RESPONSE:tentative"),
                   "Google self attendee bridge should preserve my response without account identity email")
        try expect(text.contains("X-WORKING-CURRENT-USER=TRUE"),
                   "Google self attendee bridge should mark the current user from the self flag")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Google self attendee bridge")
        try expect(event.myResponseStatus == .tentative,
                   "Google self attendee bridge should import my tentative response from the self attendee")
        try expect(event.attendees.contains { $0.email == "me@example.com" && $0.isCurrentUser && $0.status == .tentative },
                   "Google self attendee bridge should import the self attendee as current user")
    }

    private static func verifyGoogleSelfMarkedIdentityDiscoveryBridge() throws {
        let calendar = GoogleCalendarInfo(
            id: "team-calendar@group.calendar.google.com",
            summary: "Google Identity Discovery Fixture",
            backgroundColor: "#0B8043",
            accessRole: "reader",
            isPrimary: false,
            defaultReminderOffsets: []
        )
        let events: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-self-identity-1",
            "summary": "Google self identity fixture",
            "organizer": { "email": "me@example.com", "displayName": "Me", "self": true },
            "creator": { "email": "ME@example.com", "displayName": "Me", "self": true },
            "attendees": [
              { "email": "ME+calendar@example.com", "displayName": "Me alias", "responseStatus": "accepted", "self": true },
              { "email": "cy-office-pod@resource.calendar.google.com", "displayName": "CY Office Pod", "responseStatus": "accepted", "resource": true, "self": true }
            ]
          }
        ]
        """)
        let payload = GoogleCalendarPayload(
            calendar: calendar,
            events: events,
            deletedRemoteObjectURLs: [],
            cancelledRemoteOccurrences: [],
            isIncremental: false,
            syncToken: "identity-sync-token",
            windowStartDate: date("2026-07-01T00:00:00Z"),
            windowEndDate: date("2026-08-01T00:00:00Z")
        )

        try expect(payload.accountIdentityEmails == ["me@example.com", "me+calendar@example.com"],
                   "Google self-marked organizer/attendees should become persistent account identity emails")
    }

    private static func verifyGoogleMailtoIdentityNormalizationBridge() throws {
        let account = providerAccount(
            kind: .googleCalendar,
            endpointURLString: "https://www.googleapis.com/calendar/v3",
            identityEmail: "mailto:ME%2Bcalendar%40example.com?subject=calendar"
        )
        let calendar = GoogleCalendarInfo(
            id: "opaque-google-calendar-id",
            summary: "Google Mailto Identity Fixture",
            backgroundColor: "#4285F4",
            accessRole: "writer",
            isPrimary: false,
            defaultReminderOffsets: []
        )
        let events: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-mailto-identity-1",
            "etag": "\\"mailto-identity-etag\\"",
            "status": "confirmed",
            "summary": "Google mailto identity fixture",
            "iCalUID": "google-mailto-identity@example.com",
            "updated": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-07-01T13:30:00+03:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-01T14:00:00+03:00", "timeZone": "Asia/Nicosia" },
            "attendees": [
              { "email": "me+calendar@example.com", "displayName": "Me", "responseStatus": "accepted" },
              { "email": "teammate@example.com", "displayName": "Teammate", "responseStatus": "needsAction" }
            ]
          }
        ]
        """)

        let text = try GoogleCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("X-WORKING-MY-RESPONSE:accepted"),
                   "Google bridge should normalize mailto/percent-encoded account identity when detecting my response")
        try expect(text.contains("X-WORKING-CURRENT-USER=TRUE"),
                   "Google bridge should mark current user from normalized mailto identity")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Google mailto identity bridge")
        try expect(event.myResponseStatus == .accepted,
                   "Google mailto identity bridge should import my accepted response")
        try expect(event.attendees.contains { $0.email == "me+calendar@example.com" && $0.isCurrentUser && $0.status == .accepted },
                   "Google mailto identity bridge should import the normalized identity attendee as current user")
    }

    private static func verifyGoogleAliasIdentityBridge() throws {
        let account = providerAccount(
            kind: .googleCalendar,
            endpointURLString: "https://www.googleapis.com/calendar/v3",
            identityEmail: "primary@example.com",
            identityEmailAliases: ["alias@example.com"]
        )
        let calendar = GoogleCalendarInfo(
            id: "opaque-google-calendar-id",
            summary: "Google Alias Identity Fixture",
            backgroundColor: "#4285F4",
            accessRole: "writer",
            isPrimary: false,
            defaultReminderOffsets: []
        )
        let events: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-alias-identity-1",
            "etag": "\\"alias-identity-etag\\"",
            "status": "confirmed",
            "summary": "Google alias identity fixture",
            "iCalUID": "google-alias-identity@example.com",
            "updated": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-07-01T14:00:00+03:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-01T14:30:00+03:00", "timeZone": "Asia/Nicosia" },
            "attendees": [
              { "email": "alias@example.com", "displayName": "Alias Me", "responseStatus": "accepted" },
              { "email": "teammate@example.com", "displayName": "Teammate", "responseStatus": "needsAction" }
            ]
          }
        ]
        """)

        let text = try GoogleCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("X-WORKING-MY-RESPONSE:accepted"),
                   "Google bridge should use account identity aliases when detecting my response")
        try expect(text.contains("X-WORKING-CURRENT-USER=TRUE"),
                   "Google bridge should mark current user from an account identity alias")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Google alias identity bridge")
        try expect(event.myResponseStatus == .accepted,
                   "Google alias identity bridge should import my accepted response")
        try expect(event.attendees.contains { $0.email == "alias@example.com" && $0.isCurrentUser && $0.status == .accepted },
                   "Google alias identity bridge should import the alias attendee as current user")
    }

    private static func verifyGoogleResourceEmailRoomFallbackBridge() throws {
        let account = providerAccount(kind: .googleCalendar, endpointURLString: "https://www.googleapis.com/calendar/v3")
        let calendar = GoogleCalendarInfo(
            id: "rooms@example.com",
            summary: "Google Room Fallback Fixture",
            backgroundColor: "#4285F4",
            accessRole: "writer",
            isPrimary: false,
            defaultReminderOffsets: []
        )
        let events: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-room-email-fallback-1",
            "etag": "\\"room-email-fallback-etag\\"",
            "status": "confirmed",
            "summary": "Google room email fallback fixture",
            "iCalUID": "google-room-email-fallback@example.com",
            "updated": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-07-01T14:00:00+03:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-01T14:30:00+03:00", "timeZone": "Asia/Nicosia" },
            "attendees": [
              { "email": "cy-office-pod@resource.calendar.google.com", "displayName": "CY Office Pod", "responseStatus": "accepted" },
              { "email": "teammate@example.com", "displayName": "Teammate", "responseStatus": "accepted" }
            ]
          }
        ]
        """)

        let text = try GoogleCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Google resource email fallback bridge")
        try expect(event.attendees.contains { $0.email == "cy-office-pod@resource.calendar.google.com" && $0.isRoomLike },
                   "Google resource calendar email should import as a room/resource even without an explicit resource flag")
        let calendarEvent = calendarEvent(from: event)
        try expect(calendarEvent.bestLocation == "CY Office Pod",
                   "Google resource calendar email should be available as the physical display location")
        let roomRule = RulePredicate(field: .roomEmail, comparison: .contains, value: "resource.calendar.google.com")
        try expect(roomRule.matches(calendarEvent),
                   "Rules should match resource calendar attendees through room/resource fields")
    }

    private static func verifyGoogleWorkingLocationBridge() throws {
        let account = providerAccount(kind: .googleCalendar, endpointURLString: "https://www.googleapis.com/calendar/v3")
        let calendar = GoogleCalendarInfo(
            id: "primary@example.com",
            summary: "Google Working Location Fixture",
            backgroundColor: "#4285F4",
            accessRole: "reader",
            isPrimary: true,
            defaultReminderOffsets: []
        )
        let events: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-working-location-office-1",
            "etag": "\\"working-location-office-etag\\"",
            "status": "confirmed",
            "summary": "Working from office",
            "iCalUID": "google-working-location-office@example.com",
            "eventType": "workingLocation",
            "updated": "2026-06-25T08:00:00Z",
            "start": { "date": "2026-07-01" },
            "end": { "date": "2026-07-02" },
            "workingLocationProperties": {
              "type": "officeLocation",
              "officeLocation": {
                "buildingId": "CY",
                "floorId": "1",
                "deskId": "D-14",
                "label": "CY Office"
              }
            }
          },
          {
            "id": "google-working-location-custom-1",
            "etag": "\\"working-location-custom-etag\\"",
            "status": "confirmed",
            "summary": "Working from customer site",
            "iCalUID": "google-working-location-custom@example.com",
            "eventType": "workingLocation",
            "updated": "2026-06-25T08:00:00Z",
            "start": { "date": "2026-07-02" },
            "end": { "date": "2026-07-03" },
            "workingLocationProperties": {
              "type": "customLocation",
              "customLocation": { "label": "Customer HQ" }
            }
          },
          {
            "id": "google-working-location-home-1",
            "etag": "\\"working-location-home-etag\\"",
            "status": "confirmed",
            "summary": "Working from home",
            "iCalUID": "google-working-location-home@example.com",
            "eventType": "workingLocation",
            "updated": "2026-06-25T08:00:00Z",
            "start": { "date": "2026-07-03" },
            "end": { "date": "2026-07-04" },
            "workingLocationProperties": {
              "type": "homeOffice",
              "homeOffice": {}
            }
          }
        ]
        """)

        let text = try GoogleCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("LOCATION:CY Office"), "Google working-location office label should become the event location")
        try expect(text.contains("LOCATION:Customer HQ"), "Google working-location custom label should become the event location")
        try expect(text.contains("LOCATION:Home office"), "Google working-location home office should become the event location")

        let imported = try LocalCalendarICSCodec.import(text)
        let byTitle = Dictionary(uniqueKeysWithValues: imported.events.map { ($0.title, $0) })
        guard let officeEvent = byTitle["Working from office"],
              let customEvent = byTitle["Working from customer site"],
              let homeEvent = byTitle["Working from home"] else {
            throw ProviderICSBridgeInvariantError("Google working location bridge should import all fixture events")
        }
        try expect(officeEvent.location == "CY Office", "Google office working location should import as local location")
        try expect(customEvent.location == "Customer HQ", "Google custom working location should import as local location")
        try expect(homeEvent.location == "Home office", "Google home working location should import as local location")
        try expect(officeEvent.categories.contains("Google event type workingLocation"),
                   "Google working-location event type metadata should survive local import")
        let locationRule = RulePredicate(field: .location, comparison: .contains, value: "CY Office")
        try expect(locationRule.matches(calendarEvent(from: officeEvent)),
                   "Rules should match Google working-location labels through the location field")
    }

    private static func verifyGoogleNonVideoConferenceEntryPointBridge() throws {
        let account = providerAccount(kind: .googleCalendar, endpointURLString: "https://www.googleapis.com/calendar/v3")
        let calendar = GoogleCalendarInfo(
            id: "primary@example.com",
            summary: "Google Conference Fixture",
            backgroundColor: "#4285F4",
            accessRole: "owner",
            isPrimary: true,
            defaultReminderOffsets: []
        )
        let events: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-conference-more-1",
            "etag": "\\"conference-more-etag\\"",
            "status": "confirmed",
            "summary": "Google non-video conference fixture",
            "iCalUID": "google-conference-more@example.com",
            "htmlLink": "https://calendar.google.com/event?eid=conference-more",
            "updated": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-07-02T12:00:00+03:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-02T12:30:00+03:00", "timeZone": "Asia/Nicosia" },
            "conferenceData": {
              "entryPoints": [
                { "entryPointType": "more", "uri": "https://zoom.us/j/987654321?pwd=provider" }
              ]
            }
          }
        ]
        """)

        let text = try GoogleCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("URL:https://zoom.us/j/987654321?pwd=provider"),
                   "Google bridge should prefer a non-video provider conference URL over the generic event page")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Google non-video conference bridge")
        try expect(event.urlString == "https://zoom.us/j/987654321?pwd=provider",
                   "Google non-video conference bridge should import the provider join URL")
        try expect(URL(string: event.urlString).flatMap(MeetingPlatform.init(url:)) == .zoom,
                   "Google non-video conference bridge should resolve the provider join URL platform")
    }

    private static func verifyGoogleAttachmentMeetingLinkBridge() throws {
        let account = providerAccount(kind: .googleCalendar, endpointURLString: "https://www.googleapis.com/calendar/v3")
        let calendar = GoogleCalendarInfo(
            id: "primary@example.com",
            summary: "Google Attachment Fixture",
            backgroundColor: "#4285F4",
            accessRole: "owner",
            isPrimary: true,
            defaultReminderOffsets: []
        )
        let events: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-attachment-meeting-1",
            "etag": "\\"attachment-meeting-etag\\"",
            "status": "confirmed",
            "summary": "Google attachment meeting fixture",
            "iCalUID": "google-attachment-meeting@example.com",
            "htmlLink": "https://calendar.google.com/event?eid=attachment-meeting",
            "updated": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-07-02T13:00:00+03:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-02T13:30:00+03:00", "timeZone": "Asia/Nicosia" },
            "attachments": [
              { "fileUrl": "https://zoom.us/j/765432198?pwd=attached", "title": "Zoom bridge", "mimeType": "text/html" },
              { "fileUrl": "https://docs.example.com/briefing", "title": "Briefing", "mimeType": "text/html" }
            ]
          }
        ]
        """)

        let text = try GoogleCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("URL:https://zoom.us/j/765432198?pwd=attached"),
                   "Google bridge should use meeting URLs found in provider attachments")
        try expect(text.contains("ATTACH;VALUE=URI;FMTTYPE=text/html;X-FILENAME=\"Zoom bridge\":https://zoom.us/j/765432198?pwd=attached"),
                   "Google bridge should export attachment meeting links as ATTACH metadata")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Google attachment meeting bridge")
        try expect(event.urlString == "https://zoom.us/j/765432198?pwd=attached",
                   "Google attachment meeting bridge should import attachment meeting URL as the event URL")
        try expect(event.attachments == [
            LocalEventAttachment(
                urlString: "https://zoom.us/j/765432198?pwd=attached",
                formatType: "text/html",
                displayName: "Zoom bridge"
            ),
            LocalEventAttachment(
                urlString: "https://docs.example.com/briefing",
                formatType: "text/html",
                displayName: "Briefing"
            )
        ], "Google attachment meeting bridge should preserve all URI attachments")
    }

    private static func verifyGoogleSourceURLBridge() throws {
        let account = providerAccount(kind: .googleCalendar, endpointURLString: "https://www.googleapis.com/calendar/v3")
        let calendar = GoogleCalendarInfo(
            id: "primary@example.com",
            summary: "Google Source URL Fixture",
            backgroundColor: "#4285F4",
            accessRole: "owner",
            isPrimary: true,
            defaultReminderOffsets: []
        )
        let events: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-source-url-1",
            "etag": "\\"source-url-etag\\"",
            "status": "confirmed",
            "summary": "Google source URL fixture",
            "iCalUID": "google-source-url@example.com",
            "htmlLink": "https://calendar.google.com/event?eid=source-url",
            "source": {
              "title": "Working Calendar",
              "url": "https://meet.google.com/source-url"
            },
            "updated": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-07-03T12:00:00+03:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-03T12:30:00+03:00", "timeZone": "Asia/Nicosia" }
          }
        ]
        """)

        let text = try GoogleCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("URL:https://meet.google.com/source-url"),
                   "Google bridge should preserve source.url as the event join URL")
        try expect(!text.contains("URL:https://calendar.google.com/event?eid=source-url"),
                   "Google bridge should not fall back to generic htmlLink when source.url is available")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Google source URL bridge")
        try expect(event.urlString == "https://meet.google.com/source-url",
                   "Google source URL bridge should import source.url as the event URL")
        try expect(URL(string: event.urlString).flatMap(MeetingPlatform.init(url:)) == .googleMeet,
                   "Google source URL bridge should resolve source.url meeting platform")
    }

    private static func verifyGoogleDescriptionMeetingLinkFallbackBridge() throws {
        let account = providerAccount(kind: .googleCalendar, endpointURLString: "https://www.googleapis.com/calendar/v3")
        let calendar = GoogleCalendarInfo(
            id: "primary@example.com",
            summary: "Google Description Link Fixture",
            backgroundColor: "#4285F4",
            accessRole: "owner",
            isPrimary: true,
            defaultReminderOffsets: []
        )
        let events: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-description-zoom-link",
            "etag": "\\"description-zoom-etag\\"",
            "status": "confirmed",
            "summary": "Google description Zoom fixture",
            "description": "External vendor call\\nJoin Zoom: https://nexcess.zoom.us/j/246813579?pwd=google",
            "location": "CY-Office-1st-Conference",
            "iCalUID": "google-description-zoom@example.com",
            "htmlLink": "https://calendar.google.com/event?eid=description-zoom",
            "updated": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-07-03T14:00:00+03:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-03T14:30:00+03:00", "timeZone": "Asia/Nicosia" }
          },
          {
            "id": "google-description-briefing-link",
            "etag": "\\"description-briefing-etag\\"",
            "status": "confirmed",
            "summary": "Google description briefing fixture",
            "description": "Read first: https://example.com/briefing",
            "iCalUID": "google-description-briefing@example.com",
            "htmlLink": "https://calendar.google.com/event?eid=description-briefing",
            "updated": "2026-06-25T08:05:00Z",
            "start": { "dateTime": "2026-07-03T15:00:00+03:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-03T15:30:00+03:00", "timeZone": "Asia/Nicosia" }
          }
        ]
        """)

        let text = try GoogleCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("URL:https://nexcess.zoom.us/j/246813579?pwd=google"),
                   "Google bridge should use preferred meeting links found in the event description")
        try expect(text.contains("URL:https://calendar.google.com/event?eid=description-briefing"),
                   "Google bridge should keep htmlLink when the description only has a non-meeting URL")

        let imported = try LocalCalendarICSCodec.import(text)
        let byTitle = Dictionary(uniqueKeysWithValues: imported.events.map { ($0.title, $0) })
        guard let zoomEvent = byTitle["Google description Zoom fixture"],
              let briefingEvent = byTitle["Google description briefing fixture"] else {
            throw ProviderICSBridgeInvariantError("Google description link bridge should import both fixture events")
        }

        try expect(zoomEvent.urlString == "https://nexcess.zoom.us/j/246813579?pwd=google",
                   "Google description Zoom fixture should import the actual join URL")
        try expect(URL(string: zoomEvent.urlString).flatMap(MeetingPlatform.init(url:)) == .zoom,
                   "Google description Zoom fixture should resolve the provider join URL platform")
        try expect(zoomEvent.notes.localizedCaseInsensitiveContains("Join Zoom"),
                   "Google description Zoom fixture should preserve description text in notes")
        try expect(briefingEvent.urlString == "https://calendar.google.com/event?eid=description-briefing",
                   "Google non-meeting description link should not replace the provider htmlLink")
        try expect(briefingEvent.notes.localizedCaseInsensitiveContains("https://example.com/briefing"),
                   "Google non-meeting description link should still be visible in notes")
    }

    private static func verifyGoogleReadOnlyCalendarBridge() throws {
        let account = providerAccount(kind: .googleCalendar, endpointURLString: "https://www.googleapis.com/calendar/v3")
        let calendar = GoogleCalendarInfo(
            id: "readonly@example.com",
            summary: "Google Read-only Fixture",
            backgroundColor: "#AECBFA",
            accessRole: "reader",
            isPrimary: false,
            defaultReminderOffsets: []
        )
        let events: [GoogleCalendarEvent] = try decodeJSON("""
        [
          {
            "id": "google-readonly-1",
            "etag": "\\"readonly-etag\\"",
            "status": "confirmed",
            "summary": "Google read-only fixture",
            "iCalUID": "google-readonly@example.com",
            "updated": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-07-01T09:00:00Z" },
            "end": { "dateTime": "2026-07-01T09:30:00Z" }
          }
        ]
        """)

        let text = try GoogleCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("X-WORKING-CALENDAR-ALLOWS-EVENT-WRITE:FALSE"),
                   "Google read-only calendars should be marked as not writable")
        try expect(text.contains("X-WORKING-CALENDAR-ALLOWS-RESPONSES:FALSE"),
                   "Google read-only calendars should be marked as not response-capable")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Google read-only bridge")
        let calendarInfo = try requireOnlyCalendar(imported.calendars, context: "Google read-only bridge")
        try expect(calendarInfo.allowsEventWrite == false, "Google read-only calendar should import as read-only")
        try expect(calendarInfo.allowsResponses == false, "Google read-only calendar should not allow responses")
        try expect(event.remoteETag == "\"readonly-etag\"", "Google read-only bridge should preserve remote ETag")
    }

    @MainActor
    private static func verifyMicrosoftCancelledOccurrenceBridge() throws {
        let account = providerAccount(kind: .microsoft365, endpointURLString: "https://graph.microsoft.com/v1.0")
        let calendar = MicrosoftGraphCalendarInfo(
            id: "graph-calendar-1",
            name: "Graph Fixture",
            colorHex: "#2563EB",
            canEdit: true
        )
        let events: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-master-1",
            "subject": "Graph recurring fixture",
            "isCancelled": false,
            "isAllDay": false,
            "iCalUId": "graph-series@example.com",
            "type": "seriesMaster",
            "lastModifiedDateTime": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-06-25T09:00:00", "timeZone": "UTC" },
            "end": { "dateTime": "2026-06-25T09:30:00", "timeZone": "UTC" },
            "recurrence": {
              "pattern": {
                "type": "weekly",
                "interval": 1,
                "daysOfWeek": ["thursday"],
                "firstDayOfWeek": "sunday"
              },
              "range": {
                "type": "numbered",
                "startDate": "2026-06-25",
                "numberOfOccurrences": 3
              }
            },
            "cancelledOccurrences": ["graph-master-1.2026-07-02"]
          },
          {
            "id": "graph-master-1-20260709-exception",
            "subject": "Graph moved occurrence",
            "isCancelled": false,
            "isAllDay": false,
            "iCalUId": "graph-series@example.com",
            "type": "exception",
            "seriesMasterId": "graph-master-1",
            "originalStart": "2026-07-09T09:00:00Z",
            "occurrenceId": "graph-master-1.2026-07-09",
            "lastModifiedDateTime": "2026-06-25T08:15:00Z",
            "start": { "dateTime": "2026-07-09T10:00:00", "timeZone": "UTC" },
            "end": { "dateTime": "2026-07-09T10:30:00", "timeZone": "UTC" }
          }
        ]
        """)

        let client = MicrosoftGraphCalendarClient()
        let text = try client.annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("EXDATE:20260702T090000Z"), "Microsoft cancelled occurrence should become EXDATE")
        try expect(text.contains("RECURRENCE-ID:20260709T090000Z"),
                   "Microsoft moved occurrence should become a detached occurrence")
        try expect(text.contains("COUNT=3"), "Microsoft numbered recurrence should become a finite RRULE COUNT")
        try expect(text.contains("WKST=SU"), "Microsoft weekly recurrence should preserve firstDayOfWeek as WKST")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Microsoft bridge")
        try expect(event.recurrenceWeekStart == 1, "Microsoft WKST should import as the weekly recurrence week start")
        try expect(event.excludedOccurrenceStartDates.contains { sameInstant($0, "2026-07-02T09:00:00Z") },
                   "Microsoft EXDATE should import as an excluded occurrence")
        let detached = try requireOnlyDetachedOccurrence(
            event.detachedOccurrences,
            context: "Microsoft detached occurrence"
        )
        try expect(sameInstant(detached.originalStartDate, "2026-07-09T09:00:00Z"),
                   "Microsoft detached occurrence should keep its original recurrence start")
        try expect(sameInstant(detached.startDate, "2026-07-09T10:00:00Z"),
                   "Microsoft detached occurrence should keep the moved start")
        try expect(detached.title == "Graph moved occurrence", "Microsoft detached occurrence should preserve exception details")
        let keepRemoteObjectURLs = client.remoteObjectURLStringsForImportedEvents(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(keepRemoteObjectURLs.contains(client.remoteObjectURLString(event: events[0], calendar: calendar, account: account)),
                   "Microsoft full refresh keep-set should include the series master URL")
        try expect(keepRemoteObjectURLs.contains(client.remoteObjectURLString(event: events[1], calendar: calendar, account: account)),
                   "Microsoft full refresh keep-set should include moved exception URLs")
        try verifyFullRefreshPruneKeepsDetachedOccurrence(
            text: text,
            calendarIDPrefix: client.localCalendarID(for: account, graphCalendarID: calendar.id),
            keepingRemoteObjectURLs: keepRemoteObjectURLs,
            rangeStart: "2026-06-25T00:00:00Z",
            rangeEnd: "2026-07-30T00:00:00Z",
            context: "Microsoft full-refresh exception keep-set"
        )

        let expanded = try expandedEvents(
            from: text,
            start: "2026-06-25T00:00:00Z",
            end: "2026-07-30T00:00:00Z"
        )
        let graphSeriesOccurrences = expanded.filter { $0.externalIdentifier == event.externalUID }
        try expect(graphSeriesOccurrences.count == 2,
                   "Microsoft numbered recurrence should expand only the counted occurrences after EXDATE, got \(graphSeriesOccurrences.map { isoString($0.startDate) })")
        try expect(graphSeriesOccurrences.contains { sameInstant($0.startDate, "2026-06-25T09:00:00Z") },
                   "Microsoft numbered recurrence should include the first occurrence")
        try expect(graphSeriesOccurrences.contains { sameInstant($0.startDate, "2026-07-09T10:00:00Z") },
                   "Microsoft numbered recurrence should include the moved detached third occurrence")
        try expect(!graphSeriesOccurrences.contains { sameInstant($0.startDate, "2026-07-09T09:00:00Z") },
                   "Microsoft numbered recurrence should not keep the original start for a moved detached occurrence")
        try expect(!graphSeriesOccurrences.contains { sameInstant($0.startDate, "2026-07-16T09:00:00Z") },
                   "Microsoft numbered recurrence should not continue past COUNT=3")
    }

    @MainActor
    private static func verifyMicrosoftNestedExceptionKeepSetBridge() throws {
        let account = providerAccount(kind: .microsoft365, endpointURLString: "https://graph.microsoft.com/v1.0")
        let calendar = MicrosoftGraphCalendarInfo(
            id: "graph-calendar-nested-exception",
            name: "Graph Nested Exception Fixture",
            colorHex: "#2563EB",
            canEdit: true
        )
        let rawEvents: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-nested-master",
            "subject": "Graph nested recurring fixture",
            "isCancelled": false,
            "isAllDay": false,
            "iCalUId": "graph-nested-series@example.com",
            "type": "seriesMaster",
            "lastModifiedDateTime": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-06-25T09:00:00", "timeZone": "UTC" },
            "end": { "dateTime": "2026-06-25T09:30:00", "timeZone": "UTC" },
            "recurrence": {
              "pattern": {
                "type": "weekly",
                "interval": 1,
                "daysOfWeek": ["thursday"],
                "firstDayOfWeek": "sunday"
              },
              "range": {
                "type": "numbered",
                "startDate": "2026-06-25",
                "numberOfOccurrences": 3
              }
            },
            "exceptionOccurrences": [
              {
                "id": "graph-nested-master-20260709-exception",
                "subject": "Graph nested moved occurrence",
                "isCancelled": false,
                "isAllDay": false,
                "iCalUId": "graph-nested-series@example.com",
                "type": "exception",
                "seriesMasterId": "graph-nested-master",
                "originalStart": "2026-07-09T09:00:00Z",
                "occurrenceId": "graph-nested-master.2026-07-09",
                "lastModifiedDateTime": "2026-06-25T08:15:00Z",
                "start": { "dateTime": "2026-07-09T10:00:00", "timeZone": "UTC" },
                "end": { "dateTime": "2026-07-09T10:30:00", "timeZone": "UTC" }
              }
            ]
          }
        ]
        """)

        let client = MicrosoftGraphCalendarClient()
        guard let rawMaster = rawEvents.first else {
            throw ProviderICSBridgeInvariantError("Microsoft nested exception fixture should decode one master event")
        }
        let detailedException: MicrosoftGraphEvent = try decodeJSON("""
        {
          "id": "graph-nested-master-20260709-exception",
          "subject": "Graph nested moved occurrence",
          "isCancelled": false,
          "isAllDay": false,
          "iCalUId": "graph-nested-series@example.com",
          "type": "exception",
          "seriesMasterId": "graph-nested-master",
          "originalStart": "2026-07-09T09:00:00Z",
          "occurrenceId": "graph-nested-master.2026-07-09",
          "lastModifiedDateTime": "2026-06-25T08:15:00Z",
          "start": { "dateTime": "2026-07-09T10:00:00", "timeZone": "UTC" },
          "end": { "dateTime": "2026-07-09T10:30:00", "timeZone": "UTC" },
          "attachments": [
            {
              "@odata.type": "#microsoft.graph.referenceAttachment",
              "id": "nested-exception-zoom",
              "name": "Moved occurrence Zoom",
              "contentType": "text/html",
              "isInline": false,
              "sourceUrl": "https://nexcess.zoom.us/j/567890123?pwd=nested"
            }
          ],
          "extensions": [
            {
              "@odata.type": "#microsoft.graph.openTypeExtension",
              "id": "Microsoft.OutlookServices.OpenTypeExtension.dev.codex.workingCalendar",
              "extensionName": "dev.codex.workingCalendar",
              "relatedEventsJSON": "[{\\"relationType\\":\\"PARENT\\",\\"externalUID\\":\\"parent-graph-nested-exception@example.com\\"}]",
              "geoCoordinateJSON": "{\\"latitude\\":35.1855659,\\"longitude\\":33.3822764}"
            }
          ]
        }
        """)
        let events = [
            client.seriesMasterExceptionMergePreview(
                master: rawMaster,
                detailedExceptions: [detailedException]
            )
        ]
        let text = try client.annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("RECURRENCE-ID:20260709T090000Z"),
                   "Microsoft nested exception should become a detached occurrence")
        try expect(text.contains("URL:https://nexcess.zoom.us/j/567890123?pwd=nested"),
                   "Microsoft nested exception detail fetch should preserve attachment meeting URLs")
        try expect(text.contains("ATTACH;VALUE=URI;FMTTYPE=text/html;X-FILENAME=\"Moved occurrence Zoom\":https://nexcess.zoom.us/j/567890123?pwd=nested"),
                   "Microsoft nested exception detail fetch should preserve reference attachments")
        try expect(text.contains("RELATED-TO;RELTYPE=PARENT:parent-graph-nested-exception@example.com"),
                   "Microsoft nested exception detail fetch should preserve open extension relationships")
        try expect(text.contains("GEO:35.1855659;33.3822764"),
                   "Microsoft nested exception detail fetch should preserve open extension GEO metadata")
        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Microsoft nested exception bridge")
        let detached = try requireOnlyDetachedOccurrence(
            event.detachedOccurrences,
            context: "Microsoft nested detached occurrence"
        )
        try expect(detached.title == "Graph nested moved occurrence",
                   "Microsoft nested exception should preserve exception details")
        try expect(detached.urlString == "https://nexcess.zoom.us/j/567890123?pwd=nested",
                   "Microsoft nested detached occurrence should import attachment meeting URL")
        try expect(detached.attachments == [
            LocalEventAttachment(
                urlString: "https://nexcess.zoom.us/j/567890123?pwd=nested",
                formatType: "text/html",
                displayName: "Moved occurrence Zoom"
            )
        ], "Microsoft nested detached occurrence should import detailed reference attachments")
        try expect(detached.relatedEvents == [
            LocalEventRelationship(relationType: "PARENT", externalUID: "parent-graph-nested-exception@example.com")
        ], "Microsoft nested detached occurrence should import detailed open extension relationships")
        try expect(detached.geoCoordinate == LocalEventGeoCoordinate(latitude: 35.1855659, longitude: 33.3822764),
                   "Microsoft nested detached occurrence should import detailed open extension GEO coordinates")

        guard let nestedException = events.first?.exceptionOccurrences?.first else {
            throw ProviderICSBridgeInvariantError("Microsoft nested exception fixture should decode one exception occurrence")
        }
        let keepRemoteObjectURLs = client.remoteObjectURLStringsForImportedEvents(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(keepRemoteObjectURLs.contains(client.remoteObjectURLString(event: nestedException, calendar: calendar, account: account)),
                   "Microsoft full refresh keep-set should include nested exception occurrence URLs")
        try verifyFullRefreshPruneKeepsDetachedOccurrence(
            text: text,
            calendarIDPrefix: client.localCalendarID(for: account, graphCalendarID: calendar.id),
            keepingRemoteObjectURLs: keepRemoteObjectURLs,
            rangeStart: "2026-06-25T00:00:00Z",
            rangeEnd: "2026-07-30T00:00:00Z",
            context: "Microsoft nested exception full-refresh keep-set"
        )
    }

    @MainActor
    private static func verifyMicrosoftRemovedExceptionDeletesDetachedOverride() throws {
        let account = providerAccount(kind: .microsoft365, endpointURLString: "https://graph.microsoft.com/v1.0")
        let calendar = MicrosoftGraphCalendarInfo(
            id: "graph-calendar-removed-exception",
            name: "Graph Removed Exception Fixture",
            colorHex: "#2563EB",
            canEdit: true
        )
        let events: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-removed-master",
            "subject": "Graph removed exception fixture",
            "isCancelled": false,
            "isAllDay": false,
            "iCalUId": "graph-removed-series@example.com",
            "type": "seriesMaster",
            "lastModifiedDateTime": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-06-25T09:00:00", "timeZone": "UTC" },
            "end": { "dateTime": "2026-06-25T09:30:00", "timeZone": "UTC" },
            "recurrence": {
              "pattern": {
                "type": "weekly",
                "interval": 1,
                "daysOfWeek": ["thursday"],
                "firstDayOfWeek": "sunday"
              },
              "range": {
                "type": "numbered",
                "startDate": "2026-06-25",
                "numberOfOccurrences": 3
              }
            }
          },
          {
            "id": "graph-removed-master-20260709-exception",
            "subject": "Graph removed moved occurrence",
            "isCancelled": false,
            "isAllDay": false,
            "iCalUId": "graph-removed-series@example.com",
            "type": "exception",
            "seriesMasterId": "graph-removed-master",
            "originalStart": "2026-07-09T09:00:00Z",
            "occurrenceId": "graph-removed-master.2026-07-09",
            "lastModifiedDateTime": "2026-06-25T08:15:00Z",
            "start": { "dateTime": "2026-07-09T10:00:00", "timeZone": "UTC" },
            "end": { "dateTime": "2026-07-09T10:30:00", "timeZone": "UTC" }
          }
        ]
        """)
        let removedEvents: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-removed-master-20260709-exception",
            "seriesMasterId": "graph-removed-master",
            "@removed": { "reason": "deleted" }
          }
        ]
        """)

        let client = MicrosoftGraphCalendarClient()
        let text = try client.annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        let detachedRemoteObjectURL = client.remoteObjectURLString(event: events[1], calendar: calendar, account: account)
        let deletedRemoteObjectURLs = client.deletedRemoteObjectURLStringsForEvents(
            events: removedEvents,
            calendar: calendar,
            account: account
        )
        try expect(deletedRemoteObjectURLs == [detachedRemoteObjectURL],
                   "Microsoft Graph @removed exception should target the detached occurrence remote URL")

        resetLocalCalendarStorage()
        defer { resetLocalCalendarStorage() }
        let store = LocalCalendarStore()
        _ = try store.importICSText(text)
        var importedEvent = try requireOnlyEvent(store.events, context: "Microsoft removed exception import")
        try expect(importedEvent.detachedOccurrences.first?.remoteObjectURLString == detachedRemoteObjectURL,
                   "Microsoft detached occurrence should keep its own remote object URL before deletion")

        let removedCount = store.removeProviderEvents(remoteObjectURLs: deletedRemoteObjectURLs)
        try expect(removedCount == 1,
                   "Microsoft Graph @removed exception should remove one detached occurrence override")
        importedEvent = try requireOnlyEvent(store.events, context: "Microsoft removed exception after deletion")
        try expect(importedEvent.detachedOccurrences.isEmpty,
                   "Microsoft Graph @removed exception should remove the detached override but keep the series")

        let restoredOccurrences = store.events(
            from: date("2026-06-25T00:00:00Z"),
            to: date("2026-07-30T00:00:00Z"),
            includeAllDay: true
        )
        try expect(restoredOccurrences.contains { sameInstant($0.startDate, "2026-07-09T09:00:00Z") },
                   "Microsoft Graph @removed exception should restore the generated base occurrence")
        try expect(!restoredOccurrences.contains { sameInstant($0.startDate, "2026-07-09T10:00:00Z") },
                   "Microsoft Graph @removed exception should remove the moved occurrence")
    }

    @MainActor
    private static func verifyMicrosoftCancelledExceptionCancelsDetachedOverride() throws {
        let account = providerAccount(kind: .microsoft365, endpointURLString: "https://graph.microsoft.com/v1.0")
        let calendar = MicrosoftGraphCalendarInfo(
            id: "graph-calendar-cancelled-exception",
            name: "Graph Cancelled Exception Fixture",
            colorHex: "#2563EB",
            canEdit: true
        )
        let events: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-cancelled-master",
            "subject": "Graph cancelled exception fixture",
            "isCancelled": false,
            "isAllDay": false,
            "iCalUId": "graph-cancelled-series@example.com",
            "type": "seriesMaster",
            "lastModifiedDateTime": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-06-25T09:00:00", "timeZone": "UTC" },
            "end": { "dateTime": "2026-06-25T09:30:00", "timeZone": "UTC" },
            "recurrence": {
              "pattern": {
                "type": "weekly",
                "interval": 1,
                "daysOfWeek": ["thursday"],
                "firstDayOfWeek": "sunday"
              },
              "range": {
                "type": "numbered",
                "startDate": "2026-06-25",
                "numberOfOccurrences": 3
              }
            }
          },
          {
            "id": "graph-cancelled-master-20260709-exception",
            "subject": "Graph cancelled moved occurrence",
            "isCancelled": false,
            "isAllDay": false,
            "iCalUId": "graph-cancelled-series@example.com",
            "type": "exception",
            "seriesMasterId": "graph-cancelled-master",
            "originalStart": "2026-07-09T09:00:00Z",
            "occurrenceId": "graph-cancelled-master.2026-07-09",
            "lastModifiedDateTime": "2026-06-25T08:15:00Z",
            "start": { "dateTime": "2026-07-09T10:00:00", "timeZone": "UTC" },
            "end": { "dateTime": "2026-07-09T10:30:00", "timeZone": "UTC" }
          }
        ]
        """)
        let cancelledEvents: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-cancelled-master-20260709-exception",
            "seriesMasterId": "graph-cancelled-master",
            "isCancelled": true
          }
        ]
        """)

        let client = MicrosoftGraphCalendarClient()
        let text = try client.annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        let detachedRemoteObjectURL = client.remoteObjectURLString(event: events[1], calendar: calendar, account: account)
        let cancelledRemoteObjectURLs = client.cancelledDetachedOccurrenceRemoteObjectURLStringsForEvents(
            events: cancelledEvents,
            calendar: calendar,
            account: account
        )
        try expect(cancelledRemoteObjectURLs == [detachedRemoteObjectURL],
                   "Microsoft Graph cancelled exception should target the detached occurrence remote URL")
        try expect(client.deletedRemoteObjectURLStringsForEvents(events: cancelledEvents, calendar: calendar, account: account).isEmpty,
                   "Microsoft Graph cancelled exception should not be treated as a deleted override")

        resetLocalCalendarStorage()
        defer { resetLocalCalendarStorage() }
        let store = LocalCalendarStore()
        _ = try store.importICSText(text)
        var importedEvent = try requireOnlyEvent(store.events, context: "Microsoft cancelled exception import")
        try expect(importedEvent.detachedOccurrences.first?.remoteObjectURLString == detachedRemoteObjectURL,
                   "Microsoft detached occurrence should keep its own remote object URL before cancellation")

        let cancelledCount = store.cancelProviderDetachedOccurrences(remoteObjectURLs: cancelledRemoteObjectURLs)
        try expect(cancelledCount == 1,
                   "Microsoft Graph cancelled exception should cancel one detached occurrence override")
        importedEvent = try requireOnlyEvent(store.events, context: "Microsoft cancelled exception after cancellation")
        try expect(importedEvent.detachedOccurrences.isEmpty,
                   "Microsoft Graph cancelled exception should remove the detached override")
        try expect(importedEvent.excludedOccurrenceStartDates.contains { sameInstant($0, "2026-07-09T09:00:00Z") },
                   "Microsoft Graph cancelled exception should add an EXDATE-equivalent exclusion")

        let occurrences = store.events(
            from: date("2026-06-25T00:00:00Z"),
            to: date("2026-07-30T00:00:00Z"),
            includeAllDay: true
        )
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-06-25T09:00:00Z") },
                   "Microsoft Graph cancelled exception should keep earlier generated occurrences")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-07-02T09:00:00Z") },
                   "Microsoft Graph cancelled exception should keep unaffected generated occurrences")
        try expect(!occurrences.contains { sameInstant($0.startDate, "2026-07-09T09:00:00Z") },
                   "Microsoft Graph cancelled exception should not restore the base occurrence")
        try expect(!occurrences.contains { sameInstant($0.startDate, "2026-07-09T10:00:00Z") },
                   "Microsoft Graph cancelled exception should remove the moved occurrence")
    }

    @MainActor
    private static func verifyMicrosoftCancelledGeneratedOccurrenceCancelsByMasterRemoteURL() throws {
        let account = providerAccount(kind: .microsoft365, endpointURLString: "https://graph.microsoft.com/v1.0")
        let calendar = MicrosoftGraphCalendarInfo(
            id: "graph-calendar-cancelled-generated",
            name: "Graph Cancelled Generated Fixture",
            colorHex: "#2563EB",
            canEdit: true
        )
        let events: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-cancelled-generated-master",
            "subject": "Graph cancelled generated fixture",
            "isCancelled": false,
            "isAllDay": false,
            "iCalUId": "graph-cancelled-generated-series@example.com",
            "type": "seriesMaster",
            "lastModifiedDateTime": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-06-25T09:00:00", "timeZone": "UTC" },
            "end": { "dateTime": "2026-06-25T09:30:00", "timeZone": "UTC" },
            "recurrence": {
              "pattern": {
                "type": "weekly",
                "interval": 1,
                "daysOfWeek": ["thursday"],
                "firstDayOfWeek": "sunday"
              },
              "range": {
                "type": "numbered",
                "startDate": "2026-06-25",
                "numberOfOccurrences": 3
              }
            }
          }
        ]
        """)
        let cancelledEvents: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-cancelled-generated-master-20260702",
            "seriesMasterId": "graph-cancelled-generated-master",
            "isCancelled": true,
            "originalStart": "2026-07-02T09:00:00Z"
          }
        ]
        """)

        let client = MicrosoftGraphCalendarClient()
        let text = try client.annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        let masterRemoteObjectURL = client.remoteObjectURLString(event: events[0], calendar: calendar, account: account)
        let cancellations = client.cancelledRemoteOccurrencesForEvents(
            events: cancelledEvents,
            calendar: calendar,
            account: account
        )
        try expect(cancellations == Set([
            LocalProviderRemoteOccurrenceCancellation(
                masterRemoteObjectURLString: masterRemoteObjectURL,
                occurrenceStartDate: date("2026-07-02T09:00:00Z")
            )
        ]), "Microsoft Graph cancelled generated occurrence should target the master remote URL and original start")

        resetLocalCalendarStorage()
        defer { resetLocalCalendarStorage() }
        let store = LocalCalendarStore()
        _ = try store.importICSText(text)
        var importedEvent = try requireOnlyEvent(store.events, context: "Microsoft cancelled generated import")
        try expect(importedEvent.detachedOccurrences.isEmpty,
                   "Microsoft generated occurrence fixture should start without detached overrides")

        let cancelledCount = store.cancelProviderRemoteOccurrences(cancellations)
        try expect(cancelledCount == 1,
                   "Microsoft Graph cancelled generated occurrence should update the recurring series")
        importedEvent = try requireOnlyEvent(store.events, context: "Microsoft cancelled generated after cancellation")
        try expect(importedEvent.excludedOccurrenceStartDates.contains { sameInstant($0, "2026-07-02T09:00:00Z") },
                   "Microsoft Graph cancelled generated occurrence should add an EXDATE-equivalent exclusion")

        let occurrences = store.events(
            from: date("2026-06-25T00:00:00Z"),
            to: date("2026-07-30T00:00:00Z"),
            includeAllDay: true
        )
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-06-25T09:00:00Z") },
                   "Microsoft Graph cancelled generated occurrence should keep the first occurrence")
        try expect(!occurrences.contains { sameInstant($0.startDate, "2026-07-02T09:00:00Z") },
                   "Microsoft Graph cancelled generated occurrence should hide the cancelled generated occurrence")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-07-09T09:00:00Z") },
                   "Microsoft Graph cancelled generated occurrence should keep later generated occurrences")
    }

    @MainActor
    private static func verifyMicrosoftAllDayCancelledGeneratedOccurrenceCancelsByMasterRemoteURL() throws {
        let account = providerAccount(kind: .microsoft365, endpointURLString: "https://graph.microsoft.com/v1.0")
        let calendar = MicrosoftGraphCalendarInfo(
            id: "graph-calendar-cancelled-generated-all-day",
            name: "Graph Cancelled Generated All-day Fixture",
            colorHex: "#2563EB",
            canEdit: true
        )
        let events: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-cancelled-generated-all-day-master",
            "subject": "Graph cancelled generated all-day fixture",
            "isCancelled": false,
            "isAllDay": true,
            "iCalUId": "graph-cancelled-generated-all-day-series@example.com",
            "type": "seriesMaster",
            "lastModifiedDateTime": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-07-01T00:00:00", "timeZone": "New Zealand Standard Time" },
            "end": { "dateTime": "2026-07-02T00:00:00", "timeZone": "New Zealand Standard Time" },
            "recurrence": {
              "pattern": {
                "type": "weekly",
                "interval": 1,
                "daysOfWeek": ["wednesday"],
                "firstDayOfWeek": "monday"
              },
              "range": {
                "type": "numbered",
                "startDate": "2026-07-01",
                "numberOfOccurrences": 3
              }
            }
          }
        ]
        """)
        let cancelledEvents: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-cancelled-generated-all-day-master-20260708",
            "seriesMasterId": "graph-cancelled-generated-all-day-master",
            "isCancelled": true,
            "isAllDay": true,
            "originalStart": "2026-07-08T00:00:00.0000000"
          }
        ]
        """)

        let client = MicrosoftGraphCalendarClient()
        let text = try client.annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        let masterRemoteObjectURL = client.remoteObjectURLString(event: events[0], calendar: calendar, account: account)
        let cancellations = client.cancelledRemoteOccurrencesForEvents(
            events: cancelledEvents,
            calendar: calendar,
            account: account
        )
        guard cancellations.count == 1, let cancellation = cancellations.first else {
            throw ProviderICSBridgeInvariantError("Microsoft Graph cancelled generated all-day occurrence should produce one cancellation")
        }
        try expect(cancellation.masterRemoteObjectURLString == masterRemoteObjectURL,
                   "Microsoft Graph cancelled generated all-day occurrence should target the master remote URL")
        try expect(sameLocalDay(cancellation.occurrenceStartDate, "2026-07-08"),
                   "Microsoft Graph cancelled generated all-day occurrence should target the original all-day date")

        resetLocalCalendarStorage()
        defer { resetLocalCalendarStorage() }
        let store = LocalCalendarStore()
        _ = try store.importICSText(text)
        var importedEvent = try requireOnlyEvent(store.events, context: "Microsoft cancelled generated all-day import")
        try expect(importedEvent.isAllDay, "Microsoft all-day generated fixture should import as all-day")
        try expect(importedEvent.detachedOccurrences.isEmpty,
                   "Microsoft all-day generated occurrence fixture should start without detached overrides")

        let cancelledCount = store.cancelProviderRemoteOccurrences(cancellations)
        try expect(cancelledCount == 1,
                   "Microsoft Graph cancelled generated all-day occurrence should update the recurring series")
        importedEvent = try requireOnlyEvent(store.events, context: "Microsoft cancelled generated all-day after cancellation")
        try expect(importedEvent.excludedOccurrenceStartDates.contains { sameLocalDay($0, "2026-07-08") },
                   "Microsoft Graph cancelled generated all-day occurrence should add a date-only EXDATE-equivalent exclusion")

        let occurrences = store.events(
            from: date("2026-07-01T00:00:00Z"),
            to: date("2026-07-25T00:00:00Z"),
            includeAllDay: true
        )
        try expect(occurrences.contains { sameLocalDay($0.startDate, "2026-07-01") },
                   "Microsoft Graph cancelled generated all-day occurrence should keep the first occurrence")
        try expect(!occurrences.contains { sameLocalDay($0.startDate, "2026-07-08") },
                   "Microsoft Graph cancelled generated all-day occurrence should hide the cancelled occurrence")
        try expect(occurrences.contains { sameLocalDay($0.startDate, "2026-07-15") },
                   "Microsoft Graph cancelled generated all-day occurrence should keep later generated occurrences")
    }

    @MainActor
    private static func verifyMicrosoftOccurrenceIDBridgeAcrossDST() throws {
        let account = providerAccount(kind: .microsoft365, endpointURLString: "https://graph.microsoft.com/v1.0")
        let calendar = MicrosoftGraphCalendarInfo(
            id: "graph-calendar-dst",
            name: "Graph DST Fixture",
            colorHex: "#2563EB",
            canEdit: true
        )
        let events: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-dst-master",
            "subject": "Graph DST recurring fixture",
            "isCancelled": false,
            "isAllDay": false,
            "iCalUId": "graph-dst-series@example.com",
            "type": "seriesMaster",
            "lastModifiedDateTime": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-01-01T12:00:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-01-01T12:30:00", "timeZone": "Asia/Nicosia" },
            "recurrence": {
              "pattern": {
                "type": "weekly",
                "interval": 1,
                "daysOfWeek": ["thursday"],
                "firstDayOfWeek": "monday"
              },
              "range": {
                "type": "endDate",
                "startDate": "2026-01-01",
                "endDate": "2026-07-30"
              }
            },
            "cancelledOccurrences": ["graph-dst-master.2026-07-02"]
          },
          {
            "id": "graph-dst-master-20260709-exception",
            "subject": "Graph DST moved occurrence",
            "isCancelled": false,
            "isAllDay": false,
            "iCalUId": "graph-dst-series@example.com",
            "type": "exception",
            "seriesMasterId": "graph-dst-master",
            "occurrenceId": "graph-dst-master.2026-07-09",
            "lastModifiedDateTime": "2026-06-25T08:15:00Z",
            "start": { "dateTime": "2026-07-09T13:00:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-09T13:30:00", "timeZone": "Asia/Nicosia" }
          }
        ]
        """)

        let text = try MicrosoftGraphCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("EXDATE:20260702T090000Z"),
                   "Microsoft DST cancelled occurrence should use the occurrence local time, not the master winter UTC hour")
        try expect(!text.contains("EXDATE:20260702T100000Z"),
                   "Microsoft DST cancelled occurrence should not use the master winter UTC hour")
        try expect(text.contains("RECURRENCE-ID:20260709T090000Z"),
                   "Microsoft DST moved occurrence should use the occurrence local time for RECURRENCE-ID")
        try expect(!text.contains("RECURRENCE-ID:20260709T100000Z"),
                   "Microsoft DST moved occurrence should not use the master winter UTC hour")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Microsoft DST bridge")
        try expect(event.excludedOccurrenceStartDates.contains { sameInstant($0, "2026-07-02T09:00:00Z") },
                   "Microsoft DST EXDATE should import as the correct local-time occurrence")
        let detached = try requireOnlyDetachedOccurrence(
            event.detachedOccurrences,
            context: "Microsoft DST detached occurrence"
        )
        try expect(sameInstant(detached.originalStartDate, "2026-07-09T09:00:00Z"),
                   "Microsoft DST detached occurrence should keep its original local-time recurrence start")
        try expect(sameInstant(detached.startDate, "2026-07-09T10:00:00Z"),
                   "Microsoft DST detached occurrence should keep the moved start")
    }

    private static func verifyMicrosoftMeetingMetadataBridge() throws {
        let account = providerAccount(
            kind: .microsoft365,
            endpointURLString: "https://graph.microsoft.com/v1.0",
            identityEmail: "me@example.com"
        )
        let calendar = MicrosoftGraphCalendarInfo(
            id: "graph-calendar-metadata",
            name: "Graph Metadata Fixture",
            colorHex: "#7C3AED",
            canEdit: true
        )
        let events: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-metadata-1",
            "changeKey": "metadata-change-key",
            "subject": "Graph metadata fixture",
            "body": { "contentType": "html", "content": "<p>Discuss Graph bridge metadata</p><p><a href=\\"https://example.com/briefing\\">Briefing</a></p>" },
            "isCancelled": false,
            "isAllDay": false,
            "showAs": "tentative",
            "sensitivity": "personal",
            "importance": "high",
            "categories": ["Customer", "Launch"],
            "hideAttendees": true,
            "isReminderOn": true,
            "reminderMinutesBeforeStart": 15,
            "iCalUId": "graph-metadata@example.com",
            "webLink": "https://outlook.office.com/calendar/item/metadata",
            "isOnlineMeeting": true,
            "onlineMeetingProvider": "teamsForBusiness",
            "onlineMeeting": { "joinUrl": "https://teams.microsoft.com/l/meetup-join/metadata" },
            "extensions": [
              {
                "@odata.type": "#microsoft.graph.openTypeExtension",
                "id": "Microsoft.OutlookServices.OpenTypeExtension.dev.codex.workingCalendar",
                "extensionName": "dev.codex.workingCalendar",
                "relatedEventsJSON": "[{\\"relationType\\":\\"PARENT\\",\\"externalUID\\":\\"parent-graph-metadata@example.com\\"},{\\"relationType\\":\\"SIBLING\\",\\"externalUID\\":\\"sibling-graph-metadata@example.com\\"}]",
                "geoCoordinateJSON": "{\\"latitude\\":35.1855659,\\"longitude\\":33.3822764}"
              }
            ],
            "location": {
              "displayName": "CY-Office-1st-Conference",
              "locationType": "conferenceRoom",
              "locationEmailAddress": "cy-office-1st-conference@example.com",
              "uniqueId": "room-cy-1",
              "uniqueIdType": "directory"
            },
            "locations": [
              {
                "displayName": "CY-Office-1st-Conference",
                "locationType": "conferenceRoom",
                "locationEmailAddress": "cy-office-1st-conference@example.com",
                "uniqueId": "room-cy-1",
                "uniqueIdType": "directory"
              },
              { "displayName": "Overflow Room" }
            ],
            "organizer": {
              "emailAddress": { "name": "Owner", "address": "owner@example.com" }
            },
            "attendees": [
              {
                "emailAddress": { "name": "Me", "address": "me@example.com" },
                "status": { "response": "tentativelyAccepted" },
                "type": "required"
              },
              {
                "emailAddress": { "name": "Teammate", "address": "teammate@example.com" },
                "status": { "response": "none" },
                "type": "optional"
              },
              {
                "emailAddress": { "name": "CY-Office-1st-Conference", "address": "cy-office-1st-conference@example.com" },
                "status": { "response": "accepted" },
                "type": "resource"
              }
            ],
            "responseStatus": { "response": "tentativelyAccepted" },
            "responseRequested": true,
            "allowNewTimeProposals": false,
            "createdDateTime": "2026-06-25T07:45:00Z",
            "lastModifiedDateTime": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-07-01T12:00:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-01T12:30:00", "timeZone": "Asia/Nicosia" }
          }
        ]
        """)

        let text = try MicrosoftGraphCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("X-WORKING-MY-RESPONSE:tentative"), "Microsoft bridge should preserve current user tentative response")
        try expect(text.contains("STATUS:TENTATIVE"), "Microsoft bridge should preserve tentative show-as status")
        try expect(text.contains("TRANSP:OPAQUE"), "Microsoft bridge should keep tentative events as busy time")
        try expect(text.contains("URL:https://teams.microsoft.com/l/meetup-join/metadata"), "Microsoft bridge should prefer the Teams join URL")
        try expect(text.contains("RELATED-TO;RELTYPE=PARENT:parent-graph-metadata@example.com"),
                   "Microsoft bridge should preserve open extension relationships as RELATED-TO")
        try expect(text.contains("GEO:35.1855659;33.3822764"),
                   "Microsoft bridge should preserve open extension GEO metadata")
        try expect(text.contains("CUTYPE=RESOURCE"), "Microsoft bridge should mark resource attendees")
        try expect(text.contains("RSVP=TRUE"), "Microsoft bridge should preserve responseRequested on attendee RSVP params")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Microsoft metadata bridge")
        try expect(event.remoteETag == "metadata-change-key", "Microsoft metadata bridge should import changeKey for safe write-back")
        try expect(event.myResponseStatus == .tentative, "Microsoft metadata bridge should import my tentative response")
        try expect(event.organizerEmail == "owner@example.com", "Microsoft metadata bridge should import organizer email")
        try expect(event.urlString == "https://teams.microsoft.com/l/meetup-join/metadata", "Microsoft metadata bridge should import the Teams URL")
        try expect(event.notes.localizedCaseInsensitiveContains("Discuss Graph bridge metadata"),
                   "Microsoft metadata bridge should import HTML body text")
        try expect(event.notes.localizedCaseInsensitiveContains("Briefing https://example.com/briefing"),
                   "Microsoft metadata bridge should preserve anchor URLs in body notes")
        try expect(!event.notes.contains("<p>") && !event.notes.contains("<a"),
                   "Microsoft metadata bridge should strip HTML tags from body notes")
        try expect(event.location == "CY-Office-1st-Conference; Overflow Room", "Microsoft metadata bridge should merge Graph locations")
        try expect(event.reminderOffsets == [15], "Microsoft metadata bridge should import reminder offsets")
        try expect(event.relatedEvents == [
            LocalEventRelationship(relationType: "PARENT", externalUID: "parent-graph-metadata@example.com"),
            LocalEventRelationship(relationType: "SIBLING", externalUID: "sibling-graph-metadata@example.com")
        ], "Microsoft metadata bridge should import open extension relationships as structured local relationships")
        try expect(event.geoCoordinate == LocalEventGeoCoordinate(latitude: 35.1855659, longitude: 33.3822764),
                   "Microsoft metadata bridge should import open extension GEO coordinates")
        try expect(event.categories == [
            "Customer",
            "Launch",
            "Microsoft sensitivity personal",
            "Microsoft onlineMeetingProvider teamsForBusiness",
            "Microsoft attendees hidden",
            "Microsoft new time proposals disabled",
            "Microsoft location 1 name CY-Office-1st-Conference",
            "Microsoft location 1 type conferenceRoom",
            "Microsoft location 1 email cy-office-1st-conference@example.com",
            "Microsoft location 1 unique id room-cy-1",
            "Microsoft location 1 unique id type directory"
        ], "Microsoft metadata bridge should import categories, personal sensitivity, online meeting provider metadata, hidden-attendee metadata, new-time-proposal metadata, and room identity metadata")
        try expect(event.privacy == .private, "Microsoft metadata bridge should import privacy")
        try expect(event.importance == .high, "Microsoft metadata bridge should import importance")
        try expect(event.status == .tentative, "Microsoft metadata bridge should import tentative show-as as tentative status")
        try expect(event.availability == .busy, "Microsoft tentative show-as should remain busy time")
        try expect(event.attendees.contains { $0.email == "me@example.com" && $0.isCurrentUser && $0.status == .tentative },
                   "Microsoft metadata bridge should mark the current user attendee")
        try expect(event.attendees.contains { $0.email == "teammate@example.com" && $0.role == "optional" && $0.status == .pending && $0.rsvp },
                   "Microsoft metadata bridge should preserve optional pending attendees that require a response")
        try expect(event.attendees.contains { $0.email == "cy-office-1st-conference@example.com" && $0.isRoomLike && !$0.rsvp },
                   "Microsoft metadata bridge should preserve room/resource attendees")
    }

    private static func verifyMicrosoftBodyMeetingLinkFallbackBridge() throws {
        let account = providerAccount(
            kind: .microsoft365,
            endpointURLString: "https://graph.microsoft.com/v1.0",
            identityEmail: "me@example.com"
        )
        let calendar = MicrosoftGraphCalendarInfo(
            id: "graph-calendar-body-link",
            name: "Graph Body Link Fixture",
            colorHex: "#2563EB",
            canEdit: true
        )
        let events: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-body-zoom-link",
            "changeKey": "body-zoom-change-key",
            "subject": "Graph body Zoom fixture",
            "body": {
              "contentType": "html",
              "content": "<p>External vendor call</p><p><a href=\\"https://nexcess.zoom.us/j/123456789?pwd=abc\\">Join Zoom</a></p>"
            },
            "isCancelled": false,
            "isAllDay": false,
            "showAs": "busy",
            "webLink": "https://outlook.office.com/calendar/item/body-zoom",
            "createdDateTime": "2026-06-25T08:20:00Z",
            "lastModifiedDateTime": "2026-06-25T08:21:00Z",
            "start": { "dateTime": "2026-07-02T12:00:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-02T12:30:00", "timeZone": "Asia/Nicosia" }
          },
          {
            "id": "graph-body-briefing-link",
            "changeKey": "body-briefing-change-key",
            "subject": "Graph body briefing fixture",
            "body": {
              "contentType": "html",
              "content": "<p>Read this first: <a href=\\"https://example.com/briefing\\">Briefing</a></p>"
            },
            "isCancelled": false,
            "isAllDay": false,
            "showAs": "busy",
            "webLink": "https://outlook.office.com/calendar/item/body-briefing",
            "createdDateTime": "2026-06-25T08:22:00Z",
            "lastModifiedDateTime": "2026-06-25T08:23:00Z",
            "start": { "dateTime": "2026-07-02T13:00:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-02T13:30:00", "timeZone": "Asia/Nicosia" }
          },
          {
            "id": "graph-body-safelink-zoom",
            "changeKey": "body-safelink-change-key",
            "subject": "Graph body Safe Link Zoom fixture",
            "body": {
              "contentType": "html",
              "content": "<p>External vendor call</p><p><a href=\\"https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fnexcess.zoom.us%2Fj%2F987654321%3Fpwd%3Dsafelink&amp;data=fixture\\">Join Zoom</a></p>"
            },
            "isCancelled": false,
            "isAllDay": false,
            "showAs": "busy",
            "webLink": "https://outlook.office.com/calendar/item/body-safelink",
            "createdDateTime": "2026-06-25T08:24:00Z",
            "lastModifiedDateTime": "2026-06-25T08:25:00Z",
            "start": { "dateTime": "2026-07-02T14:00:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-02T14:30:00", "timeZone": "Asia/Nicosia" }
          },
          {
            "id": "graph-body-legacy-skype-link",
            "changeKey": "body-legacy-skype-change-key",
            "subject": "Graph body legacy Skype fixture",
            "body": {
              "contentType": "html",
              "content": "<p>Legacy Microsoft meeting</p><p><a href=\\"https://join.skype.com/legacy-fixture\\">Join Skype Meeting</a></p>"
            },
            "isCancelled": false,
            "isAllDay": false,
            "showAs": "busy",
            "webLink": "https://outlook.office.com/calendar/item/body-legacy-skype",
            "createdDateTime": "2026-06-25T08:26:00Z",
            "lastModifiedDateTime": "2026-06-25T08:27:00Z",
            "start": { "dateTime": "2026-07-02T15:00:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-02T15:30:00", "timeZone": "Asia/Nicosia" }
          }
        ]
        """)

        let text = try MicrosoftGraphCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("URL:https://nexcess.zoom.us/j/123456789?pwd=abc"),
                   "Microsoft bridge should use preferred meeting links found in the HTML body")
        try expect(text.contains("URL:https://outlook.office.com/calendar/item/body-briefing"),
                   "Microsoft bridge should keep Outlook webLink when the body only has a non-meeting URL")
        try expect(text.contains("URL:https://nexcess.zoom.us/j/987654321?pwd=safelink"),
                   "Microsoft bridge should unwrap Outlook Safe Links before choosing the meeting URL")
        try expect(text.contains("URL:https://join.skype.com/legacy-fixture"),
                   "Microsoft bridge should prefer legacy Skype/Lync meeting links over Outlook webLink")
        try expect(!text.contains("URL:https://nam12.safelinks.protection.outlook.com"),
                   "Microsoft bridge should not store Outlook Safe Links as the event join URL")

        let imported = try LocalCalendarICSCodec.import(text)
        let byTitle = Dictionary(uniqueKeysWithValues: imported.events.map { ($0.title, $0) })
        guard let zoomEvent = byTitle["Graph body Zoom fixture"],
              let briefingEvent = byTitle["Graph body briefing fixture"],
              let safeLinkEvent = byTitle["Graph body Safe Link Zoom fixture"],
              let skypeEvent = byTitle["Graph body legacy Skype fixture"] else {
            throw ProviderICSBridgeInvariantError("Microsoft body link bridge should import all fixture events")
        }

        try expect(zoomEvent.urlString == "https://nexcess.zoom.us/j/123456789?pwd=abc",
                   "Microsoft body Zoom fixture should import the actual join URL")
        try expect(zoomEvent.notes.localizedCaseInsensitiveContains("Join Zoom https://nexcess.zoom.us/j/123456789?pwd=abc"),
                   "Microsoft body Zoom fixture should preserve the link in notes")
        try expect(briefingEvent.urlString == "https://outlook.office.com/calendar/item/body-briefing",
                   "Microsoft non-meeting body link should not replace the provider webLink")
        try expect(briefingEvent.notes.localizedCaseInsensitiveContains("Briefing https://example.com/briefing"),
                   "Microsoft non-meeting body link should still be visible in notes")
        try expect(safeLinkEvent.urlString == "https://nexcess.zoom.us/j/987654321?pwd=safelink",
                   "Microsoft Safe Link Zoom fixture should import the unwrapped join URL")
        try expect(URL(string: safeLinkEvent.urlString).flatMap(MeetingPlatform.init(url:)) == .zoom,
                   "Microsoft Safe Link Zoom fixture should resolve the unwrapped URL as Zoom")
        try expect(skypeEvent.urlString == "https://join.skype.com/legacy-fixture",
                   "Microsoft legacy Skype fixture should import the actual join URL")
        try expect(URL(string: skypeEvent.urlString).flatMap(MeetingPlatform.init(url:)) == .skypeForBusiness,
                   "Microsoft legacy Skype fixture should resolve the provider join URL platform")
    }

    private static func verifyMicrosoftAttachmentBridge() throws {
        let client = MicrosoftGraphCalendarClient()
        let detailQuery = try queryItemsDictionary(client.eventDetailsQueryItemsPreview())
        try expect(detailQuery["$expand"]?.contains("attachments($select=") == true,
                   "Microsoft detail fetch should expand event attachments for local import")
        try expect(detailQuery["$expand"]?.contains("sourceUrl") == true,
                   "Microsoft detail fetch should request reference attachment source URLs")
        try expect(detailQuery["$expand"]?.contains("extensions($filter=id eq 'dev.codex.workingCalendar')") == true,
                   "Microsoft detail fetch should expand Working Calendar open extension metadata")

        let account = providerAccount(
            kind: .microsoft365,
            endpointURLString: "https://graph.microsoft.com/v1.0",
            identityEmail: "me@example.com"
        )
        let calendar = MicrosoftGraphCalendarInfo(
            id: "graph-calendar-attachments",
            name: "Graph Attachments Fixture",
            colorHex: "#0EA5E9",
            canEdit: true
        )
        let events: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-attachment-meeting-1",
            "changeKey": "attachment-meeting-change-key",
            "subject": "Graph attachment meeting fixture",
            "body": { "contentType": "html", "content": "<p>Attachment-driven meeting</p>" },
            "isCancelled": false,
            "isAllDay": false,
            "showAs": "busy",
            "webLink": "https://outlook.office.com/calendar/item/attachment-meeting",
            "hasAttachments": true,
            "attachments": [
              {
                "@odata.type": "#microsoft.graph.referenceAttachment",
                "id": "reference-zoom",
                "name": "Zoom bridge",
                "contentType": "text/html",
                "isInline": false,
                "sourceUrl": "https://nexcess.zoom.us/j/234567890?pwd=attached"
              },
              {
                "@odata.type": "#microsoft.graph.referenceAttachment",
                "id": "reference-brief",
                "name": "Customer brief.pdf",
                "contentType": "application/pdf",
                "isInline": false,
                "sourceUrl": "https://contoso.sharepoint.com/sites/customer/Shared%20Documents/Customer%20brief.pdf"
              },
              {
                "@odata.type": "#microsoft.graph.fileAttachment",
                "id": "file-agenda",
                "name": "Binary agenda.pdf",
                "contentType": "application/pdf",
                "isInline": false,
                "size": 2048
              }
            ],
            "createdDateTime": "2026-06-25T09:00:00Z",
            "lastModifiedDateTime": "2026-06-25T09:05:00Z",
            "start": { "dateTime": "2026-07-03T12:00:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-03T12:30:00", "timeZone": "Asia/Nicosia" }
          }
        ]
        """)

        let text = try client.annotatedICSText(events: events, calendar: calendar, account: account)
        try expect(text.contains("URL:https://nexcess.zoom.us/j/234567890?pwd=attached"),
                   "Microsoft bridge should use meeting URLs found in reference attachments")
        try expect(text.contains("ATTACH;VALUE=URI;FMTTYPE=text/html;X-FILENAME=\"Zoom bridge\":https://nexcess.zoom.us/j/234567890?pwd=attached"),
                   "Microsoft bridge should preserve reference attachment meeting links as ATTACH metadata")
        try expect(text.contains("ATTACH;VALUE=URI;FMTTYPE=application/pdf;X-FILENAME=\"Customer brief.pdf\":https://contoso.sharepoint.com/sites/customer/Shared%20Documents/Customer%20brief.pdf"),
                   "Microsoft bridge should preserve reference attachments as URI ATTACH metadata")
        try expect(!text.contains("Binary agenda.pdf"),
                   "Microsoft bridge should not invent URI ATTACH metadata for binary file attachments without a source URL")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Microsoft attachment bridge")
        try expect(event.urlString == "https://nexcess.zoom.us/j/234567890?pwd=attached",
                   "Microsoft attachment bridge should import attachment meeting URL as the event URL")
        try expect(event.attachments == [
            LocalEventAttachment(
                urlString: "https://nexcess.zoom.us/j/234567890?pwd=attached",
                formatType: "text/html",
                displayName: "Zoom bridge"
            ),
            LocalEventAttachment(
                urlString: "https://contoso.sharepoint.com/sites/customer/Shared%20Documents/Customer%20brief.pdf",
                formatType: "application/pdf",
                displayName: "Customer brief.pdf"
            )
        ], "Microsoft attachment bridge should import reference attachments as structured local attachments")
    }

    @MainActor
    private static func verifyMicrosoftCurrentUserResponseFallbackBridge() throws {
        let account = providerAccount(
            kind: .microsoft365,
            endpointURLString: "https://graph.microsoft.com/v1.0",
            identityEmail: "me@example.com"
        )
        let calendar = MicrosoftGraphCalendarInfo(
            id: "graph-calendar-response-fallback",
            name: "Graph Response Fallback Fixture",
            colorHex: "#0EA5E9",
            canEdit: true
        )
        let events: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-response-organizer-none",
            "changeKey": "organizer-none-change-key",
            "subject": "Organizer response fallback fixture",
            "body": { "contentType": "text", "content": "Organizer should not need RSVP." },
            "isCancelled": false,
            "isAllDay": false,
            "showAs": "busy",
            "organizer": {
              "emailAddress": { "name": "Me", "address": "me@example.com" }
            },
            "responseStatus": { "response": "none" },
            "createdDateTime": "2026-06-25T08:05:00Z",
            "lastModifiedDateTime": "2026-06-25T08:06:00Z",
            "start": { "dateTime": "2026-07-02T09:00:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-02T09:30:00", "timeZone": "Asia/Nicosia" }
          },
          {
            "id": "graph-response-attendee-missing-top-level",
            "changeKey": "attendee-missing-top-level-change-key",
            "subject": "Attendee response fallback fixture",
            "body": { "contentType": "text", "content": "Attendee status should win when top-level response is missing." },
            "isCancelled": false,
            "isAllDay": false,
            "showAs": "busy",
            "organizer": {
              "emailAddress": { "name": "Owner", "address": "owner@example.com" }
            },
            "attendees": [
              {
                "emailAddress": { "name": "Me", "address": "me@example.com" },
                "status": { "response": "accepted" },
                "type": "required"
              }
            ],
            "createdDateTime": "2026-06-25T08:10:00Z",
            "lastModifiedDateTime": "2026-06-25T08:11:00Z",
            "start": { "dateTime": "2026-07-02T10:00:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-02T10:30:00", "timeZone": "Asia/Nicosia" }
          },
          {
            "id": "graph-response-not-responded",
            "changeKey": "not-responded-change-key",
            "subject": "Not responded fixture",
            "body": { "contentType": "text", "content": "NotResponded should still require attention." },
            "isCancelled": false,
            "isAllDay": false,
            "showAs": "busy",
            "organizer": {
              "emailAddress": { "name": "Owner", "address": "owner@example.com" }
            },
            "responseStatus": { "response": "notResponded" },
            "createdDateTime": "2026-06-25T08:15:00Z",
            "lastModifiedDateTime": "2026-06-25T08:16:00Z",
            "start": { "dateTime": "2026-07-02T11:00:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-02T11:30:00", "timeZone": "Asia/Nicosia" }
          },
          {
            "id": "graph-response-accepted-requested",
            "changeKey": "accepted-requested-change-key",
            "subject": "Accepted response requested fixture",
            "body": { "contentType": "text", "content": "Already accepted events may still carry responseRequested." },
            "isCancelled": false,
            "isAllDay": false,
            "showAs": "busy",
            "organizer": {
              "emailAddress": { "name": "Owner", "address": "owner@example.com" }
            },
            "attendees": [
              {
                "emailAddress": { "name": "Me", "address": "me@example.com" },
                "status": { "response": "accepted" },
                "type": "required"
              }
            ],
            "responseStatus": { "response": "accepted" },
            "responseRequested": true,
            "createdDateTime": "2026-06-25T08:25:00Z",
            "lastModifiedDateTime": "2026-06-25T08:26:00Z",
            "start": { "dateTime": "2026-07-02T12:00:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-02T12:30:00", "timeZone": "Asia/Nicosia" }
          }
        ]
        """)

        let text = try MicrosoftGraphCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.components(separatedBy: "X-WORKING-MY-RESPONSE:accepted").count - 1 == 3,
                   "Microsoft bridge should mark organizer/current-attendee fallback responses as accepted")
        try expect(text.contains("X-WORKING-MY-RESPONSE:pending"),
                   "Microsoft bridge should preserve notResponded as a pending RSVP")

        let projectedEvents = try expandedEvents(
            from: text,
            start: "2026-07-01T00:00:00Z",
            end: "2026-07-03T23:59:59Z"
        )
        let byTitle = Dictionary(uniqueKeysWithValues: projectedEvents.map { ($0.title, $0) })
        guard let organizerEvent = byTitle["Organizer response fallback fixture"],
              let attendeeEvent = byTitle["Attendee response fallback fixture"],
              let pendingEvent = byTitle["Not responded fixture"],
              let acceptedRequestedEvent = byTitle["Accepted response requested fixture"] else {
            throw ProviderICSBridgeInvariantError("Microsoft response fallback bridge should import all fixture events")
        }

        let didNotRespondRule = RulePredicate(field: .iDidNotRespond, comparison: .isEqualTo, value: "true")
        let acceptedRule = RulePredicate(field: .iAccepted, comparison: .isEqualTo, value: "true")
        try expect(organizerEvent.responseStatus == .accepted,
                   "Microsoft organizer-owned events should not become pending when Graph reports response none")
        try expect(attendeeEvent.responseStatus == .accepted,
                   "Microsoft current-attendee status should fill a missing top-level response")
        try expect(!organizerEvent.needsResponse && !attendeeEvent.needsResponse,
                   "Microsoft accepted fallback events should not require response")
        try expect(!didNotRespondRule.matches(organizerEvent) && !didNotRespondRule.matches(attendeeEvent),
                   "Microsoft accepted fallback events should not match did-not-respond rules")
        try expect(acceptedRule.matches(organizerEvent) && acceptedRule.matches(attendeeEvent),
                   "Microsoft accepted fallback events should match accepted rules")
        try expect(pendingEvent.responseStatus == .pending && pendingEvent.needsResponse,
                   "Microsoft notResponded events should still require response")
        try expect(didNotRespondRule.matches(pendingEvent),
                   "Microsoft notResponded events should match did-not-respond rules")
        try expect(acceptedRequestedEvent.responseStatus == .accepted && !acceptedRequestedEvent.needsResponse,
                   "Microsoft accepted events should stay accepted even when Graph responseRequested is true")
        try expect(!didNotRespondRule.matches(acceptedRequestedEvent) && acceptedRule.matches(acceptedRequestedEvent),
                   "Microsoft accepted responseRequested events should match accepted rules, not did-not-respond rules")
    }

    private static func verifyMicrosoftMailtoIdentityNormalizationBridge() throws {
        let account = providerAccount(
            kind: .microsoft365,
            endpointURLString: "https://graph.microsoft.com/v1.0",
            identityEmail: "mailto:ME%2Bcalendar%40example.com?subject=calendar"
        )
        let calendar = MicrosoftGraphCalendarInfo(
            id: "graph-calendar-mailto-identity",
            name: "Graph Mailto Identity Fixture",
            colorHex: "#0EA5E9",
            canEdit: true
        )
        let events: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-mailto-identity-1",
            "changeKey": "mailto-identity-change-key",
            "subject": "Graph mailto identity fixture",
            "body": { "contentType": "text", "content": "Identity matching should handle mailto values." },
            "isCancelled": false,
            "isAllDay": false,
            "showAs": "busy",
            "organizer": {
              "emailAddress": { "name": "Owner", "address": "owner@example.com" }
            },
            "attendees": [
              {
                "emailAddress": { "name": "Me", "address": "me+calendar@example.com" },
                "status": { "response": "accepted" },
                "type": "required"
              },
              {
                "emailAddress": { "name": "Teammate", "address": "teammate@example.com" },
                "status": { "response": "none" },
                "type": "required"
              }
            ],
            "createdDateTime": "2026-06-25T08:30:00Z",
            "lastModifiedDateTime": "2026-06-25T08:31:00Z",
            "start": { "dateTime": "2026-07-02T14:00:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-02T14:30:00", "timeZone": "Asia/Nicosia" }
          }
        ]
        """)

        let text = try MicrosoftGraphCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("X-WORKING-MY-RESPONSE:accepted"),
                   "Microsoft bridge should normalize mailto/percent-encoded account identity when detecting my response")
        try expect(text.contains("X-WORKING-CURRENT-USER=TRUE"),
                   "Microsoft bridge should mark current user from normalized mailto identity")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Microsoft mailto identity bridge")
        try expect(event.myResponseStatus == .accepted,
                   "Microsoft mailto identity bridge should import my accepted response")
        try expect(event.attendees.contains { $0.email == "me+calendar@example.com" && $0.isCurrentUser && $0.status == .accepted },
                   "Microsoft mailto identity bridge should import the normalized identity attendee as current user")
    }

    private static func verifyMicrosoftAliasIdentityBridge() throws {
        let account = providerAccount(
            kind: .microsoft365,
            endpointURLString: "https://graph.microsoft.com/v1.0",
            identityEmail: "primary@example.com",
            identityEmailAliases: ["alias@example.com"]
        )
        let calendar = MicrosoftGraphCalendarInfo(
            id: "graph-calendar-alias-identity",
            name: "Graph Alias Identity Fixture",
            colorHex: "#0EA5E9",
            canEdit: true
        )
        let events: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-alias-identity-1",
            "changeKey": "alias-identity-change-key",
            "subject": "Graph alias identity fixture",
            "body": { "contentType": "text", "content": "Identity matching should use aliases." },
            "isCancelled": false,
            "isAllDay": false,
            "showAs": "busy",
            "organizer": {
              "emailAddress": { "name": "Owner", "address": "owner@example.com" }
            },
            "attendees": [
              {
                "emailAddress": { "name": "Alias Me", "address": "SMTP:alias%40example.com?subject=calendar#fragment" },
                "status": { "response": "accepted" },
                "type": "required"
              },
              {
                "emailAddress": { "name": "Teammate", "address": "teammate@example.com" },
                "status": { "response": "none" },
                "type": "required"
              }
            ],
            "createdDateTime": "2026-06-25T08:35:00Z",
            "lastModifiedDateTime": "2026-06-25T08:36:00Z",
            "start": { "dateTime": "2026-07-02T14:30:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-02T15:00:00", "timeZone": "Asia/Nicosia" }
          }
        ]
        """)

        let text = try MicrosoftGraphCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("X-WORKING-MY-RESPONSE:accepted"),
                   "Microsoft bridge should use account identity aliases when detecting my response")
        try expect(text.contains("X-WORKING-CURRENT-USER=TRUE"),
                   "Microsoft bridge should mark current user from an account identity alias")
        try expect(!text.localizedCaseInsensitiveContains("mailto:SMTP:"),
                   "Microsoft bridge should not emit raw SMTP proxy addresses as mailto values")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Microsoft alias identity bridge")
        try expect(event.myResponseStatus == .accepted,
                   "Microsoft alias identity bridge should import my accepted response")
        try expect(event.attendees.contains { $0.email == "alias@example.com" && $0.isCurrentUser && $0.status == .accepted },
                   "Microsoft alias identity bridge should import the alias attendee as current user")
    }

    private static func verifyMicrosoftShowAsMetadataBridge() throws {
        let account = providerAccount(
            kind: .microsoft365,
            endpointURLString: "https://graph.microsoft.com/v1.0",
            identityEmail: "me@example.com"
        )
        let calendar = MicrosoftGraphCalendarInfo(
            id: "graph-calendar-show-as",
            name: "Graph ShowAs Fixture",
            colorHex: "#7C3AED",
            canEdit: true
        )
        let events: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-show-as-1",
            "changeKey": "show-as-change-key",
            "subject": "Graph show-as fixture",
            "isCancelled": false,
            "isAllDay": false,
            "showAs": "oof",
            "categories": ["Customer"],
            "iCalUId": "graph-show-as@example.com",
            "lastModifiedDateTime": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-07-01T09:00:00", "timeZone": "UTC" },
            "end": { "dateTime": "2026-07-01T09:30:00", "timeZone": "UTC" }
          }
        ]
        """)

        let text = try MicrosoftGraphCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("CATEGORIES:Customer,Microsoft showAs oof"),
                   "Microsoft bridge should keep non-default Graph showAs as local metadata")
        try expect(text.contains("TRANSP:OPAQUE"), "Microsoft OOF show-as should stay busy time")
        try expect(!text.contains("STATUS:TENTATIVE"), "Microsoft OOF show-as should not masquerade as tentative status")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Microsoft show-as bridge")
        try expect(event.categories == ["Customer", "Microsoft showAs oof"],
                   "Microsoft show-as bridge should import provider showAs metadata alongside user categories")
        try expect(event.availability == .busy, "Microsoft OOF show-as should import as busy time")
        try expect(event.status == .confirmed, "Microsoft OOF show-as should not change local event status")
    }

    private static func verifyMicrosoftReadOnlyCalendarBridge() throws {
        let account = providerAccount(kind: .microsoft365, endpointURLString: "https://graph.microsoft.com/v1.0")
        let calendar = MicrosoftGraphCalendarInfo(
            id: "graph-calendar-readonly",
            name: "Graph Read-only Fixture",
            colorHex: "#64748B",
            canEdit: false
        )
        let events: [MicrosoftGraphEvent] = try decodeJSON("""
        [
          {
            "id": "graph-readonly-1",
            "changeKey": "readonly-change-key",
            "subject": "Graph read-only fixture",
            "isCancelled": false,
            "isAllDay": false,
            "iCalUId": "graph-readonly@example.com",
            "lastModifiedDateTime": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-07-01T09:00:00", "timeZone": "UTC" },
            "end": { "dateTime": "2026-07-01T09:30:00", "timeZone": "UTC" }
          }
        ]
        """)

        let text = try MicrosoftGraphCalendarClient().annotatedICSText(
            events: events,
            calendar: calendar,
            account: account
        )
        try expect(text.contains("X-WORKING-CALENDAR-ALLOWS-EVENT-WRITE:FALSE"),
                   "Microsoft read-only calendars should be marked as not writable")
        try expect(text.contains("X-WORKING-CALENDAR-ALLOWS-RESPONSES:FALSE"),
                   "Microsoft read-only calendars should be marked as not response-capable")

        let imported = try LocalCalendarICSCodec.import(text)
        let event = try requireOnlyEvent(imported.events, context: "Microsoft read-only bridge")
        let calendarInfo = try requireOnlyCalendar(imported.calendars, context: "Microsoft read-only bridge")
        try expect(calendarInfo.allowsEventWrite == false, "Microsoft read-only calendar should import as read-only")
        try expect(calendarInfo.allowsResponses == false, "Microsoft read-only calendar should not allow responses")
        try expect(event.remoteETag == "readonly-change-key", "Microsoft read-only bridge should preserve changeKey")
    }

    private static func providerAccount(
        kind: CalendarProviderKind,
        endpointURLString: String,
        identityEmail: String? = nil,
        identityEmailAliases: [String] = []
    ) -> CalendarProviderAccount {
        CalendarProviderAccount(
            id: "provider-fixture-\(kind.rawValue)",
            kind: kind,
            title: "Provider Fixture",
            endpointURLString: endpointURLString,
            username: nil,
            identityEmail: identityEmail,
            identityEmailAliases: identityEmailAliases,
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func decodeJSON<Value: Decodable>(_ text: String) throws -> Value {
        guard let data = text.data(using: .utf8) else {
            throw ProviderICSBridgeInvariantError("Invalid JSON fixture text")
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private static func queryItemsDictionary(_ queryItems: [URLQueryItem]) throws -> [String: String] {
        var values: [String: String] = [:]
        for queryItem in queryItems {
            guard values[queryItem.name] == nil else {
                throw ProviderICSBridgeInvariantError("Expected query item \(queryItem.name) to be unique")
            }
            values[queryItem.name] = queryItem.value ?? ""
        }
        return values
    }

    private static func requireOnlyEvent(_ events: [LocalCalendarEvent], context: String) throws -> LocalCalendarEvent {
        guard events.count == 1, let event = events.first else {
            throw ProviderICSBridgeInvariantError("\(context) should import exactly one event")
        }
        return event
    }

    private static func calendarEvent(from event: LocalCalendarEvent) -> CalendarEvent {
        CalendarEvent(
            id: event.id,
            eventIdentifier: event.id,
            calendarItemIdentifier: event.id,
            externalIdentifier: event.externalUID,
            sequence: event.sequence,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            occurrenceStartDate: event.startDate,
            isAllDay: event.isAllDay,
            availability: event.availability,
            status: event.status,
            privacy: event.privacy,
            importance: event.importance,
            categories: event.categories,
            reminderOffsets: event.reminderOffsets,
            timeZoneIdentifier: event.timeZoneIdentifier,
            isRecurring: event.isRecurring,
            isDetached: false,
            calendarID: event.calendarID,
            calendarTitle: "Fixture",
            sourceTitle: "Provider Fixture",
            calendarColor: NSColor.systemBlue,
            location: nilIfBlank(event.location),
            notes: nilIfBlank(event.notes),
            url: URL(string: event.urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
            responseStatus: event.myResponseStatus,
            responseStatusIsExplicit: event.myResponseStatus != .notInvited,
            attendeeCount: event.attendees.count,
            organizer: nil,
            participants: event.attendees.filter { !$0.isBlank }.map { attendee in
                EventParticipant(
                    id: attendee.id,
                    name: attendee.name,
                    email: attendee.email,
                    type: attendee.normalizedType,
                    role: attendee.normalizedRole,
                    status: attendee.status,
                    isCurrentUser: attendee.isCurrentUser,
                    isRoomLike: attendee.isRoomLike
                )
            }
        )
    }

    private static func nilIfBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func requireOnlyDetachedOccurrence(
        _ occurrences: [LocalDetachedOccurrence],
        context: String
    ) throws -> LocalDetachedOccurrence {
        guard occurrences.count == 1, let occurrence = occurrences.first else {
            throw ProviderICSBridgeInvariantError("\(context) should import exactly one detached occurrence")
        }
        return occurrence
    }

    private static func requireOnlyCalendar(_ calendars: [LocalCalendar], context: String) throws -> LocalCalendar {
        guard calendars.count == 1, let calendar = calendars.first else {
            throw ProviderICSBridgeInvariantError("\(context) should import exactly one calendar")
        }
        return calendar
    }

    @MainActor
    private static func expandedEvents(from text: String, start: String, end: String) throws -> [CalendarEvent] {
        resetLocalCalendarStorage()
        defer { resetLocalCalendarStorage() }
        let store = LocalCalendarStore()
        _ = try store.importICSText(text)
        return store.events(from: date(start), to: date(end), includeAllDay: true)
    }

    @MainActor
    private static func verifyFullRefreshPruneKeepsDetachedOccurrence(
        text: String,
        calendarIDPrefix: String,
        keepingRemoteObjectURLs: Set<String>,
        rangeStart: String,
        rangeEnd: String,
        context: String
    ) throws {
        resetLocalCalendarStorage()
        defer { resetLocalCalendarStorage() }
        let store = LocalCalendarStore()
        _ = try store.importICSText(text)
        let importedEvent = try requireOnlyEvent(store.events, context: context)
        try expect(!importedEvent.detachedOccurrences.isEmpty,
                   "\(context) should import at least one detached occurrence before pruning")

        let prunedCount = store.pruneProviderEvents(
            calendarIDPrefix: calendarIDPrefix,
            keepingRemoteObjectURLs: keepingRemoteObjectURLs,
            pruneRange: DateInterval(start: date(rangeStart), end: date(rangeEnd))
        )
        try expect(prunedCount == 0, "\(context) should not prune freshly imported detached occurrences")
        let prunedEvent = try requireOnlyEvent(store.events, context: context)
        try expect(prunedEvent.detachedOccurrences.count == importedEvent.detachedOccurrences.count,
                   "\(context) should keep detached occurrence overrides after full-refresh pruning")
    }

    private static func resetLocalCalendarStorage() {
        UserDefaults.standard.removeObject(forKey: "localCalendars")
        UserDefaults.standard.removeObject(forKey: "localCalendarEvents")
        UserDefaults.standard.removeObject(forKey: "selectedLocalCalendarIDs")
    }

    private static func sameInstant(_ date: Date, _ expected: String) -> Bool {
        abs(date.timeIntervalSince(Self.date(expected))) < 0.5
    }

    private static func sameLocalDay(_ date: Date, _ expectedDay: String) -> Bool {
        localDayString(date) == expectedDay
    }

    private static func localDayString(_ date: Date) -> String {
        localDayFormatter.string(from: date)
    }

    private static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func date(_ string: String) -> Date {
        guard let date = ISO8601DateFormatter().date(from: string) else {
            fatalError("Invalid test date: \(string)")
        }
        return date
    }

    private static let localDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw ProviderICSBridgeInvariantError(message)
        }
    }
}

private struct ProviderICSBridgeInvariantError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
