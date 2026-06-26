import Foundation

struct GoogleCalendarInfo: Hashable {
    let id: String
    let summary: String
    let backgroundColor: String
    let accessRole: String
    let isPrimary: Bool
    let defaultReminderOffsets: [Int]

    var allowsEventWrite: Bool {
        switch accessRole.lowercased() {
        case "owner", "writer":
            return true
        default:
            return false
        }
    }

    var allowsResponses: Bool {
        allowsEventWrite
    }

    var accountIdentityEmail: String? {
        guard isPrimary else { return nil }
        return id.normalizedGoogleIdentityEmail
    }
}

struct GoogleCalendarPayload {
    let calendar: GoogleCalendarInfo
    let events: [GoogleCalendarEvent]
    let deletedRemoteObjectURLs: Set<String>
    let cancelledRemoteOccurrences: Set<LocalProviderRemoteOccurrenceCancellation>
    let isIncremental: Bool
    let syncToken: String
    let windowStartDate: Date
    let windowEndDate: Date

    var syncState: GoogleCalendarSyncState {
        GoogleCalendarSyncState(
            googleCalendarID: calendar.id,
            syncToken: syncToken,
            windowStartDate: windowStartDate,
            windowEndDate: windowEndDate
        )
    }

    var accountIdentityEmails: [String] {
        GoogleCalendarClient.sharedParser.googleAccountIdentityEmails(calendar: calendar, events: events)
    }
}

struct GoogleCalendarWriteResult {
    let remoteObjectURLString: String
    let remoteETag: String
}

struct GoogleRecurringExceptionWritePlan: Equatable {
    let occurrenceIDsToDelete: [String]
    let occurrenceIDsToPatch: [String]
}

enum GoogleCalendarClientError: LocalizedError {
    case missingAccessToken
    case missingRefreshToken
    case invalidAccountURL
    case calendarNotFound
    case remoteObjectMissing
    case invalidRemoteObject
    case invalidEventDate
    case selfAttendeeNotFound
    case unsupportedReminderOverrides([Int])
    case unsupportedAttachmentCount(Int)
    case paginationLoop(URL)
    case paginationLimitExceeded(URL)
    case remoteConflict(URL)
    case retryAfter(Int, URL, String)
    case httpStatus(Int, URL, String)

    var errorDescription: String? {
        switch self {
        case .missingAccessToken:
            return "Google Calendar access token is missing."
        case .missingRefreshToken:
            return "Reconnect this Google Calendar account; the stored credential cannot refresh access tokens."
        case .invalidAccountURL:
            return "Google Calendar API endpoint is invalid."
        case .calendarNotFound:
            return "Could not find the Google calendar for this event."
        case .remoteObjectMissing:
            return "This event does not have a Google Calendar event ID yet."
        case .invalidRemoteObject:
            return "This Google Calendar event link is not readable."
        case .invalidEventDate:
            return "This Google Calendar event is missing a start or end date."
        case .selfAttendeeNotFound:
            return "Could not find your attendee entry on this Google Calendar event."
        case .unsupportedReminderOverrides(let offsets):
            return "Google Calendar can save at most 5 override reminders. This event has reminders at \(offsets.map(String.init).joined(separator: ",")) minutes before start."
        case .unsupportedAttachmentCount(let count):
            return "Google Calendar can save at most 25 event attachments. This event has \(count)."
        case .paginationLoop(let url):
            return "Google Calendar returned a repeated sync page for \(url.host ?? url.absoluteString)."
        case .paginationLimitExceeded(let url):
            return "Google Calendar returned too many sync pages for \(url.host ?? url.absoluteString)."
        case .remoteConflict(let url):
            let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            let eventName = name.isEmpty ? "this event" : name
            return "Google Calendar refused to save \(eventName) because it changed remotely. Sync this calendar and try again."
        case .retryAfter(let seconds, _, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "Google Calendar asked Working Calendar to retry in \(seconds) seconds."
            }
            return "Google Calendar asked Working Calendar to retry in \(seconds) seconds: \(detail)"
        case .httpStatus(let status, let url, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "Google Calendar returned HTTP \(status) for \(url.host ?? url.absoluteString)."
            }
            return "Google Calendar returned HTTP \(status): \(detail)"
        }
    }

    var allowsFullSyncFallback: Bool {
        switch self {
        case .httpStatus(let status, _, _):
            return status == 410 || status == 400
        case .missingAccessToken, .missingRefreshToken, .invalidAccountURL, .calendarNotFound, .remoteObjectMissing, .invalidRemoteObject, .invalidEventDate, .selfAttendeeNotFound, .unsupportedReminderOverrides, .unsupportedAttachmentCount, .paginationLoop, .paginationLimitExceeded, .remoteConflict, .retryAfter:
            return false
        }
    }
}

extension GoogleCalendarClientError: ProviderRetryAfterError {
    var providerRetryAfterSeconds: Int? {
        guard case .retryAfter(let seconds, _, _) = self else { return nil }
        return seconds
    }
}

final class GoogleCalendarClient {
    private static let maxGooglePageCount = 10_000
    private static let maxReminderOverrideCount = 5
    private static let maxAttachmentCount = 25
    fileprivate static let workingCategoriesExtendedPropertyKey = "workingCalendar.categories"
    fileprivate static let relatedEventsExtendedPropertyKey = "workingCalendar.relatedEvents"
    fileprivate static let geoCoordinateExtendedPropertyKey = "workingCalendar.geoCoordinate"
    fileprivate static let attendeesOmittedMetadataCategory = "Google attendees omitted"
    fileprivate static let guestsHiddenMetadataCategory = "Google guest list hidden"
    fileprivate static let guestsCannotInviteMetadataCategory = "Google guests cannot invite"
    fileprivate static let guestsCanModifyMetadataCategory = "Google guests can modify"
    fileprivate static let conferenceTypeCategoryPrefix = "Google conference "
    fileprivate static let visibilityCategoryPrefix = "Google visibility "
    fileprivate static let eventTypeCategoryPrefix = "Google event type "
    fileprivate static let workingLocationTypeCategoryPrefix = "Google working location "
    fileprivate static let workingLocationBuildingCategoryPrefix = "Google working location building "
    fileprivate static let workingLocationFloorCategoryPrefix = "Google working location floor "
    fileprivate static let workingLocationFloorSectionCategoryPrefix = "Google working location floor section "
    fileprivate static let workingLocationDeskCategoryPrefix = "Google working location desk "
    fileprivate static let outOfOfficeAutoDeclineCategoryPrefix = "Google out of office auto decline "
    fileprivate static let outOfOfficeDeclineMessageCategoryPrefix = "Google out of office decline message "
    fileprivate static let focusTimeAutoDeclineCategoryPrefix = "Google focus time auto decline "
    fileprivate static let focusTimeDeclineMessageCategoryPrefix = "Google focus time decline message "
    fileprivate static let focusTimeChatStatusCategoryPrefix = "Google focus time chat status "
    private static let defaultAPIURL = URL(string: "https://www.googleapis.com/calendar/v3")!

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

