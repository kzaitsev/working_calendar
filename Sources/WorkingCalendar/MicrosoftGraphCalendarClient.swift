import Foundation

struct MicrosoftGraphCalendarInfo: Hashable {
    let id: String
    let name: String
    let colorHex: String
    let canEdit: Bool

    var allowsEventWrite: Bool {
        canEdit
    }

    var allowsResponses: Bool {
        canEdit
    }
}

struct MicrosoftGraphCalendarPayload {
    let calendar: MicrosoftGraphCalendarInfo
    let events: [MicrosoftGraphEvent]
    let deletedRemoteObjectURLs: Set<String>
    let cancelledDetachedOccurrenceRemoteObjectURLs: Set<String>
    let cancelledRemoteOccurrences: Set<LocalProviderRemoteOccurrenceCancellation>
    let isIncremental: Bool
    let deltaLink: String
    let windowStartDate: Date
    let windowEndDate: Date

    var syncState: MicrosoftGraphSyncState {
        MicrosoftGraphSyncState(
            graphCalendarID: calendar.id,
            deltaLink: deltaLink,
            windowStartDate: windowStartDate,
            windowEndDate: windowEndDate
        )
    }
}

struct MicrosoftGraphWriteResult {
    let remoteObjectURLString: String
    let remoteETag: String
}

struct MicrosoftGraphRecurringExceptionWritePlan {
    let occurrenceIDsToDelete: [String]
    let occurrenceIDsToPatch: [String]
}

enum MicrosoftGraphCalendarClientError: LocalizedError {
    case missingAccessToken
    case missingRefreshToken
    case invalidAccountURL
    case calendarNotFound
    case remoteObjectMissing
    case invalidEventDate
    case unsupportedRelativeRecurrenceOrdinal(Int)
    case unsupportedNegativeRecurrenceMonthDay(Int)
    case unsupportedMonthlyRecurrenceMonths([Int])
    case unsupportedYearlyRecurrenceMonths([Int])
    case unsupportedWeeklyRecurrenceSetPositions([Int])
    case unsupportedAdditionalOccurrences
    case unsupportedMultipleReminders([Int])
    case paginationLoop(URL)
    case paginationLimitExceeded(URL)
    case remoteConflict(URL)
    case retryAfter(Int, URL, String)
    case httpStatus(Int, URL, String)

    var errorDescription: String? {
        switch self {
        case .missingAccessToken:
            return "Microsoft 365 access token is missing."
        case .missingRefreshToken:
            return "Reconnect this Microsoft 365 account; the stored credential cannot refresh access tokens."
        case .invalidAccountURL:
            return "Microsoft Graph endpoint is invalid."
        case .calendarNotFound:
            return "Could not find the Microsoft 365 calendar for this event."
        case .remoteObjectMissing:
            return "This event does not have a Microsoft 365 event ID yet."
        case .invalidEventDate:
            return "This Microsoft 365 event is missing a start or end date."
        case .unsupportedRelativeRecurrenceOrdinal(let ordinal):
            return "Microsoft 365 can only save first, second, third, fourth, or last weekday recurrence patterns. This event uses ordinal \(ordinal)."
        case .unsupportedNegativeRecurrenceMonthDay(let monthDay):
            return "Microsoft 365 cannot save recurrence rules such as BYMONTHDAY=\(monthDay). Move this event to a local, CalDAV, or Google calendar before editing it."
        case .unsupportedMonthlyRecurrenceMonths(let months):
            return "Microsoft 365 cannot save monthly recurrence rules with BYMONTH values (\(months.map(String.init).joined(separator: ","))). Move this event to a local, CalDAV, or Google calendar before editing it."
        case .unsupportedYearlyRecurrenceMonths(let months):
            return "Microsoft 365 cannot save yearly recurrence rules with multiple BYMONTH values (\(months.map(String.init).joined(separator: ","))). Move this event to a local, CalDAV, or Google calendar before editing it."
        case .unsupportedWeeklyRecurrenceSetPositions(let positions):
            return "Microsoft 365 cannot save weekly recurrence rules with BYSETPOS values (\(positions.map(String.init).joined(separator: ","))). Move this event to a local, CalDAV, or Google calendar before editing it."
        case .unsupportedAdditionalOccurrences:
            return "Microsoft 365 cannot save recurrence rules with extra RDATE occurrences. Move this event to a local, CalDAV, or Google calendar before editing it."
        case .unsupportedMultipleReminders(let offsets):
            return "Microsoft 365 can save only one reminder per event. This event has reminders at \(offsets.map(String.init).joined(separator: ",")) minutes before start."
        case .paginationLoop(let url):
            return "Microsoft Graph returned a repeated sync page for \(url.host ?? url.absoluteString)."
        case .paginationLimitExceeded(let url):
            return "Microsoft Graph returned too many sync pages for \(url.host ?? url.absoluteString)."
        case .remoteConflict(let url):
            let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            let eventName = name.isEmpty ? "this event" : name
            return "Microsoft 365 refused to save \(eventName) because it changed remotely. Sync this calendar and try again."
        case .retryAfter(let seconds, _, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "Microsoft Graph asked Working Calendar to retry in \(seconds) seconds."
            }
            return "Microsoft Graph asked Working Calendar to retry in \(seconds) seconds: \(detail)"
        case .httpStatus(let status, let url, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "Microsoft Graph returned HTTP \(status) for \(url.host ?? url.absoluteString)."
            }
            return "Microsoft Graph returned HTTP \(status): \(detail)"
        }
    }

    var allowsFullSyncFallback: Bool {
        switch self {
        case .httpStatus(let status, _, _):
            return status == 410 || status == 400
        case .missingAccessToken, .missingRefreshToken, .invalidAccountURL, .calendarNotFound, .remoteObjectMissing, .invalidEventDate, .unsupportedRelativeRecurrenceOrdinal, .unsupportedNegativeRecurrenceMonthDay, .unsupportedMonthlyRecurrenceMonths, .unsupportedYearlyRecurrenceMonths, .unsupportedWeeklyRecurrenceSetPositions, .unsupportedAdditionalOccurrences, .unsupportedMultipleReminders, .paginationLoop, .paginationLimitExceeded, .remoteConflict, .retryAfter:
            return false
        }
    }
}

extension MicrosoftGraphCalendarClientError: ProviderRetryAfterError {
    var providerRetryAfterSeconds: Int? {
        guard case .retryAfter(let seconds, _, _) = self else { return nil }
        return seconds
    }
}

final class MicrosoftGraphCalendarClient {
    private static let maxGraphPageCount = 10_000
    private static let workingCalendarOpenExtensionName = "dev.codex.workingCalendar"
    private static let relatedEventsExtensionField = "relatedEventsJSON"
    private static let geoCoordinateExtensionField = "geoCoordinateJSON"

    private let transport: CalendarProviderHTTPTransport
    private let accessTokenProvider: CalendarProviderAccessTokenProvider

    init(
        transport: CalendarProviderHTTPTransport = URLSessionCalendarProviderHTTPTransport(),
        accessTokenProvider: @escaping CalendarProviderAccessTokenProvider = { account, service, forceRefresh in
            try await OAuthCredentialStore.validAccessToken(
                for: account,
                service: service,
                forceRefresh: forceRefresh
            )
        }
    ) {
        self.transport = transport
        self.accessTokenProvider = accessTokenProvider
    }

    func fetchAccountIdentityEmail(account: CalendarProviderAccount) async throws -> String? {
        (try await fetchAccountIdentityEmails(account: account)).first
    }

    func fetchAccountIdentityEmails(account: CalendarProviderAccount) async throws -> [String] {
        let url = try apiURL(
            account: account,
            path: ["me"],
            queryItems: [
                URLQueryItem(name: "$select", value: "mail,userPrincipalName,otherMails,proxyAddresses")
            ]
        )
        let profile: MicrosoftGraphUserProfile = try await jsonRequest(
            account: account,
            url: url,
            method: "GET",
            body: nil
        )
        return graphIdentityEmails(from: profile)
    }

    func fetchCalendarPayloads(
        account: CalendarProviderAccount,
        startDate: Date,
        endDate: Date,
        syncStates: [MicrosoftGraphSyncState] = []
    ) async throws -> [MicrosoftGraphCalendarPayload] {
        let calendars = try await fetchCalendars(account: account)
        let syncStateByCalendarID = Dictionary(uniqueKeysWithValues: syncStates.map { ($0.graphCalendarID, $0) })
        var payloads: [MicrosoftGraphCalendarPayload] = []

        for calendar in calendars {
            if let syncState = syncStateByCalendarID[calendar.id],
               syncState.coversWindow(startDate: startDate, endDate: endDate),
               let deltaLink = syncState.deltaLink.nilIfBlank,
               let deltaURL = URL(string: deltaLink) {
                do {
                    payloads.append(try await fetchIncrementalCalendarPayload(
                        account: account,
                        calendar: calendar,
                        deltaURL: deltaURL,
                        syncedWindowStartDate: syncState.windowStartDate ?? startDate,
                        syncedWindowEndDate: syncState.windowEndDate ?? endDate,
                        startDate: startDate,
                        endDate: endDate
                    ))
                    continue
                } catch let error as MicrosoftGraphCalendarClientError where error.allowsFullSyncFallback {
                    payloads.append(try await fetchFullCalendarPayload(
                        account: account,
                        calendar: calendar,
                        startDate: startDate,
                        endDate: endDate
                    ))
                    continue
                }
            }

            payloads.append(try await fetchFullCalendarPayload(
                account: account,
                calendar: calendar,
                startDate: startDate,
                endDate: endDate
            ))
        }

        return payloads
    }

    func annotatedICSText(
        event: MicrosoftGraphEvent,
        calendar: MicrosoftGraphCalendarInfo,
        account: CalendarProviderAccount
    ) throws -> String {
        let lines = try eventLines(
            event: event,
            calendar: calendar,
            account: account,
            masterEvent: nil
        )
        return calendarText(calendar: calendar, eventLines: [lines])
    }

    func annotatedICSText(
        events: [MicrosoftGraphEvent],
        calendar: MicrosoftGraphCalendarInfo,
        account: CalendarProviderAccount
    ) throws -> String {
        let masterEventByID = Dictionary(
            uniqueKeysWithValues: events
                .filter(\.isSeriesMaster)
                .map { ($0.id, $0) }
        )
        var vevents: [[String]] = []
        var emittedExceptionKeys: Set<String> = []

        func exceptionKey(_ exception: MicrosoftGraphEvent, masterEvent: MicrosoftGraphEvent) -> String {
            [
                masterEvent.id,
                exception.originalStart.nilIfBlank
                    ?? exception.occurrenceId.nilIfBlank
                    ?? exception.id
            ].joined(separator: "|")
        }

        for event in events where event.isCancelled != true {
            if let seriesMasterID = event.seriesMasterId.nilIfBlank,
               let masterEvent = masterEventByID[seriesMasterID] {
                let key = exceptionKey(event, masterEvent: masterEvent)
                guard emittedExceptionKeys.insert(key).inserted else { continue }
                guard let lines = try? eventLines(
                    event: event,
                    calendar: calendar,
                    account: account,
                    masterEvent: masterEvent
                ) else {
                    continue
                }
                vevents.append(lines)
                continue
            }

            guard let lines = try? eventLines(
                event: event,
                calendar: calendar,
                account: account,
                masterEvent: nil
            ) else {
                continue
            }
            vevents.append(lines)

            for exception in event.exceptionOccurrences ?? [] where exception.isCancelled != true {
                let key = exceptionKey(exception, masterEvent: event)
                guard emittedExceptionKeys.insert(key).inserted else { continue }
                guard let exceptionLines = try? eventLines(
                    event: exception,
                    calendar: calendar,
                    account: account,
                    masterEvent: event
                ) else {
                    continue
                }
                vevents.append(exceptionLines)
            }
        }

        guard !vevents.isEmpty else {
            throw MicrosoftGraphCalendarClientError.invalidEventDate
        }

        return calendarText(calendar: calendar, eventLines: vevents)
    }

    func remoteObjectURLStringsForImportedEvents(
        events: [MicrosoftGraphEvent],
        calendar: MicrosoftGraphCalendarInfo,
        account: CalendarProviderAccount
    ) -> Set<String> {
        var remoteObjectURLs: Set<String> = []
        for event in events where event.isCancelled != true {
            remoteObjectURLs.insert(remoteObjectURLString(event: event, calendar: calendar, account: account))
            for exception in event.exceptionOccurrences ?? [] where exception.isCancelled != true {
                remoteObjectURLs.insert(remoteObjectURLString(event: exception, calendar: calendar, account: account))
            }
        }
        return remoteObjectURLs
    }

    private func eventLines(
        event: MicrosoftGraphEvent,
        calendar: MicrosoftGraphCalendarInfo,
        account: CalendarProviderAccount,
        masterEvent: MicrosoftGraphEvent?
    ) throws -> [String] {
        guard event.isCancelled != true,
              let start = event.start?.icsDateLine(prefix: "DTSTART", isAllDay: event.isAllDay == true),
              let end = event.end?.icsDateLine(prefix: "DTEND", isAllDay: event.isAllDay == true)
        else {
            throw MicrosoftGraphCalendarClientError.invalidEventDate
        }

        let calendarID = localCalendarID(for: account, graphCalendarID: calendar.id)
        let remoteObjectURL = remoteObjectURLString(account: account, calendarID: calendar.id, eventID: event.id)
        let updatedAt = event.lastModifiedDate ?? Date()
        let eventUID = masterEvent.map { uid(for: $0) } ?? uid(for: event)

        var lines = [
            "BEGIN:VEVENT",
            "UID:\(escapeICSText(eventUID))",
            "DTSTAMP:\(icsDateTimeFormatter.string(from: updatedAt))",
            "LAST-MODIFIED:\(icsDateTimeFormatter.string(from: updatedAt))",
            "SUMMARY:\(escapeICSText(event.subject.nilIfBlank ?? "Microsoft 365 event"))",
            "X-WORKING-CALENDAR-ID:\(escapeICSText(calendarID))",
            "X-WORKING-CALENDAR-TITLE:\(escapeICSText(calendar.name))",
            "X-WORKING-CALENDAR-COLOR:\(escapeICSText(calendar.colorHex))",
            "X-WORKING-CALENDAR-ALLOWS-EVENT-WRITE:\(calendar.allowsEventWrite ? "TRUE" : "FALSE")",
            "X-WORKING-CALENDAR-ALLOWS-RESPONSES:\(calendar.allowsResponses ? "TRUE" : "FALSE")",
            "X-WORKING-REMOTE-OBJECT-URL:\(escapeICSText(remoteObjectURL))"
        ]
        if let changeKey = event.changeKey.nilIfBlank {
            lines.append("X-WORKING-REMOTE-ETAG:\(escapeICSText(changeKey))")
        }

        if let createdAt = event.createdDate {
            lines.append("CREATED:\(icsDateTimeFormatter.string(from: createdAt))")
        }

        lines.append(start)
        lines.append(end)
        if let masterEvent,
           let recurrenceID = recurrenceExceptionLine(prefix: "RECURRENCE-ID", occurrence: event, masterEvent: masterEvent) {
            lines.append(recurrenceID)
        }
        if event.privacy != .public {
            lines.append("CLASS:\(event.privacy.icsClass)")
        }
        if event.eventImportance != .normal {
            lines.append("PRIORITY:\(event.eventImportance.icsPriority)")
        }
        if !event.eventCategories.isEmpty {
            lines.append("CATEGORIES:\(event.eventCategories.map(escapeICSText).joined(separator: ","))")
        }
        if let eventStatus = icsEventStatus(forShowAs: event.showAs) {
            lines.append("STATUS:\(eventStatus)")
        }
        lines.append("TRANSP:\(event.showAs == "free" ? "TRANSPARENT" : "OPAQUE")")
        lines.append(contentsOf: alarmLines(
            reminderOffsets: event.reminderOffsets,
            title: event.subject.nilIfBlank ?? "Microsoft 365 event"
        ))

        if let organizer = event.organizer?.emailAddress,
           organizer.address.nilIfBlank != nil || organizer.name.nilIfBlank != nil {
            var params: [String] = []
            if let name = organizer.name.nilIfBlank {
                params.append("CN=\"\(escapeICSParameter(name))\"")
            }
            lines.append("ORGANIZER\(params.isEmpty ? "" : ";\(params.joined(separator: ";"))"):\(mailtoValue(email: organizer.address, fallbackName: organizer.name))")
        }

        for attendee in event.attendees ?? [] {
            let emailAddress = attendee.emailAddress
            guard emailAddress.address.nilIfBlank != nil || emailAddress.name.nilIfBlank != nil else { continue }
            var params = [
                "PARTSTAT=\(partStat(for: attendee.status?.response))",
                attendee.type == "optional" ? "ROLE=OPT-PARTICIPANT" : "ROLE=REQ-PARTICIPANT"
            ]
            if attendee.type == "resource" {
                params.append("CUTYPE=RESOURCE")
            } else if event.responseRequested == true {
                params.append("RSVP=TRUE")
            }
            if graphAttendeeMatchesCurrentUser(attendee, account: account) {
                params.append("X-WORKING-CURRENT-USER=TRUE")
            }
            if let name = emailAddress.name.nilIfBlank {
                params.append("CN=\"\(escapeICSParameter(name))\"")
            }
            lines.append("ATTENDEE;\(params.joined(separator: ";")):\(mailtoValue(email: emailAddress.address, fallbackName: emailAddress.name))")
        }

        lines.append("X-WORKING-MY-RESPONSE:\(myResponseStatus(for: event, account: account).rawValue)")

        if let location = locationText(for: event) {
            lines.append("LOCATION:\(escapeICSText(location))")
        }
        if let notes = event.body?.normalizedContent {
            lines.append("DESCRIPTION:\(escapeICSText(notes))")
        }
        lines.append(contentsOf: microsoftGraphAttachmentLines(event.attachments))
        lines.append(contentsOf: microsoftGraphRelationshipLines(event.relatedEvents))
        if let geoCoordinate = event.geoCoordinate {
            lines.append("GEO:\(geoFloatString(geoCoordinate.latitude));\(geoFloatString(geoCoordinate.longitude))")
        }
        if let urlString = event.bestJoinURLString {
            lines.append("URL:\(escapeICSText(urlString))")
        }
        if let recurrenceLine = recurrenceLine(for: event.recurrence) {
            lines.append(recurrenceLine)
        }
        for cancelledOccurrenceID in event.cancelledOccurrences ?? [] {
            if let exdate = recurrenceExceptionLine(
                prefix: "EXDATE",
                occurrenceID: cancelledOccurrenceID,
                masterEvent: event
            ) {
                lines.append(exdate)
            }
        }

        lines.append("END:VEVENT")
        return lines
    }

