import Foundation

@main
struct VerifyICSProtocol {
    @MainActor
    static func main() throws {
        resetLocalCalendarStorage()
        try verifyVFreeBusyImport()
        try verifyUnsupportedCalendarComponents()
        resetLocalCalendarStorage()
        try verifySameUIDAcrossCalendarsStaysScoped()
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()

        let importSummary = try store.importICSText(requestICS)
        try expect(importSummary.eventsImported == 1, "Expected one imported recurring event")
        try expect(events(in: store, from: "2026-06-25T00:00:00Z", to: "2026-07-17T00:00:00Z").count == 3,
                   "Expected three weekly occurrences before cancellation")

        let updateSummary = try store.importICSText(requestUpdateICS)
        try expect(updateSummary.eventsImported == 0, "Expected same-UID REQUEST update not to import a duplicate event")
        try expect(updateSummary.eventsUpdated == 1, "Expected same-UID REQUEST update to update the existing event")
        try expect(events(in: store, from: "2026-06-25T00:00:00Z", to: "2026-07-17T00:00:00Z").count == 3,
                   "Expected same-UID REQUEST update to preserve the occurrence count")
        try expect(
            store.calendars.count == 2,
            "Expected same-UID REQUEST update not to create an unused calendar, got \(store.calendars.map { "\($0.title):\($0.id)" })"
        )
        let updatedEvent = try requireFirstEvent(in: store, from: "2026-06-25T00:00:00Z", to: "2026-06-26T00:00:00Z")
        try expect(updatedEvent.title == "Protocol fixture updated", "Expected same-UID REQUEST update to replace event details")

        let staleSummary = try store.importICSText(staleRequestICS)
        try expect(staleSummary.eventsImported == 0, "Expected stale same-UID REQUEST not to import a duplicate")
        try expect(staleSummary.eventsUpdated == 0, "Expected stale same-UID REQUEST not to update the existing event")
        try expect(staleSummary.eventsSkipped == 1, "Expected stale same-UID REQUEST to be skipped")
        let eventAfterStaleUpdate = try requireFirstEvent(in: store, from: "2026-06-25T00:00:00Z", to: "2026-06-26T00:00:00Z")
        try expect(eventAfterStaleUpdate.title == "Protocol fixture updated", "Expected stale REQUEST not to roll back event details")

        let occurrenceUpdateSummary = try store.importICSText(occurrenceUpdateICS)
        try expect(occurrenceUpdateSummary.eventsImported == 0, "Expected orphan RECURRENCE-ID update not to import a duplicate event")
        try expect(occurrenceUpdateSummary.eventsUpdated == 1, "Expected orphan RECURRENCE-ID update to update one occurrence")
        let occurrenceUpdateEvent = try requireFirstEvent(in: store, from: "2026-07-02T00:00:00Z", to: "2026-07-03T00:00:00Z")
        try expect(occurrenceUpdateEvent.isDetached, "Expected orphan RECURRENCE-ID update to create a detached occurrence")
        try expect(occurrenceUpdateEvent.title == "Protocol occurrence moved", "Expected detached occurrence to use updated occurrence details")
        try expect(sameInstant(occurrenceUpdateEvent.startDate, "2026-07-02T10:00:00Z"),
                   "Expected detached occurrence to move to the updated start time")

        do {
            _ = try LocalCalendarICSCodec.import(addOccurrenceICS)
            throw ProtocolInvariantError("METHOD:ADD should not import as a standalone event")
        } catch LocalICSImportError.noEvents {
            // Expected: ADD mutates an existing recurring event instead.
        }

        let addOccurrenceSummary = try store.importICSText(addOccurrenceICS)
        try expect(addOccurrenceSummary.eventsImported == 0, "METHOD:ADD should not import a new base event")
        try expect(addOccurrenceSummary.eventsUpdated == 1, "METHOD:ADD should update the existing recurring event")
        try expect(addOccurrenceSummary.eventsSkipped == 0, "METHOD:ADD should not skip a matching recurring event")
        try expect(store.events.count == 1, "METHOD:ADD should not create a duplicate local event")
        let afterAddOccurrences = events(in: store, from: "2026-06-25T00:00:00Z", to: "2026-07-24T00:00:00Z")
        try expect(afterAddOccurrences.count == 4, "METHOD:ADD should add one extra occurrence to the recurring event")
        let addedOccurrences = afterAddOccurrences.filter { sameInstant($0.startDate, "2026-07-22T11:00:00Z") }
        try expect(addedOccurrences.count == 1, "Expected exactly one METHOD:ADD added occurrence")
        guard let addedOccurrence = addedOccurrences.first else {
            throw ProtocolInvariantError("Expected METHOD:ADD added occurrence")
        }
        try expect(addedOccurrence.isDetached, "METHOD:ADD occurrence should preserve per-instance details")
        try expect(addedOccurrence.title == "Protocol added office hours", "METHOD:ADD occurrence should preserve its summary")
        let addedBaseEvent = try requireOnly(store.events.filter { $0.externalUID == uid }, context: "METHOD:ADD base event")
        try expect(addedBaseEvent.additionalOccurrenceStartDates.contains { sameInstant($0, "2026-07-22T11:00:00Z") },
                   "METHOD:ADD should persist the added occurrence start as an RDATE-style occurrence")
        try expect(addedBaseEvent.detachedOccurrences.contains { sameInstant($0.originalStartDate, "2026-07-22T11:00:00Z") },
                   "METHOD:ADD should persist instance-specific details as a detached occurrence")

        do {
            _ = try LocalCalendarICSCodec.import(replyICS)
            throw ProtocolInvariantError("Incomplete METHOD:REPLY should not import as a full event")
        } catch LocalICSImportError.noEvents {
            // Expected: reply files are applied to existing events instead.
        }

        do {
            _ = try LocalCalendarICSCodec.import(replyWithDatesICS)
            throw ProtocolInvariantError("Dated METHOD:REPLY should not import as a full event")
        } catch LocalICSImportError.noEvents {
            // Expected: reply files can carry scheduling dates without becoming local events.
        }

        do {
            _ = try LocalCalendarICSCodec.import(refreshICS)
            throw ProtocolInvariantError("METHOD:REFRESH should not import as a full event")
        } catch LocalICSImportError.noEvents {
            // Expected: refresh requests ask for current event state instead of creating events.
        }
        try expect(store.events.count == 1, "METHOD:REFRESH should not change imported events")

        let datedReplies = LocalCalendarICSCodec.replies(from: replyWithDatesICS)
        try expect(datedReplies.count == 1, "Expected one dated attendee reply target")
        try expect(datedReplies.first?.attendees.first?.status == .tentative, "Expected tentative dated attendee reply")

        let appliedDatedReplies = store.applyReplies(datedReplies)
        try expect(appliedDatedReplies == 1, "Expected the dated attendee reply to update one local event")
        try expect(store.events.count == 1, "Dated METHOD:REPLY should not create a second local event")
        let tentativelyRepliedEvent = try requireFirstEvent(in: store, from: "2026-06-25T00:00:00Z", to: "2026-06-26T00:00:00Z")
        let tentativelyRepliedAttendee = tentativelyRepliedEvent.participants.first {
            $0.email.caseInsensitiveCompare(attendeeEmail) == .orderedSame
        }
        try expect(tentativelyRepliedAttendee?.status == .tentative,
                   "Expected dated METHOD:REPLY to update attendee PARTSTAT without importing an event")

        let replies = LocalCalendarICSCodec.replies(from: replyICS)
        try expect(replies.count == 1, "Expected one attendee reply target")
        try expect(replies.first?.attendees.first?.status == .accepted, "Expected accepted attendee reply")

        let appliedReplies = store.applyReplies(replies)
        try expect(appliedReplies == 1, "Expected the attendee reply to update one local event")

        let repliedEvent = try requireFirstEvent(in: store, from: "2026-06-25T00:00:00Z", to: "2026-06-26T00:00:00Z")
        let repliedAttendee = repliedEvent.participants.first {
            $0.email.caseInsensitiveCompare(attendeeEmail) == .orderedSame
        }
        try expect(repliedAttendee?.status == .accepted, "Expected METHOD:REPLY to update attendee PARTSTAT")

        let localRepliedEvent = try requireOnly(
            store.events.filter { $0.externalUID == uid },
            context: "encoded RSVP identity fixture"
        )
        guard let encodedFallbackReply = LocalCalendarICSCodec.reply(
            event: localRepliedEvent,
            response: .maybe,
            attendeeEmail: "SMTP:teammate%40example.com?subject=rsvp#fragment",
            attendeeName: "Teammate",
            now: date("2026-06-25T08:25:00Z")
        ) else {
            throw ProtocolInvariantError("Expected encoded fallback RSVP identity to generate a REPLY")
        }
        let encodedFallbackReplyLines = unfoldedICSLines(from: encodedFallbackReply)
        try expect(encodedFallbackReplyLines.contains {
            $0.contains("ATTENDEE;PARTSTAT=TENTATIVE")
                && $0.contains("CN=\"Teammate\":mailto:\(attendeeEmail)")
        }, "Expected encoded SMTP fallback identity to target the existing attendee")
        try expect(!encodedFallbackReply.contains("SMTP:"),
                   "Encoded SMTP fallback identity should not be emitted as a synthetic attendee URI")

        let encodedIdentityReplies = [
            LocalICSReply(
                externalUID: uid,
                occurrenceStartDate: nil,
                attendees: [
                    LocalEventAttendee(
                        name: "Teammate",
                        email: "SMTP:teammate%40example.com?subject=rsvp#fragment",
                        status: .tentative,
                        type: "person",
                        role: "required",
                        rsvp: false,
                        isCurrentUser: false
                    )
                ]
            )
        ]
        let appliedEncodedIdentityReplies = store.applyReplies(encodedIdentityReplies)
        try expect(appliedEncodedIdentityReplies == 1, "Expected encoded SMTP identity reply to update one local event")
        let encodedIdentityEvent = try requireFirstEvent(in: store, from: "2026-06-25T00:00:00Z", to: "2026-06-26T00:00:00Z")
        let canonicalIdentityAttendees = encodedIdentityEvent.participants.filter {
            $0.email.caseInsensitiveCompare(attendeeEmail) == .orderedSame
        }
        try expect(canonicalIdentityAttendees.count == 1,
                   "Encoded SMTP identity reply should update the existing attendee instead of creating a duplicate")
        try expect(canonicalIdentityAttendees.first?.status == .tentative,
                   "Encoded SMTP identity reply should update the matched attendee response")
        try expect(!encodedIdentityEvent.participants.contains { $0.email.lowercased().hasPrefix("smtp:") },
                   "Encoded SMTP identity reply should not persist a transport URI as attendee email")

        let occurrenceReplies = LocalCalendarICSCodec.replies(from: occurrenceReplyICS)
        try expect(occurrenceReplies.count == 1, "Expected one recurrence attendee reply target")
        try expect(occurrenceReplies.first?.occurrenceStartDate.map { sameInstant($0, "2026-07-09T09:00:00Z") } == true,
                   "Expected recurrence reply to preserve RECURRENCE-ID")

        let appliedOccurrenceReplies = store.applyReplies(occurrenceReplies)
        try expect(appliedOccurrenceReplies == 1, "Expected recurrence reply to create one detached occurrence")

        let occurrenceReplyEvent = try requireFirstEvent(in: store, from: "2026-07-09T00:00:00Z", to: "2026-07-10T00:00:00Z")
        try expect(occurrenceReplyEvent.isDetached, "Expected recurrence reply to be represented as a detached occurrence")
        let occurrenceReplyAttendee = occurrenceReplyEvent.participants.first {
            $0.email.caseInsensitiveCompare(attendeeEmail) == .orderedSame
        }
        try expect(occurrenceReplyAttendee?.status == .declined, "Expected recurrence reply to override attendee status only for that occurrence")

        let occurrenceTargets = LocalCalendarICSCodec.cancellationTargets(from: occurrenceCancelICS)
        try expect(occurrenceTargets.eventUIDs.isEmpty, "Occurrence cancellation must not target the whole series")
        try expect(occurrenceTargets.occurrences.count == 1, "Expected one recurrence cancellation target")

        let changedOccurrences = store.cancelOccurrences(cancellations: occurrenceTargets.occurrences)
        try expect(changedOccurrences == 1, "Expected one recurring event to record an excluded occurrence")

        let remainingAfterOccurrenceCancel = events(in: store, from: "2026-06-25T00:00:00Z", to: "2026-07-17T00:00:00Z")
        try expect(remainingAfterOccurrenceCancel.count == 2,
                   "Expected two occurrences after cancelling one recurrence instance")
        try expect(!remainingAfterOccurrenceCancel.contains { sameInstant($0.startDate, "2026-07-02T09:00:00Z") },
                   "Cancelled recurrence instance should not be emitted")

        let futureTargets = LocalCalendarICSCodec.cancellationTargets(from: futureCancelICS)
        try expect(futureTargets.occurrences.count == 1, "Expected one this-and-future cancellation target")
        try expect(futureTargets.occurrences.first?.appliesToFutureOccurrences == true,
                   "Expected RANGE=THISANDFUTURE to be preserved on the cancellation target")

        let changedFutureOccurrences = store.cancelOccurrences(cancellations: futureTargets.occurrences)
        try expect(changedFutureOccurrences == 1, "Expected this-and-future cancellation to truncate one recurring event")

        let remainingAfterFutureCancel = events(in: store, from: "2026-06-25T00:00:00Z", to: "2026-07-17T00:00:00Z")
        try expect(remainingAfterFutureCancel.count == 1,
                   "Expected only the first occurrence after this-and-future cancellation")
        try expect(!remainingAfterFutureCancel.contains { sameInstant($0.startDate, "2026-07-09T09:00:00Z") },
                   "This-and-future cancellation should remove the future detached occurrence")

        let seriesTargets = LocalCalendarICSCodec.cancellationTargets(from: seriesCancelICS)
        try expect(seriesTargets.eventUIDs == [uid], "Series cancellation should target the event UID")
        try expect(seriesTargets.occurrences.isEmpty, "Series cancellation should not target a recurrence instance")

        let deletedEvents = store.removeEvents(externalUIDs: seriesTargets.eventUIDs)
        try expect(deletedEvents == 1, "Expected the recurring base event to be deleted by UID")
        try expect(events(in: store, from: "2026-06-25T00:00:00Z", to: "2026-07-17T00:00:00Z").isEmpty,
                   "Expected no occurrences after full series cancellation")

        let alarmSummary = try store.importICSText(alarmICS)
        try expect(alarmSummary.eventsImported == 1, "Expected VALARM fixture to import one event")
        let alarmEvent = try requireFirstEvent(in: store, from: "2026-07-20T00:00:00Z", to: "2026-07-21T00:00:00Z")
        try expect(alarmEvent.reminderOffsets == [0, 5, 10], "Expected VALARM trigger/repeat to import reminder offsets")
        let exportedAlarmText = store.exportICSText()
        try expect(exportedAlarmText.contains("BEGIN:VALARM"), "Expected exported event to preserve reminder alarms")
        try expect(exportedAlarmText.contains("TRIGGER:-PT10M"), "Expected exported event to preserve a 10 minute alarm")

        let absoluteAlarmImport = try LocalCalendarICSCodec.import(absoluteAlarmICS)
        let absoluteAlarmEvent = try requireOnly(
            absoluteAlarmImport.events.filter { $0.externalUID == "absolute-alarm-fixture@example.com" },
            context: "absolute alarm event"
        )
        try expect(absoluteAlarmEvent.reminderOffsets == [20, 30],
                   "Expected absolute VALARM triggers to import as minutes before start")
        let exportedAbsoluteAlarmText = LocalCalendarICSCodec.export(
            calendars: absoluteAlarmImport.calendars,
            events: absoluteAlarmImport.events
        )
        try expect(exportedAbsoluteAlarmText.contains("TRIGGER:-PT20M"),
                   "Expected absolute VALARM export to normalize to a relative 20 minute trigger")
        try expect(exportedAbsoluteAlarmText.contains("TRIGGER:-PT30M"),
                   "Expected timezone-aware absolute VALARM export to normalize to a relative 30 minute trigger")

        let deepLinkSummary = try store.importICSText(deepLinkMeetingICS)
        try expect(deepLinkSummary.eventsImported == 1, "Expected deep-link meeting fixture to import one event")
        let deepLinkEvent = try requireFirstEvent(in: store, from: "2026-07-22T00:00:00Z", to: "2026-07-23T00:00:00Z")
        try expect(deepLinkEvent.url?.absoluteString == "https://calendar.example.com/events/deep-link-fixture",
                   "Expected the generic event page URL to remain stored as the event URL")
        try expect(deepLinkEvent.joinURL?.absoluteString == "zoommtg://zoom.us/join?action=join&confno=123456789",
                   "Expected meeting join URL to prefer the Zoom deep link from CONFERENCE over a generic event page")
        try expect(deepLinkEvent.meetingPlatform == .zoom,
                   "Expected Zoom deep-link scheme to resolve to the Zoom meeting platform")

        let popularMeetingSummary = try store.importICSText(popularMeetingProviderICS)
        try expect(popularMeetingSummary.eventsImported == 1, "Expected popular meeting provider fixture to import one event")
        let popularMeetingEvent = try requireFirstEvent(
            in: store,
            from: "2026-07-23T00:00:00Z",
            to: "2026-07-24T00:00:00Z",
            externalIdentifier: "popular-meeting-provider-fixture@example.com"
        )
        try expect(popularMeetingEvent.url?.absoluteString == "https://calendar.example.com/events/popular-provider-fixture",
                   "Expected generic event page URL to stay stored as the event URL")
        try expect(popularMeetingEvent.joinURL?.absoluteString == "https://meet.goto.com/123456789",
                   "Expected meeting join URL to prefer the GoTo Meeting link from the description")
        try expect(popularMeetingEvent.meetingPlatform == .goToMeeting,
                   "Expected GoTo Meeting links to resolve to a specific meeting provider")

        let pathAwareMeetingSummary = try store.importICSText(pathAwareMeetingProviderICS)
        try expect(pathAwareMeetingSummary.eventsImported == 1, "Expected path-aware meeting provider fixture to import one event")
        let pathAwareMeetingEvent = try requireFirstEvent(
            in: store,
            from: "2026-07-24T00:00:00Z",
            to: "2026-07-25T00:00:00Z",
            externalIdentifier: "path-aware-meeting-provider-fixture@example.com"
        )
        try expect(pathAwareMeetingEvent.url?.absoluteString == "https://calendar.example.com/events/path-aware-provider-fixture",
                   "Expected path-aware generic event page URL to stay stored as the event URL")
        try expect(pathAwareMeetingEvent.joinURL?.absoluteString == "https://slack.com/huddle/T123/C456",
                   "Expected meeting join URL to prefer the Slack Huddle link from the description path")
        try expect(pathAwareMeetingEvent.meetingPlatform == .slackHuddle,
                   "Expected Slack Huddle links to resolve to a specific meeting provider")

        let facetimeURL = URL(string: "https://calendar.example.com/events/facetime-placeholder")!
        let facetimeJoinURL = MeetingLinkExtractor.bestLink(
            eventURL: facetimeURL,
            textFields: ["Join FaceTime: https://facetime.apple.com/join#v=1&p=fixture"]
        )
        try expect(facetimeJoinURL?.absoluteString == "https://facetime.apple.com/join#v=1&p=fixture",
                   "Expected FaceTime web links to be preferred over a generic event page URL")
        try expect(facetimeJoinURL.flatMap(MeetingPlatform.init(url:)) == .faceTime,
                   "Expected FaceTime web links to resolve to a specific meeting provider")

        let durationSummary = try store.importICSText(durationICS)
        try expect(durationSummary.eventsImported == 1, "Expected DURATION fixture to import one event")
        let durationEvent = try requireFirstEvent(in: store, from: "2026-07-21T00:00:00Z", to: "2026-07-22T00:00:00Z")
        try expect(durationEvent.durationMinutes == 75, "Expected DURATION to determine the event end time")
        try expect(sameInstant(durationEvent.endDate, "2026-07-21T10:15:00Z"), "Expected DURATION import to end at 10:15Z")

        let outlookBusyStatusImport = try LocalCalendarICSCodec.import(outlookBusyStatusICS)
        try expect(outlookBusyStatusImport.events.count == 2, "Expected Outlook busy status fixture to import two events")
        let outlookFreeEvent = try requireOnly(
            outlookBusyStatusImport.events.filter { $0.externalUID == "outlook-free-busystatus-fixture@example.com" },
            context: "Outlook free busy-status event"
        )
        let outlookTentativeEvent = try requireOnly(
            outlookBusyStatusImport.events.filter { $0.externalUID == "outlook-tentative-busystatus-fixture@example.com" },
            context: "Outlook tentative busy-status event"
        )
        try expect(outlookFreeEvent.availability == .free,
                   "Expected Outlook X-MICROSOFT-CDO-BUSYSTATUS:FREE to import as free time")
        try expect(outlookTentativeEvent.availability == .busy,
                   "Expected Outlook X-MICROSOFT-CDO-BUSYSTATUS:TENTATIVE to remain busy time")
        try expect(outlookTentativeEvent.status == .tentative,
                   "Expected Outlook X-MICROSOFT-CDO-BUSYSTATUS:TENTATIVE to import as tentative status")

        let outlookImportanceImport = try LocalCalendarICSCodec.import(outlookImportanceICS)
        try expect(outlookImportanceImport.events.count == 3, "Expected Outlook importance fixture to import three events")
        let outlookHighImportanceEvent = try requireOnly(
            outlookImportanceImport.events.filter { $0.externalUID == "outlook-high-importance-fixture@example.com" },
            context: "Outlook high importance event"
        )
        let outlookLowImportanceEvent = try requireOnly(
            outlookImportanceImport.events.filter { $0.externalUID == "outlook-low-importance-fixture@example.com" },
            context: "Outlook low importance event"
        )
        let outlookPriorityOverrideEvent = try requireOnly(
            outlookImportanceImport.events.filter { $0.externalUID == "outlook-priority-override-fixture@example.com" },
            context: "Outlook priority override event"
        )
        try expect(outlookHighImportanceEvent.importance == .high,
                   "Expected Outlook X-MICROSOFT-CDO-IMPORTANCE:2 to import as high importance")
        try expect(outlookLowImportanceEvent.importance == .low,
                   "Expected Outlook X-MICROSOFT-CDO-IMPORTANCE:0 to import as low importance")
        try expect(outlookPriorityOverrideEvent.importance == .low,
                   "Expected standard PRIORITY to win over Outlook importance metadata")

        let outlookDisallowCounterImport = try LocalCalendarICSCodec.import(outlookDisallowCounterICS)
        let outlookDisallowCounterEvent = try requireOnly(
            outlookDisallowCounterImport.events.filter { $0.externalUID == "outlook-disallow-counter-fixture@example.com" },
            context: "Outlook disallow-counter event"
        )
        try expect(outlookDisallowCounterEvent.categories == ["Microsoft new time proposals disabled"],
                   "Expected Outlook X-MICROSOFT-DISALLOW-COUNTER:TRUE to import as Microsoft new-time-proposals metadata")

        let iTIPCounterProposalImport = try LocalCalendarICSCodec.import(iTIPCounterProposalICS)
        let iTIPCounterProposalEvent = try requireOnly(
            iTIPCounterProposalImport.events.filter { $0.externalUID == "itip-counter-proposal-fixture@example.com" },
            context: "iTIP counter-proposal event"
        )
        try expect(iTIPCounterProposalEvent.status == .tentative,
                   "Expected METHOD:COUNTER to import as tentative even when STATUS says confirmed")
        try expect(iTIPCounterProposalEvent.categories == ["iTIP counter proposal"],
                   "Expected METHOD:COUNTER to preserve counter-proposal metadata")
        try expect(sameInstant(iTIPCounterProposalEvent.startDate, "2026-07-23T15:00:00Z"),
                   "Expected METHOD:COUNTER to preserve proposed start time")

        let iTIPDeclineCounterImport = try LocalCalendarICSCodec.import(iTIPDeclineCounterICS)
        let iTIPDeclineCounterEvent = try requireOnly(
            iTIPDeclineCounterImport.events.filter { $0.externalUID == "itip-decline-counter-fixture@example.com" },
            context: "iTIP decline-counter event"
        )
        try expect(iTIPDeclineCounterEvent.status == .cancelled,
                   "Expected METHOD:DECLINECOUNTER to import as cancelled scheduling metadata")
        try expect(iTIPDeclineCounterEvent.categories == ["iTIP counter proposal declined"],
                   "Expected METHOD:DECLINECOUNTER to preserve decline-counter metadata")

        let outlookTimedAllDayImport = try LocalCalendarICSCodec.import(outlookTimedAllDayICS)
        let outlookTimedAllDayEvent = try requireOnly(
            outlookTimedAllDayImport.events.filter { $0.externalUID == "outlook-timed-all-day-fixture@example.com" },
            context: "Outlook timed all-day event"
        )
        try expect(outlookTimedAllDayEvent.isAllDay,
                   "Expected Outlook X-MICROSOFT-CDO-ALLDAYEVENT:TRUE to import timed midnight boundaries as all-day")
        try expect(Int(outlookTimedAllDayEvent.endDate.timeIntervalSince(outlookTimedAllDayEvent.startDate)) == 24 * 60 * 60,
                   "Expected Outlook timed all-day event to preserve one local day duration")
        let exportedOutlookTimedAllDayText = LocalCalendarICSCodec.export(
            calendars: outlookTimedAllDayImport.calendars,
            events: outlookTimedAllDayImport.events
        )
        try expect(exportedOutlookTimedAllDayText.contains("DTSTART;VALUE=DATE:20260724"),
                   "Expected Outlook timed all-day export to use date-only DTSTART")
        try expect(exportedOutlookTimedAllDayText.contains("DTEND;VALUE=DATE:20260725"),
                   "Expected Outlook timed all-day export to use date-only DTEND")

        let vendorLowercaseTimezoneImport = try LocalCalendarICSCodec.import(vendorLowercaseTimezoneICS)
        let vendorLowercaseTimezoneEvent = try requireOnly(
            vendorLowercaseTimezoneImport.events.filter { $0.externalUID == "vendor-lowercase-timezone-fixture@example.com" },
            context: "vendor lowercase timezone event"
        )
        try expect(vendorLowercaseTimezoneEvent.timeZoneIdentifier == "America/New_York",
                   "Expected lowercase vendor-prefixed TZID to normalize to America/New_York")
        try expect(sameInstant(vendorLowercaseTimezoneEvent.startDate, "2026-07-06T13:00:00Z"),
                   "Expected lowercase vendor-prefixed TZID to parse as New York local time")
        let exportedVendorLowercaseTimezoneText = LocalCalendarICSCodec.export(
            calendars: vendorLowercaseTimezoneImport.calendars,
            events: vendorLowercaseTimezoneImport.events
        )
        try expect(exportedVendorLowercaseTimezoneText.contains("DTSTART;TZID=America/New_York:20260706T090000"),
                   "Expected lowercase vendor-prefixed TZID to export as canonical America/New_York")

        let windowsTimezoneImport = try LocalCalendarICSCodec.import(windowsTimezoneICS)
        let windowsTimezoneEvent = try requireOnly(
            windowsTimezoneImport.events.filter { $0.externalUID == "windows-timezone-fixture@example.com" },
            context: "Windows timezone event"
        )
        try expect(windowsTimezoneEvent.timeZoneIdentifier == "Europe/Athens",
                   "Expected Outlook/Exchange Windows TZID to normalize to an IANA timezone")
        try expect(sameInstant(windowsTimezoneEvent.startDate, "2026-07-06T06:00:00Z"),
                   "Expected Outlook/Exchange Windows TZID to parse as local Athens/Nicosia time")
        let exportedWindowsTimezoneText = LocalCalendarICSCodec.export(
            calendars: windowsTimezoneImport.calendars,
            events: windowsTimezoneImport.events
        )
        try expect(exportedWindowsTimezoneText.contains("DTSTART;TZID=Europe/Athens:20260706T090000"),
                   "Expected Outlook/Exchange Windows TZID import to export as canonical IANA timezone")

        let xLicLocationTimezoneImport = try LocalCalendarICSCodec.import(xLicLocationTimezoneICS)
        let xLicLocationTimezoneEvent = try requireOnly(
            xLicLocationTimezoneImport.events.filter { $0.externalUID == "x-lic-location-timezone-fixture@example.com" },
            context: "X-LIC-LOCATION timezone import"
        )
        try expect(xLicLocationTimezoneEvent.timeZoneIdentifier == "America/New_York",
                   "Expected VTIMEZONE X-LIC-LOCATION to canonicalize a custom TZID to America/New_York")
        try expect(sameInstant(xLicLocationTimezoneEvent.startDate, "2026-07-06T13:00:00Z"),
                   "Expected custom TZID with X-LIC-LOCATION to parse as New York local time")
        let exportedXLicLocationTimezoneText = LocalCalendarICSCodec.export(
            calendars: xLicLocationTimezoneImport.calendars,
            events: xLicLocationTimezoneImport.events
        )
        try expect(exportedXLicLocationTimezoneText.contains("DTSTART;TZID=America/New_York:20260706T090000"),
                   "Expected X-LIC-LOCATION timezone import to export using canonical America/New_York")

        let floatingTimezoneImport = try LocalCalendarICSCodec.import(floatingCalendarTimezoneICS)
        let floatingTimezoneEvent = try requireOnly(
            floatingTimezoneImport.events.filter { $0.externalUID == "floating-calendar-timezone-fixture@example.com" },
            context: "floating calendar timezone import"
        )
        try expect(floatingTimezoneEvent.timeZoneIdentifier == "Asia/Nicosia",
                   "Expected X-WR-TIMEZONE to apply to floating timed DTSTART")
        try expect(sameInstant(floatingTimezoneEvent.startDate, "2026-07-06T06:00:00Z"),
                   "Expected floating timed DTSTART to parse in the calendar timezone")
        try expect(floatingTimezoneEvent.additionalOccurrenceStartDates.contains { sameInstant($0, "2026-07-08T06:00:00Z") },
                   "Expected floating timed RDATE to parse in the calendar timezone")
        try expect(floatingTimezoneEvent.excludedOccurrenceStartDates.contains { sameInstant($0, "2026-07-13T06:00:00Z") },
                   "Expected floating timed EXDATE to parse in the calendar timezone")
        let exportedFloatingTimezoneText = LocalCalendarICSCodec.export(
            calendars: floatingTimezoneImport.calendars,
            events: floatingTimezoneImport.events
        )
        try expect(exportedFloatingTimezoneText.contains("DTSTART;TZID=Asia/Nicosia:20260706T090000"),
                   "Expected floating timed export to preserve the calendar timezone")
        try expect(exportedFloatingTimezoneText.contains("RDATE;TZID=Asia/Nicosia:20260708T090000"),
                   "Expected floating timed RDATE export to preserve the calendar timezone")

        let allDaySummary = try store.importICSText(allDayICS)
        try expect(allDaySummary.eventsImported == 1, "Expected date-only all-day fixture to import one event")
        let allDayEvent = try requireFirstEvent(in: store, from: "2026-07-22T00:00:00Z", to: "2026-07-23T00:00:00Z")
        try expect(allDayEvent.isAllDay, "Expected VALUE=DATE DTSTART to import as an all-day event")
        try expect(allDayEvent.durationMinutes == 24 * 60, "Expected missing all-day DTEND to default to one day")
        let exportedAllDayText = store.exportICSText()
        try expect(exportedAllDayText.contains("DTSTART;VALUE=DATE:20260722"), "Expected all-day export to preserve date-only DTSTART")
        try expect(exportedAllDayText.contains("DTEND;VALUE=DATE:20260723"), "Expected all-day export to synthesize next-day DTEND")

        let allDayMissingEndDSTImport = try LocalCalendarICSCodec.import(allDayMissingEndDSTICS)
        guard allDayMissingEndDSTImport.events.count == 1, let allDayMissingEndDSTEvent = allDayMissingEndDSTImport.events.first else {
            throw ProtocolInvariantError("Expected all-day DST fixture to import one event")
        }
        try expect(allDayMissingEndDSTEvent.isAllDay, "Expected DST all-day DTSTART to import as all-day")
        try expect(sameInstant(allDayMissingEndDSTEvent.startDate, "2026-04-04T11:00:00Z"),
                   "Expected DST all-day DTSTART to parse as midnight in Pacific/Auckland")
        try expect(sameInstant(allDayMissingEndDSTEvent.endDate, "2026-04-05T12:00:00Z"),
                   "Expected missing all-day DTEND to synthesize the next local date across DST")
        let allDayMissingEndDSTExport = LocalCalendarICSCodec.export(
            calendars: allDayMissingEndDSTImport.calendars,
            events: allDayMissingEndDSTImport.events
        )
        try expect(allDayMissingEndDSTExport.contains("DTSTART;VALUE=DATE:20260405"),
                   "Expected DST all-day export to preserve local DTSTART date")
        try expect(allDayMissingEndDSTExport.contains("DTEND;VALUE=DATE:20260406"),
                   "Expected DST all-day export to synthesize the next local date")

        let allDayDurationDSTImport = try LocalCalendarICSCodec.import(allDayDurationDSTICS)
        guard allDayDurationDSTImport.events.count == 1, let allDayDurationDSTEvent = allDayDurationDSTImport.events.first else {
            throw ProtocolInvariantError("Expected all-day DURATION DST fixture to import one event")
        }
        try expect(allDayDurationDSTEvent.isAllDay, "Expected all-day DURATION DTSTART to import as all-day")
        try expect(sameInstant(allDayDurationDSTEvent.startDate, "2026-04-04T11:00:00Z"),
                   "Expected all-day DURATION DTSTART to parse as midnight in Pacific/Auckland")
        try expect(sameInstant(allDayDurationDSTEvent.endDate, "2026-04-05T12:00:00Z"),
                   "Expected all-day DURATION:P1D to end at the next local date across DST")
        let allDayDurationDSTExport = LocalCalendarICSCodec.export(
            calendars: allDayDurationDSTImport.calendars,
            events: allDayDurationDSTImport.events
        )
        try expect(allDayDurationDSTExport.contains("DTSTART;VALUE=DATE:20260405"),
                   "Expected all-day DURATION export to preserve local DTSTART date")
        try expect(allDayDurationDSTExport.contains("DTEND;VALUE=DATE:20260406"),
                   "Expected all-day DURATION export to preserve the next local date")

        let allDayTimezoneImport = try LocalCalendarICSCodec.import(allDayTimezoneICS)
        guard allDayTimezoneImport.events.count == 1, let allDayTimezoneEvent = allDayTimezoneImport.events.first else {
            throw ProtocolInvariantError("Expected timezone-sensitive all-day fixture to import one event")
        }
        try expect(allDayTimezoneEvent.isAllDay, "Expected timezone-sensitive date-only DTSTART to import as all-day")
        try expect(allDayTimezoneEvent.timeZoneIdentifier == "Pacific/Auckland", "Expected X-WR-TIMEZONE to become the all-day event timezone")
        try expect(sameInstant(allDayTimezoneEvent.startDate, "2026-06-30T12:00:00Z"),
                   "Expected all-day DTSTART to parse as midnight in Pacific/Auckland, not the machine timezone")
        try expect(sameInstant(allDayTimezoneEvent.endDate, "2026-07-01T12:00:00Z"),
                   "Expected all-day DTEND to parse as midnight in Pacific/Auckland, not the machine timezone")
        try expect(allDayTimezoneEvent.additionalOccurrenceStartDates.contains { sameInstant($0, "2026-07-04T12:00:00Z") },
                   "Expected all-day RDATE to parse as midnight in Pacific/Auckland")
        try expect(allDayTimezoneEvent.excludedOccurrenceStartDates.contains { sameInstant($0, "2026-07-07T12:00:00Z") },
                   "Expected all-day EXDATE to parse as midnight in Pacific/Auckland")
        try expect(allDayTimezoneEvent.recurrenceEndDate.map { sameInstant($0, "2026-07-14T12:00:00Z") } == true,
                   "Expected all-day RRULE UNTIL=DATE to parse as midnight in Pacific/Auckland")
        let allDayTimezoneExport = LocalCalendarICSCodec.export(calendars: allDayTimezoneImport.calendars, events: allDayTimezoneImport.events)
        try expect(allDayTimezoneExport.contains("DTSTART;VALUE=DATE:20260701"),
                   "Expected timezone-sensitive all-day export to preserve local DTSTART date")
        try expect(allDayTimezoneExport.contains("RDATE;VALUE=DATE:20260705"),
                   "Expected timezone-sensitive all-day export to preserve local RDATE")
        try expect(allDayTimezoneExport.contains("EXDATE;VALUE=DATE:20260708"),
                   "Expected timezone-sensitive all-day export to preserve local EXDATE")
        try expect(allDayTimezoneExport.contains("UNTIL=20260715"),
                   "Expected timezone-sensitive all-day export to preserve local RRULE UNTIL")

        let allDayTimezoneCountImport = try LocalCalendarICSCodec.import(allDayTimezoneCountICS)
        guard allDayTimezoneCountImport.events.count == 1, let allDayTimezoneCountEvent = allDayTimezoneCountImport.events.first else {
            throw ProtocolInvariantError("Expected timezone-sensitive all-day COUNT fixture to import one event")
        }
        try expect(allDayTimezoneCountEvent.recurrenceEndDate.map { sameInstant($0, "2026-04-18T12:00:00Z") } == true,
                   "Expected all-day RRULE COUNT to resolve the last occurrence in Pacific/Auckland")
        let allDayTimezoneCountExport = LocalCalendarICSCodec.export(
            calendars: allDayTimezoneCountImport.calendars,
            events: allDayTimezoneCountImport.events
        )
        try expect(allDayTimezoneCountExport.contains("UNTIL=20260419"),
                   "Expected timezone-sensitive all-day COUNT export to preserve the last local occurrence date")

        let allDayRecurrenceSummary = try store.importICSText(allDayRecurrenceICS)
        try expect(allDayRecurrenceSummary.eventsImported == 1, "Expected all-day recurrence fixture to import one event")
        let allDayRecurrences = events(in: store, from: "2026-07-05T00:00:00Z", to: "2026-07-22T00:00:00Z")
            .filter { $0.externalIdentifier == "all-day-recurrence-fixture@example.com" }
        try expect(allDayRecurrences.count == 3, "Expected all-day RDATE/EXDATE recurrence to emit exactly three occurrences")
        try expect(
            Set(allDayRecurrences.map { localDayString($0.startDate) }) == ["2026-07-06", "2026-07-09", "2026-07-20"],
            "Expected all-day recurrence to include RRULE/RDATE dates and omit EXDATE"
        )
        try expect(allDayRecurrences.allSatisfy(\.isAllDay), "Expected all-day recurrence occurrences to remain all-day")
        let exportedAllDayRecurrenceText = store.exportICSText()
        try expect(exportedAllDayRecurrenceText.contains("RDATE;VALUE=DATE:20260709"), "Expected all-day RDATE to export as a date-only value")
        try expect(exportedAllDayRecurrenceText.contains("EXDATE;VALUE=DATE:20260713"), "Expected all-day EXDATE to export as a date-only value")

        let multiValueRecurrenceImport = try LocalCalendarICSCodec.import(multiValueRecurrenceDatesICS)
        let multiValueRecurrenceEvent = try requireOnly(
            multiValueRecurrenceImport.events.filter { $0.externalUID == "multi-value-recurrence-dates-fixture@example.com" },
            context: "multi-value recurrence date event"
        )
        try expect(multiValueRecurrenceEvent.additionalOccurrenceStartDates.count == 2,
                   "Expected comma-separated RDATE to import both additional occurrence starts")
        try expect(multiValueRecurrenceEvent.additionalOccurrenceStartDates.contains { sameInstant($0, "2026-07-08T09:00:00Z") },
                   "Expected comma-separated RDATE to import the first additional occurrence")
        try expect(multiValueRecurrenceEvent.additionalOccurrenceStartDates.contains { sameInstant($0, "2026-07-10T09:00:00Z") },
                   "Expected comma-separated RDATE to import the second additional occurrence")
        try expect(multiValueRecurrenceEvent.excludedOccurrenceStartDates.count == 2,
                   "Expected comma-separated EXDATE to import both excluded occurrence starts")
        try expect(multiValueRecurrenceEvent.excludedOccurrenceStartDates.contains { sameInstant($0, "2026-07-13T09:00:00Z") },
                   "Expected comma-separated EXDATE to import the first excluded occurrence")
        try expect(multiValueRecurrenceEvent.excludedOccurrenceStartDates.contains { sameInstant($0, "2026-07-20T09:00:00Z") },
                   "Expected comma-separated EXDATE to import the second excluded occurrence")
        let exportedMultiValueRecurrenceText = LocalCalendarICSCodec.export(
            calendars: multiValueRecurrenceImport.calendars,
            events: multiValueRecurrenceImport.events
        )
        try expect(exportedMultiValueRecurrenceText.contains("RDATE;TZID=UTC:20260708T090000,20260710T090000"),
                   "Expected multi-value RDATE to export as a comma-separated timed line")
        try expect(exportedMultiValueRecurrenceText.contains("EXDATE;TZID=UTC:20260713T090000,20260720T090000"),
                   "Expected multi-value EXDATE to export as a comma-separated timed line")

        let rdatePeriodSummary = try store.importICSText(rdatePeriodICS)
        try expect(rdatePeriodSummary.eventsImported == 1, "Expected RDATE PERIOD fixture to import one event")
        let rdatePeriodEvent = try requireOnly(
            store.events.filter { $0.externalUID == "rdate-period-fixture@example.com" },
            context: "RDATE PERIOD event"
        )
        try expect(rdatePeriodEvent.additionalOccurrenceStartDates.count == 2,
                   "Expected RDATE PERIOD to persist both additional occurrence starts")
        try expect(rdatePeriodEvent.detachedOccurrences.count == 2,
                   "Expected RDATE PERIOD occurrences with custom durations to persist as detached occurrences")
        let rdatePeriodOccurrences = events(in: store, from: "2026-07-26T00:00:00Z", to: "2026-07-29T00:00:00Z")
            .filter { $0.externalIdentifier == "rdate-period-fixture@example.com" }
        try expect(rdatePeriodOccurrences.count == 3,
                   "Expected RDATE PERIOD event to emit the base event plus two period occurrences")
        let firstPeriodOccurrence = try requireOnlyCalendarEvent(
            rdatePeriodOccurrences.filter { sameInstant($0.startDate, "2026-07-27T09:00:00Z") },
            context: "first RDATE PERIOD occurrence"
        )
        let secondPeriodOccurrence = try requireOnlyCalendarEvent(
            rdatePeriodOccurrences.filter { sameInstant($0.startDate, "2026-07-28T10:00:00Z") },
            context: "second RDATE PERIOD occurrence"
        )
        try expect(firstPeriodOccurrence.durationMinutes == 45,
                   "Expected RDATE PERIOD duration form to preserve a 45 minute occurrence")
        try expect(secondPeriodOccurrence.durationMinutes == 60,
                   "Expected RDATE PERIOD explicit end form to preserve a 60 minute occurrence")
        let exportedRDATEPeriodText = store.exportICSText()
        try expect(exportedRDATEPeriodText.contains("RDATE;TZID=UTC:20260727T090000,20260728T100000"),
                   "Expected RDATE PERIOD export to keep extra occurrence starts")
        try expect(exportedRDATEPeriodText.contains("RECURRENCE-ID;TZID=UTC:20260727T090000"),
                   "Expected RDATE PERIOD export to preserve custom-duration occurrence identity")

        let allDayUntilSummary = try store.importICSText(allDayUntilRecurrenceICS)
        try expect(allDayUntilSummary.eventsImported == 1, "Expected all-day date-only UNTIL fixture to import one event")
        let allDayUntilOccurrences = events(in: store, from: "2026-07-01T00:00:00Z", to: "2026-07-31T00:00:00Z")
            .filter { $0.externalIdentifier == "all-day-until-recurrence-fixture@example.com" }
        try expect(allDayUntilOccurrences.count == 3, "Expected all-day date-only UNTIL recurrence to emit exactly three occurrences")
        try expect(
            Set(allDayUntilOccurrences.map { localDayString($0.startDate) }) == ["2026-07-06", "2026-07-13", "2026-07-20"],
            "Expected all-day date-only UNTIL recurrence to include the selected end day"
        )
        try expect(allDayUntilOccurrences.allSatisfy(\.isAllDay), "Expected date-only UNTIL recurrence occurrences to remain all-day")
        try expect(
            !allDayUntilOccurrences.contains { localDayString($0.startDate) == "2026-07-27" },
            "All-day date-only UNTIL recurrence should not emit occurrences after the selected end day"
        )
        let exportedAllDayUntilText = store.exportICSText()
        let exportedAllDayRuleLines = unfoldedICSLines(from: exportedAllDayUntilText)
            .filter { $0.hasPrefix("RRULE:") }
        let exportedAllDayUntilRules = exportedAllDayRuleLines
            .filter { $0.contains("UNTIL=20260720") }
        try expect(
            exportedAllDayUntilRules.contains {
                $0.contains("FREQ=WEEKLY")
                    && $0.contains("INTERVAL=1")
                    && $0.contains("BYDAY=MO")
                    && !$0.contains("UNTIL=20260720T")
            },
            "Expected all-day date-only UNTIL recurrence to export UNTIL as a date-only value, got rules \(exportedAllDayRuleLines)"
        )

        let foldedTextSummary = try store.importICSText(foldedTextICS)
        try expect(foldedTextSummary.eventsImported == 1, "Expected folded text fixture to import one event")
        let foldedTextOccurrences = events(in: store, from: "2026-07-06T00:00:00Z", to: "2026-07-22T00:00:00Z")
            .filter { $0.externalIdentifier == "folded-text-fixture@example.com" }
        try expect(foldedTextOccurrences.count == 5, "Expected folded RRULE line to unfold and emit five occurrences")
        let foldedTextEvent = try requireFirstEvent(
            in: store,
            from: "2026-07-06T00:00:00Z",
            to: "2026-07-07T00:00:00Z",
            externalIdentifier: "folded-text-fixture@example.com"
        )
        try expect(
            foldedTextEvent.title == "Folded summary with escaped comma, semicolon; and a continued tail",
            "Expected folded SUMMARY to unfold and unescape text"
        )
        try expect(
            foldedTextEvent.notes == "First line\nSecond line with comma, semicolon; and folded tail",
            "Expected folded DESCRIPTION to preserve escaped newline and punctuation"
        )
        try expect(
            foldedTextEvent.location == "CY-Office-1st-Conference, left wing",
            "Expected folded LOCATION to unescape punctuation"
        )
        try expect(
            foldedTextEvent.categories == ["alpha,beta", "launch;phase"],
            "Expected CATEGORIES to split only on unescaped commas"
        )
        let structuredLocationSummary = try store.importICSText(structuredLocationICS)
        try expect(structuredLocationSummary.eventsImported == 1,
                   "Expected Apple structured location fixture to import one event")
        let structuredLocationEvent = try requireFirstEvent(
            in: store,
            from: "2026-07-09T00:00:00Z",
            to: "2026-07-10T00:00:00Z",
            externalIdentifier: "structured-location-fixture@example.com"
        )
        try expect(structuredLocationEvent.location == "CY-Office-1st-Conference",
                   "Expected X-APPLE-STRUCTURED-LOCATION X-TITLE to become the event location")
        let structuredLocationNotes = structuredLocationEvent.notes ?? ""
        try expect(structuredLocationNotes == "Discuss location parsing",
                   "Expected structured location import to keep DESCRIPTION as the only note text")
        try expect(!structuredLocationNotes.localizedCaseInsensitiveContains("geo:"),
                   "Structured location geo URI should not be appended to notes")
        try expect(!structuredLocationNotes.localizedCaseInsensitiveContains("X-TITLE"),
                   "Structured location parameter names should not be appended to notes")
        let structuredLocationLocalEvent = try requireOnly(
            store.events.filter { $0.externalUID == "structured-location-fixture@example.com" },
            context: "structured location local event"
        )
        try expect(
            structuredLocationLocalEvent.geoCoordinate == LocalEventGeoCoordinate(latitude: 35.1856, longitude: 33.3823),
            "Expected Apple structured location geo URI to import as structured coordinates"
        )
        let geoImport = try LocalCalendarICSCodec.import(geoICS)
        let geoLocalEvent = try requireOnly(
            geoImport.events.filter { $0.externalUID == "geo-fixture@example.com" },
            context: "GEO import"
        )
        let expectedGeoCoordinate = LocalEventGeoCoordinate(latitude: 35.1856, longitude: 33.3823)
        try expect(geoLocalEvent.geoCoordinate == expectedGeoCoordinate,
                   "Expected iCalendar GEO to import as structured coordinates")
        let geoExportedText = LocalCalendarICSCodec.export(
            calendars: geoImport.calendars,
            events: geoImport.events
        )
        let geoExportedLines = unfoldedICSLines(from: geoExportedText)
        try expect(geoExportedLines.contains("GEO:35.1856;33.3823"),
                   "Expected GEO coordinates to export as an iCalendar GEO property")
        let geoRoundTrip = try LocalCalendarICSCodec.import(geoExportedText)
        let geoRoundTripEvent = try requireOnly(
            geoRoundTrip.events.filter { $0.externalUID == "geo-fixture@example.com" },
            context: "GEO round-trip import"
        )
        try expect(geoRoundTripEvent.geoCoordinate == expectedGeoCoordinate,
                   "Expected GEO coordinates to survive export/import round-trip")
        let resourcesSummary = try store.importICSText(resourcesICS)
        try expect(resourcesSummary.eventsImported == 1,
                   "Expected iCalendar RESOURCES fixture to import one event")
        let resourcesEvent = try requireFirstEvent(
            in: store,
            from: "2026-07-09T00:00:00Z",
            to: "2026-07-10T00:00:00Z",
            externalIdentifier: "resources-fixture@example.com"
        )
        let resourceNames = resourcesEvent.roomParticipants.map(\.displayName)
        try expect(resourceNames == ["CY-Office-1st-Conference", "Projector, HDMI"],
                   "Expected RESOURCES to become room/resource participants without duplicating room attendees")
        try expect(resourcesEvent.bestLocation == "CY-Office-1st-Conference, Projector, HDMI",
                   "Expected RESOURCES to participate in best physical location fallback")
        let resourcesLocalEvent = try requireOnly(
            store.events.filter { $0.externalUID == "resources-fixture@example.com" },
            context: "RESOURCES import"
        )
        try expect(resourcesLocalEvent.attendees.filter(\.isRoomLike).count == 2,
                   "Expected RESOURCES import to persist as room/resource attendees")
        let commentContactSummary = try store.importICSText(commentContactICS)
        try expect(commentContactSummary.eventsImported == 1,
                   "Expected iCalendar COMMENT/CONTACT fixture to import one event")
        let commentContactEvent = try requireFirstEvent(
            in: store,
            from: "2026-07-10T00:00:00Z",
            to: "2026-07-11T00:00:00Z",
            externalIdentifier: "comment-contact-fixture@example.com"
        )
        let commentContactNotes = commentContactEvent.notes ?? ""
        try expect(commentContactNotes.contains("Agenda stays in the description."),
                   "Expected DESCRIPTION to remain in notes when COMMENT/CONTACT is imported")
        try expect(commentContactNotes.contains("Comment: Backup bridge https://zoom.us/j/111222333?pwd=comment"),
                   "Expected COMMENT to be preserved with a readable label")
        try expect(commentContactNotes.contains("Contact: Ops Desk, Calendar"),
                   "Expected CONTACT to be preserved with a readable label")
        try expect(commentContactEvent.joinURL?.absoluteString == "https://zoom.us/j/111222333?pwd=comment",
                   "Expected meeting URL from COMMENT to become the event join URL")
        let relatedImport = try LocalCalendarICSCodec.import(relatedToICS)
        let relatedLocalEvent = try requireOnly(
            relatedImport.events.filter { $0.externalUID == "related-to-fixture@example.com" },
            context: "RELATED-TO import"
        )
        let expectedRelationships = [
            LocalEventRelationship(relationType: "PARENT", externalUID: "parent-event@example.com"),
            LocalEventRelationship(relationType: "SIBLING", externalUID: "sibling-event@example.com")
        ]
        try expect(relatedLocalEvent.relatedEvents == expectedRelationships,
                   "Expected RELATED-TO to import as normalized structured event relationships")
        let relatedExportedText = LocalCalendarICSCodec.export(
            calendars: relatedImport.calendars,
            events: relatedImport.events
        )
        let relatedExportedLines = unfoldedICSLines(from: relatedExportedText)
        try expect(relatedExportedLines.contains("RELATED-TO;RELTYPE=PARENT:parent-event@example.com"),
                   "Expected parent RELATED-TO to export as structured iCalendar metadata")
        try expect(relatedExportedLines.contains("RELATED-TO;RELTYPE=SIBLING:sibling-event@example.com"),
                   "Expected sibling RELATED-TO to export as structured iCalendar metadata")
        let relatedRoundTrip = try LocalCalendarICSCodec.import(relatedExportedText)
        let relatedRoundTripEvent = try requireOnly(
            relatedRoundTrip.events.filter { $0.externalUID == "related-to-fixture@example.com" },
            context: "RELATED-TO round-trip import"
        )
        try expect(relatedRoundTripEvent.relatedEvents == expectedRelationships,
                   "Expected RELATED-TO relationships to survive export/import round-trip")
        let attachmentImport = try LocalCalendarICSCodec.import(attachmentICS)
        let attachmentEvent = try requireOnly(
            attachmentImport.events.filter { $0.externalUID == "attachment-fixture@example.com" },
            context: "ATTACH import"
        )
        let expectedAttachments = [
            LocalEventAttachment(
                urlString: "https://files.example.com/agenda,q3.pdf?download=1",
                formatType: "application/pdf",
                displayName: "Agenda, Q3.pdf"
            ),
            LocalEventAttachment(
                urlString: "https://docs.example.com/notes",
                formatType: "text/html",
                displayName: "Planning notes"
            ),
            LocalEventAttachment(
                urlString: "https://zoom.us/j/222333444?pwd=attach",
                formatType: "text/html",
                displayName: "Zoom bridge"
            )
        ]
        try expect(attachmentEvent.attachments == expectedAttachments,
                   "Expected URI ATTACH properties to import as structured attachments and binary data to be skipped")
        let attachmentSummary = try store.importICSText(attachmentICS)
        try expect(attachmentSummary.eventsImported == 1,
                   "Expected iCalendar ATTACH fixture to import one event into the store")
        let attachmentVisibleEvent = try requireFirstEvent(
            in: store,
            from: "2026-07-10T00:00:00Z",
            to: "2026-07-11T00:00:00Z",
            externalIdentifier: "attachment-fixture@example.com"
        )
        try expect(attachmentVisibleEvent.joinURL?.absoluteString == "https://zoom.us/j/222333444?pwd=attach",
                   "Expected meeting URL from ATTACH to remain available as the event join URL")
        let attachmentExportedText = LocalCalendarICSCodec.export(
            calendars: attachmentImport.calendars,
            events: attachmentImport.events
        )
        let attachmentExportedLines = unfoldedICSLines(from: attachmentExportedText)
        try expect(
            attachmentExportedLines.contains("ATTACH;VALUE=URI;FMTTYPE=application/pdf;X-FILENAME=\"Agenda, Q3.pdf\":https://files.example.com/agenda\\,q3.pdf?download=1"),
            "Expected PDF ATTACH metadata to export with escaped punctuation"
        )
        try expect(
            attachmentExportedLines.contains("ATTACH;VALUE=URI;FMTTYPE=text/html;X-FILENAME=\"Planning notes\":https://docs.example.com/notes"),
            "Expected named HTML ATTACH metadata to export"
        )
        try expect(!attachmentExportedLines.contains { $0.contains("AAAA") },
                   "Expected binary ATTACH payloads to stay out of URI attachment export")
        let attachmentRoundTrip = try LocalCalendarICSCodec.import(attachmentExportedText)
        let attachmentRoundTripEvent = try requireOnly(
            attachmentRoundTrip.events.filter { $0.externalUID == "attachment-fixture@example.com" },
            context: "ATTACH round-trip import"
        )
        try expect(attachmentRoundTripEvent.attachments == expectedAttachments,
                   "Expected URI ATTACH metadata to survive export/import round-trip")
        let foldedParticipant = foldedTextEvent.participants.first {
            $0.email.caseInsensitiveCompare("folded@example.com") == .orderedSame
        }
        try expect(foldedParticipant?.displayName == "Folded Teammate; Lead", "Expected folded ATTENDEE CN parameter to unescape")
        try expect(foldedParticipant?.role == "optional", "Expected folded ATTENDEE role parameter to parse")
        try expect(foldedParticipant?.status == .tentative, "Expected folded ATTENDEE PARTSTAT to parse")
        try expect(foldedParticipant?.isCurrentUser == true, "Expected folded ATTENDEE Working metadata to parse")

        let caretParameterSummary = try store.importICSText(caretParameterICS)
        try expect(caretParameterSummary.eventsImported == 1, "Expected caret parameter fixture to import one event")
        let caretParameterEvent = try requireFirstEvent(
            in: store,
            from: "2026-07-07T00:00:00Z",
            to: "2026-07-08T00:00:00Z",
            externalIdentifier: "caret-parameter-fixture@example.com"
        )
        try expect(caretParameterEvent.organizer?.displayName == "Owner \"Ops\"^Lead",
                   "Expected ORGANIZER CN parameter to decode RFC6868 caret escapes")
        let caretParticipant = caretParameterEvent.participants.first {
            $0.email.caseInsensitiveCompare("alice@example.com") == .orderedSame
        }
        try expect(caretParticipant?.displayName == "Alice \"Calendar\"^Core",
                   "Expected ATTENDEE CN parameter to decode RFC6868 caret escapes")

        let quotedParameterSummary = try store.importICSText(quotedParameterICS)
        try expect(quotedParameterSummary.eventsImported == 1, "Expected quoted parameter fixture to import one event")
        let quotedParameterEvent = try requireFirstEvent(
            in: store,
            from: "2026-07-11T00:00:00Z",
            to: "2026-07-12T00:00:00Z",
            externalIdentifier: "quoted-parameter-fixture@example.com"
        )
        try expect(quotedParameterEvent.organizer?.displayName == "Owner: Ops; Lead",
                   "Expected ORGANIZER quoted CN parameter to preserve colon and semicolon")
        let quotedParticipant = quotedParameterEvent.participants.first {
            $0.email.caseInsensitiveCompare("quoted@example.com") == .orderedSame
        }
        try expect(quotedParticipant?.displayName == "Quoted: Teammate; Lead",
                   "Expected ATTENDEE quoted CN parameter to preserve colon and semicolon")
        try expect(quotedParticipant?.role == "optional", "Expected quoted ATTENDEE role parameter to parse")
        try expect(quotedParticipant?.status == .accepted, "Expected quoted ATTENDEE PARTSTAT parameter to parse")
        let quotedRawImport = try LocalCalendarICSCodec.import(quotedParameterICS)
        let quotedRawEvent = try requireOnly(
            quotedRawImport.events.filter { $0.externalUID == "quoted-parameter-fixture@example.com" },
            context: "quoted parameter raw export event"
        )
        let quotedExportText = LocalCalendarICSCodec.export(
            calendars: quotedRawImport.calendars,
            events: [quotedRawEvent]
        )
        let quotedExportedLines = unfoldedICSLines(from: quotedExportText)
        try expect(
            quotedExportedLines.contains("ORGANIZER;CN=\"Owner: Ops; Lead\":mailto:owner@example.com"),
            "Expected quoted ORGANIZER CN parameter to export without text-property backslash escaping"
        )
        try expect(
            quotedExportedLines.contains { line in
                line.hasPrefix("ATTENDEE;")
                    && line.contains("CN=\"Quoted: Teammate; Lead\"")
                    && line.hasSuffix(":mailto:quoted@example.com")
            },
            "Expected quoted ATTENDEE CN parameter to export without text-property backslash escaping"
        )

        let caretRawImport = try LocalCalendarICSCodec.import(caretParameterICS)
        let caretRawEvent = try requireOnly(
            caretRawImport.events.filter { $0.externalUID == "caret-parameter-fixture@example.com" },
            context: "caret parameter raw export event"
        )
        let caretExportText = LocalCalendarICSCodec.export(
            calendars: caretRawImport.calendars,
            events: [caretRawEvent]
        )
        let caretExportedLines = unfoldedICSLines(from: caretExportText)
        try expect(
            caretExportedLines.contains("ORGANIZER;CN=\"Owner ^'Ops^'^^Lead\":mailto:owner@example.com"),
            "Expected ORGANIZER CN parameter quotes and carets to export with RFC6868 escaping"
        )
        try expect(
            caretExportedLines.contains { line in
                line.hasPrefix("ATTENDEE;")
                    && line.contains("CN=\"Alice ^'Calendar^'^^Core\"")
                    && line.hasSuffix(":mailto:alice@example.com")
            },
            "Expected ATTENDEE CN parameter quotes and carets to export with RFC6868 escaping"
        )

        let emailParameterImport = try LocalCalendarICSCodec.import(emailParameterICS)
        let emailParameterEvent = try requireOnly(
            emailParameterImport.events.filter { $0.externalUID == "email-parameter-fixture@example.com" },
            context: "email parameter event"
        )
        try expect(emailParameterEvent.organizerEmail == "owner+ops@example.com",
                   "Expected ORGANIZER EMAIL parameter to provide the organizer address when value is a non-email URI")
        guard let emailParameterParticipant = emailParameterEvent.attendees.first(where: { $0.email == "param+attendee@example.com" }) else {
            throw ProtocolInvariantError("Expected ATTENDEE EMAIL parameter to provide the attendee address")
        }
        try expect(emailParameterParticipant.status == .tentative,
                   "Expected ATTENDEE EMAIL parameter fallback to preserve attendee metadata")
        let exportedEmailParameterText = LocalCalendarICSCodec.export(
            calendars: emailParameterImport.calendars,
            events: emailParameterImport.events
        )
        let exportedEmailParameterLines = unfoldedICSLines(from: exportedEmailParameterText)
        try expect(exportedEmailParameterLines.contains("ORGANIZER;CN=\"Owner\":mailto:owner+ops@example.com"),
                   "Expected ORGANIZER EMAIL parameter import to export as a canonical mailto address")
        try expect(exportedEmailParameterLines.contains { line in
            line.hasPrefix("ATTENDEE;")
                && line.contains("CN=\"Param Attendee\"")
                && line.hasSuffix(":mailto:param+attendee@example.com")
        },
                   "Expected ATTENDEE EMAIL parameter import to export as a canonical mailto address")

        let mailtoQueryImport = try LocalCalendarICSCodec.import(mailtoQueryICS)
        let mailtoQueryEvent = try requireOnly(
            mailtoQueryImport.events.filter { $0.externalUID == "mailto-query-fixture@example.com" },
            context: "mailto query event"
        )
        try expect(mailtoQueryEvent.organizerEmail == "owner+query@example.com",
                   "Expected ORGANIZER mailto query parameters to be ignored when importing the email address")
        guard let mailtoQueryParticipant = mailtoQueryEvent.attendees.first(where: { $0.email == "query+attendee@example.com" }) else {
            throw ProtocolInvariantError("Expected ATTENDEE mailto query parameters to be ignored when importing the email address")
        }
        try expect(mailtoQueryParticipant.status == .accepted,
                   "Expected ATTENDEE mailto query import to preserve participant metadata")
        let exportedMailtoQueryLines = unfoldedICSLines(from: LocalCalendarICSCodec.export(
            calendars: mailtoQueryImport.calendars,
            events: mailtoQueryImport.events
        ))
        try expect(exportedMailtoQueryLines.contains("ORGANIZER;CN=\"Owner Query\":mailto:owner+query@example.com"),
                   "Expected ORGANIZER mailto query import to export without mailto headers")
        try expect(exportedMailtoQueryLines.contains { line in
            line.hasPrefix("ATTENDEE;")
                && line.contains("CN=\"Query Attendee\"")
                && line.hasSuffix(":mailto:query+attendee@example.com")
        },
                   "Expected ATTENDEE mailto query import to export without mailto headers")

        let smtpAddressImport = try LocalCalendarICSCodec.import(smtpAddressICS)
        let smtpAddressEvent = try requireOnly(
            smtpAddressImport.events.filter { $0.externalUID == "smtp-address-fixture@example.com" },
            context: "SMTP address event"
        )
        try expect(smtpAddressEvent.organizerEmail == "owner+smtp@example.com",
                   "Expected ORGANIZER SMTP URI to import as a canonical email address")
        guard let smtpAddressParticipant = smtpAddressEvent.attendees.first(where: { $0.email == "smtp+attendee@example.com" }) else {
            throw ProtocolInvariantError("Expected ATTENDEE SMTP URI to import as a canonical email address")
        }
        try expect(smtpAddressParticipant.status == .tentative,
                   "Expected ATTENDEE SMTP URI import to preserve participant metadata")
        let exportedSMTPAddressLines = unfoldedICSLines(from: LocalCalendarICSCodec.export(
            calendars: smtpAddressImport.calendars,
            events: smtpAddressImport.events
        ))
        try expect(exportedSMTPAddressLines.contains("ORGANIZER;CN=\"Owner SMTP\":mailto:owner+smtp@example.com"),
                   "Expected ORGANIZER SMTP URI import to export as a canonical mailto address")
        try expect(exportedSMTPAddressLines.contains { line in
            line.hasPrefix("ATTENDEE;")
                && line.contains("CN=\"SMTP Attendee\"")
                && line.hasSuffix(":mailto:smtp+attendee@example.com")
        },
                   "Expected ATTENDEE SMTP URI import to export as a canonical mailto address")
        try expect(!exportedSMTPAddressLines.contains { $0.localizedCaseInsensitiveContains("smtp:") },
                   "Expected SMTP URI import to avoid persisting raw SMTP cal-address values")

        let escapedBackslashImport = try LocalCalendarICSCodec.import(escapedBackslashICS)
        let escapedBackslashEvent = try requireOnly(
            escapedBackslashImport.events.filter { $0.externalUID == "escaped-backslash-fixture@example.com" },
            context: "escaped backslash text event"
        )
        try expect(escapedBackslashEvent.title == "Path C:\\Rooms\\Main",
                   "Expected SUMMARY to unescape literal backslashes")
        try expect(escapedBackslashEvent.location == "CY-Office-1st-Conference\\Main, left; wing",
                   "Expected LOCATION to unescape literal backslashes and punctuation")
        try expect(escapedBackslashEvent.notes == "Open C:\\Docs\\agenda\nBring comma, semicolon; and slash \\",
                   "Expected DESCRIPTION to unescape literal backslashes, newline, comma, and semicolon")
        try expect(escapedBackslashEvent.categories == ["ops\\core", "launch,phase"],
                   "Expected CATEGORIES to preserve escaped backslashes while splitting only on unescaped commas")
        let exportedEscapedBackslashText = LocalCalendarICSCodec.export(
            calendars: escapedBackslashImport.calendars,
            events: escapedBackslashImport.events
        )
        let exportedEscapedBackslashLines = unfoldedICSLines(from: exportedEscapedBackslashText)
        try expect(exportedEscapedBackslashLines.contains("SUMMARY:Path C:\\\\Rooms\\\\Main"),
                   "Expected SUMMARY export to escape literal backslashes")
        try expect(exportedEscapedBackslashLines.contains("LOCATION:CY-Office-1st-Conference\\\\Main\\, left\\; wing"),
                   "Expected LOCATION export to escape backslash, comma, and semicolon")
        try expect(exportedEscapedBackslashLines.contains("DESCRIPTION:Open C:\\\\Docs\\\\agenda\\nBring comma\\, semicolon\\; and slash \\\\"),
                   "Expected DESCRIPTION export to escape literal backslashes and punctuation")

        let percentMailtoSummary = try store.importICSText(percentMailtoICS)
        try expect(percentMailtoSummary.eventsImported == 1, "Expected percent-encoded mailto fixture to import one event")
        let percentMailtoEvent = try requireFirstEvent(
            in: store,
            from: "2026-07-08T00:00:00Z",
            to: "2026-07-09T00:00:00Z",
            externalIdentifier: "percent-mailto-fixture@example.com"
        )
        try expect(percentMailtoEvent.organizer?.email == "owner+ops@example.com",
                   "Expected ORGANIZER mailto percent encoding to decode")
        let percentMailtoParticipant = percentMailtoEvent.participants.first {
            $0.email.caseInsensitiveCompare("alice+calendar@example.com") == .orderedSame
        }
        try expect(percentMailtoParticipant?.status == .accepted,
                   "Expected ATTENDEE mailto percent encoding to decode before participant matching")

        let exportedFoldedText = store.exportICSText()
        let exportedPhysicalLines = exportedFoldedText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            .filter { !$0.isEmpty }
        try expect(exportedPhysicalLines.contains { $0.hasPrefix(" ") },
                   "Expected ICS export to fold at least one long physical line")
        try expect(exportedPhysicalLines.allSatisfy { $0.utf8.count <= 75 },
                   "Expected ICS export physical lines to stay within the 75-octet folding limit")
        let exportedFoldedTextLines = unfoldedICSLines(from: exportedFoldedText)
        try expect(
            exportedFoldedTextLines.contains("SUMMARY:Folded summary with escaped comma\\, semicolon\\; and a continued tail"),
            "Expected folded text export to escape SUMMARY punctuation"
        )
        try expect(
            exportedFoldedTextLines.contains("DESCRIPTION:First line\\nSecond line with comma\\, semicolon\\; and folded tail"),
            "Expected folded text export to escape DESCRIPTION punctuation and newline"
        )
        try expect(
            exportedFoldedTextLines.contains("LOCATION:CY-Office-1st-Conference\\, left wing"),
            "Expected folded text export to escape LOCATION punctuation"
        )
        try expect(
            exportedFoldedTextLines.contains("CATEGORIES:alpha\\,beta,launch\\;phase"),
            "Expected folded text export to preserve escaped CATEGORIES"
        )
        try expect(
            exportedFoldedTextLines.contains { line in
                line.hasPrefix("ATTENDEE;")
                    && line.contains("PARTSTAT=TENTATIVE")
                    && line.contains("ROLE=OPT-PARTICIPANT")
                    && line.contains("CN=\"Folded Teammate; Lead\"")
                    && line.hasSuffix(":mailto:folded@example.com")
            },
            "Expected folded text export to preserve attendee metadata"
        )

        let metadataCalendar = LocalCalendar(
            id: "local-calendar-provider-metadata-roundtrip",
            title: "Provider Metadata",
            colorHex: "#2563EB"
        )
        let longRemoteURL = "https://caldav.example.com/calendars/me/work/" + String(repeating: "remote-object-segment-", count: 8) + "event.ics?query=alpha,beta;gamma"
        let longRemoteETag = "\"provider-etag-" + String(repeating: "etag-fragment-", count: 8) + "tail\""
        let metadataEvent = LocalCalendarEvent(
            id: "provider-metadata-roundtrip",
            externalUID: "provider-metadata-roundtrip@example.com",
            remoteObjectURLString: longRemoteURL,
            remoteETag: longRemoteETag,
            sequence: 7,
            calendarID: metadataCalendar.id,
            title: "Provider metadata roundtrip",
            startDate: date("2026-07-06T09:00:00Z"),
            endDate: date("2026-07-06T09:30:00Z"),
            isAllDay: false,
            location: "CY-Office-1st-Conference",
            notes: "Provider metadata should survive folded ICS export.",
            urlString: "",
            createdAt: date("2026-06-25T09:00:00Z"),
            updatedAt: date("2026-06-25T09:10:00Z")
        )
        let metadataText = LocalCalendarICSCodec.export(
            calendars: [metadataCalendar],
            events: [metadataEvent]
        )
        let metadataPhysicalLines = metadataText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            .filter { !$0.isEmpty }
        try expect(metadataPhysicalLines.contains { $0.hasPrefix(" ") },
                   "Expected long provider metadata lines to be folded on export")
        try expect(metadataPhysicalLines.allSatisfy { $0.utf8.count <= 75 },
                   "Expected folded provider metadata lines to stay within the 75-octet limit")
        let metadataLines = unfoldedICSLines(from: metadataText)
        try expect(metadataLines.contains("X-WORKING-REMOTE-OBJECT-URL:\(longRemoteURL.replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: ";", with: "\\;"))"),
                   "Expected provider remote object URL to be exported as Working metadata")
        try expect(metadataLines.contains("X-WORKING-REMOTE-ETAG:\(longRemoteETag)"),
                   "Expected provider remote ETag to be exported as Working metadata")
        let metadataImport = try LocalCalendarICSCodec.import(metadataText)
        let roundTrippedMetadataEvent = try requireOnly(
            metadataImport.events,
            context: "provider metadata roundtrip import"
        )
        try expect(roundTrippedMetadataEvent.remoteObjectURLString == longRemoteURL,
                   "Expected folded provider remote object URL to round-trip")
        try expect(roundTrippedMetadataEvent.remoteETag == longRemoteETag,
                   "Expected folded provider remote ETag to round-trip")

        let dailyIntervalCountSummary = try store.importICSText(dailyIntervalCountICS)
        try expect(dailyIntervalCountSummary.eventsImported == 1, "Expected daily interval COUNT fixture to import one event")
        let dailyIntervalCountOccurrences = events(in: store, from: "2026-07-01T00:00:00Z", to: "2026-07-10T00:00:00Z")
            .filter { $0.externalIdentifier == "daily-interval-count-fixture@example.com" }
        try expect(dailyIntervalCountOccurrences.count == 4, "Expected daily interval COUNT rule to emit exactly four occurrences")
        try expect(
            Set(dailyIntervalCountOccurrences.map { isoString($0.startDate) }) == [
                "2026-07-01T09:00:00Z",
                "2026-07-03T09:00:00Z",
                "2026-07-05T09:00:00Z",
                "2026-07-07T09:00:00Z"
            ],
            "Expected daily interval COUNT to stop at the fourth every-other-day occurrence"
        )
        let exportedDailyIntervalText = store.exportICSText()
        try expect(exportedDailyIntervalText.contains("RRULE:FREQ=DAILY;INTERVAL=2;UNTIL=20260707T090000Z"),
                   "Expected daily interval COUNT import to export as a finite UNTIL rule")
        try expect(!dailyIntervalCountOccurrences.contains { sameInstant($0.startDate, "2026-07-09T09:00:00Z") },
                   "Daily interval COUNT should not emit a fifth occurrence")

        let dailyByTimeSummary = try store.importICSText(dailyByTimeICS)
        try expect(dailyByTimeSummary.eventsImported == 1, "Expected daily BYHOUR/BYMINUTE/BYSECOND fixture to import one event")
        let dailyByTimeOccurrences = events(in: store, from: "2026-07-01T00:00:00Z", to: "2026-07-05T00:00:00Z")
            .filter { $0.externalIdentifier == "daily-bytime-fixture@example.com" }
        try expect(dailyByTimeOccurrences.count == 3, "Expected redundant daily time filters to emit three occurrences")
        try expect(
            Set(dailyByTimeOccurrences.map { isoString($0.startDate) }) == [
                "2026-07-01T09:30:00Z",
                "2026-07-02T09:30:00Z",
                "2026-07-03T09:30:00Z"
            ],
            "Expected daily BYHOUR/BYMINUTE/BYSECOND to preserve DTSTART time"
        )
        let dailyByTimeEvent = try requireOnly(
            store.events.filter { $0.externalUID == "daily-bytime-fixture@example.com" },
            context: "daily BYHOUR/BYMINUTE/BYSECOND import"
        )
        try expect(dailyByTimeEvent.recurrenceFrequency == .daily,
                   "Redundant daily time filters should stay as a recurring daily event")
        try expect(!dailyByTimeEvent.isImportedRecurrenceSplitProjection,
                   "Redundant daily time filters should not be marked as an imported recurrence projection")

        let dailyByDayByTimeSummary = try store.importICSText(dailyByDayByTimeICS)
        try expect(dailyByDayByTimeSummary.eventsImported == 1,
                   "Expected daily BYDAY with redundant time filters fixture to import one event")
        let dailyByDayByTimeOccurrences = events(in: store, from: "2026-07-06T00:00:00Z", to: "2026-07-20T00:00:00Z")
            .filter { $0.externalIdentifier == "daily-byday-bytime-fixture@example.com" }
        try expect(dailyByDayByTimeOccurrences.count == 4,
                   "Expected daily BYDAY with redundant time filters to emit four occurrences")
        try expect(
            Set(dailyByDayByTimeOccurrences.map { isoString($0.startDate) }) == [
                "2026-07-06T09:30:00Z",
                "2026-07-08T09:30:00Z",
                "2026-07-13T09:30:00Z",
                "2026-07-15T09:30:00Z"
            ],
            "Expected daily BYDAY/BYHOUR/BYMINUTE/BYSECOND to canonicalize to weekly weekdays"
        )
        let dailyByDayByTimeEvent = try requireOnly(
            store.events.filter { $0.externalUID == "daily-byday-bytime-fixture@example.com" },
            context: "daily BYDAY with redundant time filters import"
        )
        try expect(dailyByDayByTimeEvent.recurrenceFrequency == .weekly,
                   "Daily BYDAY with redundant time filters should canonicalize to a weekly rule")
        try expect(Set(dailyByDayByTimeEvent.recurrenceWeekdays) == [2, 4],
                   "Daily BYDAY with redundant time filters should preserve Monday and Wednesday")
        try expect(!dailyByDayByTimeEvent.isImportedRecurrenceSplitProjection,
                   "Daily BYDAY with redundant time filters should not be marked as an imported recurrence projection")

        let dailyByMonthDaySummary = try store.importICSText(dailyByMonthDayICS)
        try expect(dailyByMonthDaySummary.eventsImported == 1,
                   "Expected daily BYMONTHDAY fixture to import one event")
        let dailyByMonthDayOccurrences = events(in: store, from: "2026-07-01T00:00:00Z", to: "2026-10-01T00:00:00Z")
            .filter { $0.externalIdentifier == "daily-bymonthday-fixture@example.com" }
        try expect(dailyByMonthDayOccurrences.count == 3,
                   "Expected daily BYMONTHDAY to canonicalize to three monthly occurrences")
        try expect(
            Set(dailyByMonthDayOccurrences.map { localDayString($0.startDate) }) == [
                "2026-07-05",
                "2026-08-05",
                "2026-09-05"
            ],
            "Expected daily BYMONTHDAY to emit the selected day of each month"
        )
        let dailyByMonthDayEvent = try requireOnly(
            store.events.filter { $0.externalUID == "daily-bymonthday-fixture@example.com" },
            context: "daily BYMONTHDAY import"
        )
        try expect(dailyByMonthDayEvent.recurrenceFrequency == .monthly,
                   "Daily BYMONTHDAY should canonicalize to a monthly rule")
        try expect(dailyByMonthDayEvent.recurrenceMonthDay == 5,
                   "Daily BYMONTHDAY should preserve the day-of-month")
        try expect(!dailyByMonthDayEvent.isImportedRecurrenceSplitProjection,
                   "Daily BYMONTHDAY should not be marked as an imported recurrence projection")
        let exportedDailyByMonthDayText = store.exportICSText()
        try expect(exportedDailyByMonthDayText.contains("BYMONTHDAY=5"),
                   "Expected daily BYMONTHDAY import to export canonical BYMONTHDAY")

        let dailyByMonthByMonthDaySummary = try store.importICSText(dailyByMonthByMonthDayICS)
        try expect(dailyByMonthByMonthDaySummary.eventsImported == 1,
                   "Expected daily BYMONTH/BYMONTHDAY fixture to import one event")
        let dailyByMonthByMonthDayOccurrences = events(in: store, from: "2026-01-01T00:00:00Z", to: "2026-11-01T00:00:00Z")
            .filter { $0.externalIdentifier == "daily-bymonth-bymonthday-fixture@example.com" }
        try expect(dailyByMonthByMonthDayOccurrences.count == 4,
                   "Expected daily BYMONTH/BYMONTHDAY to canonicalize to four selected monthly occurrences")
        try expect(
            Set(dailyByMonthByMonthDayOccurrences.map { localDayString($0.startDate) }) == [
                "2026-01-05",
                "2026-04-05",
                "2026-07-05",
                "2026-10-05"
            ],
            "Expected daily BYMONTH/BYMONTHDAY to emit only the selected months"
        )
        let dailyByMonthByMonthDayEvent = try requireOnly(
            store.events.filter { $0.externalUID == "daily-bymonth-bymonthday-fixture@example.com" },
            context: "daily BYMONTH/BYMONTHDAY import"
        )
        try expect(dailyByMonthByMonthDayEvent.recurrenceFrequency == .monthly,
                   "Daily BYMONTH/BYMONTHDAY should canonicalize to a monthly rule")
        try expect(dailyByMonthByMonthDayEvent.recurrenceMonths == [1, 4, 7, 10],
                   "Daily BYMONTH/BYMONTHDAY should preserve selected months")
        try expect(dailyByMonthByMonthDayEvent.recurrenceMonthDay == 5,
                   "Daily BYMONTH/BYMONTHDAY should preserve the selected day-of-month")
        try expect(!dailyByMonthByMonthDayEvent.isImportedRecurrenceSplitProjection,
                   "Daily BYMONTH/BYMONTHDAY should not be marked as an imported recurrence projection")
        let exportedDailyByMonthByMonthDayText = store.exportICSText()
        try expect(exportedDailyByMonthByMonthDayText.contains("BYMONTH=1,4,7,10"),
                   "Expected daily BYMONTH/BYMONTHDAY import to export canonical BYMONTH")
        try expect(exportedDailyByMonthByMonthDayText.contains("BYMONTHDAY=5"),
                   "Expected daily BYMONTH/BYMONTHDAY import to export canonical BYMONTHDAY")

        let dailyIntervalByMonthDaySummary = try store.importICSText(dailyIntervalByMonthDayICS)
        try expect(dailyIntervalByMonthDaySummary.eventsImported == 1,
                   "Expected unsupported daily interval BYMONTHDAY fixture to import as a guarded event")
        let dailyIntervalByMonthDayEvent = try requireOnly(
            store.events.filter { $0.externalUID == "daily-interval-bymonthday-fixture@example.com" },
            context: "daily interval BYMONTHDAY import"
        )
        try expect(dailyIntervalByMonthDayEvent.recurrenceFrequency == .none,
                   "Daily interval BYMONTHDAY should not be represented as a recurrence we cannot model")
        try expect(dailyIntervalByMonthDayEvent.isImportedRecurrenceSplitProjection,
                   "Daily interval BYMONTHDAY should be marked as an imported recurrence projection")

        let weeklyWeekStartSummary = try store.importICSText(weeklyWeekStartICS)
        try expect(weeklyWeekStartSummary.eventsImported == 1, "Expected weekly WKST fixture to import one event")
        let weeklyWeekStartOccurrences = events(in: store, from: "2026-07-01T00:00:00Z", to: "2026-08-10T00:00:00Z")
            .filter { $0.externalIdentifier == "weekly-wkst-fixture@example.com" }
        try expect(weeklyWeekStartOccurrences.count == 4, "Expected weekly WKST rule to emit four occurrences")
        let weeklyWeekStartDays = Set(weeklyWeekStartOccurrences.map { localDayString($0.startDate) })
        try expect(
            weeklyWeekStartDays == [
                "2026-07-06",
                "2026-07-19",
                "2026-07-20",
                "2026-08-02"
            ],
            "Expected weekly WKST=SU interval rule to use Sunday week boundaries, got \(weeklyWeekStartDays.sorted())"
        )
        let exportedWeeklyWeekStartText = store.exportICSText()
        try expect(exportedWeeklyWeekStartText.contains("WKST=SU"), "Expected weekly WKST import to export the week start")
        try expect(!weeklyWeekStartOccurrences.contains { localDayString($0.startDate) == "2026-07-12" },
                   "Weekly WKST=SU interval rule should not use Monday week boundaries")

        let weeklyByMonthDaySummary = try store.importICSText(weeklyByMonthDayICS)
        try expect(weeklyByMonthDaySummary.eventsImported == 1,
                   "Expected unsupported weekly BYMONTHDAY fixture to import as a guarded event")
        let weeklyByMonthDayEvent = try requireOnly(
            store.events.filter { $0.externalUID == "weekly-bymonthday-fixture@example.com" },
            context: "weekly BYMONTHDAY import"
        )
        try expect(weeklyByMonthDayEvent.recurrenceFrequency == .none,
                   "Weekly BYMONTHDAY should not be represented as a weekly recurrence that ignores the month-day filter")
        try expect(weeklyByMonthDayEvent.isImportedRecurrenceSplitProjection,
                   "Weekly BYMONTHDAY should be marked as an imported recurrence projection")
        let weeklyByMonthDayOccurrences = events(in: store, from: "2026-07-01T00:00:00Z", to: "2026-08-01T00:00:00Z")
            .filter { $0.externalIdentifier == "weekly-bymonthday-fixture@example.com" }
        try expect(weeklyByMonthDayOccurrences.count == 1,
                   "Weekly BYMONTHDAY must not emit every week while ignoring BYMONTHDAY")

        let byWeekNumberSummary = try store.importICSText(byWeekNumberICS)
        try expect(byWeekNumberSummary.eventsImported == 1,
                   "Expected unsupported BYWEEKNO fixture to import as a guarded event")
        let byWeekNumberEvent = try requireOnly(
            store.events.filter { $0.externalUID == "byweekno-fixture@example.com" },
            context: "BYWEEKNO import"
        )
        try expect(byWeekNumberEvent.recurrenceFrequency == .none,
                   "BYWEEKNO should not be represented as a recurrence we cannot model")
        try expect(byWeekNumberEvent.isImportedRecurrenceSplitProjection,
                   "BYWEEKNO should be marked as an imported recurrence projection")
        let byWeekNumberOccurrences = events(in: store, from: "2026-07-01T00:00:00Z", to: "2029-01-01T00:00:00Z")
            .filter { $0.externalIdentifier == "byweekno-fixture@example.com" }
        try expect(byWeekNumberOccurrences.count == 1,
                   "BYWEEKNO must not emit yearly or weekly occurrences while ignoring the week-number filter")

        let unknownRuleComponentSummary = try store.importICSText(unknownRuleComponentICS)
        try expect(unknownRuleComponentSummary.eventsImported == 1,
                   "Expected unknown RRULE component fixture to import as a guarded event")
        let unknownRuleComponentEvent = try requireOnly(
            store.events.filter { $0.externalUID == "unknown-rule-component-fixture@example.com" },
            context: "unknown RRULE component import"
        )
        try expect(unknownRuleComponentEvent.recurrenceFrequency == .none,
                   "Unknown RRULE components should not be represented as a recurrence we cannot model")
        try expect(unknownRuleComponentEvent.isImportedRecurrenceSplitProjection,
                   "Unknown RRULE components should be marked as an imported recurrence projection")
        let unknownRuleComponentOccurrences = events(in: store, from: "2026-07-01T00:00:00Z", to: "2026-08-01T00:00:00Z")
            .filter { $0.externalIdentifier == "unknown-rule-component-fixture@example.com" }
        try expect(unknownRuleComponentOccurrences.count == 1,
                   "Unknown RRULE components must not emit weekly occurrences while ignoring the unknown filter")

        let unsupportedRuleWithRecurrenceDatesSummary = try store.importICSText(unsupportedRuleWithRecurrenceDatesICS)
        try expect(unsupportedRuleWithRecurrenceDatesSummary.eventsImported == 1,
                   "Expected unsupported RRULE with RDATE/EXDATE fixture to import as a guarded event")
        let unsupportedRuleWithRecurrenceDatesEvent = try requireOnly(
            store.events.filter { $0.externalUID == "unsupported-rule-recurrence-dates-fixture@example.com" },
            context: "unsupported RRULE with RDATE/EXDATE import"
        )
        try expect(unsupportedRuleWithRecurrenceDatesEvent.recurrenceFrequency == .none,
                   "Unsupported RRULE with RDATE/EXDATE should not keep an unsupported recurrence frequency")
        try expect(unsupportedRuleWithRecurrenceDatesEvent.additionalOccurrenceStartDates.count == 2,
                   "Unsupported RRULE with RDATE/EXDATE should preserve explicit additional dates")
        try expect(unsupportedRuleWithRecurrenceDatesEvent.excludedOccurrenceStartDates.count == 1,
                   "Unsupported RRULE with RDATE/EXDATE should preserve EXDATE entries that exclude explicit RDATEs")
        let unsupportedRuleWithRecurrenceDatesOccurrences = events(in: store, from: "2026-07-01T00:00:00Z", to: "2026-08-01T00:00:00Z")
            .filter { $0.externalIdentifier == "unsupported-rule-recurrence-dates-fixture@example.com" }
        try expect(
            Set(unsupportedRuleWithRecurrenceDatesOccurrences.map { localDayString($0.startDate) }) == ["2026-07-06", "2026-07-13"],
            "Unsupported RRULE should keep base/RDATE occurrences and omit EXDATE-matched RDATEs"
        )

        let exruleSummary = try store.importICSText(exruleICS)
        try expect(exruleSummary.eventsImported == 1,
                   "Expected EXRULE fixture to import as a guarded event")
        let exruleEvent = try requireOnly(
            store.events.filter { $0.externalUID == "exrule-fixture@example.com" },
            context: "EXRULE import"
        )
        try expect(exruleEvent.recurrenceFrequency == .none,
                   "EXRULE should not be represented as a recurrence while ignoring exclusion rules")
        try expect(exruleEvent.isImportedRecurrenceSplitProjection,
                   "EXRULE should be marked as an imported recurrence projection")
        let exruleOccurrences = events(in: store, from: "2026-07-01T00:00:00Z", to: "2026-08-01T00:00:00Z")
            .filter { $0.externalIdentifier == "exrule-fixture@example.com" }
        try expect(exruleOccurrences.count == 1,
                   "EXRULE must not emit RRULE occurrences while ignoring recurrence exclusions")

        let weeklyBySetPositionSummary = try store.importICSText(weeklyBySetPositionICS)
        try expect(weeklyBySetPositionSummary.eventsImported == 1, "Expected weekly BYSETPOS fixture to import one event")
        let weeklyBySetPositionOccurrences = events(in: store, from: "2026-07-01T00:00:00Z", to: "2026-08-01T00:00:00Z")
            .filter { $0.externalIdentifier == "weekly-bysetpos-fixture@example.com" }
        try expect(weeklyBySetPositionOccurrences.count == 4,
                   "Expected weekly BYSETPOS rule to emit four selected occurrences")
        try expect(weeklyBySetPositionOccurrences.contains { sameInstant($0.startDate, "2026-07-06T09:00:00Z") },
                   "Expected weekly BYSETPOS rule to include the first Monday")
        try expect(weeklyBySetPositionOccurrences.contains { sameInstant($0.startDate, "2026-07-13T09:00:00Z") },
                   "Expected weekly BYSETPOS rule to include the second Monday")
        try expect(weeklyBySetPositionOccurrences.contains { sameInstant($0.startDate, "2026-07-20T09:00:00Z") },
                   "Expected weekly BYSETPOS rule to include the third Monday")
        try expect(weeklyBySetPositionOccurrences.contains { sameInstant($0.startDate, "2026-07-27T09:00:00Z") },
                   "Expected weekly BYSETPOS rule to include the fourth Monday")
        try expect(!weeklyBySetPositionOccurrences.contains { sameInstant($0.startDate, "2026-07-08T09:00:00Z") },
                   "Weekly BYSETPOS must not ignore BYSETPOS and emit Wednesday")
        let weeklyBySetPositionEvent = try requireOnly(
            store.events.filter { $0.externalUID == "weekly-bysetpos-fixture@example.com" },
            context: "weekly BYSETPOS import"
        )
        try expect(weeklyBySetPositionEvent.recurrenceFrequency == .weekly,
                   "Weekly BYSETPOS should stay as a recurring weekly event")
        try expect(weeklyBySetPositionEvent.recurrenceSetPositions == [1],
                   "Weekly BYSETPOS should preserve the set-position filter")
        try expect(!weeklyBySetPositionEvent.isImportedRecurrenceSplitProjection,
                   "Supported weekly BYSETPOS should not be marked as an imported recurrence projection")
        let exportedWeeklyBySetPositionText = store.exportICSText()
        try expect(exportedWeeklyBySetPositionText.contains("BYSETPOS=1"),
                   "Expected weekly BYSETPOS import to export the set-position filter")

        let monthlyBySetPositionSummary = try store.importICSText(monthlyBySetPositionICS)
        try expect(monthlyBySetPositionSummary.eventsImported == 1, "Expected monthly BYSETPOS fixture to import one event")
        let monthlyBySetPositionOccurrences = events(in: store, from: "2026-07-01T00:00:00Z", to: "2026-10-05T00:00:00Z")
            .filter { $0.externalIdentifier == "monthly-bysetpos-fixture@example.com" }
        try expect(monthlyBySetPositionOccurrences.count == 3, "Expected monthly BYSETPOS rule to emit three occurrences")
        try expect(monthlyBySetPositionOccurrences.contains { sameInstant($0.startDate, "2026-07-27T15:00:00Z") },
                   "Expected monthly BYSETPOS rule to include the last Monday of July")
        try expect(monthlyBySetPositionOccurrences.contains { sameInstant($0.startDate, "2026-08-31T15:00:00Z") },
                   "Expected monthly BYSETPOS rule to include the last Monday of August")
        try expect(monthlyBySetPositionOccurrences.contains { sameInstant($0.startDate, "2026-09-28T15:00:00Z") },
                   "Expected monthly BYSETPOS rule to include the last Monday of September")
        let exportedMonthlyBySetPositionText = store.exportICSText()
        try expect(exportedMonthlyBySetPositionText.contains("BYDAY=-1MO"), "Expected monthly BYSETPOS import to export as a canonical last-Monday rule")

        let monthlyNegativeMonthDaySummary = try store.importICSText(monthlyNegativeMonthDayICS)
        try expect(monthlyNegativeMonthDaySummary.eventsImported == 1, "Expected monthly negative BYMONTHDAY fixture to import one event")
        let monthlyNegativeMonthDayOccurrences = events(in: store, from: "2026-07-01T00:00:00Z", to: "2026-11-05T00:00:00Z")
            .filter { $0.externalIdentifier == "monthly-negative-bymonthday-fixture@example.com" }
        try expect(monthlyNegativeMonthDayOccurrences.count == 4, "Expected monthly BYMONTHDAY=-1 rule to emit four occurrences")
        let monthlyNegativeMonthDayStarts = Set(monthlyNegativeMonthDayOccurrences.map { localDayString($0.startDate) })
        try expect(
            monthlyNegativeMonthDayStarts == [
                "2026-07-31",
                "2026-08-31",
                "2026-09-30",
                "2026-10-31"
            ],
            "Expected monthly BYMONTHDAY=-1 to follow the last day of each month, got \(monthlyNegativeMonthDayStarts.sorted())"
        )
        let exportedMonthlyNegativeMonthDayText = store.exportICSText()
        try expect(exportedMonthlyNegativeMonthDayText.contains("BYMONTHDAY=-1"),
                   "Expected monthly negative BYMONTHDAY import to export the negative day-of-month rule")
        try expect(!monthlyNegativeMonthDayOccurrences.contains { sameInstant($0.startDate, "2026-11-30T15:00:00Z") },
                   "Monthly BYMONTHDAY=-1 COUNT should stop before a fifth occurrence")

        let monthlyByMonthSummary = try store.importICSText(monthlyByMonthICS)
        try expect(monthlyByMonthSummary.eventsImported == 1, "Expected monthly BYMONTH fixture to import one event")
        let monthlyByMonthOccurrences = events(in: store, from: "2026-01-01T00:00:00Z", to: "2026-11-01T00:00:00Z")
            .filter { $0.externalIdentifier == "monthly-bymonth-fixture@example.com" }
        try expect(monthlyByMonthOccurrences.count == 4, "Expected monthly BYMONTH rule to emit four allowed-month occurrences")
        let monthlyByMonthStarts = Set(monthlyByMonthOccurrences.map { localDayString($0.startDate) })
        try expect(
            monthlyByMonthStarts == [
                "2026-01-05",
                "2026-04-05",
                "2026-07-05",
                "2026-10-05"
            ],
            "Expected monthly BYMONTH to emit quarterly allowed months, got \(monthlyByMonthStarts.sorted())"
        )
        let monthlyByMonthEvent = try requireOnly(
            store.events.filter { $0.externalUID == "monthly-bymonth-fixture@example.com" },
            context: "monthly BYMONTH import"
        )
        try expect(monthlyByMonthEvent.recurrenceFrequency == .monthly,
                   "Monthly BYMONTH should stay as a recurring monthly event")
        try expect(monthlyByMonthEvent.recurrenceMonths == [1, 4, 7, 10],
                   "Monthly BYMONTH should preserve allowed months")
        let exportedMonthlyByMonthText = store.exportICSText()
        try expect(exportedMonthlyByMonthText.contains("BYMONTH=1,4,7,10"),
                   "Expected monthly BYMONTH import to preserve allowed months")
        try expect(exportedMonthlyByMonthText.contains("BYMONTHDAY=5"),
                   "Expected monthly BYMONTH import to preserve day-of-month")
        try expect(!monthlyByMonthOccurrences.contains { localDayString($0.startDate) == "2026-02-05" },
                   "Monthly BYMONTH must not emit months outside the allowed list")

        let yearlyBySetPositionSummary = try store.importICSText(yearlyBySetPositionICS)
        try expect(yearlyBySetPositionSummary.eventsImported == 1, "Expected yearly BYSETPOS fixture to import one event")
        let yearlyBySetPositionOccurrences = events(in: store, from: "2026-11-01T00:00:00Z", to: "2029-01-01T00:00:00Z")
            .filter { $0.externalIdentifier == "yearly-bysetpos-fixture@example.com" }
        try expect(yearlyBySetPositionOccurrences.count == 3, "Expected yearly BYSETPOS rule to emit three occurrences")
        try expect(yearlyBySetPositionOccurrences.contains { sameInstant($0.startDate, "2026-11-26T16:00:00Z") },
                   "Expected yearly BYSETPOS rule to include the fourth Thursday of November 2026")
        try expect(yearlyBySetPositionOccurrences.contains { sameInstant($0.startDate, "2027-11-25T16:00:00Z") },
                   "Expected yearly BYSETPOS rule to include the fourth Thursday of November 2027")
        try expect(yearlyBySetPositionOccurrences.contains { sameInstant($0.startDate, "2028-11-23T16:00:00Z") },
                   "Expected yearly BYSETPOS rule to include the fourth Thursday of November 2028")
        let exportedYearlyBySetPositionText = store.exportICSText()
        try expect(exportedYearlyBySetPositionText.contains("BYMONTH=11"), "Expected yearly BYSETPOS import to preserve the target month")
        try expect(exportedYearlyBySetPositionText.contains("BYDAY=4TH"), "Expected yearly BYSETPOS import to export as a canonical fourth-Thursday rule")

        let yearlyOrdinalByMonthSummary = try store.importICSText(yearlyOrdinalByMonthICS)
        try expect(yearlyOrdinalByMonthSummary.eventsImported == 1, "Expected yearly ordinal BYMONTH fixture to import one event")
        let yearlyOrdinalByMonthOccurrences = events(in: store, from: "2026-01-01T00:00:00Z", to: "2027-05-01T00:00:00Z")
            .filter { $0.externalIdentifier == "yearly-ordinal-bymonth-fixture@example.com" }
        try expect(yearlyOrdinalByMonthOccurrences.count == 4, "Expected yearly ordinal BYMONTH rule to emit four occurrences")
        let yearlyOrdinalByMonthStarts = Set(yearlyOrdinalByMonthOccurrences.map { localDayString($0.startDate) })
        try expect(
            yearlyOrdinalByMonthStarts == [
                "2026-01-22",
                "2026-04-23",
                "2027-01-28",
                "2027-04-22"
            ],
            "Expected yearly ordinal BYMONTH to emit the fourth Thursday of each allowed month, got \(yearlyOrdinalByMonthStarts.sorted())"
        )
        let yearlyOrdinalByMonthEvent = try requireOnly(
            store.events.filter { $0.externalUID == "yearly-ordinal-bymonth-fixture@example.com" },
            context: "yearly ordinal BYMONTH import"
        )
        try expect(yearlyOrdinalByMonthEvent.recurrenceFrequency == .yearly,
                   "Yearly ordinal BYMONTH should stay as a recurring yearly event")
        try expect(yearlyOrdinalByMonthEvent.recurrenceMonths == [1, 4],
                   "Yearly ordinal BYMONTH should preserve allowed months")
        try expect(!yearlyOrdinalByMonthEvent.isImportedRecurrenceSplitProjection,
                   "Supported yearly ordinal BYMONTH should not be marked as an imported recurrence projection")
        let exportedYearlyOrdinalByMonthText = store.exportICSText()
        try expect(exportedYearlyOrdinalByMonthText.contains("BYMONTH=1,4"),
                   "Expected yearly ordinal BYMONTH import to preserve allowed months")
        try expect(exportedYearlyOrdinalByMonthText.contains("BYDAY=4TH"),
                   "Expected yearly ordinal BYMONTH import to preserve ordinal weekday")

        let yearlyMultiMonthBySetPositionSummary = try store.importICSText(yearlyMultiMonthBySetPositionICS)
        try expect(yearlyMultiMonthBySetPositionSummary.eventsImported == 1,
                   "Expected unsupported yearly multi-month BYSETPOS fixture to import as a guarded event")
        let yearlyMultiMonthBySetPositionEvent = try requireOnly(
            store.events.filter { $0.externalUID == "yearly-multi-month-bysetpos-fixture@example.com" },
            context: "yearly multi-month BYSETPOS import"
        )
        try expect(yearlyMultiMonthBySetPositionEvent.recurrenceFrequency == .none,
                   "Yearly multi-month BYSETPOS should not be represented as a recurring rule we cannot model")
        try expect(yearlyMultiMonthBySetPositionEvent.isImportedRecurrenceSplitProjection,
                   "Unsupported yearly multi-month BYSETPOS should be marked as an imported recurrence projection")

        let yearlyByMonthSummary = try store.importICSText(yearlyByMonthICS)
        try expect(yearlyByMonthSummary.eventsImported == 1, "Expected yearly BYMONTH fixture to import one event")
        let yearlyByMonthOccurrences = events(in: store, from: "2026-01-01T00:00:00Z", to: "2026-11-01T00:00:00Z")
            .filter { $0.externalIdentifier == "yearly-bymonth-fixture@example.com" }
        try expect(yearlyByMonthOccurrences.count == 4, "Expected yearly BYMONTH rule to emit four occurrences in the allowed months")
        let yearlyByMonthStarts = Set(yearlyByMonthOccurrences.map { localDayString($0.startDate) })
        try expect(
            yearlyByMonthStarts == [
                "2026-01-05",
                "2026-04-05",
                "2026-07-05",
                "2026-10-05"
            ],
            "Expected yearly BYMONTH to emit quarterly allowed months, got \(yearlyByMonthStarts.sorted())"
        )
        let yearlyByMonthEvent = try requireOnly(
            store.events.filter { $0.externalUID == "yearly-bymonth-fixture@example.com" },
            context: "yearly BYMONTH import"
        )
        try expect(yearlyByMonthEvent.recurrenceFrequency == .yearly,
                   "Yearly BYMONTH should stay as a recurring yearly event")
        try expect(yearlyByMonthEvent.recurrenceMonths == [1, 4, 7, 10],
                   "Yearly BYMONTH should preserve the allowed months")
        try expect(!yearlyByMonthEvent.isImportedRecurrenceSplitProjection,
                   "Supported yearly BYMONTH should not be marked as an imported recurrence projection")
        let exportedYearlyByMonthText = store.exportICSText()
        try expect(exportedYearlyByMonthText.contains("BYMONTH=1,4,7,10"),
                   "Expected yearly BYMONTH import to preserve allowed months")
        try expect(exportedYearlyByMonthText.contains("BYMONTHDAY=5"),
                   "Expected yearly BYMONTH import to preserve day-of-month")
        try expect(!yearlyByMonthOccurrences.contains { localDayString($0.startDate) == "2026-02-05" },
                   "Yearly BYMONTH must not emit months outside the allowed list")

        let yearlyByYearDaySummary = try store.importICSText(yearlyByYearDayICS)
        try expect(yearlyByYearDaySummary.eventsImported == 1, "Expected yearly BYYEARDAY fixture to import one event")
        let yearlyByYearDayOccurrences = events(in: store, from: "2026-01-01T00:00:00Z", to: "2029-01-01T00:00:00Z")
            .filter { $0.externalIdentifier == "yearly-byyearday-fixture@example.com" }
        try expect(yearlyByYearDayOccurrences.count == 3, "Expected fixed yearly BYYEARDAY rule to emit three occurrences")
        let yearlyByYearDayStarts = Set(yearlyByYearDayOccurrences.map { localDayString($0.startDate) })
        try expect(
            yearlyByYearDayStarts == [
                "2026-01-15",
                "2027-01-15",
                "2028-01-15"
            ],
            "Expected fixed BYYEARDAY=15 to canonicalize to January 15, got \(yearlyByYearDayStarts.sorted())"
        )
        let yearlyByYearDayEvent = try requireOnly(
            store.events.filter { $0.externalUID == "yearly-byyearday-fixture@example.com" },
            context: "yearly BYYEARDAY import"
        )
        try expect(yearlyByYearDayEvent.recurrenceFrequency == .yearly,
                   "Fixed BYYEARDAY should stay as a recurring yearly event")
        try expect(yearlyByYearDayEvent.recurrenceMonths == [1],
                   "Fixed BYYEARDAY should canonicalize to the matching month")
        try expect(yearlyByYearDayEvent.recurrenceMonthDay == 15,
                   "Fixed BYYEARDAY should canonicalize to the matching day-of-month")
        try expect(!yearlyByYearDayEvent.isImportedRecurrenceSplitProjection,
                   "Fixed BYYEARDAY should not be marked as an imported recurrence projection")
        let exportedYearlyByYearDayText = store.exportICSText()
        try expect(exportedYearlyByYearDayText.contains("BYMONTH=1"),
                   "Expected fixed BYYEARDAY import to export canonical BYMONTH")
        try expect(exportedYearlyByYearDayText.contains("BYMONTHDAY=15"),
                   "Expected fixed BYYEARDAY import to export canonical BYMONTHDAY")

        let leapYearDaySummary = try store.importICSText(leapYearDayICS)
        try expect(leapYearDaySummary.eventsImported == 1,
                   "Expected leap-dependent BYYEARDAY fixture to import as a guarded event")
        let leapYearDayEvent = try requireOnly(
            store.events.filter { $0.externalUID == "leap-byyearday-fixture@example.com" },
            context: "leap-dependent BYYEARDAY import"
        )
        try expect(leapYearDayEvent.recurrenceFrequency == .none,
                   "Leap-dependent BYYEARDAY should not be represented as a fixed yearly rule")
        try expect(leapYearDayEvent.isImportedRecurrenceSplitProjection,
                   "Leap-dependent BYYEARDAY should be marked as an imported recurrence projection")

        let yearlyNegativeMonthDaySummary = try store.importICSText(yearlyNegativeMonthDayICS)
        try expect(yearlyNegativeMonthDaySummary.eventsImported == 1, "Expected yearly negative BYMONTHDAY fixture to import one event")
        let yearlyNegativeMonthDayOccurrences = events(in: store, from: "2028-02-01T00:00:00Z", to: "2031-03-01T00:00:00Z")
            .filter { $0.externalIdentifier == "yearly-negative-bymonthday-fixture@example.com" }
        try expect(yearlyNegativeMonthDayOccurrences.count == 3, "Expected yearly BYMONTHDAY=-1 rule to emit three occurrences")
        let yearlyNegativeMonthDayStarts = Set(yearlyNegativeMonthDayOccurrences.map { localDayString($0.startDate) })
        try expect(
            yearlyNegativeMonthDayStarts == [
                "2028-02-29",
                "2029-02-28",
                "2030-02-28"
            ],
            "Expected yearly BYMONTHDAY=-1 to follow the last day of February, got \(yearlyNegativeMonthDayStarts.sorted())"
        )
        let exportedYearlyNegativeMonthDayText = store.exportICSText()
        try expect(exportedYearlyNegativeMonthDayText.contains("BYMONTH=2"),
                   "Expected yearly negative BYMONTHDAY import to preserve the target month")
        try expect(exportedYearlyNegativeMonthDayText.contains("BYMONTHDAY=-1"),
                   "Expected yearly negative BYMONTHDAY import to export the negative day-of-month rule")

        let yearlyFutureRangeNegativeMonthDaySummary = try store.importICSText(yearlyFutureRangeNegativeMonthDayICS)
        try expect(yearlyFutureRangeNegativeMonthDaySummary.eventsImported == 2,
                   "Expected yearly RANGE=THISANDFUTURE fixture to split into base and future events")
        let yearlyFutureRangeNegativeMonthDayOccurrences = events(in: store, from: "2028-02-01T00:00:00Z", to: "2032-03-01T00:00:00Z")
            .filter { $0.externalIdentifier.hasPrefix("yearly-range-negative-bymonthday-fixture@example.com") }
        try expect(yearlyFutureRangeNegativeMonthDayOccurrences.count == 4,
                   "Expected yearly RANGE=THISANDFUTURE BYMONTHDAY=-1 rule to emit four occurrences")
        let yearlyFutureRangeNegativeMonthDayStarts = Set(yearlyFutureRangeNegativeMonthDayOccurrences.map { localDayString($0.startDate) })
        try expect(
            yearlyFutureRangeNegativeMonthDayStarts == [
                "2028-02-29",
                "2029-02-28",
                "2030-02-28",
                "2031-02-28"
            ],
            "Expected yearly RANGE=THISANDFUTURE split to preserve last-day-of-February semantics, got \(yearlyFutureRangeNegativeMonthDayStarts.sorted())"
        )
        try expect(yearlyFutureRangeNegativeMonthDayOccurrences.filter { $0.title == "Yearly range moved" }.count == 3,
                   "Expected future RANGE=THISANDFUTURE occurrences to use the updated future event details")
        let exportedYearlyFutureRangeNegativeMonthDayText = store.exportICSText()
        try expect(exportedYearlyFutureRangeNegativeMonthDayText.contains("SUMMARY:Yearly range moved"),
                   "Expected yearly RANGE=THISANDFUTURE import to export a split future series")
        try expect(exportedYearlyFutureRangeNegativeMonthDayText.contains("BYMONTHDAY=-1"),
                   "Expected yearly RANGE=THISANDFUTURE split to keep exporting negative BYMONTHDAY")

        let yearlyFutureRangeOrdinalSummary = try store.importICSText(yearlyFutureRangeOrdinalICS)
        try expect(yearlyFutureRangeOrdinalSummary.eventsImported == 2,
                   "Expected yearly ordinal RANGE=THISANDFUTURE fixture to split into base and future events")
        let yearlyFutureRangeOrdinalOccurrences = events(in: store, from: "2026-11-01T00:00:00Z", to: "2030-01-01T00:00:00Z")
            .filter { $0.externalIdentifier.hasPrefix("yearly-range-ordinal-fixture@example.com") }
        try expect(yearlyFutureRangeOrdinalOccurrences.count == 4,
                   "Expected yearly ordinal RANGE=THISANDFUTURE rule to emit four occurrences")
        let yearlyFutureRangeOrdinalStarts = Set(yearlyFutureRangeOrdinalOccurrences.map { localDayString($0.startDate) })
        try expect(
            yearlyFutureRangeOrdinalStarts == [
                "2026-11-26",
                "2027-11-25",
                "2028-11-23",
                "2029-11-22"
            ],
            "Expected yearly RANGE=THISANDFUTURE split to preserve fourth-Thursday semantics, got \(yearlyFutureRangeOrdinalStarts.sorted())"
        )
        try expect(yearlyFutureRangeOrdinalOccurrences.filter { $0.title == "Yearly ordinal range moved" }.count == 3,
                   "Expected future ordinal RANGE=THISANDFUTURE occurrences to use the updated future event details")
        let exportedYearlyFutureRangeOrdinalText = store.exportICSText()
        try expect(exportedYearlyFutureRangeOrdinalText.contains("SUMMARY:Yearly ordinal range moved"),
                   "Expected yearly ordinal RANGE=THISANDFUTURE import to export a split future series")
        try expect(exportedYearlyFutureRangeOrdinalText.contains("BYDAY=4TH"),
                   "Expected yearly ordinal RANGE=THISANDFUTURE split to keep exporting ordinal BYDAY")

        let allDayTimezoneFutureRangeSummary = try store.importICSText(allDayTimezoneFutureRangeICS)
        try expect(allDayTimezoneFutureRangeSummary.eventsImported == 2,
                   "Expected all-day timezone RANGE=THISANDFUTURE fixture to split into base and future events")
        let allDayTimezoneFutureRangeOccurrences = events(in: store, from: "2026-04-01T00:00:00Z", to: "2026-08-01T00:00:00Z")
            .filter { $0.externalIdentifier.hasPrefix("all-day-timezone-range-fixture@example.com") }
        try expect(allDayTimezoneFutureRangeOccurrences.count == 4,
                   "Expected all-day timezone RANGE=THISANDFUTURE rule to emit four occurrences")
        let allDayTimezoneFutureRangeStarts = Set(allDayTimezoneFutureRangeOccurrences.map {
            localDayString($0.startDate, timeZoneIdentifier: "Pacific/Auckland")
        })
        try expect(
            allDayTimezoneFutureRangeStarts == [
                "2026-04-05",
                "2026-05-05",
                "2026-06-05",
                "2026-07-05"
            ],
            "Expected all-day RANGE=THISANDFUTURE split to preserve the provider timezone day, got \(allDayTimezoneFutureRangeStarts.sorted())"
        )
        try expect(allDayTimezoneFutureRangeOccurrences.filter { $0.title == "All-day timezone range moved" }.count == 3,
                   "Expected all future all-day timezone occurrences to use the updated future event details")
        let exportedAllDayTimezoneFutureRangeText = store.exportICSText()
        try expect(exportedAllDayTimezoneFutureRangeText.contains("SUMMARY:All-day timezone range moved"),
                   "Expected all-day timezone RANGE=THISANDFUTURE import to export a split future series")

        print("ICS protocol invariant passed.")
    }