    func fetchCalendarPayloads(
        account: CalendarProviderAccount,
        startDate: Date,
        endDate: Date,
        syncStates: [GoogleCalendarSyncState] = []
    ) async throws -> [GoogleCalendarPayload] {
        let calendars = try await fetchCalendars(account: account)
        let syncStateByCalendarID = Dictionary(uniqueKeysWithValues: syncStates.map { ($0.googleCalendarID, $0) })
        var payloads: [GoogleCalendarPayload] = []

        for calendar in calendars {
            if let syncState = syncStateByCalendarID[calendar.id],
               syncState.coversWindow(startDate: startDate, endDate: endDate),
               let syncToken = syncState.syncToken.nilIfBlank {
                do {
                    payloads.append(try await fetchIncrementalCalendarPayload(
                        account: account,
                        calendar: calendar,
                        syncToken: syncToken,
                        syncedWindowStartDate: syncState.windowStartDate ?? startDate,
                        syncedWindowEndDate: syncState.windowEndDate ?? endDate
                    ))
                    continue
                } catch let error as GoogleCalendarClientError where error.allowsFullSyncFallback {
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
        event: GoogleCalendarEvent,
        calendar: GoogleCalendarInfo,
        account: CalendarProviderAccount
    ) throws -> String {
        let masterUIDByGoogleID = masterUIDByGoogleID(for: [event])
        let excludedStartsByUID = excludedStartsByUID(for: [event], masterUIDByGoogleID: masterUIDByGoogleID)
        let lines = try eventLines(
            event: event,
            calendar: calendar,
            account: account,
            masterUIDByGoogleID: masterUIDByGoogleID,
            excludedStartsByUID: excludedStartsByUID
        )
        return calendarText(calendar: calendar, eventLines: [lines])
    }

    func annotatedICSText(
        events: [GoogleCalendarEvent],
        calendar: GoogleCalendarInfo,
        account: CalendarProviderAccount
    ) throws -> String {
        let masterUIDByGoogleID = masterUIDByGoogleID(for: events)
        let excludedStartsByUID = excludedStartsByUID(for: events, masterUIDByGoogleID: masterUIDByGoogleID)
        var vevents: [[String]] = []
        for event in events where !event.isCancelled {
            guard let lines = try? eventLines(
                event: event,
                calendar: calendar,
                account: account,
                masterUIDByGoogleID: masterUIDByGoogleID,
                excludedStartsByUID: excludedStartsByUID
            ) else {
                continue
            }
            vevents.append(lines)
        }

        guard !vevents.isEmpty else {
            throw GoogleCalendarClientError.invalidEventDate
        }

        return calendarText(calendar: calendar, eventLines: vevents)
    }

    func remoteObjectURLStringsForImportedEvents(
        events: [GoogleCalendarEvent],
        calendar: GoogleCalendarInfo,
        account: CalendarProviderAccount
    ) -> Set<String> {
        return Set(events.compactMap { event in
            guard !event.isCancelled else { return nil }
            return remoteObjectURLString(event: event, calendar: calendar, account: account)
        })
    }

    private func eventLines(
        event: GoogleCalendarEvent,
        calendar: GoogleCalendarInfo,
        account: CalendarProviderAccount,
        masterUIDByGoogleID: [String: String],
        excludedStartsByUID: [String: [GoogleEventDateTime]]
    ) throws -> [String] {
        guard !event.isCancelled,
              let start = event.start?.dateLines(prefix: "DTSTART"),
              let end = event.end?.dateLines(prefix: "DTEND")
        else {
            throw GoogleCalendarClientError.invalidEventDate
        }

        let calendarID = localCalendarID(for: account, googleCalendarID: calendar.id)
        let remoteObjectURL = remoteObjectURLString(account: account, calendarID: calendar.id, eventID: event.id)
        let updatedAt = event.updatedDate ?? Date()
        let uid = uid(for: event, masterUIDByGoogleID: masterUIDByGoogleID)

        var lines = [
            "BEGIN:VEVENT",
            "UID:\(escapeICSText(uid))",
            "DTSTAMP:\(icsDateTimeFormatter.string(from: updatedAt))",
            "LAST-MODIFIED:\(icsDateTimeFormatter.string(from: updatedAt))",
            "SUMMARY:\(escapeICSText(event.summary.nilIfBlank ?? "Google Calendar event"))",
            "X-WORKING-CALENDAR-ID:\(escapeICSText(calendarID))",
            "X-WORKING-CALENDAR-TITLE:\(escapeICSText(calendar.summary))",
            "X-WORKING-CALENDAR-COLOR:\(escapeICSText(sanitizedColor(calendar.backgroundColor)))",
            "X-WORKING-CALENDAR-ALLOWS-EVENT-WRITE:\(calendar.allowsEventWrite ? "TRUE" : "FALSE")",
            "X-WORKING-CALENDAR-ALLOWS-RESPONSES:\(calendar.allowsResponses ? "TRUE" : "FALSE")",
            "X-WORKING-REMOTE-OBJECT-URL:\(escapeICSText(remoteObjectURL))"
        ]
        if let eTag = event.etag.nilIfBlank {
            lines.append("X-WORKING-REMOTE-ETAG:\(escapeICSText(eTag))")
        }

        if let createdAt = event.createdDate {
            lines.append("CREATED:\(icsDateTimeFormatter.string(from: createdAt))")
        }
        if event.sequenceValue > 0 {
            lines.append("SEQUENCE:\(event.sequenceValue)")
        }

        lines.append(start)
        lines.append(end)
        if event.isRecurringInstance,
           let recurrenceID = event.originalStartTime?.dateLines(prefix: "RECURRENCE-ID") {
            lines.append(recurrenceID)
        }
        if let status = event.status?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
           status == "TENTATIVE" || status == "CONFIRMED" {
            lines.append("STATUS:\(status)")
        }
        if event.privacy != .public {
            lines.append("CLASS:\(event.privacy.icsClass)")
        }
        if !event.categories.isEmpty {
            lines.append("CATEGORIES:\(event.categories.map(escapeICSText).joined(separator: ","))")
        }
        lines.append("TRANSP:\((event.transparency ?? "").lowercased() == "transparent" ? "TRANSPARENT" : "OPAQUE")")
        lines.append(contentsOf: alarmLines(
            reminderOffsets: event.reminderOffsets(defaults: calendar.defaultReminderOffsets),
            title: event.summary.nilIfBlank ?? "Google Calendar event"
        ))

        if let organizer = event.organizer, organizer.email.nilIfBlank != nil || organizer.displayName.nilIfBlank != nil {
            var params: [String] = []
            if let name = organizer.displayName.nilIfBlank {
                params.append("CN=\"\(escapeICSParameter(name))\"")
            }
            lines.append("ORGANIZER\(params.isEmpty ? "" : ";\(params.joined(separator: ";"))"):\(mailtoValue(email: organizer.email, fallbackName: organizer.displayName))")
        }

        for attendee in event.attendees ?? [] {
            guard attendee.email.nilIfBlank != nil || attendee.displayName.nilIfBlank != nil else { continue }
            var params = [
                "PARTSTAT=\(partStat(for: attendee.responseStatus))",
                attendee.optional == true ? "ROLE=OPT-PARTICIPANT" : "ROLE=REQ-PARTICIPANT"
            ]
            if attendee.resource == true {
                params.append("CUTYPE=RESOURCE")
            }
            if attendee.resource != true && googleAttendeeNeedsResponse(attendee.responseStatus) {
                params.append("RSVP=TRUE")
            }
            let identityEmails = googleIdentityEmails(
                calendarID: calendar.id,
                account: account,
                isPrimaryCalendar: calendar.isPrimary
            )
            if googleAttendeeMatchesCurrentUser(attendee, identityEmails: identityEmails) {
                params.append("X-WORKING-CURRENT-USER=TRUE")
            }
            if let name = attendee.displayName.nilIfBlank {
                params.append("CN=\"\(escapeICSParameter(name))\"")
            }
            lines.append("ATTENDEE;\(params.joined(separator: ";")):\(mailtoValue(email: attendee.email, fallbackName: attendee.displayName))")
        }

        if let myResponse = event.myResponseStatus(calendar: calendar, account: account) {
            lines.append("X-WORKING-MY-RESPONSE:\(myResponse.rawValue)")
        }

        if let location = event.displayLocationString {
            lines.append("LOCATION:\(escapeICSText(location))")
        }
        if let description = event.description.nilIfBlank {
            lines.append("DESCRIPTION:\(escapeICSText(description))")
        }
        if let urlString = event.bestJoinURLString {
            lines.append("URL:\(escapeICSText(urlString))")
        }
        lines.append(contentsOf: googleAttachmentLines(event.attachments))
        lines.append(contentsOf: googleRelationshipLines(event.relatedEvents))
        if let geoCoordinate = event.geoCoordinate {
            lines.append("GEO:\(geoFloatString(geoCoordinate.latitude));\(geoFloatString(geoCoordinate.longitude))")
        }

        for recurrenceLine in event.recurrence ?? [] {
            let trimmed = recurrenceLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let uppercased = trimmed.uppercased()
            guard uppercased.hasPrefix("RRULE:")
                    || uppercased.hasPrefix("RDATE")
                    || uppercased.hasPrefix("EXDATE")
            else { continue }
            lines.append(trimmed)
        }

        for excludedStart in excludedStartsByUID[uid, default: []] {
            if let line = excludedStart.dateLines(prefix: "EXDATE") {
                lines.append(line)
            }
        }

        lines.append("END:VEVENT")
        return lines
    }

    private func googleAttachmentLines(_ attachments: [GoogleEventAttachment]?) -> [String] {
        (attachments ?? []).compactMap { attachment in
            guard let fileURL = attachment.fileUrl.nilIfBlank else { return nil }
            var params = ["VALUE=URI"]
            if let mimeType = attachment.mimeType.nilIfBlank {
                params.append("FMTTYPE=\(escapeICSParameter(mimeType))")
            }
            if let title = attachment.title.nilIfBlank {
                params.append("X-FILENAME=\"\(escapeICSParameter(title))\"")
            }
            return "ATTACH;\(params.joined(separator: ";")):\(escapeICSText(fileURL))"
        }
    }

    private func googleRelationshipLines(_ relationships: [LocalEventRelationship]) -> [String] {
        normalizedEventRelationships(relationships).map { relationship in
            "RELATED-TO;RELTYPE=\(escapeICSParameter(relationship.relationType)):\(escapeICSText(relationship.externalUID))"
        }
    }

    private func calendarText(calendar: GoogleCalendarInfo, eventLines: [[String]]) -> String {
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Working Calendar//Google Calendar//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
            "X-WR-CALNAME:\(escapeICSText(calendar.summary))"
        ]
        lines.append(contentsOf: eventLines.flatMap { $0 })
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private func masterUIDByGoogleID(for events: [GoogleCalendarEvent]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: events
            .filter { !$0.isRecurringInstance }
            .map { ($0.id, uid(for: $0, masterUIDByGoogleID: [:])) })
    }

    private func excludedStartsByUID(
        for events: [GoogleCalendarEvent],
        masterUIDByGoogleID: [String: String]
    ) -> [String: [GoogleEventDateTime]] {
        var excluded: [String: [GoogleEventDateTime]] = [:]

        for event in events where event.isCancelled && event.isRecurringInstance {
            guard let originalStartTime = event.originalStartTime else { continue }
            let uid = uid(for: event, masterUIDByGoogleID: masterUIDByGoogleID)
            excluded[uid, default: []].append(originalStartTime)
        }

        return excluded
    }

    private func uid(for event: GoogleCalendarEvent, masterUIDByGoogleID: [String: String]) -> String {
        if let recurringEventID = event.recurringEventId.nilIfBlank,
           let masterUID = masterUIDByGoogleID[recurringEventID] {
            return masterUID
        }
        if let uid = event.iCalUID.nilIfBlank {
            return uid
        }
        if let recurringEventID = event.recurringEventId.nilIfBlank {
            return "\(recurringEventID)@google-calendar"
        }
        return "\(event.id)@google-calendar"
    }

    func putEvent(
        _ event: LocalCalendarEvent,
        localCalendar: LocalCalendar,
        account: CalendarProviderAccount
    ) async throws -> GoogleCalendarWriteResult {
        let target = try remoteTarget(for: event, localCalendar: localCalendar, account: account)

        let response: GoogleEventResponse
        var createdEventID: String?
        if let eventID = target.eventID {
            let requestBody = try googleWriteRequest(from: event)
            let encodedBody = try JSONEncoder().encode(requestBody)
            let url = try eventURL(
                account: account,
                calendarID: target.calendarID,
                eventID: eventID,
                queryItems: eventModificationQueryItems(supportsAttachments: requestBody.hasAttachments)
            )
            response = try await jsonRequest(
                account: account,
                url: url,
                method: "PATCH",
                body: encodedBody,
                headers: conditionalHeaders(remoteETag: event.remoteETag)
            )
        } else {
            let eventID = googleWritableEventID(for: event)
            createdEventID = eventID
            let requestBody = try googleWriteRequest(from: event, eventID: eventID)
            let encodedBody = try JSONEncoder().encode(requestBody)
            let url = try eventsURL(
                account: account,
                calendarID: target.calendarID,
                queryItems: eventModificationQueryItems(supportsAttachments: requestBody.hasAttachments)
            )
            do {
                response = try await jsonRequest(account: account, url: url, method: "POST", body: encodedBody)
            } catch GoogleCalendarClientError.httpStatus(let status, _, _) where status == 409 {
                let existingURL = try eventURL(account: account, calendarID: target.calendarID, eventID: eventID)
                response = try await jsonRequest(account: account, url: existingURL, method: "GET", body: nil)
            }
        }

        let remoteEventID = response.id.nilIfBlank ?? target.eventID ?? createdEventID ?? event.id
        try await writeRecurringExceptionState(
            for: event,
            account: account,
            calendarID: target.calendarID,
            eventID: remoteEventID
        )

        return GoogleCalendarWriteResult(
            remoteObjectURLString: remoteObjectURLString(
                account: account,
                calendarID: target.calendarID,
                eventID: remoteEventID
            ),
            remoteETag: response.etag ?? ""
        )
    }

    func deleteEvent(account: CalendarProviderAccount, remoteObjectURLString: String, remoteETag: String = "") async throws {
        guard let target = remoteTarget(from: remoteObjectURLString, account: account),
              let eventID = target.eventID
        else {
            throw GoogleCalendarClientError.remoteObjectMissing
        }

        let url = try eventURL(account: account, calendarID: target.calendarID, eventID: eventID)
        try await emptyRequest(
            account: account,
            url: url,
            method: "DELETE",
            headers: conditionalHeaders(remoteETag: remoteETag)
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
            throw GoogleCalendarClientError.remoteObjectMissing
        }

        let targetEventID = try await targetEventIDForOccurrenceResponse(
            account: account,
            calendarID: target.calendarID,
            eventID: eventID,
            occurrenceStartDate: occurrenceStartDate,
            occurrenceIsAllDay: occurrenceIsAllDay,
            occurrenceTimeZoneIdentifier: occurrenceTimeZoneIdentifier
        )
        let getURL = try eventURL(account: account, calendarID: target.calendarID, eventID: targetEventID)
        let event: GoogleCalendarEvent = try await jsonRequest(account: account, url: getURL, method: "GET", body: nil)
        let body = try JSONEncoder().encode(responsePatchRequest(
            event: event,
            calendarID: target.calendarID,
            account: account,
            response: response
        ))
        let patchURL = try eventURL(
            account: account,
            calendarID: target.calendarID,
            eventID: targetEventID,
            queryItems: eventModificationQueryItems(sendUpdates: "all")
        )
        let patchResponse: GoogleEventResponse = try await jsonRequest(account: account, url: patchURL, method: "PATCH", body: body)
        return targetEventID == eventID ? patchResponse.etag : nil
    }

    func encodedResponsePatchPayloadPreview(
        event: GoogleCalendarEvent,
        calendarID: String,
        account: CalendarProviderAccount,
        response: CalendarEventResponse
    ) throws -> Data {
        try JSONEncoder().encode(responsePatchRequest(
            event: event,
            calendarID: calendarID,
            account: account,
            response: response
        ))
    }

    func remoteObjectURLString(event: GoogleCalendarEvent, calendar: GoogleCalendarInfo, account: CalendarProviderAccount) -> String {
        remoteObjectURLString(account: account, calendarID: calendar.id, eventID: event.id)
    }

    func isCalendarID(_ calendarID: String, ownedBy account: CalendarProviderAccount) -> Bool {
        calendarID.hasPrefix(localCalendarIDPrefix(for: account))
    }

    func localCalendarIDPrefix(for account: CalendarProviderAccount) -> String {
        "local-calendar-google-\(account.id)-"
    }

    func paginationValidationCountPreview(
        pageTokens: [String?],
        account: CalendarProviderAccount
    ) throws -> Int {
        var seenPageTokens: Set<String> = []
        var pageCount = 0
        for pageToken in pageTokens {
            try validateGooglePage(
                pageToken: pageToken,
                account: account,
                seenPageTokens: &seenPageTokens,
                pageCount: &pageCount
            )
        }
        return pageCount
    }

    private func fetchCalendars(account: CalendarProviderAccount) async throws -> [GoogleCalendarInfo] {
        var calendars: [GoogleCalendarInfo] = []
        var pageToken: String?
        var seenPageTokens: Set<String> = []
        var pageCount = 0

        repeat {
            try validateGooglePage(
                pageToken: pageToken,
                account: account,
                seenPageTokens: &seenPageTokens,
                pageCount: &pageCount
            )
            var queryItems = [URLQueryItem(name: "maxResults", value: "250")]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }

            let url = try apiURL(account: account, path: ["users", "me", "calendarList"], queryItems: queryItems)
            let response: GoogleCalendarListResponse = try await jsonRequest(account: account, url: url, method: "GET", body: nil)
            calendars.append(contentsOf: response.items.compactMap(googleCalendarInfo(from:)))
            pageToken = response.nextPageToken.nilIfBlank
        } while pageToken != nil

        return calendars
    }

    private func googleCalendarInfo(from item: GoogleCalendarListItem) -> GoogleCalendarInfo? {
        guard item.deleted != true,
              item.hidden != true
        else {
            return nil
        }
        guard let id = item.id.nilIfBlank else { return nil }
        return GoogleCalendarInfo(
            id: id,
            summary: item.summary.nilIfBlank ?? item.summaryOverride.nilIfBlank ?? "Google Calendar",
            backgroundColor: sanitizedColor(item.backgroundColor),
            accessRole: item.accessRole.nilIfBlank ?? "reader",
            isPrimary: item.primary == true,
            defaultReminderOffsets: normalizedReminderOffsets(
                item.defaultReminders?
                    .filter { $0.method?.lowercased() == "popup" || $0.method == nil }
                    .compactMap(\.minutes) ?? []
            )
        )
    }

    private func fetchEvents(
        account: CalendarProviderAccount,
        calendarID: String,
        startDate: Date,
        endDate: Date
    ) async throws -> GoogleEventsFetchResult {
        var allEvents: [GoogleCalendarEvent] = []
        var pageToken: String?
        var syncToken: String?
        var seenPageTokens: Set<String> = []
        var pageCount = 0

        repeat {
            try validateGooglePage(
                pageToken: pageToken,
                account: account,
                seenPageTokens: &seenPageTokens,
                pageCount: &pageCount
            )
            var queryItems = [
                URLQueryItem(name: "timeMin", value: rfc3339Formatter.string(from: startDate)),
                URLQueryItem(name: "timeMax", value: rfc3339Formatter.string(from: endDate)),
                URLQueryItem(name: "singleEvents", value: "false"),
                URLQueryItem(name: "showDeleted", value: "true"),
                URLQueryItem(name: "maxResults", value: "2500")
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }

            let url = try eventsURL(account: account, calendarID: calendarID, queryItems: queryItems)
            let response: GoogleEventsResponse = try await jsonRequest(account: account, url: url, method: "GET", body: nil)
            allEvents.append(contentsOf: response.items)
            pageToken = response.nextPageToken.nilIfBlank
            syncToken = response.nextSyncToken.nilIfBlank ?? syncToken
        } while pageToken != nil

        return GoogleEventsFetchResult(events: allEvents, syncToken: syncToken ?? "")
    }

    private func fetchIncrementalEvents(
        account: CalendarProviderAccount,
        calendarID: String,
        syncToken: String
    ) async throws -> GoogleEventsFetchResult {
        var allEvents: [GoogleCalendarEvent] = []
        var pageToken: String?
        var nextSyncToken: String?
        var seenPageTokens: Set<String> = []
        var pageCount = 0

        repeat {
            try validateGooglePage(
                pageToken: pageToken,
                account: account,
                seenPageTokens: &seenPageTokens,
                pageCount: &pageCount
            )
            var queryItems = [
                URLQueryItem(name: "syncToken", value: syncToken),
                URLQueryItem(name: "showDeleted", value: "true"),
                URLQueryItem(name: "maxResults", value: "2500")
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }

            let url = try eventsURL(account: account, calendarID: calendarID, queryItems: queryItems)
            let response: GoogleEventsResponse = try await jsonRequest(account: account, url: url, method: "GET", body: nil)
            allEvents.append(contentsOf: response.items)
            pageToken = response.nextPageToken.nilIfBlank
            nextSyncToken = response.nextSyncToken.nilIfBlank ?? nextSyncToken
        } while pageToken != nil

        return GoogleEventsFetchResult(events: allEvents, syncToken: nextSyncToken ?? syncToken)
    }

    private func fetchFullCalendarPayload(
        account: CalendarProviderAccount,
        calendar: GoogleCalendarInfo,
        startDate: Date,
        endDate: Date
    ) async throws -> GoogleCalendarPayload {
        let result = try await fetchEvents(
            account: account,
            calendarID: calendar.id,
            startDate: startDate,
            endDate: endDate
        )
        return GoogleCalendarPayload(
            calendar: calendar,
            events: result.events,
            deletedRemoteObjectURLs: deletedRemoteObjectURLs(
                from: result.events,
                calendar: calendar,
                account: account
            ),
            cancelledRemoteOccurrences: cancelledRemoteOccurrences(
                from: result.events,
                calendar: calendar,
                account: account
            ),
            isIncremental: false,
            syncToken: result.syncToken,
            windowStartDate: startDate,
            windowEndDate: endDate
        )
    }

    private func fetchIncrementalCalendarPayload(
        account: CalendarProviderAccount,
        calendar: GoogleCalendarInfo,
        syncToken: String,
        syncedWindowStartDate: Date,
        syncedWindowEndDate: Date
    ) async throws -> GoogleCalendarPayload {
        let result = try await fetchIncrementalEvents(
            account: account,
            calendarID: calendar.id,
            syncToken: syncToken
        )
        let enrichedEvents = try await eventsIncludingMissingRecurringMasters(
            result.events,
            account: account,
            calendarID: calendar.id
        )
        return GoogleCalendarPayload(
            calendar: calendar,
            events: enrichedEvents,
            deletedRemoteObjectURLs: deletedRemoteObjectURLs(
                from: result.events,
                calendar: calendar,
                account: account
            ),
            cancelledRemoteOccurrences: cancelledRemoteOccurrences(
                from: result.events,
                calendar: calendar,
                account: account
            ),
            isIncremental: true,
            syncToken: result.syncToken,
            windowStartDate: syncedWindowStartDate,
            windowEndDate: syncedWindowEndDate
        )
    }

    private func deletedRemoteObjectURLs(
        from events: [GoogleCalendarEvent],
        calendar: GoogleCalendarInfo,
        account: CalendarProviderAccount
    ) -> Set<String> {
        Set(events.compactMap { event in
            guard event.isCancelled, !event.isRecurringInstance else { return nil }
            return remoteObjectURLString(event: event, calendar: calendar, account: account)
        })
    }

    func cancelledRemoteOccurrences(
        from events: [GoogleCalendarEvent],
        calendar: GoogleCalendarInfo,
        account: CalendarProviderAccount
    ) -> Set<LocalProviderRemoteOccurrenceCancellation> {
        Set(events.compactMap { event in
            guard event.isCancelled,
                  let recurringEventID = event.recurringEventId.nilIfBlank,
                  let occurrenceStartDate = event.originalStartTime?.resolvedDate
            else {
                return nil
            }
            return LocalProviderRemoteOccurrenceCancellation(
                masterRemoteObjectURLString: remoteObjectURLString(
                    account: account,
                    calendarID: calendar.id,
                    eventID: recurringEventID
                ),
                occurrenceStartDate: occurrenceStartDate
            )
        })
    }

    private func eventsIncludingMissingRecurringMasters(
        _ events: [GoogleCalendarEvent],
        account: CalendarProviderAccount,
        calendarID: String
    ) async throws -> [GoogleCalendarEvent] {
        let existingIDs = Set(events.map(\.id))
        let missingMasterIDs = Set(events.compactMap { event in
            event.recurringEventId.nilIfBlank.flatMap { existingIDs.contains($0) ? nil : $0 }
        })
        guard !missingMasterIDs.isEmpty else { return events }

        var enrichedEvents = events
        for masterID in missingMasterIDs {
            do {
                let master = try await fetchEvent(account: account, calendarID: calendarID, eventID: masterID)
                enrichedEvents.append(master)
            } catch GoogleCalendarClientError.httpStatus(let status, _, _) where status == 404 || status == 410 {
                continue
            }
        }
        return enrichedEvents
    }

    private func fetchEvent(
        account: CalendarProviderAccount,
        calendarID: String,
        eventID: String
    ) async throws -> GoogleCalendarEvent {
        let url = try eventURL(account: account, calendarID: calendarID, eventID: eventID)
        return try await jsonRequest(account: account, url: url, method: "GET", body: nil)
    }

    private func fetchInstances(
        account: CalendarProviderAccount,
        calendarID: String,
        eventID: String,
        startDate: Date,
        endDate: Date,
        includeDeleted: Bool = false
    ) async throws -> [GoogleCalendarEvent] {
        var instances: [GoogleCalendarEvent] = []
        var pageToken: String?
        var seenPageTokens: Set<String> = []
        var pageCount = 0

        repeat {
            try validateGooglePage(
                pageToken: pageToken,
                account: account,
                seenPageTokens: &seenPageTokens,
                pageCount: &pageCount
            )
            var queryItems = [
                URLQueryItem(name: "timeMin", value: rfc3339Formatter.string(from: startDate)),
                URLQueryItem(name: "timeMax", value: rfc3339Formatter.string(from: endDate)),
                URLQueryItem(name: "showDeleted", value: includeDeleted ? "true" : "false"),
                URLQueryItem(name: "maxResults", value: "2500")
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }

            let url = try eventInstancesURL(
                account: account,
                calendarID: calendarID,
                eventID: eventID,
                queryItems: queryItems
            )
            let response: GoogleEventsResponse = try await jsonRequest(account: account, url: url, method: "GET", body: nil)
            instances.append(contentsOf: response.items)
            pageToken = response.nextPageToken.nilIfBlank
        } while pageToken != nil

        return instances
    }

    private func validateGooglePage(
        pageToken: String?,
        account: CalendarProviderAccount,
        seenPageTokens: inout Set<String>,
        pageCount: inout Int
    ) throws {
        let pageKey = pageToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "__first__"
        let providerURL = account.endpointURL ?? Self.defaultAPIURL
        guard seenPageTokens.insert(pageKey).inserted else {
            throw GoogleCalendarClientError.paginationLoop(providerURL)
        }

        pageCount += 1
        guard pageCount <= Self.maxGooglePageCount else {
            throw GoogleCalendarClientError.paginationLimitExceeded(providerURL)
        }
    }

    private func writeRecurringExceptionState(
        for event: LocalCalendarEvent,
        account: CalendarProviderAccount,
        calendarID: String,
        eventID: String
    ) async throws {
        guard !event.detachedOccurrences.isEmpty || !event.excludedOccurrenceStartDates.isEmpty else { return }

        let sortedOriginalStarts = (event.detachedOccurrences.map(\.originalStartDate) + event.excludedOccurrenceStartDates).sorted()
        let startDate = (sortedOriginalStarts.first ?? event.startDate).addingTimeInterval(-48 * 3600)
        let endDate = (sortedOriginalStarts.last ?? event.endDate).addingTimeInterval(48 * 3600)
        let instances = try await fetchInstances(
            account: account,
            calendarID: calendarID,
            eventID: eventID,
            startDate: startDate,
            endDate: endDate,
            includeDeleted: true
        )
        let targets = try recurringExceptionWriteTargets(for: event, instances: instances)

        for target in targets.occurrencesToDelete {
            let url = try eventURL(
                account: account,
                calendarID: calendarID,
                eventID: target.eventID,
                queryItems: eventModificationQueryItems(sendUpdates: "all")
            )
            try await emptyRequest(
                account: account,
                url: url,
                method: "DELETE",
                headers: conditionalHeaders(remoteETag: target.remoteETag)
            )
        }

        for target in targets.detachedOccurrencesToPatch {
            let requestBody = try googleWriteRequest(from: target.occurrence)
            let body = try JSONEncoder().encode(requestBody)
            let url = try eventURL(
                account: account,
                calendarID: calendarID,
                eventID: target.eventID,
                queryItems: eventModificationQueryItems(sendUpdates: "all", supportsAttachments: requestBody.hasAttachments)
            )
            let _: GoogleEventResponse = try await jsonRequest(
                account: account,
                url: url,
                method: "PATCH",
                body: body,
                headers: conditionalHeaders(remoteETag: target.remoteETag)
            )
        }
    }

    func recurringExceptionWritePlanPreview(
        for event: LocalCalendarEvent,
        instances: [GoogleCalendarEvent]
    ) throws -> GoogleRecurringExceptionWritePlan {
        let targets = try recurringExceptionWriteTargets(for: event, instances: instances)
        return GoogleRecurringExceptionWritePlan(
            occurrenceIDsToDelete: targets.occurrencesToDelete.map(\.eventID),
            occurrenceIDsToPatch: targets.detachedOccurrencesToPatch.map(\.eventID)
        )
    }

    private func recurringExceptionWriteTargets(
        for event: LocalCalendarEvent,
        instances: [GoogleCalendarEvent]
    ) throws -> GoogleRecurringExceptionWriteTargets {
        var occurrencesToDelete: [GoogleOccurrenceDeleteTarget] = []
        var detachedOccurrencesToPatch: [GoogleDetachedOccurrencePatchTarget] = []

        for occurrenceStart in event.excludedOccurrenceStartDates {
            guard let instance = instances.first(where: {
                originalStartTimeMatches(
                    $0.originalStartTime,
                    occurrenceStartDate: occurrenceStart,
                    occurrenceIsAllDay: event.isAllDay,
                    occurrenceTimeZoneIdentifier: event.timeZoneIdentifier
                )
            }) else {
                continue
            }

            if !instance.isCancelled {
                occurrencesToDelete.append(GoogleOccurrenceDeleteTarget(
                    eventID: instance.id,
                    remoteETag: instance.etag ?? ""
                ))
            }
        }

        for occurrence in event.detachedOccurrences {
            guard let instance = instances.first(where: {
                originalStartTimeMatches(
                    $0.originalStartTime,
                    occurrenceStartDate: occurrence.originalStartDate,
                    occurrenceIsAllDay: event.isAllDay,
                    occurrenceTimeZoneIdentifier: event.timeZoneIdentifier
                )
            }) else {
                throw GoogleCalendarClientError.remoteObjectMissing
            }

            detachedOccurrencesToPatch.append(GoogleDetachedOccurrencePatchTarget(
                eventID: instance.id,
                remoteETag: instance.etag ?? "",
                occurrence: occurrence
            ))
        }

        return GoogleRecurringExceptionWriteTargets(
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
            originalStartTimeMatches(
                $0.originalStartTime,
                occurrenceStartDate: occurrenceStartDate,
                occurrenceIsAllDay: occurrenceIsAllDay,
                occurrenceTimeZoneIdentifier: occurrenceTimeZoneIdentifier
            ) == true
        }) else {
            throw GoogleCalendarClientError.remoteObjectMissing
        }
        return instance.id
    }

