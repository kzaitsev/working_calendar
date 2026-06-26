import Combine
import Foundation
import Security

enum CalendarProviderKind: String, Codable, CaseIterable, Hashable, Identifiable {
    case local
    case icsSubscription
    case calDAV
    case googleCalendar
    case microsoft365

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "Local"
        case .icsSubscription: return "ICS subscription"
        case .calDAV: return "CalDAV"
        case .googleCalendar: return "Google Calendar"
        case .microsoft365: return "Microsoft 365"
        }
    }

    var symbolName: String {
        switch self {
        case .local: return "tray.full"
        case .icsSubscription: return "link"
        case .calDAV: return "server.rack"
        case .googleCalendar: return "g.circle"
        case .microsoft365: return "m.circle"
        }
    }

    var supportsWriteBack: Bool {
        switch self {
        case .local, .calDAV, .googleCalendar, .microsoft365:
            return true
        case .icsSubscription:
            return false
        }
    }

    var supportsResponses: Bool {
        switch self {
        case .local, .calDAV, .googleCalendar, .microsoft365:
            return true
        case .icsSubscription:
            return false
        }
    }

    var capabilityText: String {
        switch self {
        case .local:
            return "Local read-write"
        case .icsSubscription:
            return "Read-only subscription"
        case .calDAV:
            return "Two-way CalDAV"
        case .googleCalendar:
            return "Two-way Google"
        case .microsoft365:
            return "Two-way Microsoft"
        }
    }
}

struct CalendarProviderAccount: Identifiable, Codable, Hashable {
    var id: String
    var kind: CalendarProviderKind
    var title: String
    var endpointURLString: String
    var username: String?
    var identityEmail: String?
    var identityEmailAliases: [String]
    var credentialKey: String?
    var enabled: Bool
    var importedEventCount: Int
    var updatedEventCount: Int
    var skippedEventCount: Int
    var deletedEventCount: Int
    var httpETag: String?
    var httpLastModified: String?
    var icsRefreshIntervalSeconds: Int?
    var calDAVSyncStates: [CalDAVCalendarSyncState]
    var googleCalendarSyncStates: [GoogleCalendarSyncState]
    var microsoftGraphSyncStates: [MicrosoftGraphSyncState]
    var lastSyncAt: Date?
    var lastSyncStartedAt: Date?
    var lastSyncDurationSeconds: Double?
    var lastSyncFailedAt: Date?
    var syncNotBefore: Date?
    var lastError: String?
    var createdAt: Date
    var updatedAt: Date

    var endpointURL: URL? {
        URL(string: endpointURLString)
    }

    var syncSummaryText: String {
        var parts: [String] = []
        if importedEventCount > 0 { parts.append("\(importedEventCount) imported") }
        if updatedEventCount > 0 { parts.append("\(updatedEventCount) updated") }
        if skippedEventCount > 0 { parts.append("\(skippedEventCount) skipped") }
        if deletedEventCount > 0 { parts.append("\(deletedEventCount) removed") }
        return parts.isEmpty ? "No events synced yet" : parts.joined(separator: " · ")
    }

    var capabilityText: String {
        kind.capabilityText
    }

    func isAutomaticSyncDue(at date: Date) -> Bool {
        automaticSyncReadyDate() <= date
    }

    func automaticSyncReadyDate(globalNotBefore: Date? = nil) -> Date {
        var readyAt = globalNotBefore ?? .distantPast

        if let syncNotBefore, syncNotBefore > readyAt {
            readyAt = syncNotBefore
        }

        if kind == .icsSubscription,
           let refreshInterval = icsRefreshIntervalSeconds,
           refreshInterval > 0,
           let lastSyncAt {
            let subscriptionReadyAt = lastSyncAt.addingTimeInterval(TimeInterval(refreshInterval))
            if subscriptionReadyAt > readyAt {
                readyAt = subscriptionReadyAt
            }
        }

        return readyAt
    }

    init(
        id: String,
        kind: CalendarProviderKind,
        title: String,
        endpointURLString: String,
        username: String?,
        identityEmail: String? = nil,
        identityEmailAliases: [String] = [],
        credentialKey: String?,
        enabled: Bool,
        importedEventCount: Int,
        updatedEventCount: Int,
        skippedEventCount: Int,
        deletedEventCount: Int = 0,
        httpETag: String? = nil,
        httpLastModified: String? = nil,
        icsRefreshIntervalSeconds: Int? = nil,
        calDAVSyncStates: [CalDAVCalendarSyncState] = [],
        googleCalendarSyncStates: [GoogleCalendarSyncState] = [],
        microsoftGraphSyncStates: [MicrosoftGraphSyncState] = [],
        lastSyncAt: Date?,
        lastSyncStartedAt: Date? = nil,
        lastSyncDurationSeconds: Double? = nil,
        lastSyncFailedAt: Date? = nil,
        syncNotBefore: Date? = nil,
        lastError: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.endpointURLString = endpointURLString
        self.username = username
        let normalizedIdentityEmail = Self.normalizedIdentityEmail(identityEmail)
        self.identityEmail = normalizedIdentityEmail
        self.identityEmailAliases = Self.normalizedIdentityEmailAliases(
            identityEmailAliases,
            excluding: normalizedIdentityEmail
        )
        self.credentialKey = credentialKey
        self.enabled = enabled
        self.importedEventCount = importedEventCount
        self.updatedEventCount = updatedEventCount
        self.skippedEventCount = skippedEventCount
        self.deletedEventCount = deletedEventCount
        self.httpETag = httpETag
        self.httpLastModified = httpLastModified
        self.icsRefreshIntervalSeconds = icsRefreshIntervalSeconds
        self.calDAVSyncStates = calDAVSyncStates
        self.googleCalendarSyncStates = googleCalendarSyncStates
        self.microsoftGraphSyncStates = microsoftGraphSyncStates
        self.lastSyncAt = lastSyncAt
        self.lastSyncStartedAt = lastSyncStartedAt
        self.lastSyncDurationSeconds = lastSyncDurationSeconds.map { max(0, $0) }
        self.lastSyncFailedAt = lastSyncFailedAt
        self.syncNotBefore = syncNotBefore
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(CalendarProviderKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        endpointURLString = try container.decode(String.self, forKey: .endpointURLString)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        identityEmail = Self.normalizedIdentityEmail(try container.decodeIfPresent(String.self, forKey: .identityEmail))
        identityEmailAliases = Self.normalizedIdentityEmailAliases(
            try container.decodeIfPresent([String].self, forKey: .identityEmailAliases) ?? [],
            excluding: identityEmail
        )
        credentialKey = try container.decodeIfPresent(String.self, forKey: .credentialKey)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        importedEventCount = try container.decode(Int.self, forKey: .importedEventCount)
        updatedEventCount = try container.decode(Int.self, forKey: .updatedEventCount)
        skippedEventCount = try container.decode(Int.self, forKey: .skippedEventCount)
        deletedEventCount = try container.decodeIfPresent(Int.self, forKey: .deletedEventCount) ?? 0
        httpETag = try container.decodeIfPresent(String.self, forKey: .httpETag)
        httpLastModified = try container.decodeIfPresent(String.self, forKey: .httpLastModified)
        icsRefreshIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .icsRefreshIntervalSeconds)
        calDAVSyncStates = try container.decodeIfPresent([CalDAVCalendarSyncState].self, forKey: .calDAVSyncStates) ?? []
        googleCalendarSyncStates = try container.decodeIfPresent([GoogleCalendarSyncState].self, forKey: .googleCalendarSyncStates) ?? []
        microsoftGraphSyncStates = try container.decodeIfPresent([MicrosoftGraphSyncState].self, forKey: .microsoftGraphSyncStates) ?? []
        lastSyncAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        lastSyncStartedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncStartedAt)
        lastSyncDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .lastSyncDurationSeconds).map { max(0, $0) }
        lastSyncFailedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncFailedAt)
        syncNotBefore = try container.decodeIfPresent(Date.self, forKey: .syncNotBefore)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    static func normalizedIdentityEmails(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var emails: [String] = []
        for value in values {
            guard let email = normalizedIdentityEmail(value),
                  seen.insert(email).inserted
            else {
                continue
            }
            emails.append(email)
        }
        return emails
    }

    private static func normalizedIdentityEmailAliases(_ values: [String], excluding primaryEmail: String?) -> [String] {
        let primaryKey = primaryEmail?.lowercased()
        return normalizedIdentityEmails(values).filter { $0.lowercased() != primaryKey }
    }

    static func normalizedIdentityEmail(_ value: String?) -> String? {
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
        let address = mailtoAddressComponent(withoutScheme)
        let decoded = address.trimmingCharacters(in: .whitespacesAndNewlines).removingPercentEncoding ?? address
        let email = decoded.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return email.contains("@") ? email : nil
    }

    private static func mailtoAddressComponent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryIndex = trimmed.firstIndex { $0 == "?" || $0 == "#" } ?? trimmed.endIndex
        return String(trimmed[..<queryIndex])
    }
}