    @MainActor
    private static func verifySameUIDAcrossCalendarsStaysScoped() throws {
        let store = LocalCalendarStore()
        let firstSummary = try store.importICSText(sameUIDFirstCalendarICS)
        let secondSummary = try store.importICSText(sameUIDSecondCalendarICS)
        try expect(firstSummary.eventsImported == 1,
                   "Same UID first calendar fixture should import one event")
        try expect(secondSummary.eventsImported == 1,
                   "Same UID in a different calendar should import as a second scoped event")
        try expect(store.events.count == 2,
                   "Store should retain both same-UID calendar-scoped events")

        let updateSummary = try store.importICSText(sameUIDSecondCalendarUpdateICS)
        try expect(updateSummary.eventsImported == 0,
                   "Same UID update in an existing calendar should not import a third event")
        try expect(updateSummary.eventsUpdated == 1,
                   "Same UID update should update only the matching calendar event")
        try expect(store.events.count == 2,
                   "Same UID update should keep both calendar-scoped events")

        guard let firstCalendarEvent = store.events.first(where: { $0.calendarID == "local-calendar-google-sameuid-a-primary" }),
              let secondCalendarEvent = store.events.first(where: { $0.calendarID == "local-calendar-google-sameuid-b-primary" })
        else {
            throw ProtocolInvariantError("Expected both scoped same-UID calendar events to remain")
        }
        try expect(firstCalendarEvent.title == "Same UID account A",
                   "Updating account B should not overwrite account A's same-UID event")
        try expect(secondCalendarEvent.title == "Same UID account B updated",
                   "Updating account B should update the event in account B's calendar")
    }

