import Foundation

@main
struct VerifyProviderWritePayloads {
    @MainActor
    static func main() throws {
        try verifyCalDAVRecurringWritePayload()
        try verifyCalDAVSchedulingReplyPayload()
        try verifyGoogleRecurringWritePayloads()
        try verifyGoogleResponsePatchPayload()
        try verifyGoogleRecurringExceptionWritePlan()
        try verifyMicrosoftRecurringWritePayloads()
        try verifyMicrosoftRecurringExceptionWritePlan()
        try verifyProviderFutureSplitWritePayloads()
        try verifyAllDayProviderOccurrenceMatching()
        print("Provider write payload invariant passed.")
    }

    private static func verifyCalDAVRecurringWritePayload() throws {
        let event = try recurringEvent(
            id: "local-event-provider-write-caldav",
            calendarID: "local-calendar-caldav-provider-write-work",
            title: "CalDAV provider write fixture",
            urlString: "https://meet.example.com/caldav-write-fixture"
        )
        let localCalendar = LocalCalendar(
            id: event.calendarID,
            title: "CalDAV Work",
            colorHex: "#2563EB"
        )
        let serverCalendar = CalDAVCalendar(
            href: URL(string: "https://caldav.example.com/calendars/me/work/")!,
            displayName: "CalDAV Work",
            colorHex: "#2563EB",
            syncToken: "sync-token",
            cTag: "ctag",
            allowsEventWrite: true,
            allowsResponses: true
        )

        let text = CalDAVClient().calendarDataPayloadPreview(
            for: event,
            localCalendar: localCalendar,
            calendar: serverCalendar
        )

        try expect(!text.contains("METHOD:"), "CalDAV write payload should be a stored VCALENDAR object, not a scheduling METHOD")
        try expect(!text.contains("X-WORKING-"), "CalDAV write payload should not leak private Working Calendar metadata")
        try expect(countOccurrences(of: "BEGIN:VEVENT", in: text) == 2, "CalDAV write should include base event plus detached occurrence")
        try expect(text.contains("UID:local-event-provider-write-caldav@example.com"), "CalDAV write should preserve stable UID")
        try expect(text.contains("RRULE:FREQ=WEEKLY"), "CalDAV write should preserve recurring base series")
        try expect(text.contains("RDATE;TZID=Asia/Nicosia:"), "CalDAV write should preserve extra RDATE occurrences")
        try expect(text.contains("EXDATE;TZID=Asia/Nicosia:"), "CalDAV write should preserve excluded occurrences")
        try expect(text.contains("RECURRENCE-ID;TZID=Asia/Nicosia:"), "CalDAV write should preserve detached occurrence identity")
        try expect(text.contains("BEGIN:VALARM"), "CalDAV write should preserve reminder alarms")
        try expect(text.contains("ORGANIZER;CN=\"Owner\":mailto:owner@example.com"), "CalDAV write should preserve organizer")
        try expect(text.contains("CUTYPE=RESOURCE"), "CalDAV write should preserve room/resource attendees")

        let imported = try LocalCalendarICSCodec.import(text)
        guard imported.events.count == 1, let importedEvent = imported.events.first else {
            throw ProviderWritePayloadInvariantError("CalDAV write payload should round-trip as one recurring event")
        }
        try expect(importedEvent.detachedOccurrences.count == 1, "CalDAV write payload should round-trip detached occurrences")
        try expect(importedEvent.excludedOccurrenceStartDates.count == 1, "CalDAV write payload should round-trip excluded occurrences")
        try expect(importedEvent.additionalOccurrenceStartDates.count == 1, "CalDAV write payload should round-trip extra occurrences")

        let monthDayEvent = try monthlyNegativeMonthDayEvent(
            id: "local-event-provider-write-caldav-negative-month-day",
            calendarID: localCalendar.id,
            title: "CalDAV negative month day fixture"
        )
        let monthDayText = CalDAVClient().calendarDataPayloadPreview(
            for: monthDayEvent,
            localCalendar: localCalendar,
            calendar: serverCalendar
        )
        try expect(monthDayText.contains("BYMONTHDAY=-1"), "CalDAV write should preserve negative BYMONTHDAY recurrence rules")
        let monthDayImport = try LocalCalendarICSCodec.import(monthDayText)
        try expect(monthDayImport.events.first?.recurrenceMonthDay == -1, "CalDAV negative BYMONTHDAY write should round-trip the month-day rule")

        let yearlyMonthDayEvent = try yearlyNegativeMonthDayEvent(
            id: "local-event-provider-write-caldav-yearly-negative-month-day",
            calendarID: localCalendar.id,
            title: "CalDAV yearly negative month day fixture"
        )
        let yearlyMonthDayText = CalDAVClient().calendarDataPayloadPreview(
            for: yearlyMonthDayEvent,
            localCalendar: localCalendar,
            calendar: serverCalendar
        )
        try expect(yearlyMonthDayText.contains("BYMONTH=2"), "CalDAV write should preserve yearly negative BYMONTH target month")
        try expect(yearlyMonthDayText.contains("BYMONTHDAY=-1"), "CalDAV write should preserve yearly negative BYMONTHDAY recurrence rules")
        let yearlyMonthDayImport = try LocalCalendarICSCodec.import(yearlyMonthDayText)
        try expect(yearlyMonthDayImport.events.first?.recurrenceFrequency == .yearly, "CalDAV yearly negative BYMONTHDAY write should round-trip as yearly")
        try expect(yearlyMonthDayImport.events.first?.recurrenceMonthDay == -1, "CalDAV yearly negative BYMONTHDAY write should round-trip the month-day rule")

        let yearlyByMonthEvent = try yearlyByMonthEvent(
            id: "local-event-provider-write-caldav-yearly-bymonth",
            calendarID: localCalendar.id,
            title: "CalDAV yearly BYMONTH fixture"
        )
        let yearlyByMonthText = CalDAVClient().calendarDataPayloadPreview(
            for: yearlyByMonthEvent,
            localCalendar: localCalendar,
            calendar: serverCalendar
        )
        try expect(yearlyByMonthText.contains("BYMONTH=1,4,7,10"), "CalDAV write should preserve yearly multi-month BYMONTH rules")
        try expect(yearlyByMonthText.contains("BYMONTHDAY=5"), "CalDAV write should preserve yearly BYMONTH day-of-month")
        let yearlyByMonthImport = try LocalCalendarICSCodec.import(yearlyByMonthText)
        try expect(yearlyByMonthImport.events.first?.recurrenceFrequency == .yearly, "CalDAV yearly BYMONTH write should round-trip as yearly")
        try expect(yearlyByMonthImport.events.first?.recurrenceMonths == [1, 4, 7, 10], "CalDAV yearly BYMONTH write should round-trip allowed months")

        let monthlyByMonthEvent = try monthlyByMonthEvent(
            id: "local-event-provider-write-caldav-monthly-bymonth",
            calendarID: localCalendar.id,
            title: "CalDAV monthly BYMONTH fixture"
        )
        let monthlyByMonthText = CalDAVClient().calendarDataPayloadPreview(
            for: monthlyByMonthEvent,
            localCalendar: localCalendar,
            calendar: serverCalendar
        )
        try expect(monthlyByMonthText.contains("BYMONTH=1,4,7,10"), "CalDAV write should preserve monthly multi-month BYMONTH rules")
        try expect(monthlyByMonthText.contains("BYMONTHDAY=5"), "CalDAV write should preserve monthly BYMONTH day-of-month")
        let monthlyByMonthImport = try LocalCalendarICSCodec.import(monthlyByMonthText)
        try expect(monthlyByMonthImport.events.first?.recurrenceFrequency == .monthly, "CalDAV monthly BYMONTH write should round-trip as monthly")
        try expect(monthlyByMonthImport.events.first?.recurrenceMonths == [1, 4, 7, 10], "CalDAV monthly BYMONTH write should round-trip allowed months")

        let weekStartEvent = try weeklyWeekStartEvent(
            id: "local-event-provider-write-caldav-week-start",
            calendarID: localCalendar.id,
            title: "CalDAV WKST fixture"
        )
        let weekStartText = CalDAVClient().calendarDataPayloadPreview(
            for: weekStartEvent,
            localCalendar: localCalendar,
            calendar: serverCalendar
        )
        try expect(weekStartText.contains("WKST=MO"), "CalDAV write should preserve weekly recurrence week start")
        let weekStartImport = try LocalCalendarICSCodec.import(weekStartText)
        try expect(weekStartImport.events.first?.recurrenceWeekStart == 2, "CalDAV weekly WKST write should round-trip the week start")

        let weeklySetPositionEvent = try weeklySetPositionEvent(
            id: "local-event-provider-write-caldav-weekly-set-position",
            calendarID: localCalendar.id,
            title: "CalDAV weekly BYSETPOS fixture"
        )
        let weeklySetPositionText = CalDAVClient().calendarDataPayloadPreview(
            for: weeklySetPositionEvent,
            localCalendar: localCalendar,
            calendar: serverCalendar
        )
        try expect(weeklySetPositionText.contains("BYSETPOS=-1"),
                   "CalDAV write should preserve weekly BYSETPOS recurrence rules")
        let weeklySetPositionImport = try LocalCalendarICSCodec.import(weeklySetPositionText)
        try expect(weeklySetPositionImport.events.first?.recurrenceSetPositions == [-1],
                   "CalDAV weekly BYSETPOS write should round-trip the set-position rule")

        let allDayEvent = try allDayRecurringEvent(
            id: "local-event-provider-write-caldav-all-day",
            calendarID: localCalendar.id,
            title: "CalDAV all-day fixture",
            includeAdditionalOccurrences: true
        )
        let allDayText = CalDAVClient().calendarDataPayloadPreview(
            for: allDayEvent,
            localCalendar: localCalendar,
            calendar: serverCalendar
        )
        try expect(allDayText.contains("DTSTART;VALUE=DATE:20260701"), "CalDAV all-day write should preserve date-only DTSTART in the event timezone")
        try expect(allDayText.contains("DTEND;VALUE=DATE:20260702"), "CalDAV all-day write should preserve date-only DTEND in the event timezone")
        try expect(allDayText.contains("RDATE;VALUE=DATE:20260718"), "CalDAV all-day write should preserve date-only RDATE")
        try expect(allDayText.contains("EXDATE;VALUE=DATE:20260715"), "CalDAV all-day write should preserve date-only EXDATE")
        try expect(allDayText.contains("RECURRENCE-ID;VALUE=DATE:20260708"), "CalDAV all-day write should preserve date-only detached occurrence identity")
        try expect(allDayText.contains("UNTIL=20260722"), "CalDAV all-day write should preserve date-only recurrence UNTIL in the event timezone")
        let allDayImport = try LocalCalendarICSCodec.import(allDayText)
        guard allDayImport.events.count == 1, let importedAllDayEvent = allDayImport.events.first else {
            throw ProviderWritePayloadInvariantError("CalDAV all-day write payload should round-trip as one recurring event")
        }
        try expect(importedAllDayEvent.isAllDay, "CalDAV all-day write payload should round-trip as all-day")
        try expect(importedAllDayEvent.detachedOccurrences.first?.isAllDay == true, "CalDAV all-day detached occurrence should round-trip as all-day")

        let allDayYearlyEvent = try allDayYearlyEvent(
            id: "local-event-provider-write-caldav-all-day-yearly",
            calendarID: localCalendar.id,
            title: "CalDAV all-day yearly fixture"
        )
        let allDayYearlyText = CalDAVClient().calendarDataPayloadPreview(
            for: allDayYearlyEvent,
            localCalendar: localCalendar,
            calendar: serverCalendar
        )
        try expect(allDayYearlyText.contains("DTSTART;VALUE=DATE:20260101"), "CalDAV all-day yearly write should preserve local DTSTART date")
        try expect(allDayYearlyText.contains("BYMONTH=1"), "CalDAV all-day yearly write should compute BYMONTH in the event timezone")
        try expect(allDayYearlyText.contains("BYMONTHDAY=1"), "CalDAV all-day yearly write should compute BYMONTHDAY in the event timezone")
        try expect(!allDayYearlyText.contains("BYMONTH=12"), "CalDAV all-day yearly write should not derive BYMONTH from UTC/current timezone")
        try expect(!allDayYearlyText.contains("BYMONTHDAY=31"), "CalDAV all-day yearly write should not derive BYMONTHDAY from UTC/current timezone")

        let weeklyFallbackEvent = try allDayWeeklyFallbackEvent(
            id: "local-event-provider-write-caldav-weekly-fallback",
            calendarID: localCalendar.id,
            title: "CalDAV weekly fallback fixture"
        )
        let weeklyFallbackText = CalDAVClient().calendarDataPayloadPreview(
            for: weeklyFallbackEvent,
            localCalendar: localCalendar,
            calendar: serverCalendar
        )
        try expect(weeklyFallbackText.contains("DTSTART;VALUE=DATE:20260706"), "CalDAV weekly fallback fixture should preserve local DTSTART date")
        try expect(weeklyFallbackText.contains("BYDAY=MO"), "CalDAV weekly fallback should derive BYDAY from the event timezone")
        try expect(!weeklyFallbackText.contains("BYDAY=SU"), "CalDAV weekly fallback should not derive BYDAY from UTC/current timezone")
    }

