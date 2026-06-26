import Foundation

struct LocalICSImportSummary {
    var calendarsImported: Int
    var eventsImported: Int
    var eventsUpdated: Int
    var eventsSkipped: Int
    var eventsDeleted: Int = 0
}

struct LocalICSCancellationTargets {
    var eventUIDs: Set<String> = []
    var occurrences: Set<LocalProviderOccurrenceCancellation> = []

    var isEmpty: Bool {
        eventUIDs.isEmpty && occurrences.isEmpty
    }
}

struct LocalICSReply: Hashable {
    var externalUID: String
    var occurrenceStartDate: Date?
    var attendees: [LocalEventAttendee]
}

struct LocalICSDetachedOccurrenceUpdate: Hashable {
    var externalUID: String
    var occurrence: LocalDetachedOccurrence
}

struct LocalICSAddedOccurrence: Hashable {
    var externalUID: String
    var calendarIDHint: String
    var occurrenceStartDate: Date
    var occurrence: LocalDetachedOccurrence
}

enum LocalICSImportError: LocalizedError {
    case noEvents

    var errorDescription: String? {
        switch self {
        case .noEvents:
            return "No events were found in this ICS file."
        }
    }
}

enum LocalCalendarICSCodec {
    static func export(
        calendars: [LocalCalendar],
        events: [LocalCalendarEvent],
        method: String? = "PUBLISH",
        includeWorkingMetadata: Bool = true
    ) -> String {
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Working Calendar//Local Calendar//EN",
            "CALSCALE:GREGORIAN",
            "X-WR-CALNAME:Working Calendar"
        ]
        if let method = method?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
           !method.isEmpty {
            lines.insert("METHOD:\(method)", at: 4)
        }

        let calendarByID = Dictionary(uniqueKeysWithValues: calendars.map { ($0.id, $0) })
        lines.append(contentsOf: exportedTimeZoneDefinitions(for: events))

        for event in events {
            guard let calendar = calendarByID[event.calendarID] ?? calendars.first else { continue }
            lines.append(contentsOf: eventLines(event, calendar: calendar, includeWorkingMetadata: includeWorkingMetadata))

            for occurrence in event.detachedOccurrences {
                let occurrenceCalendar = calendarByID[occurrence.calendarID] ?? calendar
                lines.append(contentsOf: detachedOccurrenceLines(
                    occurrence,
                    baseEvent: event,
                    calendar: occurrenceCalendar,
                    includeWorkingMetadata: includeWorkingMetadata
                ))
            }
        }