    private static func resetLocalCalendarStorage() {
        UserDefaults.standard.removeObject(forKey: "localCalendars")
        UserDefaults.standard.removeObject(forKey: "localCalendarEvents")
        UserDefaults.standard.removeObject(forKey: "selectedLocalCalendarIDs")
    }

    private static let uid = "protocol-fixture@example.com"
    private static let attendeeEmail = "teammate@example.com"

    private static let sameUIDFirstCalendarICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Same UID Scoped Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:same-uid-scoped@example.com
    DTSTAMP:20260625T090000Z
    DTSTART:20260701T090000Z
    DTEND:20260701T093000Z
    SUMMARY:Same UID account A
    X-WORKING-CALENDAR-ID:local-calendar-google-sameuid-a-primary
    X-WORKING-CALENDAR-TITLE:Same UID A
    END:VEVENT
    END:VCALENDAR
    """

    private static let sameUIDSecondCalendarICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Same UID Scoped Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:same-uid-scoped@example.com
    DTSTAMP:20260625T090000Z
    DTSTART:20260701T100000Z
    DTEND:20260701T103000Z
    SUMMARY:Same UID account B
    X-WORKING-CALENDAR-ID:local-calendar-google-sameuid-b-primary
    X-WORKING-CALENDAR-TITLE:Same UID B
    END:VEVENT
    END:VCALENDAR
    """

    private static let sameUIDSecondCalendarUpdateICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Same UID Scoped Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:same-uid-scoped@example.com
    SEQUENCE:1
    DTSTAMP:20260625T091000Z
    DTSTART:20260701T100000Z
    DTEND:20260701T104500Z
    SUMMARY:Same UID account B updated
    X-WORKING-CALENDAR-ID:local-calendar-google-sameuid-b-primary
    X-WORKING-CALENDAR-TITLE:Same UID B
    END:VEVENT
    END:VCALENDAR
    """

    private static let requestICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    X-WR-CALNAME:Protocol Fixture
    BEGIN:VEVENT
    UID:\(uid)
    DTSTAMP:20260625T080000Z
    DTSTART:20260625T090000Z
    DTEND:20260625T093000Z
    RRULE:FREQ=WEEKLY;COUNT=3
    SUMMARY:Protocol fixture
    ATTENDEE;CN=Teammate;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:\(attendeeEmail)
    END:VEVENT
    END:VCALENDAR
    """

    private static let requestUpdateICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    X-WR-CALNAME:Protocol Fixture Follow-up
    BEGIN:VEVENT
    UID:\(uid)
    SEQUENCE:1
    DTSTAMP:20260625T083000Z
    DTSTART:20260625T090000Z
    DTEND:20260625T093000Z
    RRULE:FREQ=WEEKLY;COUNT=3
    SUMMARY:Protocol fixture updated
    ATTENDEE;CN=Teammate;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:\(attendeeEmail)
    END:VEVENT
    END:VCALENDAR
    """

    private static let staleRequestICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    X-WR-CALNAME:Protocol Fixture Stale
    BEGIN:VEVENT
    UID:\(uid)
    SEQUENCE:0
    DTSTAMP:20260625T075000Z
    DTSTART:20260625T090000Z
    DTEND:20260625T093000Z
    RRULE:FREQ=WEEKLY;COUNT=3
    SUMMARY:Protocol fixture stale
    ATTENDEE;CN=Teammate;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:\(attendeeEmail)
    END:VEVENT
    END:VCALENDAR
    """