    private func googleWriteRequest(from event: LocalCalendarEvent, eventID: String? = nil) throws -> GoogleEventWriteRequest {
        let start = GoogleEventTimeWrite(date: event.isAllDay ? googleDateString(from: event.startDate, timeZoneIdentifier: event.timeZoneIdentifier) : nil,
                                         dateTime: event.isAllDay ? nil : googleRFC3339String(from: event.startDate, timeZoneIdentifier: event.timeZoneIdentifier),
                                         timeZone: event.isAllDay ? nil : event.timeZoneIdentifier)
        let end = GoogleEventTimeWrite(date: event.isAllDay ? googleDateString(from: event.endDate, timeZoneIdentifier: event.timeZoneIdentifier) : nil,
                                       dateTime: event.isAllDay ? nil : googleRFC3339String(from: event.endDate, timeZoneIdentifier: event.timeZoneIdentifier),
                                       timeZone: event.isAllDay ? nil : event.timeZoneIdentifier)

        let attendees = event.attendees.filter { !$0.isBlank }.map { attendee in
            GoogleAttendeeWrite(
                email: attendee.email.nilIfBlank,
                displayName: attendee.name.nilIfBlank,
                optional: attendee.normalizedRole == "optional",
                resource: attendee.isRoomLike || attendee.normalizedType == "resource",
                responseStatus: googleResponseStatus(for: attendee.status)
            )
        }.filter { $0.email != nil || $0.displayName != nil }

        return GoogleEventWriteRequest(
            id: eventID,
            status: googleEventStatus(for: event.status),
            summary: event.title,
            location: googleClearingString(event.location),
            description: googleClearingString(event.notes),
            start: start,
            end: end,
            transparency: event.availability == .free ? "transparent" : "opaque",
            visibility: googleVisibility(from: event.categories, privacy: event.privacy),
            colorId: googleColorID(from: event.categories),
            guestsCanSeeOtherGuests: googleGuestsCanSeeOtherGuests(from: event.categories, encodesDefaultValue: eventID == nil),
            guestsCanInviteOthers: googleGuestsCanInviteOthers(from: event.categories, encodesDefaultValue: eventID == nil),
            guestsCanModify: googleGuestsCanModify(from: event.categories, encodesDefaultValue: eventID == nil),
            sequence: event.sequence,
            reminders: GoogleEventRemindersWrite(
                useDefault: false,
                overrides: try googleReminderOverrides(from: event.reminderOffsets)
            ),
            attendees: attendees,
            attendeesOmitted: eventID == nil ? googleAttendeesOmittedMetadata(from: event.categories) : nil,
            recurrence: recurrenceLines(for: event) ?? [],
            conferenceData: googleConferenceData(from: event.categories, eventID: eventID),
            attachments: try googleAttachmentWrites(from: event.attachments),
            workingLocationProperties: eventID == nil
                ? googleWorkingLocationProperties(location: event.location, categories: event.categories)
                : nil,
            outOfOfficeProperties: eventID == nil
                ? googleOutOfOfficeProperties(from: event.categories)
                : nil,
            focusTimeProperties: eventID == nil
                ? googleFocusTimeProperties(from: event.categories)
                : nil,
            source: googleSource(urlString: event.urlString, categories: event.categories, eventID: eventID),
            extendedProperties: googleExtendedProperties(
                categories: event.categories,
                relatedEvents: event.relatedEvents,
                geoCoordinate: event.geoCoordinate
            ),
            encodesClearingNulls: eventID == nil
        )
    }