    private func calendarText(calendar: MicrosoftGraphCalendarInfo, eventLines: [[String]]) -> String {
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Working Calendar//Microsoft Graph//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
            "X-WR-CALNAME:\(escapeICSText(calendar.name))"
        ]
        lines.append(contentsOf: eventLines.flatMap { $0 })
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private func locationText(for event: MicrosoftGraphEvent) -> String? {
        var values: [String] = []
        var seen: Set<String> = []

        func add(_ value: String?) {
            guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !normalized.isEmpty else { return }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { return }
            values.append(normalized)
        }

        add(event.location?.displayName)
        for location in event.locations ?? [] {
            add(location.displayName)
        }

        return values.isEmpty ? nil : values.joined(separator: "; ")
    }

    private func microsoftGraphAttachmentLines(_ attachments: [MicrosoftGraphAttachment]?) -> [String] {
        (attachments ?? []).compactMap { attachment in
            guard attachment.isInline != true,
                  let sourceURL = attachment.sourceUrl.nilIfBlank else {
                return nil
            }
            var params = ["VALUE=URI"]
            if let contentType = attachment.contentType.nilIfBlank {
                params.append("FMTTYPE=\(escapeICSParameter(contentType))")
            }
            if let name = attachment.name.nilIfBlank {
                params.append("X-FILENAME=\"\(escapeICSParameter(name))\"")
            }
            return "ATTACH;\(params.joined(separator: ";")):\(escapeICSText(sourceURL))"
        }
    }

    private func microsoftGraphRelationshipLines(_ relationships: [LocalEventRelationship]) -> [String] {
        normalizedEventRelationships(relationships).map { relationship in
            "RELATED-TO;RELTYPE=\(escapeICSParameter(relationship.relationType)):\(escapeICSText(relationship.externalUID))"
        }
    }

    func putEvent(
        _ event: LocalCalendarEvent,
        localCalendar: LocalCalendar,
        account: CalendarProviderAccount
    ) async throws -> MicrosoftGraphWriteResult {
        let target = try remoteTarget(for: event, localCalendar: localCalendar, account: account)
        let response: MicrosoftGraphEventWriteResponse
        if let eventID = target.eventID {
            let requestBody = try graphWriteRequest(from: event)
            let encodedBody = try JSONEncoder().encode(requestBody)
            let url = try eventURL(account: account, calendarID: target.calendarID, eventID: eventID)
            response = try await jsonRequest(
                account: account,
                url: url,
                method: "PATCH",
                body: encodedBody,
                headers: conditionalHeaders(remoteETag: event.remoteETag)
            )
        } else {
            let requestBody = try graphWriteRequest(
                from: event,
                transactionID: microsoftGraphTransactionID(for: event),
                encodesNilRecurrence: false
            )
            let encodedBody = try JSONEncoder().encode(requestBody)
            let url = try eventsURL(account: account, calendarID: target.calendarID, queryItems: [])
            response = try await jsonRequest(account: account, url: url, method: "POST", body: encodedBody)
        }

        let remoteEventID = response.id.nilIfBlank ?? target.eventID ?? event.id
        try await writeMissingReferenceAttachments(
            event.attachments,
            account: account,
            calendarID: target.calendarID,
            eventID: remoteEventID,
            existingAttachments: target.eventID == nil ? [] : nil
        )
        try await writeWorkingCalendarOpenExtension(
            relatedEvents: event.relatedEvents,
            geoCoordinate: event.geoCoordinate,
            account: account,
            calendarID: target.calendarID,
            eventID: remoteEventID
        )
        try await writeRecurringExceptionState(
            for: event,
            account: account,
            calendarID: target.calendarID,
            eventID: remoteEventID
        )

        return MicrosoftGraphWriteResult(
            remoteObjectURLString: remoteObjectURLString(
                account: account,
                calendarID: target.calendarID,
                eventID: remoteEventID
            ),
            remoteETag: response.changeKey ?? ""
        )
    }

    func respondToEvent(
        account: CalendarProviderAccount,
        remoteObjectURLString: String,
        response: CalendarEventResponse,
        occurrenceStartDate: Date? = nil,
        occurrenceIsAllDay: Bool = false,
        occurrenceTimeZoneIdentifier: String? = nil
    ) async throws -> String? {
        guard let target = remoteTarget(from: remoteObjectURLString, account: account),
              let eventID = target.eventID
        else {
            throw MicrosoftGraphCalendarClientError.remoteObjectMissing
        }

        let action: String
        switch response {
        case .accept:
            action = "accept"
        case .maybe:
            action = "tentativelyAccept"
        case .decline:
            action = "decline"
        }

        let body = try JSONEncoder().encode(MicrosoftGraphResponseRequest(comment: "", sendResponse: true))
        let targetEventID = try await targetEventIDForOccurrenceResponse(
            account: account,
            calendarID: target.calendarID,
            eventID: eventID,
            occurrenceStartDate: occurrenceStartDate,
            occurrenceIsAllDay: occurrenceIsAllDay,
            occurrenceTimeZoneIdentifier: occurrenceTimeZoneIdentifier
        )
        let url = try actionURL(account: account, calendarID: target.calendarID, eventID: targetEventID, action: action)
        try await emptyRequest(account: account, url: url, method: "POST", body: body)
        guard targetEventID == eventID else { return nil }

        let refreshedURL = try eventURL(account: account, calendarID: target.calendarID, eventID: eventID)
        let refreshed: MicrosoftGraphEventWriteResponse? = try? await jsonRequest(
            account: account,
            url: refreshedURL,
            method: "GET",
            body: nil
        )
        return refreshed?.changeKey
    }

    func deleteEvent(account: CalendarProviderAccount, remoteObjectURLString: String, remoteETag: String = "") async throws {
        guard let target = remoteTarget(from: remoteObjectURLString, account: account),
              let eventID = target.eventID
        else {
            throw MicrosoftGraphCalendarClientError.remoteObjectMissing
        }

        let url = try eventURL(account: account, calendarID: target.calendarID, eventID: eventID)
        try await emptyRequest(
            account: account,
            url: url,
            method: "DELETE",
            body: nil,
            headers: conditionalHeaders(remoteETag: remoteETag)
        )
    }

    func remoteObjectURLString(event: MicrosoftGraphEvent, calendar: MicrosoftGraphCalendarInfo, account: CalendarProviderAccount) -> String {
        remoteObjectURLString(account: account, calendarID: calendar.id, eventID: event.id)
    }

    func isCalendarID(_ calendarID: String, ownedBy account: CalendarProviderAccount) -> Bool {
        calendarID.hasPrefix(localCalendarIDPrefix(for: account))
    }

    func localCalendarIDPrefix(for account: CalendarProviderAccount) -> String {
        "local-calendar-microsoft365-\(account.id)-"
    }

    static func workingCalendarExtensionNamePreview() -> String {
        workingCalendarOpenExtensionName
    }

    func graphPaginationValidationCountPreview(pageURLs: [URL]) throws -> Int {
        var seenPageURLs: Set<String> = []
        var pageCount = 0
        for pageURL in pageURLs {
            try validateGraphPage(pageURL, seenPageURLs: &seenPageURLs, pageCount: &pageCount)
        }
        return pageCount
    }

    private func fetchCalendars(account: CalendarProviderAccount) async throws -> [MicrosoftGraphCalendarInfo] {
        var calendars: [MicrosoftGraphCalendarInfo] = []
        var nextURL: URL? = try apiURL(
            account: account,
            path: ["me", "calendars"],
            queryItems: [
                URLQueryItem(name: "$select", value: "id,name,color,canEdit")
            ]
        )
        var seenPageURLs: Set<String> = []
        var pageCount = 0

        while let url = nextURL {
            try validateGraphPage(url, seenPageURLs: &seenPageURLs, pageCount: &pageCount)
            let response: MicrosoftGraphCollection<MicrosoftGraphCalendarResource> = try await jsonRequest(
                account: account,
                url: url,
                method: "GET",
                body: nil
            )
            calendars.append(contentsOf: response.value.compactMap { calendar in
                guard let id = calendar.id.nilIfBlank else { return nil }
                return MicrosoftGraphCalendarInfo(
                    id: id,
                    name: calendar.name.nilIfBlank ?? "Microsoft 365 Calendar",
                    colorHex: colorHex(for: calendar.color),
                    canEdit: calendar.canEdit ?? true
                )
            })
            nextURL = response.nextLink.flatMap(URL.init(string:))
        }

        return calendars
    }

    private func fetchEvents(
        account: CalendarProviderAccount,
        calendarID: String,
        startDate: Date,
        endDate: Date
    ) async throws -> MicrosoftGraphEventsFetchResult {
        let firstURL = try calendarViewDeltaURL(
            account: account,
            calendarID: calendarID,
            startDate: startDate,
            endDate: endDate
        )
        return try await fetchDeltaEvents(account: account, firstURL: firstURL)
    }

    func calendarViewDeltaURLPreview(
        account: CalendarProviderAccount,
        calendarID: String,
        startDate: Date,
        endDate: Date
    ) throws -> URL {
        try calendarViewDeltaURL(
            account: account,
            calendarID: calendarID,
            startDate: startDate,
            endDate: endDate
        )
    }

    private func calendarViewDeltaURL(
        account: CalendarProviderAccount,
        calendarID: String,
        startDate: Date,
        endDate: Date
    ) throws -> URL {
        try apiURL(
            account: account,
            path: ["me", "calendars", calendarID, "calendarView", "delta"],
            queryItems: [
                URLQueryItem(name: "startDateTime", value: rfc3339Formatter.string(from: startDate)),
                URLQueryItem(name: "endDateTime", value: rfc3339Formatter.string(from: endDate))
            ]
        )
    }

    private func fetchDeltaEvents(account: CalendarProviderAccount, firstURL: URL) async throws -> MicrosoftGraphEventsFetchResult {
        var events: [MicrosoftGraphEvent] = []
        var nextURL: URL? = firstURL
        var deltaLink: String?
        var seenPageURLs: Set<String> = []
        var pageCount = 0

        while let url = nextURL {
            try validateGraphPage(url, seenPageURLs: &seenPageURLs, pageCount: &pageCount)
            let response: MicrosoftGraphCollection<MicrosoftGraphEvent> = try await jsonRequest(
                account: account,
                url: url,
                method: "GET",
                body: nil
            )
            events.append(contentsOf: response.value)
            nextURL = response.nextLink.flatMap(URL.init(string:))
            deltaLink = response.deltaLink.nilIfBlank ?? deltaLink
        }

        return MicrosoftGraphEventsFetchResult(events: events, deltaLink: deltaLink ?? firstURL.absoluteString)
    }

    private func fetchFullCalendarPayload(
        account: CalendarProviderAccount,
        calendar: MicrosoftGraphCalendarInfo,
        startDate: Date,
        endDate: Date
    ) async throws -> MicrosoftGraphCalendarPayload {
        let result = try await fetchEvents(
            account: account,
            calendarID: calendar.id,
            startDate: startDate,
            endDate: endDate
        )
        let visibleSeriesMasterIDs = try? await fetchCalendarViewSeriesMasterIDs(
            account: account,
            calendarID: calendar.id,
            startDate: startDate,
            endDate: endDate
        )
        let events = try await detailedEventsForImport(
            result.events,
            account: account,
            calendarID: calendar.id,
            visibleSeriesMasterIDs: visibleSeriesMasterIDs,
            importWindow: DateInterval(start: startDate, end: endDate),
            includeUnboundedSeriesMasters: false
        )
        return MicrosoftGraphCalendarPayload(
            calendar: calendar,
            events: events,
            deletedRemoteObjectURLs: deletedRemoteObjectURLs(
                from: result.events,
                calendar: calendar,
                account: account
            ),
            cancelledDetachedOccurrenceRemoteObjectURLs: cancelledDetachedOccurrenceRemoteObjectURLStringsForEvents(
                events: result.events,
                calendar: calendar,
                account: account
            ),
            cancelledRemoteOccurrences: cancelledRemoteOccurrencesForEvents(
                events: result.events,
                calendar: calendar,
                account: account
            ),
            isIncremental: false,
            deltaLink: result.deltaLink,
            windowStartDate: startDate,
            windowEndDate: endDate
        )
    }

    private func fetchIncrementalCalendarPayload(
        account: CalendarProviderAccount,
        calendar: MicrosoftGraphCalendarInfo,
        deltaURL: URL,
        syncedWindowStartDate: Date,
        syncedWindowEndDate: Date,
        startDate: Date,
        endDate: Date
    ) async throws -> MicrosoftGraphCalendarPayload {
        let result = try await fetchDeltaEvents(account: account, firstURL: deltaURL)
        let events = try await detailedEventsForImport(
            result.events,
            account: account,
            calendarID: calendar.id,
            importWindow: DateInterval(start: startDate, end: endDate),
            includeUnboundedSeriesMasters: true
        )
        return MicrosoftGraphCalendarPayload(
            calendar: calendar,
            events: events,
            deletedRemoteObjectURLs: deletedRemoteObjectURLs(
                from: result.events,
                calendar: calendar,
                account: account
            ),
            cancelledDetachedOccurrenceRemoteObjectURLs: cancelledDetachedOccurrenceRemoteObjectURLStringsForEvents(
                events: result.events,
                calendar: calendar,
                account: account
            ),
            cancelledRemoteOccurrences: cancelledRemoteOccurrencesForEvents(
                events: result.events,
                calendar: calendar,
                account: account
            ),
            isIncremental: true,
            deltaLink: result.deltaLink,
            windowStartDate: syncedWindowStartDate,
            windowEndDate: syncedWindowEndDate
        )
    }

    private func detailedEventsForImport(
        _ events: [MicrosoftGraphEvent],
        account: CalendarProviderAccount,
        calendarID: String,
        visibleSeriesMasterIDs: Set<String>? = nil,
        importWindow: DateInterval? = nil,
        includeUnboundedSeriesMasters: Bool = true
    ) async throws -> [MicrosoftGraphEvent] {
        var detailedEvents: [MicrosoftGraphEvent] = []
        let importCandidates = events.filter {
            shouldImport(
                $0,
                importWindow: importWindow,
                visibleSeriesMasterIDs: visibleSeriesMasterIDs,
                includeUnboundedSeriesMasters: includeUnboundedSeriesMasters
            )
        }
        let masterIDsInResponse = Set(importCandidates.filter { $0.isSeriesMaster }.map(\.id))

        for event in importCandidates {
            do {
                let detailed = try await fetchEventDetails(
                    account: account,
                    calendarID: calendarID,
                    eventID: event.id
                )
                if detailed.isSeriesMaster {
                    detailedEvents.append(try await fetchSeriesMasterDetails(
                        account: account,
                        calendarID: calendarID,
                        eventID: event.id
                    ))
                } else {
                    detailedEvents.append(detailed)
                }
            } catch {
                detailedEvents.append(event)
            }
        }

        let missingMasterIDs = Set(importCandidates.compactMap { event in
            event.seriesMasterId.nilIfBlank.flatMap { masterIDsInResponse.contains($0) ? nil : $0 }
        }).union((visibleSeriesMasterIDs ?? []).subtracting(masterIDsInResponse))
        for masterID in missingMasterIDs {
            do {
                detailedEvents.append(try await fetchSeriesMasterDetails(
                    account: account,
                    calendarID: calendarID,
                    eventID: masterID
                ))
            } catch {
                continue
            }
        }

        return detailedEvents
    }