        lines.append("END:VCALENDAR")
        return foldedCalendarText(from: lines)
    }

    static func reply(
        event: LocalCalendarEvent,
        response: CalendarEventResponse,
        occurrenceStartDate: Date? = nil,
        occurrenceIsAllDay: Bool = false,
        attendeeEmail fallbackAttendeeEmail: String? = nil,
        attendeeName fallbackAttendeeName: String? = nil,
        now: Date = Date()
    ) -> String? {
        let attendeeSource = attendeeSource(
            for: event,
            occurrenceStartDate: occurrenceStartDate
        )
        let fallbackEmail = fallbackAttendeeEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackName = fallbackAttendeeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedFallbackEmail = normalizedEmail(fallbackEmail)
        let synthesizedFallbackEmail = normalizedFallbackEmail.isEmpty ? fallbackEmail : normalizedFallbackEmail
        guard var attendee = attendeeSource.first(where: { $0.isCurrentUser })
            ?? attendeeSource.first(where: { !normalizedFallbackEmail.isEmpty && normalizedEmail($0.email) == normalizedFallbackEmail })
            ?? (!fallbackEmail.isEmpty
                ? LocalEventAttendee(
                    name: fallbackName,
                    email: synthesizedFallbackEmail,
                    status: response.responseStatus,
                    type: "person",
                    role: "required",
                    rsvp: false,
                    isCurrentUser: false
                )
                : nil)
        else {
            return nil
        }

        attendee.status = response.responseStatus
        attendee.rsvp = false
        attendee.isCurrentUser = false

        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Working Calendar//Standalone Calendar//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:REPLY",
            "BEGIN:VEVENT",
            "UID:\(escapeText(event.externalUID))",
            "DTSTAMP:\(dateTimeFormatter.string(from: now))"
        ]
        if event.sequence > 0 {
            lines.append("SEQUENCE:\(event.sequence)")
        }
        if let occurrenceStartDate {
            lines.append(recurrenceIDLine(
                originalStartDate: occurrenceStartDate,
                isAllDay: occurrenceIsAllDay,
                timeZoneIdentifier: event.timeZoneIdentifier
            ))
        }
        lines.append(contentsOf: participantLines(
            organizerName: event.organizerName,
            organizerEmail: event.organizerEmail,
            attendees: [attendee],
            includeWorkingMetadata: false
        ))
        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")
        return foldedCalendarText(from: lines)
    }

    static func `import`(_ text: String) throws -> (calendars: [LocalCalendar], events: [LocalCalendarEvent]) {
        let lines = unfoldedLines(from: text)
        let calendarName = calendarName(from: lines)
        let calendarColorHex = calendarColorHex(from: lines)
        let calendarMethod = calendarMethod(from: lines)
        if isNonImportingSchedulingMethod(calendarMethod) {
            throw LocalICSImportError.noEvents
        }
        let timeZoneDefinitions = timeZoneDefinitions(from: lines)
        let fallbackTimeZoneIdentifier = calendarTimeZoneIdentifier(
            from: lines,
            timeZoneDefinitions: timeZoneDefinitions
        )
        let parsedEvents = eventBlocks(from: lines).compactMap {
            parseEvent(
                $0,
                fallbackCalendarTitle: calendarName,
                fallbackCalendarColorHex: calendarColorHex,
                calendarMethod: calendarMethod,
                fallbackTimeZoneIdentifier: fallbackTimeZoneIdentifier,
                timeZoneDefinitions: timeZoneDefinitions
            )
        }
        let parsedFreeBusyBlocks = freeBusyBlocks(
            from: lines,
            fallbackCalendarTitle: calendarName,
            fallbackCalendarColorHex: calendarColorHex,
            fallbackTimeZoneIdentifier: fallbackTimeZoneIdentifier,
            timeZoneDefinitions: timeZoneDefinitions
        )
        guard parsedEvents.contains(where: { !$0.isCancelled || $0.recurrenceID != nil || $0.importsCancelledAsEvent })
            || !parsedFreeBusyBlocks.isEmpty
        else {
            throw LocalICSImportError.noEvents
        }

        let now = Date()
        var calendars: [LocalCalendar] = []
        var calendarByKey: [String: LocalCalendar] = [:]

        func calendarFor(
            key: String,
            id: String,
            title: String,
            colorHexValue: String,
            allowsEventWrite: Bool,
            allowsResponses: Bool
        ) -> LocalCalendar {
            if let calendar = calendarByKey[key] {
                return calendar
            }

            let calendar = LocalCalendar(
                id: id,
                title: title.isEmpty ? "Imported Calendar" : title,
                colorHex: colorHexValue.isEmpty ? colorHex(for: calendars.count) : colorHexValue,
                allowsEventWrite: allowsEventWrite,
                allowsResponses: allowsResponses
            )
            calendars.append(calendar)
            calendarByKey[key] = calendar
            return calendar
        }

        func calendarFor(_ event: ParsedEvent) -> LocalCalendar {
            calendarFor(
                key: event.calendarKey,
                id: event.stableCalendarID,
                title: event.calendarTitle,
                colorHexValue: event.calendarColorHex,
                allowsEventWrite: event.calendarAllowsEventWrite,
                allowsResponses: event.calendarAllowsResponses
            )
        }

        func calendarFor(_ block: ParsedFreeBusyBlock) -> LocalCalendar {
            calendarFor(
                key: block.calendarKey,
                id: block.stableCalendarID,
                title: block.calendarTitle,
                colorHexValue: block.calendarColorHex,
                allowsEventWrite: false,
                allowsResponses: false
            )
        }

        var baseEventsBySeriesKey: [String: ParsedEvent] = [:]
        var detachedEventsBySeriesKey: [String: [ParsedEvent]] = [:]
        var importedEvents: [LocalCalendarEvent] = []
        let baseSeriesKeysByUID = Dictionary(grouping: parsedEvents.filter {
            !$0.isCancelled && $0.recurrenceID == nil
        }, by: \.baseLocalExternalUID)
            .mapValues { Set($0.map(\.seriesIdentityKey)) }

        func seriesIdentityKey(for event: ParsedEvent) -> String {
            guard event.recurrenceID != nil,
                  event.sourceCalendarID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let baseSeriesKeys = baseSeriesKeysByUID[event.baseLocalExternalUID],
                  baseSeriesKeys.count == 1,
                  let baseSeriesKey = baseSeriesKeys.first
            else {
                return event.seriesIdentityKey
            }

            return baseSeriesKey
        }

        for event in parsedEvents {
            if event.isCancelled, event.recurrenceID == nil, !event.importsCancelledAsEvent {
                continue
            }

            let seriesKey = seriesIdentityKey(for: event)
            if event.recurrenceID != nil {
                detachedEventsBySeriesKey[seriesKey, default: []].append(event)
            } else {
                baseEventsBySeriesKey[seriesKey] = event
            }
        }

        for (seriesKey, parsedEvent) in baseEventsBySeriesKey {
            let calendar = calendarFor(parsedEvent)
            let detachedEvents = detachedEventsBySeriesKey[seriesKey, default: []]
            let futureCancellationStarts = detachedEvents.compactMap { detached -> Date? in
                guard detached.isCancelled,
                      detached.recurrenceIDAppliesToFutureOccurrences
                else { return nil }
                return detached.recurrenceID
            }
            let futureRangeEvents = detachedEvents
                .filter { !$0.isCancelled && $0.recurrenceIDAppliesToFutureOccurrences && $0.recurrenceID != nil }
                .sorted { ($0.recurrenceID ?? .distantFuture) < ($1.recurrenceID ?? .distantFuture) }
            let futureRangeStarts = futureRangeEvents.compactMap(\.recurrenceID)
            let futureBoundaryStarts = (futureCancellationStarts + futureRangeStarts).sorted()
            let baseRecurrenceCalendar = recurrenceCalendar(for: parsedEvent)
            let cancelledOccurrenceStarts = detachedEvents.compactMap { detached -> Date? in
                guard detached.isCancelled,
                      !detached.recurrenceIDAppliesToFutureOccurrences
                else { return nil }
                return detached.recurrenceID
            }

            if let startDate = parsedEvent.startDate,
               !futureBoundaryStarts.contains(where: { cancelsEntireSeries(at: $0, baseStartDate: startDate) }) {
                let firstBoundary = futureBoundaryStarts.first
                let recurrenceEndDate = earliestRecurrenceEndDate(
                    parsedEvent.recurrenceEndDate,
                    candidates: futureBoundaryStarts.map { recurrenceEndDateBefore($0, calendar: baseRecurrenceCalendar) }
                )
                var detachedOccurrences = detachedEvents.compactMap { detached -> LocalDetachedOccurrence? in
                    guard let recurrenceID = detached.recurrenceID else { return nil }
                    guard !detached.isCancelled,
                          !detached.recurrenceIDAppliesToFutureOccurrences
                    else { return nil }
                    return LocalDetachedOccurrence(
                        originalStartDate: recurrenceID,
                        sequence: detached.sequence,
                        calendarID: calendar.id,
                        title: detached.title,
                        startDate: detached.startDate!,
                        endDate: detached.endDate!,
                        isAllDay: detached.isAllDay,
                        availability: detached.availability,
                        status: detached.eventStatus,
                        privacy: detached.privacy,
                        importance: detached.importance,
                        categories: detached.categories,
                        relatedEvents: detached.relatedEvents,
                        attachments: detached.attachments,
                        reminderOffsets: detached.reminderOffsets,
                        timeZoneIdentifier: detached.timeZoneIdentifier,
                        geoCoordinate: detached.geoCoordinate,
                        organizerName: detached.organizerName,
                        organizerEmail: detached.organizerEmail,
                        attendees: detached.attendees,
                        myResponseStatus: detached.myResponseStatus,
                        location: detached.location,
                        notes: detached.notes,
                        urlString: detached.urlString,
                        remoteObjectURLString: detached.remoteObjectURLString,
                        updatedAt: detached.updatedAt ?? detached.dtStamp ?? now
                    )
                }
                appendMissingDetachedOccurrences(
                    rdatePeriodDetachedOccurrences(
                        for: parsedEvent,
                        calendarID: calendar.id,
                        now: now
                    ).filter { periodDetached in
                        firstBoundary.map { periodDetached.originalStartDate < $0 } ?? true
                    },
                    to: &detachedOccurrences
                )

                importedEvents.append(localEvent(
                    from: parsedEvent,
                    calendar: calendar,
                    now: now,
                    recurrenceEndDate: recurrenceEndDate,
                    additionalOccurrenceStartDates: parsedEvent.additionalOccurrenceStartDates.filter { additionalStart in
                        firstBoundary.map { additionalStart < $0 } ?? true
                    }.uniqueOccurrenceStarts,
                    excludedOccurrenceStartDates: (parsedEvent.excludedOccurrenceStartDates + cancelledOccurrenceStarts).filter { exclusion in
                        firstBoundary.map { exclusion < $0 } ?? true
                    }.uniqueOccurrenceStarts,
                    detachedOccurrences: detachedOccurrences,
                    isImportedRecurrenceSplitProjection: parsedEvent.hasUnsupportedRecurrencePattern || !futureRangeEvents.isEmpty
                ))
            }

            for futureRangeEvent in futureRangeEvents {
                guard let recurrenceID = futureRangeEvent.recurrenceID,
                      recurrenceEndDateIncludes(parsedEvent.recurrenceEndDate, occurrenceStart: recurrenceID, calendar: baseRecurrenceCalendar)
                else { continue }

                let nextBoundary = futureBoundaryStarts.first { $0 > recurrenceID }
                let rangeRecurrenceEndDate = earliestRecurrenceEndDate(
                    parsedEvent.recurrenceEndDate,
                    candidates: nextBoundary.map { [recurrenceEndDateBefore($0, calendar: baseRecurrenceCalendar)] } ?? []
                )
                guard recurrenceEndDateIncludes(
                    rangeRecurrenceEndDate,
                    occurrenceStart: futureRangeEvent.startDate!,
                    calendar: recurrenceCalendar(for: futureRangeEvent)
                ) else {
                    continue
                }

                let recurrence = recurrencePatternForFutureRange(baseEvent: parsedEvent, futureRangeEvent: futureRangeEvent)
                importedEvents.append(localEvent(
                    from: futureRangeEvent,
                    calendar: calendarFor(futureRangeEvent),
                    now: now,
                    externalUID: "\(parsedEvent.localExternalUID)#range-this-and-future-\(Int(recurrenceID.timeIntervalSince1970))",
                    recurrenceFrequency: parsedEvent.recurrenceFrequency,
                    recurrenceInterval: parsedEvent.recurrenceInterval,
                    recurrenceWeekdays: recurrence.weekdays,
                    recurrenceWeekStart: recurrence.weekStart,
                    recurrenceSetPositions: recurrence.setPositions,
                    recurrenceOrdinal: recurrence.ordinal,
                    recurrenceOrdinalWeekday: recurrence.ordinalWeekday,
                    recurrenceMonthDay: recurrence.monthDay,
                    recurrenceMonths: recurrence.months,
                    recurrenceEndDate: rangeRecurrenceEndDate,
                    additionalOccurrenceStartDates: parsedEvent.additionalOccurrenceStartDates.filter { additionalStart in
                        additionalStart >= recurrenceID && (nextBoundary.map { additionalStart < $0 } ?? true)
                    }.uniqueOccurrenceStarts,
                    excludedOccurrenceStartDates: (parsedEvent.excludedOccurrenceStartDates + cancelledOccurrenceStarts).filter { exclusion in
                        exclusion >= recurrenceID && (nextBoundary.map { exclusion < $0 } ?? true)
                    }.uniqueOccurrenceStarts,
                    detachedOccurrences: rdatePeriodDetachedOccurrences(
                        for: parsedEvent,
                        calendarID: calendarFor(futureRangeEvent).id,
                        now: now
                    ).filter { periodDetached in
                        periodDetached.originalStartDate >= recurrenceID
                            && (nextBoundary.map { periodDetached.originalStartDate < $0 } ?? true)
                    },
                    isImportedRecurrenceSplitProjection: true
                ))
            }
        }

        let orphanDetachedEvents = detachedEventsBySeriesKey
            .filter { baseEventsBySeriesKey[$0.key] == nil }
            .flatMap(\.value)

        for parsedEvent in orphanDetachedEvents where !parsedEvent.isCancelled {
            let calendar = calendarFor(parsedEvent)
            importedEvents.append(LocalCalendarEvent(
                id: "local-event-\(UUID().uuidString)",
                externalUID: parsedEvent.localExternalUID,
                remoteObjectURLString: parsedEvent.remoteObjectURLString,
                remoteETag: parsedEvent.remoteETag,
                sequence: parsedEvent.sequence,
                calendarID: calendar.id,
                title: parsedEvent.title,
                startDate: parsedEvent.startDate!,
                endDate: parsedEvent.endDate!,
                isAllDay: parsedEvent.isAllDay,
                availability: parsedEvent.availability,
                status: parsedEvent.eventStatus,
                privacy: parsedEvent.privacy,
                importance: parsedEvent.importance,
                categories: parsedEvent.categories,
                relatedEvents: parsedEvent.relatedEvents,
                attachments: parsedEvent.attachments,
                reminderOffsets: parsedEvent.reminderOffsets,
                timeZoneIdentifier: parsedEvent.timeZoneIdentifier,
                geoCoordinate: parsedEvent.geoCoordinate,
                organizerName: parsedEvent.organizerName,
                organizerEmail: parsedEvent.organizerEmail,
                attendees: parsedEvent.attendees,
                myResponseStatus: parsedEvent.myResponseStatus,
                location: parsedEvent.location,
                notes: parsedEvent.notes,
                urlString: parsedEvent.urlString,
                createdAt: parsedEvent.createdAt ?? now,
                updatedAt: parsedEvent.updatedAt ?? parsedEvent.dtStamp ?? now
            ))
        }

        for block in parsedFreeBusyBlocks {
            let calendar = calendarFor(block)
            importedEvents.append(LocalCalendarEvent(
                id: "local-event-\(block.stableIdentifier)",
                externalUID: block.externalUID,
                remoteObjectURLString: block.remoteObjectURLString,
                sequence: 0,
                calendarID: calendar.id,
                title: block.title,
                startDate: block.startDate,
                endDate: block.endDate,
                isAllDay: false,
                availability: block.availability,
                status: block.status,
                privacy: .private,
                importance: .normal,
                categories: ["Free/busy"],
                reminderOffsets: [],
                timeZoneIdentifier: block.timeZoneIdentifier,
                organizerName: block.organizerName,
                organizerEmail: block.organizerEmail,
                attendees: [],
                myResponseStatus: .notInvited,
                location: "",
                notes: block.notes,
                urlString: "",
                createdAt: block.dtStamp ?? now,
                updatedAt: block.dtStamp ?? now
            ))
        }

        return (calendars, importedEvents)
    }

    static func cancellationTargets(from text: String) -> LocalICSCancellationTargets {
        let lines = unfoldedLines(from: text)
        let isCancelMethod = calendarMethod(from: lines) == "CANCEL"
        let timeZoneDefinitions = timeZoneDefinitions(from: lines)
        let fallbackTimeZoneIdentifier = calendarTimeZoneIdentifier(
            from: lines,
            timeZoneDefinitions: timeZoneDefinitions
        )
        var targets = LocalICSCancellationTargets()

        for eventLines in eventBlocks(from: lines) {
            guard isCancelledEvent(eventLines, isCancelMethod: isCancelMethod),
                  let uid = propertyValue(named: "UID", in: eventLines)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !uid.isEmpty
            else {
                continue
            }

            if let recurrenceID = property(named: "RECURRENCE-ID", in: eventLines) {
                guard let occurrenceStartDate = parseDate(
                    recurrenceID,
                    fallbackTimeZoneIdentifier: fallbackTimeZoneIdentifier,
                    timeZoneDefinitions: timeZoneDefinitions
                ).date
                else {
                    continue
                }

                targets.occurrences.insert(LocalProviderOccurrenceCancellation(
                    externalUID: uid,
                    occurrenceStartDate: occurrenceStartDate,
                    appliesToFutureOccurrences: recurrenceID.params["RANGE"]?.uppercased() == "THISANDFUTURE"
                ))
            } else {
                targets.eventUIDs.insert(uid)
            }
        }

        return targets
    }

    static func replies(from text: String) -> [LocalICSReply] {
        let lines = unfoldedLines(from: text)
        guard calendarMethod(from: lines) == "REPLY" else { return [] }

        let timeZoneDefinitions = timeZoneDefinitions(from: lines)
        let fallbackTimeZoneIdentifier = calendarTimeZoneIdentifier(
            from: lines,
            timeZoneDefinitions: timeZoneDefinitions
        )

        return eventBlocks(from: lines).compactMap { eventLines in
            guard let uid = propertyValue(named: "UID", in: eventLines)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !uid.isEmpty
            else {
                return nil
            }

            let attendees = eventLines.compactMap(replyAttendee(from:))
            guard !attendees.isEmpty else { return nil }

            let occurrenceStartDate = property(named: "RECURRENCE-ID", in: eventLines).flatMap {
                parseDate(
                    $0,
                    fallbackTimeZoneIdentifier: fallbackTimeZoneIdentifier,
                    timeZoneDefinitions: timeZoneDefinitions
                ).date
            }

            return LocalICSReply(
                externalUID: uid,
                occurrenceStartDate: occurrenceStartDate,
                attendees: attendees
            )
        }
    }

    static func isAddSchedulingMessage(_ text: String) -> Bool {
        calendarMethod(from: unfoldedLines(from: text)) == "ADD"
    }

    static func addedOccurrences(from text: String) -> [LocalICSAddedOccurrence] {
        let lines = unfoldedLines(from: text)
        let calendarMethod = calendarMethod(from: lines)
        guard calendarMethod == "ADD" else { return [] }

        let calendarName = calendarName(from: lines)
        let calendarColorHex = calendarColorHex(from: lines)
        let timeZoneDefinitions = timeZoneDefinitions(from: lines)
        let fallbackTimeZoneIdentifier = calendarTimeZoneIdentifier(
            from: lines,
            timeZoneDefinitions: timeZoneDefinitions
        )
        let now = Date()

        return eventBlocks(from: lines).flatMap { eventLines -> [LocalICSAddedOccurrence] in
            guard let parsedEvent = parseEvent(
                eventLines,
                fallbackCalendarTitle: calendarName,
                fallbackCalendarColorHex: calendarColorHex,
                calendarMethod: calendarMethod,
                fallbackTimeZoneIdentifier: fallbackTimeZoneIdentifier,
                timeZoneDefinitions: timeZoneDefinitions
            ),
                  !parsedEvent.isCancelled,
                  !parsedEvent.baseLocalExternalUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let startDate = parsedEvent.startDate,
                  let endDate = parsedEvent.endDate
            else {
                return []
            }

            let duration = max(0, endDate.timeIntervalSince(startDate))
            let occurrenceStartDates = ([parsedEvent.recurrenceID ?? startDate] + parsedEvent.additionalOccurrenceStartDates)
                .uniqueOccurrenceStarts
            return occurrenceStartDates.map { occurrenceStartDate in
                let occurrenceStart = abs(occurrenceStartDate.timeIntervalSince(startDate)) < 1 ? startDate : occurrenceStartDate
                let occurrenceEnd = occurrenceStart.addingTimeInterval(duration)
                let occurrence = LocalDetachedOccurrence(
                    originalStartDate: occurrenceStartDate,
                    sequence: parsedEvent.sequence,
                    calendarID: parsedEvent.stableCalendarID,
                    title: parsedEvent.title,
                    startDate: occurrenceStart,
                    endDate: occurrenceEnd,
                    isAllDay: parsedEvent.isAllDay,
                    availability: parsedEvent.availability,
                    status: parsedEvent.eventStatus,
                    privacy: parsedEvent.privacy,
                    importance: parsedEvent.importance,
                    categories: parsedEvent.categories,
                    relatedEvents: parsedEvent.relatedEvents,
                    attachments: parsedEvent.attachments,
                    reminderOffsets: parsedEvent.reminderOffsets,
                    timeZoneIdentifier: parsedEvent.timeZoneIdentifier,
                    geoCoordinate: parsedEvent.geoCoordinate,
                    organizerName: parsedEvent.organizerName,
                    organizerEmail: parsedEvent.organizerEmail,
                    attendees: parsedEvent.attendees,
                    myResponseStatus: parsedEvent.myResponseStatus,
                    location: parsedEvent.location,
                    notes: parsedEvent.notes,
                    urlString: parsedEvent.urlString,
                    remoteObjectURLString: parsedEvent.remoteObjectURLString,
                    updatedAt: parsedEvent.updatedAt ?? parsedEvent.dtStamp ?? now
                )
                return LocalICSAddedOccurrence(
                    externalUID: parsedEvent.baseLocalExternalUID,
                    calendarIDHint: parsedEvent.sourceCalendarID,
                    occurrenceStartDate: occurrenceStartDate,
                    occurrence: occurrence
                )
            }
        }
    }

    static func orphanDetachedOccurrenceUpdates(from text: String) -> [LocalICSDetachedOccurrenceUpdate] {
        let lines = unfoldedLines(from: text)
        let calendarName = calendarName(from: lines)
        let calendarColorHex = calendarColorHex(from: lines)
        let calendarMethod = calendarMethod(from: lines)
        let timeZoneDefinitions = timeZoneDefinitions(from: lines)
        let fallbackTimeZoneIdentifier = calendarTimeZoneIdentifier(
            from: lines,
            timeZoneDefinitions: timeZoneDefinitions
        )
        let parsedEvents = eventBlocks(from: lines).compactMap {
            parseEvent(
                $0,
                fallbackCalendarTitle: calendarName,
                fallbackCalendarColorHex: calendarColorHex,
                calendarMethod: calendarMethod,
                fallbackTimeZoneIdentifier: fallbackTimeZoneIdentifier,
                timeZoneDefinitions: timeZoneDefinitions
            )
        }
        let baseUIDs = Set(parsedEvents.filter { $0.recurrenceID == nil }.map(\.uid))
        let now = Date()

        return parsedEvents.compactMap { parsedEvent -> LocalICSDetachedOccurrenceUpdate? in
            guard let recurrenceID = parsedEvent.recurrenceID,
                  !parsedEvent.isCancelled,
                  !parsedEvent.recurrenceIDAppliesToFutureOccurrences,
                  !baseUIDs.contains(parsedEvent.uid),
                  let startDate = parsedEvent.startDate,
                  let endDate = parsedEvent.endDate
            else {
                return nil
            }

            let occurrence = LocalDetachedOccurrence(
                originalStartDate: recurrenceID,
                sequence: parsedEvent.sequence,
                calendarID: parsedEvent.stableCalendarID,
                title: parsedEvent.title,
                startDate: startDate,
                endDate: endDate,
                isAllDay: parsedEvent.isAllDay,
                availability: parsedEvent.availability,
                status: parsedEvent.eventStatus,
                privacy: parsedEvent.privacy,
                importance: parsedEvent.importance,
                categories: parsedEvent.categories,
                relatedEvents: parsedEvent.relatedEvents,
                attachments: parsedEvent.attachments,
                reminderOffsets: parsedEvent.reminderOffsets,
                timeZoneIdentifier: parsedEvent.timeZoneIdentifier,
                geoCoordinate: parsedEvent.geoCoordinate,
                organizerName: parsedEvent.organizerName,
                organizerEmail: parsedEvent.organizerEmail,
                attendees: parsedEvent.attendees,
                myResponseStatus: parsedEvent.myResponseStatus,
                location: parsedEvent.location,
                notes: parsedEvent.notes,
                urlString: parsedEvent.urlString,
                remoteObjectURLString: parsedEvent.remoteObjectURLString,
                updatedAt: parsedEvent.updatedAt ?? parsedEvent.dtStamp ?? now
            )
            return LocalICSDetachedOccurrenceUpdate(
                externalUID: parsedEvent.baseLocalExternalUID,
                occurrence: occurrence
            )
        }
    }

    private static func replyAttendee(from line: String) -> LocalEventAttendee? {
        guard let property = property(from: line),
              property.name == "ATTENDEE"
        else {
            return nil
        }

        let email = emailValue(from: property.value)
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return LocalEventAttendee(
            name: property.params["CN"] ?? "",
            email: email,
            status: EventResponseStatus(icsPartStat: property.params["PARTSTAT"] ?? "") ?? .pending,
            type: attendeeType(fromCUTYPE: property.params["CUTYPE"]),
            role: attendeeRole(fromICSRole: property.params["ROLE"]),
            rsvp: boolValue(property.params["RSVP"] ?? "", defaultValue: false),
            isCurrentUser: false
        )
    }

    private static func localEvent(
        from parsedEvent: ParsedEvent,
        calendar: LocalCalendar,
        now: Date,
        externalUID: String? = nil,
        recurrenceFrequency: LocalRecurrenceFrequency? = nil,
        recurrenceInterval: Int? = nil,
        recurrenceWeekdays: [Int]? = nil,
        recurrenceWeekStart: Int? = nil,
        recurrenceSetPositions: [Int]? = nil,
        recurrenceOrdinal: Int? = nil,
        recurrenceOrdinalWeekday: Int? = nil,
        recurrenceMonthDay: Int? = nil,
        recurrenceMonths: [Int]? = nil,
        recurrenceEndDate: Date? = nil,
        additionalOccurrenceStartDates: [Date] = [],
        excludedOccurrenceStartDates: [Date] = [],
        detachedOccurrences: [LocalDetachedOccurrence] = [],
        isImportedRecurrenceSplitProjection: Bool = false
    ) -> LocalCalendarEvent {
        LocalCalendarEvent(
            id: "local-event-\(UUID().uuidString)",
            externalUID: externalUID ?? parsedEvent.localExternalUID,
            remoteObjectURLString: parsedEvent.remoteObjectURLString,
            remoteETag: parsedEvent.remoteETag,
            sequence: parsedEvent.sequence,
            calendarID: calendar.id,
            title: parsedEvent.title,
            startDate: parsedEvent.startDate!,
            endDate: parsedEvent.endDate!,
            isAllDay: parsedEvent.isAllDay,
            availability: parsedEvent.availability,
            status: parsedEvent.eventStatus,
            privacy: parsedEvent.privacy,
            importance: parsedEvent.importance,
            categories: parsedEvent.categories,
            relatedEvents: parsedEvent.relatedEvents,
            attachments: parsedEvent.attachments,
            reminderOffsets: parsedEvent.reminderOffsets,
            timeZoneIdentifier: parsedEvent.timeZoneIdentifier,
            geoCoordinate: parsedEvent.geoCoordinate,
            organizerName: parsedEvent.organizerName,
            organizerEmail: parsedEvent.organizerEmail,
            attendees: parsedEvent.attendees,
            myResponseStatus: parsedEvent.myResponseStatus,
            location: parsedEvent.location,
            notes: parsedEvent.notes,
            urlString: parsedEvent.urlString,
            recurrenceFrequency: recurrenceFrequency ?? parsedEvent.recurrenceFrequency,
            recurrenceInterval: recurrenceInterval ?? parsedEvent.recurrenceInterval,
            recurrenceWeekdays: recurrenceWeekdays ?? parsedEvent.recurrenceWeekdays,
            recurrenceWeekStart: recurrenceWeekStart ?? parsedEvent.recurrenceWeekStart,
            recurrenceSetPositions: recurrenceSetPositions ?? parsedEvent.recurrenceSetPositions,
            recurrenceOrdinal: recurrenceOrdinal ?? parsedEvent.recurrenceOrdinal,
            recurrenceOrdinalWeekday: recurrenceOrdinalWeekday ?? parsedEvent.recurrenceOrdinalWeekday,
            recurrenceMonthDay: recurrenceMonthDay ?? parsedEvent.recurrenceMonthDay,
            recurrenceMonths: recurrenceMonths ?? parsedEvent.recurrenceMonths,
            recurrenceEndDate: recurrenceEndDate,
            additionalOccurrenceStartDates: additionalOccurrenceStartDates,
            excludedOccurrenceStartDates: excludedOccurrenceStartDates,
            detachedOccurrences: detachedOccurrences,
            isImportedRecurrenceSplitProjection: isImportedRecurrenceSplitProjection,
            createdAt: parsedEvent.createdAt ?? now,
            updatedAt: parsedEvent.updatedAt ?? parsedEvent.dtStamp ?? now
        )
    }

    private static func appendMissingDetachedOccurrences(
        _ additions: [LocalDetachedOccurrence],
        to detachedOccurrences: inout [LocalDetachedOccurrence]
    ) {
        for addition in additions where !detachedOccurrences.contains(where: {
            abs($0.originalStartDate.timeIntervalSince(addition.originalStartDate)) < 1
        }) {
            detachedOccurrences.append(addition)
        }
    }

    private static func rdatePeriodDetachedOccurrences(
        for parsedEvent: ParsedEvent,
        calendarID: String,
        now: Date
    ) -> [LocalDetachedOccurrence] {
        guard let startDate = parsedEvent.startDate,
              let endDate = parsedEvent.endDate,
              !parsedEvent.additionalOccurrencePeriods.isEmpty
        else {
            return []
        }

        let baseDuration = endDate.timeIntervalSince(startDate)
        return parsedEvent.additionalOccurrencePeriods.compactMap { period -> LocalDetachedOccurrence? in
            guard abs(period.endDate.timeIntervalSince(period.startDate) - baseDuration) >= 1 else {
                return nil
            }

            return LocalDetachedOccurrence(
                originalStartDate: period.startDate,
                sequence: parsedEvent.sequence,
                calendarID: calendarID,
                title: parsedEvent.title,
                startDate: period.startDate,
                endDate: period.endDate,
                isAllDay: parsedEvent.isAllDay,
                availability: parsedEvent.availability,
                status: parsedEvent.eventStatus,
                privacy: parsedEvent.privacy,
                importance: parsedEvent.importance,
                categories: parsedEvent.categories,
                relatedEvents: parsedEvent.relatedEvents,
                attachments: parsedEvent.attachments,
                reminderOffsets: parsedEvent.reminderOffsets,
                timeZoneIdentifier: parsedEvent.timeZoneIdentifier,
                geoCoordinate: parsedEvent.geoCoordinate,
                organizerName: parsedEvent.organizerName,
                organizerEmail: parsedEvent.organizerEmail,
                attendees: parsedEvent.attendees,
                myResponseStatus: parsedEvent.myResponseStatus,
                location: parsedEvent.location,
                notes: parsedEvent.notes,
                urlString: parsedEvent.urlString,
                remoteObjectURLString: parsedEvent.remoteObjectURLString,
                updatedAt: parsedEvent.updatedAt ?? parsedEvent.dtStamp ?? now
            )
        }
    }

    private static func eventLines(_ event: LocalCalendarEvent, calendar: LocalCalendar, includeWorkingMetadata: Bool) -> [String] {
        var lines = [
            "BEGIN:VEVENT",
            "UID:\(escapeText(event.externalUID))",
            "DTSTAMP:\(dateTimeFormatter.string(from: event.updatedAt))",
            "CREATED:\(dateTimeFormatter.string(from: event.createdAt))",
            "LAST-MODIFIED:\(dateTimeFormatter.string(from: event.updatedAt))",
            "SUMMARY:\(escapeText(event.title))"
        ]

        if event.sequence > 0 {
            lines.append("SEQUENCE:\(event.sequence)")
        }
        lines.append(contentsOf: dateLines(start: event.startDate, end: event.endDate, isAllDay: event.isAllDay, timeZoneIdentifier: event.timeZoneIdentifier))
        lines.append("TRANSP:\(event.availability.icsTransparency)")
        if event.status != .confirmed {
            lines.append("STATUS:\(event.status.icsStatus)")
        }
        if event.privacy != .public {
            lines.append("CLASS:\(event.privacy.icsClass)")
        }
        if event.importance != .normal {
            lines.append("PRIORITY:\(event.importance.icsPriority)")
        }
        if let geoLine = geoLine(event.geoCoordinate) {
            lines.append(geoLine)
        }
        if !event.categories.isEmpty {
            lines.append("CATEGORIES:\(textListValue(from: event.categories))")
        }
        lines.append(contentsOf: relationshipLines(event.relatedEvents))
        lines.append(contentsOf: attachmentLines(event.attachments))
        lines.append(contentsOf: participantLines(
            organizerName: event.organizerName,
            organizerEmail: event.organizerEmail,
            attendees: event.attendees,
            includeWorkingMetadata: includeWorkingMetadata
        ))
        lines.append(contentsOf: metadataLines(
            location: event.location,
            notes: event.notes,
            urlString: event.urlString,
            calendar: calendar,
            remoteObjectURLString: event.remoteObjectURLString,
            remoteETag: event.remoteETag,
            myResponseStatus: event.myResponseStatus,
            includeWorkingMetadata: includeWorkingMetadata
        ))

        if event.recurrenceFrequency != .none {
            lines.append(recurrenceRuleLine(
                frequency: event.recurrenceFrequency,
                interval: event.safeRecurrenceInterval,
                weekdays: event.recurrenceWeekdays,
                weekStart: event.recurrenceWeekStart,
                setPositions: event.recurrenceSetPositions,
                ordinal: event.recurrenceOrdinal,
                ordinalWeekday: event.recurrenceOrdinalWeekday,
                monthDay: event.recurrenceMonthDay,
                months: event.recurrenceMonths,
                startDate: event.startDate,
                endDate: event.recurrenceEndDate,
                isAllDay: event.isAllDay,
                timeZoneIdentifier: event.timeZoneIdentifier
            ))
        }

        if !event.additionalOccurrenceStartDates.isEmpty {
            lines.append(recurrenceDateLine(
                name: "RDATE",
                dates: event.additionalOccurrenceStartDates,
                isAllDay: event.isAllDay,
                timeZoneIdentifier: event.timeZoneIdentifier
            ))
        }

        if !event.excludedOccurrenceStartDates.isEmpty {
            lines.append(recurrenceDateLine(
                name: "EXDATE",
                dates: event.excludedOccurrenceStartDates,
                isAllDay: event.isAllDay,
                timeZoneIdentifier: event.timeZoneIdentifier
            ))
        }

        lines.append(contentsOf: alarmLines(reminderOffsets: event.reminderOffsets, title: event.title))
        lines.append("END:VEVENT")
        return lines
    }

    private static func detachedOccurrenceLines(
        _ occurrence: LocalDetachedOccurrence,
        baseEvent: LocalCalendarEvent,
        calendar: LocalCalendar,
        includeWorkingMetadata: Bool
    ) -> [String] {
        var lines = [
            "BEGIN:VEVENT",
            "UID:\(escapeText(baseEvent.externalUID))",
            recurrenceIDLine(
                originalStartDate: occurrence.originalStartDate,
                isAllDay: baseEvent.isAllDay,
                timeZoneIdentifier: baseEvent.timeZoneIdentifier
            ),
            "DTSTAMP:\(dateTimeFormatter.string(from: occurrence.updatedAt))",
            "LAST-MODIFIED:\(dateTimeFormatter.string(from: occurrence.updatedAt))",
            "SUMMARY:\(escapeText(occurrence.title))"
        ]

        if occurrence.sequence > 0 {
            lines.append("SEQUENCE:\(occurrence.sequence)")
        }
        lines.append(contentsOf: dateLines(start: occurrence.startDate, end: occurrence.endDate, isAllDay: occurrence.isAllDay, timeZoneIdentifier: occurrence.timeZoneIdentifier))
        lines.append("TRANSP:\(occurrence.availability.icsTransparency)")
        if occurrence.status != .confirmed {
            lines.append("STATUS:\(occurrence.status.icsStatus)")
        }
        if occurrence.privacy != .public {
            lines.append("CLASS:\(occurrence.privacy.icsClass)")
        }
        if occurrence.importance != .normal {
            lines.append("PRIORITY:\(occurrence.importance.icsPriority)")
        }
        if let geoLine = geoLine(occurrence.geoCoordinate) {
            lines.append(geoLine)
        }
        if !occurrence.categories.isEmpty {
            lines.append("CATEGORIES:\(textListValue(from: occurrence.categories))")
        }
        lines.append(contentsOf: relationshipLines(occurrence.relatedEvents))
        lines.append(contentsOf: attachmentLines(occurrence.attachments))
        lines.append(contentsOf: participantLines(
            organizerName: occurrence.organizerName,
            organizerEmail: occurrence.organizerEmail,
            attendees: occurrence.attendees,
            includeWorkingMetadata: includeWorkingMetadata
        ))
        lines.append(contentsOf: metadataLines(
            location: occurrence.location,
            notes: occurrence.notes,
            urlString: occurrence.urlString,
            calendar: calendar,
            remoteObjectURLString: occurrence.remoteObjectURLString ?? "",
            remoteETag: "",
            myResponseStatus: occurrence.myResponseStatus,
            includeWorkingMetadata: includeWorkingMetadata
        ))
        lines.append(contentsOf: alarmLines(reminderOffsets: occurrence.reminderOffsets, title: occurrence.title))
        lines.append("END:VEVENT")
        return lines
    }

    private static func recurrenceIDLine(originalStartDate: Date, isAllDay: Bool, timeZoneIdentifier: String) -> String {
        if isAllDay {
            return "RECURRENCE-ID;VALUE=DATE:\(allDayDateString(from: originalStartDate, timeZoneIdentifier: timeZoneIdentifier))"
        }

        let resolvedTimeZone = resolvedTimeZone(for: timeZoneIdentifier)
        return "RECURRENCE-ID;TZID=\(resolvedTimeZone.identifier):\(zonedDateTimeString(from: originalStartDate, timeZone: resolvedTimeZone.timeZone))"
    }

    private static func attendeeSource(
        for event: LocalCalendarEvent,
        occurrenceStartDate: Date?
    ) -> [LocalEventAttendee] {
        guard let occurrenceStartDate,
              let occurrence = event.detachedOccurrences.first(where: {
                  abs($0.originalStartDate.timeIntervalSince(occurrenceStartDate)) < 1
              })
        else {
            return event.attendees
        }
        return occurrence.attendees.isEmpty ? event.attendees : occurrence.attendees
    }

    private static func normalizedEmail(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        let withoutScheme: String
        if lowercased.hasPrefix("mailto:") {
            withoutScheme = String(trimmed.dropFirst("mailto:".count))
        } else if lowercased.hasPrefix("smtp:") {
            withoutScheme = String(trimmed.dropFirst("smtp:".count))
        } else {
            withoutScheme = trimmed
        }
        let email = percentDecodedEmail(mailtoAddressComponent(withoutScheme))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return email.contains("@") ? email : ""
    }

    private static func alarmLines(reminderOffsets: [Int], title: String) -> [String] {
        normalizedReminderOffsets(reminderOffsets).flatMap { minutesBeforeStart in
            [
                "BEGIN:VALARM",
                "ACTION:DISPLAY",
                "DESCRIPTION:\(escapeText(title.isEmpty ? "Reminder" : title))",
                "TRIGGER:\(alarmTriggerValue(minutesBeforeStart: minutesBeforeStart))",
                "END:VALARM"
            ]
        }
    }

    private static func dateLines(start: Date, end: Date, isAllDay: Bool, timeZoneIdentifier: String) -> [String] {
        if isAllDay {
            return [
                "DTSTART;VALUE=DATE:\(allDayDateString(from: start, timeZoneIdentifier: timeZoneIdentifier))",
                "DTEND;VALUE=DATE:\(allDayDateString(from: end, timeZoneIdentifier: timeZoneIdentifier))"
            ]
        }

        let resolvedTimeZone = resolvedTimeZone(for: timeZoneIdentifier)
        return [
            "DTSTART;TZID=\(resolvedTimeZone.identifier):\(zonedDateTimeString(from: start, timeZone: resolvedTimeZone.timeZone))",
            "DTEND;TZID=\(resolvedTimeZone.identifier):\(zonedDateTimeString(from: end, timeZone: resolvedTimeZone.timeZone))"
        ]
    }

    private static func metadataLines(
        location: String,
        notes: String,
        urlString: String,
        calendar: LocalCalendar,
        remoteObjectURLString: String = "",
        remoteETag: String = "",
        myResponseStatus: EventResponseStatus,
        includeWorkingMetadata: Bool
    ) -> [String] {
        var lines: [String] = []

        if includeWorkingMetadata {
            lines.append(contentsOf: [
                "X-WORKING-CALENDAR-ID:\(escapeText(calendar.id))",
                "X-WORKING-CALENDAR-TITLE:\(escapeText(calendar.title))",
                "X-WORKING-CALENDAR-COLOR:\(calendar.colorHex)",
                "X-WORKING-CALENDAR-ALLOWS-EVENT-WRITE:\(calendar.allowsEventWrite ? "TRUE" : "FALSE")",
                "X-WORKING-CALENDAR-ALLOWS-RESPONSES:\(calendar.allowsResponses ? "TRUE" : "FALSE")"
            ])
            if !remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("X-WORKING-REMOTE-OBJECT-URL:\(escapeText(remoteObjectURLString))")
            }
            if !remoteETag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("X-WORKING-REMOTE-ETAG:\(escapeText(remoteETag))")
            }
        }

        if includeWorkingMetadata && myResponseStatus != .notInvited {
            lines.append("X-WORKING-MY-RESPONSE:\(myResponseStatus.rawValue)")
        }

        if !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("LOCATION:\(escapeText(location))")
        }
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("DESCRIPTION:\(escapeText(notes))")
        }
        if !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("URL:\(escapeText(urlString))")
        }

        return lines
    }

    private static func relationshipLines(_ relatedEvents: [LocalEventRelationship]) -> [String] {
        normalizedEventRelationships(relatedEvents).map { relationship in
            "RELATED-TO;RELTYPE=\(relationship.relationType):\(escapeText(relationship.externalUID))"
        }
    }

    private static func attachmentLines(_ attachments: [LocalEventAttachment]) -> [String] {
        normalizedEventAttachments(attachments).map { attachment in
            var params = ["VALUE=URI"]
            if !attachment.formatType.isEmpty {
                params.append("FMTTYPE=\(escapeParameter(attachment.formatType))")
            }
            if !attachment.displayName.isEmpty {
                params.append("X-FILENAME=\"\(escapeParameter(attachment.displayName))\"")
            }
            return "ATTACH;\(params.joined(separator: ";")):\(escapeText(attachment.urlString))"
        }
    }

    private static func geoLine(_ coordinate: LocalEventGeoCoordinate?) -> String? {
        guard let coordinate else { return nil }
        return "GEO:\(geoFloatString(coordinate.latitude));\(geoFloatString(coordinate.longitude))"
    }

    private static func geoFloatString(_ value: Double) -> String {
        var text = String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.contains("."), text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }

    private static func participantLines(
        organizerName: String,
        organizerEmail: String,
        attendees: [LocalEventAttendee],
        includeWorkingMetadata: Bool
    ) -> [String] {
        var lines: [String] = []
        let trimmedOrganizerName = organizerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOrganizerEmail = organizerEmail.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedOrganizerName.isEmpty || !trimmedOrganizerEmail.isEmpty {
            var params: [String] = []
            if !trimmedOrganizerName.isEmpty {
                params.append("CN=\"\(escapeParameter(trimmedOrganizerName))\"")
            }
            lines.append("ORGANIZER\(params.isEmpty ? "" : ";\(params.joined(separator: ";"))"):\(mailtoValue(email: trimmedOrganizerEmail, fallbackName: trimmedOrganizerName))")
        }

        for attendee in attendees where !attendee.isBlank {
            var params = [
                "PARTSTAT=\(attendee.status.icsPartStat)",
                "ROLE=\(icsRole(for: attendee.normalizedRole))"
            ]
            let cutype = icsCalendarUserType(for: attendee.normalizedType)
            if cutype != "INDIVIDUAL" {
                params.append("CUTYPE=\(cutype)")
            }
            if includeWorkingMetadata && attendee.isCurrentUser {
                params.append("X-WORKING-CURRENT-USER=TRUE")
            }
            if attendee.rsvp {
                params.append("RSVP=TRUE")
            }
            let name = attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                params.append("CN=\"\(escapeParameter(name))\"")
            }
            lines.append("ATTENDEE;\(params.joined(separator: ";")):\(mailtoValue(email: attendee.email, fallbackName: name))")
        }

        return lines
    }

    private static func recurrenceRuleLine(
        frequency: LocalRecurrenceFrequency,
        interval: Int,
        weekdays: [Int],
        weekStart: Int?,
        setPositions: [Int],
        ordinal: Int?,
        ordinalWeekday: Int?,
        monthDay: Int?,
        months: [Int],
        startDate: Date,
        endDate: Date?,
        isAllDay: Bool,
        timeZoneIdentifier: String
    ) -> String {
        var parts = ["FREQ=\(frequency.icsName)", "INTERVAL=\(max(1, interval))"]
        var recurrenceCalendar = Calendar(identifier: .gregorian)
        recurrenceCalendar.timeZone = resolvedTimeZone(for: timeZoneIdentifier).timeZone
        if frequency == .weekly {
            let byDay = normalizedWeekdays(
                weekdays,
                startDate: startDate,
                calendar: recurrenceCalendar
            )
                .compactMap { icsWeekdayName(for: $0) }
                .joined(separator: ",")
            if !byDay.isEmpty {
                parts.append("BYDAY=\(byDay)")
            }
            let normalizedSetPositions = normalizedRecurrenceSetPositions(setPositions, frequency: frequency)
            if !normalizedSetPositions.isEmpty {
                parts.append("BYSETPOS=\(normalizedSetPositions.map(String.init).joined(separator: ","))")
            }
            if let weekStart,
               let weekStartName = icsWeekdayName(for: weekStart) {
                parts.append("WKST=\(weekStartName)")
            }
        } else if frequency == .monthly,
                  let ordinal,
                  let ordinalWeekday,
                  let weekdayName = icsWeekdayName(for: ordinalWeekday) {
            let normalizedMonths = normalizedRecurrenceMonths(months, frequency: frequency)
            if !normalizedMonths.isEmpty {
                parts.append("BYMONTH=\(normalizedMonths.map(String.init).joined(separator: ","))")
            }
            parts.append("BYDAY=\(ordinal)\(weekdayName)")
        } else if frequency == .monthly,
                  let monthDay {
            let normalizedMonths = normalizedRecurrenceMonths(months, frequency: frequency)
            if !normalizedMonths.isEmpty {
                parts.append("BYMONTH=\(normalizedMonths.map(String.init).joined(separator: ","))")
            }
            parts.append("BYMONTHDAY=\(monthDay)")
        } else if frequency == .monthly {
            let normalizedMonths = normalizedRecurrenceMonths(months, frequency: frequency)
            if !normalizedMonths.isEmpty {
                parts.append("BYMONTH=\(normalizedMonths.map(String.init).joined(separator: ","))")
            }
        } else if frequency == .yearly,
                  let ordinal,
                  let ordinalWeekday,
                  let weekdayName = icsWeekdayName(for: ordinalWeekday) {
            let normalizedMonths = normalizedRecurrenceMonths(months, frequency: frequency)
            if normalizedMonths.isEmpty {
                parts.append("BYMONTH=\(recurrenceCalendar.component(.month, from: startDate))")
            } else {
                parts.append("BYMONTH=\(normalizedMonths.map(String.init).joined(separator: ","))")
            }
            parts.append("BYDAY=\(ordinal)\(weekdayName)")
        } else if frequency == .yearly {
            let normalizedMonths = normalizedRecurrenceMonths(months, frequency: frequency)
            if normalizedMonths.isEmpty {
                parts.append("BYMONTH=\(recurrenceCalendar.component(.month, from: startDate))")
            } else {
                parts.append("BYMONTH=\(normalizedMonths.map(String.init).joined(separator: ","))")
            }
            parts.append("BYMONTHDAY=\(monthDay ?? recurrenceCalendar.component(.day, from: startDate))")
        }
        if let endDate {
            if isAllDay {
                parts.append("UNTIL=\(allDayDateString(from: endDate, timeZoneIdentifier: timeZoneIdentifier))")
            } else {
                parts.append("UNTIL=\(dateTimeFormatter.string(from: endDate))")
            }
        }
        return "RRULE:\(parts.joined(separator: ";"))"
    }

    private static func recurrenceDateLine(name: String, dates: [Date], isAllDay: Bool, timeZoneIdentifier: String) -> String {
        if isAllDay {
            return "\(name);VALUE=DATE:\(dates.map { allDayDateString(from: $0, timeZoneIdentifier: timeZoneIdentifier) }.joined(separator: ","))"
        }

        let resolvedTimeZone = resolvedTimeZone(for: timeZoneIdentifier)
        return "\(name);TZID=\(resolvedTimeZone.identifier):\(dates.map { zonedDateTimeString(from: $0, timeZone: resolvedTimeZone.timeZone) }.joined(separator: ","))"
    }

    private static func allDayDateString(from date: Date, timeZoneIdentifier: String) -> String {
        let resolvedTimeZone = resolvedTimeZone(for: timeZoneIdentifier)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = resolvedTimeZone.timeZone
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    private static func exportedTimeZoneDefinitions(for events: [LocalCalendarEvent]) -> [String] {
        let ranges = exportedTimeZoneRanges(for: events)
        return ranges.keys.sorted().flatMap { identifier in
            timeZoneDefinitionLines(identifier: identifier, range: ranges[identifier]!)
        }
    }

    private static func exportedTimeZoneRanges(for events: [LocalCalendarEvent]) -> [String: TimeZoneExportRange] {
        var ranges: [String: TimeZoneExportRange] = [:]

        func addRange(timeZoneIdentifier: String, dates: [Date]) {
            let dates = dates.sorted()
            guard let start = dates.first, let end = dates.last else { return }
            let resolved = resolvedTimeZone(for: timeZoneIdentifier)
            if var existing = ranges[resolved.identifier] {
                existing.start = min(existing.start, start)
                existing.end = max(existing.end, end)
                ranges[resolved.identifier] = existing
            } else {
                ranges[resolved.identifier] = TimeZoneExportRange(start: start, end: end)
            }
        }

        for event in events where !event.isAllDay {
            var dates = [event.startDate, event.endDate]
            if let recurrenceEndDate = event.recurrenceEndDate {
                dates.append(recurrenceEndDate)
            } else if event.recurrenceFrequency != .none,
                      let projectedEnd = Calendar.current.date(byAdding: .year, value: 5, to: event.startDate) {
                dates.append(projectedEnd)
            }
            dates.append(contentsOf: event.additionalOccurrenceStartDates)
            dates.append(contentsOf: event.excludedOccurrenceStartDates)
            addRange(timeZoneIdentifier: event.timeZoneIdentifier, dates: dates)
        }

        for occurrence in events.flatMap(\.detachedOccurrences) where !occurrence.isAllDay {
            addRange(
                timeZoneIdentifier: occurrence.timeZoneIdentifier,
                dates: [occurrence.originalStartDate, occurrence.startDate, occurrence.endDate]
            )
        }

        return ranges
    }

    private static func timeZoneDefinitionLines(identifier: String, range: TimeZoneExportRange) -> [String] {
        let resolved = resolvedTimeZone(for: identifier)
        let timeZone = resolved.timeZone
        let start = Calendar.current.date(byAdding: .year, value: -1, to: range.start) ?? range.start
        let end = Calendar.current.date(byAdding: .year, value: 1, to: range.end) ?? range.end
        var lines = [
            "BEGIN:VTIMEZONE",
            "TZID:\(escapeText(resolved.identifier))",
            "X-LIC-LOCATION:\(escapeText(resolved.identifier))"
        ]

        lines.append(contentsOf: fixedTimeZoneObservanceLines(timeZone: timeZone, at: start))
        lines.append(contentsOf: timeZoneTransitionObservanceLines(timeZone: timeZone, start: start, end: end))
        lines.append("END:VTIMEZONE")
        return lines
    }

    private static func fixedTimeZoneObservanceLines(timeZone: TimeZone, at date: Date) -> [String] {
        let isDaylight = timeZone.isDaylightSavingTime(for: date)
        let offset = timeZone.secondsFromGMT(for: date)
        return [
            "BEGIN:\(isDaylight ? "DAYLIGHT" : "STANDARD")",
            "DTSTART:\(zonedDateTimeString(from: date, timeZone: timeZone))",
            "TZOFFSETFROM:\(timeZoneOffsetString(offset))",
            "TZOFFSETTO:\(timeZoneOffsetString(offset))",
            "TZNAME:\(escapeText(timeZone.abbreviation(for: date) ?? timeZone.identifier))",
            "END:\(isDaylight ? "DAYLIGHT" : "STANDARD")"
        ]
    }

    private static func timeZoneTransitionObservanceLines(timeZone: TimeZone, start: Date, end: Date) -> [String] {
        var observances: [TimeZoneExportObservance] = []
        var cursor = start.addingTimeInterval(-1)

        while let transition = timeZone.nextDaylightSavingTimeTransition(after: cursor),
              transition <= end {
            let before = transition.addingTimeInterval(-1)
            let after = transition.addingTimeInterval(1)
            let observance = TimeZoneExportObservance(
                isDaylight: timeZone.isDaylightSavingTime(for: after),
                offsetFrom: timeZone.secondsFromGMT(for: before),
                offsetTo: timeZone.secondsFromGMT(for: after),
                name: timeZone.abbreviation(for: after) ?? timeZone.identifier,
                dates: [transition]
            )

            if let index = observances.firstIndex(where: { $0.sameDefinition(as: observance) }) {
                observances[index].dates.append(transition)
            } else {
                observances.append(observance)
            }
            cursor = transition.addingTimeInterval(1)
        }

        return observances.flatMap { observance in
            let dates = observance.dates.sorted()
            guard let firstDate = dates.first else { return [String]() }
            var lines = [
                "BEGIN:\(observance.isDaylight ? "DAYLIGHT" : "STANDARD")",
                "DTSTART:\(zonedDateTimeString(from: firstDate, timeZone: timeZone))",
                "TZOFFSETFROM:\(timeZoneOffsetString(observance.offsetFrom))",
                "TZOFFSETTO:\(timeZoneOffsetString(observance.offsetTo))",
                "TZNAME:\(escapeText(observance.name))"
            ]
            let extraDates = Array(dates.dropFirst())
            if !extraDates.isEmpty {
                lines.append("RDATE:\(extraDates.map { zonedDateTimeString(from: $0, timeZone: timeZone) }.joined(separator: ","))")
            }
            lines.append("END:\(observance.isDaylight ? "DAYLIGHT" : "STANDARD")")
            return lines
        }
    }

    private static func timeZoneOffsetString(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let absoluteSeconds = abs(seconds)
        let hours = absoluteSeconds / 3600
        let minutes = (absoluteSeconds % 3600) / 60
        return "\(sign)\(String(format: "%02d%02d", hours, minutes))"
    }

    private static func unfoldedLines(from text: String) -> [String] {
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

    private static func eventBlocks(from lines: [String]) -> [[String]] {
        componentBlocks(named: "VEVENT", from: lines)
    }

    private static func freeBusyComponentBlocks(from lines: [String]) -> [[String]] {
        componentBlocks(named: "VFREEBUSY", from: lines)
    }

    private static func componentBlocks(named componentName: String, from lines: [String]) -> [[String]] {
        var blocks: [[String]] = []
        var current: [String]?
        let begin = "BEGIN:\(componentName.uppercased())"
        let end = "END:\(componentName.uppercased())"

        for line in lines {
            if line.uppercased() == begin {
                current = []
            } else if line.uppercased() == end {
                if let current {
                    blocks.append(current)
                }
                current = nil
            } else if current != nil {
                current?.append(line)
            }
        }

        return blocks
    }

    private static func freeBusyBlocks(
        from lines: [String],
        fallbackCalendarTitle: String,
        fallbackCalendarColorHex: String?,
        fallbackTimeZoneIdentifier: String?,
        timeZoneDefinitions: [String: ICSTimeZoneDefinition]
    ) -> [ParsedFreeBusyBlock] {
        freeBusyComponentBlocks(from: lines).flatMap { componentLines in
            parsedFreeBusyBlocks(
                from: componentLines,
                fallbackCalendarTitle: fallbackCalendarTitle,
                fallbackCalendarColorHex: fallbackCalendarColorHex,
                fallbackTimeZoneIdentifier: fallbackTimeZoneIdentifier,
                timeZoneDefinitions: timeZoneDefinitions
            )
        }
    }

    private static func parsedFreeBusyBlocks(
        from lines: [String],
        fallbackCalendarTitle: String,
        fallbackCalendarColorHex: String?,
        fallbackTimeZoneIdentifier: String?,
        timeZoneDefinitions: [String: ICSTimeZoneDefinition]
    ) -> [ParsedFreeBusyBlock] {
        let uid = propertyValue(named: "UID", in: lines)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let dtStamp = property(named: "DTSTAMP", in: lines).flatMap {
            parseDate(
                $0,
                fallbackTimeZoneIdentifier: fallbackTimeZoneIdentifier,
                timeZoneDefinitions: timeZoneDefinitions
            ).date
        }
        let organizerProperty = property(named: "ORGANIZER", in: lines)
        let organizerName = organizerProperty?.params["CN"] ?? ""
        let organizerEmail = organizerProperty.map(participantEmail) ?? ""
        let sourceCalendarID = propertyValue(named: "X-WORKING-CALENDAR-ID", in: lines) ?? ""
        let metadataCalendarTitle = propertyValue(named: "X-WORKING-CALENDAR-TITLE", in: lines) ?? ""
        let metadataCalendarColorHex = propertyValue(named: "X-WORKING-CALENDAR-COLOR", in: lines) ?? ""
        let remoteObjectURLString = propertyValue(named: "X-WORKING-REMOTE-OBJECT-URL", in: lines) ?? ""
        let calendarTitle = fallbackCalendarTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Free/busy"
            : fallbackCalendarTitle
        let calendarColorHex = fallbackCalendarColorHex ?? "#64748B"

        var blocks: [ParsedFreeBusyBlock] = []
        for property in lines.compactMap(property(from:)).filter({ $0.name == "FREEBUSY" }) {
            let fbType = property.params["FBTYPE"]?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "BUSY"
            for periodValue in property.value.split(separator: ",").map(String.init) {
                guard let period = freeBusyPeriod(
                    from: periodValue,
                    property: property,
                    fallbackTimeZoneIdentifier: fallbackTimeZoneIdentifier,
                    timeZoneDefinitions: timeZoneDefinitions
                ) else {
                    continue
                }

                let sourceKey = [
                    uid,
                    periodValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    fbType,
                    String(blocks.count)
                ].joined(separator: "|")
                let stableIdentifier = stableIdentifierComponent(for: sourceKey)
                blocks.append(ParsedFreeBusyBlock(
                    sourceUID: uid,
                    stableIdentifier: stableIdentifier,
                    sourceCalendarID: sourceCalendarID,
                    remoteObjectURLString: remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? ""
                        : "\(remoteObjectURLString)/freebusy-\(stableIdentifier)",
                    calendarTitle: metadataCalendarTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? calendarTitle
                        : metadataCalendarTitle,
                    calendarColorHex: metadataCalendarColorHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? calendarColorHex
                        : metadataCalendarColorHex,
                    startDate: period.start,
                    endDate: period.end,
                    fbType: fbType,
                    timeZoneIdentifier: period.timeZoneIdentifier,
                    organizerName: organizerName,
                    organizerEmail: organizerEmail,
                    dtStamp: dtStamp
                ))
            }
        }

        return blocks
    }

    private static func freeBusyPeriod(
        from value: String,
        property: ICSProperty,
        fallbackTimeZoneIdentifier: String?,
        timeZoneDefinitions: [String: ICSTimeZoneDefinition]
    ) -> (start: Date, end: Date, timeZoneIdentifier: String)? {
        let pieces = value.split(separator: "/", maxSplits: 1).map(String.init)
        guard pieces.count == 2 else { return nil }
        let start = parseDateValue(
            pieces[0],
            isAllDay: property.params["VALUE"]?.uppercased() == "DATE",
            timeZoneIdentifier: property.params["TZID"] ?? fallbackTimeZoneIdentifier,
            timeZoneDefinitions: timeZoneDefinitions
        )
        guard let startDate = start.date else { return nil }

        let endDate: Date?
        if pieces[1].trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("P"),
           let duration = parseDurationSeconds(pieces[1]) {
            endDate = startDate.addingTimeInterval(duration)
        } else {
            endDate = parseDateValue(
                pieces[1],
                isAllDay: property.params["VALUE"]?.uppercased() == "DATE",
                timeZoneIdentifier: property.params["TZID"] ?? fallbackTimeZoneIdentifier,
                timeZoneDefinitions: timeZoneDefinitions
            ).date
        }

        guard let endDate, endDate > startDate else { return nil }
        return (startDate, endDate, start.timeZoneIdentifier)
    }

    private static func timeZoneDefinitions(from lines: [String]) -> [String: ICSTimeZoneDefinition] {
        var definitions: [String: ICSTimeZoneDefinition] = [:]
        var current: [String]?

        for line in lines {
            let uppercased = line.uppercased()
            if uppercased == "BEGIN:VTIMEZONE" {
                current = []
            } else if uppercased == "END:VTIMEZONE" {
                if let current, let definition = timeZoneDefinition(from: current) {
                    let keys = timeZoneDefinitionKeys(for: definition.sourceIdentifier)
                        + timeZoneDefinitionKeys(for: definition.identifier)
                    for key in keys {
                        definitions[key] = definition
                    }
                }
                current = nil
            } else if current != nil {
                current?.append(line)
            }
        }

        return definitions
    }

    private static func timeZoneDefinition(from lines: [String]) -> ICSTimeZoneDefinition? {
        var identifier = ""
        var locationIdentifier = ""
        var observances: [ICSTimeZoneObservance] = []
        var currentObservance: [String]?

        for line in lines {
            let uppercased = line.uppercased()
            if uppercased == "BEGIN:STANDARD" || uppercased == "BEGIN:DAYLIGHT" {
                currentObservance = []
                continue
            }

            if uppercased == "END:STANDARD" || uppercased == "END:DAYLIGHT" {
                if let currentObservance {
                    observances.append(contentsOf: timeZoneObservances(from: currentObservance))
                }
                currentObservance = nil
                continue
            }

            if currentObservance != nil {
                currentObservance?.append(line)
                continue
            }

            guard let property = property(from: line) else { continue }
            if property.name == "TZID" {
                identifier = property.textValue
            } else if property.name == "X-LIC-LOCATION" {
                locationIdentifier = property.textValue
            }
        }

        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIdentifier.isEmpty, !observances.isEmpty else { return nil }
        let trimmedLocationIdentifier = locationIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return ICSTimeZoneDefinition(
            identifier: normalizedTimeZoneIdentifier(trimmedLocationIdentifier)
                ?? normalizedTimeZoneIdentifier(trimmedIdentifier)
                ?? trimmedIdentifier,
            sourceIdentifier: trimmedIdentifier,
            observances: observances
        )
    }

    private static func timeZoneObservances(from lines: [String]) -> [ICSTimeZoneObservance] {
        var startDate: Date?
        var offsetToSeconds: Int?
        var recurrenceRuleComponents: [String: String] = [:]
        var rDates: [Date] = []
        var exDates: Set<Int> = []

        for line in lines {
            guard let property = property(from: line) else { continue }
            switch property.name {
            case "DTSTART":
                startDate = timeZoneLocalDate(from: property.value)
            case "TZOFFSETTO":
                offsetToSeconds = secondsFromUTCOffset(property.value)
            case "RRULE":
                recurrenceRuleComponents = recurrenceComponents(from: property.value)
            case "RDATE":
                rDates.append(contentsOf: timeZoneLocalDates(from: property))
            case "EXDATE":
                for date in timeZoneLocalDates(from: property) {
                    exDates.insert(timeZoneDateKey(date))
                }
            default:
                continue
            }
        }

        guard let offsetToSeconds else { return [] }

        var dates = rDates
        if let startDate {
            dates.append(startDate)
            dates.append(contentsOf: recurringTimeZoneObservanceDates(
                startDate: startDate,
                components: recurrenceRuleComponents
            ))
        }

        if dates.isEmpty {
            dates = [.distantPast]
        }

        var seen: Set<Int> = []
        return dates
            .sorted()
            .filter { date in
                let key = timeZoneDateKey(date)
                return !exDates.contains(key) && seen.insert(key).inserted
            }
            .map { ICSTimeZoneObservance(startDate: $0, offsetToSeconds: offsetToSeconds) }
    }

    private static func timeZoneLocalDates(from property: ICSProperty) -> [Date] {
        property.value.split(separator: ",").compactMap { value in
            let startValue = String(value)
                .split(separator: "/", maxSplits: 1)
                .first
                .map(String.init) ?? String(value)
            return timeZoneLocalDate(from: startValue)
        }
    }

    private static func timeZoneLocalDate(from value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("Z") {
            return ICSTimeZoneDefinition.localDate(from: String(trimmed.dropLast()))
        }
        return ICSTimeZoneDefinition.localDate(from: trimmed)
    }

    private static func timeZoneDateKey(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970.rounded())
    }

    private static func recurringTimeZoneObservanceDates(
        startDate: Date,
        components: [String: String]
    ) -> [Date] {
        guard components["FREQ"] == "YEARLY" else { return [] }

        let calendar = utcGregorianCalendar
        let startComponents = calendar.dateComponents([.year, .month, .day], from: startDate)
        guard let startYear = startComponents.year,
              let startMonth = startComponents.month,
              let startDay = startComponents.day
        else {
            return []
        }

        let interval = max(1, Int(components["INTERVAL"] ?? "") ?? 1)
        let countLimit = components["COUNT"].flatMap(Int.init).map { max(0, $0) }
        if countLimit == 0 { return [] }
        let untilDate = components["UNTIL"].flatMap(timeZoneLocalDate)
        let finalYear = min(untilDate.map { calendar.component(.year, from: $0) } ?? 2100, 2100)
        guard finalYear >= startYear else { return [] }
        let parsedMonths = recurrenceList(components["BYMONTH"] ?? "").filter { (1...12).contains($0) }
        let months = parsedMonths.isEmpty ? [startMonth] : parsedMonths
        let monthDays = recurrenceList(components["BYMONTHDAY"] ?? "")
            .filter { (-31...31).contains($0) && $0 != 0 }

        var dates: [Date] = []
        var emittedCount = 0

        for year in startYear...finalYear where (year - startYear).isMultiple(of: interval) {
            let candidates = months.flatMap { month in
                recurringTimeZoneCandidates(
                    year: year,
                    month: month,
                    fallbackDay: startDay,
                    monthDays: monthDays,
                    components: components,
                    matching: startDate
                )
            }.sorted()

            for candidate in candidates where candidate >= startDate {
                if let untilDate, candidate > untilDate {
                    return dates
                }

                dates.append(candidate)
                emittedCount += 1
                if let countLimit, emittedCount >= countLimit {
                    return dates
                }
            }
        }

        return dates
    }

    private static func recurringTimeZoneCandidates(
        year: Int,
        month: Int,
        fallbackDay: Int,
        monthDays: [Int],
        components: [String: String],
        matching sourceDate: Date
    ) -> [Date] {
        let byDayTokens = components["BYDAY"]?
            .split(separator: ",")
            .map { String($0).uppercased() } ?? []

        if !monthDays.isEmpty {
            return monthDays.compactMap {
                timeZoneMonthDayOccurrence(year: year, month: month, day: $0, matching: sourceDate)
            }
        }

        if !byDayTokens.isEmpty {
            var candidates = byDayTokens.flatMap {
                timeZoneWeekdayOccurrences(year: year, month: month, byDayToken: $0, matching: sourceDate)
            }.sorted()

            if let setPositions = components["BYSETPOS"].map(recurrenceList), !setPositions.isEmpty {
                candidates = setPositions.compactMap { position in
                    timeZoneSetPosition(position, in: candidates)
                }
            }

            return candidates
        }

        return timeZoneMonthDayOccurrence(
            year: year,
            month: month,
            day: fallbackDay,
            matching: sourceDate
        ).map { [$0] } ?? []
    }

    private static func timeZoneWeekdayOccurrences(
        year: Int,
        month: Int,
        byDayToken: String,
        matching sourceDate: Date
    ) -> [Date] {
        let weekdayToken = String(byDayToken.suffix(2))
        guard let weekday = weekdayNumber(forICSName: weekdayToken) else { return [] }

        let ordinalText = String(byDayToken.dropLast(2))
        if let ordinal = Int(ordinalText), ordinal != 0 {
            return timeZoneOrdinalWeekdayOccurrence(
                year: year,
                month: month,
                ordinal: ordinal,
                weekday: weekday,
                matching: sourceDate
            ).map { [$0] } ?? []
        }

        guard let monthStart = utcGregorianCalendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let monthRange = utcGregorianCalendar.range(of: .day, in: .month, for: monthStart)
        else {
            return []
        }

        return monthRange.compactMap { day in
            guard let candidate = timeZoneMonthDayOccurrence(
                year: year,
                month: month,
                day: day,
                matching: sourceDate
            ),
                  utcGregorianCalendar.component(.weekday, from: candidate) == weekday
            else {
                return nil
            }
            return candidate
        }
    }

    private static func timeZoneSetPosition(_ position: Int, in candidates: [Date]) -> Date? {
        guard position != 0, !candidates.isEmpty else { return nil }
        if position > 0 {
            let index = position - 1
            return candidates.indices.contains(index) ? candidates[index] : nil
        }

        let index = candidates.count + position
        return candidates.indices.contains(index) ? candidates[index] : nil
    }

    private static func timeZoneOrdinalWeekdayOccurrence(
        year: Int,
        month: Int,
        ordinal: Int,
        weekday: Int,
        matching sourceDate: Date
    ) -> Date? {
        guard let monthStart = utcGregorianCalendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let monthInterval = utcGregorianCalendar.dateInterval(of: .month, for: monthStart)
        else {
            return nil
        }

        let day: Date?
        if ordinal > 0 {
            let firstWeekday = utcGregorianCalendar.component(.weekday, from: monthInterval.start)
            let dayOffset = (weekday - firstWeekday + 7) % 7
            day = utcGregorianCalendar.date(
                byAdding: .day,
                value: dayOffset + ((ordinal - 1) * 7),
                to: monthInterval.start
            )
        } else {
            let lastDay = monthInterval.end.addingTimeInterval(-24 * 60 * 60)
            let lastWeekday = utcGregorianCalendar.component(.weekday, from: lastDay)
            let dayOffset = (lastWeekday - weekday + 7) % 7
            day = utcGregorianCalendar.date(
                byAdding: .day,
                value: -(dayOffset + ((abs(ordinal) - 1) * 7)),
                to: lastDay
            )
        }

        guard let day,
              day >= monthInterval.start,
              day < monthInterval.end
        else {
            return nil
        }

        return timeZoneDate(on: day, matching: sourceDate)
    }

    private static func timeZoneMonthDayOccurrence(
        year: Int,
        month: Int,
        day: Int,
        matching sourceDate: Date
    ) -> Date? {
        guard let monthStart = utcGregorianCalendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let monthRange = utcGregorianCalendar.range(of: .day, in: .month, for: monthStart)
        else {
            return nil
        }

        let resolvedDay = day > 0 ? day : monthRange.count + day + 1
        guard monthRange.contains(resolvedDay) else { return nil }
        return timeZoneDate(on: monthStart, day: resolvedDay, matching: sourceDate)
    }

    private static func timeZoneDate(on day: Date, matching sourceDate: Date) -> Date? {
        let components = utcGregorianCalendar.dateComponents([.year, .month, .day], from: day)
        return timeZoneDate(from: components, matching: sourceDate)
    }

    private static func timeZoneDate(on monthStart: Date, day: Int, matching sourceDate: Date) -> Date? {
        var components = utcGregorianCalendar.dateComponents([.year, .month], from: monthStart)
        components.day = day
        return timeZoneDate(from: components, matching: sourceDate)
    }

    private static func timeZoneDate(from sourceComponents: DateComponents, matching sourceDate: Date) -> Date? {
        var components = sourceComponents
        let time = utcGregorianCalendar.dateComponents([.hour, .minute, .second], from: sourceDate)
        components.calendar = utcGregorianCalendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.hour = time.hour ?? 0
        components.minute = time.minute ?? 0
        components.second = time.second ?? 0
        return utcGregorianCalendar.date(from: components)
    }

    private static func timeZoneDefinitionKeys(for identifier: String) -> [String] {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: " ", with: "_")
        return Array(Set([trimmed, compact, trimmed.lowercased(), compact.lowercased()].filter { !$0.isEmpty }))
    }

    private static func calendarName(from lines: [String]) -> String {
        lines.compactMap(property(from:)).first { $0.name == "X-WR-CALNAME" }?.textValue ?? "Imported Calendar"
    }

    private static func calendarColorHex(from lines: [String]) -> String? {
        for propertyName in ["X-WR-CALCOLOR", "COLOR", "X-APPLE-CALENDAR-COLOR"] {
            if let rawColor = lines.compactMap(property(from:)).first(where: { $0.name == propertyName })?.textValue,
               let color = normalizedCalendarColorHex(rawColor) {
                return color
            }
        }
        return nil
    }

    private static func calendarMethod(from lines: [String]) -> String {
        lines.compactMap(property(from:)).first { $0.name == "METHOD" }?.textValue.uppercased() ?? ""
    }

    private static func isNonImportingSchedulingMethod(_ method: String) -> Bool {
        switch method {
        case "ADD", "REPLY", "REFRESH":
            return true
        default:
            return false
        }
    }

    private static func isCancelledEvent(_ lines: [String], isCancelMethod: Bool) -> Bool {
        let status = propertyValue(named: "STATUS", in: lines)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return isCancelMethod || status == "CANCELLED"
    }

    private static func calendarTimeZoneIdentifier(
        from lines: [String],
        timeZoneDefinitions: [String: ICSTimeZoneDefinition]
    ) -> String? {
        guard let rawIdentifier = lines
            .compactMap(property(from:))
            .first(where: { $0.name == "X-WR-TIMEZONE" })?
            .textValue
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawIdentifier.isEmpty
        else {
            return nil
        }

        return normalizedTimeZoneIdentifier(rawIdentifier)
            ?? timeZoneDefinition(for: rawIdentifier, in: timeZoneDefinitions)?.identifier
            ?? rawIdentifier
    }

    private static func parseEvent(
        _ lines: [String],
        fallbackCalendarTitle: String,
        fallbackCalendarColorHex: String?,
        calendarMethod: String,
        fallbackTimeZoneIdentifier: String?,
        timeZoneDefinitions: [String: ICSTimeZoneDefinition]
    ) -> ParsedEvent? {
        var event = ParsedEvent(
            calendarTitle: fallbackCalendarTitle,
            calendarColorHex: fallbackCalendarColorHex ?? ""
        )
        if let fallbackTimeZoneIdentifier,
           !fallbackTimeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            event.timeZoneIdentifier = fallbackTimeZoneIdentifier
        }

        var currentAlarm: ParsedAlarm?
        var parsedAlarms: [ParsedAlarm] = []
        for line in lines {
            guard let property = property(from: line) else { continue }
            if property.name == "BEGIN", property.value.uppercased() == "VALARM" {
                currentAlarm = ParsedAlarm()
                continue
            }
            if property.name == "END", property.value.uppercased() == "VALARM" {
                if let currentAlarm {
                    parsedAlarms.append(currentAlarm)
                }
                currentAlarm = nil
                continue
            }
            if currentAlarm != nil {
                switch property.name {
                case "TRIGGER":
                    currentAlarm?.trigger = alarmTrigger(
                        from: property,
                        fallbackTimeZoneIdentifier: fallbackTimeZoneIdentifier,
                        timeZoneDefinitions: timeZoneDefinitions
                    )
                case "DURATION":
                    currentAlarm?.repeatDurationSeconds = parseDurationSeconds(property.value)
                case "REPEAT":
                    currentAlarm?.repeatCount = max(0, Int(property.textValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
                default:
                    break
                }
                continue
            }

            switch property.name {
            case "UID":
                event.uid = property.textValue
            case "SUMMARY":
                event.title = property.textValue
            case "SEQUENCE":
                event.sequence = max(0, Int(property.textValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
            case "CREATED":
                event.createdAt = parseDateValue(
                    property.value,
                    isAllDay: false,
                    timeZoneIdentifier: property.params["TZID"] ?? fallbackTimeZoneIdentifier,
                    timeZoneDefinitions: timeZoneDefinitions
                ).date
            case "LAST-MODIFIED":
                event.updatedAt = parseDateValue(
                    property.value,
                    isAllDay: false,
                    timeZoneIdentifier: property.params["TZID"] ?? fallbackTimeZoneIdentifier,
                    timeZoneDefinitions: timeZoneDefinitions
                ).date
            case "DTSTAMP":
                let date = parseDateValue(
                    property.value,
                    isAllDay: false,
                    timeZoneIdentifier: property.params["TZID"] ?? fallbackTimeZoneIdentifier,
                    timeZoneDefinitions: timeZoneDefinitions
                ).date
                event.dtStamp = date
                if event.updatedAt == nil {
                    event.updatedAt = date
                }
            case "DESCRIPTION":
                event.notes = property.textValue
            case "COMMENT":
                appendLabeledNoteFragment(property.textValue, label: "Comment", to: &event)
            case "CONTACT":
                appendLabeledNoteFragment(property.textValue, label: "Contact", to: &event)
            case "LOCATION":
                event.location = property.textValue
            case "GEO":
                event.geoCoordinate = geoCoordinate(from: property.textValue)
            case "URL":
                event.urlString = property.textValue
            case "X-ALT-DESC":
                appendNoteFragment(property.textValue, to: &event)
            case "CONFERENCE",
                 "X-GOOGLE-CONFERENCE",
                 "X-ZOOM-JOINURL",
                 "X-MICROSOFT-ONLINEMEETINGJOINURL",
                 "X-MICROSOFT-SKYPETEAMSMEETINGURL",
                 "X-MICROSOFT-ONLINEMEETINGCONFLINK",
                 "X-MICROSOFT-TEAMS-MEETINGURL",
                 "X-APPLE-STRUCTURED-LOCATION":
                applyAuxiliaryEventURLProperty(property, to: &event)
            case "ATTACH":
                if let attachment = attachment(from: property) {
                    event.attachments.append(attachment)
                }
                applyAuxiliaryEventURLProperty(property, to: &event)
            case "TRANSP":
                event.availability = CalendarEventAvailability(icsTransparency: property.value)
                event.availabilityWasSetByTransparency = true
            case "STATUS":
                event.status = property.textValue.uppercased()
                event.statusWasSetByStatus = true
            case "X-MICROSOFT-CDO-BUSYSTATUS":
                switch property.textValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
                case "FREE":
                    if !event.availabilityWasSetByTransparency {
                        event.availability = .free
                    }
                case "TENTATIVE":
                    if !event.availabilityWasSetByTransparency {
                        event.availability = .busy
                    }
                    if !event.statusWasSetByStatus {
                        event.status = "TENTATIVE"
                    }
                case "BUSY", "OOF", "WORKINGELSEWHERE":
                    if !event.availabilityWasSetByTransparency {
                        event.availability = .busy
                    }
                default:
                    break
                }
            case "X-MICROSOFT-CDO-ALLDAYEVENT":
                event.microsoftAllDayEvent = boolValue(property.textValue, defaultValue: event.microsoftAllDayEvent)
            case "X-MICROSOFT-DISALLOW-COUNTER":
                if boolValue(property.textValue, defaultValue: false) {
                    event.categories.append("Microsoft new time proposals disabled")
                }
            case "CLASS":
                event.privacy = CalendarEventPrivacy(icsClass: property.textValue)
            case "PRIORITY":
                event.importance = CalendarEventImportance(icsPriority: property.textValue)
                event.importanceWasSetByPriority = true
            case "IMPORTANCE", "X-MICROSOFT-CDO-IMPORTANCE":
                if !event.importanceWasSetByPriority {
                    event.importance = CalendarEventImportance(microsoftImportance: property.textValue)
                }
            case "CATEGORIES":
                event.categories.append(contentsOf: textListValues(from: property.value))
            case "RELATED-TO":
                event.relatedEvents.append(LocalEventRelationship(
                    relationType: property.params["RELTYPE"] ?? "PARENT",
                    externalUID: property.textValue
                ))
            case "RESOURCES":
                event.resourceNames.append(contentsOf: textListValues(from: property.value))
            case "ORGANIZER":
                event.organizerName = property.params["CN"] ?? ""
                event.organizerEmail = participantEmail(from: property)
            case "ATTENDEE":
                event.attendees.append(LocalEventAttendee(
                    name: property.params["CN"] ?? "",
                    email: participantEmail(from: property),
                    status: EventResponseStatus(icsPartStat: property.params["PARTSTAT"] ?? "") ?? .pending,
                    type: attendeeType(fromCUTYPE: property.params["CUTYPE"]),
                    role: attendeeRole(fromICSRole: property.params["ROLE"]),
                    rsvp: boolValue(property.params["RSVP"] ?? "", defaultValue: false),
                    isCurrentUser: boolValue(property.params["X-WORKING-CURRENT-USER"] ?? "", defaultValue: false)
                ))
            case "DTSTART":
                let parsed = parseDate(
                    property,
                    fallbackTimeZoneIdentifier: fallbackTimeZoneIdentifier,
                    timeZoneDefinitions: timeZoneDefinitions
                )
                event.startDate = parsed.date
                event.isAllDay = parsed.isAllDay
                event.timeZoneIdentifier = parsed.timeZoneIdentifier
            case "DTEND":
                event.endDate = parseDate(
                    property,
                    fallbackTimeZoneIdentifier: fallbackTimeZoneIdentifier,
                    timeZoneDefinitions: timeZoneDefinitions
                ).date
            case "DURATION":
                event.durationSeconds = parseDurationSeconds(property.value)
                event.durationCalendarDays = parseCalendarDayDuration(property.value)
            case "RECURRENCE-ID":
                let parsed = parseDate(
                    property,
                    fallbackTimeZoneIdentifier: fallbackTimeZoneIdentifier,
                    timeZoneDefinitions: timeZoneDefinitions
                )
                event.recurrenceID = parsed.date
                event.recurrenceIDAppliesToFutureOccurrences = property.params["RANGE"]?.uppercased() == "THISANDFUTURE"
                if !parsed.timeZoneIdentifier.isEmpty {
                    event.timeZoneIdentifier = parsed.timeZoneIdentifier
                }
            case "RRULE":
                applyRecurrenceRule(property.value, to: &event, timeZoneDefinitions: timeZoneDefinitions)
            case "EXRULE":
                event.hasUnsupportedRecurrenceExclusionRule = true
            case "RDATE":
                let recurrenceDates = recurrenceDates(
                    property,
                    fallbackTimeZoneIdentifier: fallbackTimeZoneIdentifier,
                    timeZoneDefinitions: timeZoneDefinitions
                )
                event.additionalOccurrenceStartDates.append(contentsOf: recurrenceDates.dates)
                event.additionalOccurrencePeriods.append(contentsOf: recurrenceDates.periods)
            case "EXDATE":
                event.excludedOccurrenceStartDates.append(contentsOf: recurrenceDateValues(
                    property,
                    fallbackTimeZoneIdentifier: fallbackTimeZoneIdentifier,
                    timeZoneDefinitions: timeZoneDefinitions
                ))
            case "X-WORKING-CALENDAR-ID":
                event.sourceCalendarID = property.textValue
            case "X-WORKING-CALENDAR-TITLE":
                event.calendarTitle = property.textValue
            case "X-WORKING-CALENDAR-COLOR":
                event.calendarColorHex = property.textValue
            case "X-WR-CALCOLOR", "COLOR", "X-APPLE-CALENDAR-COLOR":
                if let color = normalizedCalendarColorHex(property.textValue) {
                    event.calendarColorHex = color
                }
            case "X-WORKING-CALENDAR-ALLOWS-EVENT-WRITE":
                event.calendarAllowsEventWrite = boolValue(property.textValue, defaultValue: true)
            case "X-WORKING-CALENDAR-ALLOWS-RESPONSES":
                event.calendarAllowsResponses = boolValue(property.textValue, defaultValue: event.calendarAllowsEventWrite)
            case "X-WORKING-EXTERNAL-UID":
                event.externalUIDOverride = property.textValue
            case "X-WORKING-REMOTE-OBJECT-URL":
                event.remoteObjectURLString = property.textValue
            case "X-WORKING-REMOTE-ETAG":
                event.remoteETag = property.textValue
            case "X-WORKING-MY-RESPONSE":
                event.myResponseStatus = EventResponseStatus(rawValue: property.textValue) ?? event.myResponseStatus
            default:
                continue
            }
        }

        applySchedulingMethod(calendarMethod, to: &event)
        if event.isCancelled, let recurrenceID = event.recurrenceID, event.startDate == nil {
            event.startDate = recurrenceID
            event.endDate = recurrenceID
        }

        guard let startDate = event.startDate else { return nil }
        if event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            event.title = "Imported event"
        }
        if event.microsoftAllDayEvent {
            event.isAllDay = true
        }
        if event.endDate == nil {
            event.endDate = defaultEndDate(for: event, startDate: startDate)
        }
        event.reminderOffsets.append(contentsOf: parsedAlarms.flatMap {
            $0.reminderOffsets(startDate: startDate, endDate: event.endDate)
        })
        if event.uid.isEmpty {
            event.uid = fallbackUID(for: event)
        }
        if event.hasUnsupportedRecurrenceExclusionRule {
            disableRecurrence(for: &event)
        } else {
            normalizeSupportedRecurrencePattern(&event, startDate: startDate)
        }
        if event.recurrenceEndDate == nil, let recurrenceCountEndDate = recurrenceEndDateFromCount(for: event) {
            event.recurrenceEndDate = recurrenceCountEndDate
        }
        appendResourceAttendees(event.resourceNames, to: &event)
        if event.myResponseStatus == .notInvited,
           let currentUserAttendee = event.attendees.first(where: \.isCurrentUser) {
            event.myResponseStatus = currentUserAttendee.status
        }
        return event
    }

    private static func applySchedulingMethod(_ calendarMethod: String, to event: inout ParsedEvent) {
        switch calendarMethod {
        case "CANCEL":
            event.status = "CANCELLED"
        case "COUNTER":
            event.status = "TENTATIVE"
            event.categories.append("iTIP counter proposal")
        case "DECLINECOUNTER":
            event.status = "CANCELLED"
            event.categories.append("iTIP counter proposal declined")
            event.importsCancelledAsEvent = true
        default:
            break
        }
    }

    private static func defaultEndDate(for event: ParsedEvent, startDate: Date) -> Date {
        if event.isAllDay,
           let durationCalendarDays = event.durationCalendarDays,
           durationCalendarDays > 0 {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = resolvedTimeZone(for: event.timeZoneIdentifier).timeZone
            return calendar.date(byAdding: .day, value: durationCalendarDays, to: startDate)
                ?? startDate.addingTimeInterval(TimeInterval(durationCalendarDays * 24 * 3600))
        }

        if let durationSeconds = event.durationSeconds {
            return startDate.addingTimeInterval(durationSeconds)
        }

        if event.isAllDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = resolvedTimeZone(for: event.timeZoneIdentifier).timeZone
            return calendar.date(byAdding: .day, value: 1, to: startDate)
                ?? startDate.addingTimeInterval(24 * 3600)
        }

        return startDate.addingTimeInterval(30 * 60)
    }

    private static func appendResourceAttendees(_ resourceNames: [String], to event: inout ParsedEvent) {
        for resourceName in normalizedEventCategories(resourceNames) {
            let hasMatchingAttendee = event.attendees.contains { attendee in
                attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(resourceName) == .orderedSame
            }
            guard !hasMatchingAttendee else { continue }
            event.attendees.append(LocalEventAttendee(
                name: resourceName,
                email: "",
                status: .accepted,
                type: "resource",
                role: "non-participant",
                rsvp: false,
                isCurrentUser: false
            ))
        }
    }

    private static func applyAuxiliaryEventURLProperty(_ property: ICSProperty, to event: inout ParsedEvent) {
        if property.name == "X-APPLE-STRUCTURED-LOCATION",
           event.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let title = property.params["X-TITLE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            event.location = title
        }

        let fragments = ([property.textValue] + property.params.values)
            .map(normalizedEventTextFragment)
            .filter { !$0.isEmpty }

        for fragment in fragments {
            if event.geoCoordinate == nil,
               let coordinate = geoCoordinate(fromURIFragment: fragment) {
                event.geoCoordinate = coordinate
            }

            if let urlString = firstMeetingURLString(in: fragment) {
                if event.urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    event.urlString = urlString
                } else if event.urlString != urlString {
                    appendNoteFragment(urlString, to: &event)
                }
            }
        }
    }

    private static func geoCoordinate(from text: String) -> LocalEventGeoCoordinate? {
        let parts = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ";", maxSplits: 1)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2,
              let latitude = Double(parts[0]),
              let longitude = Double(parts[1])
        else {
            return nil
        }
        return LocalEventGeoCoordinate(latitude: latitude, longitude: longitude)
    }

    private static func geoCoordinate(fromURIFragment fragment: String) -> LocalEventGeoCoordinate? {
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("geo:") else { return nil }
        let body = String(trimmed.dropFirst("geo:".count))
        let coordinatePart = body.split(separator: ";", maxSplits: 1).first.map(String.init) ?? body
        let parts = coordinatePart
            .split(separator: ",")
            .prefix(2)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2,
              let latitude = Double(parts[0]),
              let longitude = Double(parts[1])
        else {
            return nil
        }
        return LocalEventGeoCoordinate(latitude: latitude, longitude: longitude)
    }

    private static func attachment(from property: ICSProperty) -> LocalEventAttachment? {
        let valueType = property.params["VALUE"]?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "URI"
        let encoding = property.params["ENCODING"]?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        guard valueType != "BINARY", encoding != "BASE64" else {
            return nil
        }

        let urlString = property.textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty, urlString.contains(":") else {
            return nil
        }

        return LocalEventAttachment(
            urlString: urlString,
            formatType: property.params["FMTTYPE"] ?? "",
            displayName: property.params["FILENAME"]
                ?? property.params["X-FILENAME"]
                ?? property.params["X-APPLE-FILENAME"]
                ?? property.params["CN"]
                ?? ""
        )
    }

    private static func appendNoteFragment(_ fragment: String, to event: inout ParsedEvent) {
        let normalized = normalizedEventTextFragment(fragment)
        guard !normalized.isEmpty else { return }
        if event.notes.localizedCaseInsensitiveContains(normalized) {
            return
        }

        if event.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            event.notes = normalized
        } else {
            event.notes += "\n\n\(normalized)"
        }
    }

    private static func appendLabeledNoteFragment(_ fragment: String, label: String, to event: inout ParsedEvent) {
        let normalized = normalizedEventTextFragment(fragment)
        guard !normalized.isEmpty else { return }
        if event.notes.localizedCaseInsensitiveContains(normalized) {
            return
        }
        appendNoteFragment("\(label): \(normalized)", to: &event)
    }

    private static func normalizedEventTextFragment(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMeetingURLString(in text: String) -> String? {
        MeetingLinkExtractor.firstMeetingURLString(in: text)
    }

    private static func cancelsEntireSeries(at occurrenceStart: Date, baseStartDate: Date) -> Bool {
        occurrenceStart < baseStartDate || abs(occurrenceStart.timeIntervalSince(baseStartDate)) < 1
    }

    private static func recurrenceEndDateBefore(_ occurrenceStart: Date, calendar: Calendar) -> Date {
        let occurrenceDayStart = calendar.startOfDay(for: occurrenceStart)
        return calendar.date(byAdding: .day, value: -1, to: occurrenceDayStart)
            ?? occurrenceStart.addingTimeInterval(-24 * 3600)
    }

    private static func earliestRecurrenceEndDate(_ current: Date?, candidates: [Date]) -> Date? {
        ([current].compactMap { $0 } + candidates).min()
    }

    private static func recurrenceEndDateIncludes(_ recurrenceEndDate: Date?, occurrenceStart: Date, calendar: Calendar) -> Bool {
        guard let recurrenceEndDate else { return true }
        let endOfSelectedDay = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: recurrenceEndDate)
        ) ?? recurrenceEndDate
        return endOfSelectedDay > occurrenceStart
    }

    private static func recurrencePatternForFutureRange(
        baseEvent: ParsedEvent,
        futureRangeEvent: ParsedEvent
    ) -> (weekdays: [Int], weekStart: Int?, setPositions: [Int], ordinal: Int?, ordinalWeekday: Int?, monthDay: Int?, months: [Int]) {
        guard let recurrenceID = futureRangeEvent.recurrenceID,
              let futureStartDate = futureRangeEvent.startDate
        else {
            return (
                baseEvent.recurrenceWeekdays,
                baseEvent.recurrenceWeekStart,
                baseEvent.recurrenceSetPositions,
                baseEvent.recurrenceOrdinal,
                baseEvent.recurrenceOrdinalWeekday,
                baseEvent.recurrenceMonthDay,
                baseEvent.recurrenceMonths
            )
        }

        switch baseEvent.recurrenceFrequency {
        case .weekly:
            let baseCalendar = recurrenceCalendar(for: baseEvent)
            let futureCalendar = recurrenceCalendar(for: futureRangeEvent)
            let baseWeekdays = baseEvent.recurrenceWeekdays.isEmpty
                ? [baseCalendar.component(.weekday, from: baseEvent.startDate ?? recurrenceID)]
                : baseEvent.recurrenceWeekdays
            let dayDelta = futureCalendar.dateComponents(
                [.day],
                from: futureCalendar.startOfDay(for: recurrenceID),
                to: futureCalendar.startOfDay(for: futureStartDate)
            ).day ?? 0
            return (
                baseWeekdays.map { shiftedWeekday($0, by: dayDelta) }.normalizedWeekdays,
                baseEvent.recurrenceWeekStart,
                baseEvent.recurrenceSetPositions,
                nil,
                nil,
                nil,
                []
            )
        case .monthly:
            let calendar = recurrenceCalendar(for: futureRangeEvent)
            if baseEvent.recurrenceOrdinal != nil,
               baseEvent.recurrenceOrdinalWeekday != nil {
                let ordinal = monthlyOrdinal(for: futureStartDate, preferNegativeOrdinal: (baseEvent.recurrenceOrdinal ?? 0) < 0, calendar: calendar)
                return ([], nil, [], ordinal, calendar.component(.weekday, from: futureStartDate), nil, baseEvent.recurrenceMonths)
            }
            if baseEvent.recurrenceMonthDay != nil {
                return ([], nil, [], nil, nil, monthlyDay(for: futureStartDate, preservingSignOf: baseEvent.recurrenceMonthDay, calendar: calendar), baseEvent.recurrenceMonths)
            }
            return ([], nil, [], nil, nil, nil, baseEvent.recurrenceMonths)
        case .yearly:
            let calendar = recurrenceCalendar(for: futureRangeEvent)
            let months = shiftedYearlyMonths(
                baseEvent.recurrenceMonths,
                recurrenceID: recurrenceID,
                futureStartDate: futureStartDate,
                calendar: calendar
            )
            if baseEvent.recurrenceOrdinal != nil,
               baseEvent.recurrenceOrdinalWeekday != nil {
                let ordinal = monthlyOrdinal(for: futureStartDate, preferNegativeOrdinal: (baseEvent.recurrenceOrdinal ?? 0) < 0, calendar: calendar)
                return ([], nil, [], ordinal, calendar.component(.weekday, from: futureStartDate), nil, months)
            }
            if baseEvent.recurrenceMonthDay != nil {
                return ([], nil, [], nil, nil, monthlyDay(for: futureStartDate, preservingSignOf: baseEvent.recurrenceMonthDay, calendar: calendar), months)
            }
            return ([], nil, [], nil, nil, nil, months)
        case .none, .daily:
            return ([], nil, [], nil, nil, nil, [])
        }
    }

    private static func shiftedWeekday(_ weekday: Int, by dayDelta: Int) -> Int {
        let zeroBased = (weekday - 1 + dayDelta) % 7
        return (zeroBased + 7) % 7 + 1
    }

    private static func shiftedYearlyMonths(
        _ months: [Int],
        recurrenceID: Date,
        futureStartDate: Date,
        calendar: Calendar
    ) -> [Int] {
        let normalizedMonths = normalizedRecurrenceMonths(months, frequency: .yearly)
        guard !normalizedMonths.isEmpty else { return [] }

        let sourceMonth = calendar.component(.month, from: recurrenceID)
        let futureMonth = calendar.component(.month, from: futureStartDate)
        let monthDelta = futureMonth - sourceMonth
        guard monthDelta != 0 else { return normalizedMonths }

        return Array(Set(normalizedMonths.map { month in
            let zeroBased = (month - 1 + monthDelta) % 12
            return (zeroBased + 12) % 12 + 1
        })).sorted()
    }

    private static func monthlyOrdinal(for date: Date, preferNegativeOrdinal: Bool, calendar: Calendar) -> Int {
        let day = calendar.component(.day, from: date)
        guard preferNegativeOrdinal,
              let range = calendar.range(of: .day, in: .month, for: date)
        else {
            return ((day - 1) / 7) + 1
        }

        let daysFromEnd = (range.count - day) / 7
        return -(daysFromEnd + 1)
    }

    private static func monthlyDay(for date: Date, preservingSignOf sourceMonthDay: Int?, calendar: Calendar) -> Int {
        let day = calendar.component(.day, from: date)
        if let sourceMonthDay, sourceMonthDay < 0,
           let days = calendar.range(of: .day, in: .month, for: date) {
            return day - (days.count + 1)
        }
        return day
    }

    private static func property(from line: String) -> ICSProperty? {
        guard let separator = propertyValueSeparator(in: line) else { return nil }
        let left = String(line[..<separator])
        let value = String(line[line.index(after: separator)...])
        let tokens = propertyTokens(from: left)
        guard let name = tokens.first?.uppercased() else { return nil }

        var params: [String: String] = [:]
        for token in tokens.dropFirst() {
            let pieces = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            params[pieces[0].uppercased()] = normalizedParameterValue(pieces[1])
        }

        return ICSProperty(name: name, params: params, value: value)
    }

    private static func property(named name: String, in lines: [String]) -> ICSProperty? {
        let normalizedName = name.uppercased()
        return lines.compactMap(property(from:)).first { $0.name == normalizedName }
    }

    private static func propertyValue(named name: String, in lines: [String]) -> String? {
        property(named: name, in: lines)?.textValue
    }

    private static func propertyValueSeparator(in line: String) -> String.Index? {
        var isQuoted = false
        var isEscaped = false

        for index in line.indices {
            let character = line[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                isQuoted.toggle()
            } else if character == ":", !isQuoted {
                return index
            }
        }

        return nil
    }

    private static func propertyTokens(from leftSide: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isQuoted = false
        var isEscaped = false

        for character in leftSide {
            if isEscaped {
                current.append(character)
                isEscaped = false
            } else if character == "\\" {
                current.append(character)
                isEscaped = true
            } else if character == "\"" {
                isQuoted.toggle()
                current.append(character)
            } else if character == ";", !isQuoted {
                tokens.append(current)
                current.removeAll()
            } else {
                current.append(character)
            }
        }

        tokens.append(current)
        return tokens
    }

    private static func normalizedParameterValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let unquoted: String
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            unquoted = String(trimmed.dropFirst().dropLast())
        } else {
            unquoted = trimmed
        }

        return unescapeText(caretDecodedParameterValue(unquoted))
    }

    private static func caretDecodedParameterValue(_ value: String) -> String {
        var result = ""
        var index = value.startIndex

        while index < value.endIndex {
            let character = value[index]
            guard character == "^" else {
                result.append(character)
                index = value.index(after: index)
                continue
            }

            let nextIndex = value.index(after: index)
            guard nextIndex < value.endIndex else {
                result.append(character)
                index = nextIndex
                continue
            }

            switch value[nextIndex] {
            case "n", "N":
                result.append("\n")
            case "'":
                result.append("\"")
            case "^":
                result.append("^")
            default:
                result.append(character)
                result.append(value[nextIndex])
            }
            index = value.index(after: nextIndex)
        }

        return result
    }

    private static func recurrenceComponents(from value: String) -> [String: String] {
        value.split(separator: ";").reduce(into: [String: String]()) { result, part in
            let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { return }
            result[pieces[0].uppercased()] = pieces[1].uppercased()
        }
    }

    private static func applyRecurrenceRule(
        _ value: String,
        to event: inout ParsedEvent,
        timeZoneDefinitions: [String: ICSTimeZoneDefinition]
    ) {
        let components = recurrenceComponents(from: value)

        event.recurrenceComponents = components
        if let recurrenceFrequency = LocalRecurrenceFrequency(icsName: components["FREQ"] ?? "") {
            event.recurrenceFrequency = recurrenceFrequency
        } else {
            event.recurrenceFrequency = .none
            event.hasUnsupportedRecurrencePattern = true
        }
        event.recurrenceInterval = max(1, Int(components["INTERVAL"] ?? "") ?? 1)
        event.recurrenceCount = components["COUNT"].flatMap(Int.init)
        event.recurrenceSetPositions = recurrenceList(components["BYSETPOS"] ?? "")
        event.recurrenceMonths = recurrenceList(components["BYMONTH"] ?? "")
        event.recurrenceWeekdays = components["BYDAY"]?
            .split(separator: ",")
            .compactMap { weekdayNumber(forICSName: String($0)) }
            .normalizedWeekdays ?? []
        if event.recurrenceFrequency == .weekly {
            if let weekStart = components["WKST"] {
                event.recurrenceWeekStart = weekdayNumber(forICSName: weekStart)
            } else {
                event.recurrenceWeekStart = 2
            }
        } else {
            event.recurrenceWeekStart = nil
        }
        let ordinalWeekday = recurrenceOrdinalWeekday(from: components)
        event.recurrenceOrdinal = ordinalWeekday.ordinal
        event.recurrenceOrdinalWeekday = ordinalWeekday.weekday
        event.recurrenceMonthDay = recurrenceList(components["BYMONTHDAY"] ?? "")
            .filter { $0 != 0 && (-31...31).contains($0) }
            .onlyElement
        if let until = components["UNTIL"] {
            event.recurrenceEndDate = parseDateValue(
                until,
                isAllDay: false,
                timeZoneIdentifier: event.timeZoneIdentifier,
                timeZoneDefinitions: timeZoneDefinitions
            ).date
        }
    }

    private static func normalizeSupportedRecurrencePattern(_ event: inout ParsedEvent, startDate: Date) {
        guard event.recurrenceFrequency != .none else { return }

        let components = event.recurrenceComponents
        let calendar = recurrenceCalendar(for: event)
        guard Set(components.keys).isSubset(of: supportedRecurrenceComponentKeys) else {
            disableRecurrence(for: &event)
            return
        }
        guard timeRecurrenceFiltersMatchStart(
            components,
            startDate: startDate,
            calendar: calendar,
            isAllDay: event.isAllDay
        ) else {
            disableRecurrence(for: &event)
            return
        }

        let unsupportedKeys = [
            "BYWEEKNO"
        ]
        if unsupportedKeys.contains(where: { components[$0] != nil }) {
            disableRecurrence(for: &event)
            return
        }

        let byDayValues = components["BYDAY"]?
            .split(separator: ",")
            .map { String($0).uppercased() } ?? []
        let hasOrdinalWeekday = byDayValues.contains { token in
            let suffix = String(token.suffix(2))
            guard weekdayNumber(forICSName: suffix) != nil else { return true }
            return token.dropLast(2).isEmpty == false
        }

        switch event.recurrenceFrequency {
        case .none:
            break
        case .weekly:
            if components["BYYEARDAY"] != nil {
                disableRecurrence(for: &event)
                return
            }
            if components["BYMONTHDAY"] != nil {
                disableRecurrence(for: &event)
                return
            }
            if components["WKST"] != nil, event.recurrenceWeekStart == nil {
                disableRecurrence(for: &event)
                return
            }
            event.recurrenceSetPositions = normalizedRecurrenceSetPositions(
                event.recurrenceSetPositions,
                frequency: event.recurrenceFrequency
            )
            if components["BYSETPOS"] != nil,
               event.recurrenceSetPositions.isEmpty {
                disableRecurrence(for: &event)
                return
            }
            if hasOrdinalWeekday {
                disableRecurrence(for: &event)
                return
            }
        case .monthly:
            if components["BYYEARDAY"] != nil {
                disableRecurrence(for: &event)
                return
            }
            event.recurrenceMonths = normalizedRecurrenceMonths(
                event.recurrenceMonths,
                frequency: event.recurrenceFrequency
            )
            if components["BYMONTH"] != nil {
                guard !event.recurrenceMonths.isEmpty,
                      event.recurrenceMonths.contains(calendar.component(.month, from: startDate))
                else {
                    disableRecurrence(for: &event)
                    return
                }
            }
            let normalizedOrdinal = normalizedOrdinalRecurrence(
                event.recurrenceOrdinal,
                weekday: event.recurrenceOrdinalWeekday,
                frequency: event.recurrenceFrequency
            )
            if (!byDayValues.isEmpty || components["BYSETPOS"] != nil),
               normalizedOrdinal.ordinal == nil {
                disableRecurrence(for: &event)
                return
            }
            if normalizedOrdinal.ordinal != nil {
                event.recurrenceMonthDay = nil
            }
        case .daily:
            if components["BYYEARDAY"] != nil {
                disableRecurrence(for: &event)
                return
            }
            if components["BYSETPOS"] != nil {
                disableRecurrence(for: &event)
                return
            }
            if components["BYMONTHDAY"] != nil {
                guard canRepresentDailyByMonthDayAsMonthly(
                    components,
                    byDayValues: byDayValues,
                    event: event,
                    startDate: startDate,
                    calendar: calendar
                ) else {
                    disableRecurrence(for: &event)
                    return
                }
                event.recurrenceFrequency = .monthly
                event.recurrenceInterval = 1
                event.recurrenceWeekdays = []
                event.recurrenceWeekStart = nil
                event.recurrenceSetPositions = []
                event.recurrenceMonths = normalizedRecurrenceMonths(
                    event.recurrenceMonths,
                    frequency: event.recurrenceFrequency
                )
            }
            if !byDayValues.isEmpty,
               canRepresentDailyByDayAsWeekly(components, byDayValues: byDayValues, interval: event.recurrenceInterval) {
                event.recurrenceFrequency = .weekly
                event.recurrenceInterval = 1
            } else if !byDayValues.isEmpty {
                disableRecurrence(for: &event)
                return
            }
        case .yearly:
            event.recurrenceMonths = normalizedRecurrenceMonths(
                event.recurrenceMonths,
                frequency: event.recurrenceFrequency
            )
            if let byYearDay = components["BYYEARDAY"] {
                guard byDayValues.isEmpty,
                      components["BYSETPOS"] == nil,
                      let pattern = byYearDayPattern(byYearDay, matches: startDate, calendar: calendar),
                      components["BYMONTH"].map({ recurrenceList($0).contains(pattern.month) }) ?? true
                else {
                    disableRecurrence(for: &event)
                    return
                }
                event.recurrenceMonths = [pattern.month]
                event.recurrenceMonthDay = pattern.monthDay
                event.recurrenceOrdinal = nil
                event.recurrenceOrdinalWeekday = nil
            }
            if components["BYMONTH"] != nil {
                guard !event.recurrenceMonths.isEmpty,
                      event.recurrenceMonths.contains(calendar.component(.month, from: startDate))
                else {
                    disableRecurrence(for: &event)
                    return
                }
            }
            if components["BYSETPOS"] != nil,
               event.recurrenceMonths.count != 1 {
                disableRecurrence(for: &event)
                return
            }
            if !byDayValues.isEmpty {
                let normalizedOrdinal = normalizedOrdinalRecurrence(
                    event.recurrenceOrdinal,
                    weekday: event.recurrenceOrdinalWeekday,
                    frequency: event.recurrenceFrequency
                )
                if normalizedOrdinal.ordinal == nil || components["BYMONTHDAY"] != nil {
                    disableRecurrence(for: &event)
                    return
                }
            } else if components["BYSETPOS"] != nil {
                disableRecurrence(for: &event)
                return
            }
        }

        if let byMonthDay = components["BYMONTHDAY"],
           !byMonthDayPattern(byMonthDay, matches: startDate, calendar: calendar) {
            disableRecurrence(for: &event)
            return
        }

        if components["BYMONTH"] != nil {
            switch event.recurrenceFrequency {
            case .monthly, .yearly:
                break
            case .none, .daily, .weekly:
                disableRecurrence(for: &event)
            }
        }
    }

    private static let supportedRecurrenceComponentKeys: Set<String> = [
        "FREQ",
        "UNTIL",
        "COUNT",
        "INTERVAL",
        "BYSECOND",
        "BYMINUTE",
        "BYHOUR",
        "BYDAY",
        "BYMONTHDAY",
        "BYYEARDAY",
        "BYWEEKNO",
        "BYMONTH",
        "BYSETPOS",
        "WKST"
    ]

    private static func disableRecurrence(for event: inout ParsedEvent) {
        event.hasUnsupportedRecurrencePattern = true
        event.recurrenceFrequency = .none
        event.recurrenceInterval = 1
        event.recurrenceWeekdays = []
        event.recurrenceWeekStart = nil
        event.recurrenceSetPositions = []
        event.recurrenceOrdinal = nil
        event.recurrenceOrdinalWeekday = nil
        event.recurrenceMonthDay = nil
        event.recurrenceMonths = []
        event.recurrenceEndDate = nil
        event.recurrenceCount = nil
        if event.additionalOccurrenceStartDates.isEmpty {
            event.excludedOccurrenceStartDates = []
        } else {
            event.excludedOccurrenceStartDates = event.excludedOccurrenceStartDates
                .filter { event.additionalOccurrenceStartDates.containsOccurrenceStart($0) }
        }
    }

    private static func canRepresentDailyByDayAsWeekly(
        _ components: [String: String],
        byDayValues: [String],
        interval: Int
    ) -> Bool {
        guard interval == 1 else { return false }
        let supportedKeys: Set<String> = [
            "FREQ",
            "INTERVAL",
            "COUNT",
            "UNTIL",
            "BYDAY",
            "WKST",
            "BYHOUR",
            "BYMINUTE",
            "BYSECOND"
        ]
        guard Set(components.keys).isSubset(of: supportedKeys) else { return false }
        return byDayValues.allSatisfy { token in
            token.count == 2 && weekdayNumber(forICSName: token) != nil
        }
    }

    private static func canRepresentDailyByMonthDayAsMonthly(
        _ components: [String: String],
        byDayValues: [String],
        event: ParsedEvent,
        startDate: Date,
        calendar: Calendar
    ) -> Bool {
        guard event.recurrenceInterval == 1,
              byDayValues.isEmpty,
              event.recurrenceMonthDay != nil
        else {
            return false
        }
        let supportedKeys: Set<String> = [
            "FREQ",
            "INTERVAL",
            "COUNT",
            "UNTIL",
            "BYMONTH",
            "BYMONTHDAY",
            "BYHOUR",
            "BYMINUTE",
            "BYSECOND"
        ]
        guard Set(components.keys).isSubset(of: supportedKeys) else { return false }

        if components["BYMONTH"] != nil {
            let months = normalizedRecurrenceMonths(event.recurrenceMonths, frequency: .monthly)
            guard !months.isEmpty,
                  months.contains(calendar.component(.month, from: startDate))
            else {
                return false
            }
        }

        return true
    }

    private static func timeRecurrenceFiltersMatchStart(
        _ components: [String: String],
        startDate: Date,
        calendar: Calendar,
        isAllDay: Bool
    ) -> Bool {
        let filters: [(key: String, range: ClosedRange<Int>, startValue: Int)] = [
            ("BYHOUR", 0...23, calendar.component(.hour, from: startDate)),
            ("BYMINUTE", 0...59, calendar.component(.minute, from: startDate)),
            ("BYSECOND", 0...60, calendar.component(.second, from: startDate))
        ]
        guard filters.contains(where: { components[$0.key] != nil }) else {
            return true
        }
        guard !isAllDay else { return false }

        for filter in filters {
            guard let rawValue = components[filter.key] else { continue }
            let values = recurrenceList(rawValue)
            guard values.count == 1,
                  let value = values.first,
                  filter.range.contains(value),
                  value == filter.startValue
            else {
                return false
            }
        }
        return true
    }

    private static func recurrenceOrdinalWeekday(from components: [String: String]) -> (ordinal: Int?, weekday: Int?) {
        let byDayTokens = components["BYDAY"]?
            .split(separator: ",")
            .map { String($0).uppercased() } ?? []
        guard byDayTokens.count == 1 else { return (nil, nil) }

        let token = byDayTokens[0]
        let weekdayToken = String(token.suffix(2))
        guard let weekday = weekdayNumber(forICSName: weekdayToken) else { return (nil, nil) }

        let ordinalPrefix = String(token.dropLast(2))
        if !ordinalPrefix.isEmpty, let ordinal = Int(ordinalPrefix) {
            return (ordinal, weekday)
        }

        if let bySetPosition = components["BYSETPOS"], let ordinal = Int(bySetPosition) {
            return (ordinal, weekday)
        }

        return (nil, nil)
    }

    private static func recurrenceList(_ value: String) -> [Int] {
        value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func byMonthDayPattern(_ value: String, matches startDate: Date, calendar: Calendar) -> Bool {
        let monthDays = recurrenceList(value)
        guard monthDays.count == 1,
              let monthDay = monthDays.first,
              monthDay != 0,
              (-31...31).contains(monthDay),
              let monthStart = calendar.dateInterval(of: .month, for: startDate)?.start,
              let occurrence = monthDayOccurrence(monthStart: monthStart, day: monthDay, matching: startDate, calendar: calendar)
        else {
            return false
        }

        return abs(occurrence.timeIntervalSince(startDate)) < 1
    }

    private static func byYearDayPattern(_ value: String, matches startDate: Date, calendar: Calendar) -> (month: Int, monthDay: Int)? {
        let yearDays = recurrenceList(value)
        guard yearDays.count == 1,
              let yearDay = yearDays.first,
              yearDay != 0,
              (-366...366).contains(yearDay),
              let yearStart = calendar.dateInterval(of: .year, for: startDate)?.start,
              let occurrence = yearDayOccurrence(
                yearStart: yearStart,
                yearDay: yearDay,
                matching: startDate,
                calendar: calendar
              ),
              abs(occurrence.timeIntervalSince(startDate)) < 1
        else {
            return nil
        }

        let month = calendar.component(.month, from: startDate)
        let monthDay = calendar.component(.day, from: startDate)
        guard fixedYearDayPattern(yearDay, month: month, monthDay: monthDay, calendar: calendar) else {
            return nil
        }
        return (month, monthDay)
    }

    private static func fixedYearDayPattern(_ yearDay: Int, month: Int, monthDay: Int, calendar: Calendar) -> Bool {
        [2024, 2025].allSatisfy { year in
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            components.year = year
            components.month = 1
            components.day = 1
            guard let yearStart = calendar.date(from: components),
                  let date = yearDayOccurrence(
                    yearStart: yearStart,
                    yearDay: yearDay,
                    matching: yearStart,
                    calendar: calendar
                  )
            else {
                return false
            }
            return calendar.component(.month, from: date) == month
                && calendar.component(.day, from: date) == monthDay
        }
    }

    private static func yearDayOccurrence(yearStart: Date, yearDay: Int, matching sourceDate: Date, calendar: Calendar) -> Date? {
        guard let year = calendar.dateInterval(of: .year, for: yearStart) else { return nil }

        let dayDate: Date?
        if yearDay > 0 {
            dayDate = calendar.date(byAdding: .day, value: yearDay - 1, to: year.start)
        } else {
            dayDate = calendar.date(byAdding: .day, value: yearDay, to: year.end)
        }

        guard let dayDate,
              dayDate >= year.start,
              dayDate < year.end
        else {
            return nil
        }

        return date(on: dayDate, matching: sourceDate, calendar: calendar)
    }

    private static func recurrenceEndDateFromCount(for event: ParsedEvent) -> Date? {
        guard let count = event.recurrenceCount,
              count > 0,
              event.recurrenceFrequency != .none,
              let startDate = event.startDate
        else {
            return nil
        }

        if count == 1 {
            return startDate
        }

        let calendar = recurrenceCalendar(for: event)
        switch event.recurrenceFrequency {
        case .none:
            return nil
        case .daily:
            return calendar.date(byAdding: .day, value: event.recurrenceInterval * (count - 1), to: startDate)
        case .weekly:
            return weeklyRecurrenceEndDateFromCount(for: event, count: count, startDate: startDate, calendar: calendar)
        case .monthly:
            return monthlyRecurrenceEndDateFromCount(for: event, count: count, startDate: startDate, calendar: calendar)
        case .yearly:
            return yearlyRecurrenceEndDateFromCount(for: event, count: count, startDate: startDate, calendar: calendar)
        }
    }

    private static func weeklyRecurrenceEndDateFromCount(for event: ParsedEvent, count: Int, startDate: Date, calendar: Calendar) -> Date? {
        guard let anchorWeek = calendar.dateInterval(of: .weekOfYear, for: startDate) else { return nil }

        let weekdays = event.recurrenceWeekdays.isEmpty
            ? [calendar.component(.weekday, from: startDate)]
            : event.recurrenceWeekdays
        let interval = max(1, event.recurrenceInterval)
        var weekStart = anchorWeek.start
        var emittedCount = 0
        var iterationCount = 0

        while iterationCount < 10_000 {
            for occurrenceStart in weeklyOccurrenceStarts(
                weekStart: weekStart,
                weekdays: weekdays,
                setPositions: event.recurrenceSetPositions,
                matching: startDate,
                calendar: calendar
            ) where occurrenceStart >= startDate {
                emittedCount += 1
                if emittedCount == count {
                    return occurrenceStart
                }
            }

            guard let nextWeekStart = calendar.date(byAdding: .weekOfYear, value: interval, to: weekStart) else {
                return nil
            }
            weekStart = nextWeekStart
            iterationCount += 1
        }

        return nil
    }

    private static func monthlyRecurrenceEndDateFromCount(for event: ParsedEvent, count: Int, startDate: Date, calendar: Calendar) -> Date? {
        guard let anchorMonth = calendar.dateInterval(of: .month, for: startDate)?.start else { return nil }

        let sourceDay = event.recurrenceMonthDay ?? calendar.component(.day, from: startDate)
        let interval = max(1, event.recurrenceInterval)
        var monthStart = anchorMonth
        var emittedCount = 0
        var iterationCount = 0

        while iterationCount < 10_000 {
            guard monthAllowed(monthStart, months: event.recurrenceMonths, calendar: calendar) else {
                guard let nextMonthStart = calendar.date(byAdding: .month, value: interval, to: monthStart) else {
                    return nil
                }
                monthStart = nextMonthStart
                iterationCount += 1
                continue
            }

            let occurrenceStart: Date?
            if let ordinal = event.recurrenceOrdinal,
               let weekday = event.recurrenceOrdinalWeekday {
                occurrenceStart = ordinalWeekdayOccurrence(
                    monthStart: monthStart,
                    ordinal: ordinal,
                    weekday: weekday,
                    matching: startDate,
                    calendar: calendar
                )
            } else {
                occurrenceStart = monthDayOccurrence(
                    monthStart: monthStart,
                    day: sourceDay,
                    matching: startDate,
                    calendar: calendar
                )
            }

            if let occurrenceStart, occurrenceStart >= startDate {
                emittedCount += 1
                if emittedCount == count {
                    return occurrenceStart
                }
            }

            guard let nextMonthStart = calendar.date(byAdding: .month, value: interval, to: monthStart) else {
                return nil
            }
            monthStart = nextMonthStart
            iterationCount += 1
        }

        return nil
    }

    private static func yearlyRecurrenceEndDateFromCount(for event: ParsedEvent, count: Int, startDate: Date, calendar: Calendar) -> Date? {
        guard let anchorYear = calendar.dateInterval(of: .year, for: startDate)?.start else { return nil }

        let sourceComponents = calendar.dateComponents([.month, .day], from: startDate)
        guard let sourceMonth = sourceComponents.month, let sourceDay = sourceComponents.day else {
            return nil
        }
        let months = recurrenceMonths(for: event, defaultMonth: sourceMonth)
        let recurrenceMonthDay = event.recurrenceMonthDay ?? sourceDay

        let interval = max(1, event.recurrenceInterval)
        var yearStart = anchorYear
        var emittedCount = 0
        var iterationCount = 0

        while iterationCount < 10_000 {
            for month in months {
                let occurrenceStart: Date?
                if let ordinal = event.recurrenceOrdinal,
                   let weekday = event.recurrenceOrdinalWeekday,
                   let monthStart = calendar.date(byAdding: .month, value: month - 1, to: yearStart) {
                    occurrenceStart = ordinalWeekdayOccurrence(
                        monthStart: monthStart,
                        ordinal: ordinal,
                        weekday: weekday,
                        matching: startDate,
                        calendar: calendar
                    )
                } else {
                    occurrenceStart = yearlyDateOccurrence(
                        yearStart: yearStart,
                        month: month,
                        day: recurrenceMonthDay,
                        matching: startDate,
                        calendar: calendar
                    )
                }

                guard let occurrenceStart, occurrenceStart >= startDate else { continue }
                emittedCount += 1
                if emittedCount == count {
                    return occurrenceStart
                }
            }

            guard let nextYearStart = calendar.date(byAdding: .year, value: interval, to: yearStart) else {
                return nil
            }
            yearStart = nextYearStart
            iterationCount += 1
        }

        return nil
    }

    private static func parseDate(
        _ property: ICSProperty,
        fallbackTimeZoneIdentifier: String?,
        timeZoneDefinitions: [String: ICSTimeZoneDefinition]
    ) -> (date: Date?, isAllDay: Bool, timeZoneIdentifier: String) {
        parseDateValue(
            property.value,
            isAllDay: property.params["VALUE"]?.uppercased() == "DATE",
            timeZoneIdentifier: property.params["TZID"] ?? fallbackTimeZoneIdentifier,
            timeZoneDefinitions: timeZoneDefinitions
        )
    }

    private static func recurrenceDateValues(
        _ property: ICSProperty,
        fallbackTimeZoneIdentifier: String?,
        timeZoneDefinitions: [String: ICSTimeZoneDefinition]
    ) -> [Date] {
        recurrenceDates(
            property,
            fallbackTimeZoneIdentifier: fallbackTimeZoneIdentifier,
            timeZoneDefinitions: timeZoneDefinitions
        ).dates
    }

    private static func recurrenceDates(
        _ property: ICSProperty,
        fallbackTimeZoneIdentifier: String?,
        timeZoneDefinitions: [String: ICSTimeZoneDefinition]
    ) -> (dates: [Date], periods: [ParsedRecurrencePeriod]) {
        let valueType = property.params["VALUE"]?.uppercased()
        if valueType == "PERIOD" {
            let periods = property.value.split(separator: ",").compactMap { value in
                recurrencePeriod(
                    from: String(value),
                    property: property,
                    fallbackTimeZoneIdentifier: fallbackTimeZoneIdentifier,
                    timeZoneDefinitions: timeZoneDefinitions
                )
            }
            return (periods.map(\.startDate), periods)
        }

        let isAllDay = valueType == "DATE"
        let dates = property.value.split(separator: ",").compactMap { value in
            let startValue = String(value).split(separator: "/", maxSplits: 1).first.map(String.init) ?? String(value)
            return parseDateValue(
                startValue,
                isAllDay: isAllDay,
                timeZoneIdentifier: property.params["TZID"] ?? fallbackTimeZoneIdentifier,
                timeZoneDefinitions: timeZoneDefinitions
            ).date
        }
        return (dates, [])
    }

    private static func recurrencePeriod(
        from value: String,
        property: ICSProperty,
        fallbackTimeZoneIdentifier: String?,
        timeZoneDefinitions: [String: ICSTimeZoneDefinition]
    ) -> ParsedRecurrencePeriod? {
        let pieces = value.split(separator: "/", maxSplits: 1).map(String.init)
        guard pieces.count == 2 else { return nil }

        let timeZoneIdentifier = property.params["TZID"] ?? fallbackTimeZoneIdentifier
        guard let startDate = parseDateValue(
            pieces[0],
            isAllDay: false,
            timeZoneIdentifier: timeZoneIdentifier,
            timeZoneDefinitions: timeZoneDefinitions
        ).date
        else {
            return nil
        }

        let endDate: Date?
        let endValue = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
        if endValue.uppercased().hasPrefix("P"),
           let duration = parseDurationSeconds(endValue) {
            endDate = startDate.addingTimeInterval(duration)
        } else {
            endDate = parseDateValue(
                endValue,
                isAllDay: false,
                timeZoneIdentifier: timeZoneIdentifier,
                timeZoneDefinitions: timeZoneDefinitions
            ).date
        }

        guard let endDate, endDate > startDate else { return nil }
        return ParsedRecurrencePeriod(startDate: startDate, endDate: endDate)
    }

    private static func parseDateValue(
        _ value: String,
        isAllDay: Bool,
        timeZoneIdentifier: String?,
        timeZoneDefinitions: [String: ICSTimeZoneDefinition] = [:]
    ) -> (date: Date?, isAllDay: Bool, timeZoneIdentifier: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedIdentifier = timeZoneIdentifier.flatMap(normalizedTimeZoneIdentifier)

        if isAllDay || value.count == 8 {
            let identifier = normalizedIdentifier
                ?? timeZoneIdentifier.flatMap { timeZoneDefinition(for: $0, in: timeZoneDefinitions)?.identifier }
                ?? TimeZone.current.identifier
            let timeZone = resolvedTimeZone(for: identifier).timeZone
            return (dateFormatter(timeZone: timeZone).date(from: value), true, identifier)
        }

        if value.hasSuffix("Z"), let date = dateTimeFormatter.date(from: value) {
            return (date, false, "UTC")
        }

        if let normalizedIdentifier,
           let timeZone = TimeZone(identifier: normalizedIdentifier),
           let date = zonedDateTimeFormatter(timeZone: timeZone).date(from: value) {
            return (date, false, normalizedIdentifier)
        }

        if let timeZoneIdentifier,
           let definition = timeZoneDefinition(for: timeZoneIdentifier, in: timeZoneDefinitions),
           let parsed = definition.date(from: value) {
            return (parsed.date, false, parsed.identifier)
        }

        return (floatingDateTimeFormatter.date(from: value), false, TimeZone.current.identifier)
    }

    private static func timeZoneDefinition(
        for rawIdentifier: String,
        in definitions: [String: ICSTimeZoneDefinition]
    ) -> ICSTimeZoneDefinition? {
        for key in timeZoneDefinitionKeys(for: rawIdentifier) {
            if let definition = definitions[key] {
                return definition
            }
        }
        return nil
    }

    private static func resolvedTimeZone(for rawIdentifier: String?) -> (identifier: String, timeZone: TimeZone) {
        let fallback = TimeZone.current
        guard let rawIdentifier,
              let identifier = normalizedTimeZoneIdentifier(rawIdentifier),
              let timeZone = TimeZone(identifier: identifier)
        else {
            return (fallback.identifier, fallback)
        }

        return (identifier, timeZone)
    }

    private static func normalizedTimeZoneIdentifier(_ rawIdentifier: String) -> String? {
        let trimmed = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if TimeZone(identifier: trimmed) != nil {
            return trimmed
        }

        let compact = trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: " ", with: "_")

        if TimeZone(identifier: compact) != nil {
            return compact
        }

        if let identifier = knownTimeZoneIdentifier(matching: compact) {
            return identifier
        }

        for prefix in ianaTimeZonePrefixes {
            if let range = compact.range(of: prefix, options: .caseInsensitive) {
                let candidate = String(compact[range.lowerBound...])
                if let identifier = knownTimeZoneIdentifier(matching: candidate) {
                    return identifier
                }
            }
        }

        let windowsKey = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
        if let mapped = windowsTimeZoneMap[windowsKey],
           TimeZone(identifier: mapped) != nil {
            return mapped
        }

        if let offset = fixedOffsetTimeZoneIdentifier(from: trimmed),
           TimeZone(identifier: offset) != nil {
            return offset
        }

        return nil
    }

    private static func knownTimeZoneIdentifier(matching rawIdentifier: String) -> String? {
        TimeZone.knownTimeZoneIdentifiers.first {
            $0.caseInsensitiveCompare(rawIdentifier) == .orderedSame
        }
    }

    private static func fixedOffsetTimeZoneIdentifier(from rawIdentifier: String) -> String? {
        let uppercased = rawIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")

        let prefixes = ["UTC", "GMT"]
        guard let prefix = prefixes.first(where: { uppercased.hasPrefix($0) }) else { return nil }
        let offsetText = String(uppercased.dropFirst(prefix.count))
        if offsetText.isEmpty || offsetText == "Z" { return "UTC" }

        guard let sign = offsetText.first, sign == "+" || sign == "-" else { return nil }
        let unsigned = String(offsetText.dropFirst())
        let parts = unsigned.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let hourText: String
        let minuteText: String

        if parts.count == 1 {
            let value = parts[0]
            if value.count <= 2 {
                hourText = value
                minuteText = "00"
            } else if value.count == 4 {
                hourText = String(value.prefix(2))
                minuteText = String(value.suffix(2))
            } else {
                return nil
            }
        } else if parts.count == 2 {
            hourText = parts[0]
            minuteText = parts[1]
        } else {
            return nil
        }

        guard let hours = Int(hourText),
              let minutes = Int(minuteText),
              (0...23).contains(hours),
              (0...59).contains(minutes)
        else {
            return nil
        }

        let direction = sign == "-" ? -1 : 1
        guard let timeZone = TimeZone(secondsFromGMT: direction * ((hours * 3600) + (minutes * 60))) else {
            return nil
        }
        return timeZone.identifier
    }

    private static func secondsFromUTCOffset(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sign = trimmed.first, sign == "+" || sign == "-" else { return nil }
        let digits = trimmed.dropFirst().filter(\.isNumber)
        guard digits.count == 2 || digits.count == 4 || digits.count == 6 else { return nil }

        let hourText = String(digits.prefix(2))
        let minuteText = digits.count >= 4 ? String(digits.dropFirst(2).prefix(2)) : "00"
        let secondText = digits.count == 6 ? String(digits.suffix(2)) : "00"

        guard let hours = Int(hourText),
              let minutes = Int(minuteText),
              let seconds = Int(secondText),
              (0...23).contains(hours),
              (0...59).contains(minutes),
              (0...59).contains(seconds)
        else {
            return nil
        }

        let direction = sign == "-" ? -1 : 1
        return direction * ((hours * 3600) + (minutes * 60) + seconds)
    }

    private static func parseDurationSeconds(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.hasPrefix("P") else { return nil }

        var totalSeconds: TimeInterval = 0
        var numberBuffer = ""
        var isInTimePart = false
        var sawComponent = false

        for character in trimmed.dropFirst() {
            if character == "T" {
                isInTimePart = true
                numberBuffer.removeAll()
                continue
            }

            if character.isNumber {
                numberBuffer.append(character)
                continue
            }

            guard let value = Double(numberBuffer), value >= 0 else { return nil }
            numberBuffer.removeAll()

            switch character {
            case "W":
                guard !isInTimePart else { return nil }
                totalSeconds += value * 7 * 24 * 3600
            case "D":
                guard !isInTimePart else { return nil }
                totalSeconds += value * 24 * 3600
            case "H":
                guard isInTimePart else { return nil }
                totalSeconds += value * 3600
            case "M":
                guard isInTimePart else { return nil }
                totalSeconds += value * 60
            case "S":
                guard isInTimePart else { return nil }
                totalSeconds += value
            default:
                return nil
            }

            sawComponent = true
        }

        guard sawComponent, numberBuffer.isEmpty else { return nil }
        return totalSeconds
    }

    private static func parseCalendarDayDuration(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.hasPrefix("P"), !trimmed.contains("T") else { return nil }

        var totalDays = 0
        var numberBuffer = ""
        var sawComponent = false

        for character in trimmed.dropFirst() {
            if character.isNumber {
                numberBuffer.append(character)
                continue
            }

            guard let value = Int(numberBuffer), value >= 0 else { return nil }
            numberBuffer.removeAll()

            switch character {
            case "W":
                totalDays += value * 7
            case "D":
                totalDays += value
            default:
                return nil
            }

            sawComponent = true
        }

        guard sawComponent, numberBuffer.isEmpty else { return nil }
        return totalDays
    }

    private static func reminderOffsetMinutes(fromAlarmTrigger value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed == "PT0M" || trimmed == "-PT0M" {
            return 0
        }

        guard trimmed.hasPrefix("-") else { return nil }
        guard let seconds = parseDurationSeconds(String(trimmed.dropFirst())) else { return nil }
        return Int((seconds / 60).rounded())
    }

    private static func alarmTrigger(
        from property: ICSProperty,
        fallbackTimeZoneIdentifier: String?,
        timeZoneDefinitions: [String: ICSTimeZoneDefinition]
    ) -> ParsedAlarmTrigger? {
        if property.params["VALUE"]?.uppercased() == "DATE-TIME" {
            guard let date = parseDateValue(
                property.value,
                isAllDay: false,
                timeZoneIdentifier: property.params["TZID"] ?? fallbackTimeZoneIdentifier,
                timeZoneDefinitions: timeZoneDefinitions
            ).date else { return nil }
            return .absolute(date)
        }

        guard let minutes = reminderOffsetMinutes(fromAlarmTrigger: property.value) else { return nil }
        if property.params["RELATED"]?.uppercased() == "END" {
            return .relativeToEnd(minutesBeforeEnd: minutes)
        }
        return .relativeToStart(minutesBeforeStart: minutes)
    }

    private static func alarmTriggerValue(minutesBeforeStart: Int) -> String {
        let minutes = max(0, minutesBeforeStart)
        if minutes == 0 {
            return "PT0M"
        }

        let days = minutes / (24 * 60)
        let remainingAfterDays = minutes % (24 * 60)
        let hours = remainingAfterDays / 60
        let remainingMinutes = remainingAfterDays % 60

        if days > 0, hours == 0, remainingMinutes == 0 {
            return "-P\(days)D"
        }

        var value = "-"
        if days > 0 {
            value += "P\(days)DT"
        } else {
            value += "PT"
        }
        if hours > 0 {
            value += "\(hours)H"
        }
        if remainingMinutes > 0 {
            value += "\(remainingMinutes)M"
        }
        return value
    }

    private static func escapeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
    }

    private static func textListValue(from values: [String]) -> String {
        normalizedEventCategories(values).map(escapeText).joined(separator: ",")
    }

    private static func textListValues(from value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var isEscaped = false

        for character in value {
            if isEscaped {
                current.append("\\")
                current.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "," {
                parts.append(current)
                current.removeAll()
            } else {
                current.append(character)
            }
        }

        if isEscaped {
            current.append("\\")
        }
        parts.append(current)
        return normalizedEventCategories(parts.map(unescapeText))
    }

    private static func escapeParameter(_ text: String) -> String {
        text
            .replacingOccurrences(of: "^", with: "^^")
            .replacingOccurrences(of: "\n", with: "^n")
            .replacingOccurrences(of: "\"", with: "^'")
    }

    private static func mailtoValue(email: String, fallbackName: String) -> String {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedEmail.isEmpty {
            return "mailto:\(trimmedEmail)"
        }

        return escapeText(fallbackName)
    }

    private static func foldedCalendarText(from lines: [String]) -> String {
        lines.flatMap(foldedLine).joined(separator: "\r\n") + "\r\n"
    }

    private static func foldedLine(_ line: String) -> [String] {
        let firstLimit = 75
        let continuationLimit = 75
        guard line.utf8.count > firstLimit else { return [line] }

        var result: [String] = []
        var current = ""
        var currentLimit = firstLimit

        for character in line {
            let characterText = String(character)
            let characterLength = characterText.utf8.count
            if !current.isEmpty,
               current != " ",
               current.utf8.count + characterLength > currentLimit {
                result.append(current)
                current = " "
                currentLimit = continuationLimit
            }
            current += characterText
        }

        if !current.isEmpty {
            result.append(current)
        }

        return result
    }

    private static func emailValue(from value: String) -> String {
        let text = unescapeText(value).trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = text.lowercased()
        let address: String
        if lowercased.hasPrefix("mailto:") {
            address = String(text.dropFirst("mailto:".count))
        } else if lowercased.hasPrefix("smtp:") {
            address = String(text.dropFirst("smtp:".count))
        } else {
            address = text
        }
        let decoded = percentDecodedEmail(mailtoAddressComponent(address))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return decoded.contains("@") ? decoded : ""
    }

    private static func participantEmail(from property: ICSProperty) -> String {
        let valueEmail = emailValue(from: property.value)
        if !valueEmail.isEmpty {
            return valueEmail
        }

        return emailValue(from: property.params["EMAIL"] ?? "")
    }

    private static func percentDecodedEmail(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.removingPercentEncoding ?? trimmed
    }

    private static func mailtoAddressComponent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryIndex = trimmed.firstIndex { $0 == "?" || $0 == "#" } ?? trimmed.endIndex
        return String(trimmed[..<queryIndex])
    }

    private static func boolValue(_ value: String, defaultValue: Bool) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1":
            return true
        case "false", "no", "0":
            return false
        default:
            return defaultValue
        }
    }

    private static func normalizedCalendarColorHex(_ value: String) -> String? {
        var color = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let semicolon = color.firstIndex(of: ";") {
            color = String(color[..<semicolon])
        }
        if color.hasPrefix("#") {
            color.removeFirst()
        }
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard color.count == 6,
              color.unicodeScalars.allSatisfy({ hexDigits.contains($0) })
        else {
            return nil
        }
        return "#\(color.uppercased())"
    }

    private static func attendeeType(fromCUTYPE value: String?) -> String {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "GROUP":
            return "group"
        case "RESOURCE":
            return "resource"
        case "ROOM":
            return "room"
        case "UNKNOWN":
            return "unknown"
        default:
            return "person"
        }
    }

    private static func attendeeRole(fromICSRole value: String?) -> String {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "CHAIR":
            return "chair"
        case "OPT-PARTICIPANT":
            return "optional"
        case "NON-PARTICIPANT":
            return "non-participant"
        default:
            return "required"
        }
    }

    private static func icsCalendarUserType(for type: String) -> String {
        switch type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "group":
            return "GROUP"
        case "resource":
            return "RESOURCE"
        case "room":
            return "ROOM"
        case "unknown":
            return "UNKNOWN"
        default:
            return "INDIVIDUAL"
        }
    }

    private static func icsRole(for role: String) -> String {
        switch role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "chair":
            return "CHAIR"
        case "optional", "opt-participant":
            return "OPT-PARTICIPANT"
        case "non-participant":
            return "NON-PARTICIPANT"
        default:
            return "REQ-PARTICIPANT"
        }
    }

    fileprivate static func unescapeText(_ text: String) -> String {
        var result = ""
        var isEscaped = false

        for character in text {
            if isEscaped {
                switch character {
                case "n", "N": result.append("\n")
                default: result.append(character)
                }
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                result.append(character)
            }
        }

        return result
    }

    private static func colorHex(for index: Int) -> String {
        let palette = ["#15A6C8", "#3B82F6", "#8B5CF6", "#22C55E", "#F59E0B", "#EF4444", "#EC4899"]
        return palette[index % palette.count]
    }

    private static func zonedDateTimeString(from date: Date, timeZone: TimeZone) -> String {
        zonedDateTimeFormatter(timeZone: timeZone).string(from: date)
    }

    private static func normalizedWeekdays(_ weekdays: [Int], startDate: Date, calendar: Calendar) -> [Int] {
        let normalized = weekdays.normalizedWeekdays
        if !normalized.isEmpty {
            return normalized
        }

        return [calendar.component(.weekday, from: startDate)]
    }

    private static func sortedWeekdays(_ weekdays: [Int], weekStart: Int? = nil) -> [Int] {
        let firstWeekday = weekStart ?? Calendar.current.firstWeekday
        return weekdays.normalizedWeekdays.sorted {
            (($0 - firstWeekday + 7) % 7) < (($1 - firstWeekday + 7) % 7)
        }
    }

    private static func weeklyOccurrenceStart(weekStart: Date, weekday: Int, matching sourceDate: Date, calendar: Calendar) -> Date? {
        let weekStartWeekday = calendar.component(.weekday, from: weekStart)
        let dayOffset = (weekday - weekStartWeekday + 7) % 7
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) else { return nil }
        return date(on: day, matching: sourceDate, calendar: calendar)
    }

    private static func weeklyOccurrenceStarts(
        weekStart: Date,
        weekdays: [Int],
        setPositions: [Int],
        matching sourceDate: Date,
        calendar: Calendar
    ) -> [Date] {
        let candidates = sortedWeekdays(weekdays, weekStart: calendar.component(.weekday, from: weekStart))
            .compactMap { weeklyOccurrenceStart(weekStart: weekStart, weekday: $0, matching: sourceDate, calendar: calendar) }
            .sorted()
        let normalizedSetPositions = normalizedRecurrenceSetPositions(setPositions, frequency: .weekly)
        guard !normalizedSetPositions.isEmpty else { return candidates }

        var selected: [Date] = []
        for position in normalizedSetPositions {
            let index = position > 0 ? position - 1 : candidates.count + position
            guard candidates.indices.contains(index) else { continue }
            let candidate = candidates[index]
            if !selected.containsOccurrenceStart(candidate) {
                selected.append(candidate)
            }
        }
        return selected.sorted()
    }

    private static func recurrenceCalendar(for event: ParsedEvent, weekStart: Int? = nil) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: event.timeZoneIdentifier) ?? TimeZone.current
        if let weekStart = weekStart ?? event.recurrenceWeekStart {
            calendar.firstWeekday = weekStart
        }
        return calendar
    }

    private static func ordinalWeekdayOccurrence(monthStart: Date, ordinal: Int, weekday: Int, matching sourceDate: Date, calendar: Calendar) -> Date? {
        guard let month = calendar.dateInterval(of: .month, for: monthStart) else { return nil }

        let candidateDay: Date?
        if ordinal > 0 {
            let firstWeekday = calendar.component(.weekday, from: month.start)
            let dayOffset = (weekday - firstWeekday + 7) % 7
            candidateDay = calendar.date(
                byAdding: .day,
                value: dayOffset + ((ordinal - 1) * 7),
                to: month.start
            )
        } else {
            let lastDay = calendar.startOfDay(for: month.end.addingTimeInterval(-1))
            let lastWeekday = calendar.component(.weekday, from: lastDay)
            let dayOffset = (lastWeekday - weekday + 7) % 7
            candidateDay = calendar.date(
                byAdding: .day,
                value: -(dayOffset + ((abs(ordinal) - 1) * 7)),
                to: lastDay
            )
        }

        guard let day = candidateDay,
              day >= month.start,
              day < month.end
        else {
            return nil
        }

        return date(on: day, matching: sourceDate, calendar: calendar)
    }

    private static func monthDayOccurrence(monthStart: Date, day: Int, matching sourceDate: Date, calendar: Calendar) -> Date? {
        guard let month = calendar.dateInterval(of: .month, for: monthStart) else { return nil }

        let dayDate: Date?
        if day > 0 {
            var components = calendar.dateComponents([.year, .month], from: month.start)
            components.day = day
            dayDate = date(from: components, matching: sourceDate, calendar: calendar)
        } else {
            dayDate = calendar.date(byAdding: .day, value: day, to: month.end)
                .flatMap { date(on: $0, matching: sourceDate, calendar: calendar) }
        }

        guard let dayDate,
              dayDate >= month.start,
              dayDate < month.end
        else {
            return nil
        }

        if day > 0 {
            guard calendar.component(.day, from: dayDate) == day else { return nil }
        }

        return dayDate
    }

    private static func monthAllowed(_ monthStart: Date, months: [Int], calendar: Calendar) -> Bool {
        let normalizedMonths = normalizedRecurrenceMonths(months, frequency: .monthly)
        guard !normalizedMonths.isEmpty else { return true }
        return normalizedMonths.contains(calendar.component(.month, from: monthStart))
    }

    private static func recurrenceMonths(for event: ParsedEvent, defaultMonth: Int) -> [Int] {
        let normalizedMonths = normalizedRecurrenceMonths(
            event.recurrenceMonths,
            frequency: event.recurrenceFrequency
        )
        return normalizedMonths.isEmpty ? [defaultMonth] : normalizedMonths
    }

    private static func yearlyDateOccurrence(yearStart: Date, month: Int, day: Int, matching sourceDate: Date, calendar: Calendar) -> Date? {
        guard let year = calendar.dateInterval(of: .year, for: yearStart) else { return nil }

        guard let monthStart = calendar.date(byAdding: .month, value: month - 1, to: year.start),
              let date = monthDayOccurrence(monthStart: monthStart, day: day, matching: sourceDate, calendar: calendar),
              date >= year.start,
              date < year.end,
              calendar.component(.month, from: date) == month
        else {
            return nil
        }

        return date
    }

    private static func date(on day: Date, matching sourceDate: Date, calendar: Calendar) -> Date? {
        date(from: calendar.dateComponents([.year, .month, .day], from: day), matching: sourceDate, calendar: calendar)
    }

    private static func date(from sourceComponents: DateComponents, matching sourceDate: Date, calendar: Calendar) -> Date? {
        var components = sourceComponents
        let time = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: sourceDate)
        components.calendar = calendar
        components.hour = time.hour ?? 0
        components.minute = time.minute ?? 0
        components.second = time.second ?? 0
        components.nanosecond = 0

        return calendar.date(from: components).flatMap { date in
            guard let nanosecond = time.nanosecond, nanosecond > 0 else { return date }
            return calendar.date(byAdding: .nanosecond, value: nanosecond, to: date)
        }
    }

    private static func icsWeekdayName(for weekday: Int) -> String? {
        switch weekday {
        case 1: return "SU"
        case 2: return "MO"
        case 3: return "TU"
        case 4: return "WE"
        case 5: return "TH"
        case 6: return "FR"
        case 7: return "SA"
        default: return nil
        }
    }

    private static func weekdayNumber(forICSName name: String) -> Int? {
        let suffix = String(name.uppercased().suffix(2))
        switch suffix {
        case "SU": return 1
        case "MO": return 2
        case "TU": return 3
        case "WE": return 4
        case "TH": return 5
        case "FR": return 6
        case "SA": return 7
        default: return nil
        }
    }

    private static func fallbackUID(for event: ParsedEvent) -> String {
        let startValue = event.startDate.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
        let endValue = event.endDate.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
        let calendarValue = event.calendarKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleValue = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let locationValue = event.location.trimmingCharacters(in: .whitespacesAndNewlines)
        return "missing-uid:\([calendarValue, titleValue, startValue, endValue, locationValue].joined(separator: "|"))"
    }

    fileprivate static func stableIdentifierComponent(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return UUID().uuidString }

        var hash: UInt64 = 14695981039346656037
        for byte in trimmed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }

        return String(hash, radix: 16)
    }

    private static func zonedDateTimeFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.isLenient = false
        return formatter
    }

    private static func dateFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd"
        formatter.isLenient = false
        return formatter
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.isLenient = false
        return formatter
    }()

    private static let floatingDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.isLenient = false
        return formatter
    }()

    private static let utcGregorianCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static let ianaTimeZonePrefixes = [
        "Africa/",
        "America/",
        "Antarctica/",
        "Arctic/",
        "Asia/",
        "Atlantic/",
        "Australia/",
        "Europe/",
        "Indian/",
        "Pacific/",
        "Etc/"
    ]

    private static let windowsTimeZoneMap: [String: String] = [
        "utc": "UTC",
        "coordinated universal time": "UTC",
        "dateline standard time": "Etc/GMT+12",
        "utc-11": "Etc/GMT+11",
        "aleutian standard time": "America/Adak",
        "hawaiian standard time": "Pacific/Honolulu",
        "marquesas standard time": "Pacific/Marquesas",
        "alaskan standard time": "America/Anchorage",
        "utc-09": "Etc/GMT+9",
        "pacific standard time": "America/Los_Angeles",
        "us mountain standard time": "America/Phoenix",
        "mountain standard time": "America/Denver",
        "central america standard time": "America/Guatemala",
        "central standard time": "America/Chicago",
        "easter island standard time": "Pacific/Easter",
        "mexico standard time": "America/Mexico_City",
        "canada central standard time": "America/Regina",
        "sa pacific standard time": "America/Bogota",
        "eastern standard time": "America/New_York",
        "haiti standard time": "America/Port-au-Prince",
        "cuba standard time": "America/Havana",
        "us eastern standard time": "America/Indianapolis",
        "turks and caicos standard time": "America/Grand_Turk",
        "paraguay standard time": "America/Asuncion",
        "atlantic standard time": "America/Halifax",
        "venezuela standard time": "America/Caracas",
        "central brazilian standard time": "America/Cuiaba",
        "sa western standard time": "America/La_Paz",
        "pacific sa standard time": "America/Santiago",
        "newfoundland standard time": "America/St_Johns",
        "tocantins standard time": "America/Araguaina",
        "e. south america standard time": "America/Sao_Paulo",
        "sa eastern standard time": "America/Cayenne",
        "argentina standard time": "America/Argentina/Buenos_Aires",
        "greenland standard time": "America/Godthab",
        "montevideo standard time": "America/Montevideo",
        "magallanes standard time": "America/Punta_Arenas",
        "saint pierre standard time": "America/Miquelon",
        "bahia standard time": "America/Bahia",
        "utc-02": "Etc/GMT+2",
        "azores standard time": "Atlantic/Azores",
        "cape verde standard time": "Atlantic/Cape_Verde",
        "gmt standard time": "Europe/London",
        "greenwich standard time": "Atlantic/Reykjavik",
        "morocco standard time": "Africa/Casablanca",
        "w. europe standard time": "Europe/Berlin",
        "central europe standard time": "Europe/Budapest",
        "romance standard time": "Europe/Paris",
        "central european standard time": "Europe/Warsaw",
        "w. central africa standard time": "Africa/Lagos",
        "jordan standard time": "Asia/Amman",
        "gtb standard time": "Europe/Athens",
        "middle east standard time": "Asia/Beirut",
        "egypt standard time": "Africa/Cairo",
        "e. europe standard time": "Europe/Chisinau",
        "syria standard time": "Asia/Damascus",
        "west bank standard time": "Asia/Hebron",
        "south africa standard time": "Africa/Johannesburg",
        "fle standard time": "Europe/Helsinki",
        "israel standard time": "Asia/Jerusalem",
        "south sudan standard time": "Africa/Juba",
        "kaliningrad standard time": "Europe/Kaliningrad",
        "sudan standard time": "Africa/Khartoum",
        "libya standard time": "Africa/Tripoli",
        "namibia standard time": "Africa/Windhoek",
        "arabic standard time": "Asia/Baghdad",
        "turkey standard time": "Europe/Istanbul",
        "arab standard time": "Asia/Riyadh",
        "belarus standard time": "Europe/Minsk",
        "russian standard time": "Europe/Moscow",
        "e. africa standard time": "Africa/Nairobi",
        "iran standard time": "Asia/Tehran",
        "arabian standard time": "Asia/Dubai",
        "astrakhan standard time": "Europe/Astrakhan",
        "azerbaijan standard time": "Asia/Baku",
        "russia time zone 3": "Europe/Samara",
        "mauritius standard time": "Indian/Mauritius",
        "saratov standard time": "Europe/Saratov",
        "georgian standard time": "Asia/Tbilisi",
        "caucasus standard time": "Asia/Yerevan",
        "afghanistan standard time": "Asia/Kabul",
        "west asia standard time": "Asia/Tashkent",
        "ekaterinburg standard time": "Asia/Yekaterinburg",
        "pakistan standard time": "Asia/Karachi",
        "india standard time": "Asia/Kolkata",
        "sri lanka standard time": "Asia/Colombo",
        "nepal standard time": "Asia/Kathmandu",
        "central asia standard time": "Asia/Almaty",
        "bangladesh standard time": "Asia/Dhaka",
        "omsk standard time": "Asia/Omsk",
        "myanmar standard time": "Asia/Yangon",
        "se asia standard time": "Asia/Bangkok",
        "altai standard time": "Asia/Barnaul",
        "w. mongolia standard time": "Asia/Hovd",
        "north asia standard time": "Asia/Krasnoyarsk",
        "n. central asia standard time": "Asia/Novosibirsk",
        "tomsk standard time": "Asia/Tomsk",
        "china standard time": "Asia/Shanghai",
        "north asia east standard time": "Asia/Irkutsk",
        "singapore standard time": "Asia/Singapore",
        "w. australia standard time": "Australia/Perth",
        "taipei standard time": "Asia/Taipei",
        "ulaanbaatar standard time": "Asia/Ulaanbaatar",
        "aus central w. standard time": "Australia/Eucla",
        "transbaikal standard time": "Asia/Chita",
        "tokyo standard time": "Asia/Tokyo",
        "north korea standard time": "Asia/Pyongyang",
        "korea standard time": "Asia/Seoul",
        "yakutsk standard time": "Asia/Yakutsk",
        "cen. australia standard time": "Australia/Adelaide",
        "aus central standard time": "Australia/Darwin",
        "e. australia standard time": "Australia/Brisbane",
        "aus eastern standard time": "Australia/Sydney",
        "west pacific standard time": "Pacific/Port_Moresby",
        "tasmania standard time": "Australia/Hobart",
        "vladivostok standard time": "Asia/Vladivostok",
        "lord howe standard time": "Australia/Lord_Howe",
        "bougainville standard time": "Pacific/Bougainville",
        "russia time zone 10": "Asia/Srednekolymsk",
        "magadan standard time": "Asia/Magadan",
        "norfolk standard time": "Pacific/Norfolk",
        "sakhalin standard time": "Asia/Sakhalin",
        "central pacific standard time": "Pacific/Guadalcanal",
        "russia time zone 11": "Asia/Kamchatka",
        "new zealand standard time": "Pacific/Auckland",
        "utc+12": "Etc/GMT-12",
        "fiji standard time": "Pacific/Fiji",
        "chatham islands standard time": "Pacific/Chatham",
        "utc+13": "Etc/GMT-13",
        "tonga standard time": "Pacific/Tongatapu",
        "samoa standard time": "Pacific/Apia",
        "line islands standard time": "Pacific/Kiritimati"
    ]
}