    private static let occurrenceUpdateICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    UID:\(uid)
    SEQUENCE:2
    DTSTAMP:20260625T084000Z
    RECURRENCE-ID:20260702T090000Z
    DTSTART:20260702T100000Z
    DTEND:20260702T103000Z
    SUMMARY:Protocol occurrence moved
    ATTENDEE;CN=Teammate;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:\(attendeeEmail)
    END:VEVENT
    END:VCALENDAR
    """

    private static let addOccurrenceICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:ADD
    BEGIN:VEVENT
    UID:\(uid)
    SEQUENCE:2
    DTSTAMP:20260625T084500Z
    DTSTART:20260722T110000Z
    DTEND:20260722T113000Z
    SUMMARY:Protocol added office hours
    LOCATION:War Room
    ATTENDEE;CN=Teammate;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:\(attendeeEmail)
    END:VEVENT
    END:VCALENDAR
    """

    private static let replyICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REPLY
    BEGIN:VEVENT
    UID:\(uid)
    DTSTAMP:20260625T081500Z
    ATTENDEE;CN=Teammate;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:\(attendeeEmail)
    END:VEVENT
    END:VCALENDAR
    """

    private static let replyWithDatesICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REPLY
    BEGIN:VEVENT
    UID:\(uid)
    DTSTAMP:20260625T081000Z
    DTSTART:20260625T090000Z
    DTEND:20260625T093000Z
    ATTENDEE;CN=Teammate;ROLE=REQ-PARTICIPANT;PARTSTAT=TENTATIVE:mailto:\(attendeeEmail)
    END:VEVENT
    END:VCALENDAR
    """