    private func shouldImport(
        _ event: MicrosoftGraphEvent,
        importWindow: DateInterval?,
        visibleSeriesMasterIDs: Set<String>?,
        includeUnboundedSeriesMasters: Bool
    ) -> Bool {
        guard event.shouldImport else { return false }
        guard let importWindow else { return true }

        if event.isSeriesMaster {
            if includeUnboundedSeriesMasters || visibleSeriesMasterIDs == nil {
                return true
            }
            if visibleSeriesMasterIDs?.contains(event.id) == true {
                return true
            }
            return eventOverlaps(event, importWindow: importWindow)
        }

        return eventOverlaps(event, importWindow: importWindow)
    }

    private func eventOverlaps(_ event: MicrosoftGraphEvent, importWindow: DateInterval) -> Bool {
        guard let start = event.start?.resolvedDate else { return false }
        let end = event.end?.resolvedDate ?? start
        let effectiveEnd = end > start ? end : start.addingTimeInterval(60)
        return start < importWindow.end && effectiveEnd > importWindow.start
    }

    private func fetchCalendarViewSeriesMasterIDs(
        account: CalendarProviderAccount,
        calendarID: String,
        startDate: Date,
        endDate: Date
    ) async throws -> Set<String> {
        var masterIDs: Set<String> = []
        var nextURL: URL? = try apiURL(
            account: account,
            path: ["me", "calendars", calendarID, "calendarView"],
            queryItems: [
                URLQueryItem(name: "startDateTime", value: rfc3339Formatter.string(from: startDate)),
                URLQueryItem(name: "endDateTime", value: rfc3339Formatter.string(from: endDate)),
                URLQueryItem(name: "$top", value: "250"),
                URLQueryItem(name: "$select", value: "id,type,seriesMasterId,isCancelled")
            ]
        )
        var seenPageURLs: Set<String> = []
        var pageCount = 0

        while let url = nextURL {
            try validateGraphPage(url, seenPageURLs: &seenPageURLs, pageCount: &pageCount)
            let response: MicrosoftGraphCollection<MicrosoftGraphEvent> = try await jsonRequest(
                account: account,
                url: url,
                method: "GET",
                body: nil
            )
            for event in response.value where event.isCancelled != true {
                if let seriesMasterID = event.seriesMasterId.nilIfBlank {
                    masterIDs.insert(seriesMasterID)
                } else if event.isSeriesMaster {
                    masterIDs.insert(event.id)
                }
            }
            nextURL = response.nextLink.flatMap(URL.init(string:))
        }

        return masterIDs
    }

    private func deletedRemoteObjectURLs(
        from events: [MicrosoftGraphEvent],
        calendar: MicrosoftGraphCalendarInfo,
        account: CalendarProviderAccount
    ) -> Set<String> {
        deletedRemoteObjectURLStringsForEvents(events: events, calendar: calendar, account: account)
    }

    func deletedRemoteObjectURLStringsForEvents(
        events: [MicrosoftGraphEvent],
        calendar: MicrosoftGraphCalendarInfo,
        account: CalendarProviderAccount
    ) -> Set<String> {
        Set(events.compactMap { event in
            guard event.isRemoteRemoval
                    || (event.isCancelled == true && event.seriesMasterId.nilIfBlank == nil)
            else {
                return nil
            }
            return remoteObjectURLString(event: event, calendar: calendar, account: account)
        })
    }

    func cancelledDetachedOccurrenceRemoteObjectURLStringsForEvents(
        events: [MicrosoftGraphEvent],
        calendar: MicrosoftGraphCalendarInfo,
        account: CalendarProviderAccount
    ) -> Set<String> {
        Set(events.compactMap { event in
            guard !event.isRemoteRemoval,
                  event.isCancelled == true,
                  event.seriesMasterId.nilIfBlank != nil
            else {
                return nil
            }
            return remoteObjectURLString(event: event, calendar: calendar, account: account)
        })
    }

    func cancelledRemoteOccurrencesForEvents(
        events: [MicrosoftGraphEvent],
        calendar: MicrosoftGraphCalendarInfo,
        account: CalendarProviderAccount
    ) -> Set<LocalProviderRemoteOccurrenceCancellation> {
        Set(events.compactMap { event in
            guard !event.isRemoteRemoval,
                  event.isCancelled == true,
                  let seriesMasterID = event.seriesMasterId.nilIfBlank,
                  let occurrenceStartDate = remoteOccurrenceStartDate(forCancelledOccurrence: event)
            else {
                return nil
            }
            return LocalProviderRemoteOccurrenceCancellation(
                masterRemoteObjectURLString: remoteObjectURLString(
                    account: account,
                    calendarID: calendar.id,
                    eventID: seriesMasterID
                ),
                occurrenceStartDate: occurrenceStartDate
            )
        })
    }

    private func fetchEventDetails(
        account: CalendarProviderAccount,
        calendarID: String,
        eventID: String
    ) async throws -> MicrosoftGraphEvent {
        let url = try eventURL(
            account: account,
            calendarID: calendarID,
            eventID: eventID,
            queryItems: [
                URLQueryItem(name: "$select", value: Self.eventDetailsSelectFields),
                URLQueryItem(name: "$expand", value: Self.eventDetailsExpandFields)
            ]
        )
        return try await jsonRequest(account: account, url: url, method: "GET", body: nil)
    }

    private func fetchSeriesMasterDetails(
        account: CalendarProviderAccount,
        calendarID: String,
        eventID: String
    ) async throws -> MicrosoftGraphEvent {
        let url = try eventURL(
            account: account,
            calendarID: calendarID,
            eventID: eventID,
            queryItems: [
                URLQueryItem(name: "$select", value: Self.eventDetailsSelectFields),
                URLQueryItem(name: "$expand", value: Self.seriesMasterDetailsExpandFields)
            ]
        )
        let master: MicrosoftGraphEvent = try await jsonRequest(account: account, url: url, method: "GET", body: nil)
        return try await seriesMasterWithDetailedExceptionOccurrences(
            master,
            account: account,
            calendarID: calendarID
        )
    }

    private func seriesMasterWithDetailedExceptionOccurrences(
        _ master: MicrosoftGraphEvent,
        account: CalendarProviderAccount,
        calendarID: String
    ) async throws -> MicrosoftGraphEvent {
        guard let exceptions = master.exceptionOccurrences,
              !exceptions.isEmpty else {
            return master
        }

        var detailedExceptions: [MicrosoftGraphEvent] = []
        for exception in exceptions {
            do {
                detailedExceptions.append(try await fetchEventDetails(
                    account: account,
                    calendarID: calendarID,
                    eventID: exception.id
                ))
            } catch {
                detailedExceptions.append(exception)
            }
        }

        return seriesMaster(master, replacingExceptionOccurrencesWith: detailedExceptions)
    }

    func seriesMasterExceptionMergePreview(
        master: MicrosoftGraphEvent,
        detailedExceptions: [MicrosoftGraphEvent]
    ) -> MicrosoftGraphEvent {
        seriesMaster(master, replacingExceptionOccurrencesWith: detailedExceptions)
    }

    private func seriesMaster(
        _ master: MicrosoftGraphEvent,
        replacingExceptionOccurrencesWith detailedExceptions: [MicrosoftGraphEvent]
    ) -> MicrosoftGraphEvent {
        guard let exceptions = master.exceptionOccurrences,
              !exceptions.isEmpty else {
            return master
        }

        let detailedByID = Dictionary(uniqueKeysWithValues: detailedExceptions.map { ($0.id, $0) })
        var detailedMaster = master
        detailedMaster.exceptionOccurrences = exceptions.map { detailedByID[$0.id] ?? $0 }
        return detailedMaster
    }

    private func fetchInstances(
        account: CalendarProviderAccount,
        calendarID: String,
        eventID: String,
        startDate: Date,
        endDate: Date
        ) async throws -> [MicrosoftGraphEvent] {
        var instances: [MicrosoftGraphEvent] = []
        var nextURL: URL? = try eventInstancesURL(
            account: account,
            calendarID: calendarID,
            eventID: eventID,
            queryItems: [
                URLQueryItem(name: "startDateTime", value: rfc3339Formatter.string(from: startDate)),
                URLQueryItem(name: "endDateTime", value: rfc3339Formatter.string(from: endDate)),
                URLQueryItem(name: "$top", value: "250"),
                URLQueryItem(name: "$select", value: [
                    "id",
                    "changeKey",
                    "subject",
                    "start",
                    "end",
                    "isAllDay",
                    "type",
                    "seriesMasterId",
                    "originalStart",
                    "occurrenceId"
                ].joined(separator: ","))
            ]
        )
        var seenPageURLs: Set<String> = []
        var pageCount = 0

        while let url = nextURL {
            try validateGraphPage(url, seenPageURLs: &seenPageURLs, pageCount: &pageCount)
            let response: MicrosoftGraphCollection<MicrosoftGraphEvent> = try await jsonRequest(
                account: account,
                url: url,
                method: "GET",
                body: nil
            )
            instances.append(contentsOf: response.value)
            nextURL = response.nextLink.flatMap(URL.init(string:))
        }

        return instances
    }

    private func writeRecurringExceptionState(
        for event: LocalCalendarEvent,
        account: CalendarProviderAccount,
        calendarID: String,
        eventID: String
    ) async throws {
        guard event.isRecurring,
              !event.detachedOccurrences.isEmpty || !event.excludedOccurrenceStartDates.isEmpty
        else {
            return
        }

        let originalStarts = (event.detachedOccurrences.map(\.originalStartDate) + event.excludedOccurrenceStartDates).sorted()
        let startDate = (originalStarts.first ?? event.startDate).addingTimeInterval(-48 * 3600)
        let endDate = (originalStarts.last ?? event.endDate).addingTimeInterval(48 * 3600)
        let instances = try await fetchInstances(
            account: account,
            calendarID: calendarID,
            eventID: eventID,
            startDate: startDate,
            endDate: endDate
        )
        let targets = try recurringExceptionWriteTargets(for: event, instances: instances)

        for target in targets.occurrencesToDelete {
            let url = try eventURL(account: account, calendarID: calendarID, eventID: target.eventID)
            try await emptyRequest(
                account: account,
                url: url,
                method: "DELETE",
                body: nil,
                headers: conditionalHeaders(remoteETag: target.remoteETag)
            )
        }

        for target in targets.detachedOccurrencesToPatch {
            let body = try JSONEncoder().encode(try graphWriteRequest(from: target.occurrence))
            let url = try eventURL(account: account, calendarID: calendarID, eventID: target.eventID)
            let _: MicrosoftGraphEventWriteResponse = try await jsonRequest(
                account: account,
                url: url,
                method: "PATCH",
                body: body,
                headers: conditionalHeaders(remoteETag: target.remoteETag)
            )
            try await writeMissingReferenceAttachments(
                target.occurrence.attachments,
                account: account,
                calendarID: calendarID,
                eventID: target.eventID
            )
            try await writeWorkingCalendarOpenExtension(
                relatedEvents: target.occurrence.relatedEvents,
                geoCoordinate: target.occurrence.geoCoordinate,
                account: account,
                calendarID: calendarID,
                eventID: target.eventID
            )
        }
    }

    func recurringExceptionWritePlanPreview(
        for event: LocalCalendarEvent,
        instances: [MicrosoftGraphEvent]
    ) throws -> MicrosoftGraphRecurringExceptionWritePlan {
        let targets = try recurringExceptionWriteTargets(for: event, instances: instances)
        return MicrosoftGraphRecurringExceptionWritePlan(
            occurrenceIDsToDelete: targets.occurrencesToDelete.map(\.eventID),
            occurrenceIDsToPatch: targets.detachedOccurrencesToPatch.map(\.eventID)
        )
    }

    private func recurringExceptionWriteTargets(
        for event: LocalCalendarEvent,
        instances: [MicrosoftGraphEvent]
    ) throws -> MicrosoftGraphRecurringExceptionWriteTargets {
        var occurrencesToDelete: [MicrosoftGraphOccurrenceDeleteTarget] = []
        var detachedOccurrencesToPatch: [MicrosoftGraphDetachedOccurrencePatchTarget] = []

        for occurrenceStart in event.excludedOccurrenceStartDates {
            guard let instance = instances.first(where: {
                originalStartMatches(
                    $0,
                    occurrenceStartDate: occurrenceStart,
                    occurrenceIsAllDay: event.isAllDay,
                    occurrenceTimeZoneIdentifier: event.timeZoneIdentifier
                ) == true
            }) else {
                continue
            }

            if instance.isCancelled != true {
                occurrencesToDelete.append(MicrosoftGraphOccurrenceDeleteTarget(
                    eventID: instance.id,
                    remoteETag: instance.changeKey ?? ""
                ))
            }
        }

        for occurrence in event.detachedOccurrences {
            guard let instance = instances.first(where: {
                originalStartMatches(
                    $0,
                    occurrenceStartDate: occurrence.originalStartDate,
                    occurrenceIsAllDay: event.isAllDay,
                    occurrenceTimeZoneIdentifier: event.timeZoneIdentifier
                ) == true
            }) else {
                throw MicrosoftGraphCalendarClientError.remoteObjectMissing
            }

            detachedOccurrencesToPatch.append(MicrosoftGraphDetachedOccurrencePatchTarget(
                eventID: instance.id,
                remoteETag: instance.changeKey ?? "",
                occurrence: occurrence
            ))
        }

        return MicrosoftGraphRecurringExceptionWriteTargets(
            occurrencesToDelete: occurrencesToDelete,
            detachedOccurrencesToPatch: detachedOccurrencesToPatch
        )
    }

    private func targetEventIDForOccurrenceResponse(
        account: CalendarProviderAccount,
        calendarID: String,
        eventID: String,
        occurrenceStartDate: Date?,
        occurrenceIsAllDay: Bool = false,
        occurrenceTimeZoneIdentifier: String?
    ) async throws -> String {
        guard let occurrenceStartDate else { return eventID }

        let instances = try await fetchInstances(
            account: account,
            calendarID: calendarID,
            eventID: eventID,
            startDate: occurrenceStartDate.addingTimeInterval(-48 * 3600),
            endDate: occurrenceStartDate.addingTimeInterval(48 * 3600)
        )
        guard let instance = instances.first(where: {
            originalStartMatches(
                $0,
                occurrenceStartDate: occurrenceStartDate,
                occurrenceIsAllDay: occurrenceIsAllDay,
                occurrenceTimeZoneIdentifier: occurrenceTimeZoneIdentifier
            )
        }) else {
            throw MicrosoftGraphCalendarClientError.remoteObjectMissing
        }
        return instance.id
    }

    private func graphWriteRequest(
        from event: LocalCalendarEvent,
        transactionID: String? = nil,
        encodesNilRecurrence: Bool = true
    ) throws -> MicrosoftGraphEventWriteRequest {
        let attendees = event.attendees.filter { !$0.isBlank }.map { attendee in
            MicrosoftGraphAttendeeWrite(
                emailAddress: MicrosoftGraphEmailAddress(name: attendee.name.nilIfBlank, address: attendee.email.nilIfBlank),
                type: graphAttendeeType(for: attendee)
            )
        }.filter { $0.emailAddress.name != nil || $0.emailAddress.address != nil }
        let start = graphDateTimeWrite(from: event.startDate, timeZoneIdentifier: event.timeZoneIdentifier)
        let end = graphDateTimeWrite(from: event.endDate, timeZoneIdentifier: event.timeZoneIdentifier)
        let writableCategories = microsoftGraphWritableCategories(from: event.categories)
        let reminderOffset = try microsoftGraphReminderOffset(from: event.reminderOffsets)
        let onlineMeetingProvider = transactionID == nil ? nil : microsoftGraphOnlineMeetingProviderMetadata(from: event.categories)

        return MicrosoftGraphEventWriteRequest(
            transactionId: transactionID,
            subject: event.title,
            body: graphBody(
                notes: event.notes,
                urlString: event.urlString,
                preservesOnlineMeetingBody: transactionID == nil && microsoftGraphShouldPreserveOnlineMeetingBody(urlString: event.urlString)
            ),
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            showAs: microsoftGraphShowAs(
                fromCategories: event.categories,
                status: event.status,
                availability: event.availability
            ),
            sensitivity: microsoftGraphSensitivity(fromCategories: event.categories, privacy: event.privacy),
            importance: event.importance.graphImportance,
            categories: writableCategories,
            isReminderOn: reminderOffset != nil,
            reminderMinutesBeforeStart: reminderOffset,
            isOnlineMeeting: onlineMeetingProvider != nil ? true : nil,
            onlineMeetingProvider: onlineMeetingProvider,
            hideAttendees: microsoftGraphHideAttendeesMetadata(from: event.categories),
            allowNewTimeProposals: microsoftGraphAllowNewTimeProposalsMetadata(from: event.categories),
            location: graphLocation(from: event.location, categories: event.categories),
            locations: graphLocations(from: event.location, categories: event.categories),
            responseRequested: graphResponseRequested(from: event.attendees),
            attendees: attendees,
            recurrence: try recurrence(for: event),
            encodesNilRecurrence: encodesNilRecurrence
        )
    }

    func encodedWritePayloadPreview(for event: LocalCalendarEvent) throws -> Data {
        try JSONEncoder().encode(graphWriteRequest(from: event))
    }