struct CalDAVCalendarSyncState: Codable, Hashable {
    var calendarHrefString: String
    var syncToken: String
    var cTag: String
}

struct GoogleCalendarSyncState: Codable, Hashable {
    var googleCalendarID: String
    var syncToken: String
    var windowStartDate: Date?
    var windowEndDate: Date?

    init(
        googleCalendarID: String,
        syncToken: String,
        windowStartDate: Date? = nil,
        windowEndDate: Date? = nil
    ) {
        self.googleCalendarID = googleCalendarID
        self.syncToken = syncToken
        self.windowStartDate = windowStartDate
        self.windowEndDate = windowEndDate
    }

    func coversWindow(startDate: Date, endDate: Date) -> Bool {
        guard let windowStartDate,
              let windowEndDate,
              !syncToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        return windowStartDate <= startDate && windowEndDate >= endDate
    }
}

struct MicrosoftGraphSyncState: Codable, Hashable {
    var graphCalendarID: String
    var deltaLink: String
    var windowStartDate: Date?
    var windowEndDate: Date?

    init(
        graphCalendarID: String,
        deltaLink: String,
        windowStartDate: Date? = nil,
        windowEndDate: Date? = nil
    ) {
        self.graphCalendarID = graphCalendarID
        self.deltaLink = deltaLink
        self.windowStartDate = windowStartDate
        self.windowEndDate = windowEndDate
    }

    func coversWindow(startDate: Date, endDate: Date) -> Bool {
        guard let windowStartDate,
              let windowEndDate,
              !deltaLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        return windowStartDate <= startDate && windowEndDate >= endDate
    }
}

enum ProviderOutboxOperation: String, Codable, Hashable {
    case write
    case delete
    case move
    case response

    var title: String {
        switch self {
        case .write: return "save"
        case .delete: return "delete"
        case .move: return "move"
        case .response: return "response"
        }
    }
}

enum ProviderOutboxFailureKind: String, Codable, Hashable {
    case retryable
    case conflict
    case blocked
}

enum ProviderOutboxRecoveryAction: String, Hashable {
    case queued
    case automaticRetry
    case retryNow
    case syncThenRetry
    case editOrFixAccess

    var title: String {
        switch self {
        case .queued:
            return "Will sync automatically"
        case .automaticRetry:
            return "Waiting for provider retry"
        case .retryNow:
            return "Ready to retry"
        case .syncThenRetry:
            return "Sync source, then retry"
        case .editOrFixAccess:
            return "Edit event or fix access"
        }
    }

    var helpText: String {
        switch self {
        case .queued:
            return "Working Calendar will send this local change through its provider outbox."
        case .automaticRetry:
            return "The provider update failed temporarily and will retry after its cooldown."
        case .retryNow:
            return "This failed update can be retried now."
        case .syncThenRetry:
            return "The remote event changed. Sync the source first so the retry uses the fresh provider version."
        case .editOrFixAccess:
            return "The provider rejected this update. Edit the event, reconnect the source, or check provider permissions before retrying."
        }
    }
}

struct ProviderOutboxItem: Identifiable, Codable, Hashable {
    var id: UUID
    var operation: ProviderOutboxOperation
    var eventID: String
    var accountIDs: [String]
    var event: LocalCalendarEvent
    var previousEvent: LocalCalendarEvent?
    var response: CalendarEventResponse?
    var responseScope: CalendarEventResponseScope?
    var responseOccurrenceStartDate: Date?
    var responseOccurrenceIsAllDay: Bool?
    var hadLocalProviderRecurrenceChanges: Bool?
    var createdAt: Date
    var updatedAt: Date
    var attemptCount: Int
    var lastAttemptAt: Date?
    var lastError: String?
    var failureKind: ProviderOutboxFailureKind?
    var nextRetryAt: Date?
    var dedupeKey: String

    private enum CodingKeys: String, CodingKey {
        case id
        case operation
        case eventID
        case accountIDs
        case event
        case previousEvent
        case response
        case responseScope
        case responseOccurrenceStartDate
        case responseOccurrenceIsAllDay
        case hadLocalProviderRecurrenceChanges
        case createdAt
        case updatedAt
        case attemptCount
        case lastAttemptAt
        case lastError
        case failureKind
        case nextRetryAt
        case dedupeKey
    }