    func encodedWritePayloadPreview(for event: LocalCalendarEvent) throws -> Data {
        try JSONEncoder().encode(try googleWriteRequest(from: event))
    }

    func encodedInsertPayloadPreview(for event: LocalCalendarEvent, eventID: String) throws -> Data {
        try JSONEncoder().encode(try googleWriteRequest(from: event, eventID: eventID))
    }

    func encodedDetachedOccurrencePayloadPreview(for occurrence: LocalDetachedOccurrence) throws -> Data {
        try JSONEncoder().encode(try googleWriteRequest(from: occurrence))
    }

    func eventModificationQueryItemsPreview(for event: LocalCalendarEvent, sendUpdates: String? = nil) throws -> [URLQueryItem] {
        try eventModificationQueryItems(
            sendUpdates: sendUpdates,
            supportsAttachments: googleAttachmentWrites(from: event.attachments) != nil
        )
    }

    func eventURLPreview(account: CalendarProviderAccount, calendarID: String, eventID: String) throws -> URL {
        try eventURL(account: account, calendarID: calendarID, eventID: eventID)
    }

    func detachedOccurrenceModificationQueryItemsPreview(
        for occurrence: LocalDetachedOccurrence,
        sendUpdates: String? = nil
    ) throws -> [URLQueryItem] {
        try eventModificationQueryItems(
            sendUpdates: sendUpdates,
            supportsAttachments: googleAttachmentWrites(from: occurrence.attachments) != nil
        )
    }

    private func responsePatchRequest(
        event: GoogleCalendarEvent,
        calendarID: String,
        account: CalendarProviderAccount,
        response: CalendarEventResponse
    ) throws -> GoogleEventAttendeesPatchRequest {
        let identityEmails = googleIdentityEmails(calendarID: calendarID, account: account)
        guard let attendee = event.attendees?.first(where: { googleAttendeeMatchesCurrentUser($0, identityEmails: identityEmails) }),
              let email = attendee.email.nilIfBlank
        else {
            throw GoogleCalendarClientError.selfAttendeeNotFound
        }

        return GoogleEventAttendeesPatchRequest(
            attendeesOmitted: true,
            attendees: [
                GoogleAttendeeWrite(
                    email: email,
                    displayName: attendee.displayName.nilIfBlank,
                    optional: attendee.optional,
                    resource: attendee.resource,
                    responseStatus: googleResponseStatus(for: response.responseStatus)
                )
            ]
        )
    }

    func allDayOccurrenceDateMatchesPreview(
        providerDate: String,
        occurrenceStartDate: Date,
        timeZoneIdentifier: String
    ) -> Bool {
        allDayProviderDate(
            providerDate,
            matches: occurrenceStartDate,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    private func googleWriteRequest(from occurrence: LocalDetachedOccurrence) throws -> GoogleEventWriteRequest {
        let start = GoogleEventTimeWrite(date: occurrence.isAllDay ? googleDateString(from: occurrence.startDate, timeZoneIdentifier: occurrence.timeZoneIdentifier) : nil,
                                         dateTime: occurrence.isAllDay ? nil : googleRFC3339String(from: occurrence.startDate, timeZoneIdentifier: occurrence.timeZoneIdentifier),
                                         timeZone: occurrence.isAllDay ? nil : occurrence.timeZoneIdentifier)
        let end = GoogleEventTimeWrite(date: occurrence.isAllDay ? googleDateString(from: occurrence.endDate, timeZoneIdentifier: occurrence.timeZoneIdentifier) : nil,
                                       dateTime: occurrence.isAllDay ? nil : googleRFC3339String(from: occurrence.endDate, timeZoneIdentifier: occurrence.timeZoneIdentifier),
                                       timeZone: occurrence.isAllDay ? nil : occurrence.timeZoneIdentifier)

        let attendees = occurrence.attendees.filter { !$0.isBlank }.map { attendee in
            GoogleAttendeeWrite(
                email: attendee.email.nilIfBlank,
                displayName: attendee.name.nilIfBlank,
                optional: attendee.normalizedRole == "optional",
                resource: attendee.isRoomLike || attendee.normalizedType == "resource",
                responseStatus: googleResponseStatus(for: attendee.status)
            )
        }.filter { $0.email != nil || $0.displayName != nil }

        return GoogleEventWriteRequest(
            id: nil,
            status: googleEventStatus(for: occurrence.status),
            summary: occurrence.title,
            location: googleClearingString(occurrence.location),
            description: googleClearingString(occurrence.notes),
            start: start,
            end: end,
            transparency: occurrence.availability == .free ? "transparent" : "opaque",
            visibility: googleVisibility(from: occurrence.categories, privacy: occurrence.privacy),
            colorId: googleColorID(from: occurrence.categories),
            guestsCanSeeOtherGuests: googleGuestsCanSeeOtherGuests(from: occurrence.categories, encodesDefaultValue: true),
            guestsCanInviteOthers: googleGuestsCanInviteOthers(from: occurrence.categories, encodesDefaultValue: true),
            guestsCanModify: googleGuestsCanModify(from: occurrence.categories, encodesDefaultValue: true),
            sequence: occurrence.sequence,
            reminders: GoogleEventRemindersWrite(
                useDefault: false,
                overrides: try googleReminderOverrides(from: occurrence.reminderOffsets)
            ),
            attendees: attendees,
            attendeesOmitted: googleAttendeesOmittedMetadata(from: occurrence.categories),
            recurrence: nil,
            conferenceData: nil,
            attachments: try googleAttachmentWrites(from: occurrence.attachments),
            workingLocationProperties: googleWorkingLocationProperties(location: occurrence.location, categories: occurrence.categories),
            outOfOfficeProperties: googleOutOfOfficeProperties(from: occurrence.categories),
            focusTimeProperties: googleFocusTimeProperties(from: occurrence.categories),
            source: googleSource(urlString: occurrence.urlString, categories: occurrence.categories, eventID: nil),
            extendedProperties: googleExtendedProperties(
                categories: occurrence.categories,
                relatedEvents: occurrence.relatedEvents,
                geoCoordinate: occurrence.geoCoordinate
            ),
            encodesClearingNulls: true
        )
    }

    private func recurrenceLines(for event: LocalCalendarEvent) -> [String]? {
        guard event.recurrenceFrequency != .none || !event.additionalOccurrenceStartDates.isEmpty else { return nil }
        var lines: [String] = []

        if event.recurrenceFrequency != .none {
            var parts = [
                "FREQ=\(googleRecurrenceFrequency(for: event.recurrenceFrequency))",
                "INTERVAL=\(max(1, event.recurrenceInterval))"
            ]

            if event.recurrenceFrequency == .weekly {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: event.timeZoneIdentifier) ?? .current
                let rawWeekdays = event.recurrenceWeekdays.isEmpty
                    ? [calendar.component(.weekday, from: event.startDate)]
                    : event.recurrenceWeekdays
                let byDay = rawWeekdays.compactMap(icsWeekdayName(for:)).joined(separator: ",")
                if !byDay.isEmpty {
                    parts.append("BYDAY=\(byDay)")
                }
                let normalizedSetPositions = normalizedRecurrenceSetPositions(
                    event.recurrenceSetPositions,
                    frequency: event.recurrenceFrequency
                )
                if !normalizedSetPositions.isEmpty {
                    parts.append("BYSETPOS=\(normalizedSetPositions.map(String.init).joined(separator: ","))")
                }
                if let weekStart = event.recurrenceWeekStart,
                   let weekStartName = icsWeekdayName(for: weekStart) {
                    parts.append("WKST=\(weekStartName)")
                }
            } else if event.recurrenceFrequency == .monthly,
                      let ordinal = event.recurrenceOrdinal,
                      let ordinalWeekday = event.recurrenceOrdinalWeekday,
                      let weekdayName = icsWeekdayName(for: ordinalWeekday) {
                let months = normalizedRecurrenceMonths(event.recurrenceMonths, frequency: event.recurrenceFrequency)
                if !months.isEmpty {
                    parts.append("BYMONTH=\(months.map(String.init).joined(separator: ","))")
                }
                parts.append("BYDAY=\(ordinal)\(weekdayName)")
            } else if event.recurrenceFrequency == .monthly,
                      let monthDay = event.recurrenceMonthDay {
                let months = normalizedRecurrenceMonths(event.recurrenceMonths, frequency: event.recurrenceFrequency)
                if !months.isEmpty {
                    parts.append("BYMONTH=\(months.map(String.init).joined(separator: ","))")
                }
                parts.append("BYMONTHDAY=\(monthDay)")
            } else if event.recurrenceFrequency == .monthly {
                let months = normalizedRecurrenceMonths(event.recurrenceMonths, frequency: event.recurrenceFrequency)
                if !months.isEmpty {
                    parts.append("BYMONTH=\(months.map(String.init).joined(separator: ","))")
                }
            } else if event.recurrenceFrequency == .yearly,
                      let ordinal = event.recurrenceOrdinal,
                      let ordinalWeekday = event.recurrenceOrdinalWeekday,
                      let weekdayName = icsWeekdayName(for: ordinalWeekday) {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: event.timeZoneIdentifier) ?? .current
                let months = normalizedRecurrenceMonths(event.recurrenceMonths, frequency: event.recurrenceFrequency)
                parts.append("BYMONTH=\((months.isEmpty ? [calendar.component(.month, from: event.startDate)] : months).map(String.init).joined(separator: ","))")
                parts.append("BYDAY=\(ordinal)\(weekdayName)")
            } else if event.recurrenceFrequency == .yearly {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: event.timeZoneIdentifier) ?? .current
                let months = normalizedRecurrenceMonths(event.recurrenceMonths, frequency: event.recurrenceFrequency)
                parts.append("BYMONTH=\((months.isEmpty ? [calendar.component(.month, from: event.startDate)] : months).map(String.init).joined(separator: ","))")
                parts.append("BYMONTHDAY=\(event.recurrenceMonthDay ?? calendar.component(.day, from: event.startDate))")
            }

            if let recurrenceEndDate = event.recurrenceEndDate {
                if event.isAllDay {
                    parts.append("UNTIL=\(googleDateString(from: recurrenceEndDate, timeZoneIdentifier: event.timeZoneIdentifier).replacingOccurrences(of: "-", with: ""))")
                } else {
                    parts.append("UNTIL=\(icsDateTimeFormatter.string(from: recurrenceEndDate))")
                }
            }

            lines.append("RRULE:\(parts.joined(separator: ";"))")
        }