    private static let refreshICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REFRESH
    BEGIN:VEVENT
    UID:\(uid)
    DTSTAMP:20260625T081200Z
    DTSTART:20260625T090000Z
    DTEND:20260625T093000Z
    ATTENDEE;CN=Teammate;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION:mailto:\(attendeeEmail)
    END:VEVENT
    END:VCALENDAR
    """

    private static let occurrenceReplyICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REPLY
    BEGIN:VEVENT
    UID:\(uid)
    DTSTAMP:20260625T082000Z
    RECURRENCE-ID:20260709T090000Z
    ATTENDEE;CN=Teammate;ROLE=REQ-PARTICIPANT;PARTSTAT=DECLINED:mailto:\(attendeeEmail)
    END:VEVENT
    END:VCALENDAR
    """

    private static let occurrenceCancelICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:CANCEL
    BEGIN:VEVENT
    UID:\(uid)
    DTSTAMP:20260625T080000Z
    RECURRENCE-ID:20260702T090000Z
    STATUS:CANCELLED
    SUMMARY:Protocol fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let futureCancelICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:CANCEL
    BEGIN:VEVENT
    UID:\(uid)
    DTSTAMP:20260625T084500Z
    RECURRENCE-ID;RANGE=THISANDFUTURE:20260709T090000Z
    STATUS:CANCELLED
    SUMMARY:Protocol fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let seriesCancelICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:CANCEL
    BEGIN:VEVENT
    UID:\(uid)
    DTSTAMP:20260625T080000Z
    STATUS:CANCELLED
    SUMMARY:Protocol fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let alarmICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:alarm-fixture@example.com
    DTSTAMP:20260625T090000Z
    DTSTART:20260720T090000Z
    DTEND:20260720T093000Z
    SUMMARY:Alarm fixture
    BEGIN:VALARM
    ACTION:DISPLAY
    DESCRIPTION:Alarm fixture
    TRIGGER:-PT10M
    DURATION:PT5M
    REPEAT:2
    END:VALARM
    END:VEVENT
    END:VCALENDAR
    """

    private static let absoluteAlarmICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:absolute-alarm-fixture@example.com
    DTSTAMP:20260625T090000Z
    DTSTART:20260726T100000Z
    DTEND:20260726T103000Z
    SUMMARY:Absolute alarm fixture
    BEGIN:VALARM
    ACTION:DISPLAY
    DESCRIPTION:Absolute alarm fixture
    TRIGGER;VALUE=DATE-TIME:20260726T094000Z
    END:VALARM
    BEGIN:VALARM
    ACTION:DISPLAY
    DESCRIPTION:Timezone absolute alarm fixture
    TRIGGER;VALUE=DATE-TIME;TZID=Asia/Nicosia:20260726T123000
    END:VALARM
    END:VEVENT
    END:VCALENDAR
    """