    func encodedInsertPayloadPreview(for event: LocalCalendarEvent, transactionID: String) throws -> Data {
        try JSONEncoder().encode(graphWriteRequest(from: event, transactionID: transactionID))
    }

    func encodedDetachedOccurrencePayloadPreview(for occurrence: LocalDetachedOccurrence) throws -> Data {
        try JSONEncoder().encode(try graphWriteRequest(from: occurrence))
    }

    func encodedReferenceAttachmentPayloadPreviews(
        for event: LocalCalendarEvent,
        existingAttachments: [MicrosoftGraphAttachment] = []
    ) throws -> [Data] {
        let writes = missingMicrosoftGraphReferenceAttachmentWrites(
            from: event.attachments,
            existingAttachments: existingAttachments
        )
        return try writes.map { try JSONEncoder().encode($0) }
    }

    func referenceAttachmentsURLPreview(
        account: CalendarProviderAccount,
        calendarID: String,
        eventID: String
    ) throws -> URL {
        try eventAttachmentsURL(account: account, calendarID: calendarID, eventID: eventID)
    }

    func encodedWorkingCalendarExtensionPayloadPreview(for event: LocalCalendarEvent) throws -> Data {
        try JSONEncoder().encode(workingCalendarOpenExtensionWrite(
            relatedEvents: event.relatedEvents,
            geoCoordinate: event.geoCoordinate
        ))
    }

    func encodedWorkingCalendarExtensionPayloadPreview(for occurrence: LocalDetachedOccurrence) throws -> Data {
        try JSONEncoder().encode(workingCalendarOpenExtensionWrite(
            relatedEvents: occurrence.relatedEvents,
            geoCoordinate: occurrence.geoCoordinate
        ))
    }

    func workingCalendarExtensionURLPreview(
        account: CalendarProviderAccount,
        calendarID: String,
        eventID: String
    ) throws -> URL {
        try eventOpenExtensionURL(account: account, calendarID: calendarID, eventID: eventID)
    }