        lines.append(contentsOf: event.additionalOccurrenceStartDates.compactMap {
            recurrenceDateLine(name: "RDATE", for: $0, isAllDay: event.isAllDay, timeZoneIdentifier: event.timeZoneIdentifier)
        })
        lines.append(contentsOf: event.excludedOccurrenceStartDates.compactMap {
            recurrenceDateLine(name: "EXDATE", for: $0, isAllDay: event.isAllDay, timeZoneIdentifier: event.timeZoneIdentifier)
        })
        return lines
    }

    private func recurrenceDateLine(name: String, for date: Date, isAllDay: Bool, timeZoneIdentifier: String) -> String {
        if isAllDay {
            return "\(name);VALUE=DATE:\(googleDateString(from: date, timeZoneIdentifier: timeZoneIdentifier).replacingOccurrences(of: "-", with: ""))"
        }

        let identifier = timeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? TimeZone.current.identifier
            : timeZoneIdentifier
        let timeZone = TimeZone(identifier: identifier) ?? .current
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return "\(name);TZID=\(identifier):\(formatter.string(from: date))"
    }

    private func googleDateString(from date: Date, timeZoneIdentifier: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func originalStartTimeMatches(
        _ originalStartTime: GoogleEventDateTime?,
        occurrenceStartDate: Date,
        occurrenceIsAllDay: Bool,
        occurrenceTimeZoneIdentifier: String?
    ) -> Bool {
        guard let originalStartTime else { return false }
        if occurrenceIsAllDay,
           let providerDate = originalStartTime.date.nilIfBlank {
            return allDayProviderDate(
                providerDate,
                matches: occurrenceStartDate,
                timeZoneIdentifier: occurrenceTimeZoneIdentifier
            )
        }

        return originalStartTime.resolvedDate?.isSameOccurrenceStart(
            as: occurrenceStartDate,
            isAllDay: occurrenceIsAllDay
        ) == true
    }

    private func allDayProviderDate(
        _ providerDate: String,
        matches occurrenceStartDate: Date,
        timeZoneIdentifier: String?
    ) -> Bool {
        let normalizedProviderDate = providerDate
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
        guard normalizedProviderDate.count == 8 else { return false }
        return normalizedProviderDate == googleDateString(
            from: occurrenceStartDate,
            timeZoneIdentifier: timeZoneIdentifier ?? TimeZone.current.identifier
        ).replacingOccurrences(of: "-", with: "")
    }

    fileprivate func googleICSDateTimeString(from date: Date, timeZoneIdentifier: String) -> String? {
        let identifier = timeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty,
              let timeZone = TimeZone(identifier: identifier)
        else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: date)
    }

    private func googleRFC3339String(from date: Date, timeZoneIdentifier: String) -> String {
        let identifier = timeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty,
              let timeZone = TimeZone(identifier: identifier)
        else {
            return rfc3339Formatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter.string(from: date)
    }

    fileprivate func googleIdentityEmails(
        calendarID: String?,
        account: CalendarProviderAccount,
        isPrimaryCalendar: Bool = false
    ) -> Set<String> {
        var candidates = [account.identityEmail] + account.identityEmailAliases.map(Optional.some) + [account.username, account.title]
        if isPrimaryCalendar || calendarID?.isGooglePersonalEmailCalendarID == true {
            candidates.append(calendarID)
        }
        return Set(candidates.compactMap { $0.normalizedGoogleIdentityEmail })
    }

    fileprivate func googleAttendeeMatchesCurrentUser(
        _ attendee: GoogleEventAttendee,
        identityEmails: Set<String>
    ) -> Bool {
        if attendee.selfFlag == true { return true }
        guard let email = attendee.email.normalizedGoogleIdentityEmail else { return false }
        return identityEmails.contains(email)
    }

    fileprivate func googlePersonMatchesCurrentUser(
        _ person: GoogleEventPerson?,
        identityEmails: Set<String>
    ) -> Bool {
        if person?.selfFlag == true { return true }
        guard let email = person?.email.normalizedGoogleIdentityEmail else { return false }
        return identityEmails.contains(email)
    }

    fileprivate func googleAccountIdentityEmails(calendar: GoogleCalendarInfo, events: [GoogleCalendarEvent]) -> [String] {
        var candidates: [String] = []
        if let accountIdentityEmail = calendar.accountIdentityEmail {
            candidates.append(accountIdentityEmail)
        }

        for event in events {
            if event.organizer?.selfFlag == true, let email = event.organizer?.email {
                candidates.append(email)
            }
            if event.creator?.selfFlag == true, let email = event.creator?.email {
                candidates.append(email)
            }
            for attendee in event.attendees ?? [] where attendee.selfFlag == true {
                if let email = attendee.email {
                    candidates.append(email)
                }
            }
        }

        var seen: Set<String> = []
        var emails: [String] = []
        for candidate in candidates {
            guard let email = candidate.normalizedGoogleIdentityEmail,
                  seen.insert(email).inserted
            else { continue }
            emails.append(email)
        }
        return emails
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
            throw GoogleCalendarClientError.calendarNotFound
        }

        let encodedCalendarID = String(localCalendar.id.dropFirst(prefix.count))
        guard let calendarID = base64URLDecode(encodedCalendarID), !calendarID.isEmpty else {
            throw GoogleCalendarClientError.calendarNotFound
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
              url.scheme == "google",
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
        "google://\(account.id)/\(base64URLEncode(calendarID))/\(base64URLEncode(eventID))"
    }

    func localCalendarID(for account: CalendarProviderAccount, googleCalendarID: String) -> String {
        "\(localCalendarIDPrefix(for: account))\(base64URLEncode(googleCalendarID))"
    }

    private func eventsURL(account: CalendarProviderAccount, calendarID: String, queryItems: [URLQueryItem]) throws -> URL {
        try apiURL(account: account, path: ["calendars", calendarID, "events"], queryItems: queryItems)
    }

    private func eventURL(account: CalendarProviderAccount, calendarID: String, eventID: String, queryItems: [URLQueryItem] = []) throws -> URL {
        try apiURL(account: account, path: ["calendars", calendarID, "events", eventID], queryItems: queryItems)
    }

    private func eventInstancesURL(
        account: CalendarProviderAccount,
        calendarID: String,
        eventID: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        try apiURL(account: account, path: ["calendars", calendarID, "events", eventID, "instances"], queryItems: queryItems)
    }

    private func apiURL(account: CalendarProviderAccount, path: [String], queryItems: [URLQueryItem]) throws -> URL {
        guard let baseURL = account.endpointURL else {
            throw GoogleCalendarClientError.invalidAccountURL
        }

        let encodedPath = path.map(pathComponent).joined(separator: "/")
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw GoogleCalendarClientError.invalidAccountURL
        }
        let basePath = components.percentEncodedPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fullPath = [basePath, encodedPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.percentEncodedPath = "/\(fullPath)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw GoogleCalendarClientError.invalidAccountURL
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
        return try JSONDecoder.googleCalendar.decode(Response.self, from: data)
    }

    private func emptyRequest(account: CalendarProviderAccount, url: URL, method: String, headers: [String: String] = [:]) async throws {
        _ = try await dataRequest(account: account, url: url, method: method, body: nil, headers: headers)
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
            accessToken = try await accessTokenProvider(account, .googleCalendar, forceRefresh)
        } catch OAuthDeviceFlowError.missingAccessToken {
            throw GoogleCalendarClientError.missingAccessToken
        } catch OAuthDeviceFlowError.missingRefreshToken {
            throw GoogleCalendarClientError.missingRefreshToken
        } catch OAuthDeviceFlowError.refreshTokenRejected(_) {
            throw GoogleCalendarClientError.missingRefreshToken
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
                throw GoogleCalendarClientError.remoteConflict(url)
            }
            if ProviderRetryAfter.isRetryAfterStatus(httpResponse.statusCode),
               let retryAfterSeconds = ProviderRetryAfter.seconds(from: httpResponse) {
                throw GoogleCalendarClientError.retryAfter(
                    retryAfterSeconds,
                    url,
                    googleErrorMessage(from: data)
                )
            }
            throw GoogleCalendarClientError.httpStatus(
                httpResponse.statusCode,
                url,
                googleErrorMessage(from: data)
            )
        }

        return data
    }

    private func conditionalHeaders(remoteETag: String) -> [String: String] {
        let trimmed = remoteETag.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [:] : ["If-Match": trimmed]
    }

    private func eventModificationQueryItems(sendUpdates: String? = nil, supportsAttachments: Bool = false) -> [URLQueryItem] {
        var queryItems = [URLQueryItem(name: "conferenceDataVersion", value: "1")]
        if let sendUpdates {
            queryItems.append(URLQueryItem(name: "sendUpdates", value: sendUpdates))
        }
        if supportsAttachments {
            queryItems.append(URLQueryItem(name: "supportsAttachments", value: "true"))
        }
        return queryItems
    }

    private func googleWritableEventID(for event: LocalCalendarEvent) -> String {
        let allowedScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuv0123456789")
        var sanitized = event.id
            .lowercased()
            .unicodeScalars
            .filter { allowedScalars.contains($0) }
            .map(String.init)
            .joined()

        if sanitized.count < 5 {
            sanitized = "a\(stableHexIdentifier(for: event.id))"
        }
        if sanitized.count > 1024 {
            sanitized = String(sanitized.prefix(1024))
        }
        return sanitized
    }

    private func stableHexIdentifier(for value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    private func googleErrorMessage(from data: Data) -> String {
        guard
            let errorResponse = try? JSONDecoder().decode(GoogleErrorResponse.self, from: data),
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
        if let email = email.nilIfBlank {
            return "mailto:\(escapeICSText(email))"
        }
        return escapeICSText(fallbackName.nilIfBlank ?? "Participant")
    }

    private func partStat(for responseStatus: String?) -> String {
        switch responseStatus?.lowercased() {
        case "accepted":
            return "ACCEPTED"
        case "declined":
            return "DECLINED"
        case "tentative":
            return "TENTATIVE"
        default:
            return "NEEDS-ACTION"
        }
    }

    private func googleAttendeeNeedsResponse(_ responseStatus: String?) -> Bool {
        switch responseStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "needsaction", "needs_action":
            return true
        default:
            return false
        }
    }

    private func googleResponseStatus(for status: EventResponseStatus) -> String {
        switch status {
        case .accepted:
            return "accepted"
        case .declined, .canceled:
            return "declined"
        case .tentative:
            return "tentative"
        default:
            return "needsAction"
        }
    }

    private func googleEventStatus(for status: CalendarEventStatus) -> String {
        switch status {
        case .cancelled:
            return "cancelled"
        case .tentative:
            return "tentative"
        case .confirmed, .unknown:
            return "confirmed"
        }
    }

    private func googleColorID(from categories: [String]) -> String? {
        let validColorIDs = Set((1...11).map(String.init))
        for category in categories {
            let normalized = category
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            let colorID: String?
            if normalized.hasPrefix("google-color-") {
                colorID = String(normalized.dropFirst("google-color-".count))
            } else if normalized.hasPrefix("google color ") {
                colorID = String(normalized.dropFirst("google color ".count))
            } else {
                colorID = nil
            }
            if let colorID, validColorIDs.contains(colorID) {
                return colorID
            }
        }
        return nil
    }

    private func googleVisibility(from categories: [String], privacy: CalendarEventPrivacy) -> String? {
        guard privacy == .public else { return privacy.googleVisibility }
        return Self.googleVisibilityMetadata(from: categories) ?? privacy.googleVisibility
    }

    private func googleGuestsCanSeeOtherGuests(from categories: [String], encodesDefaultValue: Bool) -> Bool? {
        if categories.contains(where: { Self.googleGuestsHiddenMetadataCategory($0) }) {
            return false
        }
        return encodesDefaultValue ? true : nil
    }

    private func googleGuestsCanInviteOthers(from categories: [String], encodesDefaultValue: Bool) -> Bool? {
        if categories.contains(where: { Self.googleGuestsCannotInviteMetadataCategory($0) }) {
            return false
        }
        return encodesDefaultValue ? true : nil
    }

    private func googleGuestsCanModify(from categories: [String], encodesDefaultValue: Bool) -> Bool? {
        if categories.contains(where: { Self.googleGuestsCanModifyMetadataCategory($0) }) {
            return true
        }
        return encodesDefaultValue ? false : nil
    }

    private func googleConferenceData(from categories: [String], eventID: String?) -> GoogleConferenceData? {
        guard let eventID,
              Self.googleConferenceTypeMetadata(from: categories) == "hangoutsMeet" else {
            return nil
        }
        return GoogleConferenceData(
            createRequest: GoogleConferenceCreateRequest(
                requestId: googleConferenceCreateRequestID(for: eventID),
                conferenceSolutionKey: GoogleConferenceSolutionKey(type: "hangoutsMeet")
            )
        )
    }

    private func googleWorkingLocationProperties(location: String, categories: [String]) -> GoogleWorkingLocationProperties? {
        guard Self.googleEventTypeMetadata(from: categories) == "workingLocation" else { return nil }
        let label = location.nilIfBlank
        let type = Self.googleWorkingLocationTypeMetadata(from: categories)

        switch type {
        case "homeOffice":
            return GoogleWorkingLocationProperties(
                type: "homeOffice",
                homeOffice: GoogleWorkingLocationHomeOffice(),
                officeLocation: nil,
                customLocation: nil
            )
        case "officeLocation":
            guard label != nil || Self.googleWorkingLocationOfficeMetadata(from: categories).hasAnyValue else { return nil }
            let office = Self.googleWorkingLocationOfficeMetadata(from: categories)
            return GoogleWorkingLocationProperties(
                type: "officeLocation",
                homeOffice: nil,
                officeLocation: GoogleWorkingLocationOffice(
                    buildingId: office.buildingId,
                    floorId: office.floorId,
                    floorSectionId: office.floorSectionId,
                    deskId: office.deskId,
                    label: label
                ),
                customLocation: nil
            )
        default:
            guard let label else { return nil }
            return GoogleWorkingLocationProperties(
                type: "customLocation",
                homeOffice: nil,
                officeLocation: nil,
                customLocation: GoogleWorkingLocationCustom(label: label)
            )
        }
    }

    private func googleOutOfOfficeProperties(from categories: [String]) -> GoogleOutOfOfficeProperties? {
        guard Self.googleEventTypeMetadata(from: categories) == "outOfOffice" else { return nil }
        let properties = GoogleOutOfOfficeProperties(
            autoDeclineMode: Self.googleMetadataSuffix(
                in: categories,
                humanPrefix: Self.outOfOfficeAutoDeclineCategoryPrefix,
                dashedPrefix: "google-out-of-office-auto-decline-"
            ),
            declineMessage: Self.googleMetadataSuffix(
                in: categories,
                humanPrefix: Self.outOfOfficeDeclineMessageCategoryPrefix,
                dashedPrefix: "google-out-of-office-decline-message-"
            )
        )
        return properties.hasAnyValue ? properties : nil
    }

    private func googleFocusTimeProperties(from categories: [String]) -> GoogleFocusTimeProperties? {
        guard Self.googleEventTypeMetadata(from: categories) == "focusTime" else { return nil }
        let properties = GoogleFocusTimeProperties(
            autoDeclineMode: Self.googleMetadataSuffix(
                in: categories,
                humanPrefix: Self.focusTimeAutoDeclineCategoryPrefix,
                dashedPrefix: "google-focus-time-auto-decline-"
            ),
            declineMessage: Self.googleMetadataSuffix(
                in: categories,
                humanPrefix: Self.focusTimeDeclineMessageCategoryPrefix,
                dashedPrefix: "google-focus-time-decline-message-"
            ),
            chatStatus: Self.googleMetadataSuffix(
                in: categories,
                humanPrefix: Self.focusTimeChatStatusCategoryPrefix,
                dashedPrefix: "google-focus-time-chat-status-"
            )
        )
        return properties.hasAnyValue ? properties : nil
    }

    private func googleSource(urlString: String, categories: [String], eventID: String?) -> GoogleEventSource? {
        guard let urlString = urlString.nilIfBlank else { return nil }
        if eventID != nil,
           Self.googleConferenceTypeMetadata(from: categories) == "hangoutsMeet" {
            return nil
        }
        return GoogleEventSource(title: "Working Calendar", url: urlString)
    }

    private func googleConferenceCreateRequestID(for eventID: String) -> String {
        "working-calendar-\(stableHexIdentifier(for: eventID))"
    }

    private func googleReminderOverrides(from reminderOffsets: [Int]) throws -> [GoogleEventReminderOverrideWrite] {
        let normalizedOffsets = normalizedReminderOffsets(reminderOffsets)
        guard normalizedOffsets.count <= Self.maxReminderOverrideCount else {
            throw GoogleCalendarClientError.unsupportedReminderOverrides(normalizedOffsets)
        }
        return normalizedOffsets.map {
            GoogleEventReminderOverrideWrite(method: "popup", minutes: $0)
        }
    }

    private func googleAttachmentWrites(from attachments: [LocalEventAttachment]) throws -> [GoogleAttachmentWrite]? {
        let normalizedAttachments = normalizedEventAttachments(attachments)
        guard normalizedAttachments.count <= Self.maxAttachmentCount else {
            throw GoogleCalendarClientError.unsupportedAttachmentCount(normalizedAttachments.count)
        }
        let writes = normalizedAttachments.map { attachment in
            GoogleAttachmentWrite(
                fileUrl: attachment.urlString,
                title: attachment.displayName.nilIfBlank,
                mimeType: attachment.formatType.nilIfBlank
            )
        }
        return writes.isEmpty ? nil : writes
    }

    private func googleClearingString(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : value
    }

    private func googleExtendedProperties(
        categories: [String],
        relatedEvents: [LocalEventRelationship],
        geoCoordinate: LocalEventGeoCoordinate?
    ) -> GoogleEventExtendedProperties? {
        var privateProperties: [String: String] = [:]
        if let encodedCategories = Self.googleEncodedWorkingCategories(Self.googleWorkingCategories(from: categories)) {
            privateProperties[Self.workingCategoriesExtendedPropertyKey] = encodedCategories
        }
        if let encodedRelationships = Self.googleEncodedRelatedEvents(relatedEvents) {
            privateProperties[Self.relatedEventsExtendedPropertyKey] = encodedRelationships
        }
        if let encodedGeoCoordinate = Self.googleEncodedGeoCoordinate(geoCoordinate) {
            privateProperties[Self.geoCoordinateExtendedPropertyKey] = encodedGeoCoordinate
        }
        guard !privateProperties.isEmpty else {
            return nil
        }
        return GoogleEventExtendedProperties(
            privateProperties: privateProperties,
            sharedProperties: nil
        )
    }

    fileprivate static func googleWorkingCategories(from categories: [String]) -> [String] {
        normalizedEventCategories(categories.filter { !googleProviderMetadataCategory($0) })
    }

    fileprivate static func googleProviderMetadataCategory(_ category: String) -> Bool {
        if googleAttendeesOmittedMetadata(category) {
            return true
        }
        if googleGuestsHiddenMetadataCategory(category) {
            return true
        }
        if googleGuestsCannotInviteMetadataCategory(category) {
            return true
        }
        if googleGuestsCanModifyMetadataCategory(category) {
            return true
        }
        if googleVisibilityMetadata(from: [category]) != nil {
            return true
        }
        if googleConferenceTypeMetadata(from: [category]) != nil {
            return true
        }
        if googleWorkingLocationMetadataCategory(category) {
            return true
        }
        if googleOutOfOfficeMetadataCategory(category) {
            return true
        }
        if googleFocusTimeMetadataCategory(category) {
            return true
        }

        let normalized = category
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        return normalized.hasPrefix("google-color-")
            || normalized.hasPrefix("google color ")
            || googleEventTypeMetadata(from: [category]) != nil
    }

    private func googleAttendeesOmittedMetadata(from categories: [String]) -> Bool? {
        categories.contains(where: Self.googleAttendeesOmittedMetadata) ? true : nil
    }

    fileprivate static func googleAttendeesOmittedMetadata(_ category: String) -> Bool {
        let normalized = category
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return normalized == Self.attendeesOmittedMetadataCategory.lowercased().replacingOccurrences(of: " ", with: "-")
            || normalized == "google-attendees-omitted"
            || normalized == "google-partial-attendees"
            || normalized == "google-attendees-partial"
    }

    fileprivate static func googleGuestsHiddenMetadataCategory(_ category: String) -> Bool {
        let normalized = category
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return normalized == Self.guestsHiddenMetadataCategory.lowercased().replacingOccurrences(of: " ", with: "-")
            || normalized == "google-guests-hidden"
            || normalized == "google-hidden-guests"
            || normalized == "google-guests-cannot-see-guests"
    }

    fileprivate static func googleGuestsCannotInviteMetadataCategory(_ category: String) -> Bool {
        let normalized = category
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return normalized == Self.guestsCannotInviteMetadataCategory.lowercased().replacingOccurrences(of: " ", with: "-")
            || normalized == "google-guests-cant-invite"
            || normalized == "google-guest-invites-disabled"
    }

    fileprivate static func googleGuestsCanModifyMetadataCategory(_ category: String) -> Bool {
        let normalized = category
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return normalized == Self.guestsCanModifyMetadataCategory.lowercased().replacingOccurrences(of: " ", with: "-")
            || normalized == "google-guests-can-edit"
            || normalized == "google-guests-may-modify"
    }

    fileprivate static func googleVisibilityMetadata(from categories: [String]) -> String? {
        for category in categories {
            let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = trimmed.lowercased()
            let rawValue: String?
            if lowercased.hasPrefix(visibilityCategoryPrefix.lowercased()) {
                rawValue = String(trimmed.dropFirst(visibilityCategoryPrefix.count))
            } else if lowercased.hasPrefix("google-visibility-") {
                rawValue = String(trimmed.dropFirst("google-visibility-".count))
            } else {
                rawValue = nil
            }
            let normalized = rawValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")
            if normalized == "public" {
                return "public"
            }
        }
        return nil
    }

    fileprivate static func googleVisibilityMetadataCategory(for visibility: String?) -> String? {
        let normalized = visibility?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        return normalized == "public" ? "\(visibilityCategoryPrefix)public" : nil
    }

    fileprivate static func normalizedGoogleConferenceType(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "") ?? ""

        switch normalized {
        case "hangoutsmeet", "googlemeet", "meet":
            return "hangoutsMeet"
        case "addon", "add-on":
            return "addOn"
        case "eventhangout":
            return "eventHangout"
        case "eventnamedhangout":
            return "eventNamedHangout"
        default:
            return nil
        }
    }

    fileprivate static func googleEventTypeMetadata(from categories: [String]) -> String? {
        for category in categories {
            guard let rawValue = googleMetadataSuffix(
                in: category,
                humanPrefix: eventTypeCategoryPrefix,
                dashedPrefix: "google-event-type-"
            ) else { continue }
            let normalized = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")
            switch normalized {
            case "workinglocation":
                return "workingLocation"
            case "outofoffice":
                return "outOfOffice"
            case "focustime":
                return "focusTime"
            case "birthday":
                return "birthday"
            case "fromgmail":
                return "fromGmail"
            case "default":
                return "default"
            default:
                return rawValue.nilIfBlank
            }
        }
        return nil
    }

    fileprivate static func googleWorkingLocationTypeMetadata(from categories: [String]) -> String? {
        for category in categories {
            guard let rawValue = googleMetadataSuffix(
                in: category,
                humanPrefix: workingLocationTypeCategoryPrefix,
                dashedPrefix: "google-working-location-"
            ) else { continue }
            let normalized = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")
            switch normalized {
            case "office", "officelocation":
                return "officeLocation"
            case "home", "homeoffice":
                return "homeOffice"
            case "custom", "customlocation":
                return "customLocation"
            default:
                continue
            }
        }
        return nil
    }

    fileprivate static func googleWorkingLocationOfficeMetadata(from categories: [String]) -> GoogleWorkingLocationOfficeMetadata {
        GoogleWorkingLocationOfficeMetadata(
            buildingId: googleMetadataSuffix(
                in: categories,
                humanPrefix: workingLocationBuildingCategoryPrefix,
                dashedPrefix: "google-working-location-building-"
            ),
            floorId: googleMetadataSuffix(
                in: categories,
                humanPrefix: workingLocationFloorCategoryPrefix,
                dashedPrefix: "google-working-location-floor-"
            ),
            floorSectionId: googleMetadataSuffix(
                in: categories,
                humanPrefix: workingLocationFloorSectionCategoryPrefix,
                dashedPrefix: "google-working-location-floor-section-"
            ),
            deskId: googleMetadataSuffix(
                in: categories,
                humanPrefix: workingLocationDeskCategoryPrefix,
                dashedPrefix: "google-working-location-desk-"
            )
        )
    }

    fileprivate static func googleWorkingLocationMetadataCategory(_ category: String) -> Bool {
        googleWorkingLocationTypeMetadata(from: [category]) != nil
            || googleMetadataSuffix(in: category, humanPrefix: workingLocationBuildingCategoryPrefix, dashedPrefix: "google-working-location-building-") != nil
            || googleMetadataSuffix(in: category, humanPrefix: workingLocationFloorCategoryPrefix, dashedPrefix: "google-working-location-floor-") != nil
            || googleMetadataSuffix(in: category, humanPrefix: workingLocationFloorSectionCategoryPrefix, dashedPrefix: "google-working-location-floor-section-") != nil
            || googleMetadataSuffix(in: category, humanPrefix: workingLocationDeskCategoryPrefix, dashedPrefix: "google-working-location-desk-") != nil
    }

    fileprivate static func googleOutOfOfficeMetadataCategory(_ category: String) -> Bool {
        googleMetadataSuffix(in: category, humanPrefix: outOfOfficeAutoDeclineCategoryPrefix, dashedPrefix: "google-out-of-office-auto-decline-") != nil
            || googleMetadataSuffix(in: category, humanPrefix: outOfOfficeDeclineMessageCategoryPrefix, dashedPrefix: "google-out-of-office-decline-message-") != nil
    }

    fileprivate static func googleFocusTimeMetadataCategory(_ category: String) -> Bool {
        googleMetadataSuffix(in: category, humanPrefix: focusTimeAutoDeclineCategoryPrefix, dashedPrefix: "google-focus-time-auto-decline-") != nil
            || googleMetadataSuffix(in: category, humanPrefix: focusTimeDeclineMessageCategoryPrefix, dashedPrefix: "google-focus-time-decline-message-") != nil
            || googleMetadataSuffix(in: category, humanPrefix: focusTimeChatStatusCategoryPrefix, dashedPrefix: "google-focus-time-chat-status-") != nil
    }

    private static func googleMetadataSuffix(in categories: [String], humanPrefix: String, dashedPrefix: String) -> String? {
        categories.lazy.compactMap {
            googleMetadataSuffix(in: $0, humanPrefix: humanPrefix, dashedPrefix: dashedPrefix)
        }.first
    }

    private static func googleMetadataSuffix(in category: String, humanPrefix: String, dashedPrefix: String) -> String? {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix(humanPrefix.lowercased()) {
            return String(trimmed.dropFirst(humanPrefix.count)).nilIfBlank
        }
        if lowercased.hasPrefix(dashedPrefix.lowercased()) {
            return String(trimmed.dropFirst(dashedPrefix.count)).nilIfBlank
        }
        return nil
    }

    fileprivate static func googleConferenceTypeMetadata(from categories: [String]) -> String? {
        for category in categories {
            let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = trimmed.lowercased()
            let rawValue: String?

            if lowercased.hasPrefix(conferenceTypeCategoryPrefix.lowercased()) {
                rawValue = String(trimmed.dropFirst(conferenceTypeCategoryPrefix.count))
            } else if lowercased.hasPrefix("google-conference-") {
                rawValue = String(trimmed.dropFirst("google-conference-".count))
            } else {
                rawValue = nil
            }

            if let type = normalizedGoogleConferenceType(rawValue) {
                return type
            }
        }
        return nil
    }

    fileprivate static func googleWorkingLocationMetadataCategories(from properties: GoogleWorkingLocationProperties?) -> [String] {
        guard let properties else { return [] }
        var categories: [String] = []
        if let type = properties.metadataType {
            categories.append("\(workingLocationTypeCategoryPrefix)\(type)")
        }
        if let officeLocation = properties.officeLocation {
            categories.append(contentsOf: officeLocation.metadataCategories)
        }
        return categories
    }

    fileprivate static func googleOutOfOfficeMetadataCategories(from properties: GoogleOutOfOfficeProperties?) -> [String] {
        guard let properties else { return [] }
        return [
            properties.autoDeclineMode.nilIfBlank.map { "\(outOfOfficeAutoDeclineCategoryPrefix)\($0)" },
            properties.declineMessage.nilIfBlank.map { "\(outOfOfficeDeclineMessageCategoryPrefix)\($0)" }
        ].compactMap { $0 }
    }

    fileprivate static func googleFocusTimeMetadataCategories(from properties: GoogleFocusTimeProperties?) -> [String] {
        guard let properties else { return [] }
        return [
            properties.autoDeclineMode.nilIfBlank.map { "\(focusTimeAutoDeclineCategoryPrefix)\($0)" },
            properties.declineMessage.nilIfBlank.map { "\(focusTimeDeclineMessageCategoryPrefix)\($0)" },
            properties.chatStatus.nilIfBlank.map { "\(focusTimeChatStatusCategoryPrefix)\($0)" }
        ].compactMap { $0 }
    }

    fileprivate static func googleConferenceTypeMetadataCategory(from conferenceData: GoogleConferenceData?) -> String? {
        if let type = normalizedGoogleConferenceType(conferenceData?.conferenceSolution?.key?.type) {
            return "\(conferenceTypeCategoryPrefix)\(type)"
        }
        if conferenceData?.entryPoints?.contains(where: { entryPoint in
            guard entryPoint.entryPointType?.lowercased() == "video",
                  let url = entryPoint.uri.nilIfBlank.flatMap(URL.init(string:)) else {
                return false
            }
            return MeetingPlatform(url: url) == .googleMeet
        }) == true {
            return "\(conferenceTypeCategoryPrefix)hangoutsMeet"
        }
        return nil
    }

    fileprivate static func googleEncodedWorkingCategories(_ categories: [String]) -> String? {
        guard let data = try? JSONEncoder().encode(normalizedEventCategories(categories)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    fileprivate static func googleDecodedWorkingCategories(_ value: String?) -> [String] {
        guard let value,
              let data = value.data(using: .utf8),
              let categories = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return normalizedEventCategories(categories)
    }

    fileprivate static func googleEncodedRelatedEvents(_ relationships: [LocalEventRelationship]) -> String? {
        let normalizedRelationships = normalizedEventRelationships(relationships)
        guard !normalizedRelationships.isEmpty,
              let data = try? JSONEncoder().encode(normalizedRelationships) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    fileprivate static func googleDecodedRelatedEvents(_ value: String?) -> [LocalEventRelationship] {
        guard let value,
              let data = value.data(using: .utf8),
              let relationships = try? JSONDecoder().decode([LocalEventRelationship].self, from: data) else {
            return []
        }
        return normalizedEventRelationships(relationships)
    }

    fileprivate static func googleEncodedGeoCoordinate(_ coordinate: LocalEventGeoCoordinate?) -> String? {
        guard let coordinate,
              let data = try? JSONEncoder().encode(coordinate) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    fileprivate static func googleDecodedGeoCoordinate(_ value: String?) -> LocalEventGeoCoordinate? {
        guard let value,
              let data = value.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(LocalEventGeoCoordinate.self, from: data)
    }

    private func googleRecurrenceFrequency(for frequency: LocalRecurrenceFrequency) -> String {
        switch frequency {
        case .none:
            return ""
        case .daily:
            return "DAILY"
        case .weekly:
            return "WEEKLY"
        case .monthly:
            return "MONTHLY"
        case .yearly:
            return "YEARLY"
        }
    }

    private func icsWeekdayName(for weekday: Int) -> String? {
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

    private func sanitizedColor(_ rawValue: String?) -> String {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.hasPrefix("#"), trimmed.count >= 7 else { return "#4285F4" }
        return String(trimmed.prefix(7))
    }

    private let rfc3339Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private let rfc3339FractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
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

    private let googleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    fileprivate func parseRFC3339(_ value: String) -> Date? {
        rfc3339FractionalFormatter.date(from: value) ?? rfc3339Formatter.date(from: value)
    }

    fileprivate func parseGoogleDate(_ value: String) -> Date? {
        googleDateFormatter.date(from: value)
    }
}

struct GoogleCalendarEvent: Decodable {
    let id: String
    let etag: String?
    let status: String?
    let htmlLink: String?
    let created: String?
    let updated: String?
    let summary: String?
    let description: String?
    let location: String?
    let iCalUID: String?
    let recurringEventId: String?
    let originalStartTime: GoogleEventDateTime?
    let start: GoogleEventDateTime?
    let end: GoogleEventDateTime?
    let recurrence: [String]?
    let sequence: Int?
    let transparency: String?
    let visibility: String?
    let colorId: String?
    let eventType: String?
    let reminders: GoogleEventReminders?
    let attendees: [GoogleEventAttendee]?
    let attendeesOmitted: Bool?
    let guestsCanSeeOtherGuests: Bool?
    let guestsCanInviteOthers: Bool?
    let guestsCanModify: Bool?
    let organizer: GoogleEventPerson?
    let creator: GoogleEventPerson?
    let hangoutLink: String?
    let conferenceData: GoogleConferenceData?
    let workingLocationProperties: GoogleWorkingLocationProperties?
    let outOfOfficeProperties: GoogleOutOfOfficeProperties?
    let focusTimeProperties: GoogleFocusTimeProperties?
    let source: GoogleEventSource?
    let extendedProperties: GoogleEventExtendedProperties?
    let attachments: [GoogleEventAttachment]?

    var createdDate: Date? {
        created.flatMap(GoogleCalendarClient.sharedParser.parseRFC3339)
    }

    var updatedDate: Date? {
        updated.flatMap(GoogleCalendarClient.sharedParser.parseRFC3339)
    }

    var isCancelled: Bool {
        status?.lowercased() == "cancelled"
    }

    var isRecurringInstance: Bool {
        recurringEventId.nilIfBlank != nil
    }

    var sequenceValue: Int {
        max(0, sequence ?? 0)
    }

    var privacy: CalendarEventPrivacy {
        CalendarEventPrivacy(googleVisibility: visibility)
    }

    var categories: [String] {
        let workingCategories = GoogleCalendarClient.googleDecodedWorkingCategories(
            extendedProperties?.privateProperties?[GoogleCalendarClient.workingCategoriesExtendedPropertyKey]
        )
        return normalizedEventCategories([
            colorId.nilIfBlank.map { "Google color \($0)" },
            GoogleCalendarClient.googleVisibilityMetadataCategory(for: visibility),
            eventType.nilIfBlank.map { "Google event type \($0)" },
            attendeesOmitted == true ? GoogleCalendarClient.attendeesOmittedMetadataCategory : nil,
            guestsCanSeeOtherGuests == false ? GoogleCalendarClient.guestsHiddenMetadataCategory : nil,
            guestsCanInviteOthers == false ? GoogleCalendarClient.guestsCannotInviteMetadataCategory : nil,
            guestsCanModify == true ? GoogleCalendarClient.guestsCanModifyMetadataCategory : nil,
            GoogleCalendarClient.googleConferenceTypeMetadataCategory(from: conferenceData)
        ].compactMap { $0 }
            + GoogleCalendarClient.googleWorkingLocationMetadataCategories(from: workingLocationProperties)
            + GoogleCalendarClient.googleOutOfOfficeMetadataCategories(from: outOfOfficeProperties)
            + GoogleCalendarClient.googleFocusTimeMetadataCategories(from: focusTimeProperties)
            + workingCategories)
    }

    var relatedEvents: [LocalEventRelationship] {
        GoogleCalendarClient.googleDecodedRelatedEvents(
            extendedProperties?.privateProperties?[GoogleCalendarClient.relatedEventsExtendedPropertyKey]
        )
    }

    var geoCoordinate: LocalEventGeoCoordinate? {
        GoogleCalendarClient.googleDecodedGeoCoordinate(
            extendedProperties?.privateProperties?[GoogleCalendarClient.geoCoordinateExtendedPropertyKey]
        )
    }

    func reminderOffsets(defaults: [Int]) -> [Int] {
        guard let reminders else { return defaults }
        if reminders.useDefault == true {
            return defaults
        }
        return normalizedReminderOffsets(
            reminders.overrides?
                .filter { $0.method?.lowercased() == "popup" || $0.method == nil }
                .compactMap(\.minutes) ?? []
        )
    }

    func myResponseStatus(calendar: GoogleCalendarInfo, account: CalendarProviderAccount) -> EventResponseStatus? {
        let identityEmails = GoogleCalendarClient.sharedParser.googleIdentityEmails(
            calendarID: calendar.id,
            account: account,
            isPrimaryCalendar: calendar.isPrimary
        )
        if let attendee = attendees?.first(where: {
            GoogleCalendarClient.sharedParser.googleAttendeeMatchesCurrentUser($0, identityEmails: identityEmails)
        }) {
            return EventResponseStatus(googleResponseStatus: attendee.responseStatus)
        }
        if GoogleCalendarClient.sharedParser.googlePersonMatchesCurrentUser(organizer, identityEmails: identityEmails)
            || GoogleCalendarClient.sharedParser.googlePersonMatchesCurrentUser(creator, identityEmails: identityEmails) {
            return .accepted
        }
        return nil
    }

    var displayLocationString: String? {
        location.nilIfBlank ?? workingLocationProperties?.displayText
    }

    var bestJoinURLString: String? {
        let entryPointURIs = (conferenceData?.entryPoints ?? [])
            .sorted { lhs, rhs in
                (lhs.entryPointType?.lowercased() == "video" ? 0 : 1) < (rhs.entryPointType?.lowercased() == "video" ? 0 : 1)
            }
            .compactMap(\.uri.nilIfBlank)
        let structuredCandidates = entryPointURIs + [hangoutLink.nilIfBlank, source?.url.nilIfBlank].compactMap { $0 }
        let attachmentCandidates = (attachments ?? []).compactMap(\.fileUrl.nilIfBlank)
        let richTextCandidates = [description.nilIfBlank, location.nilIfBlank].compactMap { $0 }
        if let url = MeetingLinkExtractor.preferredLink(eventURL: nil, textFields: structuredCandidates + attachmentCandidates + richTextCandidates) {
            return url.absoluteString
        }
        if let url = MeetingLinkExtractor.bestLink(eventURL: nil, textFields: structuredCandidates) {
            return url.absoluteString
        }

        return htmlLink.nilIfBlank
    }
}

struct GoogleEventAttachment: Decodable {
    let fileUrl: String?
    let title: String?
    let mimeType: String?
}

struct GoogleWorkingLocationProperties: Codable {
    let type: String?
    let homeOffice: GoogleWorkingLocationHomeOffice?
    let officeLocation: GoogleWorkingLocationOffice?
    let customLocation: GoogleWorkingLocationCustom?

    var displayText: String? {
        switch type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "officelocation":
            return officeLocation?.displayText
        case "customlocation":
            return customLocation?.label.nilIfBlank
        case "homeoffice":
            return "Home office"
        default:
            return officeLocation?.displayText
                ?? customLocation?.label.nilIfBlank
                ?? (homeOffice != nil ? "Home office" : nil)
        }
    }

    var metadataType: String? {
        switch type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "officelocation":
            return "office"
        case "customlocation":
            return "custom"
        case "homeoffice":
            return "home"
        default:
            if officeLocation != nil {
                return "office"
            }
            if customLocation != nil {
                return "custom"
            }
            if homeOffice != nil {
                return "home"
            }
            return nil
        }
    }
}

struct GoogleWorkingLocationHomeOffice: Codable {}

struct GoogleWorkingLocationOffice: Codable {
    let buildingId: String?
    let floorId: String?
    let floorSectionId: String?
    let deskId: String?
    let label: String?

    var displayText: String? {
        if let label = label.nilIfBlank {
            return label
        }
        let parts = [
            buildingId.nilIfBlank,
            floorId.nilIfBlank,
            floorSectionId.nilIfBlank,
            deskId.nilIfBlank
        ].compactMap { $0 }
        return normalizedEventCategories(parts).joined(separator: " / ").nilIfBlank
    }

    var metadataCategories: [String] {
        [
            buildingId.nilIfBlank.map { "\(GoogleCalendarClient.workingLocationBuildingCategoryPrefix)\($0)" },
            floorId.nilIfBlank.map { "\(GoogleCalendarClient.workingLocationFloorCategoryPrefix)\($0)" },
            floorSectionId.nilIfBlank.map { "\(GoogleCalendarClient.workingLocationFloorSectionCategoryPrefix)\($0)" },
            deskId.nilIfBlank.map { "\(GoogleCalendarClient.workingLocationDeskCategoryPrefix)\($0)" }
        ].compactMap { $0 }
    }
}

struct GoogleWorkingLocationCustom: Codable {
    let label: String?
}

struct GoogleOutOfOfficeProperties: Codable {
    let autoDeclineMode: String?
    let declineMessage: String?

    var hasAnyValue: Bool {
        autoDeclineMode.nilIfBlank != nil || declineMessage.nilIfBlank != nil
    }
}

struct GoogleFocusTimeProperties: Codable {
    let autoDeclineMode: String?
    let declineMessage: String?
    let chatStatus: String?

    var hasAnyValue: Bool {
        autoDeclineMode.nilIfBlank != nil || declineMessage.nilIfBlank != nil || chatStatus.nilIfBlank != nil
    }
}

struct GoogleWorkingLocationOfficeMetadata {
    let buildingId: String?
    let floorId: String?
    let floorSectionId: String?
    let deskId: String?

    var hasAnyValue: Bool {
        [buildingId, floorId, floorSectionId, deskId].contains { $0.nilIfBlank != nil }
    }
}

private struct GoogleCalendarListResponse: Decodable {
    let items: [GoogleCalendarListItem]
    let nextPageToken: String?
}

private struct GoogleCalendarListItem: Decodable {
    let id: String?
    let summary: String?
    let summaryOverride: String?
    let backgroundColor: String?
    let accessRole: String?
    let primary: Bool?
    let hidden: Bool?
    let deleted: Bool?
    let defaultReminders: [GoogleEventReminderOverride]?
}

private struct GoogleEventsResponse: Decodable {
    let items: [GoogleCalendarEvent]
    let nextPageToken: String?
    let nextSyncToken: String?
}

private struct GoogleEventsFetchResult {
    let events: [GoogleCalendarEvent]
    let syncToken: String
}

private struct GoogleOccurrenceDeleteTarget {
    let eventID: String
    let remoteETag: String
}

private struct GoogleDetachedOccurrencePatchTarget {
    let eventID: String
    let remoteETag: String
    let occurrence: LocalDetachedOccurrence
}

private struct GoogleRecurringExceptionWriteTargets {
    let occurrencesToDelete: [GoogleOccurrenceDeleteTarget]
    let detachedOccurrencesToPatch: [GoogleDetachedOccurrencePatchTarget]
}

private struct GoogleEventResponse: Decodable {
    let id: String?
    let etag: String?
}

struct GoogleEventDateTime: Decodable {
    let date: String?
    let dateTime: String?
    let timeZone: String?

    var resolvedDate: Date? {
        if let date = date.nilIfBlank {
            return GoogleCalendarClient.sharedParser.parseGoogleDate(date)
        }

        guard let dateTime = dateTime.nilIfBlank else { return nil }
        return GoogleCalendarClient.sharedParser.parseRFC3339(dateTime)
    }

    func dateLines(prefix: String) -> String? {
        if let date = date.nilIfBlank {
            let compactDate = date.replacingOccurrences(of: "-", with: "")
            return "\(prefix);VALUE=DATE:\(compactDate)"
        }

        guard let dateTime = dateTime.nilIfBlank,
              let date = GoogleCalendarClient.sharedParser.parseRFC3339(dateTime)
        else {
            return nil
        }

        if let timeZoneIdentifier = timeZone.nilIfBlank,
           let localDateTime = GoogleCalendarClient.sharedParser.googleICSDateTimeString(from: date, timeZoneIdentifier: timeZoneIdentifier) {
            return "\(prefix);TZID=\(timeZoneIdentifier):\(localDateTime)"
        }

        return "\(prefix):\(GoogleCalendarClient.sharedParser.icsDateTimeFormatter.string(from: date))"
    }
}

struct GoogleEventAttendee: Decodable {
    let email: String?
    let displayName: String?
    let responseStatus: String?
    let optional: Bool?
    let resource: Bool?
    let selfFlag: Bool?

    private enum CodingKeys: String, CodingKey {
        case email
        case displayName
        case responseStatus
        case optional
        case resource
        case selfFlag = "self"
    }
}

struct GoogleEventReminders: Decodable {
    let useDefault: Bool?
    let overrides: [GoogleEventReminderOverride]?
}

struct GoogleEventReminderOverride: Decodable {
    let method: String?
    let minutes: Int?
}

struct GoogleEventPerson: Decodable {
    let email: String?
    let displayName: String?
    let selfFlag: Bool?

    private enum CodingKeys: String, CodingKey {
        case email
        case displayName
        case selfFlag = "self"
    }
}

struct GoogleConferenceData: Codable {
    let entryPoints: [GoogleConferenceEntryPoint]?
    let conferenceSolution: GoogleConferenceSolution?
    let createRequest: GoogleConferenceCreateRequest?

    init(
        entryPoints: [GoogleConferenceEntryPoint]? = nil,
        conferenceSolution: GoogleConferenceSolution? = nil,
        createRequest: GoogleConferenceCreateRequest? = nil
    ) {
        self.entryPoints = entryPoints
        self.conferenceSolution = conferenceSolution
        self.createRequest = createRequest
    }
}

struct GoogleConferenceEntryPoint: Codable {
    let entryPointType: String?
    let uri: String?
}

struct GoogleConferenceSolution: Codable {
    let key: GoogleConferenceSolutionKey?
}

struct GoogleConferenceSolutionKey: Codable {
    let type: String?
}

struct GoogleConferenceCreateRequest: Codable {
    let requestId: String
    let conferenceSolutionKey: GoogleConferenceSolutionKey
}

struct GoogleEventExtendedProperties: Codable {
    let privateProperties: [String: String]?
    let sharedProperties: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case privateProperties = "private"
        case sharedProperties = "shared"
    }
}

private struct GoogleEventWriteRequest: Encodable {
    let id: String?
    let status: String?
    let summary: String
    let location: String?
    let description: String?
    let start: GoogleEventTimeWrite
    let end: GoogleEventTimeWrite
    let transparency: String
    let visibility: String?
    let colorId: String?
    let guestsCanSeeOtherGuests: Bool?
    let guestsCanInviteOthers: Bool?
    let guestsCanModify: Bool?
    let sequence: Int
    let reminders: GoogleEventRemindersWrite?
    let attendees: [GoogleAttendeeWrite]?
    let attendeesOmitted: Bool?
    let recurrence: [String]?
    let conferenceData: GoogleConferenceData?
    let attachments: [GoogleAttachmentWrite]?
    let workingLocationProperties: GoogleWorkingLocationProperties?
    let outOfOfficeProperties: GoogleOutOfOfficeProperties?
    let focusTimeProperties: GoogleFocusTimeProperties?
    let source: GoogleEventSource?
    let extendedProperties: GoogleEventExtendedProperties?
    let encodesClearingNulls: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case summary
        case location
        case description
        case start
        case end
        case transparency
        case visibility
        case colorId
        case guestsCanSeeOtherGuests
        case guestsCanInviteOthers
        case guestsCanModify
        case sequence
        case reminders
        case attendees
        case attendeesOmitted
        case recurrence
        case conferenceData
        case attachments
        case workingLocationProperties
        case outOfOfficeProperties
        case focusTimeProperties
        case source
        case extendedProperties
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(transparency, forKey: .transparency)
        try container.encodeIfPresent(visibility, forKey: .visibility)
        if let colorId {
            try container.encode(colorId, forKey: .colorId)
        } else if encodesClearingNulls {
            try container.encodeNil(forKey: .colorId)
        }
        try container.encodeIfPresent(guestsCanSeeOtherGuests, forKey: .guestsCanSeeOtherGuests)
        try container.encodeIfPresent(guestsCanInviteOthers, forKey: .guestsCanInviteOthers)
        try container.encodeIfPresent(guestsCanModify, forKey: .guestsCanModify)
        try container.encode(sequence, forKey: .sequence)
        try container.encodeIfPresent(reminders, forKey: .reminders)
        try container.encodeIfPresent(attendees, forKey: .attendees)
        try container.encodeIfPresent(attendeesOmitted, forKey: .attendeesOmitted)
        try container.encodeIfPresent(recurrence, forKey: .recurrence)
        try container.encodeIfPresent(conferenceData, forKey: .conferenceData)
        try container.encodeIfPresent(attachments, forKey: .attachments)
        try container.encodeIfPresent(workingLocationProperties, forKey: .workingLocationProperties)
        try container.encodeIfPresent(outOfOfficeProperties, forKey: .outOfOfficeProperties)
        try container.encodeIfPresent(focusTimeProperties, forKey: .focusTimeProperties)
        if let source {
            try container.encode(source, forKey: .source)
        } else if encodesClearingNulls {
            try container.encodeNil(forKey: .source)
        }
        try container.encodeIfPresent(extendedProperties, forKey: .extendedProperties)
    }

    var hasAttachments: Bool {
        attachments?.isEmpty == false
    }
}