private struct ICSProperty {
    let name: String
    let params: [String: String]
    let value: String

    var textValue: String {
        LocalCalendarICSCodec.unescapeText(value)
    }
}

private struct TimeZoneExportRange {
    var start: Date
    var end: Date
}

private struct TimeZoneExportObservance {
    let isDaylight: Bool
    let offsetFrom: Int
    let offsetTo: Int
    let name: String
    var dates: [Date]

    func sameDefinition(as other: TimeZoneExportObservance) -> Bool {
        isDaylight == other.isDaylight
            && offsetFrom == other.offsetFrom
            && offsetTo == other.offsetTo
            && name == other.name
    }
}

private struct ICSTimeZoneDefinition {
    let identifier: String
    let sourceIdentifier: String
    let observances: [ICSTimeZoneObservance]

    func date(from value: String) -> (date: Date, identifier: String)? {
        guard let localDate = Self.localDate(from: value) else { return nil }
        let observance = observance(for: localDate)
        let date = localDate.addingTimeInterval(TimeInterval(-observance.offsetToSeconds))
        let identifier = TimeZone(identifier: self.identifier) == nil
            ? TimeZone(secondsFromGMT: observance.offsetToSeconds)?.identifier ?? self.identifier
            : self.identifier
        return (date, identifier)
    }