    init(
        id: UUID,
        operation: ProviderOutboxOperation,
        eventID: String,
        accountIDs: [String],
        event: LocalCalendarEvent,
        previousEvent: LocalCalendarEvent?,
        response: CalendarEventResponse?,
        responseScope: CalendarEventResponseScope?,
        responseOccurrenceStartDate: Date?,
        responseOccurrenceIsAllDay: Bool?,
        hadLocalProviderRecurrenceChanges: Bool?,
        createdAt: Date,
        updatedAt: Date,
        attemptCount: Int,
        lastAttemptAt: Date?,
        lastError: String?,
        failureKind: ProviderOutboxFailureKind? = nil,
        nextRetryAt: Date?,
        dedupeKey: String
    ) {
        self.id = id
        self.operation = operation
        self.eventID = eventID
        self.accountIDs = accountIDs
        self.event = event
        self.previousEvent = previousEvent
        self.response = response
        self.responseScope = responseScope
        self.responseOccurrenceStartDate = responseOccurrenceStartDate
        self.responseOccurrenceIsAllDay = responseOccurrenceIsAllDay
        self.hadLocalProviderRecurrenceChanges = hadLocalProviderRecurrenceChanges
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.attemptCount = max(0, attemptCount)
        self.lastAttemptAt = lastAttemptAt
        let normalizedLastError = lastError?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lastError = normalizedLastError?.isEmpty == true ? nil : normalizedLastError
        self.failureKind = failureKind ?? (self.lastError == nil ? nil : .retryable)
        self.nextRetryAt = nextRetryAt
        self.dedupeKey = dedupeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.dedupeKey(
                operation: operation,
                event: event,
                previousEvent: previousEvent,
                response: response,
                responseScope: responseScope,
                occurrenceStartDate: responseOccurrenceStartDate
            )
            : dedupeKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let event = try container.decode(LocalCalendarEvent.self, forKey: .event)
        let operation = try container.decodeIfPresent(ProviderOutboxOperation.self, forKey: .operation) ?? .write
        let previousEvent = try container.decodeIfPresent(LocalCalendarEvent.self, forKey: .previousEvent)
        let response = try container.decodeIfPresent(CalendarEventResponse.self, forKey: .response)
        let responseScope = try container.decodeIfPresent(CalendarEventResponseScope.self, forKey: .responseScope)
        let responseOccurrenceStartDate = try container.decodeIfPresent(Date.self, forKey: .responseOccurrenceStartDate)
        let createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()

        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            operation: operation,
            eventID: try container.decodeIfPresent(String.self, forKey: .eventID) ?? event.id,
            accountIDs: try container.decodeIfPresent([String].self, forKey: .accountIDs) ?? [],
            event: event,
            previousEvent: previousEvent,
            response: response,
            responseScope: responseScope,
            responseOccurrenceStartDate: responseOccurrenceStartDate,
            responseOccurrenceIsAllDay: try container.decodeIfPresent(Bool.self, forKey: .responseOccurrenceIsAllDay),
            hadLocalProviderRecurrenceChanges: try container.decodeIfPresent(Bool.self, forKey: .hadLocalProviderRecurrenceChanges),
            createdAt: createdAt,
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt,
            attemptCount: try container.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0,
            lastAttemptAt: try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt),
            lastError: try container.decodeIfPresent(String.self, forKey: .lastError),
            failureKind: try container.decodeIfPresent(ProviderOutboxFailureKind.self, forKey: .failureKind),
            nextRetryAt: try container.decodeIfPresent(Date.self, forKey: .nextRetryAt),
            dedupeKey: try container.decodeIfPresent(String.self, forKey: .dedupeKey)
                ?? Self.dedupeKey(
                    operation: operation,
                    event: event,
                    previousEvent: previousEvent,
                    response: response,
                    responseScope: responseScope,
                    occurrenceStartDate: responseOccurrenceStartDate
                )
        )
    }

    var eventTitle: String {
        event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled event" : event.title
    }

    var isBlockedByConflict: Bool {
        failureKind == .conflict
    }

    var isBlockedByProviderRejection: Bool {
        failureKind == .blocked
    }

    var isBlockedFromAutomaticRetry: Bool {
        isBlockedByConflict || isBlockedByProviderRejection
    }

    var recoveryAction: ProviderOutboxRecoveryAction {
        if failureKind == .conflict {
            return .syncThenRetry
        }
        if failureKind == .blocked {
            return .editOrFixAccess
        }
        if nextRetryAt != nil {
            return .automaticRetry
        }
        if attemptCount > 0 {
            return .retryNow
        }
        return .queued
    }

    var recoverySummaryText: String {
        recoveryAction.title
    }

    var recoveryHelpText: String {
        recoveryAction.helpText
    }

    var statusText: String {
        if failureKind == .conflict {
            return "\(operation.title.capitalized) blocked by remote conflict"
        }
        if failureKind == .blocked {
            return "\(operation.title.capitalized) blocked by provider"
        }
        if let lastError = lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !lastError.isEmpty {
            return "\(operation.title.capitalized) failed: \(lastError)"
        }
        if attemptCount > 0 {
            return "\(operation.title.capitalized) queued for retry"
        }
        return "\(operation.title.capitalized) queued"
    }

    func writePayload(usingCurrentEvent currentEvent: LocalCalendarEvent) -> LocalCalendarEvent {
        var payload = event
        payload.calendarID = currentEvent.calendarID
        payload.remoteObjectURLString = currentEvent.remoteObjectURLString
        payload.remoteETag = currentEvent.remoteETag
        return payload
    }

    private static func dedupeKey(
        operation: ProviderOutboxOperation,
        event: LocalCalendarEvent,
        previousEvent: LocalCalendarEvent?,
        response: CalendarEventResponse?,
        responseScope: CalendarEventResponseScope?,
        occurrenceStartDate: Date?
    ) -> String {
        switch operation {
        case .write:
            return "write:\(event.id)"
        case .delete:
            let remoteObjectURL = event.remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            return "delete:\(event.id):\(remoteObjectURL)"
        case .move:
            return "move:\(event.id)"
        case .response:
            let occurrenceKey = occurrenceStartDate.map { String(Int($0.timeIntervalSinceReferenceDate)) } ?? "series"
            return "response:\(event.id):\(responseScope?.rawValue ?? "thisEvent"):\(occurrenceKey)"
        }
    }

    static func write(event: LocalCalendarEvent, accountID: String, now: Date = Date()) -> ProviderOutboxItem {
        ProviderOutboxItem(
            id: UUID(),
            operation: .write,
            eventID: event.id,
            accountIDs: [accountID],
            event: event,
            previousEvent: nil,
            response: nil,
            responseScope: nil,
            responseOccurrenceStartDate: nil,
            responseOccurrenceIsAllDay: nil,
            hadLocalProviderRecurrenceChanges: nil,
            createdAt: now,
            updatedAt: now,
            attemptCount: 0,
            lastAttemptAt: nil,
            lastError: nil,
            nextRetryAt: nil,
            dedupeKey: "write:\(event.id)"
        )
    }

    static func delete(event: LocalCalendarEvent, accountID: String, now: Date = Date()) -> ProviderOutboxItem {
        let remoteObjectURL = event.remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderOutboxItem(
            id: UUID(),
            operation: .delete,
            eventID: event.id,
            accountIDs: [accountID],
            event: event,
            previousEvent: nil,
            response: nil,
            responseScope: nil,
            responseOccurrenceStartDate: nil,
            responseOccurrenceIsAllDay: nil,
            hadLocalProviderRecurrenceChanges: nil,
            createdAt: now,
            updatedAt: now,
            attemptCount: 0,
            lastAttemptAt: nil,
            lastError: nil,
            nextRetryAt: nil,
            dedupeKey: "delete:\(event.id):\(remoteObjectURL)"
        )
    }

    static func move(
        previousEvent: LocalCalendarEvent,
        event: LocalCalendarEvent,
        accountIDs: [String],
        now: Date = Date()
    ) -> ProviderOutboxItem {
        ProviderOutboxItem(
            id: UUID(),
            operation: .move,
            eventID: event.id,
            accountIDs: Array(Set(accountIDs)).sorted(),
            event: event,
            previousEvent: previousEvent,
            response: nil,
            responseScope: nil,
            responseOccurrenceStartDate: nil,
            responseOccurrenceIsAllDay: nil,
            hadLocalProviderRecurrenceChanges: nil,
            createdAt: now,
            updatedAt: now,
            attemptCount: 0,
            lastAttemptAt: nil,
            lastError: nil,
            nextRetryAt: nil,
            dedupeKey: "move:\(event.id)"
        )
    }

    static func response(
        event: LocalCalendarEvent,
        accountID: String,
        response: CalendarEventResponse,
        scope: CalendarEventResponseScope,
        occurrenceStartDate: Date?,
        occurrenceIsAllDay: Bool,
        hadLocalProviderRecurrenceChanges: Bool,
        now: Date = Date()
    ) -> ProviderOutboxItem {
        let occurrenceKey = occurrenceStartDate.map { String(Int($0.timeIntervalSinceReferenceDate)) } ?? "series"
        return ProviderOutboxItem(
            id: UUID(),
            operation: .response,
            eventID: event.id,
            accountIDs: [accountID],
            event: event,
            previousEvent: nil,
            response: response,
            responseScope: scope,
            responseOccurrenceStartDate: occurrenceStartDate,
            responseOccurrenceIsAllDay: occurrenceIsAllDay,
            hadLocalProviderRecurrenceChanges: hadLocalProviderRecurrenceChanges,
            createdAt: now,
            updatedAt: now,
            attemptCount: 0,
            lastAttemptAt: nil,
            lastError: nil,
            nextRetryAt: nil,
            dedupeKey: "response:\(event.id):\(scope.rawValue):\(occurrenceKey)"
        )
    }
}