private struct GoogleAttachmentWrite: Encodable {
    let fileUrl: String
    let title: String?
    let mimeType: String?
}

private struct GoogleEventAttendeesPatchRequest: Encodable {
    let attendeesOmitted: Bool
    let attendees: [GoogleAttendeeWrite]
}

private struct GoogleEventRemindersWrite: Encodable {
    let useDefault: Bool
    let overrides: [GoogleEventReminderOverrideWrite]
}

private struct GoogleEventReminderOverrideWrite: Encodable {
    let method: String
    let minutes: Int
}

private struct GoogleEventTimeWrite: Encodable {
    let date: String?
    let dateTime: String?
    let timeZone: String?
}

private struct GoogleAttendeeWrite: Encodable {
    let email: String?
    let displayName: String?
    let optional: Bool?
    let resource: Bool?
    let responseStatus: String
}

struct GoogleEventSource: Codable {
    let title: String
    let url: String
}

private struct GoogleErrorResponse: Decodable {
    let error: GoogleErrorBody?
}

private struct GoogleErrorBody: Decodable {
    let message: String?
}

private extension GoogleCalendarClient {
    static let sharedParser = GoogleCalendarClient()
}

private extension JSONDecoder {
    static var googleCalendar: JSONDecoder {
        JSONDecoder()
    }
}