    func allDayOccurrenceDateMatchesPreview(
        providerDatePrefix: String,
        occurrenceStartDate: Date,
        timeZoneIdentifier: String
    ) -> Bool {
        allDayProviderDate(
            providerDatePrefix,
            matches: occurrenceStartDate,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    private func graphWriteRequest(from occurrence: LocalDetachedOccurrence) throws -> MicrosoftGraphEventWriteRequest {
        let attendees = occurrence.attendees.filter { !$0.isBlank }.map { attendee in
            MicrosoftGraphAttendeeWrite(
                emailAddress: MicrosoftGraphEmailAddress(name: attendee.name.nilIfBlank, address: attendee.email.nilIfBlank),
                type: graphAttendeeType(for: attendee)
            )
        }.filter { $0.emailAddress.name != nil || $0.emailAddress.address != nil }
        let start = graphDateTimeWrite(from: occurrence.startDate, timeZoneIdentifier: occurrence.timeZoneIdentifier)
        let end = graphDateTimeWrite(from: occurrence.endDate, timeZoneIdentifier: occurrence.timeZoneIdentifier)
        let writableCategories = microsoftGraphWritableCategories(from: occurrence.categories)
        let reminderOffset = try microsoftGraphReminderOffset(from: occurrence.reminderOffsets)

        return MicrosoftGraphEventWriteRequest(
            transactionId: nil,
            subject: occurrence.title,
            body: graphBody(
                notes: occurrence.notes,
                urlString: occurrence.urlString,
                preservesOnlineMeetingBody: microsoftGraphShouldPreserveOnlineMeetingBody(urlString: occurrence.urlString)
            ),
            start: start,
            end: end,
            isAllDay: occurrence.isAllDay,
            showAs: microsoftGraphShowAs(
                fromCategories: occurrence.categories,
                status: occurrence.status,
                availability: occurrence.availability
            ),
            sensitivity: microsoftGraphSensitivity(fromCategories: occurrence.categories, privacy: occurrence.privacy),
            importance: occurrence.importance.graphImportance,
            categories: writableCategories,
            isReminderOn: reminderOffset != nil,
            reminderMinutesBeforeStart: reminderOffset,
            isOnlineMeeting: nil,
            onlineMeetingProvider: nil,
            hideAttendees: microsoftGraphHideAttendeesMetadata(from: occurrence.categories),
            allowNewTimeProposals: microsoftGraphAllowNewTimeProposalsMetadata(from: occurrence.categories),
            location: graphLocation(from: occurrence.location, categories: occurrence.categories),
            locations: graphLocations(from: occurrence.location, categories: occurrence.categories),
            responseRequested: graphResponseRequested(from: occurrence.attendees),
            attendees: attendees,
            recurrence: nil,
            encodesNilRecurrence: false
        )
    }

    private func microsoftGraphReminderOffset(from reminderOffsets: [Int]) throws -> Int? {
        let normalizedOffsets = normalizedReminderOffsets(reminderOffsets)
        guard normalizedOffsets.count <= 1 else {
            throw MicrosoftGraphCalendarClientError.unsupportedMultipleReminders(normalizedOffsets)
        }
        return normalizedOffsets.first
    }

    private func writeMissingReferenceAttachments(
        _ attachments: [LocalEventAttachment],
        account: CalendarProviderAccount,
        calendarID: String,
        eventID: String,
        existingAttachments: [MicrosoftGraphAttachment]? = nil
    ) async throws {
        guard !normalizedEventAttachments(attachments).isEmpty else { return }
        let currentAttachments: [MicrosoftGraphAttachment]
        if let existingAttachments {
            currentAttachments = existingAttachments
        } else {
            currentAttachments = try await fetchEventAttachments(
                account: account,
                calendarID: calendarID,
                eventID: eventID
            )
        }
        let missing = missingMicrosoftGraphReferenceAttachmentWrites(
            from: attachments,
            existingAttachments: currentAttachments
        )
        guard !missing.isEmpty else { return }

        let url = try eventAttachmentsURL(account: account, calendarID: calendarID, eventID: eventID)
        for attachment in missing {
            let body = try JSONEncoder().encode(attachment)
            let _: MicrosoftGraphAttachment = try await jsonRequest(
                account: account,
                url: url,
                method: "POST",
                body: body
            )
        }
    }

    private func fetchEventAttachments(
        account: CalendarProviderAccount,
        calendarID: String,
        eventID: String
    ) async throws -> [MicrosoftGraphAttachment] {
        var attachments: [MicrosoftGraphAttachment] = []
        var nextURL: URL? = try eventAttachmentsURL(
            account: account,
            calendarID: calendarID,
            eventID: eventID,
            queryItems: [
                URLQueryItem(name: "$select", value: Self.eventAttachmentSelectFields)
            ]
        )
        var seenPageURLs: Set<String> = []
        var pageCount = 0

        while let url = nextURL {
            try validateGraphPage(url, seenPageURLs: &seenPageURLs, pageCount: &pageCount)
            let response: MicrosoftGraphCollection<MicrosoftGraphAttachment> = try await jsonRequest(
                account: account,
                url: url,
                method: "GET",
                body: nil
            )
            attachments.append(contentsOf: response.value)
            nextURL = response.nextLink.flatMap(URL.init(string:))
        }

        return attachments
    }

    private func missingMicrosoftGraphReferenceAttachmentWrites(
        from attachments: [LocalEventAttachment],
        existingAttachments: [MicrosoftGraphAttachment]
    ) -> [MicrosoftGraphReferenceAttachmentWrite] {
        let existingSourceURLs = Set(
            existingAttachments
                .compactMap(\.sourceUrl.nilIfBlank)
                .map(referenceAttachmentURLKey)
        )
        return microsoftGraphReferenceAttachmentWrites(from: attachments).filter {
            !existingSourceURLs.contains(referenceAttachmentURLKey($0.sourceUrl))
        }
    }

    private func microsoftGraphReferenceAttachmentWrites(
        from attachments: [LocalEventAttachment]
    ) -> [MicrosoftGraphReferenceAttachmentWrite] {
        normalizedEventAttachments(attachments).compactMap { attachment in
            guard let sourceURL = attachment.urlString.nilIfBlank else { return nil }
            return MicrosoftGraphReferenceAttachmentWrite(
                name: microsoftGraphReferenceAttachmentName(for: attachment),
                contentType: attachment.formatType.nilIfBlank,
                sourceUrl: sourceURL
            )
        }
    }

    private func microsoftGraphReferenceAttachmentName(for attachment: LocalEventAttachment) -> String {
        if let displayName = attachment.displayName.nilIfBlank {
            return displayName
        }
        if let url = URL(string: attachment.urlString),
           let lastPathComponent = url.lastPathComponent.removingPercentEncoding?.nilIfBlank {
            return lastPathComponent
        }
        if let host = URL(string: attachment.urlString)?.host?.nilIfBlank {
            return host
        }
        return "Attachment"
    }

    private func referenceAttachmentURLKey(_ urlString: String) -> String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func writeWorkingCalendarOpenExtension(
        relatedEvents: [LocalEventRelationship],
        geoCoordinate: LocalEventGeoCoordinate?,
        account: CalendarProviderAccount,
        calendarID: String,
        eventID: String
    ) async throws {
        let payload = workingCalendarOpenExtensionWrite(relatedEvents: relatedEvents, geoCoordinate: geoCoordinate)
        let body = try JSONEncoder().encode(payload)
        let patchURL = try eventOpenExtensionURL(account: account, calendarID: calendarID, eventID: eventID)
        do {
            try await emptyRequest(account: account, url: patchURL, method: "PATCH", body: body)
        } catch MicrosoftGraphCalendarClientError.httpStatus(let status, _, _) where status == 404 {
            guard payload.hasLocalMetadata else { return }
            let postURL = try eventExtensionsURL(account: account, calendarID: calendarID, eventID: eventID)
            try await emptyRequest(account: account, url: postURL, method: "POST", body: body)
        }
    }

    private func workingCalendarOpenExtensionWrite(
        relatedEvents: [LocalEventRelationship],
        geoCoordinate: LocalEventGeoCoordinate?
    ) -> MicrosoftGraphWorkingCalendarExtensionWrite {
        MicrosoftGraphWorkingCalendarExtensionWrite(
            extensionName: Self.workingCalendarOpenExtensionName,
            relatedEventsJSON: Self.microsoftGraphEncodedRelatedEvents(relatedEvents) ?? "[]",
            geoCoordinateJSON: Self.microsoftGraphEncodedGeoCoordinate(geoCoordinate) ?? ""
        )
    }

    fileprivate static func microsoftGraphEncodedRelatedEvents(_ relationships: [LocalEventRelationship]) -> String? {
        let normalizedRelationships = normalizedEventRelationships(relationships)
        guard !normalizedRelationships.isEmpty,
              let data = try? JSONEncoder().encode(normalizedRelationships) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    fileprivate static func microsoftGraphEncodedGeoCoordinate(_ coordinate: LocalEventGeoCoordinate?) -> String? {
        guard let coordinate,
              let data = try? JSONEncoder().encode(coordinate) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func graphBody(notes: String, urlString: String, preservesOnlineMeetingBody: Bool) -> MicrosoftGraphBody? {
        guard !preservesOnlineMeetingBody else { return nil }

        let trimmedNotes = notes.nilIfBlank
        guard let trimmedURL = urlString.nilIfBlank else {
            return MicrosoftGraphBody(contentType: "text", content: trimmedNotes ?? "")
        }

        let content: String
        if let trimmedNotes {
            if trimmedNotes.range(of: trimmedURL, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                content = trimmedNotes
            } else {
                content = "\(trimmedNotes)\n\nURL: \(trimmedURL)"
            }
        } else {
            content = "URL: \(trimmedURL)"
        }

        return MicrosoftGraphBody(contentType: "text", content: content)
    }

    private func microsoftGraphShouldPreserveOnlineMeetingBody(urlString: String) -> Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let text = url.absoluteString.lowercased()
        return ["msteams", "ms-teams", "skype"].contains(scheme)
            || host.contains("teams.microsoft.com")
            || host.contains("teams.live.com")
            || host.contains("msteams.link")
            || host.contains("meet.lync.com")
            || host.contains("join.skype.com")
            || text.contains("teams.microsoft.com/l/meetup-join")
    }

    private func graphLocation(from value: String, categories: [String]) -> MicrosoftGraphLocation {
        graphLocations(from: value, categories: categories).first ?? MicrosoftGraphLocation(displayName: graphClearingString(value))
    }

    private func graphLocations(from value: String, categories: [String]) -> [MicrosoftGraphLocation] {
        var seen: Set<String> = []
        let names = value
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { name in
                seen.insert(name.lowercased()).inserted
            }
        let metadataByIndex = microsoftGraphLocationMetadata(from: categories)
        return names.enumerated().map { offset, name in
            let index = offset + 1
            guard let metadata = metadataByIndex[index],
                  metadata.matches(displayName: name) else {
                return MicrosoftGraphLocation(displayName: name)
            }
            return MicrosoftGraphLocation(
                displayName: name,
                locationEmailAddress: metadata.email,
                locationUri: metadata.uri,
                locationType: metadata.type,
                uniqueId: metadata.uniqueId,
                uniqueIdType: metadata.uniqueIdType
            )
        }
    }

    private func graphResponseRequested(from attendees: [LocalEventAttendee]) -> Bool {
        attendees.contains { attendee in
            !attendee.isBlank
                && !attendee.isRoomLike
                && attendee.normalizedType != "resource"
                && attendee.rsvp
        }
    }

    private func graphClearingString(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed
    }

    private func recurrence(for event: LocalCalendarEvent) throws -> MicrosoftGraphPatternedRecurrence? {
        guard event.additionalOccurrenceStartDates.isEmpty else {
            throw MicrosoftGraphCalendarClientError.unsupportedAdditionalOccurrences
        }
        guard event.recurrenceFrequency != .none else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        let graphTimeZone = graphWriteTimeZone(for: event.timeZoneIdentifier)
        calendar.timeZone = graphTimeZone.timeZone
        let startComponents = calendar.dateComponents([.day, .month, .weekday], from: event.startDate)
        let interval = max(1, event.recurrenceInterval)
        let pattern: MicrosoftGraphRecurrencePattern

        switch event.recurrenceFrequency {
        case .none:
            return nil
        case .daily:
            pattern = MicrosoftGraphRecurrencePattern(
                type: "daily",
                interval: interval
            )
        case .weekly:
            let setPositions = normalizedRecurrenceSetPositions(
                event.recurrenceSetPositions,
                frequency: event.recurrenceFrequency
            )
            if !setPositions.isEmpty {
                throw MicrosoftGraphCalendarClientError.unsupportedWeeklyRecurrenceSetPositions(setPositions)
            }
            let rawWeekdays = event.recurrenceWeekdays.isEmpty
                ? [startComponents.weekday ?? 1]
                : event.recurrenceWeekdays
            let weekdays = rawWeekdays.compactMap(graphWeekdayName(for:))
            pattern = MicrosoftGraphRecurrencePattern(
                type: "weekly",
                interval: interval,
                daysOfWeek: weekdays.isEmpty ? ["sunday"] : weekdays,
                firstDayOfWeek: event.recurrenceWeekStart.flatMap(graphWeekdayName(for:)) ?? "sunday"
            )
        case .monthly:
            let monthlyMonths = normalizedRecurrenceMonths(
                event.recurrenceMonths,
                frequency: event.recurrenceFrequency
            )
            if !monthlyMonths.isEmpty {
                throw MicrosoftGraphCalendarClientError.unsupportedMonthlyRecurrenceMonths(monthlyMonths)
            }
            if let ordinal = event.recurrenceOrdinal,
               let ordinalWeekday = event.recurrenceOrdinalWeekday {
                guard let index = graphRecurrenceIndex(for: ordinal),
                      let weekday = graphWeekdayName(for: ordinalWeekday) else {
                    throw MicrosoftGraphCalendarClientError.unsupportedRelativeRecurrenceOrdinal(ordinal)
                }
                pattern = MicrosoftGraphRecurrencePattern(
                    type: "relativeMonthly",
                    interval: interval,
                    daysOfWeek: [weekday],
                    index: index
                )
            } else {
                if let recurrenceMonthDay = event.recurrenceMonthDay, recurrenceMonthDay < 0 {
                    throw MicrosoftGraphCalendarClientError.unsupportedNegativeRecurrenceMonthDay(recurrenceMonthDay)
                }
                pattern = MicrosoftGraphRecurrencePattern(
                    type: "absoluteMonthly",
                    interval: interval,
                    dayOfMonth: event.recurrenceMonthDay ?? startComponents.day
                )
            }
        case .yearly:
            let yearlyMonths = normalizedRecurrenceMonths(event.recurrenceMonths, frequency: event.recurrenceFrequency)
            if yearlyMonths.count > 1 {
                throw MicrosoftGraphCalendarClientError.unsupportedYearlyRecurrenceMonths(yearlyMonths)
            }
            let recurrenceMonth = yearlyMonths.first ?? startComponents.month
            if let ordinal = event.recurrenceOrdinal,
               let ordinalWeekday = event.recurrenceOrdinalWeekday {
                guard let index = graphRecurrenceIndex(for: ordinal),
                      let weekday = graphWeekdayName(for: ordinalWeekday) else {
                    throw MicrosoftGraphCalendarClientError.unsupportedRelativeRecurrenceOrdinal(ordinal)
                }
                pattern = MicrosoftGraphRecurrencePattern(
                    type: "relativeYearly",
                    interval: interval,
                    daysOfWeek: [weekday],
                    month: recurrenceMonth,
                    index: index
                )
            } else {
                if let recurrenceMonthDay = event.recurrenceMonthDay, recurrenceMonthDay < 0 {
                    throw MicrosoftGraphCalendarClientError.unsupportedNegativeRecurrenceMonthDay(recurrenceMonthDay)
                }
                pattern = MicrosoftGraphRecurrencePattern(
                    type: "absoluteYearly",
                    interval: interval,
                    dayOfMonth: event.recurrenceMonthDay ?? startComponents.day,
                    month: recurrenceMonth
                )
            }
        }

        let range = MicrosoftGraphRecurrenceRange(
            type: event.recurrenceEndDate == nil ? "noEnd" : "endDate",
            startDate: graphDateString(from: event.startDate, timeZone: graphTimeZone.timeZone),
            endDate: event.recurrenceEndDate.map { graphDateString(from: $0, timeZone: graphTimeZone.timeZone) },
            recurrenceTimeZone: graphTimeZone.identifier
        )

        return MicrosoftGraphPatternedRecurrence(pattern: pattern, range: range)
    }

    private func graphAttendeeType(for attendee: LocalEventAttendee) -> String {
        if attendee.isRoomLike || attendee.normalizedType == "resource" {
            return "resource"
        }
        if attendee.normalizedRole == "optional" {
            return "optional"
        }
        return "required"
    }

    private func recurrenceLine(for recurrence: MicrosoftGraphPatternedRecurrence?) -> String? {
        guard let recurrence else { return nil }

        var parts: [String]
        switch recurrence.pattern.type.lowercased() {
        case "daily":
            parts = ["FREQ=DAILY"]
        case "weekly":
            parts = ["FREQ=WEEKLY"]
            let weekdays = recurrence.pattern.daysOfWeek?.compactMap(icsWeekdayName(for:)) ?? []
            if !weekdays.isEmpty {
                parts.append("BYDAY=\(weekdays.joined(separator: ","))")
            }
            if let firstDayOfWeek = recurrence.pattern.firstDayOfWeek.flatMap(icsWeekdayName(for:)) {
                parts.append("WKST=\(firstDayOfWeek)")
            }
        case "absolutemonthly":
            parts = ["FREQ=MONTHLY"]
            if let dayOfMonth = recurrence.pattern.dayOfMonth {
                parts.append("BYMONTHDAY=\(dayOfMonth)")
            }
        case "relativemonthly":
            parts = ["FREQ=MONTHLY"]
            if let weekday = recurrence.pattern.daysOfWeek?.first.flatMap(icsWeekdayName(for:)),
               let ordinal = recurrenceOrdinal(forGraphIndex: recurrence.pattern.index) {
                parts.append("BYDAY=\(ordinal)\(weekday)")
            }
        case "absoluteyearly":
            parts = ["FREQ=YEARLY"]
            if let month = recurrence.pattern.month {
                parts.append("BYMONTH=\(month)")
            }
            if let dayOfMonth = recurrence.pattern.dayOfMonth {
                parts.append("BYMONTHDAY=\(dayOfMonth)")
            }
        case "relativeyearly":
            parts = ["FREQ=YEARLY"]
            if let month = recurrence.pattern.month {
                parts.append("BYMONTH=\(month)")
            }
            if let weekday = recurrence.pattern.daysOfWeek?.first.flatMap(icsWeekdayName(for:)),
               let ordinal = recurrenceOrdinal(forGraphIndex: recurrence.pattern.index) {
                parts.append("BYDAY=\(ordinal)\(weekday)")
            }
        default:
            return nil
        }

        parts.append("INTERVAL=\(max(1, recurrence.pattern.interval))")

        switch recurrence.range.type.lowercased() {
        case "numbered":
            if let count = recurrence.range.numberOfOccurrences, count > 0 {
                parts.append("COUNT=\(count)")
            }
        case "enddate":
            if let endDate = recurrence.range.endDate.flatMap(graphDateFormatter.date(from:)),
               let inclusiveEnd = Calendar(identifier: .gregorian).date(bySettingHour: 23, minute: 59, second: 59, of: endDate) {
                parts.append("UNTIL=\(icsDateTimeFormatter.string(from: inclusiveEnd))")
            }
        default:
            break
        }

        return "RRULE:\(parts.joined(separator: ";"))"
    }

    private func recurrenceExceptionLine(
        prefix: String,
        occurrence: MicrosoftGraphEvent,
        masterEvent: MicrosoftGraphEvent
    ) -> String? {
        if let originalStart = occurrence.originalStart.nilIfBlank,
           let date = parseGraphDateTime(originalStart, timeZone: "UTC") {
            if masterEvent.isAllDay == true {
                let compactDate = compactGraphDatePrefix(from: originalStart) ?? compactGraphDateString(from: date)
                return "\(prefix);VALUE=DATE:\(compactDate)"
            }
            return "\(prefix):\(icsDateTimeFormatter.string(from: date))"
        }

        guard let occurrenceID = occurrence.occurrenceId.nilIfBlank else { return nil }
        return recurrenceExceptionLine(prefix: prefix, occurrenceID: occurrenceID, masterEvent: masterEvent)
    }

    private func originalStartDate(for instance: MicrosoftGraphEvent, baseEvent: LocalCalendarEvent) -> Date? {
        if let originalStart = instance.originalStart.nilIfBlank {
            if baseEvent.isAllDay,
               let date = allDayDate(fromGraphDatePrefix: originalStart) {
                return date
            }
            if let date = parseGraphDateTime(originalStart, timeZone: "UTC") {
                return date
            }
        }

        guard let occurrenceID = instance.occurrenceId.nilIfBlank,
              let occurrenceDate = occurrenceDateString(from: occurrenceID)
        else {
            return instance.start?.resolvedDate
        }

        if baseEvent.isAllDay {
            return allDayDate(fromGraphDatePrefix: occurrenceDate)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = graphTimeZone(for: baseEvent.timeZoneIdentifier).timeZone
        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: baseEvent.startDate)
        let dateParts = occurrenceDate.split(separator: "-").compactMap { Int($0) }
        guard dateParts.count == 3 else { return nil }

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = dateParts[0]
        components.month = dateParts[1]
        components.day = dateParts[2]
        components.hour = timeComponents.hour
        components.minute = timeComponents.minute
        components.second = timeComponents.second
        return calendar.date(from: components)
    }

    private func remoteOccurrenceStartDate(forCancelledOccurrence event: MicrosoftGraphEvent) -> Date? {
        guard let originalStart = event.originalStart.nilIfBlank else { return nil }
        if event.isAllDay == true,
           let date = allDayDate(fromGraphDatePrefix: originalStart) {
            return date
        }
        return parseGraphDateTime(originalStart, timeZone: "UTC")
    }

    private func originalStartDate(
        for instance: MicrosoftGraphEvent,
        occurrenceStartDate: Date,
        occurrenceIsAllDay: Bool,
        occurrenceTimeZoneIdentifier: String?
    ) -> Date? {
        if let originalStart = instance.originalStart.nilIfBlank {
            if occurrenceIsAllDay,
               let date = allDayDate(fromGraphDatePrefix: originalStart) {
                return date
            }
            if let date = parseGraphDateTime(originalStart, timeZone: "UTC") {
                return date
            }
        }

        guard let occurrenceID = instance.occurrenceId.nilIfBlank,
              let occurrenceDate = occurrenceDateString(from: occurrenceID)
        else {
            return instance.start?.resolvedDate
        }

        if occurrenceIsAllDay {
            return allDayDate(fromGraphDatePrefix: occurrenceDate)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = graphTimeZone(for: occurrenceTimeZoneIdentifier).timeZone
        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: occurrenceStartDate)
        let dateParts = occurrenceDate.split(separator: "-").compactMap { Int($0) }
        guard dateParts.count == 3 else { return nil }

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = dateParts[0]
        components.month = dateParts[1]
        components.day = dateParts[2]
        components.hour = timeComponents.hour
        components.minute = timeComponents.minute
        components.second = timeComponents.second
        return calendar.date(from: components)
    }

    private func originalStartMatches(
        _ instance: MicrosoftGraphEvent,
        occurrenceStartDate: Date,
        occurrenceIsAllDay: Bool,
        occurrenceTimeZoneIdentifier: String?
    ) -> Bool {
        if occurrenceIsAllDay {
            if let originalStart = instance.originalStart.nilIfBlank {
                return allDayProviderDate(
                    originalStart,
                    matches: occurrenceStartDate,
                    timeZoneIdentifier: occurrenceTimeZoneIdentifier
                )
            }
            if let occurrenceID = instance.occurrenceId.nilIfBlank,
               let occurrenceDate = occurrenceDateString(from: occurrenceID) {
                return allDayProviderDate(
                    occurrenceDate,
                    matches: occurrenceStartDate,
                    timeZoneIdentifier: occurrenceTimeZoneIdentifier
                )
            }
        }

        return originalStartDate(
            for: instance,
            occurrenceStartDate: occurrenceStartDate,
            occurrenceIsAllDay: occurrenceIsAllDay,
            occurrenceTimeZoneIdentifier: occurrenceTimeZoneIdentifier
        )?.isSameOccurrenceStart(as: occurrenceStartDate, isAllDay: occurrenceIsAllDay) == true
    }

    private func allDayProviderDate(
        _ providerDatePrefix: String,
        matches occurrenceStartDate: Date,
        timeZoneIdentifier: String?
    ) -> Bool {
        let providerDate = String(providerDatePrefix.prefix(10))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard providerDate.count == 10 || providerDate.count == 8 else { return false }
        let normalizedProviderDate = providerDate.replacingOccurrences(of: "-", with: "")
        let timeZone = graphTimeZone(for: timeZoneIdentifier).timeZone
        return normalizedProviderDate == graphDateString(
            from: occurrenceStartDate,
            timeZone: timeZone
        ).replacingOccurrences(of: "-", with: "")
    }

    private func recurrenceExceptionLine(
        prefix: String,
        occurrenceID: String,
        masterEvent: MicrosoftGraphEvent
    ) -> String? {
        guard let occurrenceDate = occurrenceDateString(from: occurrenceID) else { return nil }

        if masterEvent.isAllDay == true {
            return "\(prefix);VALUE=DATE:\(occurrenceDate.replacingOccurrences(of: "-", with: ""))"
        }

        guard let masterStartDate = masterEvent.start?.dateTime.flatMap({
            parseGraphDateTime($0, timeZone: masterEvent.start?.timeZone)
        }) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = graphTimeZone(for: masterEvent.start?.timeZone).timeZone
        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: masterStartDate)
        let dateParts = occurrenceDate.split(separator: "-").compactMap { Int($0) }
        guard dateParts.count == 3 else { return nil }

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = dateParts[0]
        components.month = dateParts[1]
        components.day = dateParts[2]
        components.hour = timeComponents.hour
        components.minute = timeComponents.minute
        components.second = timeComponents.second

        guard let date = calendar.date(from: components) else { return nil }
        return "\(prefix):\(icsDateTimeFormatter.string(from: date))"
    }

    private func occurrenceDateString(from occurrenceID: String) -> String? {
        guard let datePart = occurrenceID.split(separator: ".").last.map(String.init),
              datePart.count == 10
        else {
            return nil
        }

        let pieces = datePart.split(separator: "-")
        guard pieces.count == 3,
              pieces[0].count == 4,
              pieces[1].count == 2,
              pieces[2].count == 2,
              pieces.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else {
            return nil
        }

        return datePart
    }

    private func compactGraphDateString(from date: Date) -> String {
        graphDateFormatter.string(from: date).replacingOccurrences(of: "-", with: "")
    }

    private func compactGraphDatePrefix(from value: String) -> String? {
        let datePrefix = String(value.prefix(10))
        guard datePrefix.count == 10,
              graphDateFormatter.date(from: datePrefix) != nil
        else {
            return nil
        }
        return datePrefix.replacingOccurrences(of: "-", with: "")
    }

    private func allDayDate(fromGraphDatePrefix value: String) -> Date? {
        let datePrefix = String(value.prefix(10))
        let parts = datePrefix.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar.date(from: components)
    }

    private func uid(for event: MicrosoftGraphEvent) -> String {
        "\(event.id)@microsoft-graph"
    }

    private func remoteTarget(
        for event: LocalCalendarEvent,
        localCalendar: LocalCalendar,
        account: CalendarProviderAccount
    ) throws -> (calendarID: String, eventID: String?) {
        if let target = remoteTarget(from: event.remoteObjectURLString, account: account) {
            return target
        }

        let prefix = localCalendarIDPrefix(for: account)
        guard localCalendar.id.hasPrefix(prefix) else {
            throw MicrosoftGraphCalendarClientError.calendarNotFound
        }

        let encodedCalendarID = String(localCalendar.id.dropFirst(prefix.count))
        guard let calendarID = base64URLDecode(encodedCalendarID), !calendarID.isEmpty else {
            throw MicrosoftGraphCalendarClientError.calendarNotFound
        }

        return (calendarID, nil)
    }

    private func remoteTarget(
        from remoteObjectURLString: String,
        account: CalendarProviderAccount
    ) -> (calendarID: String, eventID: String?)? {
        let trimmed = remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme == "microsoft365",
              url.host == account.id
        else {
            return nil
        }

        let pieces = url.pathComponents.filter { $0 != "/" }
        guard pieces.count >= 2,
              let calendarID = base64URLDecode(pieces[0]),
              let eventID = base64URLDecode(pieces[1])
        else {
            return nil
        }

        return (calendarID, eventID)
    }

    private func remoteObjectURLString(account: CalendarProviderAccount, calendarID: String, eventID: String) -> String {
        "microsoft365://\(account.id)/\(base64URLEncode(calendarID))/\(base64URLEncode(eventID))"
    }

    private func microsoftGraphTransactionID(for event: LocalCalendarEvent) -> String {
        "working-calendar-\(stableHexIdentifier(for: event.id))"
    }

    func eventDetailsQueryItemsPreview() -> [URLQueryItem] {
        [
            URLQueryItem(name: "$select", value: Self.eventDetailsSelectFields),
            URLQueryItem(name: "$expand", value: Self.eventDetailsExpandFields)
        ]
    }

    func localCalendarID(for account: CalendarProviderAccount, graphCalendarID: String) -> String {
        "\(localCalendarIDPrefix(for: account))\(base64URLEncode(graphCalendarID))"
    }

    private func eventsURL(account: CalendarProviderAccount, calendarID: String, queryItems: [URLQueryItem]) throws -> URL {
        try apiURL(account: account, path: ["me", "calendars", calendarID, "events"], queryItems: queryItems)
    }

    private func eventURL(
        account: CalendarProviderAccount,
        calendarID: String,
        eventID: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        try apiURL(account: account, path: ["me", "calendars", calendarID, "events", eventID], queryItems: queryItems)
    }

    private func eventAttachmentsURL(
        account: CalendarProviderAccount,
        calendarID: String,
        eventID: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        try apiURL(
            account: account,
            path: ["me", "calendars", calendarID, "events", eventID, "attachments"],
            queryItems: queryItems
        )
    }

    private func eventExtensionsURL(
        account: CalendarProviderAccount,
        calendarID: String,
        eventID: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        try apiURL(
            account: account,
            path: ["me", "calendars", calendarID, "events", eventID, "extensions"],
            queryItems: queryItems
        )
    }

    private func eventOpenExtensionURL(
        account: CalendarProviderAccount,
        calendarID: String,
        eventID: String
    ) throws -> URL {
        try apiURL(
            account: account,
            path: ["me", "calendars", calendarID, "events", eventID, "extensions", Self.workingCalendarOpenExtensionName],
            queryItems: []
        )
    }

    private func eventInstancesURL(
        account: CalendarProviderAccount,
        calendarID: String,
        eventID: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        try apiURL(account: account, path: ["me", "calendars", calendarID, "events", eventID, "instances"], queryItems: queryItems)
    }

    private func actionURL(account: CalendarProviderAccount, calendarID: String, eventID: String, action: String) throws -> URL {
        try apiURL(account: account, path: ["me", "calendars", calendarID, "events", eventID, action], queryItems: [])
    }

    private func betaAPIURL(account: CalendarProviderAccount, path: [String], queryItems: [URLQueryItem]) throws -> URL {
        try apiURL(account: account, path: path, queryItems: queryItems, apiVersionOverride: "beta")
    }

    private func validateGraphPage(_ url: URL, seenPageURLs: inout Set<String>, pageCount: inout Int) throws {
        guard seenPageURLs.insert(url.absoluteString).inserted else {
            throw MicrosoftGraphCalendarClientError.paginationLoop(url)
        }

        pageCount += 1
        guard pageCount <= Self.maxGraphPageCount else {
            throw MicrosoftGraphCalendarClientError.paginationLimitExceeded(url)
        }
    }

    private func apiURL(
        account: CalendarProviderAccount,
        path: [String],
        queryItems: [URLQueryItem],
        apiVersionOverride: String? = nil
    ) throws -> URL {
        guard let baseURL = account.endpointURL else {
            throw MicrosoftGraphCalendarClientError.invalidAccountURL
        }

        let resolvedBaseURL = try graphBaseURL(baseURL, apiVersionOverride: apiVersionOverride)
        let encodedPath = path.map(pathComponent).joined(separator: "/")
        guard var components = URLComponents(url: resolvedBaseURL, resolvingAgainstBaseURL: false) else {
            throw MicrosoftGraphCalendarClientError.invalidAccountURL
        }
        let basePath = components.percentEncodedPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fullPath = [basePath, encodedPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.percentEncodedPath = "/\(fullPath)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw MicrosoftGraphCalendarClientError.invalidAccountURL
        }
        return url
    }

    private func graphBaseURL(_ baseURL: URL, apiVersionOverride: String?) throws -> URL {
        guard let apiVersionOverride else { return baseURL }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MicrosoftGraphCalendarClientError.invalidAccountURL
        }

        components.path = "/\(apiVersionOverride)"
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw MicrosoftGraphCalendarClientError.invalidAccountURL
        }
        return url
    }