private struct LossyProviderOutbox: Decodable {
    var items: [ProviderOutboxItem]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decodedItems: [ProviderOutboxItem] = []

        while !container.isAtEnd {
            do {
                decodedItems.append(try container.decode(ProviderOutboxItem.self))
            } catch {
                _ = try? container.decode(DiscardedProviderOutboxItem.self)
            }
        }

        items = decodedItems
    }
}

private struct DiscardedProviderOutboxItem: Decodable {}

enum CalendarProviderStoreError: LocalizedError {
    case emptyURL
    case unsupportedURLScheme
    case invalidURL
    case emptyUsername
    case emptyPassword
    case keychainSaveFailed
    case unsupportedSourceKind

    var errorDescription: String? {
        switch self {
        case .emptyURL:
            return "Enter a calendar URL."
        case .unsupportedURLScheme:
            return "Use an http, https, webcal, webcals, caldav, or caldavs calendar URL."
        case .invalidURL:
            return "This calendar URL does not look valid."
        case .emptyUsername:
            return "Enter the account username."
        case .emptyPassword:
            return "Enter an app password or account password."
        case .keychainSaveFailed:
            return "Could not save the calendar credential in Keychain."
        case .unsupportedSourceKind:
            return "This source type cannot be edited here."
        }
    }
}

protocol CalendarCredentialStoring {
    func savePassword(_ password: String, key: String) -> Bool
    func deletePassword(key: String)
}

struct KeychainCalendarCredentialStore: CalendarCredentialStoring {
    func savePassword(_ password: String, key: String) -> Bool {
        CalendarCredentialStore.savePassword(password, key: key)
    }

    func deletePassword(key: String) {
        CalendarCredentialStore.deletePassword(key: key)
    }
}

protocol CalendarProviderDefaultsStoring: AnyObject {
    func data(forKey defaultName: String) -> Data?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: CalendarProviderDefaultsStoring {}

@MainActor
final class CalendarProviderStore: ObservableObject {
    static let appDefaultsSuiteName = "dev.codex.WorkingCalendar"

    @Published private(set) var accounts: [CalendarProviderAccount] = [] {
        didSet { save() }
    }

    @Published private(set) var providerOutbox: [ProviderOutboxItem] = [] {
        didSet { saveProviderOutbox() }
    }

    private let storageKey = "calendarProviderAccounts"
    private let outboxStorageKey = "calendarProviderOutbox"
    private let credentialStore: CalendarCredentialStoring
    private let userDefaults: CalendarProviderDefaultsStoring

    init(
        credentialStore: CalendarCredentialStoring = KeychainCalendarCredentialStore(),
        userDefaults: CalendarProviderDefaultsStoring = UserDefaults.standard
    ) {
        self.credentialStore = credentialStore
        self.userDefaults = userDefaults
        load()
        loadProviderOutbox()
    }

    var enabledICSSubscriptions: [CalendarProviderAccount] {
        accounts.filter { $0.enabled && $0.kind == .icsSubscription }
    }

    var enabledSyncAccounts: [CalendarProviderAccount] {
        accounts.filter {
            $0.enabled
                && ($0.kind == .icsSubscription || $0.kind == .calDAV || $0.kind == .googleCalendar || $0.kind == .microsoft365)
        }
    }

    @discardableResult
    func addICSSubscription(title: String, urlString: String) throws -> CalendarProviderAccount {
        let url = try normalizedSubscriptionURL(from: urlString)
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = url.host?.replacingOccurrences(of: "www.", with: "") ?? "Calendar Subscription"
        let now = Date()
        let identityKey = subscriptionIdentityKey(for: url)
        if let existingIndex = accounts.firstIndex(where: {
            $0.kind == .icsSubscription
                && subscriptionIdentityKey(for: $0.endpointURL) == identityKey
        }) {
            if !normalizedTitle.isEmpty {
                accounts[existingIndex].title = normalizedTitle
            }
            accounts[existingIndex].endpointURLString = url.absoluteString
            accounts[existingIndex].enabled = true
            accounts[existingIndex].updatedAt = now
            return accounts[existingIndex]
        }

        let account = CalendarProviderAccount(
            id: "provider-ics-\(UUID().uuidString)",
            kind: .icsSubscription,
            title: normalizedTitle.isEmpty ? fallbackTitle : normalizedTitle,
            endpointURLString: url.absoluteString,
            username: nil,
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: now,
            updatedAt: now
        )
        accounts.append(account)
        return account
    }

    @discardableResult
    func addCalDAVAccount(title: String, urlString: String, username: String, password: String) throws -> CalendarProviderAccount {
        let url = try normalizedHTTPURL(from: urlString)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUsername.isEmpty else { throw CalendarProviderStoreError.emptyUsername }
        guard !password.isEmpty else { throw CalendarProviderStoreError.emptyPassword }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = url.host?.replacingOccurrences(of: "www.", with: "") ?? "CalDAV Account"
        let now = Date()
        let identityKey = calDAVAccountIdentityKey(for: url, username: normalizedUsername)
        if let existingIndex = accounts.firstIndex(where: {
            $0.kind == .calDAV
                && calDAVAccountIdentityKey(for: $0.endpointURL, username: $0.username) == identityKey
        }) {
            let credentialKey = accounts[existingIndex].credentialKey ?? "\(accounts[existingIndex].id)-password"
            guard credentialStore.savePassword(password, key: credentialKey) else {
                throw CalendarProviderStoreError.keychainSaveFailed
            }

            if !normalizedTitle.isEmpty {
                accounts[existingIndex].title = normalizedTitle
            }
            accounts[existingIndex].endpointURLString = url.absoluteString
            accounts[existingIndex].username = normalizedUsername
            accounts[existingIndex].credentialKey = credentialKey
            accounts[existingIndex].enabled = true
            accounts[existingIndex].syncNotBefore = nil
            accounts[existingIndex].lastError = nil
            accounts[existingIndex].updatedAt = now
            return accounts[existingIndex]
        }

        let accountID = "provider-caldav-\(UUID().uuidString)"
        let credentialKey = "\(accountID)-password"

        guard credentialStore.savePassword(password, key: credentialKey) else {
            throw CalendarProviderStoreError.keychainSaveFailed
        }

        let account = CalendarProviderAccount(
            id: accountID,
            kind: .calDAV,
            title: normalizedTitle.isEmpty ? fallbackTitle : normalizedTitle,
            endpointURLString: url.absoluteString,
            username: normalizedUsername,
            credentialKey: credentialKey,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: now,
            updatedAt: now
        )
        accounts.append(account)
        return account
    }

