import Foundation

struct CalDAVCalendar: Hashable {
    let href: URL
    let displayName: String
    let colorHex: String
    let timeZoneIdentifier: String
    let syncToken: String
    let cTag: String
    let allowsEventWrite: Bool
    let allowsResponses: Bool

    init(
        href: URL,
        displayName: String,
        colorHex: String,
        timeZoneIdentifier: String = "",
        syncToken: String,
        cTag: String,
        allowsEventWrite: Bool,
        allowsResponses: Bool
    ) {
        self.href = href
        self.displayName = displayName
        self.colorHex = colorHex
        self.timeZoneIdentifier = timeZoneIdentifier
        self.syncToken = syncToken
        self.cTag = cTag
        self.allowsEventWrite = allowsEventWrite
        self.allowsResponses = allowsResponses
    }
}

struct CalDAVCalendarObject {
    let href: URL
    let icsText: String
    let eTag: String
}

struct CalDAVCalendarPayload {
    let calendar: CalDAVCalendar
    let objects: [CalDAVCalendarObject]
    let deletedObjectHrefs: Set<String>
    let isIncremental: Bool

    var reportsCompleteObjectSetForPruning: Bool {
        !isIncremental
    }

    var syncState: CalDAVCalendarSyncState {
        CalDAVCalendarSyncState(
            calendarHrefString: calendar.href.absoluteString,
            syncToken: calendar.syncToken,
            cTag: calendar.cTag
        )
    }
}

struct CalDAVWriteResult {
    let remoteObjectURL: URL
    let eTag: String
}

private struct CalDAVObjectFetchResult {
    let objects: [CalDAVCalendarObject]
    let deletedObjectHrefs: Set<String>
}

private enum CalDAVWritePrecondition {
    case mustNotExist
    case mustMatch(String)
}

enum CalDAVClientError: LocalizedError {
    case missingCredentials
    case discoveryFailed
    case calendarNotFound
    case remoteObjectMissing
    case scheduleOutboxNotFound
    case replyAttendeeNotFound
    case preconditionFailed(URL)
    case retryAfter(Int, URL)
    case httpStatus(Int, URL)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "CalDAV credentials are missing."
        case .discoveryFailed:
            return "Could not discover CalDAV calendars at this URL."
        case .calendarNotFound:
            return "Could not find the CalDAV calendar for this event."
        case .remoteObjectMissing:
            return "This event does not have a CalDAV object URL yet."
        case .scheduleOutboxNotFound:
            return "Could not discover the CalDAV scheduling outbox for this account."
        case .replyAttendeeNotFound:
            return "Could not build a CalDAV reply because the current attendee is missing."
        case .preconditionFailed(let url):
            return "CalDAV refused to save \(url.lastPathComponent) because the event changed remotely. Sync this calendar and try again."
        case .retryAfter(let seconds, let url):
            return "CalDAV asked Working Calendar to retry \(url.host ?? url.absoluteString) in \(seconds) seconds."
        case .httpStatus(let status, let url):
            return "CalDAV request returned HTTP \(status) for \(url.host ?? url.absoluteString)."
        }
    }

    var allowsFullSyncFallback: Bool {
        switch self {
        case .httpStatus(let status, _):
            return [400, 403, 405, 409, 501].contains(status)
        case .discoveryFailed:
            return true
        case .missingCredentials, .calendarNotFound, .remoteObjectMissing, .scheduleOutboxNotFound, .replyAttendeeNotFound, .preconditionFailed, .retryAfter:
            return false
        }
    }

    var allowsSchedulingReplyWriteBackFallback: Bool {
        switch self {
        case .scheduleOutboxNotFound:
            return true
        case .httpStatus(let status, _):
            return [400, 403, 404, 405, 501].contains(status)
        case .missingCredentials,
             .discoveryFailed,
             .calendarNotFound,
             .remoteObjectMissing,
             .replyAttendeeNotFound,
             .preconditionFailed,
             .retryAfter:
            return false
        }
    }
}

extension CalDAVClientError: ProviderRetryAfterError {
    var providerRetryAfterSeconds: Int? {
        guard case .retryAfter(let seconds, _) = self else { return nil }
        return seconds
    }
}

protocol CalDAVHTTPTransport {
    func data(for request: URLRequest, delegate: URLSessionTaskDelegate?) async throws -> (Data, URLResponse)
}

struct URLSessionCalDAVHTTPTransport: CalDAVHTTPTransport {
    func data(for request: URLRequest, delegate: URLSessionTaskDelegate?) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request, delegate: delegate)
    }
}

typealias CalDAVPasswordProvider = (String) -> String?

final class CalDAVClient {
    private static let redirectStatusCodes: Set<Int> = [301, 302, 307, 308]
    private static let maximumRedirectCount = 5
    private static let userAgent = "WorkingCalendar/1.0 (macOS; CalDAV)"

    private let transport: CalDAVHTTPTransport
    private let passwordProvider: CalDAVPasswordProvider

    init(
        transport: CalDAVHTTPTransport = URLSessionCalDAVHTTPTransport(),
        passwordProvider: @escaping CalDAVPasswordProvider = CalendarCredentialStore.password
    ) {
        self.transport = transport
        self.passwordProvider = passwordProvider
    }

    func fetchAccountIdentityEmail(account: CalendarProviderAccount) async throws -> String? {
        (try await fetchAccountIdentityEmails(account: account)).first
    }