    private func jsonRequest<Response: Decodable>(
        account: CalendarProviderAccount,
        url: URL,
        method: String,
        body: Data?,
        headers: [String: String] = [:]
    ) async throws -> Response {
        let data = try await dataRequest(account: account, url: url, method: method, body: body, headers: headers)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func emptyRequest(account: CalendarProviderAccount, url: URL, method: String, body: Data?, headers: [String: String] = [:]) async throws {
        _ = try await dataRequest(account: account, url: url, method: method, body: body, headers: headers)
    }

    private func dataRequest(account: CalendarProviderAccount, url: URL, method: String, body: Data?, headers: [String: String]) async throws -> Data {
        try await dataRequest(
            account: account,
            url: url,
            method: method,
            body: body,
            headers: headers,
            forceRefresh: false
        )
    }

    private func dataRequest(
        account: CalendarProviderAccount,
        url: URL,
        method: String,
        body: Data?,
        headers: [String: String],
        forceRefresh: Bool
    ) async throws -> Data {
        let accessToken: String
        do {
            accessToken = try await accessTokenProvider(account, .microsoft365, forceRefresh)
        } catch OAuthDeviceFlowError.missingAccessToken {
            throw MicrosoftGraphCalendarClientError.missingAccessToken
        } catch OAuthDeviceFlowError.missingRefreshToken {
            throw MicrosoftGraphCalendarClientError.missingRefreshToken
        } catch OAuthDeviceFlowError.refreshTokenRejected(_) {
            throw MicrosoftGraphCalendarClientError.missingRefreshToken
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("IdType=\"ImmutableId\", outlook.timezone=\"UTC\", outlook.body-content-type=\"text\"", forHTTPHeaderField: "Prefer")
        for (key, value) in headers where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await transport.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            if method == "DELETE", httpResponse.statusCode == 404 || httpResponse.statusCode == 410 {
                return Data()
            }
            if httpResponse.statusCode == 401, !forceRefresh {
                return try await dataRequest(
                    account: account,
                    url: url,
                    method: method,
                    body: body,
                    headers: headers,
                    forceRefresh: true
                )
            }
            if httpResponse.statusCode == 412 {
                throw MicrosoftGraphCalendarClientError.remoteConflict(url)
            }
            if ProviderRetryAfter.isRetryAfterStatus(httpResponse.statusCode),
               let retryAfterSeconds = ProviderRetryAfter.seconds(from: httpResponse) {
                throw MicrosoftGraphCalendarClientError.retryAfter(
                    retryAfterSeconds,
                    url,
                    graphErrorMessage(from: data)
                )
            }
            throw MicrosoftGraphCalendarClientError.httpStatus(
                httpResponse.statusCode,
                url,
                graphErrorMessage(from: data)
            )
        }

        return data
    }

    private func conditionalHeaders(remoteETag: String) -> [String: String] {
        let trimmed = remoteETag.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [:] : ["If-Match": trimmed]
    }

    private func graphErrorMessage(from data: Data) -> String {
        guard
            let errorResponse = try? JSONDecoder().decode(MicrosoftGraphErrorResponse.self, from: data),
            let message = errorResponse.error?.message.nilIfBlank
        else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return message
    }

    private func pathComponent(_ value: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#[]@!$&'()*+,;="))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func base64URLEncode(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func base64URLDecode(_ value: String) -> String? {
        var encoded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 {
            encoded.append("=")
        }
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func stableHexIdentifier(for value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    private func escapeICSText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
    }

    private func geoFloatString(_ value: Double) -> String {
        var text = String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.contains("."), text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }

    private func alarmLines(reminderOffsets: [Int], title: String) -> [String] {
        normalizedReminderOffsets(reminderOffsets).flatMap { minutesBeforeStart in
            [
                "BEGIN:VALARM",
                "ACTION:DISPLAY",
                "DESCRIPTION:\(escapeICSText(title.isEmpty ? "Reminder" : title))",
                "TRIGGER:\(alarmTriggerValue(minutesBeforeStart: minutesBeforeStart))",
                "END:VALARM"
            ]
        }
    }

    private func alarmTriggerValue(minutesBeforeStart: Int) -> String {
        let minutes = max(0, minutesBeforeStart)
        if minutes == 0 { return "PT0M" }
        let days = minutes / (24 * 60)
        let remainingAfterDays = minutes % (24 * 60)
        let hours = remainingAfterDays / 60
        let remainingMinutes = remainingAfterDays % 60
        if days > 0, hours == 0, remainingMinutes == 0 {
            return "-P\(days)D"
        }
        var value = days > 0 ? "-P\(days)DT" : "-PT"
        if hours > 0 {
            value += "\(hours)H"
        }
        if remainingMinutes > 0 {
            value += "\(remainingMinutes)M"
        }
        return value
    }

    private func escapeICSParameter(_ value: String) -> String {
        value
            .replacingOccurrences(of: "^", with: "^^")
            .replacingOccurrences(of: "\n", with: "^n")
            .replacingOccurrences(of: "\"", with: "^'")
    }

    private func mailtoValue(email: String?, fallbackName: String?) -> String {
        if let normalizedEmail = normalizedIdentityEmail(email) {
            return "mailto:\(escapeICSText(normalizedEmail))"
        }
        if let email = email.nilIfBlank {
            return "mailto:\(escapeICSText(email))"
        }
        return escapeICSText(fallbackName.nilIfBlank ?? "Participant")
    }

    private func graphAttendeeMatchesCurrentUser(
        _ attendee: MicrosoftGraphAttendee,
        account: CalendarProviderAccount
    ) -> Bool {
        guard let email = normalizedIdentityEmail(attendee.emailAddress.address) else { return false }
        return graphIdentityEmails(for: account).contains(email)
    }

    private func graphOrganizerMatchesCurrentUser(
        _ organizer: MicrosoftGraphRecipient?,
        account: CalendarProviderAccount
    ) -> Bool {
        guard let email = normalizedIdentityEmail(organizer?.emailAddress.address) else { return false }
        return graphIdentityEmails(for: account).contains(email)
    }

    private func graphIdentityEmails(for account: CalendarProviderAccount) -> Set<String> {
        Set(([account.identityEmail] + account.identityEmailAliases.map(Optional.some) + [account.username, account.title])
            .compactMap(normalizedIdentityEmail))
    }

    private func graphIdentityEmails(from profile: MicrosoftGraphUserProfile) -> [String] {
        uniqueIdentityEmails(
            [profile.mail, profile.userPrincipalName]
                + (profile.otherMails ?? []).map(Optional.some)
                + (profile.proxyAddresses ?? []).map(Optional.some)
        )
    }

    private func uniqueIdentityEmails(_ values: [String?]) -> [String] {
        var seen: Set<String> = []
        var emails: [String] = []
        for value in values {
            guard let email = normalizedIdentityEmail(value),
                  seen.insert(email).inserted
            else { continue }
            emails.append(email)
        }
        return emails
    }

    private func normalizedIdentityEmail(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
        return email.contains("@") ? email : nil
    }

    private func percentDecodedEmail(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.removingPercentEncoding ?? trimmed
    }

    private func mailtoAddressComponent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryIndex = trimmed.firstIndex { $0 == "?" || $0 == "#" } ?? trimmed.endIndex
        return String(trimmed[..<queryIndex])
    }

    private func partStat(for responseStatus: String?) -> String {
        switch normalizedGraphResponseStatus(responseStatus) {
        case "accepted", "organizer":
            return "ACCEPTED"
        case "declined":
            return "DECLINED"
        case "tentativelyaccepted":
            return "TENTATIVE"
        default:
            return "NEEDS-ACTION"
        }
    }

    private func icsEventStatus(forShowAs showAs: String?) -> String? {
        switch showAs?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "tentative":
            return "TENTATIVE"
        default:
            return nil
        }
    }

    private func myResponseStatus(for event: MicrosoftGraphEvent, account: CalendarProviderAccount) -> EventResponseStatus {
        if graphOrganizerMatchesCurrentUser(event.organizer, account: account) {
            return .accepted
        }

        if let currentUserAttendee = event.attendees?.first(where: { graphAttendeeMatchesCurrentUser($0, account: account) }) {
            let attendeeStatus = responseStatus(for: currentUserAttendee.status?.response)
            if attendeeStatus.isExplicitResponse {
                return attendeeStatus
            }
        }

        let topLevelStatus = responseStatus(for: event.responseStatus?.response)
        if topLevelStatus != .unknown {
            return topLevelStatus
        }

        if let currentUserAttendee = event.attendees?.first(where: { graphAttendeeMatchesCurrentUser($0, account: account) }) {
            return responseStatus(for: currentUserAttendee.status?.response)
        }

        return topLevelStatus
    }

    private func responseStatus(for graphStatus: String?) -> EventResponseStatus {
        switch normalizedGraphResponseStatus(graphStatus) {
        case "accepted", "organizer":
            return .accepted
        case "declined":
            return .declined
        case "tentativelyaccepted":
            return .tentative
        case "none", "notresponded", "":
            return .pending
        default:
            return .unknown
        }
    }

    private func normalizedGraphResponseStatus(_ value: String?) -> String? {
        guard let value else { return nil }
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
    }

    private func colorHex(for color: String?) -> String {
        switch color?.lowercased() {
        case "lightblue", "blue": return "#3B82F6"
        case "lightgreen", "green": return "#22C55E"
        case "lightorange", "orange": return "#F59E0B"
        case "lightgray", "gray": return "#64748B"
        case "lightyellow", "yellow": return "#EAB308"
        case "lightteal", "teal": return "#14B8A6"
        case "lightpink", "pink": return "#EC4899"
        case "lightbrown", "brown": return "#A16207"
        case "lightred", "red": return "#EF4444"
        case "maxcolor":
            return "#8B5CF6"
        default:
            return "#2563EB"
        }
    }

    private func graphWeekdayName(for weekday: Int) -> String? {
        switch weekday {
        case 1: return "sunday"
        case 2: return "monday"
        case 3: return "tuesday"
        case 4: return "wednesday"
        case 5: return "thursday"
        case 6: return "friday"
        case 7: return "saturday"
        default: return nil
        }
    }

    private func icsWeekdayName(for graphWeekday: String) -> String? {
        switch graphWeekday.lowercased() {
        case "sunday": return "SU"
        case "monday": return "MO"
        case "tuesday": return "TU"
        case "wednesday": return "WE"
        case "thursday": return "TH"
        case "friday": return "FR"
        case "saturday": return "SA"
        default: return nil
        }
    }

    private func graphRecurrenceIndex(for ordinal: Int) -> String? {
        switch ordinal {
        case 1: return "first"
        case 2: return "second"
        case 3: return "third"
        case 4: return "fourth"
        case -1: return "last"
        default: return nil
        }
    }

    private func recurrenceOrdinal(forGraphIndex index: String?) -> Int? {
        switch index?.lowercased() {
        case "first": return 1
        case "second": return 2
        case "third": return 3
        case "fourth": return 4
        case "last": return -1
        default: return nil
        }
    }

    private func graphDateTimeWrite(from date: Date, timeZoneIdentifier: String) -> MicrosoftGraphDateTimeTimeZoneWrite {
        let graphTimeZone = graphWriteTimeZone(for: timeZoneIdentifier)
        let formatter = graphDateTimeFormatter
        formatter.timeZone = graphTimeZone.timeZone
        return MicrosoftGraphDateTimeTimeZoneWrite(
            dateTime: formatter.string(from: date),
            timeZone: graphTimeZone.identifier
        )
    }

    private func graphDateString(from date: Date, timeZone: TimeZone) -> String {
        let formatter = graphDateFormatter
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    fileprivate func graphTimeZone(for rawIdentifier: String?) -> (identifier: String, timeZone: TimeZone) {
        let fallback = TimeZone.current
        guard let rawIdentifier,
              let identifier = normalizedGraphTimeZoneIdentifier(rawIdentifier),
              let timeZone = TimeZone(identifier: identifier)
        else {
            return (fallback.identifier, fallback)
        }
        return (identifier, timeZone)
    }

    private func graphWriteTimeZone(for rawIdentifier: String?) -> (identifier: String, timeZone: TimeZone) {
        let resolved = graphTimeZone(for: rawIdentifier)
        let rawKey = rawIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let rawKey,
           let mapped = Self.windowsTimeZoneMap[rawKey],
           TimeZone(identifier: mapped) != nil {
            return (Self.windowsTimeZoneDisplayName(for: rawKey), TimeZone(identifier: mapped) ?? resolved.timeZone)
        }
        if let override = Self.ianaToWindowsTimeZoneOverrides[resolved.identifier] {
            return (override, resolved.timeZone)
        }
        if let windowsName = Self.ianaToWindowsTimeZoneMap[resolved.identifier] {
            return (windowsName, resolved.timeZone)
        }
        return (resolved.identifier, resolved.timeZone)
    }

    private func normalizedGraphTimeZoneIdentifier(_ rawIdentifier: String) -> String? {
        let trimmed = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if TimeZone(identifier: trimmed) != nil { return trimmed }

        let compact = trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: " ", with: "_")
        if TimeZone(identifier: compact) != nil { return compact }

        for prefix in Self.ianaTimeZonePrefixes {
            if let range = compact.range(of: prefix) {
                let candidate = String(compact[range.lowerBound...])
                if TimeZone(identifier: candidate) != nil {
                    return candidate
                }
            }
        }

        let windowsKey = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
        if let mapped = Self.windowsTimeZoneMap[windowsKey],
           TimeZone(identifier: mapped) != nil {
            return mapped
        }

        if let offset = fixedOffsetTimeZoneIdentifier(from: trimmed),
           TimeZone(identifier: offset) != nil {
            return offset
        }

        return nil
    }