    @discardableResult
    func addGoogleCalendarAccount(title: String, accessToken: String) throws -> CalendarProviderAccount {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw CalendarProviderStoreError.emptyPassword }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let accountID = "provider-google-\(UUID().uuidString)"
        let credentialKey = "\(accountID)-access-token"

        guard credentialStore.savePassword(token, key: credentialKey) else {
            throw CalendarProviderStoreError.keychainSaveFailed
        }

        let account = CalendarProviderAccount(
            id: accountID,
            kind: .googleCalendar,
            title: normalizedTitle.isEmpty ? "Google Calendar" : normalizedTitle,
            endpointURLString: "https://www.googleapis.com/calendar/v3",
            username: nil,
            credentialKey: credentialKey,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: now,
            updatedAt: now
        )
        accounts.append(account)
        return account
    }

    @discardableResult
    func addGoogleCalendarAccount(title: String, credential: OAuthCredential) throws -> CalendarProviderAccount {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let accountID = "provider-google-\(UUID().uuidString)"
        let credentialKey = "\(accountID)-oauth"

        guard OAuthCredentialStore.saveCredential(credential, key: credentialKey) else {
            throw CalendarProviderStoreError.keychainSaveFailed
        }

        let account = CalendarProviderAccount(
            id: accountID,
            kind: .googleCalendar,
            title: normalizedTitle.isEmpty ? "Google Calendar" : normalizedTitle,
            endpointURLString: "https://www.googleapis.com/calendar/v3",
            username: nil,
            credentialKey: credentialKey,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: now,
            updatedAt: now
        )
        accounts.append(account)
        return account
    }

    @discardableResult
    func addMicrosoft365Account(title: String, accessToken: String) throws -> CalendarProviderAccount {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw CalendarProviderStoreError.emptyPassword }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let accountID = "provider-microsoft365-\(UUID().uuidString)"
        let credentialKey = "\(accountID)-access-token"

        guard credentialStore.savePassword(token, key: credentialKey) else {
            throw CalendarProviderStoreError.keychainSaveFailed
        }