    func fetchAccountIdentityEmails(account: CalendarProviderAccount) async throws -> [String] {
        guard let accountURL = account.endpointURL else { throw CalDAVClientError.discoveryFailed }

        var lastError: Error?
        for rootURL in discoveryRootCandidates(for: accountURL) {
            do {
                let principalURL = try await currentUserPrincipalURL(account: account, rootURL: rootURL)
                let identityEmails = try await calendarUserIdentityEmails(account: account, principalURL: principalURL)
                if !identityEmails.isEmpty {
                    return identityEmails
                }
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
        return []
    }

    func fetchCalendarPayloads(
        account: CalendarProviderAccount,
        startDate: Date,
        endDate: Date,
        syncStates: [CalDAVCalendarSyncState] = []
    ) async throws -> [CalDAVCalendarPayload] {
        let calendars = try await discoverCalendars(account: account)
        let syncStateByHref = Dictionary(uniqueKeysWithValues: syncStates.map { ($0.calendarHrefString, $0) })
        var payloads: [CalDAVCalendarPayload] = []

        for calendar in calendars {
            let previousState = syncStateByHref[calendar.href.absoluteString]
            if let syncToken = previousState?.syncToken.nilIfBlank {
                do {
                    payloads.append(try await fetchChangedObjects(
                        account: account,
                        calendar: calendar,
                        syncToken: syncToken
                    ))
                    continue
                } catch let error as CalDAVClientError where error.allowsFullSyncFallback {
                    payloads.append(try await fetchFullCalendarPayload(
                        account: account,
                        calendar: calendar,
                        startDate: startDate,
                        endDate: endDate
                    ))
                    continue
                }
            }

            if previousState?.cTag.nilIfBlank == calendar.cTag.nilIfBlank,
               calendar.cTag.nilIfBlank != nil {
                payloads.append(CalDAVCalendarPayload(
                    calendar: calendar,
                    objects: [],
                    deletedObjectHrefs: [],
                    isIncremental: true
                ))
                continue
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
        object: CalDAVCalendarObject,
        calendar: CalDAVCalendar,
        account: CalendarProviderAccount
    ) -> String {
        let calendarID = "local-calendar-caldav-\(account.id)-\(stableIdentifierComponent(for: calendar.href.absoluteString))"
        let normalizedLines = unfoldedICSLines(from: object.icsText)
        let injectsCalendarTimeZone = !calendar.timeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !normalizedLines.contains { line in
                icsProperty(from: line)?.name == "X-WR-TIMEZONE"
            }
        var lines: [String] = []
        var currentEventLines: [String]?

        for line in normalizedLines {
            let uppercasedLine = line.uppercased()
            if uppercasedLine == "BEGIN:VCALENDAR", injectsCalendarTimeZone {
                lines.append(line)
                lines.append("X-WR-TIMEZONE:\(escapeICSText(calendar.timeZoneIdentifier))")
                continue
            }

            if uppercasedLine == "BEGIN:VEVENT" {
                currentEventLines = [line]
                continue
            }

            if uppercasedLine == "END:VEVENT", var eventLines = currentEventLines {
                eventLines.append(line)
                lines.append(contentsOf: annotatedEventLines(
                    eventLines,
                    calendarID: calendarID,
                    calendar: calendar,
                    object: object,
                    account: account
                ))
                currentEventLines = nil
                continue
            }

            if currentEventLines != nil {
                currentEventLines?.append(line)
            } else {
                lines.append(line)
            }
        }

        if let currentEventLines {
            lines.append(contentsOf: currentEventLines)
        }

        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private func annotatedEventLines(
        _ eventLines: [String],
        calendarID: String,
        calendar: CalDAVCalendar,
        object: CalDAVCalendarObject,
        account: CalendarProviderAccount
    ) -> [String] {
        let currentUserResponse = currentUserResponseStatus(in: eventLines, account: account)
        var lines: [String] = []

        for line in eventLines {
            if currentUserResponse != nil,
               attendeeLineMatchesCurrentUser(line, account: account) {
                lines.append(attendeeLineWithCurrentUserFlag(line))
            } else {
                lines.append(line)
            }

            if line.uppercased() == "BEGIN:VEVENT" {
                lines.append("X-WORKING-CALENDAR-ID:\(escapeICSText(calendarID))")
                lines.append("X-WORKING-CALENDAR-TITLE:\(escapeICSText(calendar.displayName))")
                lines.append("X-WORKING-CALENDAR-COLOR:\(escapeICSText(calendar.colorHex))")
                lines.append("X-WORKING-CALENDAR-ALLOWS-EVENT-WRITE:\(calendar.allowsEventWrite ? "TRUE" : "FALSE")")
                lines.append("X-WORKING-CALENDAR-ALLOWS-RESPONSES:\(calendar.allowsResponses ? "TRUE" : "FALSE")")
                lines.append("X-WORKING-REMOTE-OBJECT-URL:\(escapeICSText(object.href.absoluteString))")
                if !object.eTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("X-WORKING-REMOTE-ETAG:\(escapeICSText(object.eTag))")
                }
                if let currentUserResponse {
                    lines.append("X-WORKING-MY-RESPONSE:\(currentUserResponse.rawValue)")
                }
            }
        }

        return lines
    }

    private func currentUserResponseStatus(in eventLines: [String], account: CalendarProviderAccount) -> EventResponseStatus? {
        for line in eventLines where attendeeLineMatchesCurrentUser(line, account: account) {
            guard let property = icsProperty(from: line),
                  let response = responseStatus(fromICSPartStat: property.params["PARTSTAT"])
            else {
                continue
            }
            return response
        }
        return nil
    }

    private func attendeeLineMatchesCurrentUser(_ line: String, account: CalendarProviderAccount) -> Bool {
        guard let property = icsProperty(from: line),
              property.name == "ATTENDEE",
              let attendeeEmail = normalizedEmail(icsEmailValue(from: property.value))
                ?? normalizedEmail(property.params["EMAIL"])
        else {
            return false
        }
        return identityEmails(for: account).contains(attendeeEmail)
    }

    private func attendeeLineWithCurrentUserFlag(_ line: String) -> String {
        guard !line.uppercased().contains(";X-WORKING-CURRENT-USER="),
              let separator = propertyValueSeparator(in: line)
        else {
            return line
        }
        return String(line[..<separator]) + ";X-WORKING-CURRENT-USER=TRUE" + String(line[separator...])
    }

    private func identityEmails(for account: CalendarProviderAccount) -> Set<String> {
        Set(([account.identityEmail] + account.identityEmailAliases.map(Optional.some) + [account.username, account.title])
            .compactMap { normalizedEmail($0) })
    }

    private func responseStatus(fromICSPartStat value: String?) -> EventResponseStatus? {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "ACCEPTED":
            return .accepted
        case "DECLINED":
            return .declined
        case "TENTATIVE":
            return .tentative
        case "DELEGATED":
            return .delegated
        case "COMPLETED":
            return .completed
        case "IN-PROCESS":
            return .inProcess
        case "NEEDS-ACTION", "":
            return .pending
        default:
            return nil
        }
    }

    func calendarMatching(localCalendarID: String, account: CalendarProviderAccount) async throws -> CalDAVCalendar {
        let calendars = try await discoverCalendars(account: account)
        guard let calendar = calendars.first(where: { self.localCalendarID(for: account, calendar: $0) == localCalendarID }) else {
            throw CalDAVClientError.calendarNotFound
        }

        return calendar
    }

    func putEvent(
        _ event: LocalCalendarEvent,
        localCalendar: LocalCalendar,
        account: CalendarProviderAccount,
        calendar: CalDAVCalendar
    ) async throws -> CalDAVWriteResult {
        let targetURL = remoteObjectURL(for: event, calendar: calendar)
        let eventForUpload = event.withRemoteObjectURL(targetURL.absoluteString)
        let body = LocalCalendarICSCodec.export(
            calendars: [localCalendar],
            events: [eventForUpload],
            method: nil,
            includeWorkingMetadata: false
        )
        let eTag: String
        do {
            eTag = try await calendarDataRequest(
                account: account,
                url: targetURL,
                method: "PUT",
                body: body,
                precondition: putPrecondition(for: event)
            )
        } catch CalDAVClientError.preconditionFailed(let url)
            where event.remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let recovered = try await recoverAlreadyCreatedEventObject(
                account: account,
                calendar: calendar,
                targetURL: targetURL,
                event: eventForUpload
            ) {
                return recovered
            }
            throw CalDAVClientError.preconditionFailed(url)
        }
        let resolvedETag: String
        if let headerETag = eTag.nilIfBlank {
            resolvedETag = headerETag
        } else {
            resolvedETag = (try? await fetchObjectETag(account: account, objectURL: targetURL)) ?? ""
        }
        return CalDAVWriteResult(remoteObjectURL: targetURL, eTag: resolvedETag)
    }

    func calendarDataPayloadPreview(
        for event: LocalCalendarEvent,
        localCalendar: LocalCalendar,
        calendar: CalDAVCalendar
    ) -> String {
        let targetURL = remoteObjectURL(for: event, calendar: calendar)
        let eventForUpload = event.withRemoteObjectURL(targetURL.absoluteString)
        return LocalCalendarICSCodec.export(
            calendars: [localCalendar],
            events: [eventForUpload],
            method: nil,
            includeWorkingMetadata: false
        )
    }

    func deleteEventObject(account: CalendarProviderAccount, remoteObjectURL: URL, remoteETag: String = "") async throws {
        _ = try await calendarDataRequest(
            account: account,
            url: remoteObjectURL,
            method: "DELETE",
            body: nil,
            precondition: remoteETag.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank.map(CalDAVWritePrecondition.mustMatch)
        )
    }

    func respondToEvent(
        account: CalendarProviderAccount,
        event: LocalCalendarEvent,
        response: CalendarEventResponse,
        occurrenceStartDate: Date?,
        occurrenceIsAllDay: Bool
    ) async throws {
        guard let body = schedulingReplyPayloadPreview(
            for: event,
            account: account,
            response: response,
            occurrenceStartDate: occurrenceStartDate,
            occurrenceIsAllDay: occurrenceIsAllDay
        ) else {
            throw CalDAVClientError.replyAttendeeNotFound
        }

        let outboxURL = try await scheduleOutboxURL(account: account)
        _ = try await calendarDataRequest(
            account: account,
            url: outboxURL,
            method: "POST",
            body: body,
            precondition: nil
        )
    }

    func schedulingReplyPayloadPreview(
        for event: LocalCalendarEvent,
        account: CalendarProviderAccount? = nil,
        response: CalendarEventResponse,
        occurrenceStartDate: Date? = nil,
        occurrenceIsAllDay: Bool = false,
        now: Date = Date()
    ) -> String? {
        let replyIdentity = replyAttendeeIdentity(for: event, account: account)
        return LocalCalendarICSCodec.reply(
            event: event,
            response: response,
            occurrenceStartDate: occurrenceStartDate,
            occurrenceIsAllDay: occurrenceIsAllDay,
            attendeeEmail: replyIdentity.email,
            attendeeName: replyIdentity.name,
            now: now
        )
    }

    private func replyAttendeeIdentity(
        for event: LocalCalendarEvent,
        account: CalendarProviderAccount?
    ) -> (email: String?, name: String?) {
        if let currentAttendee = event.attendees.first(where: \.isCurrentUser) {
            return (currentAttendee.email.nilIfBlank, currentAttendee.name.nilIfBlank)
        }

        guard let account else { return (nil, nil) }
        let emails = identityEmails(for: account)
        if let matchedAttendee = event.attendees.first(where: { attendee in
            guard let email = normalizedEmail(attendee.email) else { return false }
            return emails.contains(email)
        }) {
            return (matchedAttendee.email.nilIfBlank, matchedAttendee.name.nilIfBlank)
        }

        return (emails.sorted().first, nil)
    }

    private func discoverCalendars(account: CalendarProviderAccount) async throws -> [CalDAVCalendar] {
        guard let accountURL = account.endpointURL else { throw CalDAVClientError.discoveryFailed }

        var lastError: Error?
        for rootURL in discoveryRootCandidates(for: accountURL) {
            do {
                let calendars = try await discoverCalendars(account: account, rootURL: rootURL)
                guard !calendars.isEmpty else { continue }
                return calendars
            } catch {
                lastError = error
            }
        }

        throw lastError ?? CalDAVClientError.discoveryFailed
    }

    private func discoverCalendars(account: CalendarProviderAccount, rootURL: URL) async throws -> [CalDAVCalendar] {
        if let directCalendar = try await directCalendarIfPossible(account: account, url: rootURL) {
            return [directCalendar]
        }

        let principalURL = try await currentUserPrincipalURL(account: account, rootURL: rootURL)
        let homeURLs = try await calendarHomeURLs(account: account, principalURL: principalURL)
        var discoveredCalendars: [CalDAVCalendar] = []
        var lastError: Error?

        for homeURL in homeURLs {
            do {
                let calendars = try await calendarCollections(account: account, homeURL: homeURL)
                discoveredCalendars.append(contentsOf: calendars)
            } catch {
                lastError = error
            }
        }

        let calendars = uniqueCalendars(discoveredCalendars)
        if !calendars.isEmpty {
            return calendars
        }

        throw lastError ?? CalDAVClientError.discoveryFailed
    }

    private func discoveryRootCandidates(for accountURL: URL) -> [URL] {
        CalDAVDiscovery.rootCandidates(for: accountURL)
    }

    private func directCalendarIfPossible(account: CalendarProviderAccount, url: URL) async throws -> CalDAVCalendar? {
        let responses = try await propfind(
            account: account,
            url: url,
            depth: "0",
            body: Self.calendarPropertiesBody
        )
        guard let response = responses.first,
              response.resourceTypes.contains("calendar"),
              response.supportsEvents
        else {
            return nil
        }

        return CalDAVCalendar(
            href: calendarCollectionURL(from: url),
            displayName: response.properties["displayname"]?.nilIfBlank ?? account.title,
            colorHex: sanitizedColor(response.properties["calendar-color"]),
            timeZoneIdentifier: calendarTimeZoneIdentifier(response.properties["calendar-timezone"]),
            syncToken: response.properties["sync-token"] ?? "",
            cTag: response.properties["getctag"] ?? "",
            allowsEventWrite: response.allowsEventWrite,
            allowsResponses: response.allowsResponses
        )
    }

    private func currentUserPrincipalURL(account: CalendarProviderAccount, rootURL: URL) async throws -> URL {
        let responses = try await propfind(
            account: account,
            url: rootURL,
            depth: "0",
            body: Self.currentUserPrincipalBody
        )

        guard
            let href = responses.first?.properties["current-user-principal.href"] ?? responses.first?.properties["principal-URL.href"],
            let url = resolvedURL(from: href, relativeTo: rootURL)
        else {
            throw CalDAVClientError.discoveryFailed
        }

        return url
    }

    private func calendarHomeURLs(account: CalendarProviderAccount, principalURL: URL) async throws -> [URL] {
        let responses = try await propfind(
            account: account,
            url: principalURL,
            depth: "0",
            body: Self.calendarHomeSetBody
        )

        let properties = responses.first?.properties ?? [:]
        let urls = uniqueURLs(calendarHomeHrefs(from: properties).compactMap { href in
            resolvedURL(from: href, relativeTo: principalURL).map(calendarCollectionURL(from:))
        })

        guard !urls.isEmpty else {
            throw CalDAVClientError.discoveryFailed
        }

        return urls
    }

    private func calendarUserIdentityEmails(account: CalendarProviderAccount, principalURL: URL) async throws -> [String] {
        let responses = try await propfind(
            account: account,
            url: principalURL,
            depth: "0",
            body: Self.calendarUserAddressSetBody
        )
        let rawValues = responses.first?.properties["calendar-user-address-set.hrefs"]?
            .split(separator: "\n")
            .map(String.init) ?? []
        return uniqueEmails(rawValues.compactMap(normalizedEmail))
    }

    private func scheduleOutboxURL(account: CalendarProviderAccount) async throws -> URL {
        guard let accountURL = account.endpointURL else { throw CalDAVClientError.discoveryFailed }

        var lastError: Error?
        for rootURL in discoveryRootCandidates(for: accountURL) {
            do {
                let principalURL = try await currentUserPrincipalURL(account: account, rootURL: rootURL)
                return try await scheduleOutboxURL(account: account, principalURL: principalURL)
            } catch {
                lastError = error
            }
        }

        if let calDAVError = lastError as? CalDAVClientError {
            throw calDAVError
        }
        throw CalDAVClientError.scheduleOutboxNotFound
    }

    private func scheduleOutboxURL(account: CalendarProviderAccount, principalURL: URL) async throws -> URL {
        let responses = try await propfind(
            account: account,
            url: principalURL,
            depth: "0",
            body: Self.scheduleOutboxURLBody
        )

        guard
            let href = responses.first?.properties["schedule-outbox-URL.href"],
            let url = resolvedURL(from: href, relativeTo: principalURL)
        else {
            throw CalDAVClientError.scheduleOutboxNotFound
        }

        return calendarCollectionURL(from: url)
    }

    private func calendarCollections(account: CalendarProviderAccount, homeURL: URL) async throws -> [CalDAVCalendar] {
        let collectionHomeURL = calendarCollectionURL(from: homeURL)
        let responses = try await propfind(
            account: account,
            url: collectionHomeURL,
            depth: "1",
            body: Self.calendarPropertiesBody
        )

        return calendars(from: responses, homeURL: collectionHomeURL, fallbackTitle: "CalDAV Calendar")
    }

    private func calendars(from responses: [DAVResponse], homeURL: URL, fallbackTitle: String) -> [CalDAVCalendar] {
        responses.compactMap { response -> CalDAVCalendar? in
            guard response.resourceTypes.contains("calendar"),
                  response.supportsEvents,
                  let href = resolvedURL(from: response.href, relativeTo: homeURL)
            else {
                return nil
            }

            return CalDAVCalendar(
                href: calendarCollectionURL(from: href),
                displayName: response.properties["displayname"]?.nilIfBlank ?? fallbackTitle,
                colorHex: sanitizedColor(response.properties["calendar-color"]),
                timeZoneIdentifier: calendarTimeZoneIdentifier(response.properties["calendar-timezone"]),
                syncToken: response.properties["sync-token"] ?? "",
                cTag: response.properties["getctag"] ?? "",
                allowsEventWrite: response.allowsEventWrite,
                allowsResponses: response.allowsResponses
            )
        }
    }

    private func uniqueCalendars(_ calendars: [CalDAVCalendar]) -> [CalDAVCalendar] {
        var seen: Set<String> = []
        var result: [CalDAVCalendar] = []
        for calendar in calendars {
            let key = calendar.href.absoluteString
            guard seen.insert(key).inserted else { continue }
            result.append(calendar)
        }
        return result
    }

    private func fetchObjects(
        account: CalendarProviderAccount,
        calendar: CalDAVCalendar,
        startDate: Date,
        endDate: Date
    ) async throws -> [CalDAVCalendarObject] {
        let body = Self.calendarQueryBody(
            start: Self.calDAVDateFormatter.string(from: startDate),
            end: Self.calDAVDateFormatter.string(from: endDate)
        )
        let responses = try await report(account: account, url: calendar.href, depth: "1", body: body)

        return responses.compactMap { response -> CalDAVCalendarObject? in
            guard let icsText = response.properties["calendar-data"]?.nilIfBlank,
                  let href = resolvedURL(from: response.href, relativeTo: calendar.href)
            else {
                return nil
            }

            return CalDAVCalendarObject(
                href: href,
                icsText: icsText,
                eTag: response.properties["getetag"] ?? ""
            )
        }
    }

    private func fetchFullCalendarPayload(
        account: CalendarProviderAccount,
        calendar: CalDAVCalendar,
        startDate: Date,
        endDate: Date
    ) async throws -> CalDAVCalendarPayload {
        let objects = try await fetchObjects(
            account: account,
            calendar: calendar,
            startDate: startDate,
            endDate: endDate
        )
        return CalDAVCalendarPayload(
            calendar: calendar,
            objects: objects,
            deletedObjectHrefs: [],
            isIncremental: false
        )
    }

    private func fetchChangedObjects(
        account: CalendarProviderAccount,
        calendar: CalDAVCalendar,
        syncToken: String
    ) async throws -> CalDAVCalendarPayload {
        let result = try await syncCollection(
            account: account,
            url: calendar.href,
            body: Self.syncCollectionBody(syncToken: syncToken)
        )

        var objects: [CalDAVCalendarObject] = []
        var deletedObjectHrefs: Set<String> = []
        var changedObjectURLsMissingCalendarData: [URL] = []

        for response in result.responses {
            guard let href = resolvedURL(from: response.href, relativeTo: calendar.href) else { continue }
            if isMissingDAVObjectStatus(response.statusCode) {
                deletedObjectHrefs.insert(href.absoluteString)
                continue
            }

            if let icsText = response.properties["calendar-data"]?.nilIfBlank {
                objects.append(CalDAVCalendarObject(
                    href: href,
                    icsText: icsText,
                    eTag: response.properties["getetag"] ?? ""
                ))
            } else {
                changedObjectURLsMissingCalendarData.append(href)
            }
        }

        if !changedObjectURLsMissingCalendarData.isEmpty {
            let fetchedObjects = try await fetchObjectsByHref(
                account: account,
                calendar: calendar,
                objectURLs: changedObjectURLsMissingCalendarData
            )
            deletedObjectHrefs.formUnion(fetchedObjects.deletedObjectHrefs)
            let existingObjectURLs = Set(objects.map { $0.href.absoluteString })
            objects.append(contentsOf: fetchedObjects.objects.filter { !existingObjectURLs.contains($0.href.absoluteString) })
        }

        let nextSyncToken = result.syncToken?.nilIfBlank ?? calendar.syncToken
        let nextCalendar = CalDAVCalendar(
            href: calendarCollectionURL(from: calendar.href),
            displayName: calendar.displayName,
            colorHex: calendar.colorHex,
            timeZoneIdentifier: calendar.timeZoneIdentifier,
            syncToken: nextSyncToken,
            cTag: calendar.cTag,
            allowsEventWrite: calendar.allowsEventWrite,
            allowsResponses: calendar.allowsResponses
        )

        return CalDAVCalendarPayload(
            calendar: nextCalendar,
            objects: objects,
            deletedObjectHrefs: deletedObjectHrefs,
            isIncremental: true
        )
    }

    private func fetchObjectsByHref(
        account: CalendarProviderAccount,
        calendar: CalDAVCalendar,
        objectURLs: [URL]
    ) async throws -> CalDAVObjectFetchResult {
        let hrefs = objectURLs
            .map(davHref)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !hrefs.isEmpty else {
            return CalDAVObjectFetchResult(objects: [], deletedObjectHrefs: [])
        }

        let responses = try await report(
            account: account,
            url: calendar.href,
            depth: "1",
            body: Self.calendarMultigetBody(hrefs: hrefs)
        )

        var objects: [CalDAVCalendarObject] = []
        var deletedObjectHrefs: Set<String> = []

        for response in responses {
            guard let href = resolvedURL(from: response.href, relativeTo: calendar.href) else { continue }
            if isMissingDAVObjectStatus(response.statusCode) {
                deletedObjectHrefs.insert(href.absoluteString)
                continue
            }

            if let icsText = response.properties["calendar-data"]?.nilIfBlank {
                objects.append(CalDAVCalendarObject(
                    href: href,
                    icsText: icsText,
                    eTag: response.properties["getetag"] ?? ""
                ))
            }
        }

        return CalDAVObjectFetchResult(objects: objects, deletedObjectHrefs: deletedObjectHrefs)
    }

    private func fetchObjectETag(account: CalendarProviderAccount, objectURL: URL) async throws -> String? {
        let responses = try await propfind(
            account: account,
            url: objectURL,
            depth: "0",
            body: Self.objectETagBody
        )
        return responses.first?.properties["getetag"]?.nilIfBlank
    }

    private func recoverAlreadyCreatedEventObject(
        account: CalendarProviderAccount,
        calendar: CalDAVCalendar,
        targetURL: URL,
        event: LocalCalendarEvent
    ) async throws -> CalDAVWriteResult? {
        guard let object = try await fetchObjectsByHref(
            account: account,
            calendar: calendar,
            objectURLs: [targetURL]
        ).objects.first else {
            return nil
        }

        guard calendarObject(object, hasUID: event.externalUID) else {
            return nil
        }

        let resolvedETag: String
        if let objectETag = object.eTag.nilIfBlank {
            resolvedETag = objectETag
        } else {
            resolvedETag = (try? await fetchObjectETag(account: account, objectURL: object.href)) ?? ""
        }
        return CalDAVWriteResult(remoteObjectURL: object.href, eTag: resolvedETag)
    }

    private func calendarObject(_ object: CalDAVCalendarObject, hasUID uid: String) -> Bool {
        let normalizedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUID.isEmpty else { return false }

        for line in unfoldedICSLines(from: object.icsText) {
            guard let property = icsProperty(from: line), property.name == "UID" else { continue }
            return unescapeICSText(property.value).trimmingCharacters(in: .whitespacesAndNewlines) == normalizedUID
        }

        return false
    }

    private func propfind(account: CalendarProviderAccount, url: URL, depth: String, body: String) async throws -> [DAVResponse] {
        try await xmlRequest(account: account, url: url, method: "PROPFIND", depth: depth, body: body)
    }

    private func report(account: CalendarProviderAccount, url: URL, depth: String, body: String) async throws -> [DAVResponse] {
        try await xmlRequest(account: account, url: url, method: "REPORT", depth: depth, body: body)
    }

    private func syncCollection(account: CalendarProviderAccount, url: URL, body: String) async throws -> DAVXMLResult {
        try await xmlResultRequest(account: account, url: url, method: "REPORT", depth: "1", body: body)
    }

    private func xmlRequest(account: CalendarProviderAccount, url: URL, method: String, depth: String, body: String) async throws -> [DAVResponse] {
        try await xmlResultRequest(account: account, url: url, method: method, depth: depth, body: body).responses
    }

    private func xmlResultRequest(account: CalendarProviderAccount, url: URL, method: String, depth: String, body: String) async throws -> DAVXMLResult {
        guard let username = account.username?.nilIfBlank,
              let credentialKey = account.credentialKey,
              let password = passwordProvider(credentialKey)
        else {
            throw CalDAVClientError.missingCredentials
        }

        var requestURL = url
        var redirectCount = 0
        let requestDelegate = CalDAVRequestDelegate(username: username, password: password)

        while true {
            var request = URLRequest(url: requestURL)
            request.httpMethod = method
            applyCommonHeaders(to: &request, accept: "application/xml, text/xml")
            request.setValue(depth, forHTTPHeaderField: "Depth")
            request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body.data(using: .utf8)

            let (data, response) = try await transport.data(for: request, delegate: requestDelegate)
            if let httpResponse = response as? HTTPURLResponse {
                if let redirectURL = redirectURL(from: httpResponse, requestURL: requestURL),
                   redirectCount < Self.maximumRedirectCount {
                    requestURL = redirectURL
                    redirectCount += 1
                    continue
                }

                if !(200...299).contains(httpResponse.statusCode) {
                    if ProviderRetryAfter.isRetryAfterStatus(httpResponse.statusCode),
                       let retryAfterSeconds = ProviderRetryAfter.seconds(from: httpResponse) {
                        throw CalDAVClientError.retryAfter(retryAfterSeconds, requestURL)
                    }
                    throw CalDAVClientError.httpStatus(httpResponse.statusCode, requestURL)
                }
            }

            return try DAVXMLParser.parse(data)
        }
    }

    private func calendarDataRequest(
        account: CalendarProviderAccount,
        url: URL,
        method: String,
        body: String?,
        precondition: CalDAVWritePrecondition?
    ) async throws -> String {
        guard let username = account.username?.nilIfBlank,
              let credentialKey = account.credentialKey,
              let password = passwordProvider(credentialKey)
        else {
            throw CalDAVClientError.missingCredentials
        }

        var requestURL = url
        var redirectCount = 0
        let requestDelegate = CalDAVRequestDelegate(username: username, password: password)

        while true {
            var request = URLRequest(url: requestURL)
            request.httpMethod = method
            applyCommonHeaders(to: &request, accept: "text/calendar, */*")
            switch precondition {
            case .mustNotExist:
                request.setValue("*", forHTTPHeaderField: "If-None-Match")
            case .mustMatch(let eTag):
                request.setValue(eTag, forHTTPHeaderField: "If-Match")
            case nil:
                break
            }
            if let body {
                request.setValue("text/calendar; charset=utf-8", forHTTPHeaderField: "Content-Type")
                request.httpBody = body.data(using: .utf8)
            }

            let (_, response) = try await transport.data(for: request, delegate: requestDelegate)
            guard let httpResponse = response as? HTTPURLResponse else {
                return ""
            }

            if let redirectURL = redirectURL(from: httpResponse, requestURL: requestURL),
               redirectCount < Self.maximumRedirectCount {
                requestURL = redirectURL
                redirectCount += 1
                continue
            }

            if !(200...299).contains(httpResponse.statusCode) {
                if method == "DELETE", httpResponse.statusCode == 404 || httpResponse.statusCode == 410 {
                    return ""
                }
                if httpResponse.statusCode == 412 {
                    throw CalDAVClientError.preconditionFailed(requestURL)
                }
                if ProviderRetryAfter.isRetryAfterStatus(httpResponse.statusCode),
                   let retryAfterSeconds = ProviderRetryAfter.seconds(from: httpResponse) {
                    throw CalDAVClientError.retryAfter(retryAfterSeconds, requestURL)
                }
                throw CalDAVClientError.httpStatus(httpResponse.statusCode, requestURL)
            }

            return httpResponse.eTagHeader
        }
    }

    private func applyCommonHeaders(to request: inout URLRequest, accept: String) {
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("utf-8", forHTTPHeaderField: "Accept-Charset")
    }

    private func remoteObjectURL(for event: LocalCalendarEvent, calendar: CalDAVCalendar) -> URL {
        if let url = URL(string: event.remoteObjectURLString), url.scheme != nil {
            return url
        }

        let objectName = safeObjectName(for: event)
        return calendarCollectionURL(from: calendar.href).appendingPathComponent(objectName)
    }

    private func calendarCollectionURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        if components.path.isEmpty {
            components.path = "/"
        } else if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    private func putPrecondition(for event: LocalCalendarEvent) -> CalDAVWritePrecondition? {
        if event.remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .mustNotExist
        }

        let eTag = event.remoteETag.trimmingCharacters(in: .whitespacesAndNewlines)
        return eTag.isEmpty ? nil : .mustMatch(eTag)
    }

    private func isMissingDAVObjectStatus(_ statusCode: Int?) -> Bool {
        statusCode == 404 || statusCode == 410
    }

    func localCalendarID(for account: CalendarProviderAccount, calendar: CalDAVCalendar) -> String {
        "local-calendar-caldav-\(account.id)-\(stableIdentifierComponent(for: calendar.href.absoluteString))"
    }

    func parsedDAVXMLPreview(
        from text: String
    ) throws -> [(href: String, statusCode: Int?, properties: [String: String], privileges: Set<String>, allowsEventWrite: Bool, allowsResponses: Bool, supportsEvents: Bool)] {
        let result = try DAVXMLParser.parse(Data(text.utf8))
        return result.responses.map { response in
            (
                href: response.href,
                statusCode: response.statusCode,
                properties: response.properties,
                privileges: response.privileges,
                allowsEventWrite: response.allowsEventWrite,
                allowsResponses: response.allowsResponses,
                supportsEvents: response.supportsEvents
            )
        }
    }

    func calendarUserIdentityEmailPreview(from text: String) throws -> String? {
        try calendarUserIdentityEmailsPreview(from: text).first
    }

    func calendarUserIdentityEmailsPreview(from text: String) throws -> [String] {
        let result = try DAVXMLParser.parse(Data(text.utf8))
        let rawValues = result.responses.first?.properties["calendar-user-address-set.hrefs"]?
            .split(separator: "\n")
            .map(String.init) ?? []
        return uniqueEmails(rawValues.compactMap(normalizedEmail))
    }

    func calendarTimeZoneIdentifierPreview(from text: String) throws -> String {
        let result = try DAVXMLParser.parse(Data(text.utf8))
        return calendarTimeZoneIdentifier(result.responses.first?.properties["calendar-timezone"])
    }

    func calendarHomeURLStringsPreview(from text: String, principalURL: URL) throws -> [String] {
        let result = try DAVXMLParser.parse(Data(text.utf8))
        let properties = result.responses.first?.properties ?? [:]
        return uniqueURLs(calendarHomeHrefs(from: properties).compactMap { href in
            resolvedURL(from: href, relativeTo: principalURL).map(calendarCollectionURL(from:))
        }).map(\.absoluteString)
    }

    func aggregatedCalendarCollectionURLStringsPreview(homeFixtures: [(homeURL: URL, xml: String)]) throws -> [String] {
        var calendars: [CalDAVCalendar] = []
        for fixture in homeFixtures {
            let result = try DAVXMLParser.parse(Data(fixture.xml.utf8))
            let homeURL = calendarCollectionURL(from: fixture.homeURL)
            calendars.append(contentsOf: self.calendars(
                from: result.responses,
                homeURL: homeURL,
                fallbackTitle: "CalDAV Calendar"
            ))
        }
        return uniqueCalendars(calendars).map(\.href.absoluteString)
    }

    func redirectAllowedPreview(from sourceURL: URL, to destinationURL: URL) -> Bool {
        canFollowRedirect(from: sourceURL, to: destinationURL)
    }

    func incrementalDAVSyncPreview(
        from text: String,
        calendarHref: URL
    ) throws -> (objects: [String], deletedObjectHrefs: Set<String>) {
        let result = try DAVXMLParser.parse(Data(text.utf8))
        var objects: [String] = []
        var deletedObjectHrefs: Set<String> = []

        for response in result.responses {
            guard let href = resolvedURL(from: response.href, relativeTo: calendarHref) else { continue }
            if isMissingDAVObjectStatus(response.statusCode) {
                deletedObjectHrefs.insert(href.absoluteString)
                continue
            }

            if response.properties["calendar-data"]?.nilIfBlank != nil {
                objects.append(href.absoluteString)
            }
        }

        return (objects: objects, deletedObjectHrefs: deletedObjectHrefs)
    }

    func incrementalDAVSyncWithMultigetPreview(
        syncText: String,
        multigetText: String,
        calendarHref: URL
    ) throws -> (objects: [String], deletedObjectHrefs: Set<String>) {
        let syncResult = try DAVXMLParser.parse(Data(syncText.utf8))
        var objects: [String] = []
        var deletedObjectHrefs: Set<String> = []
        var objectHrefsMissingCalendarData: Set<String> = []

        for response in syncResult.responses {
            guard let href = resolvedURL(from: response.href, relativeTo: calendarHref) else { continue }
            if isMissingDAVObjectStatus(response.statusCode) {
                deletedObjectHrefs.insert(href.absoluteString)
                continue
            }

            if response.properties["calendar-data"]?.nilIfBlank != nil {
                objects.append(href.absoluteString)
            } else {
                objectHrefsMissingCalendarData.insert(href.absoluteString)
            }
        }

        guard !objectHrefsMissingCalendarData.isEmpty else {
            return (objects: objects, deletedObjectHrefs: deletedObjectHrefs)
        }

        let multigetResult = try DAVXMLParser.parse(Data(multigetText.utf8))
        var existingObjectHrefs = Set(objects)
        for response in multigetResult.responses {
            guard let href = resolvedURL(from: response.href, relativeTo: calendarHref),
                  objectHrefsMissingCalendarData.contains(href.absoluteString)
            else {
                continue
            }

            if isMissingDAVObjectStatus(response.statusCode) {
                deletedObjectHrefs.insert(href.absoluteString)
                continue
            }

            if response.properties["calendar-data"]?.nilIfBlank != nil,
               !existingObjectHrefs.contains(href.absoluteString) {
                objects.append(href.absoluteString)
                existingObjectHrefs.insert(href.absoluteString)
            }
        }

        return (objects: objects, deletedObjectHrefs: deletedObjectHrefs)
    }

    private func safeObjectName(for event: LocalCalendarEvent) -> String {
        let rawValue = event.externalUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? event.id : event.externalUID
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = rawValue.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let stem = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let needsStableSuffix = stem.isEmpty || stem != rawValue || stem.count > 96
        guard needsStableSuffix else { return "\(stem).ics" }

        let suffix = stableIdentifierComponent(for: rawValue)
        let fallbackStem = stem.isEmpty ? "event" : stem
        let prefixLength = max(1, 96 - suffix.count - 1)
        let prefix = String(fallbackStem.prefix(prefixLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\((prefix.isEmpty ? "event" : prefix))-\(suffix).ics"
    }

    private func redirectURL(from response: HTTPURLResponse, requestURL: URL) -> URL? {
        guard Self.redirectStatusCodes.contains(response.statusCode),
              let location = headerValue(named: "Location", in: response),
              let redirectURL = resolvedURL(from: location, relativeTo: response.url ?? requestURL),
              canFollowRedirect(from: requestURL, to: redirectURL)
        else {
            return nil
        }
        return redirectURL
    }

    private func headerValue(named headerName: String, in response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            guard String(describing: key).caseInsensitiveCompare(headerName) == .orderedSame else { continue }
            return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        }
        return nil
    }

    private func canFollowRedirect(from sourceURL: URL, to destinationURL: URL) -> Bool {
        let sourceScheme = sourceURL.scheme?.lowercased()
        let destinationScheme = destinationURL.scheme?.lowercased()
        guard destinationScheme == "http" || destinationScheme == "https" else { return false }
        if sourceScheme == "https", destinationScheme != "https" {
            return false
        }
        guard canFollowRedirectHost(from: sourceURL.host, to: destinationURL.host) else {
            return false
        }
        return port(for: sourceURL) == port(for: destinationURL)
            || (sourceScheme == "http" && destinationScheme == "https")
    }

    private func canFollowRedirectHost(from sourceHost: String?, to destinationHost: String?) -> Bool {
        let source = normalizedRedirectHost(sourceHost)
        let destination = normalizedRedirectHost(destinationHost)
        guard !source.isEmpty, !destination.isEmpty else { return false }
        if source == destination { return true }
        if destination.hasSuffix(".\(source)") { return true }
        if source.hasPrefix("www."), String(source.dropFirst(4)) == destination { return true }
        if destination.hasPrefix("www."), String(destination.dropFirst(4)) == source { return true }
        return false
    }

    private func normalizedRedirectHost(_ host: String?) -> String {
        let trimmed = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    }

    private func port(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private func resolvedURL(from href: String, relativeTo baseURL: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let absoluteURL = URL(string: trimmed), absoluteURL.scheme != nil {
            return absoluteURL
        }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }

    private func calendarHomeHrefs(from properties: [String: String]) -> [String] {
        let list = splitDAVHrefList(properties["calendar-home-set.hrefs"])
        if !list.isEmpty { return list }
        return splitDAVHrefList(properties["calendar-home-set.href"])
    }

    private func splitDAVHrefList(_ value: String?) -> [String] {
        (value ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var unique: [URL] = []
        for url in urls {
            let key = url.absoluteString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(url)
        }
        return unique
    }

    private func davHref(for url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.path
        }

        var href = components.percentEncodedPath
        if let query = components.percentEncodedQuery, !query.isEmpty {
            href += "?\(query)"
        }
        return href
    }

    private func sanitizedColor(_ rawValue: String?) -> String {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.hasPrefix("#"), trimmed.count >= 7 else { return "#3B82F6" }
        return String(trimmed.prefix(7))
    }

    private func calendarTimeZoneIdentifier(_ rawValue: String?) -> String {
        let lines = unfoldedICSLines(from: rawValue ?? "")
        let candidates = lines.compactMap { line -> String? in
            guard let property = icsProperty(from: line),
                  property.name == "X-LIC-LOCATION" || property.name == "TZID"
            else {
                return nil
            }
            return property.value
        }

        for candidate in candidates {
            if let identifier = normalizedTimeZoneIdentifier(candidate) {
                return identifier
            }
        }

        return ""
    }

    private func normalizedTimeZoneIdentifier(_ rawValue: String) -> String? {
        let trimmed = unescapeICSText(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if TimeZone(identifier: trimmed) != nil {
            return trimmed
        }

        let compact = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if TimeZone(identifier: compact) != nil {
            return compact
        }

        return TimeZone.knownTimeZoneIdentifiers.first {
            $0.caseInsensitiveCompare(compact) == .orderedSame
        }
    }

    private func escapeICSText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
    }

    private func stableIdentifierComponent(for value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    private func unfoldedICSLines(from text: String) -> [String] {
        var lines: [String] = []
        for rawLine in text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n") {
            if rawLine.hasPrefix(" ") || rawLine.hasPrefix("\t"), let previous = lines.popLast() {
                lines.append(previous + String(rawLine.dropFirst()))
            } else if !rawLine.isEmpty {
                lines.append(rawLine)
            }
        }
        return lines
    }

    private func icsProperty(from line: String) -> (name: String, params: [String: String], value: String)? {
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

        return (name, params, value)
    }

    private func propertyValueSeparator(in line: String) -> String.Index? {
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

    private func propertyTokens(from leftSide: String) -> [String] {
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

    private func normalizedParameterValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let unquoted: String
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            unquoted = String(trimmed.dropFirst().dropLast())
        } else {
            unquoted = trimmed
        }
        return unescapeICSText(unquoted)
    }

    private func icsEmailValue(from value: String) -> String {
        let text = unescapeICSText(value).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("mailto:") {
            return percentDecodedEmail(mailtoAddressComponent(String(text.dropFirst("mailto:".count))))
        }
        let decoded = percentDecodedEmail(text)
        return decoded.contains("@") ? decoded : ""
    }

    private func normalizedEmail(_ value: String?) -> String? {
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
        let email = percentDecodedEmail(mailtoAddressComponent(withoutScheme)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return email.contains("@") ? email : nil
    }

    private func uniqueEmails(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var emails: [String] = []
        for value in values {
            let email = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !email.isEmpty, seen.insert(email).inserted else { continue }
            emails.append(email)
        }
        return emails
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

    private func unescapeICSText(_ value: String) -> String {
        var output = ""
        var isEscaped = false

        for character in value {
            if isEscaped {
                switch character {
                case "n", "N":
                    output.append("\n")
                case "\\", ",", ";":
                    output.append(character)
                default:
                    output.append(character)
                }
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                output.append(character)
            }
        }

        if isEscaped {
            output.append("\\")
        }
        return output
    }

    private static let currentUserPrincipalBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:">
      <d:prop>
        <d:current-user-principal />
        <d:principal-URL />
      </d:prop>
    </d:propfind>
    """

    private static let calendarHomeSetBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:prop>
        <c:calendar-home-set />
      </d:prop>
    </d:propfind>
    """

    private static let calendarUserAddressSetBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:prop>
        <c:calendar-user-address-set />
      </d:prop>
    </d:propfind>
    """

    private static let scheduleOutboxURLBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:prop>
        <c:schedule-outbox-URL />
      </d:prop>
    </d:propfind>
    """

    private static let objectETagBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:">
      <d:prop>
        <d:getetag />
      </d:prop>
    </d:propfind>
    """

    private static let calendarPropertiesBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/" xmlns:ical="http://apple.com/ns/ical/">
      <d:prop>
        <d:resourcetype />
        <d:displayname />
        <cs:getctag />
        <d:sync-token />
        <ical:calendar-color />
        <c:calendar-timezone />
        <d:current-user-privilege-set />
        <c:supported-calendar-component-set />
        <c:supported-calendar-data />
      </d:prop>
    </d:propfind>
    """

    private static func calendarQueryBody(start: String, end: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop>
            <d:getetag />
            <c:calendar-data />
          </d:prop>
          <c:filter>
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT">
                <c:time-range start="\(start)" end="\(end)" />
              </c:comp-filter>
            </c:comp-filter>
          </c:filter>
        </c:calendar-query>
        """
    }

    private static func calendarMultigetBody(hrefs: [String]) -> String {
        let hrefLines = hrefs
            .map { "    <d:href>\(escapeXML($0))</d:href>" }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <c:calendar-multiget xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop>
            <d:getetag />
            <c:calendar-data />
          </d:prop>
        \(hrefLines)
        </c:calendar-multiget>
        """
    }

    private static func syncCollectionBody(syncToken: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <d:sync-collection xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:sync-token>\(escapeXML(syncToken))</d:sync-token>
          <d:sync-level>1</d:sync-level>
          <d:prop>
            <d:getetag />
            <c:calendar-data />
          </d:prop>
        </d:sync-collection>
        """
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static let calDAVDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}

private struct DAVResponse {
    var href = ""
    var properties: [String: String] = [:]
    var resourceTypes: Set<String> = []
    var privileges: Set<String> = []
    var calendarComponents: Set<String> = []
    var hasCalendarComponentSet = false
    var calendarDataFormats: Set<DAVCalendarDataFormat> = []
    var hasSupportedCalendarData = false
    var statusCode: Int?

    var allowsEventWrite: Bool {
        guard supportsEvents else { return false }
        guard !privileges.isEmpty else { return true }
        return !privileges.isDisjoint(with: ["all", "write", "write-content"])
    }

    var allowsResponses: Bool {
        guard supportsEvents else { return false }
        return allowsEventWrite || !privileges.isDisjoint(with: ["schedule-send", "schedule-send-reply"])
    }

    var supportsEvents: Bool {
        (!hasCalendarComponentSet || calendarComponents.contains("VEVENT")) && supportsCalendarData
    }

    private var supportsCalendarData: Bool {
        !hasSupportedCalendarData || calendarDataFormats.contains(where: \.supportsICalendar20)
    }
}

private struct DAVCalendarDataFormat: Hashable {
    let contentType: String?
    let version: String?

    var supportsICalendar20: Bool {
        let contentType = contentType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let version = version?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let contentTypeMatches = contentType == nil || contentType == "text/calendar"
        let versionMatches = version == nil || version == "2.0"
        return contentTypeMatches && versionMatches
    }
}

private struct DAVXMLResult {
    var responses: [DAVResponse]
    var syncToken: String?
}

private final class DAVXMLParser: NSObject, XMLParserDelegate {
    private var responses: [DAVResponse] = []
    private var currentResponse: DAVResponse?
    private var currentResponseHasDirectStatus = false
    private var currentPropstatProperties: [String: String]?
    private var currentPropstatResourceTypes: Set<String> = []
    private var currentPropstatPrivileges: Set<String> = []
    private var currentPropstatCalendarComponents: Set<String> = []
    private var currentPropstatHasCalendarComponentSet = false
    private var currentPropstatCalendarDataFormats: Set<DAVCalendarDataFormat> = []
    private var currentPropstatHasSupportedCalendarData = false
    private var currentPropstatStatusCode: Int?
    private var syncToken: String?
    private var elementStack: [String] = []
    private var textStack: [String] = []
    private var parseError: Error?

    static func parse(_ data: Data) throws -> DAVXMLResult {
        let delegate = DAVXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? delegate.parseError ?? CalDAVClientError.discoveryFailed
        }
        return DAVXMLResult(responses: delegate.responses, syncToken: delegate.syncToken)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = normalizedName(elementName)
        elementStack.append(name)
        textStack.append("")

        if name == "response" {
            currentResponse = DAVResponse()
            currentResponseHasDirectStatus = false
        } else if currentResponse != nil, name == "propstat" {
            currentPropstatProperties = [:]
            currentPropstatResourceTypes = []
            currentPropstatPrivileges = []
            currentPropstatCalendarComponents = []
            currentPropstatHasCalendarComponentSet = false
            currentPropstatCalendarDataFormats = []
            currentPropstatHasSupportedCalendarData = false
            currentPropstatStatusCode = nil
        } else if currentResponse != nil,
                  elementStack.contains("resourcetype"),
                  name != "resourcetype" {
            insertResourceType(name)
        } else if currentResponse != nil,
                  elementStack.contains("current-user-privilege-set"),
                  name != "current-user-privilege-set",
                  name != "privilege" {
            insertPrivilege(name.lowercased())
        } else if currentResponse != nil,
                  name == "supported-calendar-component-set" {
            markCalendarComponentSetSeen()
        } else if currentResponse != nil,
                  elementStack.contains("supported-calendar-component-set"),
                  name == "comp",
                  let componentName = attributeDict.first(where: { $0.key.caseInsensitiveCompare("name") == .orderedSame })?.value.nilIfBlank {
            insertCalendarComponent(componentName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
        } else if currentResponse != nil,
                  name == "supported-calendar-data" {
            markSupportedCalendarDataSeen()
        } else if currentResponse != nil,
                  elementStack.contains("supported-calendar-data"),
                  name == "calendar-data" {
            insertCalendarDataFormat(
                contentType: attributeDict.first(where: { $0.key.caseInsensitiveCompare("content-type") == .orderedSame })?.value.nilIfBlank,
                version: attributeDict.first(where: { $0.key.caseInsensitiveCompare("version") == .orderedSame })?.value.nilIfBlank
            )
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !textStack.isEmpty else { return }
        textStack[textStack.count - 1].append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = normalizedName(elementName)
        let text = (textStack.popLast() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if name == "response" {
            if let currentResponse {
                responses.append(currentResponse)
            }
            currentResponse = nil
            currentResponseHasDirectStatus = false
            resetPropstat()
            elementStack.removeLast()
            return
        }

        if name == "sync-token", currentResponse == nil {
            syncToken = text.nilIfBlank
            elementStack.removeLast()
            return
        }

        guard currentResponse != nil else {
            elementStack.removeLast()
            return
        }

        if name == "propstat" {
            applyCurrentPropstat()
            elementStack.removeLast()
            return
        }

        if name == "href" {
            if elementStack.contains("current-user-principal") {
                setProperty("current-user-principal.href", text)
            } else if elementStack.contains("principal-URL") {
                setProperty("principal-URL.href", text)
            } else if elementStack.contains("calendar-home-set") {
                setPropertyIfMissing("calendar-home-set.href", text)
                appendProperty("calendar-home-set.hrefs", text)
            } else if elementStack.contains("calendar-user-address-set") {
                appendProperty("calendar-user-address-set.hrefs", text)
            } else if elementStack.contains("schedule-outbox-URL") || elementStack.contains("schedule-outbox-url") {
                setProperty("schedule-outbox-URL.href", text)
            } else if elementStack.contains("response"), !elementStack.contains("prop") {
                currentResponse?.href = text
            }
        } else if elementStack.contains("prop") && Self.textProperties.contains(name) {
            setProperty(name, text)
        } else if name == "status", let statusCode = Self.statusCode(from: text) {
            if elementStack.contains("propstat") {
                currentPropstatStatusCode = statusCode
            } else {
                currentResponse?.statusCode = statusCode
                currentResponseHasDirectStatus = true
            }
        }

        elementStack.removeLast()
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }

    private var isInsidePropstat: Bool {
        currentPropstatProperties != nil && elementStack.contains("propstat")
    }

    private func setProperty(_ key: String, _ value: String) {
        if isInsidePropstat {
            currentPropstatProperties?[key] = value
        } else {
            currentResponse?.properties[key] = value
        }
    }

    private func setPropertyIfMissing(_ key: String, _ value: String) {
        if isInsidePropstat {
            if currentPropstatProperties?[key] == nil {
                currentPropstatProperties?[key] = value
            }
        } else if currentResponse?.properties[key] == nil {
            currentResponse?.properties[key] = value
        }
    }

    private func appendProperty(_ key: String, _ value: String) {
        if isInsidePropstat {
            let existing = currentPropstatProperties?[key] ?? ""
            currentPropstatProperties?[key] = existing.isEmpty ? value : "\(existing)\n\(value)"
        } else {
            let existing = currentResponse?.properties[key] ?? ""
            currentResponse?.properties[key] = existing.isEmpty ? value : "\(existing)\n\(value)"
        }
    }

    private func insertResourceType(_ value: String) {
        if isInsidePropstat {
            currentPropstatResourceTypes.insert(value)
        } else {
            currentResponse?.resourceTypes.insert(value)
        }
    }

    private func insertPrivilege(_ value: String) {
        if isInsidePropstat {
            currentPropstatPrivileges.insert(value)
        } else {
            currentResponse?.privileges.insert(value)
        }
    }

    private func insertCalendarComponent(_ value: String) {
        if isInsidePropstat {
            currentPropstatCalendarComponents.insert(value)
        } else {
            currentResponse?.calendarComponents.insert(value)
        }
    }

    private func markCalendarComponentSetSeen() {
        if isInsidePropstat {
            currentPropstatHasCalendarComponentSet = true
        } else {
            currentResponse?.hasCalendarComponentSet = true
        }
    }

    private func markSupportedCalendarDataSeen() {
        if isInsidePropstat {
            currentPropstatHasSupportedCalendarData = true
        } else {
            currentResponse?.hasSupportedCalendarData = true
        }
    }

    private func insertCalendarDataFormat(contentType: String?, version: String?) {
        let format = DAVCalendarDataFormat(contentType: contentType, version: version)
        if isInsidePropstat {
            currentPropstatCalendarDataFormats.insert(format)
        } else {
            currentResponse?.calendarDataFormats.insert(format)
        }
    }

    private func applyCurrentPropstat() {
        defer { resetPropstat() }
        guard currentResponse != nil else { return }

        let statusCode = currentPropstatStatusCode
        let isSuccess = statusCode.map { (200...299).contains($0) } ?? true
        if isSuccess {
            currentResponse?.properties.merge(currentPropstatProperties ?? [:]) { _, new in new }
            currentResponse?.resourceTypes.formUnion(currentPropstatResourceTypes)
            currentResponse?.privileges.formUnion(currentPropstatPrivileges)
            currentResponse?.calendarComponents.formUnion(currentPropstatCalendarComponents)
            if currentPropstatHasCalendarComponentSet {
                currentResponse?.hasCalendarComponentSet = true
            }
            currentResponse?.calendarDataFormats.formUnion(currentPropstatCalendarDataFormats)
            if currentPropstatHasSupportedCalendarData {
                currentResponse?.hasSupportedCalendarData = true
            }
        }

        guard !currentResponseHasDirectStatus, let statusCode else { return }
        let currentStatusIsSuccess = currentResponse?.statusCode.map { (200...299).contains($0) } ?? false
        if isSuccess || currentResponse?.statusCode == nil || !currentStatusIsSuccess {
            currentResponse?.statusCode = statusCode
        }
    }

    private func resetPropstat() {
        currentPropstatProperties = nil
        currentPropstatResourceTypes = []
        currentPropstatPrivileges = []
        currentPropstatCalendarComponents = []
        currentPropstatHasCalendarComponentSet = false
        currentPropstatCalendarDataFormats = []
        currentPropstatHasSupportedCalendarData = false
        currentPropstatStatusCode = nil
    }

    private func normalizedName(_ name: String) -> String {
        if let colonIndex = name.lastIndex(of: ":") {
            return String(name[name.index(after: colonIndex)...])
        }
        return name
    }

    private static func statusCode(from value: String) -> Int? {
        value
            .split(separator: " ")
            .lazy
            .compactMap { Int($0) }
            .first
    }

    private static let textProperties: Set<String> = [
        "displayname",
        "calendar-color",
        "calendar-timezone",
        "getctag",
        "sync-token",
        "calendar-data",
        "getetag"
    ]
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension HTTPURLResponse {
    var eTagHeader: String {
        for (key, value) in allHeaderFields {
            guard String(describing: key).caseInsensitiveCompare("ETag") == .orderedSame else { continue }
            return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
}

enum CalDAVAuthenticationDisposition: Hashable {
    case useCredential
    case rejectProtectionSpace
    case performDefaultHandling
}

struct CalDAVAuthenticationPolicy {
    static func disposition(authenticationMethod: String, previousFailureCount: Int) -> CalDAVAuthenticationDisposition {
        guard previousFailureCount == 0 else {
            return .rejectProtectionSpace
        }

        switch authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodDefault:
            return .useCredential
        default:
            return .performDefaultHandling
        }
    }
}

private final class CalDAVRequestDelegate: NSObject, URLSessionTaskDelegate {
    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch CalDAVAuthenticationPolicy.disposition(
            authenticationMethod: challenge.protectionSpace.authenticationMethod,
            previousFailureCount: challenge.previousFailureCount
        ) {
        case .useCredential:
            completionHandler(
                .useCredential,
                URLCredential(user: username, password: password, persistence: .forSession)
            )
        case .rejectProtectionSpace:
            completionHandler(.rejectProtectionSpace, nil)
        case .performDefaultHandling:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

private extension LocalCalendarEvent {
    func withRemoteObjectURL(_ urlString: String) -> LocalCalendarEvent {
        var copy = self
        copy.remoteObjectURLString = urlString
        return copy
    }
}