    private func fixedOffsetTimeZoneIdentifier(from rawIdentifier: String) -> String? {
        let uppercased = rawIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
        guard let prefix = ["UTC", "GMT"].first(where: { uppercased.hasPrefix($0) }) else { return nil }
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
              (0...59).contains(minutes),
              let timeZone = TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * ((hours * 3600) + (minutes * 60)))
        else {
            return nil
        }
        return timeZone.identifier
    }

    private static let eventDetailsSelectFields = [
        "id",
        "changeKey",
        "subject",
        "body",
        "start",
        "end",
        "isAllDay",
        "showAs",
        "sensitivity",
        "importance",
        "categories",
        "hasAttachments",
        "isReminderOn",
        "reminderMinutesBeforeStart",
        "isCancelled",
        "iCalUId",
        "webLink",
        "isOnlineMeeting",
        "onlineMeetingProvider",
        "onlineMeetingUrl",
        "onlineMeeting",
        "location",
        "locations",
        "organizer",
        "attendees",
        "responseStatus",
        "responseRequested",
        "allowNewTimeProposals",
        "createdDateTime",
        "lastModifiedDateTime",
        "recurrence",
        "type",
        "seriesMasterId",
        "originalStart",
        "occurrenceId",
        "exceptionOccurrences",
        "cancelledOccurrences"
    ].joined(separator: ",")

    private static let eventAttachmentSelectFields = [
        "id",
        "name",
        "contentType",
        "isInline",
        "size",
        "lastModifiedDateTime",
        "sourceUrl"
    ].joined(separator: ",")

    private static let eventDetailsExpandFields = [
        "attachments($select=\(eventAttachmentSelectFields))",
        "extensions($filter=id eq '\(workingCalendarOpenExtensionName)')"
    ].joined(separator: ",")
    private static let seriesMasterDetailsExpandFields = "\(eventDetailsExpandFields),exceptionOccurrences"

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
        "alaskan standard time": "America/Anchorage",
        "pacific standard time": "America/Los_Angeles",
        "us mountain standard time": "America/Phoenix",
        "mountain standard time": "America/Denver",
        "central standard time": "America/Chicago",
        "eastern standard time": "America/New_York",
        "atlantic standard time": "America/Halifax",
        "gmt standard time": "Europe/London",
        "greenwich standard time": "Atlantic/Reykjavik",
        "w. europe standard time": "Europe/Berlin",
        "central europe standard time": "Europe/Budapest",
        "romance standard time": "Europe/Paris",
        "central european standard time": "Europe/Warsaw",
        "gtb standard time": "Europe/Athens",
        "e. europe standard time": "Europe/Chisinau",
        "fle standard time": "Europe/Helsinki",
        "israel standard time": "Asia/Jerusalem",
        "turkey standard time": "Europe/Istanbul",
        "russian standard time": "Europe/Moscow",
        "arab standard time": "Asia/Riyadh",
        "arabian standard time": "Asia/Dubai",
        "iran standard time": "Asia/Tehran",
        "west asia standard time": "Asia/Tashkent",
        "india standard time": "Asia/Kolkata",
        "nepal standard time": "Asia/Kathmandu",
        "central asia standard time": "Asia/Almaty",
        "bangladesh standard time": "Asia/Dhaka",
        "se asia standard time": "Asia/Bangkok",
        "china standard time": "Asia/Shanghai",
        "singapore standard time": "Asia/Singapore",
        "taipei standard time": "Asia/Taipei",
        "tokyo standard time": "Asia/Tokyo",
        "korea standard time": "Asia/Seoul",
        "aus eastern standard time": "Australia/Sydney",
        "e. australia standard time": "Australia/Brisbane",
        "tasmania standard time": "Australia/Hobart",
        "new zealand standard time": "Pacific/Auckland"
    ]

    private static let ianaToWindowsTimeZoneOverrides: [String: String] = [
        "Asia/Nicosia": "GTB Standard Time"
    ]

    private static let ianaToWindowsTimeZoneMap: [String: String] = {
        var result: [String: String] = [:]
        for (windowsKey, ianaIdentifier) in windowsTimeZoneMap where result[ianaIdentifier] == nil {
            result[ianaIdentifier] = windowsTimeZoneDisplayName(for: windowsKey)
        }
        for (ianaIdentifier, windowsName) in ianaToWindowsTimeZoneOverrides {
            result[ianaIdentifier] = windowsName
        }
        return result
    }()

    private static func windowsTimeZoneDisplayName(for key: String) -> String {
        switch key {
        case "utc":
            return "UTC"
        case "utc-11", "utc-09", "utc-02", "utc+12", "utc+13":
            return key.uppercased()
        default:
            return key
                .split(separator: " ")
                .map { token in
                    token == "w." || token == "e."
                        ? token.uppercased()
                        : String(token.prefix(1)).uppercased() + String(token.dropFirst())
                }
                .joined(separator: " ")
        }
    }

    private let rfc3339Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    fileprivate let icsDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    fileprivate let graphDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    fileprivate let graphDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    fileprivate func parseGraphDateTime(_ value: String, timeZone: String?) -> Date? {
        if let date = rfc3339Formatter.date(from: value) {
            return date
        }

        let normalized = value.split(separator: ".").first.map(String.init) ?? value
        let formatter = graphDateTimeFormatter
        formatter.timeZone = graphTimeZone(for: timeZone).timeZone
        return formatter.date(from: normalized)
    }
}

private let microsoftGraphShowAsCategoryPrefix = "Microsoft showAs "
private let microsoftGraphSensitivityCategoryPrefix = "Microsoft sensitivity "
private let microsoftGraphLocationCategoryPrefix = "Microsoft location "
private let microsoftGraphOnlineMeetingProviderCategoryPrefix = "Microsoft onlineMeetingProvider "
private let microsoftGraphOnlineMeetingCategory = "Microsoft online meeting"
private let microsoftGraphHiddenAttendeesCategory = "Microsoft attendees hidden"
private let microsoftGraphNewTimeProposalsDisabledCategory = "Microsoft new time proposals disabled"
private let microsoftGraphNewTimeProposalsEnabledCategory = "Microsoft new time proposals enabled"

private extension EventResponseStatus {
    var isExplicitResponse: Bool {
        switch self {
        case .accepted, .declined, .tentative, .delegated, .completed, .inProcess, .canceled:
            return true
        case .notInvited, .unknown, .pending:
            return false
        }
    }
}

fileprivate func normalizedMicrosoftGraphShowAs(_ value: String?) -> String? {
    let normalized = value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: "_", with: "")
        .lowercased() ?? ""

    switch normalized {
    case "free":
        return "free"
    case "tentative":
        return "tentative"
    case "busy":
        return "busy"
    case "oof":
        return "oof"
    case "workingelsewhere":
        return "workingElsewhere"
    case "unknown":
        return "unknown"
    case "unknownfuturevalue":
        return "unknownFutureValue"
    default:
        return nil
    }
}

fileprivate func microsoftGraphShowAsMetadataCategory(for showAs: String?) -> String? {
    guard let showAs = normalizedMicrosoftGraphShowAs(showAs),
          !["free", "busy", "tentative"].contains(showAs) else { return nil }
    return "\(microsoftGraphShowAsCategoryPrefix)\(showAs)"
}

fileprivate func microsoftGraphShowAsMetadata(from categories: [String]) -> String? {
    for category in categories {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        let rawValue: String?

        if lowercased.hasPrefix(microsoftGraphShowAsCategoryPrefix.lowercased()) {
            rawValue = String(trimmed.dropFirst(microsoftGraphShowAsCategoryPrefix.count))
        } else if lowercased.hasPrefix("microsoft-showas-") {
            rawValue = String(trimmed.dropFirst("microsoft-showas-".count))
        } else {
            rawValue = nil
        }

        if let showAs = normalizedMicrosoftGraphShowAs(rawValue) {
            return showAs
        }
    }

    return nil
}

fileprivate func normalizedMicrosoftGraphSensitivity(_ value: String?) -> String? {
    let normalized = value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: "_", with: "")
        .lowercased() ?? ""

    switch normalized {
    case "normal", "public":
        return "normal"
    case "personal":
        return "personal"
    case "private":
        return "private"
    case "confidential":
        return "confidential"
    default:
        return nil
    }
}

fileprivate func microsoftGraphSensitivityMetadataCategory(for sensitivity: String?) -> String? {
    guard let sensitivity = normalizedMicrosoftGraphSensitivity(sensitivity),
          sensitivity == "personal" else { return nil }
    return "\(microsoftGraphSensitivityCategoryPrefix)\(sensitivity)"
}

fileprivate func microsoftGraphSensitivityMetadata(from categories: [String]) -> String? {
    for category in categories {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        let rawValue: String?

        if lowercased.hasPrefix(microsoftGraphSensitivityCategoryPrefix.lowercased()) {
            rawValue = String(trimmed.dropFirst(microsoftGraphSensitivityCategoryPrefix.count))
        } else if lowercased.hasPrefix("microsoft-sensitivity-") {
            rawValue = String(trimmed.dropFirst("microsoft-sensitivity-".count))
        } else {
            rawValue = nil
        }

        if let sensitivity = normalizedMicrosoftGraphSensitivity(rawValue) {
            return sensitivity
        }
    }

    return nil
}

private struct MicrosoftGraphLocationMetadata {
    var name: String?
    var type: String?
    var email: String?
    var uri: String?
    var uniqueId: String?
    var uniqueIdType: String?

    var hasAnyProviderValue: Bool {
        type.nilIfBlank != nil
            || email.nilIfBlank != nil
            || uri.nilIfBlank != nil
            || uniqueId.nilIfBlank != nil
            || uniqueIdType.nilIfBlank != nil
    }

    func matches(displayName: String) -> Bool {
        guard let name = name.nilIfBlank else { return false }
        return name.caseInsensitiveCompare(displayName.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
}

fileprivate func microsoftGraphLocationMetadataCategories(from locations: [MicrosoftGraphLocation]) -> [String] {
    locations.enumerated().flatMap { offset, location -> [String] in
        guard location.hasAnyProviderMetadata,
              let displayName = location.displayName.nilIfBlank else { return [] }
        let index = offset + 1
        let prefix = "\(microsoftGraphLocationCategoryPrefix)\(index) "
        return [
            "\(prefix)name \(displayName)",
            location.locationType.nilIfBlank.map { "\(prefix)type \($0)" },
            location.locationEmailAddress.nilIfBlank.map { "\(prefix)email \($0)" },
            location.locationUri.nilIfBlank.map { "\(prefix)uri \($0)" },
            location.uniqueId.nilIfBlank.map { "\(prefix)unique id \($0)" },
            location.uniqueIdType.nilIfBlank.map { "\(prefix)unique id type \($0)" }
        ].compactMap { $0 }
    }
}

fileprivate func microsoftGraphLocationMetadata(from categories: [String]) -> [Int: MicrosoftGraphLocationMetadata] {
    var result: [Int: MicrosoftGraphLocationMetadata] = [:]
    for category in categories {
        guard let parsed = microsoftGraphLocationMetadataField(from: category) else { continue }
        var metadata = result[parsed.index] ?? MicrosoftGraphLocationMetadata()
        switch parsed.field {
        case "name":
            metadata.name = parsed.value
        case "type":
            metadata.type = parsed.value
        case "email":
            metadata.email = parsed.value
        case "uri":
            metadata.uri = parsed.value
        case "unique id":
            metadata.uniqueId = parsed.value
        case "unique id type":
            metadata.uniqueIdType = parsed.value
        default:
            break
        }
        result[parsed.index] = metadata
    }
    return result.filter { $0.value.hasAnyProviderValue }
}

fileprivate func microsoftGraphLocationMetadataCategory(_ category: String) -> Bool {
    microsoftGraphLocationMetadataField(from: category) != nil
}

private func microsoftGraphLocationMetadataField(from category: String) -> (index: Int, field: String, value: String)? {
    let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix(microsoftGraphLocationCategoryPrefix.lowercased()) else { return nil }
    let remainder = String(trimmed.dropFirst(microsoftGraphLocationCategoryPrefix.count))
    guard let indexEnd = remainder.firstIndex(where: { $0 == " " || $0 == "\t" }),
          let index = Int(remainder[..<indexEnd]),
          index > 0 else { return nil }
    let fieldText = remainder[indexEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
    for field in ["unique id type", "unique id", "name", "type", "email", "uri"] {
        let prefix = "\(field) "
        guard fieldText.lowercased().hasPrefix(prefix) else { continue }
        let value = String(fieldText.dropFirst(prefix.count)).nilIfBlank
        guard let value else { return nil }
        return (index, field, value)
    }
    return nil
}

fileprivate func normalizedMicrosoftGraphOnlineMeetingProvider(_ value: String?) -> String? {
    let normalized = value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: "_", with: "")
        .lowercased() ?? ""

    switch normalized {
    case "teams", "teamsonline", "microsoftteams", "teamsforbusiness":
        return "teamsForBusiness"
    case "skype", "skypeforbusiness":
        return "skypeForBusiness"
    case "skypeconsumer", "skypeforconsumer":
        return "skypeForConsumer"
    default:
        return nil
    }
}

fileprivate func microsoftGraphOnlineMeetingProviderMetadataCategory(isOnlineMeeting: Bool?, provider: String?) -> String? {
    if let provider = normalizedMicrosoftGraphOnlineMeetingProvider(provider) {
        return "\(microsoftGraphOnlineMeetingProviderCategoryPrefix)\(provider)"
    }
    return isOnlineMeeting == true ? microsoftGraphOnlineMeetingCategory : nil
}

fileprivate func microsoftGraphOnlineMeetingProviderMetadata(from categories: [String]) -> String? {
    for category in categories {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        let rawValue: String?

        if lowercased.hasPrefix(microsoftGraphOnlineMeetingProviderCategoryPrefix.lowercased()) {
            rawValue = String(trimmed.dropFirst(microsoftGraphOnlineMeetingProviderCategoryPrefix.count))
        } else if lowercased.hasPrefix("microsoft-online-meeting-provider-") {
            rawValue = String(trimmed.dropFirst("microsoft-online-meeting-provider-".count))
        } else if lowercased.hasPrefix("microsoft-onlinemeetingprovider-") {
            rawValue = String(trimmed.dropFirst("microsoft-onlinemeetingprovider-".count))
        } else {
            rawValue = nil
        }

        if let provider = normalizedMicrosoftGraphOnlineMeetingProvider(rawValue) {
            return provider
        }
    }
    return nil
}

fileprivate func microsoftGraphWritableCategories(from categories: [String]) -> [String] {
    normalizedEventCategories(categories.filter { !microsoftGraphProviderMetadataCategory($0) })
}

fileprivate func microsoftGraphHideAttendeesMetadata(from categories: [String]) -> Bool {
    categories.contains { category in
        let normalized = category
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return normalized == microsoftGraphHiddenAttendeesCategory.lowercased().replacingOccurrences(of: " ", with: "-")
            || normalized == "microsoft-hideattendees"
            || normalized == "microsoft-hidden-attendees"
    }
}

fileprivate func microsoftGraphAllowNewTimeProposalsMetadataCategory(for allowNewTimeProposals: Bool?) -> String? {
    allowNewTimeProposals == false ? microsoftGraphNewTimeProposalsDisabledCategory : nil
}

fileprivate func microsoftGraphAllowNewTimeProposalsMetadata(from categories: [String]) -> Bool? {
    for category in categories {
        let normalized = category
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        switch normalized {
        case microsoftGraphNewTimeProposalsDisabledCategory.lowercased().replacingOccurrences(of: " ", with: "-"),
             "microsoft-disable-new-time-proposals",
             "microsoft-new-time-proposals-false",
             "microsoft-allow-new-time-proposals-false":
            return false
        case microsoftGraphNewTimeProposalsEnabledCategory.lowercased().replacingOccurrences(of: " ", with: "-"),
             "microsoft-enable-new-time-proposals",
             "microsoft-new-time-proposals-true",
             "microsoft-allow-new-time-proposals-true":
            return true
        default:
            continue
        }
    }
    return nil
}

fileprivate func microsoftGraphProviderMetadataCategory(_ category: String) -> Bool {
    if microsoftGraphShowAsMetadata(from: [category]) != nil {
        return true
    }
    if microsoftGraphSensitivityMetadata(from: [category]) != nil {
        return true
    }
    if microsoftGraphLocationMetadataCategory(category) {
        return true
    }
    if microsoftGraphOnlineMeetingProviderMetadata(from: [category]) != nil {
        return true
    }
    if microsoftGraphAllowNewTimeProposalsMetadata(from: [category]) != nil {
        return true
    }

    let normalized = category
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "_", with: "-")
        .replacingOccurrences(of: " ", with: "-")
    return normalized == microsoftGraphHiddenAttendeesCategory.lowercased().replacingOccurrences(of: " ", with: "-")
        || normalized == microsoftGraphOnlineMeetingCategory.lowercased().replacingOccurrences(of: " ", with: "-")
        || normalized == "microsoft-hideattendees"
        || normalized == "microsoft-hidden-attendees"
}

fileprivate func microsoftGraphShowAs(
    fromCategories categories: [String],
    status: CalendarEventStatus,
    availability: CalendarEventAvailability
) -> String {
    if let showAs = microsoftGraphShowAsMetadata(from: categories) {
        return showAs
    }
    if availability == .free {
        return "free"
    }
    if status == .tentative {
        return "tentative"
    }
    return "busy"
}

fileprivate func microsoftGraphSensitivity(
    fromCategories categories: [String],
    privacy: CalendarEventPrivacy
) -> String {
    microsoftGraphSensitivityMetadata(from: categories) ?? privacy.graphSensitivity
}

struct MicrosoftGraphEvent: Decodable {
    let id: String
    let removed: MicrosoftGraphRemoved?
    let changeKey: String?
    let subject: String?
    let body: MicrosoftGraphBody?
    let start: MicrosoftGraphDateTimeTimeZone?
    let end: MicrosoftGraphDateTimeTimeZone?
    let isAllDay: Bool?
    let showAs: String?
    let sensitivity: String?
    let importance: String?
    let categories: [String]?
    let hasAttachments: Bool?
    let attachments: [MicrosoftGraphAttachment]?
    let extensions: [MicrosoftGraphOpenExtension]?
    let hideAttendees: Bool?
    let isReminderOn: Bool?
    let reminderMinutesBeforeStart: Int?
    let isCancelled: Bool?
    let iCalUId: String?
    let webLink: String?
    let isOnlineMeeting: Bool?
    let onlineMeetingProvider: String?
    let onlineMeetingUrl: String?
    let onlineMeeting: MicrosoftGraphOnlineMeeting?
    let location: MicrosoftGraphLocation?
    let locations: [MicrosoftGraphLocation]?
    let organizer: MicrosoftGraphRecipient?
    let attendees: [MicrosoftGraphAttendee]?
    let responseStatus: MicrosoftGraphResponseStatus?
    let responseRequested: Bool?
    let allowNewTimeProposals: Bool?
    let createdDateTime: String?
    let lastModifiedDateTime: String?
    let recurrence: MicrosoftGraphPatternedRecurrence?
    let type: String?
    let seriesMasterId: String?
    let originalStart: String?
    let occurrenceId: String?
    var exceptionOccurrences: [MicrosoftGraphEvent]?
    let cancelledOccurrences: [String]?