    private static let deepLinkMeetingICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    UID:deep-link-meeting-fixture@example.com
    DTSTAMP:20260625T102500Z
    DTSTART:20260722T100000Z
    DTEND:20260722T103000Z
    SUMMARY:Deep link meeting fixture
    URL:https://calendar.example.com/events/deep-link-fixture
    CONFERENCE;VALUE=URI:zoommtg://zoom.us/join?action=join&confno=123456789
    END:VEVENT
    END:VCALENDAR
    """

    private static let popularMeetingProviderICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    UID:popular-meeting-provider-fixture@example.com
    DTSTAMP:20260625T102700Z
    DTSTART:20260723T100000Z
    DTEND:20260723T103000Z
    SUMMARY:Popular meeting provider fixture
    URL:https://calendar.example.com/events/popular-provider-fixture
    DESCRIPTION:Join with GoTo Meeting\\nhttps://meet.goto.com/123456789
    END:VEVENT
    END:VCALENDAR
    """

    private static let pathAwareMeetingProviderICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    UID:path-aware-meeting-provider-fixture@example.com
    DTSTAMP:20260625T102900Z
    DTSTART:20260724T100000Z
    DTEND:20260724T103000Z
    SUMMARY:Path-aware meeting provider fixture
    URL:https://calendar.example.com/events/path-aware-provider-fixture
    DESCRIPTION:Join with Slack Huddle\\nhttps://slack.com/huddle/T123/C456
    END:VEVENT
    END:VCALENDAR
    """

    private static let durationICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:duration-fixture@example.com
    DTSTAMP:20260625T091500Z
    DTSTART:20260721T090000Z
    DURATION:PT1H15M
    SUMMARY:Duration fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let allDayICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:all-day-fixture@example.com
    DTSTAMP:20260625T093000Z
    DTSTART;VALUE=DATE:20260722
    SUMMARY:All-day fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let allDayMissingEndDSTICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    X-WR-TIMEZONE:Pacific/Auckland
    BEGIN:VEVENT
    UID:all-day-missing-end-dst-fixture@example.com
    DTSTAMP:20260625T094000Z
    DTSTART;VALUE=DATE:20260405
    SUMMARY:All-day missing DTEND on DST boundary
    END:VEVENT
    END:VCALENDAR
    """

    private static let allDayDurationDSTICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    X-WR-TIMEZONE:Pacific/Auckland
    BEGIN:VEVENT
    UID:all-day-duration-dst-fixture@example.com
    DTSTAMP:20260625T094200Z
    DTSTART;VALUE=DATE:20260405
    DURATION:P1D
    SUMMARY:All-day duration on DST boundary
    END:VEVENT
    END:VCALENDAR
    """

    private static let allDayTimezoneICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    X-WR-TIMEZONE:Pacific/Auckland
    BEGIN:VEVENT
    UID:all-day-timezone-fixture@example.com
    DTSTAMP:20260625T094500Z
    DTSTART;VALUE=DATE:20260701
    DTEND;VALUE=DATE:20260702
    RRULE:FREQ=WEEKLY;UNTIL=20260715
    RDATE;VALUE=DATE:20260705
    EXDATE;VALUE=DATE:20260708
    SUMMARY:All-day timezone fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let allDayTimezoneCountICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    X-WR-TIMEZONE:Pacific/Auckland
    BEGIN:VEVENT
    UID:all-day-timezone-count-fixture@example.com
    DTSTAMP:20260625T095000Z
    DTSTART;VALUE=DATE:20260405
    DTEND;VALUE=DATE:20260406
    RRULE:FREQ=WEEKLY;COUNT=3;BYDAY=SU;WKST=MO
    SUMMARY:All-day timezone COUNT fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let allDayRecurrenceICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:all-day-recurrence-fixture@example.com
    DTSTAMP:20260625T100000Z
    DTSTART;VALUE=DATE:20260706
    DTEND;VALUE=DATE:20260707
    RRULE:FREQ=WEEKLY;COUNT=3
    RDATE;VALUE=DATE:20260709
    EXDATE;VALUE=DATE:20260713
    SUMMARY:All-day recurrence fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let multiValueRecurrenceDatesICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:multi-value-recurrence-dates-fixture@example.com
    DTSTAMP:20260625T100500Z
    DTSTART:20260706T090000Z
    DTEND:20260706T093000Z
    RRULE:FREQ=WEEKLY;COUNT=4
    RDATE:20260708T090000Z,20260710T090000Z
    EXDATE:20260713T090000Z,20260720T090000Z
    SUMMARY:Multi-value recurrence dates fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let rdatePeriodICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:rdate-period-fixture@example.com
    DTSTAMP:20260625T102200Z
    DTSTART:20260726T090000Z
    DTEND:20260726T093000Z
    RDATE;VALUE=PERIOD:20260727T090000Z/PT45M,20260728T100000Z/20260728T110000Z
    SUMMARY:RDATE period fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let allDayUntilRecurrenceICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:all-day-until-recurrence-fixture@example.com
    DTSTAMP:20260625T100000Z
    DTSTART;VALUE=DATE:20260706
    DTEND;VALUE=DATE:20260707
    RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=MO;UNTIL=20260720
    SUMMARY:All-day date-only UNTIL recurrence fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let monthlyBySetPositionICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:monthly-bysetpos-fixture@example.com
    DTSTAMP:20260625T101500Z
    DTSTART:20260727T150000Z
    DTEND:20260727T153000Z
    RRULE:FREQ=MONTHLY;COUNT=3;BYDAY=MO;BYSETPOS=-1
    SUMMARY:Monthly BYSETPOS fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let monthlyNegativeMonthDayICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:monthly-negative-bymonthday-fixture@example.com
    DTSTAMP:20260625T102000Z
    DTSTART:20260731T150000Z
    DTEND:20260731T153000Z
    RRULE:FREQ=MONTHLY;COUNT=4;BYMONTHDAY=-1
    SUMMARY:Monthly negative BYMONTHDAY fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let monthlyByMonthICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:monthly-bymonth-fixture@example.com
    DTSTAMP:20260625T101500Z
    DTSTART:20260105T150000Z
    DTEND:20260105T153000Z
    RRULE:FREQ=MONTHLY;COUNT=4;BYMONTH=1,4,7,10;BYMONTHDAY=5
    SUMMARY:Monthly BYMONTH fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let outlookBusyStatusICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:outlook-free-busystatus-fixture@example.com
    DTSTAMP:20260625T101500Z
    DTSTART:20260723T090000Z
    DTEND:20260723T093000Z
    SUMMARY:Outlook free busy status fixture
    X-MICROSOFT-CDO-BUSYSTATUS:FREE
    END:VEVENT
    BEGIN:VEVENT
    UID:outlook-tentative-busystatus-fixture@example.com
    DTSTAMP:20260625T101500Z
    DTSTART:20260723T100000Z
    DTEND:20260723T103000Z
    SUMMARY:Outlook tentative busy status fixture
    X-MICROSOFT-CDO-BUSYSTATUS:TENTATIVE
    END:VEVENT
    END:VCALENDAR
    """

    private static let outlookImportanceICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:outlook-high-importance-fixture@example.com
    DTSTAMP:20260625T101500Z
    DTSTART:20260723T110000Z
    DTEND:20260723T113000Z
    SUMMARY:Outlook high importance fixture
    X-MICROSOFT-CDO-IMPORTANCE:2
    END:VEVENT
    BEGIN:VEVENT
    UID:outlook-low-importance-fixture@example.com
    DTSTAMP:20260625T101500Z
    DTSTART:20260723T120000Z
    DTEND:20260723T123000Z
    SUMMARY:Outlook low importance fixture
    X-MICROSOFT-CDO-IMPORTANCE:0
    END:VEVENT
    BEGIN:VEVENT
    UID:outlook-priority-override-fixture@example.com
    DTSTAMP:20260625T101500Z
    DTSTART:20260723T130000Z
    DTEND:20260723T133000Z
    SUMMARY:Outlook priority override fixture
    PRIORITY:9
    X-MICROSOFT-CDO-IMPORTANCE:2
    END:VEVENT
    END:VCALENDAR
    """

    private static let outlookDisallowCounterICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:outlook-disallow-counter-fixture@example.com
    DTSTAMP:20260625T101500Z
    DTSTART:20260723T140000Z
    DTEND:20260723T143000Z
    SUMMARY:Outlook disallow counter fixture
    X-MICROSOFT-DISALLOW-COUNTER:TRUE
    END:VEVENT
    END:VCALENDAR
    """

    private static let iTIPCounterProposalICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:COUNTER
    BEGIN:VEVENT
    UID:itip-counter-proposal-fixture@example.com
    DTSTAMP:20260625T101500Z
    DTSTART:20260723T150000Z
    DTEND:20260723T153000Z
    SUMMARY:Proposed support sync time
    STATUS:CONFIRMED
    ORGANIZER;CN="Lead":mailto:lead@example.com
    ATTENDEE;CN="Current User";PARTSTAT=TENTATIVE;ROLE=REQ-PARTICIPANT:mailto:me@example.com
    END:VEVENT
    END:VCALENDAR
    """

    private static let iTIPDeclineCounterICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:DECLINECOUNTER
    BEGIN:VEVENT
    UID:itip-decline-counter-fixture@example.com
    DTSTAMP:20260625T101500Z
    DTSTART:20260723T160000Z
    DTEND:20260723T163000Z
    SUMMARY:Declined proposed support sync time
    STATUS:TENTATIVE
    ORGANIZER;CN="Lead":mailto:lead@example.com
    ATTENDEE;CN="Current User";PARTSTAT=DECLINED;ROLE=REQ-PARTICIPANT:mailto:me@example.com
    END:VEVENT
    END:VCALENDAR
    """

    private static let vFreeBusyICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    X-WR-CALNAME:Team availability
    X-WR-CALCOLOR:#64748B
    BEGIN:VFREEBUSY
    UID:freebusy-fixture@example.com
    DTSTAMP:20260625T080000Z
    ORGANIZER;CN="Scheduler":mailto:scheduler@example.com
    FREEBUSY;FBTYPE=BUSY:20260728T090000Z/20260728T093000Z
    FREEBUSY;FBTYPE=BUSY-TENTATIVE:20260728T100000Z/PT30M
    FREEBUSY;FBTYPE=FREE:20260728T110000Z/20260728T113000Z
    END:VFREEBUSY
    END:VCALENDAR
    """

    private static let mixedUnsupportedComponentICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    X-WR-CALNAME:Mixed component calendar
    BEGIN:VTODO
    UID:mixed-component-todo@example.com
    DTSTAMP:20260625T080000Z
    DUE:20260728T090000Z
    SUMMARY:This task must not become a meeting
    END:VTODO
    BEGIN:VJOURNAL
    UID:mixed-component-journal@example.com
    DTSTAMP:20260625T080500Z
    DTSTART;VALUE=DATE:20260728
    SUMMARY:This journal entry must not become a meeting
    END:VJOURNAL
    BEGIN:VEVENT
    UID:mixed-component-event@example.com
    DTSTAMP:20260625T081000Z
    DTSTART:20260728T120000Z
    DTEND:20260728T123000Z
    SUMMARY:Supported event in mixed component fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let unsupportedOnlyComponentICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VTODO
    UID:unsupported-only-todo@example.com
    DTSTAMP:20260625T080000Z
    DUE:20260728T090000Z
    SUMMARY:Standalone task should stay unsupported
    END:VTODO
    BEGIN:VJOURNAL
    UID:unsupported-only-journal@example.com
    DTSTAMP:20260625T080500Z
    DTSTART;VALUE=DATE:20260728
    SUMMARY:Standalone journal should stay unsupported
    END:VJOURNAL
    END:VCALENDAR
    """

    private static let outlookTimedAllDayICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    X-WR-TIMEZONE:Asia/Nicosia
    BEGIN:VEVENT
    UID:outlook-timed-all-day-fixture@example.com
    DTSTAMP:20260625T101500Z
    DTSTART;TZID=Asia/Nicosia:20260724T000000
    DTEND;TZID=Asia/Nicosia:20260725T000000
    SUMMARY:Outlook timed all-day fixture
    X-MICROSOFT-CDO-ALLDAYEVENT:TRUE
    END:VEVENT
    END:VCALENDAR
    """

    private static let vendorLowercaseTimezoneICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:vendor-lowercase-timezone-fixture@example.com
    DTSTAMP:20260625T101700Z
    DTSTART;TZID=/freeassociation.sourceforge.net/america/new_york:20260706T090000
    DTEND;TZID=/freeassociation.sourceforge.net/america/new_york:20260706T093000
    SUMMARY:Vendor lowercase timezone fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let windowsTimezoneICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:windows-timezone-fixture@example.com
    DTSTAMP:20260625T101750Z
    DTSTART;TZID=GTB Standard Time:20260706T090000
    DTEND;TZID=GTB Standard Time:20260706T093000
    SUMMARY:Windows timezone fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let floatingCalendarTimezoneICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    X-WR-TIMEZONE:Asia/Nicosia
    BEGIN:VEVENT
    UID:floating-calendar-timezone-fixture@example.com
    DTSTAMP:20260625T101900Z
    DTSTART:20260706T090000
    DTEND:20260706T093000
    RDATE:20260708T090000
    EXDATE:20260713T090000
    RRULE:FREQ=WEEKLY;COUNT=3
    SUMMARY:Floating calendar timezone fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let xLicLocationTimezoneICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VTIMEZONE
    TZID:Custom-Eastern-Fixture
    X-LIC-LOCATION:America/New_York
    BEGIN:STANDARD
    DTSTART:20260101T000000
    TZOFFSETFROM:-0500
    TZOFFSETTO:-0500
    END:STANDARD
    BEGIN:DAYLIGHT
    DTSTART:20260308T020000
    TZOFFSETFROM:-0500
    TZOFFSETTO:-0400
    END:DAYLIGHT
    END:VTIMEZONE
    BEGIN:VEVENT
    UID:x-lic-location-timezone-fixture@example.com
    DTSTAMP:20260625T101800Z
    DTSTART;TZID=Custom-Eastern-Fixture:20260706T090000
    DTEND;TZID=Custom-Eastern-Fixture:20260706T093000
    SUMMARY:X-LIC-LOCATION timezone fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let foldedTextICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    X-WR-CALNAME:Folded Fixture
    BEGIN:VEVENT
    UID:folded-text-fixture@example.com
    DTSTAMP:20260625T101500Z
    DTSTART:20260706T090000Z
    DTEND:20260706T093000Z
    RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE;WKST=MO;UNTIL=2026072
     0T090000Z
    SUMMARY:Folded summary with escaped comma\\, semicolon\\; and a 
     continued tail
    DESCRIPTION:First line\\nSecond line with comma\\, semicolon\\; and 
     folded tail
    LOCATION:CY-Office-1st-Conference\\, 
     left wing
    CATEGORIES:alpha\\,beta,launch\\;phase
    ATTENDEE;CN="Folded Teammate\\; Lead";ROLE=OPT-PARTICI
     PANT;PARTSTAT=TENTATIVE;RSVP=TRUE;X-WORKING-CURRENT-USER=TRUE:mailto:folded@example.com
    END:VEVENT
    END:VCALENDAR
    """

    private static let structuredLocationICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:structured-location-fixture@example.com
    DTSTAMP:20260625T101600Z
    DTSTART:20260709T090000Z
    DTEND:20260709T093000Z
    SUMMARY:Structured location fixture
    DESCRIPTION:Discuss location parsing
    X-APPLE-STRUCTURED-LOCATION;VALUE=URI;X-TITLE=CY-Office-1st-Conference:geo:35.1856,33.3823
    END:VEVENT
    END:VCALENDAR
    """

    private static let geoICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:geo-fixture@example.com
    DTSTAMP:20260625T101715Z
    DTSTART:20260709T093000Z
    DTEND:20260709T100000Z
    SUMMARY:Geo fixture
    LOCATION:CY-Office-1st-Conference
    GEO:35.1856;33.3823
    END:VEVENT
    END:VCALENDAR
    """

    private static let resourcesICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:resources-fixture@example.com
    DTSTAMP:20260625T101650Z
    DTSTART:20260709T100000Z
    DTEND:20260709T103000Z
    SUMMARY:Resources fixture
    ATTENDEE;CN=CY-Office-1st-Conference;CUTYPE=ROOM;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:cy-office-1st-conference@example.com
    RESOURCES:CY-Office-1st-Conference,Projector\\, HDMI
    END:VEVENT
    END:VCALENDAR
    """

    private static let commentContactICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:comment-contact-fixture@example.com
    DTSTAMP:20260625T101720Z
    DTSTART:20260710T090000Z
    DTEND:20260710T093000Z
    SUMMARY:Comment contact fixture
    DESCRIPTION:Agenda stays in the description.
    COMMENT:Backup bridge https://zoom.us/j/111222333?pwd=comment
    CONTACT:Ops Desk\\, Calendar
    END:VEVENT
    END:VCALENDAR
    """