    private func observance(for localDate: Date) -> ICSTimeZoneObservance {
        let sorted = observances.sorted { $0.startDate < $1.startDate }
        return sorted.last { $0.startDate <= localDate } ?? sorted.first ?? ICSTimeZoneObservance(startDate: .distantPast, offsetToSeconds: 0)
    }

    static func localDate(from value: String) -> Date? {
        if value.count == 8 {
            return localDateFormatter.date(from: value)
        }

        return localDateTimeFormatter.date(from: value)
    }

    private static let localDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.isLenient = false
        return formatter
    }()

    private static let localDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        formatter.isLenient = false
        return formatter
    }()
}

private struct ICSTimeZoneObservance {
    let startDate: Date
    let offsetToSeconds: Int
}

private enum ParsedAlarmTrigger {
    case relativeToStart(minutesBeforeStart: Int)
    case relativeToEnd(minutesBeforeEnd: Int)
    case absolute(Date)
}

private struct ParsedAlarm {
    var trigger: ParsedAlarmTrigger?
    var repeatDurationSeconds: TimeInterval?
    var repeatCount = 0

    func reminderOffsets(startDate: Date, endDate: Date?) -> [Int] {
        guard let triggerMinutesBeforeStart = minutesBeforeStart(startDate: startDate, endDate: endDate) else { return [] }
        let repeatIntervalMinutes = max(0, Int(((repeatDurationSeconds ?? 0) / 60).rounded()))
        guard repeatCount > 0, repeatIntervalMinutes > 0 else {
            return [triggerMinutesBeforeStart]
        }

        return (0...repeatCount).compactMap { index in
            let offset = triggerMinutesBeforeStart - (index * repeatIntervalMinutes)
            return offset >= 0 ? offset : nil
        }
    }