        let account = CalendarProviderAccount(
            id: accountID,
            kind: .microsoft365,
            title: normalizedTitle.isEmpty ? "Microsoft 365" : normalizedTitle,
            endpointURLString: "https://graph.microsoft.com/v1.0",
            username: nil,
            credentialKey: credentialKey,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: now,
            updatedAt: now
        )
        accounts.append(account)
        return account
    }

    @discardableResult
    func addMicrosoft365Account(title: String, credential: OAuthCredential) throws -> CalendarProviderAccount {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let accountID = "provider-microsoft365-\(UUID().uuidString)"
        let credentialKey = "\(accountID)-oauth"

        guard OAuthCredentialStore.saveCredential(credential, key: credentialKey) else {
            throw CalendarProviderStoreError.keychainSaveFailed
        }

        let account = CalendarProviderAccount(
            id: accountID,
            kind: .microsoft365,
            title: normalizedTitle.isEmpty ? "Microsoft 365" : normalizedTitle,
            endpointURLString: "https://graph.microsoft.com/v1.0",
            username: nil,
            credentialKey: credentialKey,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: now,
            updatedAt: now
        )
        accounts.append(account)
        return account
    }

    func setAccount(_ account: CalendarProviderAccount, enabled: Bool) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].enabled = enabled
        accounts[index].updatedAt = Date()
    }

    @discardableResult
    func updateICSSubscription(
        _ account: CalendarProviderAccount,
        title: String,
        urlString: String
    ) throws -> CalendarProviderAccount {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }),
              accounts[index].kind == .icsSubscription
        else {
            throw CalendarProviderStoreError.unsupportedSourceKind
        }

        let url = try normalizedSubscriptionURL(from: urlString)
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = url.host?.replacingOccurrences(of: "www.", with: "") ?? "Calendar Subscription"
        let previousURLString = accounts[index].endpointURLString

        accounts[index].title = normalizedTitle.isEmpty ? fallbackTitle : normalizedTitle
        accounts[index].endpointURLString = url.absoluteString
        accounts[index].updatedAt = Date()
        if previousURLString != url.absoluteString {
            resetSyncStateForAccount(at: index)
        }

        return accounts[index]
    }

    @discardableResult
    func updateCalDAVAccount(
        _ account: CalendarProviderAccount,
        title: String,
        urlString: String,
        username: String,
        password: String
    ) throws -> CalendarProviderAccount {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }),
              accounts[index].kind == .calDAV
        else {
            throw CalendarProviderStoreError.unsupportedSourceKind
        }

        let url = try normalizedHTTPURL(from: urlString)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUsername.isEmpty else { throw CalendarProviderStoreError.emptyUsername }

        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        var credentialKey = accounts[index].credentialKey
        if !trimmedPassword.isEmpty {
            let key = credentialKey ?? "\(accounts[index].id)-password"
            guard credentialStore.savePassword(password, key: key) else {
                throw CalendarProviderStoreError.keychainSaveFailed
            }
            credentialKey = key
        } else if credentialKey == nil {
            throw CalendarProviderStoreError.emptyPassword
        }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = url.host?.replacingOccurrences(of: "www.", with: "") ?? "CalDAV Account"
        let previousURLString = accounts[index].endpointURLString
        let previousUsername = accounts[index].username

        accounts[index].title = normalizedTitle.isEmpty ? fallbackTitle : normalizedTitle
        accounts[index].endpointURLString = url.absoluteString
        accounts[index].username = normalizedUsername
        accounts[index].credentialKey = credentialKey
        accounts[index].updatedAt = Date()
        if previousURLString != url.absoluteString || previousUsername != normalizedUsername || !trimmedPassword.isEmpty {
            resetSyncStateForAccount(at: index)
        }

        return accounts[index]
    }

    func recordAccountUsername(accountID: String, username: String, at date: Date = Date()) {
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUsername.isEmpty,
              let index = accounts.firstIndex(where: { $0.id == accountID }),
              accounts[index].username != normalizedUsername
        else {
            return
        }
        accounts[index].username = normalizedUsername
        accounts[index].updatedAt = date
    }

    func recordAccountIdentityEmail(accountID: String, identityEmail: String, at date: Date = Date()) {
        recordAccountIdentityEmails(accountID: accountID, identityEmails: [identityEmail], at: date)
    }

    func recordAccountIdentityEmails(accountID: String, identityEmails: [String], at date: Date = Date()) {
        let normalizedEmails = CalendarProviderAccount.normalizedIdentityEmails(identityEmails)
        guard !normalizedEmails.isEmpty,
              let index = accounts.firstIndex(where: { $0.id == accountID })
        else { return }

        let primaryEmail = normalizedEmails[0]
        let aliases = Array(normalizedEmails.dropFirst())
        guard accounts[index].identityEmail != primaryEmail
                || accounts[index].identityEmailAliases != aliases
        else { return }

        accounts[index].identityEmail = primaryEmail
        accounts[index].identityEmailAliases = aliases
        accounts[index].updatedAt = date
    }

    func accountMatchingIdentity(
        kind: CalendarProviderKind,
        excluding excludedAccountID: String,
        identityEmails: [String]
    ) -> CalendarProviderAccount? {
        let normalizedEmails = Set(CalendarProviderAccount.normalizedIdentityEmails(identityEmails))
        guard !normalizedEmails.isEmpty else { return nil }

        return accounts.first { account in
            guard account.kind == kind,
                  account.id != excludedAccountID
            else { return false }

            let accountEmails = Set(CalendarProviderAccount.normalizedIdentityEmails(
                [account.identityEmail].compactMap { $0 } + account.identityEmailAliases
            ))
            return !accountEmails.isDisjoint(with: normalizedEmails)
        }
    }

    func delete(_ account: CalendarProviderAccount) {
        if let credentialKey = account.credentialKey {
            credentialStore.deletePassword(key: credentialKey)
        }
        removeProviderOutboxItems(accountID: account.id)
        accounts.removeAll { $0.id == account.id }
    }

    var pendingProviderOutboxCount: Int {
        providerOutbox.count
    }

    var conflictedProviderOutboxCount: Int {
        providerOutbox.filter(\.isBlockedByConflict).count
    }

    var blockedProviderOutboxCount: Int {
        providerOutbox.filter(\.isBlockedByProviderRejection).count
    }

    func providerOutboxCount(accountID: String) -> Int {
        providerOutbox.filter { outboxItem($0, matchesAccountID: accountID) }.count
    }

    func providerOutboxConflictCount(accountID: String) -> Int {
        providerOutbox.filter {
            outboxItem($0, matchesAccountID: accountID) && $0.isBlockedByConflict
        }.count
    }

    func providerOutboxBlockedCount(accountID: String) -> Int {
        providerOutbox.filter {
            outboxItem($0, matchesAccountID: accountID) && $0.isBlockedByProviderRejection
        }.count
    }

    func conflictRetryAccountIDs(for items: [ProviderOutboxItem]) -> [String] {
        Array(Set(items.filter(\.isBlockedByConflict).flatMap { item in
            item.accountIDs.isEmpty ? enabledSyncAccounts.map(\.id) : item.accountIDs
        })).sorted()
    }

    func hasProviderOutboxItems(accountID: String) -> Bool {
        providerOutbox.contains { outboxItem($0, matchesAccountID: accountID) }
    }

    func hasSyncBlockingProviderOutboxItems(accountID: String) -> Bool {
        providerOutbox.contains {
            outboxItem($0, matchesAccountID: accountID) && !$0.isBlockedFromAutomaticRetry
        }
    }

    func remoteObjectURLsProtectedFromPruning(accountID: String) -> Set<String> {
        Set(providerOutbox
            .filter {
                outboxItem($0, matchesAccountID: accountID)
                    && $0.isBlockedFromAutomaticRetry
                    && ($0.operation == .write || $0.operation == .move)
            }
            .flatMap { item -> [String] in
                var remoteObjectURLs = [item.event.remoteObjectURLString]
                remoteObjectURLs.append(contentsOf: item.event.detachedOccurrences.compactMap(\.remoteObjectURLString))
                if let previousEvent = item.previousEvent {
                    remoteObjectURLs.append(previousEvent.remoteObjectURLString)
                    remoteObjectURLs.append(contentsOf: previousEvent.detachedOccurrences.compactMap(\.remoteObjectURLString))
                }
                return remoteObjectURLs
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    func localResponseRemoteObjectURLsProtectedFromProviderRefresh(accountID: String) -> Set<String> {
        Set(providerOutbox
            .filter {
                outboxItem($0, matchesAccountID: accountID)
                    && $0.operation == .response
            }
            .flatMap { item -> [String] in
                var remoteObjectURLs = [item.event.remoteObjectURLString]
                remoteObjectURLs.append(contentsOf: item.event.detachedOccurrences.compactMap(\.remoteObjectURLString))
                return remoteObjectURLs
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    func calendarIDsProtectedFromPruning(accountID: String) -> Set<String> {
        Set(providerOutbox
            .filter {
                outboxItem($0, matchesAccountID: accountID)
                    && $0.isBlockedFromAutomaticRetry
                    && ($0.operation == .write || $0.operation == .move)
            }
            .flatMap { item in
                [
                    item.event.calendarID,
                    item.previousEvent?.calendarID ?? ""
                ]
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    func dueProviderOutboxItems(now: Date = Date()) -> [ProviderOutboxItem] {
        providerOutbox
            .filter { item in
                guard !item.isBlockedFromAutomaticRetry else { return false }
                guard !isResponseWaitingForPendingRemoteObject(item) else { return false }
                guard let nextRetryAt = item.nextRetryAt else { return true }
                return nextRetryAt <= now
            }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    private func isResponseWaitingForPendingRemoteObject(_ item: ProviderOutboxItem) -> Bool {
        guard item.operation == .response else { return false }
        return providerOutbox.contains { pendingItem in
            pendingItem.id != item.id
                && pendingItem.eventID == item.eventID
                && (pendingItem.operation == .write || pendingItem.operation == .move)
                && outboxAccountsOverlap(item, pendingItem)
        }
    }

    @discardableResult
    func enqueueProviderOutboxItem(_ item: ProviderOutboxItem) -> Bool {
        var nextItem = item
        let now = Date()
        var deleteSupersededMoveAccountIDs: [String] = []
        nextItem.updatedAt = now

        if nextItem.operation == .delete,
           let moveItem = providerOutbox.first(where: {
               $0.eventID == nextItem.eventID
                   && $0.operation == .move
                   && outboxAccountsOverlap($0, nextItem)
           }),
           let sourceEvent = moveItem.previousEvent {
            deleteSupersededMoveAccountIDs = moveItem.accountIDs
            guard eventHasRemoteObjectBinding(sourceEvent) else {
                providerOutbox.removeAll {
                    $0.eventID == nextItem.eventID && outboxAccountsOverlap($0, moveItem)
                }
                return false
            }

            let sourceAccountIDs = outboxAccountIDsOwning(
                calendarID: sourceEvent.calendarID,
                from: moveItem.accountIDs
            )
            nextItem = ProviderOutboxItem.delete(
                event: sourceEvent,
                accountID: sourceAccountIDs.first ?? moveItem.accountIDs.first ?? "",
                now: item.createdAt
            )
            nextItem.accountIDs = sourceAccountIDs
            nextItem.updatedAt = now
        }

        if nextItem.operation == .delete,
           !eventHasRemoteObjectBinding(nextItem.event) {
            providerOutbox.removeAll {
                $0.eventID == nextItem.eventID && outboxAccountsOverlap($0, nextItem)
            }
            return false
        }

        if nextItem.operation == .write,
           let moveIndex = providerOutbox.firstIndex(where: {
               $0.eventID == nextItem.eventID
                   && $0.operation == .move
                   && outboxAccountsOverlap($0, nextItem)
           }) {
            providerOutbox[moveIndex].event = nextItem.event
            providerOutbox[moveIndex].updatedAt = now
            providerOutbox[moveIndex].attemptCount = 0
            providerOutbox[moveIndex].lastAttemptAt = nil
            providerOutbox[moveIndex].lastError = nil
            providerOutbox[moveIndex].failureKind = nil
            providerOutbox[moveIndex].nextRetryAt = nil
            return true
        }

        providerOutbox.removeAll { existing in
            switch nextItem.operation {
            case .write:
                return existing.eventID == nextItem.eventID
                    && existing.operation == .write
                    && outboxAccountsOverlap(existing, nextItem)
            case .delete:
                let supersededAccountIDs = deleteSupersededMoveAccountIDs.isEmpty
                    ? nextItem.accountIDs
                    : deleteSupersededMoveAccountIDs
                return existing.eventID == nextItem.eventID
                    && outboxAccountIDsOverlap(existing.accountIDs, supersededAccountIDs)
            case .move:
                return existing.eventID == nextItem.eventID
                    && outboxAccountsOverlap(existing, nextItem)
            case .response:
                return existing.operation == .response
                    && existing.eventID == nextItem.eventID
                    && existing.responseScope == nextItem.responseScope
                    && responseOccurrenceKey(existing.responseOccurrenceStartDate) == responseOccurrenceKey(nextItem.responseOccurrenceStartDate)
                    && outboxAccountsOverlap(existing, nextItem)
            }
        }

        if let index = providerOutbox.firstIndex(where: {
            $0.dedupeKey == nextItem.dedupeKey && outboxAccountsOverlap($0, nextItem)
        }) {
            nextItem.id = providerOutbox[index].id
            nextItem.createdAt = providerOutbox[index].createdAt
            providerOutbox[index] = nextItem
        } else {
            providerOutbox.append(nextItem)
        }
        return true
    }

    func removeProviderOutboxItem(id: UUID) {
        providerOutbox.removeAll { $0.id == id }
    }

    func markProviderOutboxItemDue(id: UUID, at date: Date = Date()) {
        guard let index = providerOutbox.firstIndex(where: { $0.id == id }) else { return }
        providerOutbox[index].failureKind = nil
        providerOutbox[index].lastError = nil
        providerOutbox[index].nextRetryAt = nil
        providerOutbox[index].updatedAt = date
    }

    func markAllProviderOutboxItemsDue(at date: Date = Date()) {
        guard !providerOutbox.isEmpty else { return }
        for index in providerOutbox.indices {
            providerOutbox[index].failureKind = nil
            providerOutbox[index].lastError = nil
            providerOutbox[index].nextRetryAt = nil
            providerOutbox[index].updatedAt = date
        }
    }

    func markAllRetryableProviderOutboxItemsDue(at date: Date = Date()) {
        guard !providerOutbox.isEmpty else { return }
        for index in providerOutbox.indices where !providerOutbox[index].isBlockedFromAutomaticRetry {
            providerOutbox[index].failureKind = nil
            providerOutbox[index].lastError = nil
            providerOutbox[index].nextRetryAt = nil
            providerOutbox[index].updatedAt = date
        }
    }

    func removeProviderOutboxItems(accountID: String) {
        providerOutbox.removeAll { outboxItem($0, matchesAccountID: accountID) }
    }

    private func responseOccurrenceKey(_ date: Date?) -> String {
        date.map { String(Int($0.timeIntervalSinceReferenceDate)) } ?? "series"
    }

    private func outboxAccountsOverlap(_ lhs: ProviderOutboxItem, _ rhs: ProviderOutboxItem) -> Bool {
        outboxAccountIDsOverlap(lhs.accountIDs, rhs.accountIDs)
    }

    private func outboxItem(_ item: ProviderOutboxItem, matchesAccountID accountID: String) -> Bool {
        outboxAccountIDsOverlap(item.accountIDs, [accountID])
    }

    private func outboxAccountIDsOverlap(_ lhs: [String], _ rhs: [String]) -> Bool {
        let lhsIDs = Set(lhs)
        let rhsIDs = Set(rhs)
        guard !lhsIDs.isEmpty, !rhsIDs.isEmpty else { return true }
        return !lhsIDs.isDisjoint(with: rhsIDs)
    }

    private func eventHasRemoteObjectBinding(_ event: LocalCalendarEvent) -> Bool {
        if !event.remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        return event.detachedOccurrences.contains {
            !($0.remoteObjectURLString ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func outboxAccountIDsOwning(calendarID: String, from accountIDs: [String]) -> [String] {
        let trimmedCalendarID = calendarID.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = accountIDs.filter { accountID in
            let trimmedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAccountID.isEmpty else { return false }
            return trimmedCalendarID.hasPrefix("local-calendar-caldav-\(trimmedAccountID)-")
                || trimmedCalendarID.hasPrefix("local-calendar-google-\(trimmedAccountID)-")
                || trimmedCalendarID.hasPrefix("local-calendar-microsoft365-\(trimmedAccountID)-")
        }
        let uniqueMatches = Array(Set(matches)).sorted()
        if !uniqueMatches.isEmpty {
            return uniqueMatches
        }
        return Array(Set(accountIDs)).sorted()
    }

    func recordProviderOutboxFailure(
        id: UUID,
        error: String,
        at date: Date = Date(),
        retryAfterSeconds: Int? = nil
    ) {
        guard let index = providerOutbox.firstIndex(where: { $0.id == id }) else { return }
        providerOutbox[index].attemptCount += 1
        providerOutbox[index].lastAttemptAt = date
        providerOutbox[index].lastError = error.trimmingCharacters(in: .whitespacesAndNewlines)
        providerOutbox[index].failureKind = .retryable
        providerOutbox[index].updatedAt = date

        let attempt = max(1, providerOutbox[index].attemptCount)
        let exponentialDelay = min(30 * 60, Int(pow(2.0, Double(min(attempt, 6)))) * 30)
        let providerDelay = retryAfterSeconds.map { min(max(1, $0), ProviderRetryAfter.maximumSeconds) }
        let delay = providerDelay ?? exponentialDelay
        providerOutbox[index].nextRetryAt = date.addingTimeInterval(TimeInterval(delay))
    }

    func recordProviderOutboxConflict(id: UUID, error: String, at date: Date = Date()) {
        guard let index = providerOutbox.firstIndex(where: { $0.id == id }) else { return }
        providerOutbox[index].attemptCount += 1
        providerOutbox[index].lastAttemptAt = date
        providerOutbox[index].lastError = error.trimmingCharacters(in: .whitespacesAndNewlines)
        providerOutbox[index].failureKind = .conflict
        providerOutbox[index].nextRetryAt = nil
        providerOutbox[index].updatedAt = date
    }

    func recordProviderOutboxBlocked(id: UUID, error: String, at date: Date = Date()) {
        guard let index = providerOutbox.firstIndex(where: { $0.id == id }) else { return }
        providerOutbox[index].attemptCount += 1
        providerOutbox[index].lastAttemptAt = date
        providerOutbox[index].lastError = error.trimmingCharacters(in: .whitespacesAndNewlines)
        providerOutbox[index].failureKind = .blocked
        providerOutbox[index].nextRetryAt = nil
        providerOutbox[index].updatedAt = date
    }

    func recordSync(
        accountID: String,
        summary: LocalICSImportSummary,
        startedAt: Date? = nil,
        at date: Date = Date()
    ) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].importedEventCount = summary.eventsImported
        accounts[index].updatedEventCount = summary.eventsUpdated
        accounts[index].skippedEventCount = summary.eventsSkipped
        accounts[index].deletedEventCount = summary.eventsDeleted
        accounts[index].lastSyncAt = date
        accounts[index].lastSyncStartedAt = startedAt
        accounts[index].lastSyncDurationSeconds = startedAt.map { max(0, date.timeIntervalSince($0)) }
        accounts[index].lastSyncFailedAt = nil
        accounts[index].syncNotBefore = nil
        accounts[index].lastError = nil
        accounts[index].updatedAt = date
    }

    func recordHTTPValidators(
        accountID: String,
        eTag: String?,
        lastModified: String?,
        preservesMissing: Bool = true,
        at date: Date = Date()
    ) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        if let eTag = eTag?.trimmingCharacters(in: .whitespacesAndNewlines), !eTag.isEmpty {
            accounts[index].httpETag = eTag
        } else if !preservesMissing {
            accounts[index].httpETag = nil
        }
        if let lastModified = lastModified?.trimmingCharacters(in: .whitespacesAndNewlines), !lastModified.isEmpty {
            accounts[index].httpLastModified = lastModified
        } else if !preservesMissing {
            accounts[index].httpLastModified = nil
        }
        accounts[index].updatedAt = date
    }

    func recordICSRefreshInterval(
        accountID: String,
        seconds: Int?,
        preservesMissing: Bool = true,
        at date: Date = Date()
    ) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        if let seconds, seconds > 0 {
            accounts[index].icsRefreshIntervalSeconds = seconds
        } else if !preservesMissing {
            accounts[index].icsRefreshIntervalSeconds = nil
        }
        accounts[index].updatedAt = date
    }

    func recordCalDAVSyncStates(accountID: String, states: [CalDAVCalendarSyncState], at date: Date = Date()) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].calDAVSyncStates = states
        accounts[index].updatedAt = date
    }

    func recordGoogleCalendarSyncStates(accountID: String, states: [GoogleCalendarSyncState], at date: Date = Date()) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].googleCalendarSyncStates = states
        accounts[index].updatedAt = date
    }

    func recordMicrosoftGraphSyncStates(accountID: String, states: [MicrosoftGraphSyncState], at date: Date = Date()) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].microsoftGraphSyncStates = states
        accounts[index].updatedAt = date
    }

    func recordSyncError(
        accountID: String,
        error: Error,
        syncStartedAt: Date? = nil,
        at date: Date = Date()
    ) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        if let retryAfterSeconds = (error as? ProviderRetryAfterError)?.providerRetryAfterSeconds {
            accounts[index].syncNotBefore = date.addingTimeInterval(
                TimeInterval(min(max(1, retryAfterSeconds), ProviderRetryAfter.maximumSeconds))
            )
        }
        if let syncStartedAt {
            accounts[index].lastSyncStartedAt = syncStartedAt
            accounts[index].lastSyncDurationSeconds = max(0, date.timeIntervalSince(syncStartedAt))
            accounts[index].lastSyncFailedAt = date
        }
        accounts[index].lastError = error.localizedDescription
        accounts[index].updatedAt = date
    }

    func recordProviderActionSuccess(accountID: String, at date: Date = Date()) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].lastError = nil
        accounts[index].updatedAt = date
    }

    func resetSyncState(accountID: String, at date: Date = Date()) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        resetSyncStateForAccount(at: index, date: date)
    }

    private func resetSyncStateForAccount(at index: Int, date: Date = Date()) {
        guard accounts.indices.contains(index) else { return }
        accounts[index].httpETag = nil
        accounts[index].httpLastModified = nil
        accounts[index].syncNotBefore = nil
        accounts[index].calDAVSyncStates = []
        accounts[index].googleCalendarSyncStates = []
        accounts[index].microsoftGraphSyncStates = []
        accounts[index].lastSyncStartedAt = nil
        accounts[index].lastSyncDurationSeconds = nil
        accounts[index].lastSyncFailedAt = nil
        accounts[index].lastError = nil
        accounts[index].updatedAt = date
    }

    private func load() {
        guard
            let data = userDefaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([CalendarProviderAccount].self, from: data)
        else {
            accounts = []
            return
        }

        accounts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    private func loadProviderOutbox() {
        guard
            let data = userDefaults.data(forKey: outboxStorageKey),
            let decoded = try? JSONDecoder().decode(LossyProviderOutbox.self, from: data)
        else {
            providerOutbox = []
            return
        }

        providerOutbox = decoded.items
    }

    private func saveProviderOutbox() {
        guard let data = try? JSONEncoder().encode(providerOutbox) else { return }
        userDefaults.set(data, forKey: outboxStorageKey)
    }

    private func normalizedSubscriptionURL(from value: String) throws -> URL {
        do {
            return try CalendarURLNormalizer.subscriptionURL(from: value)
        } catch let error as CalendarURLNormalizerError {
            throw storeError(for: error)
        }
    }

    private func normalizedHTTPURL(from value: String) throws -> URL {
        do {
            return try CalendarURLNormalizer.httpURL(from: value)
        } catch let error as CalendarURLNormalizerError {
            throw storeError(for: error)
        }
    }

    private func subscriptionIdentityKey(for url: URL?) -> String {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased()
        else {
            return ""
        }

        let port = components.port.map { ":\($0)" } ?? ""
        let path = components.path.removingPercentEncoding ?? components.path
        let querySuffix: String
        if let queryItems = components.queryItems, !queryItems.isEmpty {
            let query = queryItems.sorted {
                if $0.name == $1.name {
                    return ($0.value ?? "") < ($1.value ?? "")
                }
                return $0.name < $1.name
            }
            .map { "\($0.name)=\($0.value ?? "")" }
            .joined(separator: "&")
            querySuffix = "?\(query)"
        } else {
            querySuffix = ""
        }

        return "\(scheme)://\(host)\(port)\(path)\(querySuffix)"
    }

    private func calDAVAccountIdentityKey(for url: URL?, username: String?) -> String {
        let endpointKey = subscriptionIdentityKey(for: url)
        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usernameKey = CalendarProviderAccount.normalizedIdentityEmail(trimmedUsername) ?? trimmedUsername
        return "caldav:\(endpointKey)|user:\(usernameKey)"
    }

    private func storeError(for error: CalendarURLNormalizerError) -> CalendarProviderStoreError {
        switch error {
        case .emptyURL:
            return .emptyURL
        case .unsupportedURLScheme:
            return .unsupportedURLScheme
        case .invalidURL:
            return .invalidURL
        }
    }
}

enum CalendarCredentialStore {
    private static let service = "dev.codex.WorkingCalendar.calendarProviders"

    static func savePassword(_ password: String, key: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func password(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
