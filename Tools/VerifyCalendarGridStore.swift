import AppKit
import Foundation

@main
struct VerifyCalendarGridStore {
    @MainActor
    static func main() throws {
        try verifyMoveSingleOccurrenceDetachedRoundTrip()
        try verifyResizeSingleOccurrenceDetachedRoundTrip()
        try verifyMoveAllDaySingleOccurrenceDetachedRoundTrip()
        try verifyAllDayRecurringExpansionAcrossProviderTimeZoneDST()
        try verifyAllDayProviderTimezoneFutureSplitKeepsLocalMonthDay()
        try verifyMoveThisAndFutureSplit()
        try verifyResizeThisAndFutureSplit()
        try verifyMoveAllDayThisAndFutureSplit()
        try verifyRecurringRemovalScopes()
        try verifyDockUpcomingBadgeSemantics()
        try verifyGridVenueTextUsesMeetingMethod()
        try verifySingleOccurrenceResponseOverridesSeriesPendingStatus()
        try verifyProviderResponseReplacesStaleLocalUnresolvedStatus()
        try verifyExactProviderPruneDoesNotCrossCalendarPrefix()
        try verifyProviderBackedCalendarCannotUseLocalDeletePath()
        try verifyScopedProviderRemovalDoesNotCrossCalendarOwnership()
        try verifyProviderRemoteIdentityIsCalendarScoped()
        try verifyScopedProviderRepliesDoNotCrossCalendarOwnership()
        print("Calendar grid store invariant passed.")
    }

    @MainActor
    private static func verifyMoveSingleOccurrenceDetachedRoundTrip() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let event = try createWeeklyEvent(in: store, title: "Single move fixture")
        let selectedOccurrence = try requireOccurrence(
            in: store,
            from: "2026-07-15T00:00:00Z",
            to: "2026-07-16T00:00:00Z",
            title: event.title
        )

        let changedEvents = store.move(
            selectedOccurrence,
            dayDelta: 1,
            minuteDelta: 30,
            scope: .thisEvent
        )

        try expect(changedEvents.count == 1, "Expected single occurrence move to update only the source series")
        try expect(store.events.count == 1, "Expected single occurrence move to keep one recurring series")
        try expect(store.events.first?.detachedOccurrences.count == 1, "Expected single occurrence move to create one detached occurrence")
        try expect(store.events.first?.hasLocalProviderRecurrenceChanges == true, "Expected detached move to mark provider recurrence changes")

        let occurrences = store.events(
            from: try date("2026-07-01T00:00:00Z"),
            to: try date("2026-07-24T00:00:00Z")
        ).filter { $0.title == event.title }