    private func minutesBeforeStart(startDate: Date, endDate: Date?) -> Int? {
        guard let trigger else { return nil }

        let alarmDate: Date
        switch trigger {
        case .relativeToStart(let minutesBeforeStart):
            return max(0, minutesBeforeStart)
        case .relativeToEnd(let minutesBeforeEnd):
            guard let endDate else { return nil }
            alarmDate = endDate.addingTimeInterval(-Double(max(0, minutesBeforeEnd)) * 60)
        case .absolute(let date):
            alarmDate = date
        }

        let minutes = Int((startDate.timeIntervalSince(alarmDate) / 60).rounded())
        return minutes >= 0 ? minutes : nil
    }
}

private struct ParsedFreeBusyBlock {
    var sourceUID: String
    var stableIdentifier: String
    var sourceCalendarID: String
    var remoteObjectURLString: String
    var calendarTitle: String
    var calendarColorHex: String
    var startDate: Date
    var endDate: Date
    var fbType: String
    var timeZoneIdentifier: String
    var organizerName: String
    var organizerEmail: String
    var dtStamp: Date?

    var externalUID: String {
        let trimmedUID = sourceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseUID = trimmedUID.isEmpty ? "freebusy" : trimmedUID
        return "\(baseUID)#freebusy-\(stableIdentifier)"
    }