    private static let relatedToICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:related-to-fixture@example.com
    DTSTAMP:20260625T101725Z
    DTSTART:20260710T100000Z
    DTEND:20260710T103000Z
    SUMMARY:Related-to fixture
    RELATED-TO:parent-event@example.com
    RELATED-TO;RELTYPE=sibling:sibling-event@example.com
    RELATED-TO;RELTYPE=SIBLING:sibling-event@example.com
    END:VEVENT
    END:VCALENDAR
    """

    private static let attachmentICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:attachment-fixture@example.com
    DTSTAMP:20260625T101730Z
    DTSTART:20260710T110000Z
    DTEND:20260710T113000Z
    SUMMARY:Attachment fixture
    ATTACH;VALUE=URI;FMTTYPE=application/pdf;X-FILENAME="Agenda\\, Q3.pdf":https://files.example.com/agenda\\,q3.pdf?download=1
    ATTACH;FMTTYPE=text/html;CN="Planning notes":https://docs.example.com/notes
    ATTACH;VALUE=URI;FMTTYPE=text/html;X-FILENAME="Zoom bridge":https://zoom.us/j/222333444?pwd=attach
    ATTACH;VALUE=BINARY;ENCODING=BASE64;FMTTYPE=application/octet-stream:AAAA
    END:VEVENT
    END:VCALENDAR
    """

    private static let caretParameterICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:caret-parameter-fixture@example.com
    DTSTAMP:20260625T101500Z
    DTSTART:20260707T090000Z
    DTEND:20260707T093000Z
    SUMMARY:Caret parameter fixture
    ORGANIZER;CN=Owner ^'Ops^'^^Lead:mailto:owner@example.com
    ATTENDEE;CN="Alice ^'Calendar^'^^Core";ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:alice@example.com
    END:VEVENT
    END:VCALENDAR
    """

    private static let quotedParameterICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:quoted-parameter-fixture@example.com
    DTSTAMP:20260625T101700Z
    DTSTART:20260711T090000Z
    DTEND:20260711T093000Z
    SUMMARY:Quoted parameter fixture
    ORGANIZER;CN="Owner: Ops; Lead":mailto:owner@example.com
    ATTENDEE;CN="Quoted: Teammate; Lead";ROLE=OPT-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:quoted@example.com
    END:VEVENT
    END:VCALENDAR
    """

    private static let emailParameterICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:email-parameter-fixture@example.com
    DTSTAMP:20260625T101750Z
    DTSTART:20260712T100000Z
    DTEND:20260712T103000Z
    SUMMARY:Email parameter fixture
    ORGANIZER;CN=Owner;EMAIL=owner%2Bops%40example.com:urn:uuid:owner-fixture
    ATTENDEE;CN=Param Attendee;EMAIL=param%2Battendee%40example.com;ROLE=REQ-PARTICIPANT;PARTSTAT=TENTATIVE:urn:uuid:attendee-fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let mailtoQueryICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:mailto-query-fixture@example.com
    DTSTAMP:20260625T101755Z
    DTSTART:20260712T110000Z
    DTEND:20260712T113000Z
    SUMMARY:Mailto query fixture
    ORGANIZER;CN=Owner Query:mailto:owner%2Bquery%40example.com?subject=calendar
    ATTENDEE;CN=Query Attendee;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:query%2Battendee%40example.com?subject=rsvp#fragment
    END:VEVENT
    END:VCALENDAR
    """

    private static let smtpAddressICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:smtp-address-fixture@example.com
    DTSTAMP:20260625T101756Z
    DTSTART:20260712T120000Z
    DTEND:20260712T123000Z
    SUMMARY:SMTP address fixture
    ORGANIZER;CN=Owner SMTP:SMTP:owner%2Bsmtp%40example.com?subject=calendar
    ATTENDEE;CN=SMTP Attendee;ROLE=REQ-PARTICIPANT;PARTSTAT=TENTATIVE:SMTP:smtp%2Battendee%40example.com?subject=rsvp#fragment
    END:VEVENT
    END:VCALENDAR
    """

    private static let escapedBackslashICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:escaped-backslash-fixture@example.com
    DTSTAMP:20260625T101800Z
    DTSTART:20260712T090000Z
    DTEND:20260712T093000Z
    SUMMARY:Path C:\\\\Rooms\\\\Main
    DESCRIPTION:Open C:\\\\Docs\\\\agenda\\nBring comma\\, semicolon\\; and slash \\\\
    LOCATION:CY-Office-1st-Conference\\\\Main\\, left\\; wing
    CATEGORIES:ops\\\\core,launch\\,phase
    END:VEVENT
    END:VCALENDAR
    """

    private static let percentMailtoICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:percent-mailto-fixture@example.com
    DTSTAMP:20260625T112000Z
    DTSTART:20260708T090000Z
    DTEND:20260708T093000Z
    SUMMARY:Percent mailto fixture
    ORGANIZER;CN=Owner:mailto:owner%2Bops%40example.com
    ATTENDEE;CN=Alice;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:alice%2Bcalendar%40example.com
    END:VEVENT
    END:VCALENDAR
    """

    private static let dailyIntervalCountICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:daily-interval-count-fixture@example.com
    DTSTAMP:20260625T100500Z
    DTSTART:20260701T090000Z
    DTEND:20260701T093000Z
    RRULE:FREQ=DAILY;INTERVAL=2;COUNT=4
    SUMMARY:Daily interval COUNT fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let dailyByTimeICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:daily-bytime-fixture@example.com
    DTSTAMP:20260625T100600Z
    DTSTART:20260701T093000Z
    DTEND:20260701T100000Z
    RRULE:FREQ=DAILY;COUNT=3;BYHOUR=9;BYMINUTE=30;BYSECOND=0
    SUMMARY:Daily BYHOUR/BYMINUTE/BYSECOND fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let dailyByDayByTimeICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:daily-byday-bytime-fixture@example.com
    DTSTAMP:20260625T100700Z
    DTSTART:20260706T093000Z
    DTEND:20260706T100000Z
    RRULE:FREQ=DAILY;COUNT=4;BYDAY=MO,WE;BYHOUR=9;BYMINUTE=30;BYSECOND=0
    SUMMARY:Daily BYDAY with time filters fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let dailyByMonthDayICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:daily-bymonthday-fixture@example.com
    DTSTAMP:20260625T100800Z
    DTSTART:20260705T090000Z
    DTEND:20260705T093000Z
    RRULE:FREQ=DAILY;COUNT=3;BYMONTHDAY=5
    SUMMARY:Daily BYMONTHDAY fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let dailyByMonthByMonthDayICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:daily-bymonth-bymonthday-fixture@example.com
    DTSTAMP:20260625T101000Z
    DTSTART:20260105T090000Z
    DTEND:20260105T093000Z
    RRULE:FREQ=DAILY;COUNT=4;BYMONTH=1,4,7,10;BYMONTHDAY=5
    SUMMARY:Daily BYMONTH BYMONTHDAY fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let dailyIntervalByMonthDayICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:daily-interval-bymonthday-fixture@example.com
    DTSTAMP:20260625T100900Z
    DTSTART:20260705T090000Z
    DTEND:20260705T093000Z
    RRULE:FREQ=DAILY;INTERVAL=2;COUNT=3;BYMONTHDAY=5
    SUMMARY:Daily interval BYMONTHDAY fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let weeklyWeekStartICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:weekly-wkst-fixture@example.com
    DTSTAMP:20260625T101000Z
    DTSTART:20260706T090000Z
    DTEND:20260706T093000Z
    RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=SU,MO;WKST=SU
    SUMMARY:Weekly WKST fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let weeklyByMonthDayICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:weekly-bymonthday-fixture@example.com
    DTSTAMP:20260625T101100Z
    DTSTART:20260706T090000Z
    DTEND:20260706T093000Z
    RRULE:FREQ=WEEKLY;COUNT=3;BYDAY=MO;BYMONTHDAY=6
    SUMMARY:Weekly BYMONTHDAY fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let byWeekNumberICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:byweekno-fixture@example.com
    DTSTAMP:20260625T101150Z
    DTSTART:20260706T090000Z
    DTEND:20260706T093000Z
    RRULE:FREQ=YEARLY;COUNT=3;BYWEEKNO=28;BYDAY=MO;WKST=MO
    SUMMARY:BYWEEKNO fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let unknownRuleComponentICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:unknown-rule-component-fixture@example.com
    DTSTAMP:20260625T101152Z
    DTSTART:20260706T090000Z
    DTEND:20260706T093000Z
    RRULE:FREQ=WEEKLY;COUNT=3;BYDAY=MO;BYEASTER=1
    SUMMARY:Unknown RRULE component fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let unsupportedRuleWithRecurrenceDatesICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:unsupported-rule-recurrence-dates-fixture@example.com
    DTSTAMP:20260625T101155Z
    DTSTART:20260706T090000Z
    DTEND:20260706T093000Z
    RRULE:FREQ=YEARLY;COUNT=3;BYWEEKNO=28;BYDAY=MO;WKST=MO
    RDATE:20260713T090000Z,20260720T090000Z
    EXDATE:20260720T090000Z
    SUMMARY:Unsupported RRULE with recurrence dates fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let exruleICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:exrule-fixture@example.com
    DTSTAMP:20260625T101156Z
    DTSTART:20260706T090000Z
    DTEND:20260706T093000Z
    RRULE:FREQ=WEEKLY;COUNT=4
    EXRULE:FREQ=WEEKLY;COUNT=2
    SUMMARY:EXRULE fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let weeklyBySetPositionICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:weekly-bysetpos-fixture@example.com
    DTSTAMP:20260625T101200Z
    DTSTART:20260706T090000Z
    DTEND:20260706T093000Z
    RRULE:FREQ=WEEKLY;COUNT=4;BYDAY=MO,WE;BYSETPOS=1
    SUMMARY:Weekly BYSETPOS fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let yearlyBySetPositionICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:yearly-bysetpos-fixture@example.com
    DTSTAMP:20260625T103000Z
    DTSTART:20261126T160000Z
    DTEND:20261126T163000Z
    RRULE:FREQ=YEARLY;COUNT=3;BYMONTH=11;BYDAY=TH;BYSETPOS=4
    SUMMARY:Yearly BYSETPOS fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let yearlyOrdinalByMonthICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:yearly-ordinal-bymonth-fixture@example.com
    DTSTAMP:20260625T103500Z
    DTSTART:20260122T160000Z
    DTEND:20260122T163000Z
    RRULE:FREQ=YEARLY;COUNT=4;BYMONTH=1,4;BYDAY=4TH
    SUMMARY:Yearly ordinal BYMONTH fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let yearlyMultiMonthBySetPositionICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:yearly-multi-month-bysetpos-fixture@example.com
    DTSTAMP:20260625T103600Z
    DTSTART:20260122T160000Z
    DTEND:20260122T163000Z
    RRULE:FREQ=YEARLY;COUNT=4;BYMONTH=1,4;BYDAY=TH;BYSETPOS=4
    SUMMARY:Yearly multi-month BYSETPOS fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let yearlyByMonthICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:yearly-bymonth-fixture@example.com
    DTSTAMP:20260625T101500Z
    DTSTART:20260105T150000Z
    DTEND:20260105T153000Z
    RRULE:FREQ=YEARLY;COUNT=4;BYMONTH=1,4,7,10;BYMONTHDAY=5
    SUMMARY:Yearly BYMONTH fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let yearlyByYearDayICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:yearly-byyearday-fixture@example.com
    DTSTAMP:20260625T103700Z
    DTSTART:20260115T150000Z
    DTEND:20260115T153000Z
    RRULE:FREQ=YEARLY;COUNT=3;BYYEARDAY=15
    SUMMARY:Yearly BYYEARDAY fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let leapYearDayICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:leap-byyearday-fixture@example.com
    DTSTAMP:20260625T103800Z
    DTSTART:20240229T150000Z
    DTEND:20240229T153000Z
    RRULE:FREQ=YEARLY;COUNT=3;BYYEARDAY=60
    SUMMARY:Leap-dependent BYYEARDAY fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let yearlyNegativeMonthDayICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:yearly-negative-bymonthday-fixture@example.com
    DTSTAMP:20260625T104000Z
    DTSTART:20280229T150000Z
    DTEND:20280229T153000Z
    RRULE:FREQ=YEARLY;COUNT=3;BYMONTH=2;BYMONTHDAY=-1
    SUMMARY:Yearly negative BYMONTHDAY fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let yearlyFutureRangeNegativeMonthDayICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    UID:yearly-range-negative-bymonthday-fixture@example.com
    DTSTAMP:20260625T105000Z
    DTSTART:20280229T150000Z
    DTEND:20280229T153000Z
    RRULE:FREQ=YEARLY;COUNT=4;BYMONTH=2;BYMONTHDAY=-1
    SUMMARY:Yearly range base
    END:VEVENT
    BEGIN:VEVENT
    UID:yearly-range-negative-bymonthday-fixture@example.com
    DTSTAMP:20260625T105500Z
    RECURRENCE-ID;RANGE=THISANDFUTURE:20290228T150000Z
    DTSTART:20290228T160000Z
    DTEND:20290228T163000Z
    SUMMARY:Yearly range moved
    END:VEVENT
    END:VCALENDAR
    """

    private static let yearlyFutureRangeOrdinalICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    UID:yearly-range-ordinal-fixture@example.com
    DTSTAMP:20260625T110000Z
    DTSTART:20261126T160000Z
    DTEND:20261126T163000Z
    RRULE:FREQ=YEARLY;COUNT=4;BYMONTH=11;BYDAY=TH;BYSETPOS=4
    SUMMARY:Yearly ordinal range base
    END:VEVENT
    BEGIN:VEVENT
    UID:yearly-range-ordinal-fixture@example.com
    DTSTAMP:20260625T110500Z
    RECURRENCE-ID;RANGE=THISANDFUTURE:20271125T160000Z
    DTSTART:20271125T170000Z
    DTEND:20271125T173000Z
    SUMMARY:Yearly ordinal range moved
    END:VEVENT
    END:VCALENDAR
    """

    private static let allDayTimezoneFutureRangeICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Protocol Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    X-WR-TIMEZONE:Pacific/Auckland
    BEGIN:VEVENT
    UID:all-day-timezone-range-fixture@example.com
    DTSTAMP:20260625T111000Z
    DTSTART;VALUE=DATE:20260405
    DTEND;VALUE=DATE:20260406
    RRULE:FREQ=MONTHLY;COUNT=4;BYMONTHDAY=5
    SUMMARY:All-day timezone range base
    END:VEVENT
    BEGIN:VEVENT
    UID:all-day-timezone-range-fixture@example.com
    DTSTAMP:20260625T111500Z
    RECURRENCE-ID;RANGE=THISANDFUTURE;VALUE=DATE:20260505
    DTSTART;VALUE=DATE:20260505
    DTEND;VALUE=DATE:20260506
    SUMMARY:All-day timezone range moved
    END:VEVENT
    END:VCALENDAR
    """

    @MainActor
    private static func verifyVFreeBusyImport() throws {
        let store = LocalCalendarStore()
        let summary = try store.importICSText(vFreeBusyICS)
        try expect(summary.calendarsImported == 1, "Expected VFREEBUSY import to create a free/busy calendar")
        try expect(summary.eventsImported == 3, "Expected VFREEBUSY import to create one placeholder per FREEBUSY period")
        guard let freeBusyCalendar = store.calendars.first(where: { $0.title == "Team availability" }) else {
            throw ProtocolInvariantError("Expected VFREEBUSY import to create the Team availability calendar")
        }
        try expect(freeBusyCalendar.allowsEventWrite == false, "VFREEBUSY calendar should be read-only")
        try expect(freeBusyCalendar.allowsResponses == false, "VFREEBUSY calendar should not allow RSVP responses")

        let events = store.events.sorted { $0.startDate < $1.startDate }
        try expect(events.map(\.title) == ["Busy", "Tentative", "Free"], "Expected VFREEBUSY FBTYPE values to become clear placeholder titles")
        try expect(events.allSatisfy { $0.privacy == .private }, "VFREEBUSY placeholders should import as private blocks")
        try expect(events.allSatisfy { $0.categories == ["Free/busy"] }, "VFREEBUSY placeholders should be categorized as free/busy blocks")
        try expect(events.allSatisfy { $0.organizerEmail == "scheduler@example.com" }, "VFREEBUSY placeholders should preserve organizer email")
        try expect(events[0].availability == .busy, "BUSY FBTYPE should import as busy")
        try expect(events[1].status == .tentative, "BUSY-TENTATIVE FBTYPE should import as tentative status")
        try expect(events[2].availability == .free, "FREE FBTYPE should import as free availability")
        try expect(sameInstant(events[1].endDate, "2026-07-28T10:30:00Z"), "VFREEBUSY duration periods should derive the end date")
        try expect(
            store.events(from: date("2026-07-28T00:00:00Z"), to: date("2026-07-29T00:00:00Z")).count == 3,
            "VFREEBUSY placeholders should be visible through the calendar event expansion API"
        )
    }

    private static func verifyUnsupportedCalendarComponents() throws {
        let mixedComponentImport = try LocalCalendarICSCodec.import(mixedUnsupportedComponentICS)
        try expect(mixedComponentImport.events.count == 1,
                   "Expected VTODO/VJOURNAL components not to import as events")
        let mixedComponentEvent = try requireOnly(
            mixedComponentImport.events.filter { $0.externalUID == "mixed-component-event@example.com" },
            context: "mixed unsupported component fixture"
        )
        try expect(mixedComponentEvent.title == "Supported event in mixed component fixture",
                   "Expected the VEVENT in a mixed-component ICS to keep importing")

        do {
            _ = try LocalCalendarICSCodec.import(unsupportedOnlyComponentICS)
            throw ProtocolInvariantError("VTODO/VJOURNAL-only ICS should not import as events")
        } catch LocalICSImportError.noEvents {
            // Expected: unsupported components remain non-events until the app has first-class models for them.
        }
    }

    @MainActor
    private static func events(in store: LocalCalendarStore, from start: String, to end: String) -> [CalendarEvent] {
        store.events(from: date(start), to: date(end), includeAllDay: true)
    }

    @MainActor
    private static func requireFirstEvent(in store: LocalCalendarStore, from start: String, to end: String) throws -> CalendarEvent {
        guard let event = events(in: store, from: start, to: end).first else {
            throw ProtocolInvariantError("Expected an event in fixture range")
        }
        return event
    }

    @MainActor
    private static func requireFirstEvent(
        in store: LocalCalendarStore,
        from start: String,
        to end: String,
        externalIdentifier: String
    ) throws -> CalendarEvent {
        guard let event = events(in: store, from: start, to: end)
            .first(where: { $0.externalIdentifier == externalIdentifier })
        else {
            throw ProtocolInvariantError("Expected \(externalIdentifier) in fixture range")
        }
        return event
    }

    private static func requireOnly(
        _ events: [LocalCalendarEvent],
        context: String
    ) throws -> LocalCalendarEvent {
        guard events.count == 1, let event = events.first else {
            throw ProtocolInvariantError("Expected exactly one event for \(context), got \(events.count)")
        }
        return event
    }

    private static func requireOnlyCalendarEvent(
        _ events: [CalendarEvent],
        context: String
    ) throws -> CalendarEvent {
        guard events.count == 1, let event = events.first else {
            throw ProtocolInvariantError("Expected exactly one calendar event for \(context), got \(events.count)")
        }
        return event
    }

    private static func sameInstant(_ date: Date, _ expected: String) -> Bool {
        abs(date.timeIntervalSince(Self.date(expected))) < 0.5
    }

    private static func localDayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func localDayString(_ date: Date, timeZoneIdentifier: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func unfoldedICSLines(from text: String) -> [String] {
        var lines: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix(" ") || line.hasPrefix("\t"), let previous = lines.popLast() {
                lines.append(previous + String(line.dropFirst()))
            } else if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    private static func date(_ string: String) -> Date {
        guard let date = ISO8601DateFormatter().date(from: string) else {
            fatalError("Invalid test date: \(string)")
        }
        return date
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw ProtocolInvariantError(message)
        }
    }
}

private struct ProtocolInvariantError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