        try expect(occurrences.count == 4, "Expected four weekly occurrences after single move")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-07-01T09:00:00Z") }, "Expected first occurrence to stay put")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-07-08T09:00:00Z") }, "Expected second occurrence to stay put")
        try expect(!occurrences.contains { sameInstant($0.startDate, "2026-07-15T09:00:00Z") }, "Expected selected occurrence to leave its original slot")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-07-16T09:30:00Z") && $0.isDetached }, "Expected selected occurrence to become a moved detached occurrence")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-07-22T09:00:00Z") }, "Expected later occurrence to stay put")

        try verifyICSRoundTrip(
            from: store,
            title: event.title,
            expectedStarts: [
                "2026-07-01T09:00:00Z",
                "2026-07-08T09:00:00Z",
                "2026-07-16T09:30:00Z",
                "2026-07-22T09:00:00Z"
            ],
            expectedDurations: [30, 30, 30, 30],
            expectedImportedEvents: 1,
            expectedRRuleCount: 1,
            expectedRecurrenceIDCount: 1
        )
    }

    @MainActor
    private static func verifySingleOccurrenceResponseOverridesSeriesPendingStatus() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let event = try createWeeklyEvent(
            in: store,
            title: "Single occurrence response fixture",
            myResponseStatus: .pending
        )
        let pendingRule = RulePredicate(field: .iDidNotRespond, comparison: .isEqualTo, value: "true")
        let acceptedRule = RulePredicate(field: .iAccepted, comparison: .isEqualTo, value: "true")
        let selectedOccurrence = try requireOccurrence(
            in: store,
            from: "2026-07-15T00:00:00Z",
            to: "2026-07-16T00:00:00Z",
            title: event.title
        )

        try expect(selectedOccurrence.needsResponse, "Expected fixture occurrence to require a response before accepting")
        try expect(pendingRule.matches(selectedOccurrence), "Expected pending fixture occurrence to match the pending-response rule")
        try expect(selectedOccurrence.gridResponseBadge?.title == "No reply", "Expected pending occurrence to expose a no-reply grid badge")
        try expect(selectedOccurrence.gridResponseBadge?.requiresAttention == true, "Expected pending grid badge to require attention")
        try expect(selectedOccurrence.searchableText.localizedCaseInsensitiveContains("no reply"), "Expected grid search text to include pending response wording")

        let updatedSeries = store.respond(to: selectedOccurrence, with: .accept, scope: .thisEvent)

        try expect(updatedSeries != nil, "Expected single occurrence response to update the source series")
        try expect(store.events.count == 1, "Expected single occurrence response to keep one recurring series")
        try expect(store.events.first?.detachedOccurrences.count == 1, "Expected single occurrence response to create one detached response override")

        let occurrences = store.events(
            from: try date("2026-07-01T00:00:00Z"),
            to: try date("2026-07-24T00:00:00Z")
        ).filter { $0.title == event.title }

        let acceptedOccurrence = try requireOnly(
            occurrences.filter { sameInstant($0.startDate, "2026-07-15T09:00:00Z") },
            context: "accepted occurrence"
        )
        let untouchedOccurrence = try requireOnly(
            occurrences.filter { sameInstant($0.startDate, "2026-07-22T09:00:00Z") },
            context: "untouched pending occurrence"
        )

        try expect(acceptedOccurrence.isDetached, "Expected accepted single occurrence to be represented as detached")
        try expect(acceptedOccurrence.responseStatus == .accepted, "Expected accepted occurrence to expose the accepted RSVP")
        try expect(acceptedOccurrence.gridResponseBadge?.compactTitle == "Yes", "Expected accepted occurrence to expose an accepted grid badge")
        try expect(acceptedOccurrence.gridResponseBadge?.requiresAttention == false, "Accepted grid badge should not require attention")
        try expect(acceptedOccurrence.searchableText.localizedCaseInsensitiveContains("accepted"), "Expected grid search text to include accepted response wording")
        try expect(!acceptedOccurrence.needsResponse, "Accepted occurrence should leave the response queue")
        try expect(!pendingRule.matches(acceptedOccurrence), "Accepted occurrence should not match the pending-response rule")
        try expect(acceptedRule.matches(acceptedOccurrence), "Accepted occurrence should match the accepted-response rule")
        try expect(untouchedOccurrence.responseStatus == .pending, "Untouched series occurrence should keep the pending RSVP")
        try expect(untouchedOccurrence.needsResponse, "Untouched series occurrence should still require a response")
        try expect(untouchedOccurrence.gridResponseBadge?.title == "No reply", "Untouched pending occurrence should keep the no-reply grid badge")
        try expect(pendingRule.matches(untouchedOccurrence), "Untouched pending occurrence should still match the pending-response rule")
    }

    @MainActor
    private static func verifyProviderResponseReplacesStaleLocalUnresolvedStatus() throws {
        for staleStatus in [EventResponseStatus.pending, .unknown, .inProcess] {
            resetLocalCalendarStorage()
            let store = LocalCalendarStore()
            let title = "Provider response merge fixture \(staleStatus.rawValue)"
            var draft = store.draft(
                start: try date("2026-07-01T12:00:00Z"),
                end: try date("2026-07-01T12:30:00Z")
            )
            draft.title = title
            draft.myResponseStatus = staleStatus
            draft.attendees = [
                LocalEventAttendee(
                    name: "Me",
                    email: "me@example.com",
                    status: staleStatus,
                    type: "person",
                    role: "required",
                    rsvp: staleStatus.requiresAttention,
                    isCurrentUser: true
                )
            ]
            guard let created = store.save(draft) else {
                throw CalendarGridStoreInvariantError("Expected \(staleStatus.rawValue) response fixture to be saved")
            }

            let remoteObjectURLString = "https://calendar.example.com/calendars/me/provider-response-merge-\(staleStatus.rawValue).ics"
            store.setRemoteObjectURL(
                eventID: created.id,
                remoteObjectURLString: remoteObjectURLString,
                remoteETag: "\(staleStatus.rawValue)-etag"
            )

            let localOccurrence = try requireOccurrence(
                in: store,
                from: "2026-07-01T00:00:00Z",
                to: "2026-07-02T00:00:00Z",
                title: title
            )
            guard var newerLocalDraft = store.draft(for: localOccurrence) else {
                throw CalendarGridStoreInvariantError("Expected \(staleStatus.rawValue) response fixture draft")
            }
            newerLocalDraft.notes = "Local unresolved response state is newer but not authoritative"
            _ = store.save(newerLocalDraft)

            guard let calendar = store.calendar(withID: created.calendarID) else {
                throw CalendarGridStoreInvariantError("Expected response fixture calendar")
            }
            let importedICS = """
            BEGIN:VCALENDAR
            VERSION:2.0
            PRODID:-//Working Calendar//Provider Response Merge Fixture//EN
            BEGIN:VEVENT
            UID:provider-response-merge-\(staleStatus.rawValue)@example.com
            DTSTAMP:20260625T090000Z
            LAST-MODIFIED:20260625T090000Z
            SEQUENCE:0
            SUMMARY:\(title)
            DTSTART:20260701T120000Z
            DTEND:20260701T123000Z
            X-WORKING-CALENDAR-ID:\(calendar.id)
            X-WORKING-CALENDAR-TITLE:\(calendar.title)
            X-WORKING-CALENDAR-COLOR:\(calendar.colorHex)
            X-WORKING-CALENDAR-ALLOWS-EVENT-WRITE:TRUE
            X-WORKING-CALENDAR-ALLOWS-RESPONSES:TRUE
            X-WORKING-REMOTE-OBJECT-URL:\(remoteObjectURLString)
            X-WORKING-REMOTE-ETAG:accepted-etag
            X-WORKING-MY-RESPONSE:accepted
            ATTENDEE;PARTSTAT=ACCEPTED;ROLE=REQ-PARTICIPANT;X-WORKING-CURRENT-USER=TRUE;CN="Me":mailto:me@example.com
            END:VEVENT
            END:VCALENDAR
            """
            let summary = try store.importICSText(importedICS)
            try expect(summary.eventsUpdated == 1, "Expected provider response import to update the existing \(staleStatus.rawValue) event")

            let mergedOccurrence = try requireOccurrence(
                in: store,
                from: "2026-07-01T00:00:00Z",
                to: "2026-07-02T00:00:00Z",
                title: title
            )
            let pendingRule = RulePredicate(field: .iDidNotRespond, comparison: .isEqualTo, value: "true")
            let needsResponseRule = RulePredicate(field: .needsMyResponse, comparison: .isEqualTo, value: "true")
            let acceptedRule = RulePredicate(field: .iAccepted, comparison: .isEqualTo, value: "true")

            try expect(mergedOccurrence.responseStatus == .accepted, "Provider accepted response should replace stale local \(staleStatus.rawValue)")
            try expect(!mergedOccurrence.needsResponse, "Provider accepted response should leave the response queue after stale \(staleStatus.rawValue)")
            try expect(!pendingRule.matches(mergedOccurrence), "Accepted provider response should not match the pending-response rule after stale \(staleStatus.rawValue)")
            try expect(!needsResponseRule.matches(mergedOccurrence), "Accepted provider response should not match needs-response rules after stale \(staleStatus.rawValue)")
            try expect(acceptedRule.matches(mergedOccurrence), "Accepted provider response should match the accepted-response rule after stale \(staleStatus.rawValue)")
            try expect(mergedOccurrence.gridResponseBadge?.compactTitle == "Yes", "Accepted provider response should expose the accepted badge after stale \(staleStatus.rawValue)")
        }
    }

    @MainActor
    private static func verifyGridVenueTextUsesMeetingMethod() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()

        var virtualDraft = store.draft(
            start: try date("2026-07-01T15:00:00Z"),
            end: try date("2026-07-01T15:30:00Z")
        )
        virtualDraft.title = "Virtual grid venue fixture"
        virtualDraft.urlString = "https://zoom.us/j/123456789"
        guard store.save(virtualDraft) != nil else {
            throw CalendarGridStoreInvariantError("Expected virtual venue fixture to save")
        }

        let virtualEvent = try requireOccurrence(
            in: store,
            from: "2026-07-01T00:00:00Z",
            to: "2026-07-02T00:00:00Z",
            title: virtualDraft.title
        )
        try expect(virtualEvent.meetingMethod.title == "Zoom", "Expected Zoom URL to produce Zoom meeting method")
        try expect(virtualEvent.gridVenueText(displayLocation: nil) == "Zoom",
                   "Grid venue text should show the virtual meeting method instead of the calendar title")
        try expect(virtualEvent.gridVenueText(displayLocation: "  ") == "Zoom",
                   "Blank display locations should not hide the virtual meeting method")
        try expect(virtualEvent.gridVenueText(displayLocation: "CY-Office-1st-Conference") == "CY-Office-1st-Conference",
                   "Explicit display locations should win over virtual meeting method")
        try expect(virtualEvent.searchableText.localizedCaseInsensitiveContains("Zoom"),
                   "Grid search text should include the virtual meeting method")

        var plainDraft = store.draft(
            start: try date("2026-07-01T16:00:00Z"),
            end: try date("2026-07-01T16:30:00Z")
        )
        plainDraft.title = "Plain grid venue fixture"
        guard store.save(plainDraft) != nil else {
            throw CalendarGridStoreInvariantError("Expected plain venue fixture to save")
        }

        let plainEvent = try requireOccurrence(
            in: store,
            from: "2026-07-01T00:00:00Z",
            to: "2026-07-02T00:00:00Z",
            title: plainDraft.title
        )
        try expect(plainEvent.gridVenueText(displayLocation: nil) == plainEvent.calendarTitle,
                   "Events without location or meeting method should fall back to the calendar title")
    }

    @MainActor
    private static func verifyExactProviderPruneDoesNotCrossCalendarPrefix() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let shortCalendarID = "local-calendar-google-account-abc"
        let longCalendarID = "local-calendar-google-account-abcdef"
        let shortRemoteURL = "google://account/abc/event-short"
        let longRemoteURL = "google://account/abcdef/event-long"

        let importSummary = try store.importICSText("""
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Provider Prune Fixture//EN
        CALSCALE:GREGORIAN
        BEGIN:VEVENT
        UID:provider-prune-short@example.com
        DTSTAMP:20260625T120000Z
        DTSTART:20260701T100000Z
        DTEND:20260701T103000Z
        SUMMARY:Provider prune short calendar fixture
        X-WORKING-CALENDAR-ID:\(shortCalendarID)
        X-WORKING-CALENDAR-TITLE:Short provider calendar
        X-WORKING-CALENDAR-COLOR:#2563EB
        X-WORKING-REMOTE-OBJECT-URL:\(shortRemoteURL)
        END:VEVENT
        BEGIN:VEVENT
        UID:provider-prune-long@example.com
        DTSTAMP:20260625T120000Z
        DTSTART:20260701T110000Z
        DTEND:20260701T113000Z
        SUMMARY:Provider prune long calendar fixture
        X-WORKING-CALENDAR-ID:\(longCalendarID)
        X-WORKING-CALENDAR-TITLE:Long provider calendar
        X-WORKING-CALENDAR-COLOR:#7C3AED
        X-WORKING-REMOTE-OBJECT-URL:\(longRemoteURL)
        END:VEVENT
        END:VCALENDAR
        """)

        try expect(importSummary.eventsImported == 2, "Expected both provider prune fixtures to import")
        try expect(store.events.count == 2, "Expected two provider events before exact prune")

        let prunedCount = store.pruneProviderEvents(
            calendarID: shortCalendarID,
            keepingRemoteObjectURLs: [shortRemoteURL]
        )

        try expect(prunedCount == 0,
                   "Exact provider prune should not touch a different calendar whose id merely shares the prefix")
        try expect(store.events.count == 2,
                   "Exact provider prune should keep the long-calendar event")
        try expect(store.events.contains { $0.calendarID == longCalendarID && $0.remoteObjectURLString == longRemoteURL },
                   "Long provider calendar event should survive exact prune of the short calendar")
    }

    @MainActor
    private static func verifyProviderBackedCalendarCannotUseLocalDeletePath() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let providerCalendarID = "local-calendar-google-provider-delete-guard-primary"
        let remoteURL = "google://provider-delete-guard-primary/event"

        let importSummary = try store.importICSText("""
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Provider Delete Guard Fixture//EN
        CALSCALE:GREGORIAN
        BEGIN:VEVENT
        UID:provider-delete-guard@example.com
        DTSTAMP:20260625T120000Z
        DTSTART:20260701T100000Z
        DTEND:20260701T103000Z
        SUMMARY:Provider delete guard fixture
        X-WORKING-CALENDAR-ID:\(providerCalendarID)
        X-WORKING-CALENDAR-TITLE:Provider delete guard
        X-WORKING-CALENDAR-COLOR:#2563EB
        X-WORKING-REMOTE-OBJECT-URL:\(remoteURL)
        END:VEVENT
        END:VCALENDAR
        """)

        try expect(importSummary.eventsImported == 1, "Expected provider delete guard fixture to import")
        guard let providerCalendar = store.calendar(withID: providerCalendarID) else {
            throw CalendarGridStoreInvariantError("Expected provider-backed calendar to exist before delete guard")
        }

        store.deleteCalendar(providerCalendar)

        try expect(store.calendar(withID: providerCalendarID) != nil,
                   "Generic local calendar deletion should not remove provider-backed calendars")
        try expect(store.events.count == 1,
                   "Generic local calendar deletion should not remove provider-backed events")
        try expect(store.events.first?.calendarID == providerCalendarID,
                   "Generic local calendar deletion should not move provider-backed events into a fallback calendar")
        try expect(store.events.first?.remoteObjectURLString == remoteURL,
                   "Generic local calendar deletion should preserve provider remote object bindings")
    }

    @MainActor
    private static func verifyScopedProviderRemovalDoesNotCrossCalendarOwnership() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let firstCalendarID = "local-calendar-caldav-account-a-shared"
        let secondCalendarID = "local-calendar-caldav-account-b-shared"
        let firstRemoteURL = "https://dav.example.com/shared/event-a.ics"
        let secondRemoteURL = "https://dav.example.com/shared/event-b.ics"
        let sharedRemoteURL = "https://dav.example.com/shared/event.ics"

        let importSummary = try store.importICSText("""
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Scoped Provider Removal Fixture//EN
        CALSCALE:GREGORIAN
        BEGIN:VEVENT
        UID:scoped-removal-a@example.com
        DTSTAMP:20260625T120000Z
        DTSTART:20260701T100000Z
        DTEND:20260701T103000Z
        SUMMARY:Scoped removal first fixture
        X-WORKING-CALENDAR-ID:\(firstCalendarID)
        X-WORKING-CALENDAR-TITLE:First shared provider calendar
        X-WORKING-CALENDAR-COLOR:#2563EB
        X-WORKING-REMOTE-OBJECT-URL:\(firstRemoteURL)
        END:VEVENT
        BEGIN:VEVENT
        UID:scoped-removal-b@example.com
        DTSTAMP:20260625T120000Z
        DTSTART:20260701T110000Z
        DTEND:20260701T113000Z
        SUMMARY:Scoped removal second fixture
        X-WORKING-CALENDAR-ID:\(secondCalendarID)
        X-WORKING-CALENDAR-TITLE:Second shared provider calendar
        X-WORKING-CALENDAR-COLOR:#7C3AED
        X-WORKING-REMOTE-OBJECT-URL:\(secondRemoteURL)
        END:VEVENT
        END:VCALENDAR
        """)

        try expect(importSummary.eventsImported == 2, "Expected both scoped provider removal fixtures to import")
        guard let firstEvent = store.events.first(where: { $0.calendarID == firstCalendarID }),
              let secondEvent = store.events.first(where: { $0.calendarID == secondCalendarID }) else {
            throw CalendarGridStoreInvariantError("Expected both scoped provider removal events before rebinding")
        }
        store.setRemoteObjectURL(eventID: firstEvent.id, remoteObjectURLString: sharedRemoteURL)
        store.setRemoteObjectURL(eventID: secondEvent.id, remoteObjectURLString: sharedRemoteURL)

        let removedCount = store.removeProviderEvents(
            remoteObjectURLs: [sharedRemoteURL],
            calendarIDs: [firstCalendarID]
        )

        try expect(removedCount == 1,
                   "Scoped provider removal should delete only matching remote objects owned by the requested calendars")
        try expect(store.events.count == 1,
                   "Scoped provider removal should preserve matching remote objects owned by other provider calendars")
        try expect(store.events.first?.calendarID == secondCalendarID,
                   "Scoped provider removal should preserve the second provider calendar event")
        try expect(store.events.first?.remoteObjectURLString == sharedRemoteURL,
                   "Scoped provider removal should preserve the shared remote binding on untouched calendars")
    }

    @MainActor
    private static func verifyProviderRemoteIdentityIsCalendarScoped() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let firstCalendarID = "local-calendar-caldav-identity-account-a-primary"
        let secondCalendarID = "local-calendar-caldav-identity-account-b-primary"
        let sharedRemoteURL = "https://dav.example.com/shared/same-event.ics"

        let importSummary = try store.importICSText("""
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Scoped Remote Identity Fixture//EN
        CALSCALE:GREGORIAN
        BEGIN:VEVENT
        UID:scoped-remote-identity@example.com
        DTSTAMP:20260625T120000Z
        DTSTART:20260701T100000Z
        DTEND:20260701T103000Z
        SUMMARY:Scoped identity first fixture
        X-WORKING-CALENDAR-ID:\(firstCalendarID)
        X-WORKING-CALENDAR-TITLE:First remote identity calendar
        X-WORKING-CALENDAR-COLOR:#2563EB
        X-WORKING-REMOTE-OBJECT-URL:\(sharedRemoteURL)
        END:VEVENT
        BEGIN:VEVENT
        UID:scoped-remote-identity@example.com
        DTSTAMP:20260625T120000Z
        DTSTART:20260701T110000Z
        DTEND:20260701T113000Z
        SUMMARY:Scoped identity second fixture
        X-WORKING-CALENDAR-ID:\(secondCalendarID)
        X-WORKING-CALENDAR-TITLE:Second remote identity calendar
        X-WORKING-CALENDAR-COLOR:#7C3AED
        X-WORKING-REMOTE-OBJECT-URL:\(sharedRemoteURL)
        END:VEVENT
        END:VCALENDAR
        """)

        try expect(importSummary.eventsImported == 2,
                   "Provider-backed remote object identity should be scoped by calendar ownership")
        try expect(store.events.count == 2,
                   "Same remote URL and UID in different provider calendars should remain distinct local events")

        let updateSummary = try store.importICSText("""
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Scoped Remote Identity Update Fixture//EN
        CALSCALE:GREGORIAN
        BEGIN:VEVENT
        UID:scoped-remote-identity@example.com
        DTSTAMP:20260625T121000Z
        DTSTART:20260701T100000Z
        DTEND:20260701T103000Z
        SUMMARY:Scoped identity first fixture updated
        X-WORKING-CALENDAR-ID:\(firstCalendarID)
        X-WORKING-CALENDAR-TITLE:First remote identity calendar
        X-WORKING-CALENDAR-COLOR:#2563EB
        X-WORKING-REMOTE-OBJECT-URL:\(sharedRemoteURL)
        END:VEVENT
        END:VCALENDAR
        """)

        try expect(updateSummary.eventsUpdated == 1,
                   "Scoped provider remote identity should update only the matching provider calendar event")
        try expect(store.events.count == 2,
                   "Scoped provider remote identity update should not collapse other provider calendars")
        try expect(store.events.contains { $0.calendarID == firstCalendarID && $0.title == "Scoped identity first fixture updated" },
                   "Scoped provider remote identity update should refresh the matching calendar event")
        try expect(store.events.contains { $0.calendarID == secondCalendarID && $0.title == "Scoped identity second fixture" },
                   "Scoped provider remote identity update should leave other provider calendars untouched")
    }

    @MainActor
    private static func verifyScopedProviderRepliesDoNotCrossCalendarOwnership() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let firstCalendarID = "local-calendar-caldav-reply-account-a-primary"
        let secondCalendarID = "local-calendar-caldav-reply-account-b-primary"

        let firstImportSummary = try store.importICSText("""
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Scoped Provider Reply Fixture//EN
        CALSCALE:GREGORIAN
        BEGIN:VEVENT
        UID:scoped-reply@example.com
        DTSTAMP:20260625T120000Z
        DTSTART:20260701T100000Z
        DTEND:20260701T103000Z
        SUMMARY:Scoped reply first fixture
        X-WORKING-CALENDAR-ID:\(firstCalendarID)
        X-WORKING-CALENDAR-TITLE:First reply provider calendar
        X-WORKING-CALENDAR-COLOR:#2563EB
        X-WORKING-REMOTE-OBJECT-URL:https://dav.example.com/a/scoped-reply.ics
        ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN="Teammate":mailto:teammate@example.com
        END:VEVENT
        END:VCALENDAR
        """)
        let secondImportSummary = try store.importICSText("""
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Scoped Provider Reply Fixture//EN
        CALSCALE:GREGORIAN
        BEGIN:VEVENT
        UID:scoped-reply@example.com
        DTSTAMP:20260625T120000Z
        DTSTART:20260701T110000Z
        DTEND:20260701T113000Z
        SUMMARY:Scoped reply second fixture
        X-WORKING-CALENDAR-ID:\(secondCalendarID)
        X-WORKING-CALENDAR-TITLE:Second reply provider calendar
        X-WORKING-CALENDAR-COLOR:#7C3AED
        X-WORKING-REMOTE-OBJECT-URL:https://dav.example.com/b/scoped-reply.ics
        ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN="Teammate":mailto:teammate@example.com
        END:VEVENT
        END:VCALENDAR
        """)

        try expect(firstImportSummary.eventsImported == 1 && secondImportSummary.eventsImported == 1,
                   "Expected both scoped provider reply fixtures to import")
        let replies = LocalCalendarICSCodec.replies(from: """
        BEGIN:VCALENDAR
        VERSION:2.0
        METHOD:REPLY
        PRODID:-//Working Calendar//Scoped Reply//EN
        BEGIN:VEVENT
        UID:scoped-reply@example.com
        DTSTAMP:20260625T121000Z
        ATTENDEE;PARTSTAT=ACCEPTED;CN="Teammate":mailto:teammate@example.com
        END:VEVENT
        END:VCALENDAR
        """)

        let updatedCount = store.applyReplies(
            replies,
            calendarIDPrefix: "local-calendar-caldav-reply-account-a-"
        )

        try expect(updatedCount == 1,
                   "Scoped provider replies should update only events owned by the requested calendar prefix")
        let firstStatus = attendeeStatus(in: store, calendarID: firstCalendarID, email: "teammate@example.com")
        let secondStatus = attendeeStatus(in: store, calendarID: secondCalendarID, email: "teammate@example.com")
        try expect(firstStatus == .accepted,
                   "Scoped provider replies should update the matching provider calendar attendee")
        try expect(secondStatus == .pending,
                   "Scoped provider replies should leave same-UID events in other provider calendars untouched")
    }

    @MainActor
    private static func verifyResizeSingleOccurrenceDetachedRoundTrip() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let event = try createWeeklyEvent(in: store, title: "Single resize fixture")
        let selectedOccurrence = try requireOccurrence(
            in: store,
            from: "2026-07-15T00:00:00Z",
            to: "2026-07-16T00:00:00Z",
            title: event.title
        )

        let changedEvents = store.resize(
            selectedOccurrence,
            endMinuteDelta: 20,
            scope: .thisEvent
        )

        try expect(changedEvents.count == 1, "Expected single occurrence resize to update only the source series")
        try expect(store.events.count == 1, "Expected single occurrence resize to keep one recurring series")
        try expect(store.events.first?.detachedOccurrences.count == 1, "Expected single occurrence resize to create one detached occurrence")
        try expect(store.events.first?.hasLocalProviderRecurrenceChanges == true, "Expected detached resize to mark provider recurrence changes")

        let occurrences = store.events(
            from: try date("2026-07-01T00:00:00Z"),
            to: try date("2026-07-23T00:00:00Z")
        ).filter { $0.title == event.title }

        try expect(occurrences.count == 4, "Expected four weekly occurrences after single resize")
        let oldDurations = occurrences
            .filter { sameInstant($0.startDate, "2026-07-01T09:00:00Z") || sameInstant($0.startDate, "2026-07-08T09:00:00Z") || sameInstant($0.startDate, "2026-07-22T09:00:00Z") }
            .map(\.durationMinutes)
        let resized = occurrences.first { sameInstant($0.startDate, "2026-07-15T09:00:00Z") }

        try expect(oldDurations == [30, 30, 30], "Expected untouched occurrences to keep their original duration")
        try expect(resized?.durationMinutes == 50 && resized?.isDetached == true, "Expected selected occurrence to become a resized detached occurrence")

        try verifyICSRoundTrip(
            from: store,
            title: event.title,
            expectedStarts: [
                "2026-07-01T09:00:00Z",
                "2026-07-08T09:00:00Z",
                "2026-07-15T09:00:00Z",
                "2026-07-22T09:00:00Z"
            ],
            expectedDurations: [30, 30, 50, 30],
            expectedImportedEvents: 1,
            expectedRRuleCount: 1,
            expectedRecurrenceIDCount: 1
        )
    }

    @MainActor
    private static func verifyMoveAllDaySingleOccurrenceDetachedRoundTrip() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let event = try createAllDayWeeklyEvent(in: store, title: "All-day single move fixture")
        let selectedOccurrence = try requireOccurrence(
            in: store,
            from: "2026-07-15T00:00:00Z",
            to: "2026-07-16T00:00:00Z",
            title: event.title
        )

        let changedEvents = store.move(
            selectedOccurrence,
            dayDelta: 2,
            minuteDelta: 0,
            scope: .thisEvent
        )

        try expect(changedEvents.count == 1, "Expected all-day single occurrence move to update only the source series")
        try expect(store.events.count == 1, "Expected all-day single occurrence move to keep one recurring series")
        try expect(store.events.first?.detachedOccurrences.count == 1, "Expected all-day single occurrence move to create one detached occurrence")
        try expect(store.events.first?.detachedOccurrences.first?.isAllDay == true, "Expected detached all-day occurrence to stay all-day")
        try expect(store.events.first?.hasLocalProviderRecurrenceChanges == true, "Expected all-day detached move to mark provider recurrence changes")

        let occurrences = store.events(
            from: try date("2026-07-01T00:00:00Z"),
            to: try date("2026-07-25T00:00:00Z")
        ).filter { $0.title == event.title }

        try expect(occurrences.count == 4, "Expected four weekly all-day occurrences after single move")
        try expect(occurrences.allSatisfy(\.isAllDay), "Expected moved all-day recurrence to remain all-day")
        try expect(occurrences.contains { sameLocalDay($0.startDate, "2026-07-01") }, "Expected first all-day occurrence to stay put")
        try expect(occurrences.contains { sameLocalDay($0.startDate, "2026-07-08") }, "Expected second all-day occurrence to stay put")
        try expect(!occurrences.contains { sameLocalDay($0.startDate, "2026-07-15") }, "Expected selected all-day occurrence to leave its original day")
        try expect(occurrences.contains { sameLocalDay($0.startDate, "2026-07-17") && $0.isDetached }, "Expected selected all-day occurrence to become a moved detached occurrence")
        try expect(occurrences.contains { sameLocalDay($0.startDate, "2026-07-22") }, "Expected later all-day occurrence to stay put")

        let exportedText = store.exportICSText()
        try expect(exportedText.contains("RECURRENCE-ID;VALUE=DATE:20260715"),
                   "Expected all-day detached occurrence export to use date-only RECURRENCE-ID")

        try verifyICSRoundTrip(
            from: store,
            title: event.title,
            expectedStarts: [
            ],
            expectedDurations: [1440, 1440, 1440, 1440],
            expectedLocalDays: [
                "2026-07-01",
                "2026-07-08",
                "2026-07-17",
                "2026-07-22"
            ],
            expectedImportedEvents: 1,
            expectedRRuleCount: 1,
            expectedRecurrenceIDCount: 1,
            expectedAllDay: true
        )
    }

    @MainActor
    private static func verifyAllDayRecurringExpansionAcrossProviderTimeZoneDST() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let summary = try store.importICSText(allDayAucklandDSTSeriesICS)
        try expect(summary.eventsImported == 1, "Expected Auckland all-day DST series to import one event")

        let occurrences = store.events(
            from: try date("2026-04-01T00:00:00Z"),
            to: try date("2026-04-25T00:00:00Z"),
            includeAllDay: true
        ).filter { $0.externalIdentifier == "all-day-auckland-dst-series@example.com" }

        try expect(occurrences.count == 3, "Expected three Auckland all-day weekly occurrences, got \(occurrences.map { isoString($0.startDate) })")
        try expect(occurrences.allSatisfy(\.isAllDay), "Expected Auckland DST recurrence to remain all-day")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-04-04T11:00:00Z") && sameInstant($0.endDate, "2026-04-05T12:00:00Z") },
                   "Expected first Auckland all-day occurrence to span the local DST-end day")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-04-11T12:00:00Z") && sameInstant($0.endDate, "2026-04-12T12:00:00Z") },
                   "Expected second Auckland all-day occurrence to preserve the next local day")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-04-18T12:00:00Z") && sameInstant($0.endDate, "2026-04-19T12:00:00Z") },
                   "Expected third Auckland all-day occurrence to preserve the next local day")
        try expect(
            occurrences.map(\.durationMinutes) == [1500, 1440, 1440],
            "Expected all-day occurrence durations to follow each local day across DST"
        )
    }

    @MainActor
    private static func verifyAllDayProviderTimezoneFutureSplitKeepsLocalMonthDay() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let summary = try store.importICSText(allDayAucklandMonthlySeriesICS)
        try expect(summary.eventsImported == 1, "Expected Auckland monthly all-day series to import one event")

        let selectedOccurrence = try requireOccurrence(
            in: store,
            from: "2026-05-01T00:00:00Z",
            to: "2026-05-10T00:00:00Z",
            title: "Auckland monthly all-day recurrence"
        )

        let changedEvents = store.move(
            selectedOccurrence,
            dayDelta: 0,
            minuteDelta: 0,
            scope: .futureEvents
        )

        try expect(changedEvents.count == 2, "Expected no-op future move to split one provider-backed series")
        try expect(store.events.count == 2, "Expected Auckland monthly all-day future split to create two local series")

        let occurrences = store.events(
            from: try date("2026-04-01T00:00:00Z"),
            to: try date("2026-08-01T00:00:00Z"),
            includeAllDay: true
        ).filter { $0.externalIdentifier.hasPrefix("all-day-auckland-monthly-series@example.com") }

        let occurrenceDays = Set(occurrences.map {
            localDayString($0.startDate, timeZoneIdentifier: "Pacific/Auckland")
        })
        try expect(
            occurrenceDays == ["2026-04-05", "2026-05-05", "2026-06-05", "2026-07-05"],
            "Expected future split to keep Auckland local month day 5, got \(occurrenceDays.sorted())"
        )
        try expect(occurrences.allSatisfy(\.isAllDay), "Expected Auckland monthly future split occurrences to remain all-day")
    }

    @MainActor
    private static func verifyMoveThisAndFutureSplit() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let event = try createWeeklyEvent(in: store, title: "Future move fixture")
        let selectedOccurrence = try requireOccurrence(
            in: store,
            from: "2026-07-15T00:00:00Z",
            to: "2026-07-16T00:00:00Z",
            title: event.title
        )

        let changedEvents = store.move(
            selectedOccurrence,
            dayDelta: 0,
            minuteDelta: 60,
            scope: .futureEvents
        )

        try expect(changedEvents.count == 2, "Expected future move to update old and new split series")
        try expect(store.events.count == 2, "Expected future move to split one local series into two")
        let occurrences = store.events(
            from: try date("2026-07-01T00:00:00Z"),
            to: try date("2026-07-23T00:00:00Z")
        )

        try expect(occurrences.count == 4, "Expected four weekly occurrences after future move")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-07-01T09:00:00Z") }, "Expected first occurrence to stay put")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-07-08T09:00:00Z") }, "Expected second occurrence to stay put")
        try expect(!occurrences.contains { sameInstant($0.startDate, "2026-07-15T09:00:00Z") }, "Expected split occurrence to move away from original time")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-07-15T10:00:00Z") }, "Expected split occurrence to move one hour later")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-07-22T10:00:00Z") }, "Expected future occurrence to move one hour later")
        try expect(Set(store.events.map(\.externalUID)).count == 2, "Expected split series to use distinct external UIDs")
        try expect(store.events.contains { $0.remoteObjectURLString.isEmpty }, "Expected new future series to be ready for provider creation")
        try verifyICSRoundTrip(
            from: store,
            title: event.title,
            expectedStarts: [
                "2026-07-01T09:00:00Z",
                "2026-07-08T09:00:00Z",
                "2026-07-15T10:00:00Z",
                "2026-07-22T10:00:00Z"
            ],
            expectedDurations: [30, 30, 30, 30]
        )
    }

    @MainActor
    private static func verifyResizeThisAndFutureSplit() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let event = try createWeeklyEvent(in: store, title: "Future resize fixture")
        let selectedOccurrence = try requireOccurrence(
            in: store,
            from: "2026-07-15T00:00:00Z",
            to: "2026-07-16T00:00:00Z",
            title: event.title
        )

        let changedEvents = store.resize(
            selectedOccurrence,
            endMinuteDelta: 15,
            scope: .futureEvents
        )

        try expect(changedEvents.count == 2, "Expected future resize to update old and new split series")
        try expect(store.events.count == 2, "Expected future resize to split one local series into two")
        let occurrences = store.events(
            from: try date("2026-07-01T00:00:00Z"),
            to: try date("2026-07-23T00:00:00Z")
        )

        let oldDurations = occurrences
            .filter { sameInstant($0.startDate, "2026-07-01T09:00:00Z") || sameInstant($0.startDate, "2026-07-08T09:00:00Z") }
            .map(\.durationMinutes)
        let futureDurations = occurrences
            .filter { sameInstant($0.startDate, "2026-07-15T09:00:00Z") || sameInstant($0.startDate, "2026-07-22T09:00:00Z") }
            .map(\.durationMinutes)

        try expect(oldDurations == [30, 30], "Expected old occurrences to keep their original duration")
        try expect(futureDurations == [45, 45], "Expected future occurrences to use resized duration")
        try verifyICSRoundTrip(
            from: store,
            title: event.title,
            expectedStarts: [
                "2026-07-01T09:00:00Z",
                "2026-07-08T09:00:00Z",
                "2026-07-15T09:00:00Z",
                "2026-07-22T09:00:00Z"
            ],
            expectedDurations: [30, 30, 45, 45]
        )
    }

    @MainActor
    private static func verifyMoveAllDayThisAndFutureSplit() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let event = try createAllDayWeeklyEvent(in: store, title: "All-day future move fixture")
        let selectedOccurrence = try requireOccurrence(
            in: store,
            from: "2026-07-15T00:00:00Z",
            to: "2026-07-16T00:00:00Z",
            title: event.title
        )

        let changedEvents = store.move(
            selectedOccurrence,
            dayDelta: 1,
            minuteDelta: 0,
            scope: .futureEvents
        )

        try expect(changedEvents.count == 2, "Expected all-day future move to update old and new split series")
        try expect(store.events.count == 2, "Expected all-day future move to split one local series into two")

        let occurrences = store.events(
            from: try date("2026-07-01T00:00:00Z"),
            to: try date("2026-07-25T00:00:00Z")
        ).filter { $0.title == event.title }

        try expect(occurrences.count == 4, "Expected four weekly all-day occurrences after future move")
        try expect(occurrences.allSatisfy(\.isAllDay), "Expected split all-day recurrence to remain all-day")
        try expect(occurrences.contains { sameLocalDay($0.startDate, "2026-07-01") }, "Expected first all-day occurrence to stay put")
        try expect(occurrences.contains { sameLocalDay($0.startDate, "2026-07-08") }, "Expected second all-day occurrence to stay put")
        try expect(!occurrences.contains { sameLocalDay($0.startDate, "2026-07-15") }, "Expected split all-day occurrence to leave its original day")
        try expect(occurrences.contains { sameLocalDay($0.startDate, "2026-07-16") }, "Expected split all-day occurrence to move one day later")
        try expect(occurrences.contains { sameLocalDay($0.startDate, "2026-07-23") }, "Expected future all-day occurrence to move one day later")
        try expect(Set(store.events.map(\.externalUID)).count == 2, "Expected all-day split series to use distinct external UIDs")
        try expect(store.events.contains { $0.remoteObjectURLString.isEmpty }, "Expected all-day future series to be ready for provider creation")

        try verifyICSRoundTrip(
            from: store,
            title: event.title,
            expectedStarts: [
            ],
            expectedDurations: [1440, 1440, 1440, 1440],
            expectedLocalDays: [
                "2026-07-01",
                "2026-07-08",
                "2026-07-16",
                "2026-07-23"
            ],
            expectedAllDay: true
        )
    }

    @MainActor
    private static func verifyRecurringRemovalScopes() throws {
        resetLocalCalendarStorage()
        let allEventsStore = LocalCalendarStore()
        let allEventsSeries = try createWeeklyEvent(in: allEventsStore, title: "Remove all fixture")
        let allEventsOccurrence = try requireOccurrence(
            in: allEventsStore,
            from: "2026-07-15T00:00:00Z",
            to: "2026-07-16T00:00:00Z",
            title: allEventsSeries.title
        )

        allEventsStore.remove(allEventsOccurrence, scope: .allEvents)

        try expect(allEventsStore.events.isEmpty, "All-events removal should delete the recurring source series")
        let allEventsOccurrences = allEventsStore.events(
            from: try date("2026-07-01T00:00:00Z"),
            to: try date("2026-07-24T00:00:00Z")
        ).filter { $0.title == allEventsSeries.title }
        try expect(allEventsOccurrences.isEmpty, "All-events removal should leave no generated occurrences")

        resetLocalCalendarStorage()
        let firstFutureStore = LocalCalendarStore()
        let firstFutureSeries = try createWeeklyEvent(in: firstFutureStore, title: "Remove future from first fixture")
        let firstOccurrence = try requireOccurrence(
            in: firstFutureStore,
            from: "2026-07-01T00:00:00Z",
            to: "2026-07-02T00:00:00Z",
            title: firstFutureSeries.title
        )

        firstFutureStore.remove(firstOccurrence, scope: .futureEvents)

        try expect(firstFutureStore.events.isEmpty,
                   "This-and-future removal from the first occurrence should delete the whole source series")

        resetLocalCalendarStorage()
        let futureStore = LocalCalendarStore()
        let futureSeries = try createWeeklyEvent(in: futureStore, title: "Remove future fixture")
        let middleOccurrence = try requireOccurrence(
            in: futureStore,
            from: "2026-07-15T00:00:00Z",
            to: "2026-07-16T00:00:00Z",
            title: futureSeries.title
        )

        futureStore.remove(middleOccurrence, scope: .futureEvents)

        try expect(futureStore.events.count == 1, "This-and-future removal from the middle should keep one truncated source series")
        let remainingOccurrences = futureStore.events(
            from: try date("2026-07-01T00:00:00Z"),
            to: try date("2026-07-24T00:00:00Z")
        ).filter { $0.title == futureSeries.title }
        try expect(remainingOccurrences.count == 2, "This-and-future removal should keep only earlier occurrences")
        try expect(remainingOccurrences.contains { sameInstant($0.startDate, "2026-07-01T09:00:00Z") },
                   "This-and-future removal should keep the first occurrence")
        try expect(remainingOccurrences.contains { sameInstant($0.startDate, "2026-07-08T09:00:00Z") },
                   "This-and-future removal should keep the second occurrence")
        try expect(!remainingOccurrences.contains { sameInstant($0.startDate, "2026-07-15T09:00:00Z") },
                   "This-and-future removal should remove the selected occurrence")
        try expect(!remainingOccurrences.contains { sameInstant($0.startDate, "2026-07-22T09:00:00Z") },
                   "This-and-future removal should remove later occurrences")
    }

    private static func verifyDockUpcomingBadgeSemantics() throws {
        let now = try date("2026-07-01T12:00:00Z")
        let events = [
            badgeEvent(
                id: "active",
                title: "Active meeting",
                start: try date("2026-07-01T11:45:00Z"),
                end: try date("2026-07-01T12:15:00Z")
            ),
            badgeEvent(
                id: "future",
                title: "Future meeting",
                start: try date("2026-07-01T12:30:00Z"),
                end: try date("2026-07-01T13:00:00Z")
            ),
            badgeEvent(
                id: "ended",
                title: "Ended meeting",
                start: try date("2026-07-01T11:30:00Z"),
                end: try date("2026-07-01T11:55:00Z")
            ),
            badgeEvent(
                id: "all-day",
                title: "All-day note",
                start: try date("2026-07-01T00:00:00Z"),
                end: try date("2026-07-02T00:00:00Z"),
                isAllDay: true
            ),
            badgeEvent(
                id: "declined",
                title: "Declined meeting",
                start: try date("2026-07-01T12:45:00Z"),
                end: try date("2026-07-01T13:15:00Z"),
                responseStatus: .declined,
                responseStatusIsExplicit: true
            ),
            badgeEvent(
                id: "cancelled",
                title: "Cancelled meeting",
                start: try date("2026-07-01T13:30:00Z"),
                end: try date("2026-07-01T14:00:00Z"),
                status: .cancelled
            )
        ]

        let countedIDs = events
            .filter { $0.countsTowardDockUpcoming(at: now) }
            .map(\.id)

        try expect(countedIDs == ["active", "future"],
                   "Dock upcoming badge should count only active/future timed meetings, got \(countedIDs)")
    }

    @MainActor
    private static func verifyICSRoundTrip(
        from sourceStore: LocalCalendarStore,
        title: String,
        expectedStarts: [String] = [],
        expectedDurations: [Int],
        expectedLocalDays: [String]? = nil,
        expectedImportedEvents: Int = 2,
        expectedRRuleCount: Int = 2,
        expectedRecurrenceIDCount: Int = 0,
        expectedAllDay: Bool? = nil
    ) throws {
        let exportedText = sourceStore.exportICSText()
        try expect(countOccurrences(of: "BEGIN:VEVENT", in: exportedText) == 2, "Expected ICS export to contain two VEVENTs")
        try expect(countOccurrences(of: "RRULE:", in: exportedText) == expectedRRuleCount, "Expected ICS export to preserve \(expectedRRuleCount) recurrence rules")
        try expect(countOccurrences(of: "RECURRENCE-ID", in: exportedText) == expectedRecurrenceIDCount, "Expected ICS export to preserve \(expectedRecurrenceIDCount) detached occurrence IDs")

        resetLocalCalendarStorage()
        let importedStore = LocalCalendarStore()
        let summary = try importedStore.importICSText(exportedText)
        try expect(summary.eventsImported == expectedImportedEvents, "Expected ICS import to recreate \(expectedImportedEvents) stored event(s)")

        let importedOccurrences = importedStore.events(
            from: try date("2026-07-01T00:00:00Z"),
            to: try date("2026-07-23T00:00:00Z")
        ).filter { $0.title == title }

        let expectedCount = expectedLocalDays?.count ?? expectedStarts.count
        try expect(importedOccurrences.count == expectedCount, "Expected ICS round-trip occurrence count to match")
        let actualStarts = importedOccurrences.map { isoString($0.startDate) }
        if let expectedLocalDays {
            let actualLocalDays = importedOccurrences.map { localDayString($0.startDate) }
            for expectedLocalDay in expectedLocalDays {
                try expect(
                    importedOccurrences.contains { sameLocalDay($0.startDate, expectedLocalDay) },
                    "Expected ICS round-trip to preserve all-day occurrence on \(expectedLocalDay), got \(actualLocalDays)"
                )
            }
        } else {
            for expectedStart in expectedStarts {
                try expect(
                    importedOccurrences.contains { sameInstant($0.startDate, expectedStart) },
                    "Expected ICS round-trip to preserve occurrence at \(expectedStart), got \(actualStarts)"
                )
            }
        }
        try expect(
            importedOccurrences.map(\.durationMinutes) == expectedDurations,
            "Expected ICS round-trip to preserve occurrence durations"
        )
        if let expectedAllDay {
            try expect(
                importedOccurrences.allSatisfy { $0.isAllDay == expectedAllDay },
                "Expected ICS round-trip to preserve all-day flags"
            )
        }
    }

    @MainActor
    private static func createWeeklyEvent(
        in store: LocalCalendarStore,
        title: String,
        myResponseStatus: EventResponseStatus = .notInvited
    ) throws -> LocalCalendarEvent {
        var draft = store.draft(
            start: try date("2026-07-01T09:00:00Z"),
            end: try date("2026-07-01T09:30:00Z")
        )
        draft.title = title
        draft.myResponseStatus = myResponseStatus
        if myResponseStatus != .notInvited {
            draft.attendees = [
                LocalEventAttendee(
                    name: "Me",
                    email: "me@example.com",
                    status: myResponseStatus,
                    type: "person",
                    role: "required",
                    rsvp: myResponseStatus == .pending,
                    isCurrentUser: true
                )
            ]
        }
        draft.recurrenceFrequency = .weekly
        draft.recurrenceInterval = 1
        draft.recurrenceWeekdays = [4]
        draft.recurrenceEndDate = try date("2026-07-22T00:00:00Z")

        guard let event = store.save(draft) else {
            throw CalendarGridStoreInvariantError("Expected fixture event to be saved")
        }
        store.setRemoteObjectURL(
            eventID: event.id,
            remoteObjectURLString: "caldav://fixture/calendar/\(event.id).ics",
            remoteETag: "fixture-etag",
            clearsLocalProviderRecurrenceChanges: false
        )
        return store.localEvent(withID: event.id) ?? event
    }

    private static func badgeEvent(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        status: CalendarEventStatus = .confirmed,
        responseStatus: EventResponseStatus = .notInvited,
        responseStatusIsExplicit: Bool = false
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
            isAllDay: isAllDay,
            availability: .busy,
            status: status,
            privacy: .public,
            importance: .normal,
            categories: [],
            reminderOffsets: [],
            timeZoneIdentifier: "UTC",
            isRecurring: false,
            isDetached: false,
            calendarID: "local-calendar-fixture",
            calendarTitle: "Fixture",
            sourceTitle: "Working Calendar",
            calendarColor: .systemBlue,
            location: nil,
            notes: nil,
            url: nil,
            responseStatus: responseStatus,
            responseStatusIsExplicit: responseStatusIsExplicit,
            attendeeCount: 0,
            organizer: nil,
            participants: []
        )
    }

    @MainActor
    private static func createAllDayWeeklyEvent(in store: LocalCalendarStore, title: String) throws -> LocalCalendarEvent {
        var draft = store.draft(
            start: try localDayStart("2026-07-01"),
            end: try localDayStart("2026-07-02"),
            isAllDay: true
        )
        draft.title = title
        draft.recurrenceFrequency = .weekly
        draft.recurrenceInterval = 1
        draft.recurrenceWeekdays = [4]
        draft.recurrenceEndDate = try localDayStart("2026-07-22")

        guard let event = store.save(draft) else {
            throw CalendarGridStoreInvariantError("Expected all-day fixture event to be saved")
        }
        store.setRemoteObjectURL(
            eventID: event.id,
            remoteObjectURLString: "caldav://fixture/calendar/\(event.id).ics",
            remoteETag: "fixture-etag",
            clearsLocalProviderRecurrenceChanges: false
        )
        return store.localEvent(withID: event.id) ?? event
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
            throw CalendarGridStoreInvariantError("Expected exactly one occurrence for \(title), got \(matches.count)")
        }
        return event
    }

    private static func requireOnly(_ events: [CalendarEvent], context: String) throws -> CalendarEvent {
        guard events.count == 1, let event = events.first else {
            throw CalendarGridStoreInvariantError("Expected exactly one \(context), got \(events.count)")
        }
        return event
    }

    private static func resetLocalCalendarStorage() {
        UserDefaults.standard.removeObject(forKey: "localCalendars")
        UserDefaults.standard.removeObject(forKey: "localCalendarEvents")
        UserDefaults.standard.removeObject(forKey: "selectedLocalCalendarIDs")
    }

    private static let allDayAucklandDSTSeriesICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Grid Store Fixture//EN
    CALSCALE:GREGORIAN
    X-WR-TIMEZONE:Pacific/Auckland
    BEGIN:VEVENT
    UID:all-day-auckland-dst-series@example.com
    DTSTAMP:20260625T120000Z
    DTSTART;VALUE=DATE:20260405
    DTEND;VALUE=DATE:20260406
    RRULE:FREQ=WEEKLY;COUNT=3;BYDAY=SU;WKST=MO
    SUMMARY:Auckland DST all-day recurrence
    END:VEVENT
    END:VCALENDAR
    """

    private static let allDayAucklandMonthlySeriesICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Grid Store Fixture//EN
    CALSCALE:GREGORIAN
    X-WR-TIMEZONE:Pacific/Auckland
    BEGIN:VEVENT
    UID:all-day-auckland-monthly-series@example.com
    DTSTAMP:20260625T121000Z
    DTSTART;VALUE=DATE:20260405
    DTEND;VALUE=DATE:20260406
    RRULE:FREQ=MONTHLY;COUNT=4;BYMONTHDAY=5
    SUMMARY:Auckland monthly all-day recurrence
    END:VEVENT
    END:VCALENDAR
    """

    private static func sameInstant(_ date: Date, _ expected: String) -> Bool {
        guard let expectedDate = try? Self.date(expected) else { return false }
        return abs(date.timeIntervalSince(expectedDate)) < 1
    }

    private static func sameLocalDay(_ date: Date, _ expectedDay: String) -> Bool {
        localDayString(date) == expectedDay
    }

    private static func localDayString(_ date: Date) -> String {
        localDayFormatter.string(from: date)
    }

    private static func localDayString(_ date: Date, timeZoneIdentifier: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    @MainActor
    private static func attendeeStatus(
        in store: LocalCalendarStore,
        calendarID: String,
        email: String
    ) -> EventResponseStatus? {
        store.events
            .first { $0.calendarID == calendarID }?
            .attendees
            .first { $0.email.caseInsensitiveCompare(email) == .orderedSame }?
            .status
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            throw CalendarGridStoreInvariantError("Invalid date fixture: \(value)")
        }
        return date
    }

    private static func localDayStart(_ value: String) throws -> Date {
        guard let date = localDayFormatter.date(from: value) else {
            throw CalendarGridStoreInvariantError("Invalid local day fixture: \(value)")
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
        guard condition() else { throw CalendarGridStoreInvariantError(message) }
    }
}

private struct CalendarGridStoreInvariantError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