    var calendarKey: String {
        if !sourceCalendarID.isEmpty { return sourceCalendarID }
        return calendarTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Free/busy"
            : calendarTitle
    }

    var stableCalendarID: String {
        let rawID = sourceCalendarID.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawID.hasPrefix("local-calendar-") {
            return rawID
        }

        return "local-calendar-import-\(LocalCalendarICSCodec.stableIdentifierComponent(for: calendarKey))"
    }

    var title: String {
        switch fbType {
        case "FREE":
            return "Free"
        case "BUSY-TENTATIVE":
            return "Tentative"
        case "BUSY-UNAVAILABLE":
            return "Unavailable"
        default:
            return "Busy"
        }
    }

    var availability: CalendarEventAvailability {
        fbType == "FREE" ? .free : .busy
    }

    var status: CalendarEventStatus {
        fbType == "BUSY-TENTATIVE" ? .tentative : .confirmed
    }

    var notes: String {
        "Free/busy block imported from VFREEBUSY"
    }
}

private struct ParsedRecurrencePeriod {
    var startDate: Date
    var endDate: Date
}

private struct ParsedEvent {
    var uid = ""
    var sequence = 0
    var title = ""
    var createdAt: Date?
    var updatedAt: Date?
    var dtStamp: Date?
    var startDate: Date?
    var endDate: Date?
    var isAllDay = false
    var microsoftAllDayEvent = false
    var availability: CalendarEventAvailability = .busy
    var availabilityWasSetByTransparency = false
    var status = ""
    var statusWasSetByStatus = false
    var privacy: CalendarEventPrivacy = .public
    var importance: CalendarEventImportance = .normal
    var importanceWasSetByPriority = false
    var categories: [String] = []
    var importsCancelledAsEvent = false
    var relatedEvents: [LocalEventRelationship] = []
    var attachments: [LocalEventAttachment] = []
    var resourceNames: [String] = []
    var reminderOffsets: [Int] = []
    var location = ""
    var geoCoordinate: LocalEventGeoCoordinate?
    var notes = ""
    var urlString = ""
    var timeZoneIdentifier = TimeZone.current.identifier
    var organizerName = ""
    var organizerEmail = ""
    var attendees: [LocalEventAttendee] = []
    var myResponseStatus: EventResponseStatus = .notInvited
    var recurrenceFrequency: LocalRecurrenceFrequency = .none
    var recurrenceInterval = 1
    var recurrenceWeekdays: [Int] = []
    var recurrenceWeekStart: Int?
    var recurrenceSetPositions: [Int] = []
    var recurrenceOrdinal: Int?
    var recurrenceOrdinalWeekday: Int?
    var recurrenceMonthDay: Int?
    var recurrenceMonths: [Int] = []
    var recurrenceEndDate: Date?
    var recurrenceCount: Int?
    var recurrenceComponents: [String: String] = [:]
    var hasUnsupportedRecurrencePattern = false
    var hasUnsupportedRecurrenceExclusionRule = false
    var durationSeconds: TimeInterval?
    var durationCalendarDays: Int?
    var additionalOccurrenceStartDates: [Date] = []
    var additionalOccurrencePeriods: [ParsedRecurrencePeriod] = []
    var excludedOccurrenceStartDates: [Date] = []
    var recurrenceID: Date?
    var recurrenceIDAppliesToFutureOccurrences = false
    var sourceCalendarID = ""
    var externalUIDOverride = ""
    var remoteObjectURLString = ""
    var remoteETag = ""
    var calendarTitle: String
    var calendarColorHex = ""
    var calendarAllowsEventWrite = true
    var calendarAllowsResponses = true