private extension EventResponseStatus {
    init?(googleResponseStatus: String?) {
        switch googleResponseStatus?.lowercased() {
        case "accepted":
            self = .accepted
        case "declined":
            self = .declined
        case "tentative":
            self = .tentative
        case "needsaction", "needs_action", "":
            self = .pending
        default:
            return nil
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

    init(googleVisibility: String?) {
        switch googleVisibility?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "private":
            self = .private
        case "confidential":
            self = .confidential
        default:
            self = .public
        }
    }

    var googleVisibility: String? {
        switch self {
        case .public:
            return "default"
        case .private:
            return "private"
        case .confidential:
            return "confidential"
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var normalizedGoogleIdentityEmail: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        let withoutScheme: String
        if lowercased.hasPrefix("mailto:") {
            withoutScheme = String(trimmed.dropFirst("mailto:".count)).mailtoAddressComponent
        } else if lowercased.hasPrefix("smtp:") {
            withoutScheme = String(trimmed.dropFirst("smtp:".count)).mailtoAddressComponent
        } else {
            withoutScheme = trimmed
        }
        let email = withoutScheme.percentDecodedEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@") else { return nil }
        guard !email.hasSuffix("@group.calendar.google.com"),
              !email.hasSuffix("@resource.calendar.google.com")
        else {
            return nil
        }
        return email
    }

    var isGooglePersonalEmailCalendarID: Bool {
        normalizedGoogleIdentityEmail != nil
    }

    private var percentDecodedEmail: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.removingPercentEncoding ?? trimmed
    }

    private var mailtoAddressComponent: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        let queryIndex = trimmed.firstIndex { $0 == "?" || $0 == "#" } ?? trimmed.endIndex
        return String(trimmed[..<queryIndex])
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        self?.nilIfBlank
    }

    var normalizedGoogleIdentityEmail: String? {
        self?.normalizedGoogleIdentityEmail
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