    private static func verifyCalDAVSchedulingReplyPayload() throws {
        let event = try recurringEvent(
            id: "local-event-provider-write-caldav-reply",
            calendarID: "local-calendar-caldav-provider-write-work",
            title: "CalDAV reply fixture",
            urlString: "https://meet.example.com/caldav-reply-fixture"
        )
        let client = CalDAVClient()
        let now = try date("2026-06-25T08:45:00Z")

        guard let seriesReply = client.schedulingReplyPayloadPreview(
            for: event,
            response: .maybe,
            now: now
        ) else {
            throw ProviderWritePayloadInvariantError("CalDAV scheduling reply payload should be generated for current attendee")
        }
        let unfoldedSeriesReply = unfoldedICSText(seriesReply)
        try expect(unfoldedSeriesReply.contains("METHOD:REPLY"), "CalDAV RSVP should be sent as an iTIP REPLY")
        try expect(unfoldedSeriesReply.contains("UID:local-event-provider-write-caldav-reply@example.com"), "CalDAV REPLY should target the event UID")
        try expect(unfoldedSeriesReply.contains("DTSTAMP:20260625T084500Z"), "CalDAV REPLY should use the provided DTSTAMP")
        try expect(unfoldedSeriesReply.contains("SEQUENCE:4"), "CalDAV REPLY should preserve the event sequence")
        try expect(unfoldedSeriesReply.contains("ORGANIZER;CN=\"Owner\":mailto:owner@example.com"), "CalDAV REPLY should include the organizer")
        try expect(unfoldedSeriesReply.contains("ATTENDEE;PARTSTAT=TENTATIVE"),
                   "CalDAV REPLY should include the selected PARTSTAT")
        try expect(unfoldedSeriesReply.contains("CN=\"Me\":mailto:me@example.com"),
                   "CalDAV REPLY should target the current attendee")
        try expect(!unfoldedSeriesReply.contains("SUMMARY:"), "CalDAV REPLY should not send a stored event body")
        try expect(!unfoldedSeriesReply.contains("X-WORKING-"), "CalDAV REPLY should not leak private Working Calendar metadata")
        try expect(countOccurrences(of: "ATTENDEE", in: unfoldedSeriesReply) == 1, "CalDAV REPLY should contain one attendee response")
        do {
            _ = try LocalCalendarICSCodec.import(seriesReply)
            throw ProviderWritePayloadInvariantError("CalDAV REPLY payload should not import as a standalone event")
        } catch LocalICSImportError.noEvents {
            // Expected: scheduling replies only update attendee response state.
        }
        let replies = LocalCalendarICSCodec.replies(from: seriesReply)
        try expect(replies.count == 1, "CalDAV REPLY payload should parse as one reply")
        try expect(replies.first?.attendees.first?.status == .tentative, "CalDAV REPLY should parse the tentative response")

        var aliasMatchedEvent = event
        aliasMatchedEvent.attendees[0].isCurrentUser = false
        let aliasAccount = CalendarProviderAccount(
            id: "caldav-reply-alias-fixture",
            kind: .calDAV,
            title: "CalDAV Reply Alias Fixture",
            endpointURLString: "https://caldav.example.com/",
            username: nil,
            identityEmail: "alpha@example.com",
            identityEmailAliases: ["me@example.com"],
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
        guard let aliasReply = client.schedulingReplyPayloadPreview(
            for: aliasMatchedEvent,
            account: aliasAccount,
            response: .accept,
            now: now
        ) else {
            throw ProviderWritePayloadInvariantError("CalDAV alias scheduling reply payload should be generated")
        }
        let unfoldedAliasReply = unfoldedICSText(aliasReply)
        try expect(unfoldedAliasReply.contains("CN=\"Me\":mailto:me@example.com"),
                   "CalDAV REPLY should target the event attendee matching an account alias")
        try expect(!unfoldedAliasReply.contains("mailto:alpha@example.com"),
                   "CalDAV REPLY should not synthesize a primary account identity when an alias attendee is present")
        try expect(countOccurrences(of: "ATTENDEE", in: unfoldedAliasReply) == 1,
                   "CalDAV alias REPLY should still contain one attendee response")

        guard let occurrenceReply = client.schedulingReplyPayloadPreview(
            for: event,
            response: .decline,
            occurrenceStartDate: try date("2026-07-08T06:00:00Z"),
            occurrenceIsAllDay: false,
            now: now
        ) else {
            throw ProviderWritePayloadInvariantError("CalDAV occurrence scheduling reply payload should be generated")
        }
        let unfoldedOccurrenceReply = unfoldedICSText(occurrenceReply)
        try expect(unfoldedOccurrenceReply.contains("RECURRENCE-ID;TZID=Asia/Nicosia:20260708T090000"),
                   "CalDAV occurrence REPLY should target the local recurrence start")
        try expect(unfoldedOccurrenceReply.contains("PARTSTAT=DECLINED"), "CalDAV occurrence REPLY should carry the declined response")
    }

    private static func verifyGoogleRecurringWritePayloads() throws {
        let event = try recurringEvent(
            id: "local-event-provider-write-google",
            calendarID: "local-calendar-google-provider-write",
            title: "Google provider write fixture",
            urlString: "https://meet.google.com/write-fixture",
            categories: [
                "Google color 5",
                "Google event type outOfOffice",
                "Google attendees omitted",
                "Google guest list hidden",
                "Google guests cannot invite",
                "Google guests can modify",
                "Google conference hangoutsMeet",
                "Customer"
            ]
        )
        let client = GoogleCalendarClient()
        let endpointAccount = CalendarProviderAccount(
            id: "google-endpoint-write-fixture",
            kind: .googleCalendar,
            title: "Google Endpoint Write Fixture",
            endpointURLString: "https://www.googleapis.com/calendar/v3",
            username: nil,
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
        let endpoint = try client.eventURLPreview(
            account: endpointAccount,
            calendarID: "calendar with spaces%2Fplus+id",
            eventID: "event/id%2Fplus+id"
        )
        try expect(endpoint.absoluteString == "https://www.googleapis.com/calendar/v3/calendars/calendar%20with%20spaces%252Fplus%2Bid/events/event%2Fid%252Fplus%2Bid",
                   "Google write-back should preserve the API base path and percent-encode calendar/event IDs")
        let basePayload = try jsonObject(client.encodedWritePayloadPreview(for: event))
        let recurrence = try stringArray(basePayload["recurrence"], context: "Google recurrence")

        try expect(basePayload["summary"] as? String == "Google provider write fixture", "Google base write should preserve title")
        try expect(basePayload["location"] as? String == "CY-Office-1st-Conference", "Google base write should preserve location")
        try expect(basePayload["visibility"] as? String == "private", "Google base write should preserve privacy")
        try expect(basePayload["transparency"] as? String == "opaque", "Google base write should preserve busy availability")
        try expect(basePayload["colorId"] as? String == "5", "Google base write should preserve Google color metadata")
        try expect(basePayload["guestsCanSeeOtherGuests"] as? Bool == false,
                   "Google base write should preserve hidden guest list metadata")
        try expect(basePayload["guestsCanInviteOthers"] as? Bool == false,
                   "Google base write should preserve disabled guest invitations metadata")
        try expect(basePayload["guestsCanModify"] as? Bool == true,
                   "Google base write should preserve guest modification metadata")
        try expect(basePayload["attendeesOmitted"] as? Bool == true,
                   "Google base write should mark partial attendee payloads so omitted remote attendees are not cleared")
        try expect(basePayload["eventType"] == nil, "Google base write should not send read-only Google event type metadata")
        try expect(try googleWorkingCategories(in: basePayload, context: "Google base") == ["Customer"],
                   "Google base write should preserve non-provider categories in extended properties")
        var structuredMetadataEvent = event
        structuredMetadataEvent.relatedEvents = [
            LocalEventRelationship(relationType: "PARENT", externalUID: "parent-google-provider-write@example.com"),
            LocalEventRelationship(relationType: "SIBLING", externalUID: "sibling-google-provider-write@example.com")
        ]
        structuredMetadataEvent.geoCoordinate = LocalEventGeoCoordinate(latitude: 35.1855659, longitude: 33.3822764)
        let structuredMetadataPayload = try jsonObject(client.encodedWritePayloadPreview(for: structuredMetadataEvent))
        try expect(
            try googleRelatedEvents(in: structuredMetadataPayload, context: "Google structured metadata") == structuredMetadataEvent.relatedEvents,
            "Google write should preserve local RELATED-TO relationships in private extended properties"
        )
        try expect(
            try googleGeoCoordinate(in: structuredMetadataPayload, context: "Google structured metadata") == structuredMetadataEvent.geoCoordinate,
            "Google write should preserve local GEO coordinates in private extended properties"
        )
        try expect(basePayload["conferenceData"] == nil,
                   "Google patch should not create a fresh Meet conference on existing events")
        try expect(try queryItemsDictionary(client.eventModificationQueryItemsPreview(for: event))["supportsAttachments"] == nil,
                   "Google write should not request attachment support for events without attachments")
        var explicitPublicVisibilityEvent = event
        explicitPublicVisibilityEvent.privacy = .public
        explicitPublicVisibilityEvent.categories = ["Google visibility public", "Customer"]
        let explicitPublicVisibilityPayload = try jsonObject(client.encodedWritePayloadPreview(for: explicitPublicVisibilityEvent))
        try expect(explicitPublicVisibilityPayload["visibility"] as? String == "public",
                   "Google write should preserve explicit public visibility metadata instead of collapsing it to default")
        try expect(try googleWorkingCategories(in: explicitPublicVisibilityPayload, context: "Google explicit public visibility") == ["Customer"],
                   "Google explicit public visibility metadata should not leak into Working Calendar categories")
        var explicitPublicPrivacyOverrideEvent = explicitPublicVisibilityEvent
        explicitPublicPrivacyOverrideEvent.privacy = .private
        let explicitPublicPrivacyOverridePayload = try jsonObject(client.encodedWritePayloadPreview(for: explicitPublicPrivacyOverrideEvent))
        try expect(explicitPublicPrivacyOverridePayload["visibility"] as? String == "private",
                   "Google local private privacy should override stale explicit public visibility metadata")
        var officeWorkingLocationEvent = event
        officeWorkingLocationEvent.location = "CY Office"
        officeWorkingLocationEvent.categories = [
            "Google event type workingLocation",
            "Google working location office",
            "Google working location building CY",
            "Google working location floor 1",
            "Google working location desk D-14",
            "Customer"
        ]
        let officeWorkingLocationPayload = try jsonObject(client.encodedWritePayloadPreview(for: officeWorkingLocationEvent))
        let officeWorkingLocationProperties = try dictionary(
            officeWorkingLocationPayload["workingLocationProperties"],
            context: "Google office working-location properties"
        )
        let officeLocation = try dictionary(
            officeWorkingLocationProperties["officeLocation"],
            context: "Google office working-location office"
        )
        try expect(officeWorkingLocationPayload["eventType"] == nil,
                   "Google working-location patch should not rewrite read-only eventType metadata")
        try expect(officeWorkingLocationProperties["type"] as? String == "officeLocation",
                   "Google working-location patch should preserve office-location type")
        try expect(officeLocation["label"] as? String == "CY Office",
                   "Google office working-location patch should preserve the display label")
        try expect(officeLocation["buildingId"] as? String == "CY",
                   "Google office working-location patch should preserve building id metadata")
        try expect(officeLocation["floorId"] as? String == "1",
                   "Google office working-location patch should preserve floor id metadata")
        try expect(officeLocation["deskId"] as? String == "D-14",
                   "Google office working-location patch should preserve desk id metadata")
        try expect(try googleWorkingCategories(in: officeWorkingLocationPayload, context: "Google office working-location") == ["Customer"],
                   "Google working-location provider metadata should not leak into Working Calendar categories")

        var customWorkingLocationEvent = event
        customWorkingLocationEvent.location = "Customer HQ"
        customWorkingLocationEvent.categories = ["Google event type workingLocation", "Google working location custom"]
        let customWorkingLocationPayload = try jsonObject(client.encodedWritePayloadPreview(for: customWorkingLocationEvent))
        let customWorkingLocationProperties = try dictionary(
            customWorkingLocationPayload["workingLocationProperties"],
            context: "Google custom working-location properties"
        )
        let customLocation = try dictionary(
            customWorkingLocationProperties["customLocation"],
            context: "Google custom working-location custom"
        )
        try expect(customWorkingLocationProperties["type"] as? String == "customLocation",
                   "Google working-location patch should preserve custom-location type")
        try expect(customLocation["label"] as? String == "Customer HQ",
                   "Google custom working-location patch should preserve the display label")

        var homeWorkingLocationEvent = event
        homeWorkingLocationEvent.location = "Home office"
        homeWorkingLocationEvent.categories = ["Google event type workingLocation", "Google working location home"]
        let homeWorkingLocationPayload = try jsonObject(client.encodedWritePayloadPreview(for: homeWorkingLocationEvent))
        let homeWorkingLocationProperties = try dictionary(
            homeWorkingLocationPayload["workingLocationProperties"],
            context: "Google home working-location properties"
        )
        try expect(homeWorkingLocationProperties["type"] as? String == "homeOffice",
                   "Google working-location patch should preserve home-office type")
        _ = try dictionary(homeWorkingLocationProperties["homeOffice"], context: "Google home working-location homeOffice")

        let workingLocationInsertPayload = try jsonObject(client.encodedInsertPayloadPreview(for: officeWorkingLocationEvent, eventID: "insert-working-location"))
        try expect(workingLocationInsertPayload["workingLocationProperties"] == nil,
                   "Google insert should not try to create working-location properties without eventType support")

        var outOfOfficeEvent = event
        outOfOfficeEvent.categories = [
            "Google event type outOfOffice",
            "Google out of office auto decline declineAllConflictingInvitations",
            "Google out of office decline message OOO until Monday",
            "Customer"
        ]
        let outOfOfficePayload = try jsonObject(client.encodedWritePayloadPreview(for: outOfOfficeEvent))
        let outOfOfficeProperties = try dictionary(
            outOfOfficePayload["outOfOfficeProperties"],
            context: "Google out-of-office properties"
        )
        try expect(outOfOfficeProperties["autoDeclineMode"] as? String == "declineAllConflictingInvitations",
                   "Google out-of-office patch should preserve auto-decline mode metadata")
        try expect(outOfOfficeProperties["declineMessage"] as? String == "OOO until Monday",
                   "Google out-of-office patch should preserve decline-message metadata")
        try expect(outOfOfficePayload["eventType"] == nil,
                   "Google out-of-office patch should not rewrite read-only eventType metadata")
        try expect(try googleWorkingCategories(in: outOfOfficePayload, context: "Google out-of-office") == ["Customer"],
                   "Google out-of-office provider metadata should not leak into Working Calendar categories")
        let outOfOfficeInsertPayload = try jsonObject(client.encodedInsertPayloadPreview(for: outOfOfficeEvent, eventID: "insert-out-of-office"))
        try expect(outOfOfficeInsertPayload["outOfOfficeProperties"] == nil,
                   "Google insert should not try to create out-of-office properties without eventType support")

        var focusTimeEvent = event
        focusTimeEvent.categories = [
            "Google event type focusTime",
            "Google focus time auto decline declineOnlyNewConflictingInvitations",
            "Google focus time decline message Heads down",
            "Google focus time chat status doNotDisturb"
        ]
        let focusTimePayload = try jsonObject(client.encodedWritePayloadPreview(for: focusTimeEvent))
        let focusTimeProperties = try dictionary(
            focusTimePayload["focusTimeProperties"],
            context: "Google focus-time properties"
        )
        try expect(focusTimeProperties["autoDeclineMode"] as? String == "declineOnlyNewConflictingInvitations",
                   "Google focus-time patch should preserve auto-decline mode metadata")
        try expect(focusTimeProperties["declineMessage"] as? String == "Heads down",
                   "Google focus-time patch should preserve decline-message metadata")
        try expect(focusTimeProperties["chatStatus"] as? String == "doNotDisturb",
                   "Google focus-time patch should preserve chat-status metadata")
        try expect(focusTimePayload["eventType"] == nil,
                   "Google focus-time patch should not rewrite read-only eventType metadata")
        try expect(try googleWorkingCategories(in: focusTimePayload, context: "Google focus-time") == [],
                   "Google focus-time provider metadata should not leak into Working Calendar categories")
        let focusTimeInsertPayload = try jsonObject(client.encodedInsertPayloadPreview(for: focusTimeEvent, eventID: "insert-focus-time"))
        try expect(focusTimeInsertPayload["focusTimeProperties"] == nil,
                   "Google insert should not try to create focus-time properties without eventType support")

        var clearedCategoriesEvent = event
        clearedCategoriesEvent.categories = ["Google color 5", "Google event type outOfOffice"]
        let clearedCategoriesPayload = try jsonObject(client.encodedWritePayloadPreview(for: clearedCategoriesEvent))
        try expect(clearedCategoriesPayload["colorId"] as? String == "5",
                   "Google write should still preserve provider color metadata when clearing Working Calendar categories")
        try expect(try googleWorkingCategories(in: clearedCategoriesPayload, context: "Google cleared categories") == [],
                   "Google write should send an empty Working Calendar category marker so stale extended properties are cleared")
        try expect(try nestedString(basePayload, "source", "url") == "https://meet.google.com/write-fixture", "Google base write should preserve join URL as source")
        var attachmentEvent = event
        attachmentEvent.attachments = [
            LocalEventAttachment(
                urlString: "https://drive.google.com/file/d/google-provider-write-agenda/view",
                formatType: "application/vnd.google-apps.document",
                displayName: "Agenda"
            ),
            LocalEventAttachment(
                urlString: "https://drive.google.com/file/d/google-provider-write-brief/view",
                formatType: "application/pdf",
                displayName: "Customer brief"
            )
        ]
        let attachmentPayload = try jsonObject(client.encodedWritePayloadPreview(for: attachmentEvent))
        let attachments = try array(attachmentPayload["attachments"], context: "Google attachment write payload")
        try expect(attachments.count == 2, "Google write should preserve every supported local attachment")
        let firstAttachment = try dictionary(attachments[0], context: "Google first attachment")
        let secondAttachment = try dictionary(attachments[1], context: "Google second attachment")
        try expect(firstAttachment["fileUrl"] as? String == "https://drive.google.com/file/d/google-provider-write-agenda/view",
                   "Google write should preserve attachment fileUrl")
        try expect(firstAttachment["title"] as? String == "Agenda",
                   "Google write should preserve attachment title")
        try expect(firstAttachment["mimeType"] as? String == "application/vnd.google-apps.document",
                   "Google write should preserve attachment MIME type")
        try expect(secondAttachment["fileUrl"] as? String == "https://drive.google.com/file/d/google-provider-write-brief/view",
                   "Google write should preserve multiple attachment fileUrls")
        try expect(secondAttachment["title"] as? String == "Customer brief",
                   "Google write should preserve multiple attachment titles")
        let attachmentQuery = try queryItemsDictionary(client.eventModificationQueryItemsPreview(for: attachmentEvent))
        try expect(attachmentQuery["supportsAttachments"] == "true",
                   "Google write should set supportsAttachments=true when saving attachments")
        try expect(attachmentQuery["conferenceDataVersion"] == "1",
                   "Google write should keep conferenceDataVersion while adding attachment support")
        var clearedProviderMetadataEvent = event
        clearedProviderMetadataEvent.privacy = .public
        clearedProviderMetadataEvent.categories = ["Customer"]
        clearedProviderMetadataEvent.urlString = ""
        let clearedProviderMetadataPayload = try jsonObject(client.encodedWritePayloadPreview(for: clearedProviderMetadataEvent))
        try expect(clearedProviderMetadataPayload["visibility"] as? String == "default",
                   "Google write should explicitly restore default visibility when local event is public")
        try expect(clearedProviderMetadataPayload["colorId"] is NSNull,
                   "Google write should explicitly clear stale remote color metadata with colorId null")
        try expect(clearedProviderMetadataPayload["guestsCanSeeOtherGuests"] as? Bool == true,
                   "Google write should explicitly restore visible guest lists when hidden guest metadata is cleared")
        try expect(clearedProviderMetadataPayload["guestsCanInviteOthers"] as? Bool == true,
                   "Google write should explicitly restore guest invitations when disabled guest invitation metadata is cleared")
        try expect(clearedProviderMetadataPayload["guestsCanModify"] as? Bool == false,
                   "Google write should explicitly disable guest modifications when guest modification metadata is cleared")
        try expect(clearedProviderMetadataPayload["attendeesOmitted"] == nil,
                   "Google write should stop using partial-attendee patch semantics when omitted-attendee metadata is cleared")
        try expect(clearedProviderMetadataPayload["source"] is NSNull,
                   "Google write should explicitly clear stale remote source URL with source null")
        try expect(try googleWorkingCategories(in: clearedProviderMetadataPayload, context: "Google cleared provider metadata") == ["Customer"],
                   "Google write should keep Working Calendar categories while clearing provider metadata")
        let insertProviderMetadataPayload = try jsonObject(client.encodedInsertPayloadPreview(for: clearedProviderMetadataEvent, eventID: "insert-provider-metadata"))
        try expect(insertProviderMetadataPayload["colorId"] == nil,
                   "Google insert should omit absent color metadata instead of sending a clearing null")
        try expect(insertProviderMetadataPayload["guestsCanSeeOtherGuests"] == nil,
                   "Google insert should omit default guest visibility metadata")
        try expect(insertProviderMetadataPayload["guestsCanInviteOthers"] == nil,
                   "Google insert should omit default guest invitation metadata")
        try expect(insertProviderMetadataPayload["guestsCanModify"] == nil,
                   "Google insert should omit default guest modification metadata")
        try expect(insertProviderMetadataPayload["source"] == nil,
                   "Google insert should omit absent source URL instead of sending a clearing null")
        let nativeMeetInsertPayload = try jsonObject(client.encodedInsertPayloadPreview(for: event, eventID: "insert-native-meet"))
        try expect(nativeMeetInsertPayload["attendeesOmitted"] == nil,
                   "Google insert should not carry partial-attendee patch semantics into a newly created event")
        let conferenceData = try dictionary(nativeMeetInsertPayload["conferenceData"], context: "Google native Meet conference data")
        let createRequest = try dictionary(conferenceData["createRequest"], context: "Google native Meet create request")
        let conferenceSolutionKey = try dictionary(createRequest["conferenceSolutionKey"], context: "Google native Meet solution key")
        try expect(conferenceSolutionKey["type"] as? String == "hangoutsMeet",
                   "Google insert should request a native Google Meet conference")
        try expect((createRequest["requestId"] as? String)?.isEmpty == false,
                   "Google insert should include a stable conference create request id")
        try expect(nativeMeetInsertPayload["source"] == nil,
                   "Google insert should not reuse an old Meet URL as source when requesting a fresh native conference")
        try expect(try nestedString(basePayload, "start", "timeZone") == "Asia/Nicosia", "Google base write should preserve start timezone")
        try expect(try reminderMinutes(in: basePayload, context: "Google base") == [10],
                   "Google base write should preserve a single reminder offset")
        try expect(recurrence.contains { $0.hasPrefix("RRULE:FREQ=WEEKLY;") && $0.contains("BYDAY=WE") }, "Google base write should preserve weekly RRULE")
        try expect(recurrence.contains { $0.hasPrefix("RDATE;TZID=Asia/Nicosia:") }, "Google base write should preserve extra RDATE occurrence")
        try expect(recurrence.contains { $0.hasPrefix("EXDATE;TZID=Asia/Nicosia:") }, "Google base write should preserve excluded occurrence")
        try expect(
            try attendee(basePayload, email: "cy-office-1st-conference@example.com")["resource"] as? Bool == true,
            "Google base write should preserve room/resource attendees"
        )
        var clearedTextEvent = event
        clearedTextEvent.location = "   "
        clearedTextEvent.notes = " \n\t "
        let clearedTextPayload = try jsonObject(client.encodedWritePayloadPreview(for: clearedTextEvent))
        try expect(clearedTextPayload["location"] as? String == "",
                   "Google write should explicitly clear remote location with an empty string")
        try expect(clearedTextPayload["description"] as? String == "",
                   "Google write should explicitly clear remote description with an empty string")
        var clearedReminderEvent = event
        clearedReminderEvent.reminderOffsets = []
        let clearedReminderPayload = try jsonObject(client.encodedWritePayloadPreview(for: clearedReminderEvent))
        let clearedReminderSettings = try dictionary(clearedReminderPayload["reminders"], context: "Google cleared reminders")
        try expect(clearedReminderSettings["useDefault"] as? Bool == false,
                   "Google write should disable default reminders when local reminders are cleared")
        try expect(try array(clearedReminderSettings["overrides"], context: "Google cleared reminder overrides").isEmpty,
                   "Google write should explicitly clear remote reminder overrides with an empty override array")

        let detached = try requireOnlyDetachedOccurrence(event)
        let detachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: detached))
        try expect(detachedPayload["summary"] as? String == "Moved provider occurrence", "Google detached write should preserve occurrence title")
        try expect(detachedPayload["recurrence"] == nil, "Google detached write should not send a nested recurrence")
        try expect(detachedPayload["attendeesOmitted"] == nil,
                   "Google detached write should not use partial-attendee semantics when the occurrence metadata is absent")
        var partialAttendeesDetached = detached
        partialAttendeesDetached.categories.append("Google attendees omitted")
        let partialAttendeesDetachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: partialAttendeesDetached))
        try expect(partialAttendeesDetachedPayload["attendeesOmitted"] as? Bool == true,
                   "Google detached write should preserve partial-attendee patch semantics for omitted attendee occurrences")
        var focusTimeDetached = detached
        focusTimeDetached.categories = [
            "Google event type focusTime",
            "Google focus time auto decline declineOnlyNewConflictingInvitations",
            "Google focus time chat status doNotDisturb",
            "Customer"
        ]
        let focusTimeDetachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: focusTimeDetached))
        let focusTimeDetachedProperties = try dictionary(
            focusTimeDetachedPayload["focusTimeProperties"],
            context: "Google detached focus-time properties"
        )
        try expect(focusTimeDetachedProperties["autoDeclineMode"] as? String == "declineOnlyNewConflictingInvitations",
                   "Google detached focus-time write should preserve auto-decline mode metadata")
        try expect(focusTimeDetachedProperties["chatStatus"] as? String == "doNotDisturb",
                   "Google detached focus-time write should preserve chat-status metadata")
        try expect(try googleWorkingCategories(in: focusTimeDetachedPayload, context: "Google detached focus-time") == ["Customer"],
                   "Google detached focus-time provider metadata should not leak into Working Calendar categories")
        var explicitPublicVisibilityDetached = detached
        explicitPublicVisibilityDetached.privacy = .public
        explicitPublicVisibilityDetached.categories = ["Google visibility public", "Customer"]
        let explicitPublicVisibilityDetachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: explicitPublicVisibilityDetached))
        try expect(explicitPublicVisibilityDetachedPayload["visibility"] as? String == "public",
                   "Google detached write should preserve explicit public visibility metadata")
        try expect(try googleWorkingCategories(in: explicitPublicVisibilityDetachedPayload, context: "Google detached explicit public visibility") == ["Customer"],
                   "Google detached explicit public visibility metadata should not leak into Working Calendar categories")
        try expect(try nestedString(detachedPayload, "start", "timeZone") == "Asia/Nicosia", "Google detached write should preserve occurrence timezone")
        try expect(try nestedString(detachedPayload, "source", "url") == "https://meet.google.com/moved-provider-occurrence", "Google detached write should preserve occurrence URL")
        try expect(try googleWorkingCategories(in: detachedPayload, context: "Google detached") == ["Customer"],
                   "Google detached write should preserve non-provider categories in extended properties")
        try expect(try reminderMinutes(in: detachedPayload, context: "Google detached") == [5],
                   "Google detached write should preserve a single reminder offset")
        var structuredMetadataDetached = detached
        structuredMetadataDetached.relatedEvents = [
            LocalEventRelationship(relationType: "PARENT", externalUID: "parent-google-provider-detached-write@example.com"),
            LocalEventRelationship(relationType: "SIBLING", externalUID: "sibling-google-provider-detached-write@example.com")
        ]
        structuredMetadataDetached.geoCoordinate = LocalEventGeoCoordinate(latitude: 35.1855659, longitude: 33.3822764)
        let structuredMetadataDetachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: structuredMetadataDetached))
        try expect(
            try googleRelatedEvents(in: structuredMetadataDetachedPayload, context: "Google detached structured metadata") == structuredMetadataDetached.relatedEvents,
            "Google detached write should preserve occurrence RELATED-TO metadata in private extended properties"
        )
        try expect(
            try googleGeoCoordinate(in: structuredMetadataDetachedPayload, context: "Google detached structured metadata") == structuredMetadataDetached.geoCoordinate,
            "Google detached write should preserve occurrence GEO metadata in private extended properties"
        )
        var attachmentDetached = detached
        attachmentDetached.attachments = [
            LocalEventAttachment(
                urlString: "https://drive.google.com/file/d/google-provider-write-detached/view",
                formatType: "application/vnd.google-apps.spreadsheet",
                displayName: "Moved occurrence sheet"
            )
        ]
        let attachmentDetachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: attachmentDetached))
        let detachedAttachments = try array(attachmentDetachedPayload["attachments"], context: "Google detached attachment write payload")
        try expect(detachedAttachments.count == 1, "Google detached write should preserve occurrence attachments")
        let detachedAttachment = try dictionary(detachedAttachments[0], context: "Google detached attachment")
        try expect(detachedAttachment["fileUrl"] as? String == "https://drive.google.com/file/d/google-provider-write-detached/view",
                   "Google detached write should preserve attachment fileUrl")
        try expect(detachedAttachment["title"] as? String == "Moved occurrence sheet",
                   "Google detached write should preserve attachment title")
        let attachmentDetachedQuery = try queryItemsDictionary(
            client.detachedOccurrenceModificationQueryItemsPreview(for: attachmentDetached, sendUpdates: "all")
        )
        try expect(attachmentDetachedQuery["supportsAttachments"] == "true",
                   "Google detached write should request attachment support when saving occurrence attachments")
        try expect(attachmentDetachedQuery["sendUpdates"] == "all",
                   "Google detached attachment write should preserve sendUpdates query metadata")
        var clearedTextDetached = detached
        clearedTextDetached.location = " \n "
        clearedTextDetached.notes = "\t"
        let clearedTextDetachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: clearedTextDetached))
        try expect(clearedTextDetachedPayload["location"] as? String == "",
                   "Google detached write should explicitly clear remote location with an empty string")
        try expect(clearedTextDetachedPayload["description"] as? String == "",
                   "Google detached write should explicitly clear remote description with an empty string")
        var clearedReminderDetached = detached
        clearedReminderDetached.reminderOffsets = []
        let clearedReminderDetachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: clearedReminderDetached))
        let clearedDetachedReminderSettings = try dictionary(clearedReminderDetachedPayload["reminders"], context: "Google cleared detached reminders")
        try expect(clearedDetachedReminderSettings["useDefault"] as? Bool == false,
                   "Google detached write should disable default reminders when local reminders are cleared")
        try expect(try array(clearedDetachedReminderSettings["overrides"], context: "Google cleared detached reminder overrides").isEmpty,
                   "Google detached write should explicitly clear remote reminder overrides with an empty override array")
        var clearedProviderMetadataDetached = detached
        clearedProviderMetadataDetached.privacy = .public
        clearedProviderMetadataDetached.urlString = ""
        let clearedProviderMetadataDetachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: clearedProviderMetadataDetached))
        try expect(clearedProviderMetadataDetachedPayload["visibility"] as? String == "default",
                   "Google detached write should explicitly restore default visibility when local occurrence is public")
        try expect(clearedProviderMetadataDetachedPayload["colorId"] is NSNull,
                   "Google detached write should explicitly clear stale remote color metadata with colorId null")
        try expect(clearedProviderMetadataDetachedPayload["guestsCanSeeOtherGuests"] as? Bool == true,
                   "Google detached write should explicitly restore visible guest lists when hidden guest metadata is cleared")
        try expect(clearedProviderMetadataDetachedPayload["guestsCanInviteOthers"] as? Bool == true,
                   "Google detached write should explicitly restore guest invitations when disabled guest invitation metadata is cleared")
        try expect(clearedProviderMetadataDetachedPayload["guestsCanModify"] as? Bool == false,
                   "Google detached write should explicitly disable guest modifications when guest modification metadata is cleared")
        try expect(clearedProviderMetadataDetachedPayload["source"] is NSNull,
                   "Google detached write should explicitly clear stale remote source URL with source null")

        var clearedSeriesEvent = event
        clearedSeriesEvent.attendees = []
        clearedSeriesEvent.recurrenceFrequency = .none
        clearedSeriesEvent.recurrenceWeekdays = []
        clearedSeriesEvent.recurrenceWeekStart = nil
        clearedSeriesEvent.recurrenceSetPositions = []
        clearedSeriesEvent.recurrenceOrdinal = nil
        clearedSeriesEvent.recurrenceOrdinalWeekday = nil
        clearedSeriesEvent.recurrenceMonthDay = nil
        clearedSeriesEvent.recurrenceMonths = []
        clearedSeriesEvent.recurrenceEndDate = nil
        clearedSeriesEvent.additionalOccurrenceStartDates = []
        clearedSeriesEvent.excludedOccurrenceStartDates = []
        clearedSeriesEvent.detachedOccurrences = []
        let clearedSeriesPayload = try jsonObject(client.encodedWritePayloadPreview(for: clearedSeriesEvent))
        try expect(try stringArray(clearedSeriesPayload["recurrence"], context: "Google cleared recurrence").isEmpty,
                   "Google write should explicitly clear remote recurrence with an empty recurrence array")
        try expect(try array(clearedSeriesPayload["attendees"], context: "Google cleared attendees").isEmpty,
                   "Google write should explicitly clear remote attendees with an empty attendee array")

        var clearedDetached = detached
        clearedDetached.attendees = []
        let clearedDetachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: clearedDetached))
        try expect(try array(clearedDetachedPayload["attendees"], context: "Google cleared detached attendees").isEmpty,
                   "Google detached write should explicitly clear remote attendees with an empty attendee array")
        try expect(clearedDetachedPayload["recurrence"] == nil,
                   "Google detached write should still omit recurrence because instances cannot own recurrence rules")

        var fiveReminderEvent = event
        fiveReminderEvent.reminderOffsets = [5, 10, 15, 30, 60]
        let fiveReminderPayload = try jsonObject(client.encodedWritePayloadPreview(for: fiveReminderEvent))
        try expect(try reminderMinutes(in: fiveReminderPayload, context: "Google five-reminder event") == [5, 10, 15, 30, 60],
                   "Google write should preserve all five supported reminder overrides")

        var tooManyReminderEvent = event
        tooManyReminderEvent.reminderOffsets = [1, 2, 3, 4, 5, 6]
        do {
            _ = try client.encodedWritePayloadPreview(for: tooManyReminderEvent)
            throw ProviderWritePayloadInvariantError("Google write should reject more than five reminders instead of dropping extras")
        } catch GoogleCalendarClientError.unsupportedReminderOverrides(let offsets) {
            try expect(offsets == [1, 2, 3, 4, 5, 6], "Google reminder rejection should report normalized reminder offsets")
        }

        var tooManyReminderDetached = detached
        tooManyReminderDetached.reminderOffsets = [1, 2, 3, 4, 5, 6]
        do {
            _ = try client.encodedDetachedOccurrencePayloadPreview(for: tooManyReminderDetached)
            throw ProviderWritePayloadInvariantError("Google detached write should reject more than five reminders instead of dropping extras")
        } catch GoogleCalendarClientError.unsupportedReminderOverrides(let offsets) {
            try expect(offsets == [1, 2, 3, 4, 5, 6], "Google detached reminder rejection should report normalized reminder offsets")
        }

        var tooManyAttachmentEvent = event
        tooManyAttachmentEvent.attachments = (0..<26).map { index in
            LocalEventAttachment(urlString: "https://drive.google.com/file/d/google-provider-write-\(index)/view")
        }
        do {
            _ = try client.encodedWritePayloadPreview(for: tooManyAttachmentEvent)
            throw ProviderWritePayloadInvariantError("Google write should reject more than 25 attachments instead of dropping extras")
        } catch GoogleCalendarClientError.unsupportedAttachmentCount(let count) {
            try expect(count == 26, "Google attachment rejection should report the normalized attachment count")
        }

        let monthDayEvent = try monthlyNegativeMonthDayEvent(
            id: "local-event-provider-write-google-negative-month-day",
            calendarID: event.calendarID,
            title: "Google negative month day fixture"
        )
        let monthDayPayload = try jsonObject(client.encodedWritePayloadPreview(for: monthDayEvent))
        let monthDayRecurrence = try stringArray(monthDayPayload["recurrence"], context: "Google negative month-day recurrence")
        try expect(
            monthDayRecurrence.contains { $0.contains("FREQ=MONTHLY") && $0.contains("BYMONTHDAY=-1") },
            "Google write should preserve negative BYMONTHDAY recurrence rules"
        )

        let yearlyMonthDayEvent = try yearlyNegativeMonthDayEvent(
            id: "local-event-provider-write-google-yearly-negative-month-day",
            calendarID: event.calendarID,
            title: "Google yearly negative month day fixture"
        )
        let yearlyMonthDayPayload = try jsonObject(client.encodedWritePayloadPreview(for: yearlyMonthDayEvent))
        let yearlyMonthDayRecurrence = try stringArray(yearlyMonthDayPayload["recurrence"], context: "Google yearly negative month-day recurrence")
        try expect(
            yearlyMonthDayRecurrence.contains { $0.contains("FREQ=YEARLY") && $0.contains("BYMONTH=2") && $0.contains("BYMONTHDAY=-1") },
            "Google write should preserve yearly negative BYMONTHDAY recurrence rules"
        )

        let yearlyByMonthEvent = try yearlyByMonthEvent(
            id: "local-event-provider-write-google-yearly-bymonth",
            calendarID: event.calendarID,
            title: "Google yearly BYMONTH fixture"
        )
        let yearlyByMonthPayload = try jsonObject(client.encodedWritePayloadPreview(for: yearlyByMonthEvent))
        let yearlyByMonthRecurrence = try stringArray(yearlyByMonthPayload["recurrence"], context: "Google yearly BYMONTH recurrence")
        try expect(
            yearlyByMonthRecurrence.contains { $0.contains("FREQ=YEARLY") && $0.contains("BYMONTH=1,4,7,10") && $0.contains("BYMONTHDAY=5") },
            "Google write should preserve yearly multi-month BYMONTH recurrence rules"
        )

        let monthlyByMonthEvent = try monthlyByMonthEvent(
            id: "local-event-provider-write-google-monthly-bymonth",
            calendarID: event.calendarID,
            title: "Google monthly BYMONTH fixture"
        )
        let monthlyByMonthPayload = try jsonObject(client.encodedWritePayloadPreview(for: monthlyByMonthEvent))
        let monthlyByMonthRecurrence = try stringArray(monthlyByMonthPayload["recurrence"], context: "Google monthly BYMONTH recurrence")
        try expect(
            monthlyByMonthRecurrence.contains { $0.contains("FREQ=MONTHLY") && $0.contains("BYMONTH=1,4,7,10") && $0.contains("BYMONTHDAY=5") },
            "Google write should preserve monthly multi-month BYMONTH recurrence rules"
        )

        let weekStartEvent = try weeklyWeekStartEvent(
            id: "local-event-provider-write-google-week-start",
            calendarID: event.calendarID,
            title: "Google WKST fixture"
        )
        let weekStartPayload = try jsonObject(client.encodedWritePayloadPreview(for: weekStartEvent))
        let weekStartRecurrence = try stringArray(weekStartPayload["recurrence"], context: "Google weekly WKST recurrence")
        try expect(
            weekStartRecurrence.contains { $0.contains("FREQ=WEEKLY") && $0.contains("WKST=MO") },
            "Google write should preserve weekly recurrence week start"
        )

        let weeklySetPositionEvent = try weeklySetPositionEvent(
            id: "local-event-provider-write-google-weekly-set-position",
            calendarID: event.calendarID,
            title: "Google weekly BYSETPOS fixture"
        )
        let weeklySetPositionPayload = try jsonObject(client.encodedWritePayloadPreview(for: weeklySetPositionEvent))
        let weeklySetPositionRecurrence = try stringArray(
            weeklySetPositionPayload["recurrence"],
            context: "Google weekly BYSETPOS recurrence"
        )
        try expect(
            weeklySetPositionRecurrence.contains { $0.contains("FREQ=WEEKLY") && $0.contains("BYDAY=MO,WE") && $0.contains("BYSETPOS=-1") },
            "Google write should preserve weekly BYSETPOS recurrence rules"
        )

        let allDayEvent = try allDayRecurringEvent(
            id: "local-event-provider-write-google-all-day",
            calendarID: event.calendarID,
            title: "Google all-day fixture",
            includeAdditionalOccurrences: true
        )
        let allDayPayload = try jsonObject(client.encodedWritePayloadPreview(for: allDayEvent))
        let allDayRecurrence = try stringArray(allDayPayload["recurrence"], context: "Google all-day recurrence")
        try expect(try nestedString(allDayPayload, "start", "date") == "2026-07-01", "Google all-day write should preserve start date in the event timezone")
        try expect(try nestedString(allDayPayload, "end", "date") == "2026-07-02", "Google all-day write should preserve exclusive end date in the event timezone")
        try expect(try nestedString(allDayPayload, "start", "dateTime") == nil, "Google all-day write should not send a timed start")
        try expect(try nestedString(allDayPayload, "start", "timeZone") == nil, "Google all-day write should not send a start timezone field")
        try expect(allDayRecurrence.contains { $0.contains("UNTIL=20260722") }, "Google all-day write should preserve date-only recurrence UNTIL in the event timezone")
        try expect(allDayRecurrence.contains("RDATE;VALUE=DATE:20260718"), "Google all-day write should preserve date-only RDATE")
        try expect(allDayRecurrence.contains("EXDATE;VALUE=DATE:20260715"), "Google all-day write should preserve date-only EXDATE")

        let weeklyFallbackEvent = try allDayWeeklyFallbackEvent(
            id: "local-event-provider-write-google-weekly-fallback",
            calendarID: event.calendarID,
            title: "Google weekly fallback fixture"
        )
        let weeklyFallbackPayload = try jsonObject(client.encodedWritePayloadPreview(for: weeklyFallbackEvent))
        let weeklyFallbackRecurrence = try stringArray(weeklyFallbackPayload["recurrence"], context: "Google weekly fallback recurrence")
        try expect(
            weeklyFallbackRecurrence.contains { $0.contains("FREQ=WEEKLY") && $0.contains("BYDAY=MO") },
            "Google weekly fallback should derive BYDAY from the event timezone"
        )
        try expect(
            !weeklyFallbackRecurrence.contains { $0.contains("BYDAY=SU") },
            "Google weekly fallback should not derive BYDAY from UTC/current timezone"
        )

        let allDayDetached = try requireOnlyDetachedOccurrence(allDayEvent)
        let allDayDetachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: allDayDetached))
        try expect(try nestedString(allDayDetachedPayload, "start", "date") == "2026-07-09", "Google all-day detached write should preserve moved start date")
        try expect(try nestedString(allDayDetachedPayload, "end", "date") == "2026-07-10", "Google all-day detached write should preserve moved exclusive end date")
        try expect(try nestedString(allDayDetachedPayload, "start", "dateTime") == nil, "Google all-day detached write should not send a timed start")
    }

    private static func verifyGoogleResponsePatchPayload() throws {
        let account = CalendarProviderAccount(
            id: "google-response-patch-fixture",
            kind: .googleCalendar,
            title: "SMTP:ME%40example.com",
            endpointURLString: "https://www.googleapis.com/calendar/v3",
            username: nil,
            identityEmail: "primary@example.com",
            identityEmailAliases: [],
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
        let events = try googleEvents("""
        [
          {
            "id": "google-response-patch-1",
            "status": "confirmed",
            "summary": "Google response patch fixture",
            "iCalUID": "google-response-patch@example.com",
            "updated": "2026-06-25T08:00:00Z",
            "start": { "dateTime": "2026-07-03T16:00:00+03:00", "timeZone": "Asia/Nicosia" },
            "end": { "dateTime": "2026-07-03T16:30:00+03:00", "timeZone": "Asia/Nicosia" },
            "attendees": [
              { "email": "me@example.com", "displayName": "Me", "responseStatus": "needsAction" },
              { "email": "teammate@example.com", "displayName": "Teammate", "responseStatus": "accepted", "optional": true },
              { "email": "cy-office-1st-conference@resource.calendar.google.com", "displayName": "CY-Office-1st-Conference", "responseStatus": "accepted", "resource": true }
            ]
          }
        ]
        """)
        guard events.count == 1, let event = events.first else {
            throw ProviderWritePayloadInvariantError("Expected exactly one Google response patch event, got \(events.count)")
        }

        let payload = try jsonObject(GoogleCalendarClient().encodedResponsePatchPayloadPreview(
            event: event,
            calendarID: "opaque-google-calendar-id",
            account: account,
            response: .maybe
        ))
        try expect(payload["attendeesOmitted"] as? Bool == true,
                   "Google RSVP patch should set attendeesOmitted so only my response is updated")
        let attendees = try array(payload["attendees"], context: "Google RSVP patch attendees")
        try expect(attendees.count == 1,
                   "Google RSVP patch should include only the current user's attendee entry")
        let attendee = try dictionary(attendees.first, context: "Google RSVP patch attendee")
        try expect(attendee["email"] as? String == "me@example.com",
                   "Google RSVP patch should target the current user attendee from a normalized SMTP fallback identity")
        try expect(attendee["responseStatus"] as? String == "tentative",
                   "Google Maybe response should be written as tentative")
        try expect(!attendees.contains { value in
            (try? dictionary(value, context: "Google RSVP non-current attendee"))?["email"] as? String == "teammate@example.com"
        }, "Google RSVP patch should not rewrite teammate attendee state")
        try expect(!attendees.contains { value in
            (try? dictionary(value, context: "Google RSVP room attendee"))?["email"] as? String == "cy-office-1st-conference@resource.calendar.google.com"
        }, "Google RSVP patch should not rewrite resource attendee state")
    }

    private static func verifyGoogleRecurringExceptionWritePlan() throws {
        var event = try recurringEvent(
            id: "local-event-provider-write-google-exception-plan",
            calendarID: "local-calendar-google-provider-write",
            title: "Google exception write plan fixture",
            urlString: "https://meet.google.com/exception-plan",
            includeAdditionalOccurrences: false
        )
        event.excludedOccurrenceStartDates.append(try date("2026-07-22T06:00:00Z"))
        event.excludedOccurrenceStartDates.append(try date("2026-07-29T06:00:00Z"))

        let instances = try googleEvents("""
        [
          {
            "id": "google-detached-20260708",
            "etag": "\\"detached-etag\\"",
            "status": "confirmed",
            "recurringEventId": "google-master",
            "originalStartTime": {
              "dateTime": "2026-07-08T09:00:00+03:00",
              "timeZone": "Asia/Nicosia"
            },
            "start": {
              "dateTime": "2026-07-08T10:00:00+03:00",
              "timeZone": "Asia/Nicosia"
            },
            "end": {
              "dateTime": "2026-07-08T10:45:00+03:00",
              "timeZone": "Asia/Nicosia"
            }
          },
          {
            "id": "google-excluded-live-20260715",
            "etag": "\\"excluded-live-etag\\"",
            "status": "confirmed",
            "recurringEventId": "google-master",
            "originalStartTime": {
              "dateTime": "2026-07-15T09:00:00+03:00",
              "timeZone": "Asia/Nicosia"
            },
            "start": {
              "dateTime": "2026-07-15T09:00:00+03:00",
              "timeZone": "Asia/Nicosia"
            },
            "end": {
              "dateTime": "2026-07-15T09:30:00+03:00",
              "timeZone": "Asia/Nicosia"
            }
          },
          {
            "id": "google-excluded-cancelled-20260722",
            "etag": "\\"excluded-cancelled-etag\\"",
            "status": "cancelled",
            "recurringEventId": "google-master",
            "originalStartTime": {
              "dateTime": "2026-07-22T09:00:00+03:00",
              "timeZone": "Asia/Nicosia"
            }
          }
        ]
        """)

        let plan = try GoogleCalendarClient().recurringExceptionWritePlanPreview(for: event, instances: instances)
        try expect(plan.occurrenceIDsToDelete == ["google-excluded-live-20260715"],
                   "Google write-back should delete live excluded instances without failing on already-missing exclusions")
        try expect(plan.occurrenceIDsToPatch == ["google-detached-20260708"],
                   "Google write-back should patch detached instances by their provider instance ID")
    }

    private static func verifyMicrosoftRecurringWritePayloads() throws {
        let event = try recurringEvent(
            id: "local-event-provider-write-microsoft",
            calendarID: "local-calendar-microsoft-provider-write",
            title: "Microsoft provider write fixture",
            urlString: "https://teams.microsoft.com/l/meetup-join/write-fixture",
            categories: [
                "Customer",
                "Launch",
                "Microsoft attendees hidden",
                "Microsoft new time proposals disabled",
                "Microsoft onlineMeetingProvider teamsForBusiness",
                "Microsoft location 1 name CY-Office-1st-Conference",
                "Microsoft location 1 type conferenceRoom",
                "Microsoft location 1 email cy-office-1st-conference@example.com",
                "Microsoft location 1 unique id room-cy-1",
                "Microsoft location 1 unique id type directory"
            ],
            includeAdditionalOccurrences: false
        )
        let client = MicrosoftGraphCalendarClient()
        let basePayload = try jsonObject(client.encodedWritePayloadPreview(for: event))
        let recurrence = try dictionary(basePayload["recurrence"], context: "Microsoft recurrence")
        let pattern = try dictionary(recurrence["pattern"], context: "Microsoft recurrence pattern")
        let range = try dictionary(recurrence["range"], context: "Microsoft recurrence range")

        try expect(basePayload["subject"] as? String == "Microsoft provider write fixture", "Microsoft base write should preserve title")
        try expect(basePayload["body"] == nil,
                   "Microsoft patch should omit body for existing online meetings so Graph can preserve the meeting blob")
        try expect(basePayload["isOnlineMeeting"] == nil,
                   "Microsoft patch should not rewrite immutable online meeting state")
        try expect(basePayload["onlineMeetingProvider"] == nil,
                   "Microsoft patch should not rewrite immutable online meeting provider state")
        let insertPayload = try jsonObject(client.encodedInsertPayloadPreview(for: event, transactionID: "provider-write-insert"))
        try expect(try nestedString(insertPayload, "body", "content")?.contains("https://teams.microsoft.com/l/meetup-join/write-fixture") == true,
                   "Microsoft insert should still include body content for new events")
        try expect(insertPayload["isOnlineMeeting"] as? Bool == true,
                   "Microsoft insert should create a native online meeting when provider metadata is present")
        try expect(insertPayload["onlineMeetingProvider"] as? String == "teamsForBusiness",
                   "Microsoft insert should preserve the native online meeting provider")
        try expect(insertPayload["hideAttendees"] as? Bool == true,
                   "Microsoft insert should preserve hidden-attendees metadata")
        try expect(insertPayload["allowNewTimeProposals"] as? Bool == false,
                   "Microsoft insert should preserve disabled new-time-proposals metadata")
        var attachmentEvent = event
        attachmentEvent.attachments = [
            LocalEventAttachment(
                urlString: "https://contoso.sharepoint.com/sites/customer/Shared%20Documents/Agenda.pdf",
                formatType: "application/pdf",
                displayName: "Agenda"
            ),
            LocalEventAttachment(
                urlString: "https://contoso.sharepoint.com/sites/customer/Shared%20Documents/Customer%20brief.docx",
                formatType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            )
        ]
        let existingAttachment = MicrosoftGraphAttachment(
            odataType: "#microsoft.graph.referenceAttachment",
            id: "existing-agenda",
            name: "Agenda",
            contentType: "application/pdf",
            isInline: false,
            size: nil,
            lastModifiedDateTime: nil,
            sourceUrl: "https://contoso.sharepoint.com/sites/customer/Shared%20Documents/Agenda.pdf"
        )
        let attachmentPayloads = try client.encodedReferenceAttachmentPayloadPreviews(
            for: attachmentEvent,
            existingAttachments: [existingAttachment]
        )
        try expect(attachmentPayloads.count == 1,
                   "Microsoft attachment write-back should skip reference attachments already present on the remote event")
        let attachmentPayload = try jsonObject(attachmentPayloads[0])
        try expect(attachmentPayload["@odata.type"] as? String == "#microsoft.graph.referenceAttachment",
                   "Microsoft attachment write-back should create Graph referenceAttachment payloads")
        try expect(attachmentPayload["sourceUrl"] as? String == "https://contoso.sharepoint.com/sites/customer/Shared%20Documents/Customer%20brief.docx",
                   "Microsoft attachment write-back should preserve local attachment sourceUrl")
        try expect(attachmentPayload["contentType"] as? String == "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                   "Microsoft attachment write-back should preserve local attachment MIME type")
        try expect(attachmentPayload["name"] as? String == "Customer brief.docx",
                   "Microsoft attachment write-back should derive a required referenceAttachment name when local displayName is blank")
        let attachmentEndpointAccount = CalendarProviderAccount(
            id: "microsoft-attachment-write-fixture",
            kind: .microsoft365,
            title: "Microsoft Attachment Write Fixture",
            endpointURLString: "https://graph.microsoft.com/v1.0",
            username: nil,
            identityEmail: "me@example.com",
            identityEmailAliases: [],
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
        let attachmentEndpoint = try client.referenceAttachmentsURLPreview(
            account: attachmentEndpointAccount,
            calendarID: "calendar with spaces%2Fplus+id",
            eventID: "event/id%2Fplus+id"
        )
        try expect(attachmentEndpoint.absoluteString == "https://graph.microsoft.com/v1.0/me/calendars/calendar%20with%20spaces%252Fplus%2Bid/events/event%2Fid%252Fplus%2Bid/attachments",
                   "Microsoft attachment write-back should target the event attachments collection endpoint")
        var structuredMetadataEvent = event
        structuredMetadataEvent.relatedEvents = [
            LocalEventRelationship(relationType: "PARENT", externalUID: "parent-microsoft-provider-write@example.com"),
            LocalEventRelationship(relationType: "SIBLING", externalUID: "sibling-microsoft-provider-write@example.com")
        ]
        structuredMetadataEvent.geoCoordinate = LocalEventGeoCoordinate(latitude: 35.1855659, longitude: 33.3822764)
        let workingCalendarExtensionPayload = try jsonObject(client.encodedWorkingCalendarExtensionPayloadPreview(for: structuredMetadataEvent))
        try expect(workingCalendarExtensionPayload["@odata.type"] as? String == "#microsoft.graph.openTypeExtension",
                   "Microsoft structured metadata write-back should use a Graph openTypeExtension")
        try expect(workingCalendarExtensionPayload["extensionName"] as? String == "dev.codex.workingCalendar",
                   "Microsoft structured metadata write-back should use the Working Calendar extension name")
        try expect(
            try microsoftRelatedEvents(in: workingCalendarExtensionPayload, context: "Microsoft structured metadata") == structuredMetadataEvent.relatedEvents,
            "Microsoft structured metadata write-back should preserve RELATED-TO relationships"
        )
        try expect(
            try microsoftGeoCoordinate(in: workingCalendarExtensionPayload, context: "Microsoft structured metadata") == structuredMetadataEvent.geoCoordinate,
            "Microsoft structured metadata write-back should preserve GEO coordinates"
        )
        let extensionEndpoint = try client.workingCalendarExtensionURLPreview(
            account: attachmentEndpointAccount,
            calendarID: "calendar with spaces%2Fplus+id",
            eventID: "event/id%2Fplus+id"
        )
        try expect(extensionEndpoint.absoluteString == "https://graph.microsoft.com/v1.0/me/calendars/calendar%20with%20spaces%252Fplus%2Bid/events/event%2Fid%252Fplus%2Bid/extensions/dev.codex.workingCalendar",
                   "Microsoft structured metadata write-back should target the event open extension endpoint")
        try expect(try nestedString(basePayload, "location", "displayName") == "CY-Office-1st-Conference", "Microsoft base write should preserve location")
        try expect(try nestedString(basePayload, "location", "locationType") == "conferenceRoom",
                   "Microsoft base write should preserve room location type metadata")
        try expect(try nestedString(basePayload, "location", "locationEmailAddress") == "cy-office-1st-conference@example.com",
                   "Microsoft base write should preserve room location email metadata")
        try expect(try nestedString(basePayload, "location", "uniqueId") == "room-cy-1",
                   "Microsoft base write should preserve room unique id metadata")
        try expect(try nestedString(basePayload, "location", "uniqueIdType") == "directory",
                   "Microsoft base write should preserve room unique id type metadata")
        try expect(try graphLocationNames(in: basePayload, context: "Microsoft base locations") == ["CY-Office-1st-Conference"],
                   "Microsoft base write should preserve the locations collection alongside primary location")
        let baseLocation = try dictionary(
            try array(basePayload["locations"], context: "Microsoft base locations").first,
            context: "Microsoft base location metadata"
        )
        try expect(baseLocation["locationType"] as? String == "conferenceRoom",
                   "Microsoft locations collection should preserve room location type metadata")
        try expect(baseLocation["locationEmailAddress"] as? String == "cy-office-1st-conference@example.com",
                   "Microsoft locations collection should preserve room email metadata")
        try expect(basePayload["responseRequested"] as? Bool == true,
                   "Microsoft base write should request responses when any person attendee has RSVP enabled")
        try expect(basePayload["hideAttendees"] as? Bool == true,
                   "Microsoft base write should preserve hidden-attendees metadata")
        try expect(basePayload["allowNewTimeProposals"] as? Bool == false,
                   "Microsoft base write should preserve disabled new-time-proposals metadata")
        try expect(basePayload["sensitivity"] as? String == "private", "Microsoft base write should preserve privacy")
        try expect(basePayload["showAs"] as? String == "busy", "Microsoft base write should preserve busy availability")
        try expect(basePayload["isReminderOn"] as? Bool == true, "Microsoft base write should enable a single reminder")
        try expect(basePayload["reminderMinutesBeforeStart"] as? Int == 10, "Microsoft base write should preserve a single reminder offset")
        try expect(
            try stringArray(basePayload["categories"], context: "Microsoft base categories") == ["Customer", "Launch"],
            "Microsoft base write should explicitly preserve writable Outlook categories without provider metadata"
        )
        try expect(pattern["type"] as? String == "weekly", "Microsoft base write should preserve weekly recurrence")
        try expect(try stringArray(pattern["daysOfWeek"], context: "Microsoft recurrence weekdays") == ["wednesday"], "Microsoft base write should preserve recurrence weekday")
        try expect(range["type"] as? String == "endDate", "Microsoft base write should preserve finite recurrence range")
        try expect(range["recurrenceTimeZone"] as? String == "GTB Standard Time", "Microsoft base write should preserve recurrence timezone as a Graph-compatible Windows timezone")
        try expect(
            try attendee(basePayload, email: "cy-office-1st-conference@example.com")["type"] as? String == "resource",
            "Microsoft base write should preserve room/resource attendees"
        )
        var multiLocationEvent = event
        multiLocationEvent.location = "CY-Office-1st-Conference; Overflow Room; cy-office-1st-conference"
        let multiLocationPayload = try jsonObject(client.encodedWritePayloadPreview(for: multiLocationEvent))
        try expect(try nestedString(multiLocationPayload, "location", "displayName") == "CY-Office-1st-Conference",
                   "Microsoft multi-location write should keep the first location as the primary Graph location")
        try expect(try graphLocationNames(in: multiLocationPayload, context: "Microsoft multi locations") == ["CY-Office-1st-Conference", "Overflow Room"],
                   "Microsoft multi-location write should restore Graph locations from the local semicolon-separated location text")

        var clearedTextEvent = event
        clearedTextEvent.location = "   "
        clearedTextEvent.notes = " \n\t "
        clearedTextEvent.urlString = ""
        let clearedTextPayload = try jsonObject(client.encodedWritePayloadPreview(for: clearedTextEvent))
        try expect(try nestedString(clearedTextPayload, "location", "displayName") == "",
                   "Microsoft write should explicitly clear remote location with an empty displayName")
        try expect(try graphLocationNames(in: clearedTextPayload, context: "Microsoft cleared locations").isEmpty,
                   "Microsoft write should explicitly clear stale Graph locations with an empty locations array")
        try expect(try nestedString(clearedTextPayload, "body", "contentType") == "text",
                   "Microsoft write should include a text body when clearing remote body")
        try expect(try nestedString(clearedTextPayload, "body", "content") == "",
                   "Microsoft write should explicitly clear remote body content with an empty string")
        var clearedReminderEvent = event
        clearedReminderEvent.reminderOffsets = []
        let clearedReminderPayload = try jsonObject(client.encodedWritePayloadPreview(for: clearedReminderEvent))
        try expect(clearedReminderPayload["isReminderOn"] as? Bool == false,
                   "Microsoft write should explicitly disable remote reminders when local reminders are cleared")
        try expect(clearedReminderPayload["reminderMinutesBeforeStart"] == nil,
                   "Microsoft write should omit stale reminder minutes when reminders are disabled")

        var clearedRecurrenceEvent = event
        clearedRecurrenceEvent.recurrenceFrequency = .none
        clearedRecurrenceEvent.recurrenceWeekdays = []
        clearedRecurrenceEvent.recurrenceWeekStart = nil
        clearedRecurrenceEvent.recurrenceSetPositions = []
        clearedRecurrenceEvent.recurrenceOrdinal = nil
        clearedRecurrenceEvent.recurrenceOrdinalWeekday = nil
        clearedRecurrenceEvent.recurrenceMonthDay = nil
        clearedRecurrenceEvent.recurrenceMonths = []
        clearedRecurrenceEvent.recurrenceEndDate = nil
        clearedRecurrenceEvent.additionalOccurrenceStartDates = []
        clearedRecurrenceEvent.excludedOccurrenceStartDates = []
        clearedRecurrenceEvent.detachedOccurrences = []
        let clearedRecurrencePayload = try jsonObject(client.encodedWritePayloadPreview(for: clearedRecurrenceEvent))
        try expect(clearedRecurrencePayload["recurrence"] is NSNull,
                   "Microsoft write should explicitly clear remote recurrence with recurrence null")

        var clearedAttendeesEvent = event
        clearedAttendeesEvent.attendees = []
        let clearedAttendeesPayload = try jsonObject(client.encodedWritePayloadPreview(for: clearedAttendeesEvent))
        try expect(
            try array(clearedAttendeesPayload["attendees"], context: "Microsoft cleared attendees").isEmpty,
            "Microsoft write should explicitly clear remote attendees with an empty attendee array"
        )
        try expect(clearedAttendeesPayload["responseRequested"] as? Bool == false,
                   "Microsoft write should clear responseRequested when there are no attendee RSVP requests")

        let showAsMetadataEvent = try recurringEvent(
            id: "local-event-provider-write-microsoft-show-as",
            calendarID: event.calendarID,
            title: "Microsoft show-as metadata fixture",
            urlString: "https://teams.microsoft.com/l/meetup-join/show-as-fixture",
            categories: ["Microsoft showAs oof", "Customer"],
            includeAdditionalOccurrences: false
        )
        let showAsMetadataPayload = try jsonObject(client.encodedWritePayloadPreview(for: showAsMetadataEvent))
        try expect(showAsMetadataPayload["showAs"] as? String == "oof",
                   "Microsoft write should restore provider showAs metadata")
        try expect(showAsMetadataPayload["hideAttendees"] as? Bool == false,
                   "Microsoft write should explicitly clear hidden-attendees state when metadata is absent")
        try expect(
            try stringArray(showAsMetadataPayload["categories"], context: "Microsoft showAs metadata categories") == ["Customer"],
            "Microsoft write should not send provider showAs metadata as an Outlook category"
        )

        let showAsOnlyMetadataEvent = try recurringEvent(
            id: "local-event-provider-write-microsoft-show-as-only",
            calendarID: event.calendarID,
            title: "Microsoft show-as-only metadata fixture",
            urlString: "https://teams.microsoft.com/l/meetup-join/show-as-only-fixture",
            categories: ["Microsoft showAs oof"],
            includeAdditionalOccurrences: false
        )
        let showAsOnlyMetadataPayload = try jsonObject(client.encodedWritePayloadPreview(for: showAsOnlyMetadataEvent))
        try expect(showAsOnlyMetadataPayload["showAs"] as? String == "oof",
                   "Microsoft write should restore provider showAs metadata when no writable categories remain")
        try expect(
            try stringArray(showAsOnlyMetadataPayload["categories"], context: "Microsoft showAs-only metadata categories").isEmpty,
            "Microsoft write should explicitly clear Outlook categories when only provider metadata remains"
        )

        let personalSensitivityMetadataEvent = try recurringEvent(
            id: "local-event-provider-write-microsoft-personal-sensitivity",
            calendarID: event.calendarID,
            title: "Microsoft personal sensitivity metadata fixture",
            urlString: "https://teams.microsoft.com/l/meetup-join/personal-sensitivity-fixture",
            categories: ["Microsoft sensitivity personal", "Customer"],
            includeAdditionalOccurrences: false
        )
        let personalSensitivityMetadataPayload = try jsonObject(client.encodedWritePayloadPreview(for: personalSensitivityMetadataEvent))
        try expect(personalSensitivityMetadataPayload["sensitivity"] as? String == "personal",
                   "Microsoft write should restore provider personal sensitivity metadata")
        try expect(
            try stringArray(personalSensitivityMetadataPayload["categories"], context: "Microsoft personal sensitivity metadata categories") == ["Customer"],
            "Microsoft write should not send provider sensitivity metadata as an Outlook category"
        )

        let enabledNewTimeProposalsEvent = try recurringEvent(
            id: "local-event-provider-write-microsoft-enabled-time-proposals",
            calendarID: event.calendarID,
            title: "Microsoft enabled time proposals metadata fixture",
            urlString: "https://teams.microsoft.com/l/meetup-join/enabled-time-proposals-fixture",
            categories: ["Microsoft new time proposals enabled", "Customer"],
            includeAdditionalOccurrences: false
        )
        let enabledNewTimeProposalsPayload = try jsonObject(client.encodedWritePayloadPreview(for: enabledNewTimeProposalsEvent))
        try expect(enabledNewTimeProposalsPayload["allowNewTimeProposals"] as? Bool == true,
                   "Microsoft write should support explicitly re-enabling new time proposals")
        try expect(
            try stringArray(enabledNewTimeProposalsPayload["categories"], context: "Microsoft enabled new-time-proposals categories") == ["Customer"],
            "Microsoft write should not send new-time-proposals provider metadata as an Outlook category"
        )

        let outlookDisallowCounterImport = try LocalCalendarICSCodec.import(outlookDisallowCounterICS)
        let outlookDisallowCounterEvent = try requireOnly(
            outlookDisallowCounterImport.events,
            context: "Outlook disallow-counter provider write import"
        )
        let outlookDisallowCounterPayload = try jsonObject(client.encodedWritePayloadPreview(for: outlookDisallowCounterEvent))
        try expect(outlookDisallowCounterPayload["allowNewTimeProposals"] as? Bool == false,
                   "Microsoft write should restore Graph allowNewTimeProposals=false from imported Outlook disallow-counter metadata")
        try expect(
            try stringArray(outlookDisallowCounterPayload["categories"], context: "Outlook disallow-counter provider write categories").isEmpty,
            "Microsoft write should not send imported Outlook disallow-counter metadata as a writable category"
        )

        var tentativeEvent = try recurringEvent(
            id: "local-event-provider-write-microsoft-tentative",
            calendarID: event.calendarID,
            title: "Microsoft tentative status fixture",
            urlString: "https://teams.microsoft.com/l/meetup-join/tentative-fixture",
            includeAdditionalOccurrences: false
        )
        tentativeEvent.status = .tentative
        let tentativePayload = try jsonObject(client.encodedWritePayloadPreview(for: tentativeEvent))
        try expect(tentativePayload["showAs"] as? String == "tentative",
                   "Microsoft write should restore tentative showAs from local event status")

        let detached = try requireOnlyDetachedOccurrence(event)
        let detachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: detached))
        try expect(detachedPayload["subject"] as? String == "Moved provider occurrence", "Microsoft detached write should preserve occurrence title")
        try expect(detachedPayload["recurrence"] == nil, "Microsoft detached write should not send a nested recurrence")
        try expect(detachedPayload["responseRequested"] as? Bool == false,
                   "Microsoft detached write should not request responses when no person attendee has RSVP enabled")
        try expect(try nestedString(detachedPayload, "start", "timeZone") == "GTB Standard Time", "Microsoft detached write should preserve occurrence timezone as a Graph-compatible Windows timezone")
        try expect(detachedPayload["isReminderOn"] as? Bool == true, "Microsoft detached write should enable a single reminder")
        try expect(detachedPayload["reminderMinutesBeforeStart"] as? Int == 5, "Microsoft detached write should preserve a single reminder offset")
        try expect(
            try stringArray(detachedPayload["categories"], context: "Microsoft detached categories") == ["Customer"],
            "Microsoft detached write should explicitly preserve writable Outlook categories"
        )
        var structuredMetadataDetached = detached
        structuredMetadataDetached.relatedEvents = [
            LocalEventRelationship(relationType: "PARENT", externalUID: "parent-microsoft-provider-detached-write@example.com"),
            LocalEventRelationship(relationType: "SIBLING", externalUID: "sibling-microsoft-provider-detached-write@example.com")
        ]
        structuredMetadataDetached.geoCoordinate = LocalEventGeoCoordinate(latitude: 35.1855659, longitude: 33.3822764)
        let detachedWorkingCalendarExtensionPayload = try jsonObject(
            client.encodedWorkingCalendarExtensionPayloadPreview(for: structuredMetadataDetached)
        )
        try expect(detachedWorkingCalendarExtensionPayload["@odata.type"] as? String == "#microsoft.graph.openTypeExtension",
                   "Microsoft detached structured metadata write-back should use a Graph openTypeExtension")
        try expect(detachedWorkingCalendarExtensionPayload["extensionName"] as? String == "dev.codex.workingCalendar",
                   "Microsoft detached structured metadata write-back should use the Working Calendar extension name")
        try expect(
            try microsoftRelatedEvents(in: detachedWorkingCalendarExtensionPayload, context: "Microsoft detached structured metadata") == structuredMetadataDetached.relatedEvents,
            "Microsoft detached structured metadata write-back should preserve occurrence RELATED-TO relationships"
        )
        try expect(
            try microsoftGeoCoordinate(in: detachedWorkingCalendarExtensionPayload, context: "Microsoft detached structured metadata") == structuredMetadataDetached.geoCoordinate,
            "Microsoft detached structured metadata write-back should preserve occurrence GEO coordinates"
        )
        var teamsDetached = detached
        teamsDetached.urlString = "https://teams.microsoft.com/l/meetup-join/detached"
        let teamsDetachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: teamsDetached))
        try expect(teamsDetachedPayload["body"] == nil,
                   "Microsoft detached patch should omit body for existing online meetings so Graph can preserve the meeting blob")

        var clearedTextDetached = detached
        clearedTextDetached.location = " \n "
        clearedTextDetached.notes = "\t"
        clearedTextDetached.urlString = ""
        let clearedTextDetachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: clearedTextDetached))
        try expect(try nestedString(clearedTextDetachedPayload, "location", "displayName") == "",
                   "Microsoft detached write should explicitly clear remote location with an empty displayName")
        try expect(try nestedString(clearedTextDetachedPayload, "body", "contentType") == "text",
                   "Microsoft detached write should include a text body when clearing remote body")
        try expect(try nestedString(clearedTextDetachedPayload, "body", "content") == "",
                   "Microsoft detached write should explicitly clear remote body content with an empty string")
        var clearedReminderDetached = detached
        clearedReminderDetached.reminderOffsets = []
        let clearedReminderDetachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: clearedReminderDetached))
        try expect(clearedReminderDetachedPayload["isReminderOn"] as? Bool == false,
                   "Microsoft detached write should explicitly disable remote reminders when local reminders are cleared")
        try expect(clearedReminderDetachedPayload["reminderMinutesBeforeStart"] == nil,
                   "Microsoft detached write should omit stale reminder minutes when reminders are disabled")

        var clearedAttendeesDetached = detached
        clearedAttendeesDetached.attendees = []
        let clearedAttendeesDetachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: clearedAttendeesDetached))
        try expect(
            try array(clearedAttendeesDetachedPayload["attendees"], context: "Microsoft cleared detached attendees").isEmpty,
            "Microsoft detached write should explicitly clear remote attendees with an empty attendee array"
        )
        try expect(clearedAttendeesDetachedPayload["responseRequested"] as? Bool == false,
                   "Microsoft detached write should clear responseRequested when detached attendees are cleared")

        var clearedDetached = detached
        clearedDetached.categories = ["Microsoft showAs oof"]
        let clearedDetachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: clearedDetached))
        try expect(clearedDetachedPayload["showAs"] as? String == "oof",
                   "Microsoft detached write should restore provider showAs metadata")
        try expect(
            try stringArray(clearedDetachedPayload["categories"], context: "Microsoft cleared detached categories").isEmpty,
            "Microsoft detached write should explicitly clear Outlook categories when only provider metadata remains"
        )
        var personalSensitivityDetached = detached
        personalSensitivityDetached.categories = ["Microsoft sensitivity personal"]
        let personalSensitivityDetachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: personalSensitivityDetached))
        try expect(personalSensitivityDetachedPayload["sensitivity"] as? String == "personal",
                   "Microsoft detached write should restore provider personal sensitivity metadata")
        try expect(
            try stringArray(personalSensitivityDetachedPayload["categories"], context: "Microsoft detached personal sensitivity categories").isEmpty,
            "Microsoft detached write should explicitly clear Outlook categories when only sensitivity provider metadata remains"
        )
        var disabledNewTimeProposalsDetached = detached
        disabledNewTimeProposalsDetached.categories = ["Microsoft new time proposals disabled", "Customer"]
        let disabledNewTimeProposalsDetachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: disabledNewTimeProposalsDetached))
        try expect(disabledNewTimeProposalsDetachedPayload["allowNewTimeProposals"] as? Bool == false,
                   "Microsoft detached write should preserve disabled new-time-proposals metadata")
        try expect(
            try stringArray(disabledNewTimeProposalsDetachedPayload["categories"], context: "Microsoft detached disabled new-time-proposals categories") == ["Customer"],
            "Microsoft detached write should not send new-time-proposals provider metadata as an Outlook category"
        )

        var multiReminderEvent = event
        multiReminderEvent.reminderOffsets = [5, 10]
        do {
            _ = try client.encodedWritePayloadPreview(for: multiReminderEvent)
            throw ProviderWritePayloadInvariantError("Microsoft write should reject multiple reminders instead of dropping all but one")
        } catch MicrosoftGraphCalendarClientError.unsupportedMultipleReminders(let offsets) {
            try expect(offsets == [5, 10], "Microsoft multiple-reminder rejection should report normalized reminder offsets")
        }

        var multiReminderDetached = detached
        multiReminderDetached.reminderOffsets = [5, 10]
        do {
            _ = try client.encodedDetachedOccurrencePayloadPreview(for: multiReminderDetached)
            throw ProviderWritePayloadInvariantError("Microsoft detached write should reject multiple reminders instead of dropping all but one")
        } catch MicrosoftGraphCalendarClientError.unsupportedMultipleReminders(let offsets) {
            try expect(offsets == [5, 10], "Microsoft detached multiple-reminder rejection should report normalized reminder offsets")
        }

        var unsupported = event
        unsupported.additionalOccurrenceStartDates = [try date("2026-07-18T06:00:00Z")]
        do {
            _ = try client.encodedWritePayloadPreview(for: unsupported)
            throw ProviderWritePayloadInvariantError("Microsoft write should reject extra RDATE occurrences instead of silently dropping them")
        } catch MicrosoftGraphCalendarClientError.unsupportedAdditionalOccurrences {
        }

        let monthDayEvent = try monthlyNegativeMonthDayEvent(
            id: "local-event-provider-write-microsoft-negative-month-day",
            calendarID: event.calendarID,
            title: "Microsoft negative month day fixture"
        )
        do {
            _ = try client.encodedWritePayloadPreview(for: monthDayEvent)
            throw ProviderWritePayloadInvariantError("Microsoft write should reject negative BYMONTHDAY rules instead of converting them to a different recurrence")
        } catch MicrosoftGraphCalendarClientError.unsupportedNegativeRecurrenceMonthDay(-1) {
        }

        let yearlyMonthDayEvent = try yearlyNegativeMonthDayEvent(
            id: "local-event-provider-write-microsoft-yearly-negative-month-day",
            calendarID: event.calendarID,
            title: "Microsoft yearly negative month day fixture"
        )
        do {
            _ = try client.encodedWritePayloadPreview(for: yearlyMonthDayEvent)
            throw ProviderWritePayloadInvariantError("Microsoft write should reject yearly negative BYMONTHDAY rules instead of converting them to a different recurrence")
        } catch MicrosoftGraphCalendarClientError.unsupportedNegativeRecurrenceMonthDay(-1) {
        }

        let yearlyByMonthEvent = try yearlyByMonthEvent(
            id: "local-event-provider-write-microsoft-yearly-bymonth",
            calendarID: event.calendarID,
            title: "Microsoft yearly BYMONTH fixture"
        )
        do {
            _ = try client.encodedWritePayloadPreview(for: yearlyByMonthEvent)
            throw ProviderWritePayloadInvariantError("Microsoft write should reject yearly multi-month BYMONTH rules instead of dropping allowed months")
        } catch MicrosoftGraphCalendarClientError.unsupportedYearlyRecurrenceMonths(let months) {
            try expect(months == [1, 4, 7, 10], "Microsoft yearly BYMONTH rejection should report the unsupported months")
        }

        let monthlyByMonthEvent = try monthlyByMonthEvent(
            id: "local-event-provider-write-microsoft-monthly-bymonth",
            calendarID: event.calendarID,
            title: "Microsoft monthly BYMONTH fixture"
        )
        do {
            _ = try client.encodedWritePayloadPreview(for: monthlyByMonthEvent)
            throw ProviderWritePayloadInvariantError("Microsoft write should reject monthly BYMONTH rules instead of dropping allowed months")
        } catch MicrosoftGraphCalendarClientError.unsupportedMonthlyRecurrenceMonths(let months) {
            try expect(months == [1, 4, 7, 10], "Microsoft monthly BYMONTH rejection should report the unsupported months")
        }

        let weeklySetPositionEvent = try weeklySetPositionEvent(
            id: "local-event-provider-write-microsoft-weekly-set-position",
            calendarID: event.calendarID,
            title: "Microsoft weekly BYSETPOS fixture"
        )
        do {
            _ = try client.encodedWritePayloadPreview(for: weeklySetPositionEvent)
            throw ProviderWritePayloadInvariantError("Microsoft write should reject weekly BYSETPOS rules instead of dropping set-position filters")
        } catch MicrosoftGraphCalendarClientError.unsupportedWeeklyRecurrenceSetPositions(let positions) {
            try expect(positions == [-1], "Microsoft weekly BYSETPOS rejection should report the unsupported positions")
        }

        let weekStartEvent = try weeklyWeekStartEvent(
            id: "local-event-provider-write-microsoft-week-start",
            calendarID: event.calendarID,
            title: "Microsoft WKST fixture"
        )
        let weekStartPayload = try jsonObject(client.encodedWritePayloadPreview(for: weekStartEvent))
        let weekStartRecurrence = try dictionary(weekStartPayload["recurrence"], context: "Microsoft weekly WKST recurrence")
        let weekStartPattern = try dictionary(weekStartRecurrence["pattern"], context: "Microsoft weekly WKST pattern")
        try expect(weekStartPattern["firstDayOfWeek"] as? String == "monday", "Microsoft write should preserve weekly recurrence week start")

        let allDayEvent = try allDayRecurringEvent(
            id: "local-event-provider-write-microsoft-all-day",
            calendarID: event.calendarID,
            title: "Microsoft all-day fixture",
            includeAdditionalOccurrences: false
        )
        let allDayPayload = try jsonObject(client.encodedWritePayloadPreview(for: allDayEvent))
        try expect(allDayPayload["isAllDay"] as? Bool == true, "Microsoft all-day write should mark the event as all-day")
        try expect(try nestedString(allDayPayload, "start", "dateTime") == "2026-07-01T00:00:00", "Microsoft all-day write should preserve local midnight start")
        try expect(try nestedString(allDayPayload, "end", "dateTime") == "2026-07-02T00:00:00", "Microsoft all-day write should preserve local midnight exclusive end")
        try expect(try nestedString(allDayPayload, "start", "timeZone") == "New Zealand Standard Time", "Microsoft all-day write should use a Graph-compatible timezone")
        let allDayRecurrence = try dictionary(allDayPayload["recurrence"], context: "Microsoft all-day recurrence")
        let allDayRange = try dictionary(allDayRecurrence["range"], context: "Microsoft all-day recurrence range")
        try expect(allDayRange["endDate"] as? String == "2026-07-22", "Microsoft all-day write should preserve recurrence end date in the event timezone")

        let weeklyFallbackEvent = try allDayWeeklyFallbackEvent(
            id: "local-event-provider-write-microsoft-weekly-fallback",
            calendarID: event.calendarID,
            title: "Microsoft weekly fallback fixture"
        )
        let weeklyFallbackPayload = try jsonObject(client.encodedWritePayloadPreview(for: weeklyFallbackEvent))
        let weeklyFallbackRecurrence = try dictionary(weeklyFallbackPayload["recurrence"], context: "Microsoft weekly fallback recurrence")
        let weeklyFallbackPattern = try dictionary(weeklyFallbackRecurrence["pattern"], context: "Microsoft weekly fallback pattern")
        try expect(
            try stringArray(weeklyFallbackPattern["daysOfWeek"], context: "Microsoft weekly fallback days") == ["monday"],
            "Microsoft weekly fallback should derive daysOfWeek from the event timezone"
        )

        let allDayDetached = try requireOnlyDetachedOccurrence(allDayEvent)
        let allDayDetachedPayload = try jsonObject(client.encodedDetachedOccurrencePayloadPreview(for: allDayDetached))
        try expect(allDayDetachedPayload["isAllDay"] as? Bool == true, "Microsoft all-day detached write should mark the occurrence as all-day")
        try expect(try nestedString(allDayDetachedPayload, "start", "dateTime") == "2026-07-09T00:00:00", "Microsoft all-day detached write should preserve moved local midnight start")
        try expect(try nestedString(allDayDetachedPayload, "end", "dateTime") == "2026-07-10T00:00:00", "Microsoft all-day detached write should preserve moved local midnight exclusive end")
    }

    private static func verifyMicrosoftRecurringExceptionWritePlan() throws {
        var event = try recurringEvent(
            id: "local-event-provider-write-microsoft-exception-plan",
            calendarID: "local-calendar-microsoft-provider-write",
            title: "Microsoft exception write plan fixture",
            urlString: "https://teams.microsoft.com/l/meetup-join/exception-plan",
            includeAdditionalOccurrences: false
        )
        event.excludedOccurrenceStartDates.append(try date("2026-07-22T06:00:00Z"))
        event.excludedOccurrenceStartDates.append(try date("2026-07-29T06:00:00Z"))

        let instances = try microsoftGraphEvents("""
        [
          {
            "id": "graph-detached-20260708",
            "changeKey": "detached-change-key",
            "type": "exception",
            "originalStart": "2026-07-08T06:00:00Z"
          },
          {
            "id": "graph-excluded-live-20260715",
            "changeKey": "excluded-live-change-key",
            "type": "occurrence",
            "isCancelled": false,
            "originalStart": "2026-07-15T06:00:00Z"
          },
          {
            "id": "graph-excluded-cancelled-20260722",
            "changeKey": "excluded-cancelled-change-key",
            "type": "occurrence",
            "isCancelled": true,
            "originalStart": "2026-07-22T06:00:00Z"
          }
        ]
        """)

        let plan = try MicrosoftGraphCalendarClient().recurringExceptionWritePlanPreview(for: event, instances: instances)
        try expect(plan.occurrenceIDsToDelete == ["graph-excluded-live-20260715"],
                   "Microsoft write-back should delete live excluded instances without failing on already-missing exclusions")
        try expect(plan.occurrenceIDsToPatch == ["graph-detached-20260708"],
                   "Microsoft write-back should patch detached instances by their provider instance ID")
    }

    @MainActor
    private static func verifyProviderFutureSplitWritePayloads() throws {
        resetLocalCalendarStorage()
        defer { resetLocalCalendarStorage() }

        let store = LocalCalendarStore()
        let summary = try store.importICSText(futureSplitSeriesICS)
        try expect(summary.eventsImported == 1, "Expected future-split fixture to import one event")
        guard let importedEvent = store.events.first,
              let localCalendar = store.calendar(withID: importedEvent.calendarID) else {
            throw ProviderWritePayloadInvariantError("Expected future-split fixture to create one local event and calendar")
        }
        store.setRemoteObjectURL(
            eventID: importedEvent.id,
            remoteObjectURLString: "https://caldav.example.com/calendars/me/work/future-split.ics",
            remoteETag: "\"future-split-etag\"",
            clearsLocalProviderRecurrenceChanges: false
        )

        let selectedOccurrence = try requireOccurrence(
            in: store,
            from: "2026-07-15T00:00:00Z",
            to: "2026-07-16T00:00:00Z",
            title: "Provider future split fixture"
        )
        let changedEvents = store.move(
            selectedOccurrence,
            dayDelta: 1,
            minuteDelta: 30,
            scope: .futureEvents
        )

        try expect(changedEvents.count == 2, "This-and-future grid move should produce source and future provider writes")
        try expect(store.events.count == 2, "This-and-future grid move should split one recurring series into two local events")

        let sourceSeries = try requireOnly(
            store.events.filter { !$0.remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            context: "source provider-backed series"
        )
        let futureSeries = try requireOnly(
            store.events.filter { $0.id != sourceSeries.id },
            context: "future split series"
        )

        try expect(sourceSeries.remoteObjectURLString == "https://caldav.example.com/calendars/me/work/future-split.ics",
                   "Source series should keep its remote binding for provider PATCH/PUT")
        try expect(sourceSeries.remoteETag == "\"future-split-etag\"",
                   "Source series should keep its remote ETag for conflict-safe provider write")
        try expect(futureSeries.remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   "Future split series should clear remote binding so providers create a new object")
        try expect(futureSeries.remoteETag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   "Future split series should clear stale ETag before provider create")
        try expect(futureSeries.externalUID.contains("#future-"),
                   "Future split series should get a distinct UID instead of reusing the source provider UID")
        try expect(sameInstant(futureSeries.startDate, "2026-07-16T06:30:00Z"),
                   "Future split series should start at the moved occurrence")

        let visibleOccurrences = store.events(
            from: try date("2026-07-01T00:00:00Z"),
            to: try date("2026-08-01T00:00:00Z")
        ).filter { $0.title == "Provider future split fixture" }
        try expect(visibleOccurrences.count == 5, "Split series should expose the two past and three moved future occurrences")
        try expect(visibleOccurrences.contains { sameInstant($0.startDate, "2026-07-01T06:00:00Z") },
                   "Source series should keep the first occurrence")
        try expect(visibleOccurrences.contains { sameInstant($0.startDate, "2026-07-08T06:00:00Z") },
                   "Source series should keep the occurrence before the split")
        try expect(!visibleOccurrences.contains { sameInstant($0.startDate, "2026-07-15T06:00:00Z") },
                   "Split series should remove the original future occurrence slot")
        try expect(visibleOccurrences.contains { sameInstant($0.startDate, "2026-07-16T06:30:00Z") },
                   "Future series should expose the moved first future occurrence")

        let serverCalendar = CalDAVCalendar(
            href: URL(string: "https://caldav.example.com/calendars/me/work/")!,
            displayName: "Future Split Work",
            colorHex: "#2563EB",
            syncToken: "sync-token",
            cTag: "ctag",
            allowsEventWrite: true,
            allowsResponses: true
        )
        let sourceCalDAVText = CalDAVClient().calendarDataPayloadPreview(
            for: sourceSeries,
            localCalendar: localCalendar,
            calendar: serverCalendar
        )
        let futureCalDAVText = CalDAVClient().calendarDataPayloadPreview(
            for: futureSeries,
            localCalendar: localCalendar,
            calendar: serverCalendar
        )
        try expect(sourceCalDAVText.contains("UID:provider-future-split@example.com"),
                   "CalDAV source split write should preserve the original provider UID")
        try expect(sourceCalDAVText.contains("RRULE:FREQ=WEEKLY") && sourceCalDAVText.contains("BYDAY=WE"),
                   "CalDAV source split write should preserve the original weekday rule")
        try expect(futureCalDAVText.contains("UID:provider-future-split@example.com#future-"),
                   "CalDAV future split write should use a distinct future UID")
        try expect(futureCalDAVText.contains("RRULE:FREQ=WEEKLY") && futureCalDAVText.contains("BYDAY=TH"),
                   "CalDAV future split write should serialize the moved weekday rule")

        let googleClient = GoogleCalendarClient()
        let googleSourcePayload = try jsonObject(googleClient.encodedWritePayloadPreview(for: sourceSeries))
        let googleSourceRecurrence = try stringArray(googleSourcePayload["recurrence"], context: "Google source split recurrence")
        let googleFuturePayload = try jsonObject(googleClient.encodedWritePayloadPreview(for: futureSeries))
        let googleFutureRecurrence = try stringArray(googleFuturePayload["recurrence"], context: "Google future split recurrence")
        try expect(googleSourceRecurrence.contains { $0.contains("FREQ=WEEKLY") && $0.contains("BYDAY=WE") && $0.contains("UNTIL=") },
                   "Google source split write should preserve a bounded Wednesday series")
        try expect(googleFutureRecurrence.contains { $0.contains("FREQ=WEEKLY") && $0.contains("BYDAY=TH") && $0.contains("UNTIL=") },
                   "Google future split write should create a bounded moved Thursday series")
        try expect(try nestedString(googleFuturePayload, "start", "dateTime")?.hasPrefix("2026-07-16T09:30:00") == true,
                   "Google future split write should use the moved local start time")

        let microsoftClient = MicrosoftGraphCalendarClient()
        let microsoftSourcePayload = try jsonObject(microsoftClient.encodedWritePayloadPreview(for: sourceSeries))
        let microsoftSourceRecurrence = try dictionary(microsoftSourcePayload["recurrence"], context: "Microsoft source split recurrence")
        let microsoftSourcePattern = try dictionary(microsoftSourceRecurrence["pattern"], context: "Microsoft source split pattern")
        let microsoftSourceRange = try dictionary(microsoftSourceRecurrence["range"], context: "Microsoft source split range")
        let microsoftFuturePayload = try jsonObject(microsoftClient.encodedWritePayloadPreview(for: futureSeries))
        let microsoftFutureRecurrence = try dictionary(microsoftFuturePayload["recurrence"], context: "Microsoft future split recurrence")
        let microsoftFuturePattern = try dictionary(microsoftFutureRecurrence["pattern"], context: "Microsoft future split pattern")
        let microsoftFutureRange = try dictionary(microsoftFutureRecurrence["range"], context: "Microsoft future split range")
        try expect(try stringArray(microsoftSourcePattern["daysOfWeek"], context: "Microsoft source split days") == ["wednesday"],
                   "Microsoft source split write should preserve the original weekday")
        try expect(microsoftSourceRange["endDate"] as? String == "2026-07-14",
                   "Microsoft source split write should end before the moved future occurrence")
        try expect(try stringArray(microsoftFuturePattern["daysOfWeek"], context: "Microsoft future split days") == ["thursday"],
                   "Microsoft future split write should serialize the moved weekday")
        try expect(microsoftFutureRange["startDate"] as? String == "2026-07-16",
                   "Microsoft future split write should start on the moved occurrence day")
        try expect(try nestedString(microsoftFuturePayload, "start", "dateTime") == "2026-07-16T09:30:00",
                   "Microsoft future split write should use the moved local start time")
    }

    private static func verifyAllDayProviderOccurrenceMatching() throws {
        let timeZoneIdentifier = "Pacific/Auckland"
        let occurrenceStartDate = try localDayStart("2026-07-01", timeZoneIdentifier: timeZoneIdentifier)

        try expect(
            GoogleCalendarClient().allDayOccurrenceDateMatchesPreview(
                providerDate: "2026-07-01",
                occurrenceStartDate: occurrenceStartDate,
                timeZoneIdentifier: timeZoneIdentifier
            ),
            "Google all-day occurrence matching should compare provider date in the event timezone"
        )
        try expect(
            !GoogleCalendarClient().allDayOccurrenceDateMatchesPreview(
                providerDate: "2026-06-30",
                occurrenceStartDate: occurrenceStartDate,
                timeZoneIdentifier: timeZoneIdentifier
            ),
            "Google all-day occurrence matching should not fall back to the UTC calendar day"
        )

        try expect(
            MicrosoftGraphCalendarClient().allDayOccurrenceDateMatchesPreview(
                providerDatePrefix: "2026-07-01T00:00:00.0000000",
                occurrenceStartDate: occurrenceStartDate,
                timeZoneIdentifier: timeZoneIdentifier
            ),
            "Microsoft all-day occurrence matching should compare Graph originalStart in the event timezone"
        )
        try expect(
            !MicrosoftGraphCalendarClient().allDayOccurrenceDateMatchesPreview(
                providerDatePrefix: "2026-06-30T00:00:00.0000000",
                occurrenceStartDate: occurrenceStartDate,
                timeZoneIdentifier: timeZoneIdentifier
            ),
            "Microsoft all-day occurrence matching should not fall back to the UTC calendar day"
        )
    }

    private static func monthlyNegativeMonthDayEvent(
        id: String,
        calendarID: String,
        title: String
    ) throws -> LocalCalendarEvent {
        let startDate = try date("2026-07-31T06:00:00Z")
        return LocalCalendarEvent(
            id: id,
            externalUID: "\(id)@example.com",
            calendarID: calendarID,
            title: title,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(30 * 60),
            isAllDay: false,
            timeZoneIdentifier: "Asia/Nicosia",
            location: "CY-Office-1st-Conference",
            notes: "Negative month day provider fixture",
            urlString: "https://meet.example.com/negative-month-day",
            recurrenceFrequency: .monthly,
            recurrenceInterval: 1,
            recurrenceMonthDay: -1,
            recurrenceEndDate: try date("2026-10-31T06:00:00Z"),
            createdAt: try date("2026-06-25T08:00:00Z"),
            updatedAt: try date("2026-06-25T08:30:00Z")
        )
    }

    private static func yearlyNegativeMonthDayEvent(
        id: String,
        calendarID: String,
        title: String
    ) throws -> LocalCalendarEvent {
        let startDate = try date("2028-02-29T06:00:00Z")
        return LocalCalendarEvent(
            id: id,
            externalUID: "\(id)@example.com",
            calendarID: calendarID,
            title: title,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(30 * 60),
            isAllDay: false,
            timeZoneIdentifier: "Asia/Nicosia",
            location: "CY-Office-1st-Conference",
            notes: "Yearly negative month day provider fixture",
            urlString: "https://meet.example.com/yearly-negative-month-day",
            recurrenceFrequency: .yearly,
            recurrenceInterval: 1,
            recurrenceMonthDay: -1,
            recurrenceEndDate: try date("2030-02-28T06:00:00Z"),
            createdAt: try date("2026-06-25T08:00:00Z"),
            updatedAt: try date("2026-06-25T08:30:00Z")
        )
    }

    private static func yearlyByMonthEvent(
        id: String,
        calendarID: String,
        title: String
    ) throws -> LocalCalendarEvent {
        let startDate = try date("2026-01-05T06:00:00Z")
        return LocalCalendarEvent(
            id: id,
            externalUID: "\(id)@example.com",
            calendarID: calendarID,
            title: title,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(30 * 60),
            isAllDay: false,
            timeZoneIdentifier: "Asia/Nicosia",
            location: "CY-Office-1st-Conference",
            notes: "Yearly BYMONTH provider fixture",
            urlString: "https://meet.example.com/yearly-bymonth",
            recurrenceFrequency: .yearly,
            recurrenceInterval: 1,
            recurrenceMonthDay: 5,
            recurrenceMonths: [1, 4, 7, 10],
            recurrenceEndDate: try date("2026-10-05T06:00:00Z"),
            createdAt: try date("2026-06-25T08:00:00Z"),
            updatedAt: try date("2026-06-25T08:30:00Z")
        )
    }

    private static func monthlyByMonthEvent(
        id: String,
        calendarID: String,
        title: String
    ) throws -> LocalCalendarEvent {
        let startDate = try date("2026-01-05T06:00:00Z")
        return LocalCalendarEvent(
            id: id,
            externalUID: "\(id)@example.com",
            calendarID: calendarID,
            title: title,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(30 * 60),
            isAllDay: false,
            timeZoneIdentifier: "Asia/Nicosia",
            location: "CY-Office-1st-Conference",
            notes: "Monthly BYMONTH provider fixture",
            urlString: "https://meet.example.com/monthly-bymonth",
            recurrenceFrequency: .monthly,
            recurrenceInterval: 1,
            recurrenceMonthDay: 5,
            recurrenceMonths: [1, 4, 7, 10],
            recurrenceEndDate: try date("2026-10-05T06:00:00Z"),
            createdAt: try date("2026-06-25T08:00:00Z"),
            updatedAt: try date("2026-06-25T08:30:00Z")
        )
    }

    private static func weeklyWeekStartEvent(
        id: String,
        calendarID: String,
        title: String
    ) throws -> LocalCalendarEvent {
        let startDate = try date("2026-07-06T06:00:00Z")
        return LocalCalendarEvent(
            id: id,
            externalUID: "\(id)@example.com",
            calendarID: calendarID,
            title: title,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(30 * 60),
            isAllDay: false,
            timeZoneIdentifier: "Asia/Nicosia",
            location: "CY-Office-1st-Conference",
            notes: "Weekly week-start provider fixture",
            urlString: "https://meet.example.com/weekly-week-start",
            recurrenceFrequency: .weekly,
            recurrenceInterval: 2,
            recurrenceWeekdays: [1, 2],
            recurrenceWeekStart: 2,
            recurrenceEndDate: try date("2026-08-03T06:00:00Z"),
            createdAt: try date("2026-06-25T08:00:00Z"),
            updatedAt: try date("2026-06-25T08:30:00Z")
        )
    }

    private static func weeklySetPositionEvent(
        id: String,
        calendarID: String,
        title: String
    ) throws -> LocalCalendarEvent {
        let startDate = try date("2026-07-08T06:00:00Z")
        return LocalCalendarEvent(
            id: id,
            externalUID: "\(id)@example.com",
            calendarID: calendarID,
            title: title,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(30 * 60),
            isAllDay: false,
            timeZoneIdentifier: "Asia/Nicosia",
            location: "CY-Office-1st-Conference",
            notes: "Weekly BYSETPOS provider fixture",
            urlString: "https://meet.example.com/weekly-set-position",
            recurrenceFrequency: .weekly,
            recurrenceInterval: 1,
            recurrenceWeekdays: [2, 4],
            recurrenceWeekStart: 2,
            recurrenceSetPositions: [-1],
            recurrenceEndDate: try date("2026-07-29T06:00:00Z"),
            createdAt: try date("2026-06-25T08:00:00Z"),
            updatedAt: try date("2026-06-25T08:30:00Z")
        )
    }

    private static func recurringEvent(
        id: String,
        calendarID: String,
        title: String,
        urlString: String,
        categories: [String] = ["Customer", "Launch"],
        includeAdditionalOccurrences: Bool = true
    ) throws -> LocalCalendarEvent {
        let baseStart = try date("2026-07-01T06:00:00Z")
        let detachedOriginalStart = try date("2026-07-08T06:00:00Z")
        let detachedStart = try date("2026-07-08T07:00:00Z")
        return LocalCalendarEvent(
            id: id,
            externalUID: "\(id)@example.com",
            remoteObjectURLString: "",
            remoteETag: "\"provider-write-etag\"",
            sequence: 4,
            calendarID: calendarID,
            title: title,
            startDate: baseStart,
            endDate: baseStart.addingTimeInterval(30 * 60),
            isAllDay: false,
            availability: .busy,
            privacy: .private,
            importance: .high,
            categories: categories,
            reminderOffsets: [10],
            timeZoneIdentifier: "Asia/Nicosia",
            organizerName: "Owner",
            organizerEmail: "owner@example.com",
            attendees: [
                LocalEventAttendee(name: "Me", email: "me@example.com", status: .accepted, type: "person", role: "required", rsvp: false, isCurrentUser: true),
                LocalEventAttendee(name: "Teammate", email: "teammate@example.com", status: .pending, type: "person", role: "optional", rsvp: true, isCurrentUser: false),
                LocalEventAttendee(name: "CY-Office-1st-Conference", email: "cy-office-1st-conference@example.com", status: .accepted, type: "resource", role: "required", rsvp: false, isCurrentUser: false)
            ],
            myResponseStatus: .accepted,
            location: "CY-Office-1st-Conference",
            notes: "Provider write payload fixture",
            urlString: urlString,
            recurrenceFrequency: .weekly,
            recurrenceInterval: 1,
            recurrenceWeekdays: [4],
            recurrenceEndDate: try date("2026-07-22T00:00:00Z"),
            additionalOccurrenceStartDates: includeAdditionalOccurrences ? [try date("2026-07-18T06:00:00Z")] : [],
            excludedOccurrenceStartDates: [try date("2026-07-15T06:00:00Z")],
            detachedOccurrences: [
                LocalDetachedOccurrence(
                    originalStartDate: detachedOriginalStart,
                    sequence: 5,
                    calendarID: calendarID,
                    title: "Moved provider occurrence",
                    startDate: detachedStart,
                    endDate: detachedStart.addingTimeInterval(45 * 60),
                    isAllDay: false,
                    availability: .busy,
                    status: .confirmed,
                    privacy: .private,
                    importance: .high,
                    categories: ["Customer"],
                    reminderOffsets: [5],
                    timeZoneIdentifier: "Asia/Nicosia",
                    organizerName: "Owner",
                    organizerEmail: "owner@example.com",
                    attendees: [
                        LocalEventAttendee(name: "Me", email: "me@example.com", status: .accepted, type: "person", role: "required", rsvp: false, isCurrentUser: true)
                    ],
                    myResponseStatus: .accepted,
                    location: "CY-Office-1st-Conference",
                    notes: "Moved occurrence notes",
                    urlString: "https://meet.google.com/moved-provider-occurrence",
                    updatedAt: try date("2026-06-25T09:00:00Z")
                )
            ],
            hasLocalProviderRecurrenceChanges: true,
            createdAt: try date("2026-06-25T08:00:00Z"),
            updatedAt: try date("2026-06-25T08:30:00Z")
        )
    }

    private static func allDayRecurringEvent(
        id: String,
        calendarID: String,
        title: String,
        includeAdditionalOccurrences: Bool
    ) throws -> LocalCalendarEvent {
        let timeZoneIdentifier = "Pacific/Auckland"
        let baseStart = try localDayStart("2026-07-01", timeZoneIdentifier: timeZoneIdentifier)
        let baseEnd = try localDayStart("2026-07-02", timeZoneIdentifier: timeZoneIdentifier)
        let detachedOriginalStart = try localDayStart("2026-07-08", timeZoneIdentifier: timeZoneIdentifier)
        let detachedStart = try localDayStart("2026-07-09", timeZoneIdentifier: timeZoneIdentifier)
        let detachedEnd = try localDayStart("2026-07-10", timeZoneIdentifier: timeZoneIdentifier)
        return LocalCalendarEvent(
            id: id,
            externalUID: "\(id)@example.com",
            remoteObjectURLString: "",
            remoteETag: "\"provider-write-all-day-etag\"",
            sequence: 2,
            calendarID: calendarID,
            title: title,
            startDate: baseStart,
            endDate: baseEnd,
            isAllDay: true,
            availability: .busy,
            privacy: .public,
            importance: .normal,
            categories: [],
            reminderOffsets: [],
            timeZoneIdentifier: timeZoneIdentifier,
            organizerName: "Owner",
            organizerEmail: "owner@example.com",
            attendees: [],
            myResponseStatus: .notInvited,
            location: "All-day room",
            notes: "All-day provider write payload fixture",
            urlString: "https://meet.example.com/all-day-provider-write",
            recurrenceFrequency: .weekly,
            recurrenceInterval: 1,
            recurrenceWeekdays: [4],
            recurrenceEndDate: try localDayStart("2026-07-22", timeZoneIdentifier: timeZoneIdentifier),
            additionalOccurrenceStartDates: includeAdditionalOccurrences
                ? [try localDayStart("2026-07-18", timeZoneIdentifier: timeZoneIdentifier)]
                : [],
            excludedOccurrenceStartDates: [try localDayStart("2026-07-15", timeZoneIdentifier: timeZoneIdentifier)],
            detachedOccurrences: [
                LocalDetachedOccurrence(
                    originalStartDate: detachedOriginalStart,
                    sequence: 3,
                    calendarID: calendarID,
                    title: "Moved all-day provider occurrence",
                    startDate: detachedStart,
                    endDate: detachedEnd,
                    isAllDay: true,
                    availability: .busy,
                    status: .confirmed,
                    privacy: .public,
                    importance: .normal,
                    categories: [],
                    reminderOffsets: [],
                    timeZoneIdentifier: timeZoneIdentifier,
                    organizerName: "Owner",
                    organizerEmail: "owner@example.com",
                    attendees: [],
                    myResponseStatus: .notInvited,
                    location: "Moved all-day room",
                    notes: "Moved all-day occurrence notes",
                    urlString: "https://meet.example.com/moved-all-day-provider-occurrence",
                    updatedAt: try date("2026-06-25T09:00:00Z")
                )
            ],
            hasLocalProviderRecurrenceChanges: true,
            createdAt: try date("2026-06-25T08:00:00Z"),
            updatedAt: try date("2026-06-25T08:30:00Z")
        )
    }

    private static func allDayYearlyEvent(
        id: String,
        calendarID: String,
        title: String
    ) throws -> LocalCalendarEvent {
        let timeZoneIdentifier = "Pacific/Auckland"
        let baseStart = try localDayStart("2026-01-01", timeZoneIdentifier: timeZoneIdentifier)
        let baseEnd = try localDayStart("2026-01-02", timeZoneIdentifier: timeZoneIdentifier)
        return LocalCalendarEvent(
            id: id,
            externalUID: "\(id)@example.com",
            remoteObjectURLString: "",
            remoteETag: "\"provider-write-all-day-yearly-etag\"",
            sequence: 1,
            calendarID: calendarID,
            title: title,
            startDate: baseStart,
            endDate: baseEnd,
            isAllDay: true,
            availability: .busy,
            privacy: .public,
            importance: .normal,
            categories: [],
            reminderOffsets: [],
            timeZoneIdentifier: timeZoneIdentifier,
            organizerName: "",
            organizerEmail: "",
            attendees: [],
            myResponseStatus: .notInvited,
            location: "",
            notes: "All-day yearly provider write payload fixture",
            urlString: "",
            recurrenceFrequency: .yearly,
            recurrenceInterval: 1,
            recurrenceEndDate: try localDayStart("2028-01-01", timeZoneIdentifier: timeZoneIdentifier),
            createdAt: try date("2026-06-25T08:00:00Z"),
            updatedAt: try date("2026-06-25T08:30:00Z")
        )
    }

    private static func allDayWeeklyFallbackEvent(
        id: String,
        calendarID: String,
        title: String
    ) throws -> LocalCalendarEvent {
        let timeZoneIdentifier = "Pacific/Auckland"
        let baseStart = try localDayStart("2026-07-06", timeZoneIdentifier: timeZoneIdentifier)
        let baseEnd = try localDayStart("2026-07-07", timeZoneIdentifier: timeZoneIdentifier)
        return LocalCalendarEvent(
            id: id,
            externalUID: "\(id)@example.com",
            remoteObjectURLString: "",
            remoteETag: "\"provider-write-weekly-fallback-etag\"",
            sequence: 1,
            calendarID: calendarID,
            title: title,
            startDate: baseStart,
            endDate: baseEnd,
            isAllDay: true,
            availability: .busy,
            privacy: .public,
            importance: .normal,
            categories: [],
            reminderOffsets: [],
            timeZoneIdentifier: timeZoneIdentifier,
            organizerName: "",
            organizerEmail: "",
            attendees: [],
            myResponseStatus: .notInvited,
            location: "",
            notes: "All-day weekly fallback provider write payload fixture",
            urlString: "",
            recurrenceFrequency: .weekly,
            recurrenceInterval: 1,
            recurrenceWeekdays: [],
            recurrenceEndDate: try localDayStart("2026-07-20", timeZoneIdentifier: timeZoneIdentifier),
            createdAt: try date("2026-06-25T08:00:00Z"),
            updatedAt: try date("2026-06-25T08:30:00Z")
        )
    }

    private static func requireOnlyDetachedOccurrence(_ event: LocalCalendarEvent) throws -> LocalDetachedOccurrence {
        guard event.detachedOccurrences.count == 1, let occurrence = event.detachedOccurrences.first else {
            throw ProviderWritePayloadInvariantError("Expected exactly one detached occurrence fixture")
        }
        return occurrence
    }

    @MainActor
    private static func requireOccurrence(
        in store: LocalCalendarStore,
        from start: String,
        to end: String,
        title: String
    ) throws -> CalendarEvent {
        let matches = store.events(from: try date(start), to: try date(end)).filter { $0.title == title }
        guard matches.count == 1, let event = matches.first else {
            throw ProviderWritePayloadInvariantError("Expected exactly one occurrence for \(title), got \(matches.count)")
        }
        return event
    }

    private static func requireOnly(_ events: [LocalCalendarEvent], context: String) throws -> LocalCalendarEvent {
        guard events.count == 1, let event = events.first else {
            throw ProviderWritePayloadInvariantError("Expected exactly one \(context), got \(events.count)")
        }
        return event
    }

    private static func attendee(_ payload: [String: Any], email: String) throws -> [String: Any] {
        let attendees = try array(payload["attendees"], context: "attendees")
        for attendeeValue in attendees {
            let attendee = try dictionary(attendeeValue, context: "attendee")
            if attendee["email"] as? String == email {
                return attendee
            }
            if let emailAddress = attendee["emailAddress"] as? [String: Any],
               emailAddress["address"] as? String == email {
                return attendee
            }
        }
        throw ProviderWritePayloadInvariantError("Could not find attendee \(email)")
    }

    private static func nestedString(_ payload: [String: Any], _ key: String, _ nestedKey: String) throws -> String? {
        try dictionary(payload[key], context: key)[nestedKey] as? String
    }

    private static func graphLocationNames(in payload: [String: Any], context: String) throws -> [String] {
        try array(payload["locations"], context: context).compactMap { value in
            try dictionary(value, context: "\(context) item")["displayName"] as? String
        }
    }

    private static func reminderMinutes(in payload: [String: Any], context: String) throws -> [Int] {
        let reminders = try dictionary(payload["reminders"], context: "\(context) reminders")
        let overrides = try array(reminders["overrides"], context: "\(context) reminder overrides")
        return try overrides.map { value in
            let override = try dictionary(value, context: "\(context) reminder override")
            guard let minutes = override["minutes"] as? Int else {
                throw ProviderWritePayloadInvariantError("Expected \(context) reminder override minutes")
            }
            return minutes
        }
    }

    private static func googleWorkingCategories(in payload: [String: Any], context: String) throws -> [String] {
        let extendedProperties = try dictionary(payload["extendedProperties"], context: "\(context) extended properties")
        let privateProperties = try dictionary(extendedProperties["private"], context: "\(context) private extended properties")
        guard let encodedCategories = privateProperties["workingCalendar.categories"] as? String,
              let data = encodedCategories.data(using: .utf8),
              let categories = try? JSONDecoder().decode([String].self, from: data) else {
            throw ProviderWritePayloadInvariantError("Expected \(context) Working Calendar categories in Google extended properties")
        }
        return categories
    }

    private static func googleRelatedEvents(in payload: [String: Any], context: String) throws -> [LocalEventRelationship] {
        let privateProperties = try googlePrivateExtendedProperties(in: payload, context: context)
        guard let encodedRelationships = privateProperties["workingCalendar.relatedEvents"] as? String,
              let data = encodedRelationships.data(using: .utf8),
              let relationships = try? JSONDecoder().decode([LocalEventRelationship].self, from: data) else {
            throw ProviderWritePayloadInvariantError("Expected \(context) related events in Google extended properties")
        }
        return normalizedEventRelationships(relationships)
    }

    private static func googleGeoCoordinate(in payload: [String: Any], context: String) throws -> LocalEventGeoCoordinate {
        let privateProperties = try googlePrivateExtendedProperties(in: payload, context: context)
        guard let encodedCoordinate = privateProperties["workingCalendar.geoCoordinate"] as? String,
              let data = encodedCoordinate.data(using: .utf8),
              let coordinate = try? JSONDecoder().decode(LocalEventGeoCoordinate.self, from: data) else {
            throw ProviderWritePayloadInvariantError("Expected \(context) GEO coordinate in Google extended properties")
        }
        return coordinate
    }

    private static func googlePrivateExtendedProperties(in payload: [String: Any], context: String) throws -> [String: Any] {
        let extendedProperties = try dictionary(payload["extendedProperties"], context: "\(context) extended properties")
        return try dictionary(extendedProperties["private"], context: "\(context) private extended properties")
    }

    private static func microsoftRelatedEvents(in payload: [String: Any], context: String) throws -> [LocalEventRelationship] {
        guard let encodedRelationships = payload["relatedEventsJSON"] as? String,
              let data = encodedRelationships.data(using: .utf8),
              let relationships = try? JSONDecoder().decode([LocalEventRelationship].self, from: data) else {
            throw ProviderWritePayloadInvariantError("Expected \(context) related events in Microsoft open extension")
        }
        return normalizedEventRelationships(relationships)
    }

    private static func microsoftGeoCoordinate(in payload: [String: Any], context: String) throws -> LocalEventGeoCoordinate {
        guard let encodedCoordinate = payload["geoCoordinateJSON"] as? String,
              let data = encodedCoordinate.data(using: .utf8),
              let coordinate = try? JSONDecoder().decode(LocalEventGeoCoordinate.self, from: data) else {
            throw ProviderWritePayloadInvariantError("Expected \(context) GEO coordinate in Microsoft open extension")
        }
        return coordinate
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderWritePayloadInvariantError("Expected encoded payload to be a JSON object")
        }
        return object
    }

    private static func googleEvents(_ text: String) throws -> [GoogleCalendarEvent] {
        try JSONDecoder().decode([GoogleCalendarEvent].self, from: Data(text.utf8))
    }

    private static func microsoftGraphEvents(_ text: String) throws -> [MicrosoftGraphEvent] {
        try JSONDecoder().decode([MicrosoftGraphEvent].self, from: Data(text.utf8))
    }

    private static func dictionary(_ value: Any?, context: String) throws -> [String: Any] {
        guard let dictionary = value as? [String: Any] else {
            throw ProviderWritePayloadInvariantError("Expected \(context) to be an object")
        }
        return dictionary
    }

    private static func array(_ value: Any?, context: String) throws -> [Any] {
        guard let array = value as? [Any] else {
            throw ProviderWritePayloadInvariantError("Expected \(context) to be an array")
        }
        return array
    }

    private static func stringArray(_ value: Any?, context: String) throws -> [String] {
        guard let array = value as? [String] else {
            throw ProviderWritePayloadInvariantError("Expected \(context) to be a string array")
        }
        return array
    }

    private static func queryItemsDictionary(_ queryItems: [URLQueryItem]) throws -> [String: String] {
        var values: [String: String] = [:]
        for queryItem in queryItems {
            guard values[queryItem.name] == nil else {
                throw ProviderWritePayloadInvariantError("Expected query item \(queryItem.name) to be unique")
            }
            values[queryItem.name] = queryItem.value ?? ""
        }
        return values
    }

    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private static func unfoldedICSText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\n ", with: "")
    }

    private static func sameInstant(_ date: Date, _ expected: String) -> Bool {
        guard let expectedDate = try? Self.date(expected) else { return false }
        return abs(date.timeIntervalSince(expectedDate)) < 1
    }

    private static func date(_ value: String) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            throw ProviderWritePayloadInvariantError("Could not parse fixture date \(value)")
        }
        return date
    }

    private static func localDayStart(_ value: String, timeZoneIdentifier: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else {
            throw ProviderWritePayloadInvariantError("Could not parse local day fixture \(value)")
        }
        return date
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw ProviderWritePayloadInvariantError(message)
        }
    }

    private static func resetLocalCalendarStorage() {
        UserDefaults.standard.removeObject(forKey: "localCalendars")
        UserDefaults.standard.removeObject(forKey: "localCalendarEvents")
        UserDefaults.standard.removeObject(forKey: "selectedLocalCalendarIDs")
    }

    private static let futureSplitSeriesICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Future Split Fixture//EN
    CALSCALE:GREGORIAN
    X-WR-TIMEZONE:Asia/Nicosia
    BEGIN:VEVENT
    UID:provider-future-split@example.com
    DTSTAMP:20260625T090000Z
    DTSTART;TZID=Asia/Nicosia:20260701T090000
    DTEND;TZID=Asia/Nicosia:20260701T093000
    RRULE:FREQ=WEEKLY;UNTIL=20260729T060000Z;BYDAY=WE;WKST=MO
    SUMMARY:Provider future split fixture
    LOCATION:CY-Office-1st-Conference
    DESCRIPTION:Future split provider write fixture
    URL:https://meet.example.com/future-split
    END:VEVENT
    END:VCALENDAR
    """

    private static let outlookDisallowCounterICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Write Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:outlook-disallow-counter-provider-write@example.com
    DTSTAMP:20260625T101500Z
    DTSTART:20260723T140000Z
    DTEND:20260723T143000Z
    SUMMARY:Outlook disallow counter provider write fixture
    X-MICROSOFT-DISALLOW-COUNTER:TRUE
    END:VEVENT
    END:VCALENDAR
    """
}

private struct ProviderWritePayloadInvariantError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