    var isCancelled: Bool {
        status == "CANCELLED"
    }

    var eventStatus: CalendarEventStatus {
        CalendarEventStatus(icsStatus: status)
    }

    var calendarKey: String {
        if !sourceCalendarID.isEmpty { return sourceCalendarID }
        if !calendarTitle.isEmpty { return calendarTitle }
        return "Imported Calendar"
    }

    var stableCalendarID: String {
        let rawID = sourceCalendarID.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawID.hasPrefix("local-calendar-") {
            return rawID
        }

        return "local-calendar-import-\(LocalCalendarICSCodec.stableIdentifierComponent(for: calendarKey))"
    }

    var baseLocalExternalUID: String {
        externalUIDOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? uid : externalUIDOverride
    }

    var seriesIdentityKey: String {
        "\(stableCalendarID)|\(baseLocalExternalUID.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    var localExternalUID: String {
        let baseUID = baseLocalExternalUID
        guard let recurrenceID else { return baseUID }
        return "\(baseUID)#\(Int(recurrenceID.timeIntervalSince1970))"
    }
}

private extension Array where Element == Int {
    var normalizedWeekdays: [Int] {
        Array(Set(filter { (1...7).contains($0) })).sorted()
    }

    var onlyElement: Int? {
        count == 1 ? first : nil
    }
}