    private enum CodingKeys: String, CodingKey {
        case id
        case removed = "@removed"
        case changeKey
        case subject
        case body
        case start
        case end
        case isAllDay
        case showAs
        case sensitivity
        case importance
        case categories
        case hasAttachments
        case attachments
        case extensions
        case hideAttendees
        case isReminderOn
        case reminderMinutesBeforeStart
        case isCancelled
        case iCalUId
        case webLink
        case isOnlineMeeting
        case onlineMeetingProvider
        case onlineMeetingUrl
        case onlineMeeting
        case location
        case locations
        case organizer
        case attendees
        case responseStatus
        case responseRequested
        case allowNewTimeProposals
        case createdDateTime
        case lastModifiedDateTime
        case recurrence
        case type
        case seriesMasterId
        case originalStart
        case occurrenceId
        case exceptionOccurrences
        case cancelledOccurrences
    }

    var createdDate: Date? {
        createdDateTime.flatMap { MicrosoftGraphCalendarClient.sharedParser.parseGraphDateTime($0, timeZone: "UTC") }
    }

    var lastModifiedDate: Date? {
        lastModifiedDateTime.flatMap { MicrosoftGraphCalendarClient.sharedParser.parseGraphDateTime($0, timeZone: "UTC") }
    }

    var bestJoinURLString: String? {
        let structuredCandidates = [onlineMeeting?.joinUrl.nilIfBlank, onlineMeetingUrl.nilIfBlank].compactMap { $0 }
        let attachmentCandidates = (attachments ?? []).compactMap(\.sourceUrl.nilIfBlank)
        if let url = MeetingLinkExtractor.preferredLink(eventURL: nil, textFields: structuredCandidates + attachmentCandidates) {
            return url.absoluteString
        }
        if let url = MeetingLinkExtractor.bestLink(eventURL: nil, textFields: structuredCandidates) {
            return url.absoluteString
        }

        if let notes = body?.normalizedContent,
           let url = MeetingLinkExtractor.preferredLink(eventURL: nil, textFields: [notes]) {
            return url.absoluteString
        }

        return webLink.nilIfBlank
    }

    var isSeriesMaster: Bool {
        type?.lowercased() == "seriesmaster" || recurrence != nil
    }

    var privacy: CalendarEventPrivacy {
        CalendarEventPrivacy(graphSensitivity: sensitivity)
    }

    var eventImportance: CalendarEventImportance {
        CalendarEventImportance(graphImportance: importance)
    }

    var eventCategories: [String] {
        normalizedEventCategories(
            (categories ?? [])
                + [
                    microsoftGraphShowAsMetadataCategory(for: showAs),
                    microsoftGraphSensitivityMetadataCategory(for: sensitivity),
                    microsoftGraphOnlineMeetingProviderMetadataCategory(
                        isOnlineMeeting: isOnlineMeeting,
                        provider: onlineMeetingProvider
                    ),
                    hideAttendees == true ? microsoftGraphHiddenAttendeesCategory : nil,
                    microsoftGraphAllowNewTimeProposalsMetadataCategory(for: allowNewTimeProposals)
                ].compactMap { $0 }
                + microsoftGraphLocationMetadataCategories(
                    from: (locations?.isEmpty == false ? locations : location.map { [$0] }) ?? []
                )
        )
    }

    var relatedEvents: [LocalEventRelationship] {
        workingCalendarOpenExtension?.relatedEvents ?? []
    }

    var geoCoordinate: LocalEventGeoCoordinate? {
        workingCalendarOpenExtension?.geoCoordinate
    }

    var reminderOffsets: [Int] {
        guard isReminderOn == true, let reminderMinutesBeforeStart else { return [] }
        return normalizedReminderOffsets([reminderMinutesBeforeStart])
    }

    var isRemoteRemoval: Bool {
        removed != nil
    }

    var shouldImport: Bool {
        !isRemoteRemoval && isCancelled != true
    }

    private var workingCalendarOpenExtension: MicrosoftGraphOpenExtension? {
        extensions?.first(where: { $0.matchesWorkingCalendarExtension })
    }
}

struct MicrosoftGraphRemoved: Decodable {
    let reason: String?
}

struct MicrosoftGraphOpenExtension: Decodable, Hashable {
    let odataType: String?
    let id: String?
    let extensionName: String?
    let relatedEventsJSON: String?
    let geoCoordinateJSON: String?

    private enum CodingKeys: String, CodingKey {
        case odataType = "@odata.type"
        case id
        case extensionName
        case relatedEventsJSON
        case geoCoordinateJSON
    }

    var matchesWorkingCalendarExtension: Bool {
        let expected = MicrosoftGraphCalendarClient.workingCalendarExtensionNamePreview()
        if extensionName?.caseInsensitiveCompare(expected) == .orderedSame {
            return true
        }
        if id?.caseInsensitiveCompare(expected) == .orderedSame {
            return true
        }
        return id?.lowercased().hasSuffix(".\(expected.lowercased())") == true
    }

    var relatedEvents: [LocalEventRelationship] {
        guard let relatedEventsJSON,
              let data = relatedEventsJSON.data(using: .utf8),
              let relationships = try? JSONDecoder().decode([LocalEventRelationship].self, from: data) else {
            return []
        }
        return normalizedEventRelationships(relationships)
    }

    var geoCoordinate: LocalEventGeoCoordinate? {
        guard let geoCoordinateJSON,
              let data = geoCoordinateJSON.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(LocalEventGeoCoordinate.self, from: data)
    }
}

private struct MicrosoftGraphWorkingCalendarExtensionWrite: Encodable {
    let odataType = "#microsoft.graph.openTypeExtension"
    let extensionName: String
    let relatedEventsJSON: String
    let geoCoordinateJSON: String

    private enum CodingKeys: String, CodingKey {
        case odataType = "@odata.type"
        case extensionName
        case relatedEventsJSON
        case geoCoordinateJSON
    }

    var hasLocalMetadata: Bool {
        relatedEventsJSON != "[]" || !geoCoordinateJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct MicrosoftGraphAttachment: Decodable, Hashable {
    let odataType: String?
    let id: String?
    let name: String?
    let contentType: String?
    let isInline: Bool?
    let size: Int?
    let lastModifiedDateTime: String?
    let sourceUrl: String?

    private enum CodingKeys: String, CodingKey {
        case odataType = "@odata.type"
        case id
        case name
        case contentType
        case isInline
        case size
        case lastModifiedDateTime
        case sourceUrl
    }
}

private struct MicrosoftGraphReferenceAttachmentWrite: Encodable {
    let odataType = "#microsoft.graph.referenceAttachment"
    let name: String
    let contentType: String?
    let sourceUrl: String

    private enum CodingKeys: String, CodingKey {
        case odataType = "@odata.type"
        case name
        case contentType
        case sourceUrl
    }
}

private struct MicrosoftGraphCalendarResource: Decodable {
    let id: String?
    let name: String?
    let color: String?
    let canEdit: Bool?
}

private struct MicrosoftGraphCollection<Value: Decodable>: Decodable {
    let value: [Value]
    let nextLink: String?
    let deltaLink: String?

    private enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
        case deltaLink = "@odata.deltaLink"
    }
}

private struct MicrosoftGraphUserProfile: Decodable {
    let mail: String?
    let userPrincipalName: String?
    let otherMails: [String]?
    let proxyAddresses: [String]?
}

private struct MicrosoftGraphEventsFetchResult {
    let events: [MicrosoftGraphEvent]
    let deltaLink: String
}

private struct MicrosoftGraphEventWriteResponse: Decodable {
    let id: String?
    let changeKey: String?
}

private struct MicrosoftGraphOccurrenceDeleteTarget {
    let eventID: String
    let remoteETag: String
}

private struct MicrosoftGraphDetachedOccurrencePatchTarget {
    let eventID: String
    let remoteETag: String
    let occurrence: LocalDetachedOccurrence
}

private struct MicrosoftGraphRecurringExceptionWriteTargets {
    let occurrencesToDelete: [MicrosoftGraphOccurrenceDeleteTarget]
    let detachedOccurrencesToPatch: [MicrosoftGraphDetachedOccurrencePatchTarget]
}

struct MicrosoftGraphBody: Codable {
    let contentType: String?
    let content: String?

    var normalizedContent: String? {
        guard let content = content.nilIfBlank else { return nil }
        guard contentType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "html" else {
            return content
        }
        return content.normalizedHTMLBodyText.nilIfBlank
    }
}

struct MicrosoftGraphDateTimeTimeZone: Decodable {
    let dateTime: String?
    let timeZone: String?

    var resolvedDate: Date? {
        guard let dateTime = dateTime.nilIfBlank else { return nil }
        return MicrosoftGraphCalendarClient.sharedParser.parseGraphDateTime(dateTime, timeZone: timeZone)
    }

    func icsDateLine(prefix: String, isAllDay: Bool) -> String? {
        guard let dateTime = dateTime.nilIfBlank else { return nil }

        if isAllDay {
            let datePrefix = String(dateTime.prefix(10)).replacingOccurrences(of: "-", with: "")
            guard datePrefix.count == 8 else { return nil }
            return "\(prefix);VALUE=DATE:\(datePrefix)"
        }

        guard let date = MicrosoftGraphCalendarClient.sharedParser.parseGraphDateTime(dateTime, timeZone: timeZone) else {
            return nil
        }
        let graphTimeZone = MicrosoftGraphCalendarClient.sharedParser.graphTimeZone(for: timeZone)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = graphTimeZone.timeZone
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return "\(prefix);TZID=\(graphTimeZone.identifier):\(formatter.string(from: date))"
    }
}

struct MicrosoftGraphLocation: Codable {
    let displayName: String?
    let locationEmailAddress: String?
    let locationUri: String?
    let locationType: String?
    let uniqueId: String?
    let uniqueIdType: String?

    init(
        displayName: String?,
        locationEmailAddress: String? = nil,
        locationUri: String? = nil,
        locationType: String? = nil,
        uniqueId: String? = nil,
        uniqueIdType: String? = nil
    ) {
        self.displayName = displayName
        self.locationEmailAddress = locationEmailAddress
        self.locationUri = locationUri
        self.locationType = locationType
        self.uniqueId = uniqueId
        self.uniqueIdType = uniqueIdType
    }

    var hasAnyProviderMetadata: Bool {
        locationEmailAddress.nilIfBlank != nil
            || locationUri.nilIfBlank != nil
            || locationType.nilIfBlank != nil
            || uniqueId.nilIfBlank != nil
            || uniqueIdType.nilIfBlank != nil
    }
}

struct MicrosoftGraphRecipient: Decodable {
    let emailAddress: MicrosoftGraphEmailAddress
}

struct MicrosoftGraphEmailAddress: Codable {
    let name: String?
    let address: String?
}

struct MicrosoftGraphAttendee: Decodable {
    let emailAddress: MicrosoftGraphEmailAddress
    let status: MicrosoftGraphResponseStatus?
    let type: String?
}

struct MicrosoftGraphResponseStatus: Decodable {
    let response: String?
}

struct MicrosoftGraphOnlineMeeting: Decodable {
    let joinUrl: String?
}

private struct MicrosoftGraphEventWriteRequest: Encodable {
    let transactionId: String?
    let subject: String
    let body: MicrosoftGraphBody?
    let start: MicrosoftGraphDateTimeTimeZoneWrite
    let end: MicrosoftGraphDateTimeTimeZoneWrite
    let isAllDay: Bool
    let showAs: String
    let sensitivity: String
    let importance: String
    let categories: [String]?
    let isReminderOn: Bool
    let reminderMinutesBeforeStart: Int?
    let isOnlineMeeting: Bool?
    let onlineMeetingProvider: String?
    let hideAttendees: Bool
    let allowNewTimeProposals: Bool?
    let location: MicrosoftGraphLocation?
    let locations: [MicrosoftGraphLocation]
    let responseRequested: Bool
    let attendees: [MicrosoftGraphAttendeeWrite]?
    let recurrence: MicrosoftGraphPatternedRecurrence?
    let encodesNilRecurrence: Bool

    private enum CodingKeys: String, CodingKey {
        case transactionId
        case subject
        case body
        case start
        case end
        case isAllDay
        case showAs
        case sensitivity
        case importance
        case categories
        case isReminderOn
        case reminderMinutesBeforeStart
        case isOnlineMeeting
        case onlineMeetingProvider
        case hideAttendees
        case allowNewTimeProposals
        case location
        case locations
        case responseRequested
        case attendees
        case recurrence
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(transactionId, forKey: .transactionId)
        try container.encode(subject, forKey: .subject)
        try container.encodeIfPresent(body, forKey: .body)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(isAllDay, forKey: .isAllDay)
        try container.encode(showAs, forKey: .showAs)
        try container.encode(sensitivity, forKey: .sensitivity)
        try container.encode(importance, forKey: .importance)
        try container.encodeIfPresent(categories, forKey: .categories)
        try container.encode(isReminderOn, forKey: .isReminderOn)
        try container.encodeIfPresent(reminderMinutesBeforeStart, forKey: .reminderMinutesBeforeStart)
        try container.encodeIfPresent(isOnlineMeeting, forKey: .isOnlineMeeting)
        try container.encodeIfPresent(onlineMeetingProvider, forKey: .onlineMeetingProvider)
        try container.encode(hideAttendees, forKey: .hideAttendees)
        try container.encodeIfPresent(allowNewTimeProposals, forKey: .allowNewTimeProposals)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encode(locations, forKey: .locations)
        try container.encode(responseRequested, forKey: .responseRequested)
        try container.encodeIfPresent(attendees, forKey: .attendees)
        if let recurrence {
            try container.encode(recurrence, forKey: .recurrence)
        } else if encodesNilRecurrence {
            try container.encodeNil(forKey: .recurrence)
        }
    }
}

private struct MicrosoftGraphDateTimeTimeZoneWrite: Encodable {
    let dateTime: String
    let timeZone: String
}

private struct MicrosoftGraphAttendeeWrite: Encodable {
    let emailAddress: MicrosoftGraphEmailAddress
    let type: String
}

struct MicrosoftGraphPatternedRecurrence: Codable {
    let pattern: MicrosoftGraphRecurrencePattern
    let range: MicrosoftGraphRecurrenceRange
}

struct MicrosoftGraphRecurrencePattern: Codable {
    let type: String
    let interval: Int
    var daysOfWeek: [String]? = nil
    var firstDayOfWeek: String? = nil
    var dayOfMonth: Int? = nil
    var month: Int? = nil
    var index: String? = nil
}

struct MicrosoftGraphRecurrenceRange: Codable {
    let type: String
    let startDate: String
    var endDate: String? = nil
    var recurrenceTimeZone: String? = nil
    var numberOfOccurrences: Int? = nil
}

private struct MicrosoftGraphResponseRequest: Encodable {
    let comment: String
    let sendResponse: Bool
}

private struct MicrosoftGraphErrorResponse: Decodable {
    let error: MicrosoftGraphErrorBody?
}

private struct MicrosoftGraphErrorBody: Decodable {
    let message: String?
}

private extension MicrosoftGraphCalendarClient {
    static let sharedParser = MicrosoftGraphCalendarClient()
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

    init(graphSensitivity: String?) {
        switch graphSensitivity?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "private", "personal":
            self = .private
        case "confidential":
            self = .confidential
        default:
            self = .public
        }
    }

    var graphSensitivity: String {
        switch self {
        case .public:
            return "normal"
        case .private:
            return "private"
        case .confidential:
            return "confidential"
        }
    }
}

private extension CalendarEventImportance {
    var graphImportance: String {
        switch self {
        case .low:
            return "low"
        case .normal:
            return "normal"
        case .high:
            return "high"
        }
    }

    init(graphImportance: String?) {
        switch graphImportance?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "low":
            self = .low
        case "high":
            self = .high
        default:
            self = .normal
        }
    }

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
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var normalizedHTMLBodyText: String {
        var text = replacingAnchorTagsWithTextAndURL()
        text = text
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</(p|div|li|tr|h[1-6])>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<li\\b[^>]*>", with: "- ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .decodedCommonHTMLEntities
            .replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n[ \\t]+", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    private var decodedCommonHTMLEntities: String {
        replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private func replacingAnchorTagsWithTextAndURL() -> String {
        let pattern = #"<a\b[^>]*\bhref\s*=\s*(["'])(.*?)\1[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return self
        }

        var text = self
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, options: [], range: range).reversed() {
            guard match.numberOfRanges >= 4,
                  let matchRange = Range(match.range(at: 0), in: text),
                  let urlRange = Range(match.range(at: 2), in: text),
                  let labelRange = Range(match.range(at: 3), in: text)
            else { continue }

            let url = String(text[urlRange]).decodedCommonHTMLEntities.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = String(text[labelRange])
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .decodedCommonHTMLEntities
                .replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let replacement: String
            if label.isEmpty {
                replacement = url
            } else if label.range(of: url, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                replacement = label
            } else {
                replacement = "\(label) \(url)"
            }
            text.replaceSubrange(matchRange, with: replacement)
        }
        return text
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        self?.nilIfBlank
    }
}

private extension Date {
    func isSameOccurrenceStart(as other: Date) -> Bool {
        abs(timeIntervalSince(other)) < 1
    }

    func isSameOccurrenceStart(as other: Date, isAllDay: Bool) -> Bool {
        if isAllDay {
            return Calendar.current.isDate(self, inSameDayAs: other)
        }
        return isSameOccurrenceStart(as: other)
    }
}