private extension Array where Element == Date {
    var uniqueOccurrenceStarts: [Date] {
        var seen: Set<Int> = []
        return filter { date in
            seen.insert(Int(date.timeIntervalSince1970)).inserted
        }
    }

    func containsOccurrenceStart(_ date: Date) -> Bool {
        contains { abs($0.timeIntervalSince(date)) < 1 }
    }
}

private extension LocalRecurrenceFrequency {
    var icsName: String {
        switch self {
        case .none: return ""
        case .daily: return "DAILY"
        case .weekly: return "WEEKLY"
        case .monthly: return "MONTHLY"
        case .yearly: return "YEARLY"
        }
    }

    init?(icsName: String) {
        switch icsName.uppercased() {
        case "DAILY": self = .daily
        case "WEEKLY": self = .weekly
        case "MONTHLY": self = .monthly
        case "YEARLY": self = .yearly
        default: return nil
        }
    }
}

private extension Array where Element == Int {
    func matchesOnly(_ value: Int) -> Bool {
        count == 1 && first == value
    }
}

private extension CalendarEventAvailability {
    var icsTransparency: String {
        switch self {
        case .busy: return "OPAQUE"
        case .free: return "TRANSPARENT"
        }
    }

    init(icsTransparency: String) {
        switch icsTransparency.uppercased() {
        case "TRANSPARENT":
            self = .free
        default:
            self = .busy
        }
    }
}

private extension CalendarEventStatus {
    var icsStatus: String {
        switch self {
        case .confirmed:
            return "CONFIRMED"
        case .tentative:
            return "TENTATIVE"
        case .cancelled:
            return "CANCELLED"
        case .unknown:
            return "CONFIRMED"
        }
    }

    init(icsStatus: String) {
        switch icsStatus.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "TENTATIVE":
            self = .tentative
        case "CANCELLED":
            self = .cancelled
        case "CONFIRMED":
            self = .confirmed
        default:
            self = .confirmed
        }
    }
}

private extension CalendarEventPrivacy {
    var icsClass: String {
        switch self {
        case .public:
            return "PUBLIC"
        case .private:
            return "PRIVATE"
        case .confidential:
            return "CONFIDENTIAL"
        }
    }

    init(icsClass: String) {
        switch icsClass.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "PRIVATE":
            self = .private
        case "CONFIDENTIAL":
            self = .confidential
        default:
            self = .public
        }
    }
}

private extension CalendarEventImportance {
    var icsPriority: Int {
        switch self {
        case .high:
            return 1
        case .normal:
            return 5
        case .low:
            return 9
        }
    }

    init(icsPriority: String) {
        let value = Int(icsPriority.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        switch value {
        case 1...4:
            self = .high
        case 6...9:
            self = .low
        default:
            self = .normal
        }
    }

    init(microsoftImportance: String) {
        let normalized = microsoftImportance
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch normalized {
        case "2", "high":
            self = .high
        case "0", "low":
            self = .low
        default:
            self = .normal
        }
    }
}

private extension EventResponseStatus {
    var icsPartStat: String {
        switch self {
        case .accepted:
            return "ACCEPTED"
        case .declined:
            return "DECLINED"
        case .tentative:
            return "TENTATIVE"
        case .delegated:
            return "DELEGATED"
        case .completed:
            return "COMPLETED"
        case .inProcess:
            return "IN-PROCESS"
        case .notInvited, .unknown, .pending, .canceled:
            return "NEEDS-ACTION"
        }
    }

    init?(icsPartStat: String) {
        switch icsPartStat.uppercased() {
        case "ACCEPTED":
            self = .accepted
        case "DECLINED":
            self = .declined
        case "TENTATIVE":
            self = .tentative
        case "DELEGATED":
            self = .delegated
        case "COMPLETED":
            self = .completed
        case "IN-PROCESS":
            self = .inProcess
        case "NEEDS-ACTION", "":
            self = .pending
        default:
            return nil
        }
    }
}
