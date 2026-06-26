import AppKit
import Combine
import Foundation

struct LocalCalendar: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var colorHex: String
    var allowsEventWrite: Bool
    var allowsResponses: Bool

    var color: NSColor {
        NSColor(hexString: colorHex) ?? .systemTeal
    }

    init(
        id: String,
        title: String,
        colorHex: String,
        allowsEventWrite: Bool = true,
        allowsResponses: Bool = true
    ) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
        self.allowsEventWrite = allowsEventWrite
        self.allowsResponses = allowsResponses
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case colorHex
        case allowsEventWrite
        case allowsResponses
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        allowsEventWrite = try container.decodeIfPresent(Bool.self, forKey: .allowsEventWrite) ?? true
        allowsResponses = try container.decodeIfPresent(Bool.self, forKey: .allowsResponses) ?? allowsEventWrite
    }
}

struct LocalProviderOccurrenceCancellation: Hashable {
    var externalUID: String
    var occurrenceStartDate: Date
    var appliesToFutureOccurrences: Bool = false
}

struct LocalProviderRemoteOccurrenceCancellation: Hashable {
    var masterRemoteObjectURLString: String
    var occurrenceStartDate: Date
}

enum LocalRecurrenceFrequency: String, Codable, CaseIterable, Hashable, Identifiable {
    case none
    case daily
    case weekly
    case monthly
    case yearly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Never"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }

    var calendarComponent: Calendar.Component? {
        switch self {
        case .none: return nil
        case .daily: return .day
        case .weekly: return .weekOfYear
        case .monthly: return .month
        case .yearly: return .year
        }
    }

    func intervalTitle(count: Int) -> String {
        switch self {
        case .none:
            return "events"
        case .daily:
            return count == 1 ? "day" : "days"
        case .weekly:
            return count == 1 ? "week" : "weeks"
        case .monthly:
            return count == 1 ? "month" : "months"
        case .yearly:
            return count == 1 ? "year" : "years"
        }
    }
}

func normalizedOrdinalRecurrence(
    _ ordinal: Int?,
    weekday: Int?,
    frequency: LocalRecurrenceFrequency
) -> (ordinal: Int?, weekday: Int?) {
    guard (frequency == .monthly || frequency == .yearly),
          let ordinal,
          ordinal != 0,
          (-5...5).contains(ordinal),
          let weekday,
          (1...7).contains(weekday)
    else {
        return (nil, nil)
    }

    return (ordinal, weekday)
}

func normalizedRecurrenceMonthDay(
    _ monthDay: Int?,
    frequency: LocalRecurrenceFrequency
) -> Int? {
    guard frequency == .monthly || frequency == .yearly,
          let monthDay,
          monthDay != 0,
          (-31...31).contains(monthDay)
    else {
        return nil
    }

    return monthDay
}

func normalizedRecurrenceMonths(
    _ months: [Int],
    frequency: LocalRecurrenceFrequency
) -> [Int] {
    guard frequency == .monthly || frequency == .yearly else { return [] }
    return Array(Set(months.filter { (1...12).contains($0) })).sorted()
}

func normalizedRecurrenceWeekStart(
    _ weekStart: Int?,
    frequency: LocalRecurrenceFrequency
) -> Int? {
    guard frequency == .weekly,
          let weekStart,
          (1...7).contains(weekStart)
    else {
        return nil
    }

    return weekStart
}

func normalizedRecurrenceSetPositions(
    _ setPositions: [Int],
    frequency: LocalRecurrenceFrequency
) -> [Int] {
    guard frequency == .weekly else { return [] }
    return Array(Set(setPositions.filter { $0 != 0 && (-366...366).contains($0) })).sorted()
}

struct LocalEventRelationship: Identifiable, Codable, Hashable {
    var relationType: String
    var externalUID: String

    var id: String {
        "\(relationType)|\(externalUID)"
    }

    init(relationType: String = "PARENT", externalUID: String) {
        let normalizedRelationType = relationType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        self.relationType = normalizedRelationType.isEmpty ? "PARENT" : normalizedRelationType
        self.externalUID = externalUID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func normalizedEventRelationships(_ relationships: [LocalEventRelationship]) -> [LocalEventRelationship] {
    var seen = Set<String>()
    return relationships.compactMap { relationship in
        let normalized = LocalEventRelationship(
            relationType: relationship.relationType,
            externalUID: relationship.externalUID
        )
        guard !normalized.externalUID.isEmpty else { return nil }
        let key = "\(normalized.relationType.lowercased())|\(normalized.externalUID.lowercased())"
        guard seen.insert(key).inserted else { return nil }
        return normalized
    }
}

struct LocalEventAttachment: Identifiable, Codable, Hashable {
    var urlString: String
    var formatType: String
    var displayName: String

    var id: String {
        urlString
    }

    init(urlString: String, formatType: String = "", displayName: String = "") {
        self.urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        self.formatType = formatType.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func normalizedEventAttachments(_ attachments: [LocalEventAttachment]) -> [LocalEventAttachment] {
    var seen = Set<String>()
    return attachments.compactMap { attachment in
        let normalized = LocalEventAttachment(
            urlString: attachment.urlString,
            formatType: attachment.formatType,
            displayName: attachment.displayName
        )
        guard !normalized.urlString.isEmpty else { return nil }
        guard seen.insert(normalized.urlString.lowercased()).inserted else { return nil }
        return normalized
    }
}

struct LocalEventGeoCoordinate: Codable, Hashable {
    var latitude: Double
    var longitude: Double

    init?(latitude: Double, longitude: Double) {
        guard (-90...90).contains(latitude),
              (-180...180).contains(longitude),
              latitude.isFinite,
              longitude.isFinite
        else {
            return nil
        }

        self.latitude = latitude
        self.longitude = longitude
    }
}

struct LocalCalendarEvent: Identifiable, Codable, Hashable {
    var id: String
    var externalUID: String
    var remoteObjectURLString: String
    var remoteETag: String
    var sequence: Int
    var calendarID: String
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var availability: CalendarEventAvailability
    var status: CalendarEventStatus
    var privacy: CalendarEventPrivacy
    var importance: CalendarEventImportance
    var categories: [String]
    var relatedEvents: [LocalEventRelationship]
    var attachments: [LocalEventAttachment]
    var reminderOffsets: [Int]
    var timeZoneIdentifier: String
    var geoCoordinate: LocalEventGeoCoordinate?
    var organizerName: String
    var organizerEmail: String
    var attendees: [LocalEventAttendee]
    var myResponseStatus: EventResponseStatus
    var location: String
    var notes: String
    var urlString: String
    var recurrenceFrequency: LocalRecurrenceFrequency
    var recurrenceInterval: Int
    var recurrenceWeekdays: [Int]
    var recurrenceWeekStart: Int?
    var recurrenceSetPositions: [Int]
    var recurrenceOrdinal: Int?
    var recurrenceOrdinalWeekday: Int?
    var recurrenceMonthDay: Int?
    var recurrenceMonths: [Int]
    var recurrenceEndDate: Date?
    var additionalOccurrenceStartDates: [Date]
    var excludedOccurrenceStartDates: [Date]
    var detachedOccurrences: [LocalDetachedOccurrence]
    var hasLocalProviderRecurrenceChanges: Bool
    var isImportedRecurrenceSplitProjection: Bool
    var createdAt: Date
    var updatedAt: Date

    var isRecurring: Bool {
        recurrenceFrequency != .none || !additionalOccurrenceStartDates.isEmpty
    }

    var safeRecurrenceInterval: Int {
        max(1, recurrenceInterval)
    }

    init(
        id: String,
        externalUID: String = "",
        remoteObjectURLString: String = "",
        remoteETag: String = "",
        sequence: Int = 0,
        calendarID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        availability: CalendarEventAvailability = .busy,
        status: CalendarEventStatus = .confirmed,
        privacy: CalendarEventPrivacy = .public,
        importance: CalendarEventImportance = .normal,
        categories: [String] = [],
        relatedEvents: [LocalEventRelationship] = [],
        attachments: [LocalEventAttachment] = [],
        reminderOffsets: [Int] = [],
        timeZoneIdentifier: String = TimeZone.current.identifier,
        geoCoordinate: LocalEventGeoCoordinate? = nil,
        organizerName: String = "",
        organizerEmail: String = "",
        attendees: [LocalEventAttendee] = [],
        myResponseStatus: EventResponseStatus = .notInvited,
        location: String,
        notes: String,
        urlString: String,
        recurrenceFrequency: LocalRecurrenceFrequency = .none,
        recurrenceInterval: Int = 1,
        recurrenceWeekdays: [Int] = [],
        recurrenceWeekStart: Int? = nil,
        recurrenceSetPositions: [Int] = [],
        recurrenceOrdinal: Int? = nil,
        recurrenceOrdinalWeekday: Int? = nil,
        recurrenceMonthDay: Int? = nil,
        recurrenceMonths: [Int] = [],
        recurrenceEndDate: Date? = nil,
        additionalOccurrenceStartDates: [Date] = [],
        excludedOccurrenceStartDates: [Date] = [],
        detachedOccurrences: [LocalDetachedOccurrence] = [],
        hasLocalProviderRecurrenceChanges: Bool = false,
        isImportedRecurrenceSplitProjection: Bool = false,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        let normalizedExternalUID = externalUID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.externalUID = normalizedExternalUID.isEmpty ? id : normalizedExternalUID
        self.remoteObjectURLString = remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        self.remoteETag = remoteETag.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sequence = max(0, sequence)
        self.calendarID = calendarID
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.availability = availability
        self.status = status
        self.privacy = privacy
        self.importance = importance
        self.categories = normalizedEventCategories(categories)
        self.relatedEvents = normalizedEventRelationships(relatedEvents)
        self.attachments = normalizedEventAttachments(attachments)
        self.reminderOffsets = normalizedReminderOffsets(reminderOffsets)
        self.timeZoneIdentifier = timeZoneIdentifier.isEmpty ? TimeZone.current.identifier : timeZoneIdentifier
        self.geoCoordinate = geoCoordinate
        self.organizerName = organizerName
        self.organizerEmail = organizerEmail
        self.attendees = attendees
        self.myResponseStatus = myResponseStatus
        self.location = location
        self.notes = notes
        self.urlString = urlString
        self.recurrenceFrequency = recurrenceFrequency
        self.recurrenceInterval = max(1, recurrenceInterval)
        self.recurrenceWeekdays = recurrenceFrequency == .weekly ? recurrenceWeekdays.normalizedWeekdays : []
        self.recurrenceWeekStart = normalizedRecurrenceWeekStart(recurrenceWeekStart, frequency: recurrenceFrequency)
        self.recurrenceSetPositions = normalizedRecurrenceSetPositions(recurrenceSetPositions, frequency: recurrenceFrequency)
        let normalizedOrdinal = normalizedOrdinalRecurrence(
            recurrenceOrdinal,
            weekday: recurrenceOrdinalWeekday,
            frequency: recurrenceFrequency
        )
        self.recurrenceOrdinal = normalizedOrdinal.ordinal
        self.recurrenceOrdinalWeekday = normalizedOrdinal.weekday
        self.recurrenceMonthDay = normalizedOrdinal.ordinal == nil
            ? normalizedRecurrenceMonthDay(recurrenceMonthDay, frequency: recurrenceFrequency)
            : nil
        self.recurrenceMonths = normalizedRecurrenceMonths(recurrenceMonths, frequency: recurrenceFrequency)
        self.recurrenceEndDate = recurrenceFrequency == .none ? nil : recurrenceEndDate
        self.additionalOccurrenceStartDates = additionalOccurrenceStartDates.uniqueOccurrenceStarts.sorted()
        let hasRecurrenceData = recurrenceFrequency != .none || !self.additionalOccurrenceStartDates.isEmpty
        self.excludedOccurrenceStartDates = hasRecurrenceData ? excludedOccurrenceStartDates : []
        self.detachedOccurrences = hasRecurrenceData ? detachedOccurrences : []
        self.hasLocalProviderRecurrenceChanges = hasRecurrenceData ? hasLocalProviderRecurrenceChanges : false
        self.isImportedRecurrenceSplitProjection = isImportedRecurrenceSplitProjection
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case externalUID
        case remoteObjectURLString
        case remoteETag
        case sequence
        case calendarID
        case title
        case startDate
        case endDate
        case isAllDay
        case availability
        case status
        case privacy
        case importance
        case categories
        case relatedEvents
        case attachments
        case reminderOffsets
        case timeZoneIdentifier
        case geoCoordinate
        case organizerName
        case organizerEmail
        case attendees
        case myResponseStatus
        case location
        case notes
        case urlString
        case recurrenceFrequency
        case recurrenceInterval
        case recurrenceWeekdays
        case recurrenceWeekStart
        case recurrenceSetPositions
        case recurrenceOrdinal
        case recurrenceOrdinalWeekday
        case recurrenceMonthDay
        case recurrenceMonths
        case recurrenceEndDate
        case additionalOccurrenceStartDates
        case excludedOccurrenceStartDates
        case detachedOccurrences
        case hasLocalProviderRecurrenceChanges
        case isImportedRecurrenceSplitProjection
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let decodedExternalUID = try container.decodeIfPresent(String.self, forKey: .externalUID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        externalUID = decodedExternalUID.isEmpty ? id : decodedExternalUID
        remoteObjectURLString = try container.decodeIfPresent(String.self, forKey: .remoteObjectURLString)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        remoteETag = try container.decodeIfPresent(String.self, forKey: .remoteETag)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        sequence = max(0, try container.decodeIfPresent(Int.self, forKey: .sequence) ?? 0)
        calendarID = try container.decode(String.self, forKey: .calendarID)
        title = try container.decode(String.self, forKey: .title)
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decode(Date.self, forKey: .endDate)
        isAllDay = try container.decode(Bool.self, forKey: .isAllDay)
        availability = try container.decodeIfPresent(CalendarEventAvailability.self, forKey: .availability) ?? .busy
        status = try container.decodeIfPresent(CalendarEventStatus.self, forKey: .status) ?? .confirmed
        privacy = try container.decodeIfPresent(CalendarEventPrivacy.self, forKey: .privacy) ?? .public
        importance = try container.decodeIfPresent(CalendarEventImportance.self, forKey: .importance) ?? .normal
        categories = normalizedEventCategories(try container.decodeIfPresent([String].self, forKey: .categories) ?? [])
        relatedEvents = normalizedEventRelationships(try container.decodeIfPresent([LocalEventRelationship].self, forKey: .relatedEvents) ?? [])
        attachments = normalizedEventAttachments(try container.decodeIfPresent([LocalEventAttachment].self, forKey: .attachments) ?? [])
        reminderOffsets = normalizedReminderOffsets(try container.decodeIfPresent([Int].self, forKey: .reminderOffsets) ?? [])
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier) ?? TimeZone.current.identifier
        geoCoordinate = try container.decodeIfPresent(LocalEventGeoCoordinate.self, forKey: .geoCoordinate)
        organizerName = try container.decodeIfPresent(String.self, forKey: .organizerName) ?? ""
        organizerEmail = try container.decodeIfPresent(String.self, forKey: .organizerEmail) ?? ""
        attendees = try container.decodeIfPresent([LocalEventAttendee].self, forKey: .attendees) ?? []
        myResponseStatus = try container.decodeIfPresent(EventResponseStatus.self, forKey: .myResponseStatus) ?? .notInvited
        location = try container.decode(String.self, forKey: .location)
        notes = try container.decode(String.self, forKey: .notes)
        urlString = try container.decode(String.self, forKey: .urlString)
        recurrenceFrequency = try container.decodeIfPresent(LocalRecurrenceFrequency.self, forKey: .recurrenceFrequency) ?? .none
        recurrenceInterval = max(1, try container.decodeIfPresent(Int.self, forKey: .recurrenceInterval) ?? 1)
        recurrenceWeekdays = recurrenceFrequency == .weekly
            ? (try container.decodeIfPresent([Int].self, forKey: .recurrenceWeekdays) ?? []).normalizedWeekdays
            : []
        recurrenceWeekStart = normalizedRecurrenceWeekStart(
            try container.decodeIfPresent(Int.self, forKey: .recurrenceWeekStart),
            frequency: recurrenceFrequency
        )
        recurrenceSetPositions = normalizedRecurrenceSetPositions(
            try container.decodeIfPresent([Int].self, forKey: .recurrenceSetPositions) ?? [],
            frequency: recurrenceFrequency
        )
        let normalizedOrdinal = normalizedOrdinalRecurrence(
            try container.decodeIfPresent(Int.self, forKey: .recurrenceOrdinal),
            weekday: try container.decodeIfPresent(Int.self, forKey: .recurrenceOrdinalWeekday),
            frequency: recurrenceFrequency
        )
        recurrenceOrdinal = normalizedOrdinal.ordinal
        recurrenceOrdinalWeekday = normalizedOrdinal.weekday
        recurrenceMonthDay = normalizedOrdinal.ordinal == nil
            ? normalizedRecurrenceMonthDay(
                try container.decodeIfPresent(Int.self, forKey: .recurrenceMonthDay),
                frequency: recurrenceFrequency
            )
            : nil
        recurrenceMonths = normalizedRecurrenceMonths(
            try container.decodeIfPresent([Int].self, forKey: .recurrenceMonths) ?? [],
            frequency: recurrenceFrequency
        )
        recurrenceEndDate = recurrenceFrequency == .none ? nil : try container.decodeIfPresent(Date.self, forKey: .recurrenceEndDate)
        additionalOccurrenceStartDates = (try container.decodeIfPresent([Date].self, forKey: .additionalOccurrenceStartDates) ?? [])
            .uniqueOccurrenceStarts
            .sorted()
        let hasRecurrenceData = recurrenceFrequency != .none || !additionalOccurrenceStartDates.isEmpty
        excludedOccurrenceStartDates = !hasRecurrenceData
            ? []
            : (try container.decodeIfPresent([Date].self, forKey: .excludedOccurrenceStartDates) ?? [])
        detachedOccurrences = !hasRecurrenceData
            ? []
            : (try container.decodeIfPresent([LocalDetachedOccurrence].self, forKey: .detachedOccurrences) ?? [])
        hasLocalProviderRecurrenceChanges = !hasRecurrenceData
            ? false
            : (try container.decodeIfPresent(Bool.self, forKey: .hasLocalProviderRecurrenceChanges) ?? false)
        isImportedRecurrenceSplitProjection = try container.decodeIfPresent(Bool.self, forKey: .isImportedRecurrenceSplitProjection) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct LocalDetachedOccurrence: Codable, Hashable {
    var originalStartDate: Date
    var sequence: Int
    var calendarID: String
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var availability: CalendarEventAvailability
    var status: CalendarEventStatus
    var privacy: CalendarEventPrivacy
    var importance: CalendarEventImportance
    var categories: [String]
    var relatedEvents: [LocalEventRelationship]
    var attachments: [LocalEventAttachment]
    var reminderOffsets: [Int]
    var timeZoneIdentifier: String
    var geoCoordinate: LocalEventGeoCoordinate?
    var organizerName: String
    var organizerEmail: String
    var attendees: [LocalEventAttendee]
    var myResponseStatus: EventResponseStatus
    var location: String
    var notes: String
    var urlString: String
    var remoteObjectURLString: String?
    var updatedAt: Date

    init(
        originalStartDate: Date,
        sequence: Int = 0,
        calendarID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        availability: CalendarEventAvailability = .busy,
        status: CalendarEventStatus = .confirmed,
        privacy: CalendarEventPrivacy = .public,
        importance: CalendarEventImportance = .normal,
        categories: [String] = [],
        relatedEvents: [LocalEventRelationship] = [],
        attachments: [LocalEventAttachment] = [],
        reminderOffsets: [Int] = [],
        timeZoneIdentifier: String = TimeZone.current.identifier,
        geoCoordinate: LocalEventGeoCoordinate? = nil,
        organizerName: String = "",
        organizerEmail: String = "",
        attendees: [LocalEventAttendee] = [],
        myResponseStatus: EventResponseStatus = .notInvited,
        location: String,
        notes: String,
        urlString: String,
        remoteObjectURLString: String = "",
        updatedAt: Date
    ) {
        self.originalStartDate = originalStartDate
        self.sequence = max(0, sequence)
        self.calendarID = calendarID
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.availability = availability
        self.status = status
        self.privacy = privacy
        self.importance = importance
        self.categories = normalizedEventCategories(categories)
        self.relatedEvents = normalizedEventRelationships(relatedEvents)
        self.attachments = normalizedEventAttachments(attachments)
        self.reminderOffsets = normalizedReminderOffsets(reminderOffsets)
        self.timeZoneIdentifier = timeZoneIdentifier.isEmpty ? TimeZone.current.identifier : timeZoneIdentifier
        self.geoCoordinate = geoCoordinate
        self.organizerName = organizerName
        self.organizerEmail = organizerEmail
        self.attendees = attendees
        self.myResponseStatus = myResponseStatus
        self.location = location
        self.notes = notes
        self.urlString = urlString
        let normalizedRemoteObjectURLString = remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        self.remoteObjectURLString = normalizedRemoteObjectURLString.isEmpty ? nil : normalizedRemoteObjectURLString
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case originalStartDate
        case sequence
        case calendarID
        case title
        case startDate
        case endDate
        case isAllDay
        case availability
        case status
        case privacy
        case importance
        case categories
        case relatedEvents
        case attachments
        case reminderOffsets
        case timeZoneIdentifier
        case geoCoordinate
        case organizerName
        case organizerEmail
        case attendees
        case myResponseStatus
        case location
        case notes
        case urlString
        case remoteObjectURLString
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        originalStartDate = try container.decode(Date.self, forKey: .originalStartDate)
        sequence = max(0, try container.decodeIfPresent(Int.self, forKey: .sequence) ?? 0)
        calendarID = try container.decode(String.self, forKey: .calendarID)
        title = try container.decode(String.self, forKey: .title)
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decode(Date.self, forKey: .endDate)
        isAllDay = try container.decode(Bool.self, forKey: .isAllDay)
        availability = try container.decodeIfPresent(CalendarEventAvailability.self, forKey: .availability) ?? .busy
        status = try container.decodeIfPresent(CalendarEventStatus.self, forKey: .status) ?? .confirmed
        privacy = try container.decodeIfPresent(CalendarEventPrivacy.self, forKey: .privacy) ?? .public
        importance = try container.decodeIfPresent(CalendarEventImportance.self, forKey: .importance) ?? .normal
        categories = normalizedEventCategories(try container.decodeIfPresent([String].self, forKey: .categories) ?? [])
        relatedEvents = normalizedEventRelationships(try container.decodeIfPresent([LocalEventRelationship].self, forKey: .relatedEvents) ?? [])
        attachments = normalizedEventAttachments(try container.decodeIfPresent([LocalEventAttachment].self, forKey: .attachments) ?? [])
        reminderOffsets = normalizedReminderOffsets(try container.decodeIfPresent([Int].self, forKey: .reminderOffsets) ?? [])
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier) ?? TimeZone.current.identifier
        geoCoordinate = try container.decodeIfPresent(LocalEventGeoCoordinate.self, forKey: .geoCoordinate)
        organizerName = try container.decodeIfPresent(String.self, forKey: .organizerName) ?? ""
        organizerEmail = try container.decodeIfPresent(String.self, forKey: .organizerEmail) ?? ""
        attendees = try container.decodeIfPresent([LocalEventAttendee].self, forKey: .attendees) ?? []
        myResponseStatus = try container.decodeIfPresent(EventResponseStatus.self, forKey: .myResponseStatus) ?? .notInvited
        location = try container.decode(String.self, forKey: .location)
        notes = try container.decode(String.self, forKey: .notes)
        urlString = try container.decode(String.self, forKey: .urlString)
        let decodedRemoteObjectURLString = try container.decodeIfPresent(String.self, forKey: .remoteObjectURLString)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        remoteObjectURLString = decodedRemoteObjectURLString.isEmpty ? nil : decodedRemoteObjectURLString
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct LocalEventAttendee: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var email: String
    var status: EventResponseStatus
    var type: String
    var role: String
    var rsvp: Bool
    var isCurrentUser: Bool

    init(
        id: String = UUID().uuidString,
        name: String = "",
        email: String = "",
        status: EventResponseStatus = .pending,
        type: String = "person",
        role: String = "required",
        rsvp: Bool = false,
        isCurrentUser: Bool = false
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.status = status
        self.type = type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "person" : type
        self.role = role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "required" : role
        self.rsvp = rsvp
        self.isCurrentUser = isCurrentUser
    }

    var isBlank: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var normalizedType: String {
        let normalized = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? "person" : normalized
    }

    var normalizedRole: String {
        let normalized = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? "required" : normalized
    }

    var isRoomLike: Bool {
        let type = normalizedType
        if type == "room" || type == "resource" || type == "equipment" {
            return true
        }

        let normalizedEmail = email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedEmail.hasSuffix("@resource.calendar.google.com")
            || normalizedEmail.contains(".resource.")
            || normalizedEmail.contains("-resource@")
            || normalizedEmail.contains("_resource@") {
            return true
        }

        let haystack = [name, email]
            .joined(separator: " ")
            .lowercased()
        return haystack.contains("room")
            || haystack.contains("conference")
            || haystack.contains("meeting")
            || haystack.contains("переговор")
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case email
        case status
        case type
        case role
        case rsvp
        case isCurrentUser
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        status = try container.decodeIfPresent(EventResponseStatus.self, forKey: .status) ?? .pending
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "person"
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "required"
        rsvp = try container.decodeIfPresent(Bool.self, forKey: .rsvp) ?? false
        isCurrentUser = try container.decodeIfPresent(Bool.self, forKey: .isCurrentUser) ?? false
    }
}

struct LocalCalendarDraft: Identifiable, Equatable {
    let id = UUID()
    var calendarID: String?
    var title: String
    var colorHex: String
}

struct LocalEventDraft: Identifiable, Equatable {
    let id = UUID()
    var eventID: String?
    var calendarID: String
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var availability: CalendarEventAvailability
    var privacy: CalendarEventPrivacy
    var importance: CalendarEventImportance
    var categories: [String]
    var reminderOffsets: [Int]
    var timeZoneIdentifier: String
    var organizerName: String
    var organizerEmail: String
    var attendees: [LocalEventAttendee]
    var myResponseStatus: EventResponseStatus
    var location: String
    var notes: String
    var urlString: String
    var recurrenceFrequency: LocalRecurrenceFrequency
    var recurrenceInterval: Int
    var recurrenceWeekdays: [Int]
    var recurrenceWeekStart: Int?
    var recurrenceSetPositions: [Int]
    var recurrenceOrdinal: Int?
    var recurrenceOrdinalWeekday: Int?
    var recurrenceMonthDay: Int?
    var recurrenceMonths: [Int]
    var recurrenceEndDate: Date?
    var hasAdditionalOccurrences: Bool
    var detachedOriginalStartDate: Date?

    var isDetachedOccurrenceDraft: Bool {
        detachedOriginalStartDate != nil
    }
}

@MainActor
final class LocalCalendarStore: ObservableObject {
    static let eventIDPrefix = "local-event-"
    static let calendarIDPrefix = "local-calendar-"
    private static let occurrenceSeparator = "::"

    @Published private(set) var calendars: [LocalCalendar] = [] {
        didSet { save() }
    }
    @Published private(set) var events: [LocalCalendarEvent] = [] {
        didSet { save() }
    }
    @Published var selectedCalendarIDs: Set<String> = [] {
        didSet { saveSelectedCalendars() }
    }

    private enum Keys {
        static let calendars = "localCalendars"
        static let events = "localCalendarEvents"
        static let selectedCalendarIDs = "selectedLocalCalendarIDs"
    }

    init() {
        load()
    }

    func events(from start: Date, to end: Date, includeAllDay: Bool = true) -> [CalendarEvent] {
        events
            .flatMap { calendarEvents(from: $0, rangeStart: start, rangeEnd: end, includeAllDay: includeAllDay) }
            .sorted { $0.startDate < $1.startDate }
    }

    func events(inNextHours hours: Double, now: Date = Date(), includeAllDay: Bool = false) -> [CalendarEvent] {
        let end = now.addingTimeInterval(hours * 3600)
        return events(from: now.addingTimeInterval(-15 * 60), to: end, includeAllDay: includeAllDay)
    }

    func exportICSText() -> String {
        LocalCalendarICSCodec.export(calendars: calendars, events: events)
    }

    func importICSText(
        _ text: String,
        preservingLocalResponsesForRemoteObjectURLs protectedResponseRemoteObjectURLs: Set<String> = []
    ) throws -> LocalICSImportSummary {
        if LocalCalendarICSCodec.isAddSchedulingMessage(text) {
            let addedOccurrences = LocalCalendarICSCodec.addedOccurrences(from: text)
            guard !addedOccurrences.isEmpty else { throw LocalICSImportError.noEvents }
            let updatedCount = applyAddedOccurrences(addedOccurrences)
            return LocalICSImportSummary(
                calendarsImported: 0,
                eventsImported: 0,
                eventsUpdated: updatedCount,
                eventsSkipped: max(0, addedOccurrences.count - updatedCount)
            )
        }

        let imported = try LocalCalendarICSCodec.import(text)
        guard !imported.events.isEmpty else { throw LocalICSImportError.noEvents }

        let normalizedProtectedResponseRemoteObjectURLs = normalizedRemoteObjectURLSet(protectedResponseRemoteObjectURLs)
        let orphanDetachedUpdates = LocalCalendarICSCodec.orphanDetachedOccurrenceUpdates(from: text)
        let handledDetachedUpdateUIDs = handledDetachedOccurrenceUpdateUIDs(orphanDetachedUpdates)
        let detachedUpdatedCount = applyDetachedOccurrenceUpdates(orphanDetachedUpdates)

        var seenImportedKeys: Set<String> = []
        var newEvents: [LocalCalendarEvent] = []
        var skippedEventCount = 0
        var updatedEventCount = detachedUpdatedCount
        var deletedEventCount = 0
        var usedCalendarIDs: Set<String> = []

        for var event in imported.events {
            if shouldSkipImportedEventAfterDetachedOccurrenceUpdate(event, handledExternalUIDs: handledDetachedUpdateUIDs) {
                continue
            }

            guard seenImportedKeys.insert(importIdentityKey(for: event)).inserted else {
                skippedEventCount += 1
                continue
            }

            deletedEventCount += mergeExistingOrphanDetachedOccurrences(into: &event)

            if let existingIndex = events.firstIndex(where: { isSameImportedEvent($0, as: event) }) {
                let existingEvent = events[existingIndex]
                if shouldPreserveExistingImportedVersion(existingEvent, over: event) {
                    skippedEventCount += 1
                    continue
                }
                var updatedEvent = event
                updatedEvent.id = existingEvent.id
                updatedEvent.calendarID = existingEvent.calendarID
                updatedEvent.createdAt = existingEvent.createdAt
                preserveLocalProviderRecurrenceChanges(from: existingEvent, into: &updatedEvent)
                preservePartialProviderAttendees(from: existingEvent, into: &updatedEvent)
                preserveLocallyNewerResponse(
                    from: existingEvent,
                    into: &updatedEvent,
                    protectedRemoteObjectURLs: normalizedProtectedResponseRemoteObjectURLs
                )
                usedCalendarIDs.insert(updatedEvent.calendarID)
                events[existingIndex] = updatedEvent
                updatedEventCount += 1
                continue
            }

            usedCalendarIDs.insert(event.calendarID)
            newEvents.append(event)
        }

        var importedCalendarsByID: [String: LocalCalendar] = [:]
        for calendar in imported.calendars {
            importedCalendarsByID[calendar.id] = calendar
        }

        for index in calendars.indices {
            guard usedCalendarIDs.contains(calendars[index].id),
                  let importedCalendar = importedCalendarsByID[calendars[index].id]
            else {
                continue
            }

            calendars[index].title = importedCalendar.title
            calendars[index].colorHex = importedCalendar.colorHex
            calendars[index].allowsEventWrite = importedCalendar.allowsEventWrite
            calendars[index].allowsResponses = importedCalendar.allowsResponses
        }

        let existingCalendarIDs = Set(calendars.map(\.id))
        let newCalendars = imported.calendars.filter {
            usedCalendarIDs.contains($0.id) && !existingCalendarIDs.contains($0.id)
        }

        calendars.append(contentsOf: newCalendars)
        events.append(contentsOf: newEvents)
        selectedCalendarIDs.formUnion(newCalendars.map(\.id))

        return LocalICSImportSummary(
            calendarsImported: newCalendars.count,
            eventsImported: newEvents.count,
            eventsUpdated: updatedEventCount,
            eventsSkipped: skippedEventCount,
            eventsDeleted: deletedEventCount
        )
    }

    @discardableResult
    private func mergeExistingOrphanDetachedOccurrences(into importedEvent: inout LocalCalendarEvent) -> Int {
        guard importedEvent.isRecurring else { return 0 }

        let prefix = "\(importedEvent.externalUID)#"
        var removedCount = 0

        for index in events.indices.reversed() {
            let orphan = events[index]
            guard !orphan.isRecurring,
                  orphan.externalUID.hasPrefix(prefix),
                  orphan.calendarID == importedEvent.calendarID,
                  let originalStartDate = orphanOriginalStartDate(orphan.externalUID, baseExternalUID: importedEvent.externalUID),
                  event(importedEvent, canContainOccurrenceStart: originalStartDate)
            else {
                continue
            }

            let occurrence = LocalDetachedOccurrence(
                originalStartDate: originalStartDate,
                sequence: orphan.sequence,
                calendarID: importedEvent.calendarID,
                title: orphan.title,
                startDate: orphan.startDate,
                endDate: orphan.endDate,
                isAllDay: orphan.isAllDay,
                availability: orphan.availability,
                status: orphan.status,
                privacy: orphan.privacy,
                importance: orphan.importance,
                categories: orphan.categories,
                reminderOffsets: orphan.reminderOffsets,
                timeZoneIdentifier: orphan.timeZoneIdentifier,
                geoCoordinate: orphan.geoCoordinate,
                organizerName: orphan.organizerName,
                organizerEmail: orphan.organizerEmail,
                attendees: orphan.attendees,
                myResponseStatus: orphan.myResponseStatus,
                location: orphan.location,
                notes: orphan.notes,
                urlString: orphan.urlString,
                remoteObjectURLString: orphan.remoteObjectURLString,
                updatedAt: orphan.updatedAt
            )
            if let detachedIndex = importedEvent.detachedOccurrences.firstIndex(where: {
                $0.originalStartDate.isSameOccurrenceStart(as: occurrence.originalStartDate)
            }) {
                if !shouldPreserveImportedOccurrence(
                    sequence: importedEvent.detachedOccurrences[detachedIndex].sequence,
                    updatedAt: importedEvent.detachedOccurrences[detachedIndex].updatedAt,
                    over: occurrence
                ) {
                    importedEvent.detachedOccurrences[detachedIndex] = occurrence
                }
            } else {
                importedEvent.detachedOccurrences.append(occurrence)
            }
            importedEvent.excludedOccurrenceStartDates.removeAll {
                $0.isSameOccurrenceStart(as: originalStartDate)
            }
            events.remove(at: index)
            removedCount += 1
        }

        return removedCount
    }

    private func orphanOriginalStartDate(_ externalUID: String, baseExternalUID: String) -> Date? {
        let prefix = "\(baseExternalUID)#"
        guard externalUID.hasPrefix(prefix) else { return nil }
        let suffix = String(externalUID.dropFirst(prefix.count))
        guard !suffix.hasPrefix("range-this-and-future-"),
              let seconds = TimeInterval(suffix)
        else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private func handledDetachedOccurrenceUpdateUIDs(_ updates: [LocalICSDetachedOccurrenceUpdate]) -> Set<String> {
        Set(updates.compactMap { update in
            let externalUID = update.externalUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !externalUID.isEmpty,
                  events.contains(where: { $0.isRecurring && event($0, matchesExternalUID: externalUID) })
            else {
                return nil
            }
            return externalUID
        })
    }

    private func shouldSkipImportedEventAfterDetachedOccurrenceUpdate(
        _ event: LocalCalendarEvent,
        handledExternalUIDs: Set<String>
    ) -> Bool {
        let externalUID = event.externalUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !externalUID.isEmpty else { return false }
        if handledExternalUIDs.contains(externalUID) {
            return true
        }

        guard let recurrenceSuffixStart = externalUID.lastIndex(of: "#") else { return false }
        let baseExternalUID = String(externalUID[..<recurrenceSuffixStart])
        return handledExternalUIDs.contains(baseExternalUID)
    }

    private func importIdentityKey(for event: LocalCalendarEvent) -> String {
        let remoteObjectURLString = normalizedRemoteObjectURLString(event.remoteObjectURLString)
        if !remoteObjectURLString.isEmpty {
            let remoteIdentityPrefix = isProviderBackedCalendarID(event.calendarID)
                ? "calendar:\(event.calendarID)|remote:\(remoteObjectURLString)"
                : "remote:\(remoteObjectURLString)"
            if event.isImportedRecurrenceSplitProjection {
                return "\(remoteIdentityPrefix)|uid:\(event.externalUID)"
            }
            return remoteIdentityPrefix
        }

        return "calendar:\(event.calendarID)|uid:\(event.externalUID)"
    }

    private func isSameImportedEvent(_ existingEvent: LocalCalendarEvent, as importedEvent: LocalCalendarEvent) -> Bool {
        let importedRemoteObjectURLString = normalizedRemoteObjectURLString(importedEvent.remoteObjectURLString)
        let existingRemoteObjectURLString = normalizedRemoteObjectURLString(existingEvent.remoteObjectURLString)

        if !importedRemoteObjectURLString.isEmpty {
            if importedEvent.isImportedRecurrenceSplitProjection || existingEvent.isImportedRecurrenceSplitProjection {
                return existingRemoteObjectURLString == importedRemoteObjectURLString
                    && remoteObjectIdentityCanMatch(existingEvent, importedEvent)
                    && existingEvent.externalUID == importedEvent.externalUID
            }
            return existingRemoteObjectURLString == importedRemoteObjectURLString
                    && remoteObjectIdentityCanMatch(existingEvent, importedEvent)
                || eventsShareImportedUIDInSameCalendar(existingEvent, importedEvent)
        }

        if eventsShareImportedUIDInSameCalendar(existingEvent, importedEvent) {
            return true
        }

        guard existingRemoteObjectURLString.isEmpty else { return false }
        return eventsShareImportedUIDWithoutRemoteObject(existingEvent, importedEvent)
    }

    private func shouldPreserveExistingImportedVersion(_ existingEvent: LocalCalendarEvent, over importedEvent: LocalCalendarEvent) -> Bool {
        if shouldPreserveLocalProviderVersion(existingEvent, over: importedEvent) {
            return true
        }

        guard eventsShareImportedUIDWithoutRemoteObject(existingEvent, importedEvent)
            || eventsShareImportedUIDInSameCalendar(existingEvent, importedEvent)
        else {
            return false
        }

        if existingEvent.sequence != importedEvent.sequence {
            return existingEvent.sequence > importedEvent.sequence
        }

        return existingEvent.updatedAt > importedEvent.updatedAt
    }

    private func shouldPreserveLocalProviderVersion(_ existingEvent: LocalCalendarEvent, over importedEvent: LocalCalendarEvent) -> Bool {
        let existingRemoteObjectURLString = normalizedRemoteObjectURLString(existingEvent.remoteObjectURLString)
        let importedRemoteObjectURLString = normalizedRemoteObjectURLString(importedEvent.remoteObjectURLString)
        guard !existingRemoteObjectURLString.isEmpty,
              existingRemoteObjectURLString == importedRemoteObjectURLString
                && remoteObjectIdentityCanMatch(existingEvent, importedEvent)
        else {
            return false
        }

        let existingRemoteETag = existingEvent.remoteETag.trimmingCharacters(in: .whitespacesAndNewlines)
        let importedRemoteETag = importedEvent.remoteETag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existingRemoteETag.isEmpty,
              existingRemoteETag == importedRemoteETag,
              existingEvent.sequence > importedEvent.sequence,
              existingEvent.updatedAt > importedEvent.updatedAt
        else {
            return false
        }

        return true
    }

    private func eventsShareImportedUIDWithoutRemoteObject(_ lhs: LocalCalendarEvent, _ rhs: LocalCalendarEvent) -> Bool {
        guard lhs.remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rhs.remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }

        if isProviderBackedCalendarID(lhs.calendarID) || isProviderBackedCalendarID(rhs.calendarID) {
            return eventsShareImportedUIDInSameCalendar(lhs, rhs)
        }

        return eventsShareImportedUID(lhs, rhs)
    }

    private func eventsShareImportedUIDInSameCalendar(_ lhs: LocalCalendarEvent, _ rhs: LocalCalendarEvent) -> Bool {
        guard !lhs.isImportedRecurrenceSplitProjection,
              !rhs.isImportedRecurrenceSplitProjection,
              lhs.calendarID == rhs.calendarID
        else {
            return false
        }

        return eventsShareImportedUID(lhs, rhs)
    }

    private func eventsShareImportedUID(_ lhs: LocalCalendarEvent, _ rhs: LocalCalendarEvent) -> Bool {
        let lhsUID = lhs.externalUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsUID = rhs.externalUID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !lhsUID.isEmpty && lhsUID == rhsUID
    }

    private func remoteObjectIdentityCanMatch(_ lhs: LocalCalendarEvent, _ rhs: LocalCalendarEvent) -> Bool {
        guard isProviderBackedCalendarID(lhs.calendarID) || isProviderBackedCalendarID(rhs.calendarID) else {
            return true
        }
        return lhs.calendarID == rhs.calendarID
    }

    private func isProviderBackedCalendarID(_ calendarID: String) -> Bool {
        calendarID.hasPrefix("local-calendar-ics-")
            || calendarID.hasPrefix("local-calendar-caldav-")
            || calendarID.hasPrefix("local-calendar-google-")
            || calendarID.hasPrefix("local-calendar-microsoft365-")
    }

    private func preserveLocalProviderRecurrenceChanges(
        from existingEvent: LocalCalendarEvent,
        into importedEvent: inout LocalCalendarEvent
    ) {
        let localResponseOnlyOccurrences = localResponseOnlyDetachedOccurrences(from: existingEvent)
        guard importedEvent.isRecurring,
              existingEvent.hasLocalProviderRecurrenceChanges || !localResponseOnlyOccurrences.isEmpty
        else {
            return
        }

        let providerExcludedOccurrenceStartDates = importedEvent.excludedOccurrenceStartDates
        importedEvent.excludedOccurrenceStartDates = mergedOccurrenceStartDates(
            importedEvent.excludedOccurrenceStartDates,
            existingEvent.excludedOccurrenceStartDates
        )
        let preservedDetachedOccurrences: [LocalDetachedOccurrence]
        if existingEvent.hasLocalProviderRecurrenceChanges {
            preservedDetachedOccurrences = existingEvent.detachedOccurrences.filter { occurrence in
                !providerExcludedOccurrenceStartDates.containsOccurrenceStart(occurrence.originalStartDate)
            }
        } else {
            preservedDetachedOccurrences = localResponseOnlyOccurrences.compactMap { occurrence in
                guard !providerExcludedOccurrenceStartDates.containsOccurrenceStart(occurrence.originalStartDate),
                      !importedEvent.detachedOccurrences.contains(where: {
                          $0.originalStartDate.isSameOccurrenceStart(as: occurrence.originalStartDate)
                      })
                else {
                    return nil
                }

                var responseOccurrence = detachedOccurrence(
                    from: importedEvent,
                    originalStartDate: occurrence.originalStartDate,
                    now: occurrence.updatedAt
                )
                responseOccurrence.sequence = max(responseOccurrence.sequence, occurrence.sequence)
                responseOccurrence.myResponseStatus = occurrence.myResponseStatus
                applyCurrentUserResponseStatus(occurrence.myResponseStatus, to: &responseOccurrence.attendees)
                return responseOccurrence
            }
        }

        importedEvent.detachedOccurrences = mergedDetachedOccurrences(
            importedEvent.detachedOccurrences,
            preservedDetachedOccurrences
        )
        if existingEvent.hasLocalProviderRecurrenceChanges {
            importedEvent.hasLocalProviderRecurrenceChanges = true
            importedEvent.updatedAt = existingEvent.updatedAt
        }
    }

    private func localResponseOnlyDetachedOccurrences(from event: LocalCalendarEvent) -> [LocalDetachedOccurrence] {
        guard event.isRecurring else { return [] }
        return event.detachedOccurrences.filter { occurrence in
            let remoteObjectURLString = normalizedRemoteObjectURLString(occurrence.remoteObjectURLString ?? "")
            return remoteObjectURLString.isEmpty
                && occurrence.myResponseStatus != .notInvited
                && occurrence.myResponseStatus != event.myResponseStatus
        }
    }

    private func preservePartialProviderAttendees(
        from existingEvent: LocalCalendarEvent,
        into importedEvent: inout LocalCalendarEvent
    ) {
        if hasPartialProviderAttendeeList(importedEvent.categories) {
            importedEvent.attendees = mergedPartialProviderAttendees(
                imported: importedEvent.attendees,
                existing: existingEvent.attendees
            )
            if importedEvent.myResponseStatus == .notInvited {
                importedEvent.myResponseStatus = existingEvent.myResponseStatus
            }
        }

        for detachedIndex in importedEvent.detachedOccurrences.indices {
            guard hasPartialProviderAttendeeList(importedEvent.detachedOccurrences[detachedIndex].categories),
                  let existingDetached = existingEvent.detachedOccurrence(
                    for: importedEvent.detachedOccurrences[detachedIndex].originalStartDate
                  )
            else {
                continue
            }

            importedEvent.detachedOccurrences[detachedIndex].attendees = mergedPartialProviderAttendees(
                imported: importedEvent.detachedOccurrences[detachedIndex].attendees,
                existing: existingDetached.attendees
            )
            if importedEvent.detachedOccurrences[detachedIndex].myResponseStatus == .notInvited {
                importedEvent.detachedOccurrences[detachedIndex].myResponseStatus = existingDetached.myResponseStatus
            }
        }
    }

    private func hasPartialProviderAttendeeList(_ categories: [String]) -> Bool {
        categories.contains { category in
            category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "google attendees omitted"
        }
    }

    private func mergedPartialProviderAttendees(
        imported: [LocalEventAttendee],
        existing: [LocalEventAttendee]
    ) -> [LocalEventAttendee] {
        var merged = imported
        var importedEmails = Set(imported.map { normalizedEmail($0.email) }.filter { !$0.isEmpty })
        for attendee in existing where !attendee.isBlank {
            let email = normalizedEmail(attendee.email)
            guard !email.isEmpty,
                  importedEmails.insert(email).inserted
            else {
                continue
            }
            merged.append(attendee)
        }
        return merged
    }

    private func preserveLocallyNewerResponse(
        from existingEvent: LocalCalendarEvent,
        into importedEvent: inout LocalCalendarEvent,
        protectedRemoteObjectURLs: Set<String> = []
    ) {
        guard eventsShareRemoteObject(existingEvent, importedEvent) else { return }
        let shouldProtectLocalResponse = shouldProtectLocalResponse(
            from: existingEvent,
            over: importedEvent,
            protectedRemoteObjectURLs: protectedRemoteObjectURLs
        )

        if shouldPreserveLocallyNewerResponse(
            status: existingEvent.myResponseStatus,
            updatedAt: existingEvent.updatedAt,
            sequence: existingEvent.sequence,
            overStatus: importedEvent.myResponseStatus,
            importedUpdatedAt: importedEvent.updatedAt,
            importedSequence: importedEvent.sequence,
            force: shouldProtectLocalResponse
        ) {
            importedEvent.myResponseStatus = existingEvent.myResponseStatus
            applyCurrentUserResponseStatus(existingEvent.myResponseStatus, to: &importedEvent.attendees)
        }

        for detachedIndex in importedEvent.detachedOccurrences.indices {
            let originalStart = importedEvent.detachedOccurrences[detachedIndex].originalStartDate
            guard let existingDetached = existingEvent.detachedOccurrence(for: originalStart),
                  shouldPreserveLocallyNewerResponse(
                    status: existingDetached.myResponseStatus,
                    updatedAt: existingDetached.updatedAt,
                    sequence: existingDetached.sequence,
                    overStatus: importedEvent.detachedOccurrences[detachedIndex].myResponseStatus,
                    importedUpdatedAt: importedEvent.detachedOccurrences[detachedIndex].updatedAt,
                    importedSequence: importedEvent.detachedOccurrences[detachedIndex].sequence,
                    force: shouldProtectLocalResponse
                  )
            else {
                continue
            }

            importedEvent.detachedOccurrences[detachedIndex].myResponseStatus = existingDetached.myResponseStatus
            applyCurrentUserResponseStatus(existingDetached.myResponseStatus, to: &importedEvent.detachedOccurrences[detachedIndex].attendees)
        }
    }

    private func shouldPreserveLocallyNewerResponse(
        from existingEvent: LocalCalendarEvent,
        over importedEvent: LocalCalendarEvent
    ) -> Bool {
        guard eventsShareRemoteObject(existingEvent, importedEvent) else { return false }

        return shouldPreserveLocallyNewerResponse(
            status: existingEvent.myResponseStatus,
            updatedAt: existingEvent.updatedAt,
            sequence: existingEvent.sequence,
            overStatus: importedEvent.myResponseStatus,
            importedUpdatedAt: importedEvent.updatedAt,
            importedSequence: importedEvent.sequence
        )
    }

    private func shouldProtectLocalResponse(
        from existingEvent: LocalCalendarEvent,
        over importedEvent: LocalCalendarEvent,
        protectedRemoteObjectURLs: Set<String>
    ) -> Bool {
        guard !protectedRemoteObjectURLs.isEmpty,
              eventsShareRemoteObject(existingEvent, importedEvent)
        else {
            return false
        }

        let existingRemoteObjectURLString = normalizedRemoteObjectURLString(existingEvent.remoteObjectURLString)
        let importedRemoteObjectURLString = normalizedRemoteObjectURLString(importedEvent.remoteObjectURLString)
        return (!existingRemoteObjectURLString.isEmpty && protectedRemoteObjectURLs.contains(existingRemoteObjectURLString))
            || (!importedRemoteObjectURLString.isEmpty && protectedRemoteObjectURLs.contains(importedRemoteObjectURLString))
    }

    private func eventsShareRemoteObject(_ lhs: LocalCalendarEvent, _ rhs: LocalCalendarEvent) -> Bool {
        let lhsRemoteObjectURLString = normalizedRemoteObjectURLString(lhs.remoteObjectURLString)
        let rhsRemoteObjectURLString = normalizedRemoteObjectURLString(rhs.remoteObjectURLString)
        if !lhsRemoteObjectURLString.isEmpty,
           lhsRemoteObjectURLString == rhsRemoteObjectURLString,
           remoteObjectIdentityCanMatch(lhs, rhs) {
            return true
        }

        guard !lhsRemoteObjectURLString.isEmpty || !rhsRemoteObjectURLString.isEmpty else { return false }
        return eventsShareImportedUIDInSameCalendar(lhs, rhs)
    }

    private func normalizedRemoteObjectURLString(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed)
        else {
            return trimmed
        }

        if let scheme = components.scheme?.lowercased(), !scheme.isEmpty {
            components.scheme = scheme
            if let host = components.host?.lowercased(), !host.isEmpty {
                components.host = host
            }
            if (scheme == "https" && components.port == 443)
                || (scheme == "http" && components.port == 80) {
                components.port = nil
            }
        }
        components.fragment = nil
        components.percentEncodedPath = normalizedPercentEncodedComponent(components.percentEncodedPath)
        if let query = components.percentEncodedQuery {
            components.percentEncodedQuery = normalizedPercentEncodedComponent(query)
        }

        return components.url?.absoluteString ?? trimmed
    }

    private func normalizedRemoteObjectURLSet(_ values: Set<String>) -> Set<String> {
        Set(values.map { normalizedRemoteObjectURLString($0) }.filter { !$0.isEmpty })
    }

    private func normalizedPercentEncodedComponent(_ value: String) -> String {
        let characters = Array(value)
        var result = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "%",
               index + 2 < characters.count,
               let high = hexValue(characters[index + 1]),
               let low = hexValue(characters[index + 2]) {
                let byte = high * 16 + low
                if let scalar = UnicodeScalar(byte),
                   isURLUnreservedScalar(scalar) {
                    result.unicodeScalars.append(scalar)
                } else {
                    result.append("%")
                    result.append(String(characters[index + 1]).uppercased())
                    result.append(String(characters[index + 2]).uppercased())
                }
                index += 3
            } else {
                result.append(characters[index])
                index += 1
            }
        }
        return result
    }

    private func hexValue(_ character: Character) -> Int? {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1
        else {
            return nil
        }
        switch scalar.value {
        case 48...57:
            return Int(scalar.value - 48)
        case 65...70:
            return Int(scalar.value - 55)
        case 97...102:
            return Int(scalar.value - 87)
        default:
            return nil
        }
    }

    private func isURLUnreservedScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 65...90, 97...122, 48...57:
            return true
        case 45, 46, 95, 126:
            return true
        default:
            return false
        }
    }

    private func shouldPreserveLocallyNewerResponse(
        status: EventResponseStatus,
        updatedAt: Date,
        sequence: Int,
        overStatus importedStatus: EventResponseStatus,
        importedUpdatedAt: Date,
        importedSequence: Int,
        force: Bool = false
    ) -> Bool {
        guard status != .notInvited,
              status != importedStatus
        else {
            return false
        }

        if force {
            return status != .pending
        }

        if status.requiresAttention && importedStatus.isResolvedResponse {
            return false
        }

        if status == .pending && importedStatus != .notInvited {
            return false
        }

        return sequence > importedSequence || updatedAt > importedUpdatedAt
    }

    private func mergedOccurrenceStartDates(_ imported: [Date], _ local: [Date]) -> [Date] {
        var merged = imported
        for date in local where !merged.containsOccurrenceStart(date) {
            merged.append(date)
        }
        return merged.sorted()
    }

    private func mergedDetachedOccurrences(
        _ imported: [LocalDetachedOccurrence],
        _ local: [LocalDetachedOccurrence]
    ) -> [LocalDetachedOccurrence] {
        var merged = imported
        for occurrence in local {
            if let index = merged.firstIndex(where: { $0.originalStartDate.isSameOccurrenceStart(as: occurrence.originalStartDate) }) {
                merged[index] = occurrence
            } else {
                merged.append(occurrence)
            }
        }
        return merged.sorted { $0.originalStartDate < $1.originalStartDate }
    }

    @discardableResult
    private func applyAddedOccurrences(_ additions: [LocalICSAddedOccurrence]) -> Int {
        guard !additions.isEmpty else { return 0 }

        var changedCount = 0
        for addition in additions {
            let externalUID = addition.externalUID.trimmingCharacters(in: .whitespacesAndNewlines)
            let calendarIDHint = addition.calendarIDHint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !externalUID.isEmpty else { continue }

            for index in events.indices {
                guard events[index].isRecurring,
                      event(events[index], matchesExternalUID: externalUID),
                      calendarIDHint.isEmpty || events[index].calendarID == calendarIDHint
                else {
                    continue
                }

                var occurrence = addition.occurrence
                occurrence.calendarID = events[index].calendarID

                if shouldPreserveImportedOccurrence(
                    sequence: events[index].sequence,
                    updatedAt: events[index].updatedAt,
                    over: occurrence
                ) {
                    continue
                }

                var didChange = false
                if !events[index].additionalOccurrenceStartDates.containsOccurrenceStart(addition.occurrenceStartDate) {
                    events[index].additionalOccurrenceStartDates.append(addition.occurrenceStartDate)
                    events[index].additionalOccurrenceStartDates = events[index].additionalOccurrenceStartDates.uniqueOccurrenceStarts.sorted()
                    didChange = true
                }

                if let detachedIndex = events[index].detachedOccurrences.firstIndex(where: {
                    $0.originalStartDate.isSameOccurrenceStart(as: occurrence.originalStartDate)
                }) {
                    if !shouldPreserveImportedOccurrence(
                        sequence: events[index].detachedOccurrences[detachedIndex].sequence,
                        updatedAt: events[index].detachedOccurrences[detachedIndex].updatedAt,
                        over: occurrence
                    ),
                       events[index].detachedOccurrences[detachedIndex] != occurrence {
                        events[index].detachedOccurrences[detachedIndex] = occurrence
                        didChange = true
                    }
                } else {
                    events[index].detachedOccurrences.append(occurrence)
                    didChange = true
                }

                let oldExclusionCount = events[index].excludedOccurrenceStartDates.count
                events[index].excludedOccurrenceStartDates.removeAll {
                    $0.isSameOccurrenceStart(as: addition.occurrenceStartDate)
                }
                if events[index].excludedOccurrenceStartDates.count != oldExclusionCount {
                    didChange = true
                }

                guard didChange else { continue }
                events[index].updatedAt = max(events[index].updatedAt, occurrence.updatedAt)
                changedCount += 1
            }
        }

        return changedCount
    }

    func draft(for date: Date = Date()) -> LocalEventDraft {
        let start = roundedStartDate(for: date)
        let end = Calendar.current.date(byAdding: .minute, value: 30, to: start) ?? start.addingTimeInterval(30 * 60)

        return draft(start: start, end: end, isAllDay: false)
    }

    func draft(start: Date, end: Date, isAllDay: Bool = false) -> LocalEventDraft {
        let calendar = preferredCalendarForNewEvents()
        let safeEnd = max(end, start.addingTimeInterval(isAllDay ? 24 * 3600 : 5 * 60))

        return LocalEventDraft(
            eventID: nil,
            calendarID: calendar.id,
            title: "New event",
            startDate: start,
            endDate: safeEnd,
            isAllDay: isAllDay,
            availability: .busy,
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
            recurrenceFrequency: .none,
            recurrenceInterval: 1,
            recurrenceWeekdays: [],
            recurrenceWeekStart: nil,
            recurrenceSetPositions: [],
            recurrenceMonthDay: nil,
            recurrenceMonths: [],
            recurrenceEndDate: nil,
            hasAdditionalOccurrences: false,
            detachedOriginalStartDate: nil
        )
    }

    func draft(for event: CalendarEvent) -> LocalEventDraft? {
        guard let localEvent = events.first(where: { $0.id == baseEventID(for: event) }) else { return nil }
        return LocalEventDraft(
            eventID: localEvent.id,
            calendarID: localEvent.calendarID,
            title: localEvent.title,
            startDate: localEvent.startDate,
            endDate: localEvent.endDate,
            isAllDay: localEvent.isAllDay,
            availability: localEvent.availability,
            privacy: localEvent.privacy,
            importance: localEvent.importance,
            categories: localEvent.categories,
            reminderOffsets: localEvent.reminderOffsets,
            timeZoneIdentifier: localEvent.timeZoneIdentifier,
            organizerName: localEvent.organizerName,
            organizerEmail: localEvent.organizerEmail,
            attendees: localEvent.attendees,
            myResponseStatus: localEvent.myResponseStatus,
            location: localEvent.location,
            notes: localEvent.notes,
            urlString: localEvent.urlString,
            recurrenceFrequency: localEvent.recurrenceFrequency,
            recurrenceInterval: localEvent.safeRecurrenceInterval,
            recurrenceWeekdays: recurrenceWeekdays(for: localEvent),
            recurrenceWeekStart: localEvent.recurrenceWeekStart,
            recurrenceSetPositions: localEvent.recurrenceSetPositions,
            recurrenceOrdinal: localEvent.recurrenceOrdinal,
            recurrenceOrdinalWeekday: localEvent.recurrenceOrdinalWeekday,
            recurrenceMonthDay: localEvent.recurrenceMonthDay,
            recurrenceMonths: localEvent.recurrenceMonths,
            recurrenceEndDate: localEvent.recurrenceEndDate,
            hasAdditionalOccurrences: !localEvent.additionalOccurrenceStartDates.isEmpty,
            detachedOriginalStartDate: nil
        )
    }

    func occurrenceDraft(for event: CalendarEvent) -> LocalEventDraft? {
        guard let localEvent = events.first(where: { $0.id == baseEventID(for: event) }) else { return nil }
        let originalStartDate = occurrenceStartDate(for: event, in: localEvent)

        if let detached = localEvent.detachedOccurrences.first(where: { $0.originalStartDate.isSameOccurrenceStart(as: originalStartDate) }) {
            return LocalEventDraft(
                eventID: localEvent.id,
                calendarID: detached.calendarID,
                title: detached.title,
                startDate: detached.startDate,
                endDate: detached.endDate,
                isAllDay: detached.isAllDay,
                availability: detached.availability,
                privacy: detached.privacy,
                importance: detached.importance,
                categories: detached.categories,
                reminderOffsets: detached.reminderOffsets,
                timeZoneIdentifier: detached.timeZoneIdentifier,
                organizerName: detached.organizerName,
                organizerEmail: detached.organizerEmail,
                attendees: detached.attendees,
                myResponseStatus: detached.myResponseStatus,
                location: detached.location,
                notes: detached.notes,
                urlString: detached.urlString,
                recurrenceFrequency: .none,
                recurrenceInterval: 1,
                recurrenceWeekdays: [],
                recurrenceWeekStart: nil,
                recurrenceSetPositions: [],
                recurrenceOrdinal: nil,
                recurrenceOrdinalWeekday: nil,
                recurrenceMonthDay: nil,
                recurrenceMonths: [],
                recurrenceEndDate: nil,
                hasAdditionalOccurrences: false,
                detachedOriginalStartDate: originalStartDate
            )
        }

        return LocalEventDraft(
            eventID: localEvent.id,
            calendarID: localEvent.calendarID,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            availability: event.availability,
            privacy: localEvent.privacy,
            importance: localEvent.importance,
            categories: localEvent.categories,
            reminderOffsets: localEvent.reminderOffsets,
            timeZoneIdentifier: localEvent.timeZoneIdentifier,
            organizerName: localEvent.organizerName,
            organizerEmail: localEvent.organizerEmail,
            attendees: localEvent.attendees,
            myResponseStatus: localEvent.myResponseStatus,
            location: event.location ?? "",
            notes: event.notes ?? "",
            urlString: event.url?.absoluteString ?? "",
            recurrenceFrequency: .none,
            recurrenceInterval: 1,
            recurrenceWeekdays: [],
            recurrenceWeekStart: nil,
            recurrenceSetPositions: [],
            recurrenceOrdinal: nil,
            recurrenceOrdinalWeekday: nil,
            recurrenceMonthDay: nil,
            recurrenceMonths: [],
            recurrenceEndDate: nil,
            hasAdditionalOccurrences: false,
            detachedOriginalStartDate: originalStartDate
        )
    }

    func duplicateDraft(for event: CalendarEvent) -> LocalEventDraft? {
        guard let localEvent = events.first(where: { $0.id == baseEventID(for: event) }) else { return nil }

        let duration = max(event.isAllDay ? 24 * 3600 : 5 * 60, event.endDate.timeIntervalSince(event.startDate))
        let copiedStart: Date
        if event.isAllDay {
            copiedStart = Calendar.current.date(byAdding: .day, value: 1, to: event.startDate) ?? event.startDate.addingTimeInterval(24 * 3600)
        } else {
            copiedStart = event.endDate
        }
        let copiedEnd = copiedStart.addingTimeInterval(duration)

        return LocalEventDraft(
            eventID: nil,
            calendarID: event.calendarID,
            title: event.title,
            startDate: copiedStart,
            endDate: copiedEnd,
            isAllDay: event.isAllDay,
            availability: event.availability,
            privacy: localEvent.privacy,
            importance: localEvent.importance,
            categories: localEvent.categories,
            reminderOffsets: localEvent.reminderOffsets,
            timeZoneIdentifier: event.timeZoneIdentifier ?? localEvent.timeZoneIdentifier,
            organizerName: localEvent.organizerName,
            organizerEmail: localEvent.organizerEmail,
            attendees: localEvent.attendees,
            myResponseStatus: localEvent.myResponseStatus,
            location: event.location ?? localEvent.location,
            notes: event.notes ?? localEvent.notes,
            urlString: event.url?.absoluteString ?? localEvent.urlString,
            recurrenceFrequency: .none,
            recurrenceInterval: 1,
            recurrenceWeekdays: [],
            recurrenceWeekStart: nil,
            recurrenceSetPositions: [],
            recurrenceOrdinal: nil,
            recurrenceOrdinalWeekday: nil,
            recurrenceMonthDay: nil,
            recurrenceMonths: [],
            recurrenceEndDate: nil,
            hasAdditionalOccurrences: false,
            detachedOriginalStartDate: nil
        )
    }

    func newCalendarDraft() -> LocalCalendarDraft {
        LocalCalendarDraft(
            calendarID: nil,
            title: "New Calendar",
            colorHex: nextColorHex()
        )
    }

    func draft(for calendar: LocalCalendar) -> LocalCalendarDraft {
        LocalCalendarDraft(
            calendarID: calendar.id,
            title: calendar.title,
            colorHex: calendar.colorHex
        )
    }

    func saveCalendar(_ draft: LocalCalendarDraft) {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Calendar" : draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let colorHex = draft.colorHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nextColorHex() : draft.colorHex

        if let calendarID = draft.calendarID,
           let index = calendars.firstIndex(where: { $0.id == calendarID }) {
            calendars[index].title = title
            calendars[index].colorHex = colorHex
            return
        }

        let calendar = LocalCalendar(
            id: "\(Self.calendarIDPrefix)\(UUID().uuidString)",
            title: title,
            colorHex: colorHex
        )
        calendars.append(calendar)
        selectedCalendarIDs.insert(calendar.id)
    }

    func deleteCalendar(_ calendar: LocalCalendar) {
        guard !isProviderBackedCalendarID(calendar.id) else { return }
        guard calendars.count > 1 else { return }

        let remainingCalendars = calendars.filter { $0.id != calendar.id }
        guard let fallbackCalendar = remainingCalendars.first else { return }

        calendars = remainingCalendars
        events = events.map { event in
            var copy = event
            if copy.calendarID == calendar.id {
                copy.calendarID = fallbackCalendar.id
                copy.sequence += 1
                copy.updatedAt = Date()
            }
            return copy
        }

        selectedCalendarIDs.remove(calendar.id)
        if selectedCalendarIDs.isEmpty {
            selectedCalendarIDs = Set(calendars.map(\.id))
        }
    }

    @discardableResult
    func deleteProviderCalendars(calendarIDPrefix: String) -> (calendarsDeleted: Int, eventsDeleted: Int) {
        let normalizedPrefix = calendarIDPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrefix.isEmpty else { return (0, 0) }

        let removedCalendarIDs = Set(calendars.filter { $0.id.hasPrefix(normalizedPrefix) }.map(\.id))
        return deleteProviderCalendars(calendarIDs: removedCalendarIDs)
    }

    @discardableResult
    func deleteProviderCalendars(calendarIDs: Set<String>) -> (calendarsDeleted: Int, eventsDeleted: Int) {
        let removedCalendarIDs = normalizedCalendarIDSet(calendarIDs)
        guard !removedCalendarIDs.isEmpty else { return (0, 0) }

        return removeProviderCalendars(calendarIDs: removedCalendarIDs)
    }

    @discardableResult
    func pruneProviderCalendars(
        calendarIDPrefix: String,
        keepingCalendarIDs: Set<String>,
        protectingCalendarIDs protectedCalendarIDs: Set<String> = []
    ) -> (calendarsDeleted: Int, eventsDeleted: Int) {
        let normalizedPrefix = calendarIDPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrefix.isEmpty else { return (0, 0) }

        let normalizedKeepIDs = Set(keepingCalendarIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let normalizedProtectedIDs = normalizedCalendarIDSet(protectedCalendarIDs)
        let removedCalendarIDs = Set(calendars.filter { calendar in
            calendar.id.hasPrefix(normalizedPrefix)
                && !normalizedKeepIDs.contains(calendar.id)
                && !normalizedProtectedIDs.contains(calendar.id)
        }.map(\.id))
        return deleteProviderCalendars(calendarIDs: removedCalendarIDs)
    }

    @discardableResult
    func pruneProviderCalendars(
        ownedCalendarIDs: Set<String>,
        keepingCalendarIDs: Set<String>,
        protectingCalendarIDs protectedCalendarIDs: Set<String> = []
    ) -> (calendarsDeleted: Int, eventsDeleted: Int) {
        let normalizedOwnedIDs = normalizedCalendarIDSet(ownedCalendarIDs)
        let normalizedKeepIDs = normalizedCalendarIDSet(keepingCalendarIDs)
        let normalizedProtectedIDs = normalizedCalendarIDSet(protectedCalendarIDs)
        let removedCalendarIDs = normalizedOwnedIDs
            .subtracting(normalizedKeepIDs)
            .subtracting(normalizedProtectedIDs)
        return deleteProviderCalendars(calendarIDs: removedCalendarIDs)
    }

    private func removeProviderCalendars(calendarIDs removedCalendarIDs: Set<String>) -> (calendarsDeleted: Int, eventsDeleted: Int) {
        guard !removedCalendarIDs.isEmpty else { return (0, 0) }

        let existingRemovedCalendarIDs = Set(calendars.filter { removedCalendarIDs.contains($0.id) }.map(\.id))
        guard !existingRemovedCalendarIDs.isEmpty else { return (0, 0) }

        let originalEventCount = events.count
        calendars.removeAll { existingRemovedCalendarIDs.contains($0.id) }
        events.removeAll { existingRemovedCalendarIDs.contains($0.calendarID) }
        selectedCalendarIDs.subtract(existingRemovedCalendarIDs)

        if calendars.isEmpty {
            calendars = [Self.defaultCalendar]
            selectedCalendarIDs = [Self.defaultCalendar.id]
        } else if selectedCalendarIDs.isEmpty {
            selectedCalendarIDs = Set(calendars.map(\.id))
        }

        return (
            calendarsDeleted: existingRemovedCalendarIDs.count,
            eventsDeleted: originalEventCount - events.count
        )
    }

    private func normalizedCalendarIDSet(_ calendarIDs: Set<String>) -> Set<String> {
        Set(calendarIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    func setCalendar(_ calendar: LocalCalendar, enabled: Bool) {
        if enabled {
            selectedCalendarIDs.insert(calendar.id)
        } else {
            selectedCalendarIDs.remove(calendar.id)
        }
    }

    @discardableResult
    func save(_ draft: LocalEventDraft) -> LocalCalendarEvent? {
        let now = Date()
        let normalizedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = normalizedTitle.isEmpty ? "Untitled event" : normalizedTitle
        let safeEndDate = max(draft.endDate, draft.startDate.addingTimeInterval(draft.isAllDay ? 24 * 3600 : 5 * 60))
        let safeRecurrenceInterval = max(1, draft.recurrenceInterval)
        let safeRecurrenceWeekStart = normalizedRecurrenceWeekStart(
            draft.recurrenceWeekStart,
            frequency: draft.recurrenceFrequency
        )
        let safeRecurrenceWeekdays = normalizedRecurrenceWeekdays(
            draft.recurrenceWeekdays,
            frequency: draft.recurrenceFrequency,
            startDate: draft.startDate,
            weekStart: safeRecurrenceWeekStart,
            timeZoneIdentifier: draft.timeZoneIdentifier
        )
        let safeRecurrenceSetPositions = normalizedRecurrenceSetPositions(
            draft.recurrenceSetPositions,
            frequency: draft.recurrenceFrequency
        )
        let safeOrdinalRecurrence = normalizedOrdinalRecurrence(
            draft.recurrenceOrdinal,
            weekday: draft.recurrenceOrdinalWeekday,
            frequency: draft.recurrenceFrequency
        )
        let safeRecurrenceMonthDay = safeOrdinalRecurrence.ordinal == nil
            ? normalizedRecurrenceMonthDay(draft.recurrenceMonthDay, frequency: draft.recurrenceFrequency)
            : nil
        let safeRecurrenceMonths = normalizedRecurrenceMonths(
            draft.recurrenceMonths,
            frequency: draft.recurrenceFrequency
        )
        let safeRecurrenceEndDate = draft.recurrenceFrequency == .none ? nil : draft.recurrenceEndDate
        let safeTimeZoneIdentifier = draft.timeZoneIdentifier.isEmpty ? TimeZone.current.identifier : draft.timeZoneIdentifier
        let safeAttendees = draft.attendees
            .filter { !$0.isBlank }
            .map { attendee in
                LocalEventAttendee(
                    id: attendee.id,
                    name: attendee.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    email: attendee.email.trimmingCharacters(in: .whitespacesAndNewlines),
                    status: attendee.status,
                    type: attendee.normalizedType,
                    role: attendee.normalizedRole,
                    rsvp: attendee.rsvp,
                    isCurrentUser: attendee.isCurrentUser
                )
            }
        let safeResponseStatus = normalizedResponseStatus(draft.myResponseStatus, hasAttendees: !safeAttendees.isEmpty)
        let safeCategories = normalizedEventCategories(draft.categories)
        let safeReminderOffsets = normalizedReminderOffsets(draft.reminderOffsets)
        selectedCalendarIDs.insert(draft.calendarID)

        if let originalStartDate = draft.detachedOriginalStartDate,
           let eventID = draft.eventID,
           let index = events.firstIndex(where: { $0.id == eventID }) {
            let existingGeoCoordinate = events[index].detachedOccurrence(for: originalStartDate)?.geoCoordinate
                ?? events[index].geoCoordinate
            upsertDetachedOccurrence(
                LocalDetachedOccurrence(
                    originalStartDate: originalStartDate,
                    sequence: nextDetachedSequence(originalStartDate: originalStartDate, eventIndex: index),
                    calendarID: draft.calendarID,
                    title: safeTitle,
                    startDate: draft.startDate,
                    endDate: safeEndDate,
                    isAllDay: draft.isAllDay,
                    availability: draft.availability,
                    status: events[index].status,
                    privacy: draft.privacy,
                    importance: draft.importance,
                    categories: safeCategories,
                    reminderOffsets: safeReminderOffsets,
                    timeZoneIdentifier: safeTimeZoneIdentifier,
                    geoCoordinate: existingGeoCoordinate,
                    organizerName: draft.organizerName.trimmingCharacters(in: .whitespacesAndNewlines),
                    organizerEmail: draft.organizerEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                    attendees: safeAttendees,
                    myResponseStatus: safeResponseStatus,
                    location: draft.location,
                    notes: draft.notes,
                    urlString: draft.urlString,
                    updatedAt: now
                ),
                eventIndex: index
            )
            return events[index]
        }

        if let eventID = draft.eventID, let index = events.firstIndex(where: { $0.id == eventID }) {
            events[index].calendarID = draft.calendarID
            events[index].title = safeTitle
            events[index].startDate = draft.startDate
            events[index].endDate = safeEndDate
            events[index].isAllDay = draft.isAllDay
            events[index].availability = draft.availability
            events[index].privacy = draft.privacy
            events[index].importance = draft.importance
            events[index].categories = safeCategories
            events[index].reminderOffsets = safeReminderOffsets
            events[index].timeZoneIdentifier = safeTimeZoneIdentifier
            events[index].organizerName = draft.organizerName.trimmingCharacters(in: .whitespacesAndNewlines)
            events[index].organizerEmail = draft.organizerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            events[index].attendees = safeAttendees
            events[index].myResponseStatus = safeResponseStatus
            events[index].location = draft.location
            events[index].notes = draft.notes
            events[index].urlString = draft.urlString
            events[index].recurrenceFrequency = draft.recurrenceFrequency
            events[index].recurrenceInterval = safeRecurrenceInterval
            events[index].recurrenceWeekdays = safeRecurrenceWeekdays
            events[index].recurrenceWeekStart = safeRecurrenceWeekStart
            events[index].recurrenceSetPositions = safeRecurrenceSetPositions
            events[index].recurrenceOrdinal = safeOrdinalRecurrence.ordinal
            events[index].recurrenceOrdinalWeekday = safeOrdinalRecurrence.weekday
            events[index].recurrenceMonthDay = safeRecurrenceMonthDay
            events[index].recurrenceMonths = safeRecurrenceMonths
            events[index].recurrenceEndDate = safeRecurrenceEndDate
            if draft.recurrenceFrequency == .none {
                events[index].recurrenceWeekdays = []
                events[index].recurrenceWeekStart = nil
                events[index].recurrenceSetPositions = []
                events[index].recurrenceOrdinal = nil
                events[index].recurrenceOrdinalWeekday = nil
                events[index].recurrenceMonthDay = nil
                events[index].recurrenceMonths = []
                if !draft.hasAdditionalOccurrences {
                    events[index].additionalOccurrenceStartDates = []
                    events[index].excludedOccurrenceStartDates = []
                    events[index].detachedOccurrences = []
                    events[index].hasLocalProviderRecurrenceChanges = false
                }
            }
            bumpEventRevision(at: index, now: now)
            return events[index]
        }

        let eventID = "\(Self.eventIDPrefix)\(UUID().uuidString)"
        let event = LocalCalendarEvent(
            id: eventID,
            calendarID: draft.calendarID,
            title: safeTitle,
            startDate: draft.startDate,
            endDate: safeEndDate,
            isAllDay: draft.isAllDay,
            availability: draft.availability,
            status: .confirmed,
            privacy: draft.privacy,
            importance: draft.importance,
            categories: safeCategories,
            reminderOffsets: safeReminderOffsets,
            timeZoneIdentifier: safeTimeZoneIdentifier,
            organizerName: draft.organizerName.trimmingCharacters(in: .whitespacesAndNewlines),
            organizerEmail: draft.organizerEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            attendees: safeAttendees,
            myResponseStatus: safeResponseStatus,
            location: draft.location,
            notes: draft.notes,
            urlString: draft.urlString,
            recurrenceFrequency: draft.recurrenceFrequency,
            recurrenceInterval: safeRecurrenceInterval,
            recurrenceWeekdays: safeRecurrenceWeekdays,
            recurrenceWeekStart: safeRecurrenceWeekStart,
            recurrenceSetPositions: safeRecurrenceSetPositions,
            recurrenceOrdinal: safeOrdinalRecurrence.ordinal,
            recurrenceOrdinalWeekday: safeOrdinalRecurrence.weekday,
            recurrenceMonthDay: safeRecurrenceMonthDay,
            recurrenceMonths: safeRecurrenceMonths,
            recurrenceEndDate: safeRecurrenceEndDate,
            createdAt: now,
            updatedAt: now
        )
        events.append(event)
        return event
    }

    func localEvent(for event: CalendarEvent) -> LocalCalendarEvent? {
        events.first { $0.id == baseEventID(for: event) }
    }

    func localEvent(withID eventID: String) -> LocalCalendarEvent? {
        events.first { $0.id == eventID }
    }

    func calendar(withID calendarID: String) -> LocalCalendar? {
        calendars.first { $0.id == calendarID }
    }

    func setRemoteObjectURL(
        eventID: String,
        remoteObjectURLString: String,
        remoteETag: String? = nil,
        clearsLocalProviderRecurrenceChanges: Bool = true
    ) {
        guard let index = events.firstIndex(where: { $0.id == eventID }) else { return }
        events[index].remoteObjectURLString = normalizedRemoteObjectURLString(remoteObjectURLString)
        if let remoteETag {
            events[index].remoteETag = remoteETag.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if clearsLocalProviderRecurrenceChanges {
            events[index].hasLocalProviderRecurrenceChanges = false
        }
    }

    func clearRemoteBinding(eventID: String, clearsLocalProviderRecurrenceChanges: Bool = false) {
        guard let index = events.firstIndex(where: { $0.id == eventID }) else { return }
        events[index].remoteObjectURLString = ""
        events[index].remoteETag = ""
        if clearsLocalProviderRecurrenceChanges {
            events[index].hasLocalProviderRecurrenceChanges = false
        }
    }

    func clearLocalProviderRecurrenceChanges(eventID: String) {
        guard let index = events.firstIndex(where: { $0.id == eventID }) else { return }
        events[index].hasLocalProviderRecurrenceChanges = false
    }

    @discardableResult
    func pruneProviderEvents(
        calendarIDPrefix: String,
        keepingRemoteObjectURLs remoteObjectURLs: Set<String>,
        pruneRange: DateInterval? = nil,
        protectingRemoteObjectURLs protectedRemoteObjectURLs: Set<String> = []
    ) -> Int {
        let normalizedPrefix = calendarIDPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrefix.isEmpty else { return 0 }
        return pruneProviderEvents(
            shouldIncludeCalendarID: { $0.hasPrefix(normalizedPrefix) },
            keepingRemoteObjectURLs: remoteObjectURLs,
            pruneRange: pruneRange,
            protectingRemoteObjectURLs: protectedRemoteObjectURLs
        )
    }

    @discardableResult
    func pruneProviderEvents(
        calendarID: String,
        keepingRemoteObjectURLs remoteObjectURLs: Set<String>,
        pruneRange: DateInterval? = nil,
        protectingRemoteObjectURLs protectedRemoteObjectURLs: Set<String> = []
    ) -> Int {
        let normalizedCalendarID = calendarID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCalendarID.isEmpty else { return 0 }
        return pruneProviderEvents(
            shouldIncludeCalendarID: { $0 == normalizedCalendarID },
            keepingRemoteObjectURLs: remoteObjectURLs,
            pruneRange: pruneRange,
            protectingRemoteObjectURLs: protectedRemoteObjectURLs
        )
    }

    @discardableResult
    func pruneProviderEvents(
        calendarIDs: Set<String>,
        keepingRemoteObjectURLs remoteObjectURLs: Set<String>,
        pruneRange: DateInterval? = nil,
        protectingRemoteObjectURLs protectedRemoteObjectURLs: Set<String> = []
    ) -> Int {
        let normalizedCalendarIDs = normalizedCalendarIDSet(calendarIDs)
        guard !normalizedCalendarIDs.isEmpty else { return 0 }
        return pruneProviderEvents(
            shouldIncludeCalendarID: { normalizedCalendarIDs.contains($0) },
            keepingRemoteObjectURLs: remoteObjectURLs,
            pruneRange: pruneRange,
            protectingRemoteObjectURLs: protectedRemoteObjectURLs
        )
    }

    @discardableResult
    private func pruneProviderEvents(
        shouldIncludeCalendarID: (String) -> Bool,
        keepingRemoteObjectURLs remoteObjectURLs: Set<String>,
        pruneRange: DateInterval?,
        protectingRemoteObjectURLs protectedRemoteObjectURLs: Set<String>
    ) -> Int {
        let normalizedRemoteObjectURLs = normalizedRemoteObjectURLSet(remoteObjectURLs)
        let normalizedProtectedRemoteObjectURLs = normalizedRemoteObjectURLSet(protectedRemoteObjectURLs)
        var removedCount = 0
        let originalCount = events.count

        events.removeAll { event in
            let remoteObjectURLString = normalizedRemoteObjectURLString(event.remoteObjectURLString)
            return shouldIncludeCalendarID(event.calendarID)
                && !remoteObjectURLString.isEmpty
                && shouldPruneProviderEvent(event, in: pruneRange)
                && !normalizedRemoteObjectURLs.contains(remoteObjectURLString)
                && !normalizedProtectedRemoteObjectURLs.contains(remoteObjectURLString)
        }

        removedCount += originalCount - events.count
        let now = Date()

        for index in events.indices {
            guard shouldIncludeCalendarID(events[index].calendarID),
                  events[index].isRecurring
            else {
                continue
            }

            let originalDetachedCount = events[index].detachedOccurrences.count
            events[index].detachedOccurrences.removeAll { occurrence in
                let remoteObjectURLString = normalizedRemoteObjectURLString(occurrence.remoteObjectURLString ?? "")
                return !remoteObjectURLString.isEmpty
                    && shouldPruneProviderDetachedOccurrence(occurrence, in: pruneRange)
                    && !normalizedRemoteObjectURLs.contains(remoteObjectURLString)
                    && !normalizedProtectedRemoteObjectURLs.contains(remoteObjectURLString)
            }

            let removedDetachedCount = originalDetachedCount - events[index].detachedOccurrences.count
            if removedDetachedCount > 0 {
                removedCount += removedDetachedCount
                events[index].updatedAt = now
            }
        }

        return removedCount
    }

    @discardableResult
    func removeProviderEvents(remoteObjectURLs: Set<String>) -> Int {
        removeProviderEvents(remoteObjectURLs: remoteObjectURLs, protectingRemoteObjectURLs: []) { _ in true }
    }

    @discardableResult
    func removeProviderEvents(
        remoteObjectURLs: Set<String>,
        calendarIDPrefix: String,
        protectingRemoteObjectURLs protectedRemoteObjectURLs: Set<String> = []
    ) -> Int {
        let normalizedPrefix = calendarIDPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrefix.isEmpty else { return 0 }
        return removeProviderEvents(
            remoteObjectURLs: remoteObjectURLs,
            protectingRemoteObjectURLs: protectedRemoteObjectURLs
        ) { $0.hasPrefix(normalizedPrefix) }
    }

    @discardableResult
    func removeProviderEvents(
        remoteObjectURLs: Set<String>,
        calendarIDs: Set<String>,
        protectingRemoteObjectURLs protectedRemoteObjectURLs: Set<String> = []
    ) -> Int {
        let normalizedCalendarIDs = normalizedCalendarIDSet(calendarIDs)
        guard !normalizedCalendarIDs.isEmpty else { return 0 }
        return removeProviderEvents(
            remoteObjectURLs: remoteObjectURLs,
            protectingRemoteObjectURLs: protectedRemoteObjectURLs
        ) { normalizedCalendarIDs.contains($0) }
    }

    @discardableResult
    private func removeProviderEvents(
        remoteObjectURLs: Set<String>,
        protectingRemoteObjectURLs protectedRemoteObjectURLs: Set<String>,
        shouldIncludeCalendarID: (String) -> Bool
    ) -> Int {
        let normalizedRemoteObjectURLs = normalizedRemoteObjectURLSet(remoteObjectURLs)
        guard !normalizedRemoteObjectURLs.isEmpty else { return 0 }
        let normalizedProtectedRemoteObjectURLs = normalizedRemoteObjectURLSet(protectedRemoteObjectURLs)

        var removedCount = 0
        let originalCount = events.count
        events.removeAll { event in
            let remoteObjectURLString = normalizedRemoteObjectURLString(event.remoteObjectURLString)
            return shouldIncludeCalendarID(event.calendarID)
                && normalizedRemoteObjectURLs.contains(remoteObjectURLString)
                && !normalizedProtectedRemoteObjectURLs.contains(remoteObjectURLString)
        }
        removedCount += originalCount - events.count
        let now = Date()

        for index in events.indices {
            guard shouldIncludeCalendarID(events[index].calendarID),
                  events[index].isRecurring
            else { continue }

            let originalDetachedCount = events[index].detachedOccurrences.count
            events[index].detachedOccurrences.removeAll { occurrence in
                let remoteObjectURLString = normalizedRemoteObjectURLString(occurrence.remoteObjectURLString ?? "")
                return normalizedRemoteObjectURLs.contains(remoteObjectURLString)
                    && !normalizedProtectedRemoteObjectURLs.contains(remoteObjectURLString)
            }

            let removedDetachedCount = originalDetachedCount - events[index].detachedOccurrences.count
            if removedDetachedCount > 0 {
                removedCount += removedDetachedCount
                events[index].updatedAt = now
            }
        }

        return removedCount
    }

    @discardableResult
    func cancelProviderDetachedOccurrences(remoteObjectURLs: Set<String>) -> Int {
        cancelProviderDetachedOccurrences(
            remoteObjectURLs: remoteObjectURLs,
            protectingRemoteObjectURLs: []
        ) { _ in true }
    }

    @discardableResult
    func cancelProviderDetachedOccurrences(
        remoteObjectURLs: Set<String>,
        calendarIDs: Set<String>,
        protectingRemoteObjectURLs protectedRemoteObjectURLs: Set<String> = []
    ) -> Int {
        let normalizedCalendarIDs = normalizedCalendarIDSet(calendarIDs)
        guard !normalizedCalendarIDs.isEmpty else { return 0 }
        return cancelProviderDetachedOccurrences(
            remoteObjectURLs: remoteObjectURLs,
            protectingRemoteObjectURLs: protectedRemoteObjectURLs
        ) { normalizedCalendarIDs.contains($0) }
    }

    @discardableResult
    private func cancelProviderDetachedOccurrences(
        remoteObjectURLs: Set<String>,
        protectingRemoteObjectURLs protectedRemoteObjectURLs: Set<String>,
        shouldIncludeCalendarID: (String) -> Bool
    ) -> Int {
        let normalizedRemoteObjectURLs = normalizedRemoteObjectURLSet(remoteObjectURLs)
        guard !normalizedRemoteObjectURLs.isEmpty else { return 0 }
        let normalizedProtectedRemoteObjectURLs = normalizedRemoteObjectURLSet(protectedRemoteObjectURLs)

        var cancelledCount = 0
        let now = Date()

        for index in events.indices {
            guard shouldIncludeCalendarID(events[index].calendarID),
                  events[index].isRecurring
            else { continue }

            let cancelledOriginalStarts = events[index].detachedOccurrences.compactMap { occurrence -> Date? in
                let remoteObjectURLString = normalizedRemoteObjectURLString(occurrence.remoteObjectURLString ?? "")
                guard normalizedRemoteObjectURLs.contains(remoteObjectURLString),
                      !normalizedProtectedRemoteObjectURLs.contains(remoteObjectURLString)
                else { return nil }
                return occurrence.originalStartDate
            }
            guard !cancelledOriginalStarts.isEmpty else { continue }

            events[index].detachedOccurrences.removeAll { occurrence in
                let remoteObjectURLString = normalizedRemoteObjectURLString(occurrence.remoteObjectURLString ?? "")
                return normalizedRemoteObjectURLs.contains(remoteObjectURLString)
                    && !normalizedProtectedRemoteObjectURLs.contains(remoteObjectURLString)
            }

            for originalStartDate in cancelledOriginalStarts {
                if !events[index].excludedOccurrenceStartDates.containsOccurrenceStart(originalStartDate) {
                    events[index].excludedOccurrenceStartDates.append(originalStartDate)
                }
            }

            events[index].updatedAt = now
            cancelledCount += cancelledOriginalStarts.count
        }

        return cancelledCount
    }

    @discardableResult
    func cancelProviderRemoteOccurrences(_ cancellations: Set<LocalProviderRemoteOccurrenceCancellation>) -> Int {
        cancelProviderRemoteOccurrences(
            cancellations,
            protectingRemoteObjectURLs: []
        ) { _ in true }
    }

    @discardableResult
    func cancelProviderRemoteOccurrences(
        _ cancellations: Set<LocalProviderRemoteOccurrenceCancellation>,
        calendarIDs: Set<String>,
        protectingRemoteObjectURLs protectedRemoteObjectURLs: Set<String> = []
    ) -> Int {
        let normalizedCalendarIDs = normalizedCalendarIDSet(calendarIDs)
        guard !normalizedCalendarIDs.isEmpty else { return 0 }
        return cancelProviderRemoteOccurrences(
            cancellations,
            protectingRemoteObjectURLs: protectedRemoteObjectURLs
        ) { normalizedCalendarIDs.contains($0) }
    }

    @discardableResult
    private func cancelProviderRemoteOccurrences(
        _ cancellations: Set<LocalProviderRemoteOccurrenceCancellation>,
        protectingRemoteObjectURLs protectedRemoteObjectURLs: Set<String>,
        shouldIncludeCalendarID: (String) -> Bool
    ) -> Int {
        let normalizedCancellations = cancellations.compactMap { cancellation -> (masterRemoteObjectURLString: String, occurrenceStartDate: Date)? in
            let masterRemoteObjectURLString = normalizedRemoteObjectURLString(cancellation.masterRemoteObjectURLString)
            guard !masterRemoteObjectURLString.isEmpty else { return nil }
            return (masterRemoteObjectURLString, cancellation.occurrenceStartDate)
        }
        guard !normalizedCancellations.isEmpty else { return 0 }
        let normalizedProtectedRemoteObjectURLs = normalizedRemoteObjectURLSet(protectedRemoteObjectURLs)

        var changedCount = 0
        let now = Date()

        for cancellation in normalizedCancellations {
            for index in events.indices {
                let eventRemoteObjectURLString = normalizedRemoteObjectURLString(events[index].remoteObjectURLString)
                guard events[index].isRecurring,
                      shouldIncludeCalendarID(events[index].calendarID),
                      eventRemoteObjectURLString == cancellation.masterRemoteObjectURLString,
                      !normalizedProtectedRemoteObjectURLs.contains(eventRemoteObjectURLString),
                      !hasProtectedDetachedOccurrence(
                        in: events[index],
                        originalStartDate: cancellation.occurrenceStartDate,
                        protectedRemoteObjectURLs: normalizedProtectedRemoteObjectURLs
                      )
                else {
                    continue
                }

                var didChange = false
                if !events[index].excludedOccurrenceStartDates.containsOccurrenceStart(
                    cancellation.occurrenceStartDate,
                    isAllDay: events[index].isAllDay
                ) {
                    events[index].excludedOccurrenceStartDates.append(cancellation.occurrenceStartDate)
                    didChange = true
                }

                let detachedCount = events[index].detachedOccurrences.count
                events[index].detachedOccurrences.removeAll {
                    $0.originalStartDate.isSameOccurrenceStart(
                        as: cancellation.occurrenceStartDate,
                        isAllDay: events[index].isAllDay
                    )
                }
                if events[index].detachedOccurrences.count != detachedCount {
                    didChange = true
                }

                if didChange {
                    events[index].updatedAt = now
                    changedCount += 1
                }
            }
        }

        return changedCount
    }

    private func hasProtectedRemoteObject(
        in event: LocalCalendarEvent,
        protectedRemoteObjectURLs: Set<String>
    ) -> Bool {
        hasProtectedMasterRemoteObject(in: event, protectedRemoteObjectURLs: protectedRemoteObjectURLs)
            || event.detachedOccurrences.contains { occurrence in
                protectedRemoteObjectURLs.contains(
                    normalizedRemoteObjectURLString(occurrence.remoteObjectURLString ?? "")
                )
            }
    }

    private func hasProtectedMasterRemoteObject(
        in event: LocalCalendarEvent,
        protectedRemoteObjectURLs: Set<String>
    ) -> Bool {
        protectedRemoteObjectURLs.contains(normalizedRemoteObjectURLString(event.remoteObjectURLString))
    }

    private func hasProtectedDetachedOccurrence(
        in event: LocalCalendarEvent,
        originalStartDate: Date,
        protectedRemoteObjectURLs: Set<String>
    ) -> Bool {
        event.detachedOccurrences.contains { occurrence in
            occurrence.originalStartDate.isSameOccurrenceStart(
                as: originalStartDate,
                isAllDay: event.isAllDay
            ) && protectedRemoteObjectURLs.contains(
                normalizedRemoteObjectURLString(occurrence.remoteObjectURLString ?? "")
            )
        }
    }

    @discardableResult
    private func hasProtectedDetachedOccurrenceAtOrAfter(
        in event: LocalCalendarEvent,
        originalStartDate: Date,
        protectedRemoteObjectURLs: Set<String>
    ) -> Bool {
        event.detachedOccurrences.contains { occurrence in
            (occurrence.originalStartDate >= originalStartDate
                || occurrence.originalStartDate.isSameOccurrenceStart(
                    as: originalStartDate,
                    isAllDay: event.isAllDay
                ))
                && protectedRemoteObjectURLs.contains(
                    normalizedRemoteObjectURLString(occurrence.remoteObjectURLString ?? "")
                )
        }
    }

    @discardableResult
    func removeEvents(
        externalUIDs: Set<String>,
        calendarIDPrefix: String = "",
        protectingRemoteObjectURLs protectedRemoteObjectURLs: Set<String> = []
    ) -> Int {
        let normalizedExternalUIDs = Set(externalUIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        let normalizedPrefix = calendarIDPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedExternalUIDs.isEmpty else { return 0 }
        return removeEvents(
            externalUIDs: normalizedExternalUIDs,
            protectingRemoteObjectURLs: protectedRemoteObjectURLs,
            shouldIncludeCalendarID: { normalizedPrefix.isEmpty || $0.hasPrefix(normalizedPrefix) }
        )
    }

    @discardableResult
    func removeEvents(
        externalUIDs: Set<String>,
        calendarIDs: Set<String>,
        protectingRemoteObjectURLs protectedRemoteObjectURLs: Set<String> = []
    ) -> Int {
        let normalizedExternalUIDs = Set(externalUIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        let normalizedCalendarIDs = normalizedCalendarIDSet(calendarIDs)
        guard !normalizedExternalUIDs.isEmpty, !normalizedCalendarIDs.isEmpty else { return 0 }
        return removeEvents(
            externalUIDs: normalizedExternalUIDs,
            protectingRemoteObjectURLs: protectedRemoteObjectURLs,
            shouldIncludeCalendarID: { normalizedCalendarIDs.contains($0) }
        )
    }

    @discardableResult
    private func removeEvents(
        externalUIDs normalizedExternalUIDs: Set<String>,
        protectingRemoteObjectURLs protectedRemoteObjectURLs: Set<String>,
        shouldIncludeCalendarID: (String) -> Bool
    ) -> Int {
        let normalizedProtectedRemoteObjectURLs = normalizedRemoteObjectURLSet(protectedRemoteObjectURLs)
        let originalCount = events.count
        events.removeAll { event in
            shouldIncludeCalendarID(event.calendarID)
                && !hasProtectedRemoteObject(
                    in: event,
                    protectedRemoteObjectURLs: normalizedProtectedRemoteObjectURLs
                )
                && normalizedExternalUIDs.contains { externalUID in
                    self.event(event, matchesExternalUID: externalUID)
                }
        }
        return originalCount - events.count
    }

    @discardableResult
    func cancelProviderOccurrences(
        calendarIDPrefix: String,
        cancellations: Set<LocalProviderOccurrenceCancellation>,
        protectingRemoteObjectURLs protectedRemoteObjectURLs: Set<String> = []
    ) -> Int {
        let normalizedPrefix = calendarIDPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrefix.isEmpty else { return 0 }
        return cancelOccurrences(
            cancellations: cancellations,
            protectingRemoteObjectURLs: protectedRemoteObjectURLs,
            shouldIncludeCalendarID: { $0.hasPrefix(normalizedPrefix) }
        )
    }

    @discardableResult
    func cancelProviderOccurrences(
        calendarIDs: Set<String>,
        cancellations: Set<LocalProviderOccurrenceCancellation>,
        protectingRemoteObjectURLs protectedRemoteObjectURLs: Set<String> = []
    ) -> Int {
        let normalizedCalendarIDs = normalizedCalendarIDSet(calendarIDs)
        guard !normalizedCalendarIDs.isEmpty else { return 0 }
        return cancelOccurrences(
            cancellations: cancellations,
            protectingRemoteObjectURLs: protectedRemoteObjectURLs,
            shouldIncludeCalendarID: { normalizedCalendarIDs.contains($0) }
        )
    }

    @discardableResult
    func cancelOccurrences(
        calendarIDPrefix: String = "",
        cancellations: Set<LocalProviderOccurrenceCancellation>
    ) -> Int {
        let normalizedPrefix = calendarIDPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return cancelOccurrences(
            cancellations: cancellations,
            protectingRemoteObjectURLs: [],
            shouldIncludeCalendarID: { normalizedPrefix.isEmpty || $0.hasPrefix(normalizedPrefix) }
        )
    }

    @discardableResult
    private func cancelOccurrences(
        cancellations: Set<LocalProviderOccurrenceCancellation>,
        protectingRemoteObjectURLs protectedRemoteObjectURLs: Set<String>,
        shouldIncludeCalendarID: (String) -> Bool
    ) -> Int {
        guard !cancellations.isEmpty else { return 0 }
        let normalizedProtectedRemoteObjectURLs = normalizedRemoteObjectURLSet(protectedRemoteObjectURLs)

        var changedCount = 0
        let now = Date()

        for cancellation in cancellations {
            let externalUID = cancellation.externalUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !externalUID.isEmpty else { continue }

            for index in events.indices.reversed() {
                guard shouldIncludeCalendarID(events[index].calendarID),
                      events[index].isRecurring,
                      event(events[index], matchesExternalUID: externalUID),
                      !hasProtectedMasterRemoteObject(
                        in: events[index],
                        protectedRemoteObjectURLs: normalizedProtectedRemoteObjectURLs
                      )
                else {
                    continue
                }

                if cancellation.appliesToFutureOccurrences {
                    guard !hasProtectedDetachedOccurrenceAtOrAfter(
                        in: events[index],
                        originalStartDate: cancellation.occurrenceStartDate,
                        protectedRemoteObjectURLs: normalizedProtectedRemoteObjectURLs
                    ) else {
                        continue
                    }
                    if truncateImportedSeries(at: cancellation.occurrenceStartDate, eventIndex: index, now: now) {
                        changedCount += 1
                    }
                    continue
                }

                guard !hasProtectedDetachedOccurrence(
                    in: events[index],
                    originalStartDate: cancellation.occurrenceStartDate,
                    protectedRemoteObjectURLs: normalizedProtectedRemoteObjectURLs
                ) else {
                    continue
                }

                var didChange = false
                if !events[index].excludedOccurrenceStartDates.containsOccurrenceStart(
                    cancellation.occurrenceStartDate,
                    isAllDay: events[index].isAllDay
                ) {
                    events[index].excludedOccurrenceStartDates.append(cancellation.occurrenceStartDate)
                    didChange = true
                }

                let detachedCount = events[index].detachedOccurrences.count
                events[index].detachedOccurrences.removeAll {
                    $0.originalStartDate.isSameOccurrenceStart(
                        as: cancellation.occurrenceStartDate,
                        isAllDay: events[index].isAllDay
                    )
                }
                if events[index].detachedOccurrences.count != detachedCount {
                    didChange = true
                }

                if didChange {
                    events[index].updatedAt = now
                    changedCount += 1
                }
            }
        }

        return changedCount
    }

    private func truncateImportedSeries(at occurrenceStart: Date, eventIndex: Int, now: Date) -> Bool {
        guard events.indices.contains(eventIndex) else { return false }

        if occurrenceStart <= events[eventIndex].startDate {
            events.remove(at: eventIndex)
            return true
        }

        let calendar = recurrenceCalendar(for: events[eventIndex])
        let occurrenceDayStart = calendar.startOfDay(for: occurrenceStart)
        guard let previousDay = calendar.date(byAdding: .day, value: -1, to: occurrenceDayStart) else {
            events.remove(at: eventIndex)
            return true
        }

        var didChange = false
        if events[eventIndex].recurrenceEndDate.map({ $0 > previousDay }) ?? true {
            events[eventIndex].recurrenceEndDate = previousDay
            didChange = true
        }

        let excludedCount = events[eventIndex].excludedOccurrenceStartDates.count
        events[eventIndex].excludedOccurrenceStartDates.removeAll { $0 >= occurrenceStart }
        if events[eventIndex].excludedOccurrenceStartDates.count != excludedCount {
            didChange = true
        }

        let detachedCount = events[eventIndex].detachedOccurrences.count
        events[eventIndex].detachedOccurrences.removeAll { $0.originalStartDate >= occurrenceStart }
        if events[eventIndex].detachedOccurrences.count != detachedCount {
            didChange = true
        }

        if didChange {
            events[eventIndex].updatedAt = now
        }
        return didChange
    }

    @discardableResult
    func applyReplies(_ replies: [LocalICSReply]) -> Int {
        applyReplies(replies, shouldIncludeCalendarID: { _ in true })
    }

    @discardableResult
    func applyReplies(_ replies: [LocalICSReply], calendarIDs: Set<String>) -> Int {
        let normalizedCalendarIDs = normalizedCalendarIDSet(calendarIDs)
        guard !normalizedCalendarIDs.isEmpty else { return 0 }
        return applyReplies(
            replies,
            shouldIncludeCalendarID: { normalizedCalendarIDs.contains($0) }
        )
    }

    @discardableResult
    func applyReplies(_ replies: [LocalICSReply], calendarIDPrefix: String) -> Int {
        let normalizedPrefix = calendarIDPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrefix.isEmpty else { return 0 }
        return applyReplies(
            replies,
            shouldIncludeCalendarID: { $0.hasPrefix(normalizedPrefix) }
        )
    }

    @discardableResult
    private func applyReplies(_ replies: [LocalICSReply], shouldIncludeCalendarID: (String) -> Bool) -> Int {
        guard !replies.isEmpty else { return 0 }

        var changedCount = 0
        let now = Date()

        for reply in replies {
            let externalUID = reply.externalUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !externalUID.isEmpty, !reply.attendees.isEmpty else { continue }

            for index in events.indices {
                guard shouldIncludeCalendarID(events[index].calendarID),
                      event(events[index], matchesExternalUID: externalUID)
                else { continue }

                let didChange: Bool
                if let occurrenceStartDate = reply.occurrenceStartDate {
                    didChange = applyReplyAttendees(
                        reply.attendees,
                        toDetachedOccurrenceStartingAt: occurrenceStartDate,
                        eventIndex: index,
                        now: now
                    )
                } else {
                    var event = events[index]
                    didChange = applyReplyAttendees(
                        reply.attendees,
                        to: &event.attendees,
                        myResponseStatus: &event.myResponseStatus
                    )
                    if didChange {
                        events[index] = event
                    }
                }

                if didChange {
                    events[index].updatedAt = now
                    changedCount += 1
                }
            }
        }

        return changedCount
    }

    private func applyReplyAttendees(
        _ replyAttendees: [LocalEventAttendee],
        toDetachedOccurrenceStartingAt occurrenceStartDate: Date,
        eventIndex: Int,
        now: Date
    ) -> Bool {
        guard events.indices.contains(eventIndex) else { return false }

        if let detachedIndex = events[eventIndex].detachedOccurrences.firstIndex(where: {
            $0.originalStartDate.isSameOccurrenceStart(as: occurrenceStartDate)
        }) {
            var detached = events[eventIndex].detachedOccurrences[detachedIndex]
            let didChange = applyReplyAttendees(
                replyAttendees,
                to: &detached.attendees,
                myResponseStatus: &detached.myResponseStatus
            )
            if didChange {
                events[eventIndex].detachedOccurrences[detachedIndex] = detached
            }
            return didChange
        }

        guard events[eventIndex].isRecurring,
              !events[eventIndex].isOccurrenceExcluded(occurrenceStartDate),
              event(events[eventIndex], canContainOccurrenceStart: occurrenceStartDate)
        else {
            guard occurrenceStartDate.isSameOccurrenceStart(as: events[eventIndex].startDate) else {
                return false
            }
            var event = events[eventIndex]
            let didChange = applyReplyAttendees(
                replyAttendees,
                to: &event.attendees,
                myResponseStatus: &event.myResponseStatus
            )
            if didChange {
                events[eventIndex] = event
            }
            return didChange
        }

        var detached = detachedOccurrence(
            from: events[eventIndex],
            originalStartDate: occurrenceStartDate,
            now: now
        )
        guard applyReplyAttendees(
            replyAttendees,
            to: &detached.attendees,
            myResponseStatus: &detached.myResponseStatus
        ) else {
            return false
        }
        events[eventIndex].detachedOccurrences.append(detached)
        return true
    }

    private func applyReplyAttendees(
        _ replyAttendees: [LocalEventAttendee],
        to attendees: inout [LocalEventAttendee],
        myResponseStatus: inout EventResponseStatus
    ) -> Bool {
        var didChange = false

        for replyAttendee in replyAttendees {
            let replyEmail = normalizedEmail(replyAttendee.email)
            guard !replyEmail.isEmpty else { continue }

            if let index = attendees.firstIndex(where: { normalizedEmail($0.email) == replyEmail }) {
                var updatedAttendee = attendees[index]
                let replyName = replyAttendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !replyName.isEmpty {
                    updatedAttendee.name = replyAttendee.name
                }
                updatedAttendee.email = replyEmail
                updatedAttendee.status = replyAttendee.status
                updatedAttendee.type = replyAttendee.type
                updatedAttendee.role = replyAttendee.role
                updatedAttendee.rsvp = replyAttendee.rsvp

                if updatedAttendee != attendees[index] {
                    attendees[index] = updatedAttendee
                    didChange = true
                }
                if updatedAttendee.isCurrentUser, myResponseStatus != updatedAttendee.status {
                    myResponseStatus = updatedAttendee.status
                    didChange = true
                }
            } else {
                attendees.append(replyAttendee)
                if replyAttendee.isCurrentUser, myResponseStatus != replyAttendee.status {
                    myResponseStatus = replyAttendee.status
                }
                didChange = true
            }
        }

        return didChange
    }

    @discardableResult
    func applyDetachedOccurrenceUpdates(_ updates: [LocalICSDetachedOccurrenceUpdate]) -> Int {
        guard !updates.isEmpty else { return 0 }

        var changedCount = 0
        for update in updates {
            let externalUID = update.externalUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !externalUID.isEmpty else { continue }

            for index in events.indices {
                guard events[index].isRecurring,
                      event(events[index], matchesExternalUID: externalUID)
                else {
                    continue
                }

                var occurrence = update.occurrence
                occurrence.calendarID = events[index].calendarID

                if shouldPreserveImportedOccurrence(
                    sequence: events[index].sequence,
                    updatedAt: events[index].updatedAt,
                    over: occurrence
                ) {
                    continue
                }

                if let detachedIndex = events[index].detachedOccurrences.firstIndex(where: {
                    $0.originalStartDate.isSameOccurrenceStart(as: occurrence.originalStartDate)
                }) {
                    if shouldPreserveImportedOccurrence(
                        sequence: events[index].detachedOccurrences[detachedIndex].sequence,
                        updatedAt: events[index].detachedOccurrences[detachedIndex].updatedAt,
                        over: occurrence
                    ) {
                        continue
                    }

                    guard events[index].detachedOccurrences[detachedIndex] != occurrence else { continue }
                    events[index].detachedOccurrences[detachedIndex] = occurrence
                } else {
                    events[index].detachedOccurrences.append(occurrence)
                }

                events[index].excludedOccurrenceStartDates.removeAll {
                    $0.isSameOccurrenceStart(as: occurrence.originalStartDate)
                }
                events[index].updatedAt = max(events[index].updatedAt, occurrence.updatedAt)
                changedCount += 1
            }
        }

        return changedCount
    }

    private func shouldPreserveImportedOccurrence(
        sequence existingSequence: Int,
        updatedAt existingUpdatedAt: Date,
        over occurrence: LocalDetachedOccurrence
    ) -> Bool {
        if existingSequence != occurrence.sequence {
            return existingSequence > occurrence.sequence
        }
        return existingUpdatedAt > occurrence.updatedAt
    }

    private func shouldPruneProviderEvent(_ event: LocalCalendarEvent, in pruneRange: DateInterval?) -> Bool {
        guard let pruneRange else { return true }

        if event.isRecurring {
            return !calendarEvents(
                from: event,
                rangeStart: pruneRange.start,
                rangeEnd: pruneRange.end,
                includeAllDay: true
            ).isEmpty
        }

        return event.endDate > pruneRange.start && event.startDate < pruneRange.end
    }

    private func shouldPruneProviderDetachedOccurrence(_ occurrence: LocalDetachedOccurrence, in pruneRange: DateInterval?) -> Bool {
        guard let pruneRange else { return true }
        return occurrence.endDate > pruneRange.start && occurrence.startDate < pruneRange.end
    }

    private func event(_ event: LocalCalendarEvent, matchesExternalUID externalUID: String) -> Bool {
        event.externalUID == externalUID
            || event.externalUID.hasPrefix("\(externalUID)#range-this-and-future-")
    }

    private func event(_ event: LocalCalendarEvent, canContainOccurrenceStart occurrenceStart: Date) -> Bool {
        guard event.isRecurring else {
            return occurrenceStart.isSameOccurrenceStart(as: event.startDate)
        }

        guard occurrenceStart >= event.startDate || occurrenceStart.isSameOccurrenceStart(as: event.startDate) else {
            return false
        }

        if let recurrenceEnd = recurrenceEndLimit(for: event),
           occurrenceStart >= recurrenceEnd {
            return false
        }

        return true
    }

    private func normalizedEmail(_ value: String) -> String {
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

    private func percentDecodedEmail(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.removingPercentEncoding ?? trimmed
    }

    private func mailtoAddressComponent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryIndex = trimmed.firstIndex { $0 == "?" || $0 == "#" } ?? trimmed.endIndex
        return String(trimmed[..<queryIndex])
    }

    func remove(_ event: CalendarEvent, scope: CalendarEventRemovalScope = .thisEvent) {
        let eventID = baseEventID(for: event)
        guard let index = events.firstIndex(where: { $0.id == eventID }) else { return }

        guard events[index].isRecurring else {
            events.remove(at: index)
            return
        }

        switch scope {
        case .thisEvent:
            excludeOccurrence(occurrenceStartDate(for: event, in: events[index]), from: index)
        case .futureEvents:
            truncateSeries(at: occurrenceStartDate(for: event, in: events[index]), eventIndex: index)
        case .allEvents:
            events.remove(at: index)
        }
    }

    func contains(_ event: CalendarEvent) -> Bool {
        events.contains { $0.id == baseEventID(for: event) }
    }

    @discardableResult
    func respond(
        to event: CalendarEvent,
        with response: CalendarEventResponse,
        scope: CalendarEventResponseScope = .thisEvent
    ) -> LocalCalendarEvent? {
        let eventID = baseEventID(for: event)
        guard let index = events.firstIndex(where: { $0.id == eventID }) else {
            return nil
        }
        let now = Date()
        let responseStatus = response.responseStatus

        if events[index].isRecurring && scope == .allEvents {
            events[index].myResponseStatus = responseStatus
            applyCurrentUserResponseStatus(responseStatus, to: &events[index].attendees)
            for detachedIndex in events[index].detachedOccurrences.indices {
                events[index].detachedOccurrences[detachedIndex].myResponseStatus = responseStatus
                applyCurrentUserResponseStatus(responseStatus, to: &events[index].detachedOccurrences[detachedIndex].attendees)
                events[index].detachedOccurrences[detachedIndex].sequence += 1
                events[index].detachedOccurrences[detachedIndex].updatedAt = now
            }
            if !events[index].detachedOccurrences.isEmpty {
                events[index].hasLocalProviderRecurrenceChanges = true
            }
            bumpEventRevision(at: index, now: now)
        } else if events[index].isRecurring {
            let originalStartDate = occurrenceStartDate(for: event, in: events[index])
            if let detachedIndex = events[index].detachedOccurrences.firstIndex(where: { $0.originalStartDate.isSameOccurrenceStart(as: originalStartDate) }) {
                events[index].detachedOccurrences[detachedIndex].myResponseStatus = responseStatus
                applyCurrentUserResponseStatus(responseStatus, to: &events[index].detachedOccurrences[detachedIndex].attendees)
                events[index].detachedOccurrences[detachedIndex].sequence += 1
                events[index].detachedOccurrences[detachedIndex].updatedAt = now
                bumpEventRevision(at: index, now: now)
            } else {
                let detached = detachedOccurrence(
                    from: event,
                    originalStartDate: originalStartDate,
                    startDate: event.startDate,
                    endDate: event.endDate,
                    timeZoneIdentifier: events[index].timeZoneIdentifier,
                    geoCoordinate: events[index].geoCoordinate
                )
                upsertDetachedOccurrence(detached, eventIndex: index)
                if let detachedIndex = events[index].detachedOccurrences.firstIndex(where: { $0.originalStartDate.isSameOccurrenceStart(as: originalStartDate) }) {
                    events[index].detachedOccurrences[detachedIndex].myResponseStatus = responseStatus
                    applyCurrentUserResponseStatus(responseStatus, to: &events[index].detachedOccurrences[detachedIndex].attendees)
                    events[index].detachedOccurrences[detachedIndex].updatedAt = now
                }
            }
        } else {
            events[index].myResponseStatus = responseStatus
            applyCurrentUserResponseStatus(responseStatus, to: &events[index].attendees)
            bumpEventRevision(at: index, now: now)
        }
        return events[index]
    }

    private func applyCurrentUserResponseStatus(_ responseStatus: EventResponseStatus, to attendees: inout [LocalEventAttendee]) {
        guard let index = attendees.firstIndex(where: \.isCurrentUser) else { return }
        attendees[index].status = responseStatus
        attendees[index].rsvp = responseStatus == .pending
    }

    @discardableResult
    func move(
        _ event: CalendarEvent,
        dayDelta: Int,
        minuteDelta: Int,
        scope: CalendarEventChangeScope = .thisEvent
    ) -> [LocalCalendarEvent] {
        guard let index = events.firstIndex(where: { $0.id == baseEventID(for: event) }) else { return [] }
        if events[index].isRecurring {
            if scope == .futureEvents {
                return moveFutureRecurringSeries(
                    event,
                    eventIndex: index,
                    dayDelta: dayDelta,
                    minuteDelta: minuteDelta
                )
            } else if scope == .allEvents {
                moveRecurringSeries(at: index, dayDelta: dayDelta, minuteDelta: minuteDelta)
                return events.indices.contains(index) ? [events[index]] : []
            }

            let shiftedStart = Calendar.current.date(byAdding: .day, value: dayDelta, to: event.startDate) ?? event.startDate
            let snappedStart = Calendar.current.date(byAdding: .minute, value: minuteDelta, to: shiftedStart) ?? shiftedStart
            let duration = event.endDate.timeIntervalSince(event.startDate)
            let occurrenceStart = occurrenceStartDate(for: event, in: events[index])
            let geoCoordinate = events[index].detachedOccurrence(for: occurrenceStart)?.geoCoordinate
                ?? events[index].geoCoordinate
            upsertDetachedOccurrence(
                detachedOccurrence(from: event, originalStartDate: occurrenceStart, startDate: snappedStart, endDate: snappedStart.addingTimeInterval(max(5 * 60, duration)), timeZoneIdentifier: events[index].timeZoneIdentifier, geoCoordinate: geoCoordinate),
                eventIndex: index
            )
            return [events[index]]
        }

        let duration = events[index].endDate.timeIntervalSince(events[index].startDate)
        let shiftedStart = Calendar.current.date(byAdding: .day, value: dayDelta, to: events[index].startDate) ?? events[index].startDate
        let snappedStart = Calendar.current.date(byAdding: .minute, value: minuteDelta, to: shiftedStart) ?? shiftedStart

        events[index].startDate = snappedStart
        events[index].endDate = snappedStart.addingTimeInterval(max(5 * 60, duration))
        bumpEventRevision(at: index)
        return [events[index]]
    }

    @discardableResult
    func resize(
        _ event: CalendarEvent,
        endMinuteDelta: Int,
        scope: CalendarEventChangeScope = .thisEvent
    ) -> [LocalCalendarEvent] {
        guard let index = events.firstIndex(where: { $0.id == baseEventID(for: event) }) else { return [] }
        if events[index].isRecurring {
            if scope == .futureEvents {
                return resizeFutureRecurringSeries(
                    event,
                    eventIndex: index,
                    endMinuteDelta: endMinuteDelta
                )
            } else if scope == .allEvents {
                resizeRecurringSeries(at: index, endMinuteDelta: endMinuteDelta)
                return events.indices.contains(index) ? [events[index]] : []
            }

            let resizedEnd = Calendar.current.date(byAdding: .minute, value: endMinuteDelta, to: event.endDate) ?? event.endDate
            let minimumEnd = event.startDate.addingTimeInterval(5 * 60)
            let occurrenceStart = occurrenceStartDate(for: event, in: events[index])
            let geoCoordinate = events[index].detachedOccurrence(for: occurrenceStart)?.geoCoordinate
                ?? events[index].geoCoordinate
            upsertDetachedOccurrence(
                detachedOccurrence(from: event, originalStartDate: occurrenceStart, startDate: event.startDate, endDate: max(resizedEnd, minimumEnd), timeZoneIdentifier: events[index].timeZoneIdentifier, geoCoordinate: geoCoordinate),
                eventIndex: index
            )
            return [events[index]]
        }

        let resizedEnd = Calendar.current.date(byAdding: .minute, value: endMinuteDelta, to: events[index].endDate) ?? events[index].endDate
        let minimumEnd = events[index].startDate.addingTimeInterval(5 * 60)

        events[index].endDate = max(resizedEnd, minimumEnd)
        bumpEventRevision(at: index)
        return [events[index]]
    }

    private func moveFutureRecurringSeries(
        _ event: CalendarEvent,
        eventIndex: Int,
        dayDelta: Int,
        minuteDelta: Int
    ) -> [LocalCalendarEvent] {
        guard events.indices.contains(eventIndex) else { return [] }
        let occurrenceStart = occurrenceStartDate(for: event, in: events[eventIndex])
        if occurrenceStart <= events[eventIndex].startDate
            || occurrenceStart.isSameOccurrenceStart(as: events[eventIndex].startDate) {
            moveRecurringSeries(at: eventIndex, dayDelta: dayDelta, minuteDelta: minuteDelta)
            return events.indices.contains(eventIndex) ? [events[eventIndex]] : []
        }

        guard let futureIndex = splitRecurringSeriesForFutureChange(at: occurrenceStart, eventIndex: eventIndex) else {
            return []
        }
        moveRecurringSeries(at: futureIndex, dayDelta: dayDelta, minuteDelta: minuteDelta)
        return changedEvents(at: [eventIndex, futureIndex])
    }

    private func resizeFutureRecurringSeries(
        _ event: CalendarEvent,
        eventIndex: Int,
        endMinuteDelta: Int
    ) -> [LocalCalendarEvent] {
        guard events.indices.contains(eventIndex) else { return [] }
        let occurrenceStart = occurrenceStartDate(for: event, in: events[eventIndex])
        if occurrenceStart <= events[eventIndex].startDate
            || occurrenceStart.isSameOccurrenceStart(as: events[eventIndex].startDate) {
            resizeRecurringSeries(at: eventIndex, endMinuteDelta: endMinuteDelta)
            return events.indices.contains(eventIndex) ? [events[eventIndex]] : []
        }

        guard let futureIndex = splitRecurringSeriesForFutureChange(at: occurrenceStart, eventIndex: eventIndex) else {
            return []
        }
        resizeRecurringSeries(at: futureIndex, endMinuteDelta: endMinuteDelta)
        return changedEvents(at: [eventIndex, futureIndex])
    }

    private func changedEvents(at indices: [Int]) -> [LocalCalendarEvent] {
        indices.compactMap { index in
            guard events.indices.contains(index) else { return nil }
            return events[index]
        }
    }

    private func moveRecurringSeries(at eventIndex: Int, dayDelta: Int, minuteDelta: Int) {
        guard events.indices.contains(eventIndex) else { return }

        let now = Date()
        let originalWeekdays = recurrenceWeekdays(for: events[eventIndex])
        let originalMonthlyOrdinal = events[eventIndex].recurrenceOrdinal
        let originalMonthDay = events[eventIndex].recurrenceMonthDay
        let calendar = recurrenceCalendar(for: events[eventIndex])

        events[eventIndex].startDate = shiftedDate(events[eventIndex].startDate, dayDelta: dayDelta, minuteDelta: minuteDelta, calendar: calendar)
        events[eventIndex].endDate = shiftedDate(events[eventIndex].endDate, dayDelta: dayDelta, minuteDelta: minuteDelta, calendar: calendar)
        events[eventIndex].endDate = max(events[eventIndex].endDate, events[eventIndex].startDate.addingTimeInterval(5 * 60))

        if events[eventIndex].recurrenceFrequency == .weekly {
            events[eventIndex].recurrenceWeekdays = shiftedWeekdays(originalWeekdays, dayDelta: dayDelta)
        }

        if (events[eventIndex].recurrenceFrequency == .monthly || events[eventIndex].recurrenceFrequency == .yearly),
           let originalMonthlyOrdinal,
           events[eventIndex].recurrenceOrdinalWeekday != nil {
            events[eventIndex].recurrenceOrdinal = monthlyOrdinal(
                for: events[eventIndex].startDate,
                preservingSignOf: originalMonthlyOrdinal,
                calendar: calendar
            )
            events[eventIndex].recurrenceOrdinalWeekday = calendar.component(
                .weekday,
                from: events[eventIndex].startDate
            )
        } else if (events[eventIndex].recurrenceFrequency == .monthly || events[eventIndex].recurrenceFrequency == .yearly),
                  originalMonthDay != nil {
            events[eventIndex].recurrenceMonthDay = monthlyDay(
                for: events[eventIndex].startDate,
                preservingSignOf: originalMonthDay,
                calendar: calendar
            )
        }

        events[eventIndex].recurrenceEndDate = events[eventIndex].recurrenceEndDate.map {
            shiftedDate($0, dayDelta: dayDelta, minuteDelta: 0, calendar: calendar)
        }
        events[eventIndex].additionalOccurrenceStartDates = events[eventIndex].additionalOccurrenceStartDates
            .map { shiftedDate($0, dayDelta: dayDelta, minuteDelta: minuteDelta, calendar: calendar) }
            .uniqueOccurrenceStarts
        events[eventIndex].excludedOccurrenceStartDates = events[eventIndex].excludedOccurrenceStartDates
            .map { shiftedDate($0, dayDelta: dayDelta, minuteDelta: minuteDelta, calendar: calendar) }
            .uniqueOccurrenceStarts
        events[eventIndex].detachedOccurrences = events[eventIndex].detachedOccurrences.map { detached in
            var updated = detached
            updated.originalStartDate = shiftedDate(detached.originalStartDate, dayDelta: dayDelta, minuteDelta: minuteDelta, calendar: calendar)
            updated.startDate = shiftedDate(detached.startDate, dayDelta: dayDelta, minuteDelta: minuteDelta, calendar: calendar)
            updated.endDate = shiftedDate(detached.endDate, dayDelta: dayDelta, minuteDelta: minuteDelta, calendar: calendar)
            updated.endDate = max(updated.endDate, updated.startDate.addingTimeInterval(5 * 60))
            updated.sequence += 1
            updated.updatedAt = now
            return updated
        }

        events[eventIndex].hasLocalProviderRecurrenceChanges = true
        bumpEventRevision(at: eventIndex, now: now)
    }

    private func resizeRecurringSeries(at eventIndex: Int, endMinuteDelta: Int) {
        guard events.indices.contains(eventIndex) else { return }

        let now = Date()
        let resizedEnd = Calendar.current.date(
            byAdding: .minute,
            value: endMinuteDelta,
            to: events[eventIndex].endDate
        ) ?? events[eventIndex].endDate
        events[eventIndex].endDate = max(resizedEnd, events[eventIndex].startDate.addingTimeInterval(5 * 60))
        events[eventIndex].detachedOccurrences = events[eventIndex].detachedOccurrences.map { detached in
            var updated = detached
            let detachedResizedEnd = Calendar.current.date(
                byAdding: .minute,
                value: endMinuteDelta,
                to: detached.endDate
            ) ?? detached.endDate
            updated.endDate = max(detachedResizedEnd, detached.startDate.addingTimeInterval(5 * 60))
            updated.sequence += 1
            updated.updatedAt = now
            return updated
        }

        events[eventIndex].hasLocalProviderRecurrenceChanges = true
        bumpEventRevision(at: eventIndex, now: now)
    }

    private func shiftedDate(_ date: Date, dayDelta: Int, minuteDelta: Int, calendar: Calendar) -> Date {
        let dayShifted = calendar.date(byAdding: .day, value: dayDelta, to: date) ?? date
        return calendar.date(byAdding: .minute, value: minuteDelta, to: dayShifted) ?? dayShifted
    }

    private func shiftedWeekdays(_ weekdays: [Int], dayDelta: Int) -> [Int] {
        sortedWeekdays(weekdays.map { weekday in
            let zeroBased = (weekday - 1 + dayDelta) % 7
            return (zeroBased + 7) % 7 + 1
        })
    }

    private func monthlyOrdinal(for date: Date, preservingSignOf sourceOrdinal: Int, calendar: Calendar) -> Int {
        let day = calendar.component(.day, from: date)
        if sourceOrdinal < 0,
           let days = calendar.range(of: .day, in: .month, for: date) {
            return -(((days.upperBound - 1 - day) / 7) + 1)
        }

        return ((day - 1) / 7) + 1
    }

    private func monthlyDay(for date: Date, preservingSignOf sourceMonthDay: Int?, calendar: Calendar) -> Int {
        let day = calendar.component(.day, from: date)
        if let sourceMonthDay, sourceMonthDay < 0,
           let days = calendar.range(of: .day, in: .month, for: date) {
            return day - (days.count + 1)
        }

        return day
    }

    private func calendarEvents(from localEvent: LocalCalendarEvent, rangeStart: Date, rangeEnd: Date, includeAllDay: Bool) -> [CalendarEvent] {
        if localEvent.recurrenceFrequency == .weekly {
            return weeklyCalendarEvents(from: localEvent, rangeStart: rangeStart, rangeEnd: rangeEnd, includeAllDay: includeAllDay)
        }

        if localEvent.recurrenceFrequency == .monthly,
           localEvent.recurrenceOrdinal != nil,
           localEvent.recurrenceOrdinalWeekday != nil {
            return monthlyOrdinalCalendarEvents(from: localEvent, rangeStart: rangeStart, rangeEnd: rangeEnd, includeAllDay: includeAllDay)
        }

        if localEvent.recurrenceFrequency == .monthly {
            return monthlyDayCalendarEvents(from: localEvent, rangeStart: rangeStart, rangeEnd: rangeEnd, includeAllDay: includeAllDay)
        }

        if localEvent.recurrenceFrequency == .yearly,
           localEvent.recurrenceOrdinal != nil,
           localEvent.recurrenceOrdinalWeekday != nil {
            return yearlyOrdinalCalendarEvents(from: localEvent, rangeStart: rangeStart, rangeEnd: rangeEnd, includeAllDay: includeAllDay)
        }

        if localEvent.recurrenceFrequency == .yearly {
            return yearlyDateCalendarEvents(from: localEvent, rangeStart: rangeStart, rangeEnd: rangeEnd, includeAllDay: includeAllDay)
        }

        guard localEvent.isRecurring, let component = localEvent.recurrenceFrequency.calendarComponent else {
            var occurrences: [CalendarEvent] = []
            if shouldInclude(localEvent, includeAllDay: includeAllDay),
               localEvent.endDate > rangeStart,
               localEvent.startDate < rangeEnd,
               let event = calendarEvent(from: localEvent, occurrenceStart: localEvent.startDate, occurrenceEnd: localEvent.endDate) {
                occurrences.append(event)
            }
            occurrences.append(contentsOf: additionalCalendarEvents(
                from: localEvent,
                rangeStart: rangeStart,
                rangeEnd: rangeEnd,
                includeAllDay: includeAllDay,
                existingOccurrences: occurrences
            ))
            return occurrences.sorted { $0.startDate < $1.startDate }
        }

        var occurrenceStart = localEvent.startDate
        var occurrenceEnd = localEvent.endDate
        var occurrences: [CalendarEvent] = []
        var emittedDetachedKeys: Set<Int> = []
        let recurrenceLimit = recurrenceEndLimit(for: localEvent)
        let interval = localEvent.safeRecurrenceInterval
        let calendar = recurrenceCalendar(for: localEvent)
        var iterationCount = 0

        while occurrenceEnd <= rangeStart && iterationCount < 5_000 {
            guard let nextStart = calendar.date(byAdding: component, value: interval, to: occurrenceStart),
                  let nextEnd = calendar.date(byAdding: component, value: interval, to: occurrenceEnd) else {
                return occurrences
            }
            occurrenceStart = nextStart
            occurrenceEnd = nextEnd
            iterationCount += 1
        }

        while occurrenceStart < rangeEnd && iterationCount < 10_000 {
            if let recurrenceLimit, occurrenceStart >= recurrenceLimit {
                break
            }

            if let detached = localEvent.detachedOccurrence(for: occurrenceStart) {
                if shouldInclude(detached, includeAllDay: includeAllDay),
                   detached.endDate > rangeStart,
                   detached.startDate < rangeEnd,
                   let calendarEvent = calendarEvent(from: localEvent, detachedOccurrence: detached) {
                    occurrences.append(calendarEvent)
                    emittedDetachedKeys.insert(detached.originalStartDate.occurrenceKey)
                }
            } else if shouldInclude(localEvent, includeAllDay: includeAllDay),
                      !localEvent.isOccurrenceExcluded(occurrenceStart),
                      occurrenceEnd > rangeStart,
                      let calendarEvent = calendarEvent(from: localEvent, occurrenceStart: occurrenceStart, occurrenceEnd: occurrenceEnd) {
                occurrences.append(calendarEvent)
            }

            guard let nextStart = calendar.date(byAdding: component, value: interval, to: occurrenceStart),
                  let nextEnd = calendar.date(byAdding: component, value: interval, to: occurrenceEnd) else {
                break
            }
            occurrenceStart = nextStart
            occurrenceEnd = nextEnd
            iterationCount += 1
        }

        let movedDetachedOccurrences = localEvent.detachedOccurrences.filter { detached in
            !emittedDetachedKeys.contains(detached.originalStartDate.occurrenceKey)
                && shouldInclude(detached, includeAllDay: includeAllDay)
                && detached.endDate > rangeStart
                && detached.startDate < rangeEnd
        }
        occurrences.append(contentsOf: movedDetachedOccurrences.compactMap { calendarEvent(from: localEvent, detachedOccurrence: $0) })
        occurrences.append(contentsOf: additionalCalendarEvents(
            from: localEvent,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            includeAllDay: includeAllDay,
            existingOccurrences: occurrences
        ))

        return occurrences.sorted { $0.startDate < $1.startDate }
    }

    private func weeklyCalendarEvents(from localEvent: LocalCalendarEvent, rangeStart: Date, rangeEnd: Date, includeAllDay: Bool) -> [CalendarEvent] {
        guard localEvent.isRecurring else { return [] }
        let calendar = recurrenceCalendar(for: localEvent, weekStart: localEvent.recurrenceWeekStart)
        guard let anchorWeek = calendar.dateInterval(of: .weekOfYear, for: localEvent.startDate) else { return [] }

        let duration = eventDurationSeconds(for: localEvent)
        let weekdays = recurrenceWeekdays(for: localEvent)
        let recurrenceLimit = recurrenceEndLimit(for: localEvent)
        let interval = localEvent.safeRecurrenceInterval
        var weekStart = anchorWeek.start
        var occurrences: [CalendarEvent] = []
        var emittedDetachedKeys: Set<Int> = []
        var iterationCount = 0

        while let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart),
              weekEnd.addingTimeInterval(duration) <= rangeStart,
              iterationCount < 5_000 {
            guard let nextWeekStart = calendar.date(byAdding: .weekOfYear, value: interval, to: weekStart) else {
                return occurrences
            }
            weekStart = nextWeekStart
            iterationCount += 1
        }

        while weekStart < rangeEnd && iterationCount < 10_000 {
            for occurrenceStart in weeklyOccurrenceStarts(
                weekStart: weekStart,
                weekdays: weekdays,
                setPositions: localEvent.recurrenceSetPositions,
                matching: localEvent.startDate,
                calendar: calendar
            ) {
                if occurrenceStart < localEvent.startDate { continue }
                if let recurrenceLimit, occurrenceStart >= recurrenceLimit { continue }

                let occurrenceEnd = occurrenceEnd(for: localEvent, occurrenceStart: occurrenceStart, fallbackDuration: duration, calendar: calendar)
                if let detached = localEvent.detachedOccurrence(for: occurrenceStart) {
                    if shouldInclude(detached, includeAllDay: includeAllDay),
                       detached.endDate > rangeStart,
                       detached.startDate < rangeEnd,
                       let calendarEvent = calendarEvent(from: localEvent, detachedOccurrence: detached) {
                        occurrences.append(calendarEvent)
                        emittedDetachedKeys.insert(detached.originalStartDate.occurrenceKey)
                    }
                } else if shouldInclude(localEvent, includeAllDay: includeAllDay),
                          !localEvent.isOccurrenceExcluded(occurrenceStart),
                          occurrenceEnd > rangeStart,
                          occurrenceStart < rangeEnd,
                          let calendarEvent = calendarEvent(from: localEvent, occurrenceStart: occurrenceStart, occurrenceEnd: occurrenceEnd) {
                    occurrences.append(calendarEvent)
                }
            }

            guard let nextWeekStart = calendar.date(byAdding: .weekOfYear, value: interval, to: weekStart) else {
                break
            }
            weekStart = nextWeekStart
            iterationCount += 1
        }

        let movedDetachedOccurrences = localEvent.detachedOccurrences.filter { detached in
            !emittedDetachedKeys.contains(detached.originalStartDate.occurrenceKey)
                && shouldInclude(detached, includeAllDay: includeAllDay)
                && detached.endDate > rangeStart
                && detached.startDate < rangeEnd
        }
        occurrences.append(contentsOf: movedDetachedOccurrences.compactMap { calendarEvent(from: localEvent, detachedOccurrence: $0) })
        occurrences.append(contentsOf: additionalCalendarEvents(
            from: localEvent,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            includeAllDay: includeAllDay,
            existingOccurrences: occurrences
        ))

        return occurrences.sorted { $0.startDate < $1.startDate }
    }

    private func monthlyDayCalendarEvents(from localEvent: LocalCalendarEvent, rangeStart: Date, rangeEnd: Date, includeAllDay: Bool) -> [CalendarEvent] {
        guard localEvent.isRecurring,
              let anchorMonth = recurrenceCalendar(for: localEvent).dateInterval(of: .month, for: localEvent.startDate)?.start
        else {
            return []
        }

        let calendar = recurrenceCalendar(for: localEvent)
        let sourceDay = localEvent.recurrenceMonthDay ?? calendar.component(.day, from: localEvent.startDate)
        let duration = eventDurationSeconds(for: localEvent)
        let recurrenceLimit = recurrenceEndLimit(for: localEvent)
        let interval = localEvent.safeRecurrenceInterval
        var monthStart = anchorMonth
        var occurrences: [CalendarEvent] = []
        var emittedDetachedKeys: Set<Int> = []
        var iterationCount = 0

        while let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart),
              monthEnd.addingTimeInterval(duration) <= rangeStart,
              iterationCount < 5_000 {
            guard let nextMonth = calendar.date(byAdding: .month, value: interval, to: monthStart) else {
                return occurrences
            }
            monthStart = nextMonth
            iterationCount += 1
        }

        while monthStart < rangeEnd && iterationCount < 10_000 {
            if let recurrenceLimit, monthStart >= recurrenceLimit {
                break
            }

            guard monthAllowed(monthStart, months: localEvent.recurrenceMonths, calendar: calendar) else {
                guard let nextMonth = calendar.date(byAdding: .month, value: interval, to: monthStart) else {
                    break
                }
                monthStart = nextMonth
                iterationCount += 1
                continue
            }

            if let occurrenceStart = monthDayOccurrence(
                monthStart: monthStart,
                day: sourceDay,
                matching: localEvent.startDate,
                calendar: calendar
            ), occurrenceStart >= localEvent.startDate {
                if let recurrenceLimit, occurrenceStart >= recurrenceLimit {
                    break
                }

                let occurrenceEnd = occurrenceEnd(for: localEvent, occurrenceStart: occurrenceStart, fallbackDuration: duration, calendar: calendar)
                if let detached = localEvent.detachedOccurrence(for: occurrenceStart) {
                    if shouldInclude(detached, includeAllDay: includeAllDay),
                       detached.endDate > rangeStart,
                       detached.startDate < rangeEnd,
                       let calendarEvent = calendarEvent(from: localEvent, detachedOccurrence: detached) {
                        occurrences.append(calendarEvent)
                        emittedDetachedKeys.insert(detached.originalStartDate.occurrenceKey)
                    }
                } else if shouldInclude(localEvent, includeAllDay: includeAllDay),
                          !localEvent.isOccurrenceExcluded(occurrenceStart),
                          occurrenceEnd > rangeStart,
                          occurrenceStart < rangeEnd,
                          let calendarEvent = calendarEvent(from: localEvent, occurrenceStart: occurrenceStart, occurrenceEnd: occurrenceEnd) {
                    occurrences.append(calendarEvent)
                }
            }

            guard let nextMonth = calendar.date(byAdding: .month, value: interval, to: monthStart) else {
                break
            }
            monthStart = nextMonth
            iterationCount += 1
        }

        let movedDetachedOccurrences = localEvent.detachedOccurrences.filter { detached in
            !emittedDetachedKeys.contains(detached.originalStartDate.occurrenceKey)
                && shouldInclude(detached, includeAllDay: includeAllDay)
                && detached.endDate > rangeStart
                && detached.startDate < rangeEnd
        }
        occurrences.append(contentsOf: movedDetachedOccurrences.compactMap { calendarEvent(from: localEvent, detachedOccurrence: $0) })
        occurrences.append(contentsOf: additionalCalendarEvents(
            from: localEvent,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            includeAllDay: includeAllDay,
            existingOccurrences: occurrences
        ))

        return occurrences.sorted { $0.startDate < $1.startDate }
    }

    private func monthlyOrdinalCalendarEvents(from localEvent: LocalCalendarEvent, rangeStart: Date, rangeEnd: Date, includeAllDay: Bool) -> [CalendarEvent] {
        guard localEvent.isRecurring,
              let ordinal = localEvent.recurrenceOrdinal,
              let weekday = localEvent.recurrenceOrdinalWeekday,
              let anchorMonth = recurrenceCalendar(for: localEvent).dateInterval(of: .month, for: localEvent.startDate)?.start
        else {
            return []
        }

        let calendar = recurrenceCalendar(for: localEvent)
        let duration = eventDurationSeconds(for: localEvent)
        let recurrenceLimit = recurrenceEndLimit(for: localEvent)
        let interval = localEvent.safeRecurrenceInterval
        var monthStart = anchorMonth
        var occurrences: [CalendarEvent] = []
        var emittedDetachedKeys: Set<Int> = []
        var iterationCount = 0

        while let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart),
              monthEnd.addingTimeInterval(duration) <= rangeStart,
              iterationCount < 5_000 {
            guard let nextMonth = calendar.date(byAdding: .month, value: interval, to: monthStart) else {
                return occurrences
            }
            monthStart = nextMonth
            iterationCount += 1
        }

        while monthStart < rangeEnd && iterationCount < 10_000 {
            if let recurrenceLimit, monthStart >= recurrenceLimit {
                break
            }

            guard monthAllowed(monthStart, months: localEvent.recurrenceMonths, calendar: calendar) else {
                guard let nextMonth = calendar.date(byAdding: .month, value: interval, to: monthStart) else {
                    break
                }
                monthStart = nextMonth
                iterationCount += 1
                continue
            }

            if let occurrenceStart = ordinalWeekdayOccurrence(
                    monthStart: monthStart,
                    ordinal: ordinal,
                    weekday: weekday,
                    matching: localEvent.startDate,
                    calendar: calendar
                ), occurrenceStart >= localEvent.startDate {
                if let recurrenceLimit, occurrenceStart >= recurrenceLimit {
                    break
                }

                let occurrenceEnd = occurrenceEnd(for: localEvent, occurrenceStart: occurrenceStart, fallbackDuration: duration, calendar: calendar)
                if let detached = localEvent.detachedOccurrence(for: occurrenceStart) {
                    if shouldInclude(detached, includeAllDay: includeAllDay),
                       detached.endDate > rangeStart,
                       detached.startDate < rangeEnd,
                       let calendarEvent = calendarEvent(from: localEvent, detachedOccurrence: detached) {
                        occurrences.append(calendarEvent)
                        emittedDetachedKeys.insert(detached.originalStartDate.occurrenceKey)
                    }
                } else if shouldInclude(localEvent, includeAllDay: includeAllDay),
                          !localEvent.isOccurrenceExcluded(occurrenceStart),
                          occurrenceEnd > rangeStart,
                          occurrenceStart < rangeEnd,
                          let calendarEvent = calendarEvent(from: localEvent, occurrenceStart: occurrenceStart, occurrenceEnd: occurrenceEnd) {
                    occurrences.append(calendarEvent)
                }
            }

            guard let nextMonth = calendar.date(byAdding: .month, value: interval, to: monthStart) else {
                break
            }
            monthStart = nextMonth
            iterationCount += 1
        }

        let movedDetachedOccurrences = localEvent.detachedOccurrences.filter { detached in
            !emittedDetachedKeys.contains(detached.originalStartDate.occurrenceKey)
                && shouldInclude(detached, includeAllDay: includeAllDay)
                && detached.endDate > rangeStart
                && detached.startDate < rangeEnd
        }
        occurrences.append(contentsOf: movedDetachedOccurrences.compactMap { calendarEvent(from: localEvent, detachedOccurrence: $0) })
        occurrences.append(contentsOf: additionalCalendarEvents(
            from: localEvent,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            includeAllDay: includeAllDay,
            existingOccurrences: occurrences
        ))

        return occurrences.sorted { $0.startDate < $1.startDate }
    }

    private func yearlyOrdinalCalendarEvents(from localEvent: LocalCalendarEvent, rangeStart: Date, rangeEnd: Date, includeAllDay: Bool) -> [CalendarEvent] {
        guard localEvent.isRecurring,
              let ordinal = localEvent.recurrenceOrdinal,
              let weekday = localEvent.recurrenceOrdinalWeekday,
              let anchorYear = recurrenceCalendar(for: localEvent).dateInterval(of: .year, for: localEvent.startDate)?.start
        else {
            return []
        }

        let calendar = recurrenceCalendar(for: localEvent)
        let sourceMonth = calendar.component(.month, from: localEvent.startDate)
        let months = recurrenceMonths(for: localEvent, defaultMonth: sourceMonth)
        let duration = eventDurationSeconds(for: localEvent)
        let recurrenceLimit = recurrenceEndLimit(for: localEvent)
        let interval = localEvent.safeRecurrenceInterval
        var yearStart = anchorYear
        var occurrences: [CalendarEvent] = []
        var emittedDetachedKeys: Set<Int> = []
        var iterationCount = 0

        while let nextYear = calendar.date(byAdding: .year, value: 1, to: yearStart),
              nextYear.addingTimeInterval(duration) <= rangeStart,
              iterationCount < 5_000 {
            guard let steppedYear = calendar.date(byAdding: .year, value: interval, to: yearStart) else {
                return occurrences
            }
            yearStart = steppedYear
            iterationCount += 1
        }

        while yearStart < rangeEnd && iterationCount < 10_000 {
            if let recurrenceLimit, yearStart >= recurrenceLimit {
                break
            }

            for month in months {
                guard let monthStart = calendar.date(byAdding: .month, value: month - 1, to: yearStart),
                      let occurrenceStart = ordinalWeekdayOccurrence(
                    monthStart: monthStart,
                    ordinal: ordinal,
                    weekday: weekday,
                    matching: localEvent.startDate,
                    calendar: calendar
                      ),
                      occurrenceStart >= localEvent.startDate
                else {
                    continue
                }

                if let recurrenceLimit, occurrenceStart >= recurrenceLimit {
                    continue
                }

                let occurrenceEnd = occurrenceEnd(for: localEvent, occurrenceStart: occurrenceStart, fallbackDuration: duration, calendar: calendar)
                if let detached = localEvent.detachedOccurrence(for: occurrenceStart) {
                    if shouldInclude(detached, includeAllDay: includeAllDay),
                       detached.endDate > rangeStart,
                       detached.startDate < rangeEnd,
                       let calendarEvent = calendarEvent(from: localEvent, detachedOccurrence: detached) {
                        occurrences.append(calendarEvent)
                        emittedDetachedKeys.insert(detached.originalStartDate.occurrenceKey)
                    }
                } else if shouldInclude(localEvent, includeAllDay: includeAllDay),
                          !localEvent.isOccurrenceExcluded(occurrenceStart),
                          occurrenceEnd > rangeStart,
                          occurrenceStart < rangeEnd,
                          let calendarEvent = calendarEvent(from: localEvent, occurrenceStart: occurrenceStart, occurrenceEnd: occurrenceEnd) {
                    occurrences.append(calendarEvent)
                }
            }

            guard let nextYear = calendar.date(byAdding: .year, value: interval, to: yearStart) else {
                break
            }
            yearStart = nextYear
            iterationCount += 1
        }

        let movedDetachedOccurrences = localEvent.detachedOccurrences.filter { detached in
            !emittedDetachedKeys.contains(detached.originalStartDate.occurrenceKey)
                && shouldInclude(detached, includeAllDay: includeAllDay)
                && detached.endDate > rangeStart
                && detached.startDate < rangeEnd
        }
        occurrences.append(contentsOf: movedDetachedOccurrences.compactMap { calendarEvent(from: localEvent, detachedOccurrence: $0) })
        occurrences.append(contentsOf: additionalCalendarEvents(
            from: localEvent,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            includeAllDay: includeAllDay,
            existingOccurrences: occurrences
        ))

        return occurrences.sorted { $0.startDate < $1.startDate }
    }

    private func yearlyDateCalendarEvents(from localEvent: LocalCalendarEvent, rangeStart: Date, rangeEnd: Date, includeAllDay: Bool) -> [CalendarEvent] {
        guard localEvent.isRecurring,
              let anchorYear = recurrenceCalendar(for: localEvent).dateInterval(of: .year, for: localEvent.startDate)?.start
        else {
            return []
        }

        let calendar = recurrenceCalendar(for: localEvent)
        let sourceComponents = calendar.dateComponents([.month, .day], from: localEvent.startDate)
        guard let sourceMonth = sourceComponents.month, let sourceDay = sourceComponents.day else {
            return []
        }
        let months = recurrenceMonths(for: localEvent, defaultMonth: sourceMonth)
        let recurrenceMonthDay = localEvent.recurrenceMonthDay ?? sourceDay

        let duration = eventDurationSeconds(for: localEvent)
        let recurrenceLimit = recurrenceEndLimit(for: localEvent)
        let interval = localEvent.safeRecurrenceInterval
        var yearStart = anchorYear
        var occurrences: [CalendarEvent] = []
        var emittedDetachedKeys: Set<Int> = []
        var iterationCount = 0

        while let yearEnd = calendar.date(byAdding: .year, value: 1, to: yearStart),
              yearEnd.addingTimeInterval(duration) <= rangeStart,
              iterationCount < 5_000 {
            guard let nextYear = calendar.date(byAdding: .year, value: interval, to: yearStart) else {
                return occurrences
            }
            yearStart = nextYear
            iterationCount += 1
        }

        while yearStart < rangeEnd && iterationCount < 10_000 {
            if let recurrenceLimit, yearStart >= recurrenceLimit {
                break
            }

            for month in months {
                guard let occurrenceStart = yearlyDateOccurrence(
                    yearStart: yearStart,
                    month: month,
                    day: recurrenceMonthDay,
                    matching: localEvent.startDate,
                    calendar: calendar
                ),
                occurrenceStart >= localEvent.startDate
                else {
                    continue
                }

                if let recurrenceLimit, occurrenceStart >= recurrenceLimit {
                    continue
                }

                let occurrenceEnd = occurrenceEnd(for: localEvent, occurrenceStart: occurrenceStart, fallbackDuration: duration, calendar: calendar)
                if let detached = localEvent.detachedOccurrence(for: occurrenceStart) {
                    if shouldInclude(detached, includeAllDay: includeAllDay),
                       detached.endDate > rangeStart,
                       detached.startDate < rangeEnd,
                       let calendarEvent = calendarEvent(from: localEvent, detachedOccurrence: detached) {
                        occurrences.append(calendarEvent)
                        emittedDetachedKeys.insert(detached.originalStartDate.occurrenceKey)
                    }
                } else if shouldInclude(localEvent, includeAllDay: includeAllDay),
                          !localEvent.isOccurrenceExcluded(occurrenceStart),
                          occurrenceEnd > rangeStart,
                          occurrenceStart < rangeEnd,
                          let calendarEvent = calendarEvent(from: localEvent, occurrenceStart: occurrenceStart, occurrenceEnd: occurrenceEnd) {
                    occurrences.append(calendarEvent)
                }
            }

            guard let nextYear = calendar.date(byAdding: .year, value: interval, to: yearStart) else {
                break
            }
            yearStart = nextYear
            iterationCount += 1
        }

        let movedDetachedOccurrences = localEvent.detachedOccurrences.filter { detached in
            !emittedDetachedKeys.contains(detached.originalStartDate.occurrenceKey)
                && shouldInclude(detached, includeAllDay: includeAllDay)
                && detached.endDate > rangeStart
                && detached.startDate < rangeEnd
        }
        occurrences.append(contentsOf: movedDetachedOccurrences.compactMap { calendarEvent(from: localEvent, detachedOccurrence: $0) })
        occurrences.append(contentsOf: additionalCalendarEvents(
            from: localEvent,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            includeAllDay: includeAllDay,
            existingOccurrences: occurrences
        ))

        return occurrences.sorted { $0.startDate < $1.startDate }
    }

    private func additionalCalendarEvents(
        from localEvent: LocalCalendarEvent,
        rangeStart: Date,
        rangeEnd: Date,
        includeAllDay: Bool,
        existingOccurrences: [CalendarEvent]
    ) -> [CalendarEvent] {
        guard !localEvent.additionalOccurrenceStartDates.isEmpty else { return [] }

        let calendar = recurrenceCalendar(for: localEvent)
        let duration = eventDurationSeconds(for: localEvent)
        var emittedStarts = existingOccurrences.map(\.occurrenceStartDate)
        var occurrences: [CalendarEvent] = []

        for occurrenceStart in localEvent.additionalOccurrenceStartDates.sorted() {
            guard !emittedStarts.containsOccurrenceStart(occurrenceStart),
                  !localEvent.isOccurrenceExcluded(occurrenceStart)
            else { continue }

            if let detached = localEvent.detachedOccurrence(for: occurrenceStart) {
                if shouldInclude(detached, includeAllDay: includeAllDay),
                   detached.endDate > rangeStart,
                   detached.startDate < rangeEnd,
                   let calendarEvent = calendarEvent(from: localEvent, detachedOccurrence: detached) {
                    occurrences.append(calendarEvent)
                    emittedStarts.append(detached.originalStartDate)
                }
                continue
            }

            let occurrenceEnd = occurrenceEnd(for: localEvent, occurrenceStart: occurrenceStart, fallbackDuration: duration, calendar: calendar)
            guard shouldInclude(localEvent, includeAllDay: includeAllDay),
                  occurrenceEnd > rangeStart,
                  occurrenceStart < rangeEnd,
                  let calendarEvent = calendarEvent(from: localEvent, occurrenceStart: occurrenceStart, occurrenceEnd: occurrenceEnd)
            else {
                continue
            }

            occurrences.append(calendarEvent)
            emittedStarts.append(occurrenceStart)
        }

        return occurrences
    }

    private func calendarEvent(from localEvent: LocalCalendarEvent, detachedOccurrence: LocalDetachedOccurrence) -> CalendarEvent? {
        let calendarID = detachedOccurrence.calendarID
        guard let calendar = calendars.first(where: { $0.id == calendarID }) ?? calendars.first(where: { $0.id == localEvent.calendarID }) ?? calendars.first else {
            return nil
        }

        return CalendarEvent(
            id: occurrenceID(for: localEvent, occurrenceStart: detachedOccurrence.originalStartDate),
            eventIdentifier: occurrenceID(for: localEvent, occurrenceStart: detachedOccurrence.originalStartDate),
            calendarItemIdentifier: localEvent.id,
            externalIdentifier: localEvent.externalUID,
            sequence: detachedOccurrence.sequence,
            title: detachedOccurrence.title,
            startDate: detachedOccurrence.startDate,
            endDate: detachedOccurrence.endDate,
            occurrenceStartDate: detachedOccurrence.originalStartDate,
            isAllDay: detachedOccurrence.isAllDay,
            availability: detachedOccurrence.availability,
            status: detachedOccurrence.status,
            privacy: detachedOccurrence.privacy,
            importance: detachedOccurrence.importance,
            categories: detachedOccurrence.categories,
            reminderOffsets: detachedOccurrence.reminderOffsets,
            timeZoneIdentifier: detachedOccurrence.timeZoneIdentifier,
            isRecurring: true,
            isDetached: true,
            calendarID: calendar.id,
            calendarTitle: calendar.title,
            sourceTitle: "Working Calendar",
            calendarColor: calendar.color,
            location: detachedOccurrence.location.nilIfBlank,
            notes: detachedOccurrence.notes.nilIfBlank,
            url: URL(string: detachedOccurrence.urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
            responseStatus: detachedOccurrence.myResponseStatus,
            responseStatusIsExplicit: detachedOccurrence.myResponseStatus != .notInvited,
            attendeeCount: detachedOccurrence.attendees.count,
            organizer: localOrganizer(name: detachedOccurrence.organizerName, email: detachedOccurrence.organizerEmail),
            participants: localParticipants(from: detachedOccurrence.attendees)
        )
    }

    private func calendarEvent(from localEvent: LocalCalendarEvent, occurrenceStart: Date, occurrenceEnd: Date) -> CalendarEvent? {
        guard let calendar = calendars.first(where: { $0.id == localEvent.calendarID }) ?? calendars.first else {
            return nil
        }

        let occurrenceID = occurrenceID(for: localEvent, occurrenceStart: occurrenceStart)

        return CalendarEvent(
            id: occurrenceID,
            eventIdentifier: occurrenceID,
            calendarItemIdentifier: localEvent.id,
            externalIdentifier: localEvent.externalUID,
            sequence: localEvent.sequence,
            title: localEvent.title,
            startDate: occurrenceStart,
            endDate: occurrenceEnd,
            occurrenceStartDate: occurrenceStart,
            isAllDay: localEvent.isAllDay,
            availability: localEvent.availability,
            status: localEvent.status,
            privacy: localEvent.privacy,
            importance: localEvent.importance,
            categories: localEvent.categories,
            reminderOffsets: localEvent.reminderOffsets,
            timeZoneIdentifier: localEvent.timeZoneIdentifier,
            isRecurring: localEvent.isRecurring,
            isDetached: false,
            calendarID: calendar.id,
            calendarTitle: calendar.title,
            sourceTitle: "Working Calendar",
            calendarColor: calendar.color,
            location: localEvent.location.nilIfBlank,
            notes: localEvent.notes.nilIfBlank,
            url: URL(string: localEvent.urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
            responseStatus: localEvent.myResponseStatus,
            responseStatusIsExplicit: localEvent.myResponseStatus != .notInvited,
            attendeeCount: localEvent.attendees.count,
            organizer: localOrganizer(name: localEvent.organizerName, email: localEvent.organizerEmail),
            participants: localParticipants(from: localEvent.attendees)
        )
    }

    private func baseEventID(for event: CalendarEvent) -> String {
        if event.calendarItemIdentifier.hasPrefix(Self.eventIDPrefix) {
            return event.calendarItemIdentifier
        }

        return event.id.components(separatedBy: Self.occurrenceSeparator).first ?? event.id
    }

    private func occurrenceID(for localEvent: LocalCalendarEvent, occurrenceStart: Date) -> String {
        if occurrenceStart.isSameOccurrenceStart(as: localEvent.startDate) {
            return localEvent.id
        }

        return "\(localEvent.id)\(Self.occurrenceSeparator)\(Int(occurrenceStart.timeIntervalSince1970))"
    }

    private func occurrenceStartDate(for event: CalendarEvent, in localEvent: LocalCalendarEvent) -> Date {
        if event.id == localEvent.id {
            return localEvent.startDate
        }

        guard let timestamp = event.id.components(separatedBy: Self.occurrenceSeparator).last,
              let seconds = TimeInterval(timestamp) else {
            return event.startDate
        }

        return Date(timeIntervalSince1970: seconds)
    }

    private func shouldInclude(_ event: LocalCalendarEvent, includeAllDay: Bool) -> Bool {
        selectedCalendarIDs.contains(event.calendarID) && (includeAllDay || !event.isAllDay)
    }

    private func shouldInclude(_ occurrence: LocalDetachedOccurrence, includeAllDay: Bool) -> Bool {
        selectedCalendarIDs.contains(occurrence.calendarID) && (includeAllDay || !occurrence.isAllDay)
    }

    private func normalizedResponseStatus(_ status: EventResponseStatus, hasAttendees: Bool) -> EventResponseStatus {
        if status == .notInvited && hasAttendees {
            return .pending
        }

        if !hasAttendees && status == .pending {
            return .notInvited
        }

        return status
    }

    private func normalizedRecurrenceWeekdays(
        _ weekdays: [Int],
        frequency: LocalRecurrenceFrequency,
        startDate: Date,
        weekStart: Int? = nil,
        timeZoneIdentifier: String? = nil
    ) -> [Int] {
        guard frequency == .weekly else { return [] }
        let normalized = weekdays.normalizedWeekdays
        if !normalized.isEmpty {
            return sortedWeekdays(normalized, weekStart: weekStart)
        }

        return [recurrenceCalendar(timeZoneIdentifier: timeZoneIdentifier).component(.weekday, from: startDate)]
    }

    private func recurrenceWeekdays(for event: LocalCalendarEvent) -> [Int] {
        normalizedRecurrenceWeekdays(
            event.recurrenceWeekdays,
            frequency: event.recurrenceFrequency,
            startDate: event.startDate,
            weekStart: event.recurrenceWeekStart,
            timeZoneIdentifier: event.timeZoneIdentifier
        )
    }

    private func sortedWeekdays(_ weekdays: [Int], weekStart: Int? = nil) -> [Int] {
        let firstWeekday = weekStart ?? Calendar.current.firstWeekday
        return weekdays.normalizedWeekdays.sorted {
            (($0 - firstWeekday + 7) % 7) < (($1 - firstWeekday + 7) % 7)
        }
    }

    private func weeklyOccurrenceStart(weekStart: Date, weekday: Int, matching sourceDate: Date, calendar: Calendar) -> Date? {
        let weekStartWeekday = calendar.component(.weekday, from: weekStart)
        let dayOffset = (weekday - weekStartWeekday + 7) % 7
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) else { return nil }
        return date(on: day, matching: sourceDate, calendar: calendar)
    }

    private func weeklyOccurrenceStarts(
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

    private func recurrenceCalendar(for event: LocalCalendarEvent, weekStart: Int? = nil) -> Calendar {
        recurrenceCalendar(timeZoneIdentifier: event.timeZoneIdentifier, weekStart: weekStart)
    }

    private func recurrenceCalendar(timeZoneIdentifier: String?, weekStart: Int? = nil) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneIdentifier
            .flatMap(TimeZone.init(identifier:))
            ?? TimeZone.current
        if let weekStart {
            calendar.firstWeekday = weekStart
        }
        return calendar
    }

    private func eventDurationSeconds(for localEvent: LocalCalendarEvent) -> TimeInterval {
        max(localEvent.isAllDay ? 24 * 3600 : 5 * 60, localEvent.endDate.timeIntervalSince(localEvent.startDate))
    }

    private func occurrenceEnd(
        for localEvent: LocalCalendarEvent,
        occurrenceStart: Date,
        fallbackDuration: TimeInterval,
        calendar: Calendar
    ) -> Date {
        guard localEvent.isAllDay else {
            return occurrenceStart.addingTimeInterval(fallbackDuration)
        }

        let startDay = calendar.startOfDay(for: localEvent.startDate)
        let endDay = calendar.startOfDay(for: localEvent.endDate)
        let dayCount = max(1, calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 1)
        return calendar.date(byAdding: .day, value: dayCount, to: occurrenceStart)
            ?? occurrenceStart.addingTimeInterval(fallbackDuration)
    }

    private func ordinalWeekdayOccurrence(monthStart: Date, ordinal: Int, weekday: Int, matching sourceDate: Date, calendar: Calendar) -> Date? {
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

    private func monthDayOccurrence(monthStart: Date, day: Int, matching sourceDate: Date, calendar: Calendar) -> Date? {
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

    private func monthAllowed(_ monthStart: Date, months: [Int], calendar: Calendar) -> Bool {
        let normalizedMonths = normalizedRecurrenceMonths(months, frequency: .monthly)
        guard !normalizedMonths.isEmpty else { return true }
        return normalizedMonths.contains(calendar.component(.month, from: monthStart))
    }

    private func recurrenceMonths(for localEvent: LocalCalendarEvent, defaultMonth: Int) -> [Int] {
        let normalizedMonths = normalizedRecurrenceMonths(
            localEvent.recurrenceMonths,
            frequency: localEvent.recurrenceFrequency
        )
        return normalizedMonths.isEmpty ? [defaultMonth] : normalizedMonths
    }

    private func yearlyDateOccurrence(yearStart: Date, month: Int, day: Int, matching sourceDate: Date, calendar: Calendar) -> Date? {
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

    private func date(on day: Date, matching sourceDate: Date, calendar: Calendar) -> Date? {
        date(from: calendar.dateComponents([.year, .month, .day], from: day), matching: sourceDate, calendar: calendar)
    }

    private func date(from sourceComponents: DateComponents, matching sourceDate: Date, calendar: Calendar) -> Date? {
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

    private func upsertDetachedOccurrence(_ occurrence: LocalDetachedOccurrence, eventIndex: Int) {
        guard events.indices.contains(eventIndex) else { return }
        var updatedOccurrence = occurrence

        if let detachedIndex = events[eventIndex].detachedOccurrences.firstIndex(where: { $0.originalStartDate.isSameOccurrenceStart(as: occurrence.originalStartDate) }) {
            let nextSequence = events[eventIndex].detachedOccurrences[detachedIndex].sequence + 1
            updatedOccurrence.sequence = max(updatedOccurrence.sequence, nextSequence)
            events[eventIndex].detachedOccurrences[detachedIndex] = updatedOccurrence
        } else {
            updatedOccurrence.sequence = max(updatedOccurrence.sequence, events[eventIndex].sequence + 1)
            events[eventIndex].detachedOccurrences.append(updatedOccurrence)
        }

        events[eventIndex].excludedOccurrenceStartDates.removeAll { $0.isSameOccurrenceStart(as: updatedOccurrence.originalStartDate) }
        events[eventIndex].hasLocalProviderRecurrenceChanges = true
        bumpEventRevision(at: eventIndex)
    }

    private func bumpEventRevision(at eventIndex: Int, now: Date = Date()) {
        guard events.indices.contains(eventIndex) else { return }
        events[eventIndex].sequence += 1
        events[eventIndex].updatedAt = now
    }

    private func nextDetachedSequence(originalStartDate: Date, eventIndex: Int) -> Int {
        guard events.indices.contains(eventIndex) else { return 1 }
        if let detached = events[eventIndex].detachedOccurrences.first(where: { $0.originalStartDate.isSameOccurrenceStart(as: originalStartDate) }) {
            return detached.sequence + 1
        }
        return events[eventIndex].sequence + 1
    }

    private func detachedOccurrence(
        from localEvent: LocalCalendarEvent,
        originalStartDate: Date,
        now: Date
    ) -> LocalDetachedOccurrence {
        let duration = max(localEvent.isAllDay ? 24 * 3600 : 5 * 60, localEvent.endDate.timeIntervalSince(localEvent.startDate))
        return LocalDetachedOccurrence(
            originalStartDate: originalStartDate,
            sequence: localEvent.sequence,
            calendarID: localEvent.calendarID,
            title: localEvent.title,
            startDate: originalStartDate,
            endDate: originalStartDate.addingTimeInterval(duration),
            isAllDay: localEvent.isAllDay,
            availability: localEvent.availability,
            status: localEvent.status,
            privacy: localEvent.privacy,
            importance: localEvent.importance,
            categories: localEvent.categories,
            reminderOffsets: localEvent.reminderOffsets,
            timeZoneIdentifier: localEvent.timeZoneIdentifier,
            geoCoordinate: localEvent.geoCoordinate,
            organizerName: localEvent.organizerName,
            organizerEmail: localEvent.organizerEmail,
            attendees: localEvent.attendees,
            myResponseStatus: localEvent.myResponseStatus,
            location: localEvent.location,
            notes: localEvent.notes,
            urlString: localEvent.urlString,
            updatedAt: now
        )
    }

    private func detachedOccurrence(
        from event: CalendarEvent,
        originalStartDate: Date,
        startDate: Date,
        endDate: Date,
        timeZoneIdentifier: String,
        geoCoordinate: LocalEventGeoCoordinate?
    ) -> LocalDetachedOccurrence {
        LocalDetachedOccurrence(
            originalStartDate: originalStartDate,
            sequence: event.sequence + 1,
            calendarID: event.calendarID,
            title: event.title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: event.isAllDay,
            availability: event.availability,
            status: event.status,
            privacy: event.privacy,
            importance: event.importance,
            categories: event.categories,
            reminderOffsets: event.reminderOffsets,
            timeZoneIdentifier: timeZoneIdentifier,
            geoCoordinate: geoCoordinate,
            organizerName: event.organizer?.name ?? "",
            organizerEmail: event.organizer?.email ?? "",
            attendees: event.participants.map { participant in
                LocalEventAttendee(
                    name: participant.name,
                    email: participant.email,
                    status: participant.status,
                    type: participant.isRoomLike ? "room" : participant.type,
                    role: participant.role,
                    rsvp: participant.status == .pending,
                    isCurrentUser: participant.isCurrentUser
                )
            },
            myResponseStatus: event.responseStatus,
            location: event.location ?? "",
            notes: event.notes ?? "",
            urlString: event.url?.absoluteString ?? "",
            updatedAt: Date()
        )
    }

    private func localOrganizer(name: String, email: String) -> EventParticipant? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty || !trimmedEmail.isEmpty else { return nil }

        return EventParticipant(
            id: "local-organizer-\(trimmedEmail.isEmpty ? trimmedName : trimmedEmail)",
            name: trimmedName,
            email: trimmedEmail,
                type: "person",
                role: "chair",
                status: .accepted,
                isCurrentUser: false,
                isRoomLike: false
        )
    }

    private func localParticipants(from attendees: [LocalEventAttendee]) -> [EventParticipant] {
        attendees.filter { !$0.isBlank }.map { attendee in
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
    }

    private func excludeOccurrence(_ occurrenceStart: Date, from eventIndex: Int) {
        guard events.indices.contains(eventIndex) else { return }
        if !events[eventIndex].excludedOccurrenceStartDates.containsOccurrenceStart(occurrenceStart) {
            events[eventIndex].excludedOccurrenceStartDates.append(occurrenceStart)
        }
        events[eventIndex].detachedOccurrences.removeAll { $0.originalStartDate.isSameOccurrenceStart(as: occurrenceStart) }
        events[eventIndex].hasLocalProviderRecurrenceChanges = true
        bumpEventRevision(at: eventIndex)
    }

    private func truncateSeries(at occurrenceStart: Date, eventIndex: Int) {
        guard events.indices.contains(eventIndex) else { return }
        let baseStart = events[eventIndex].startDate

        if occurrenceStart <= baseStart {
            events.remove(at: eventIndex)
            return
        }

        let calendar = recurrenceCalendar(for: events[eventIndex])
        let occurrenceDayStart = calendar.startOfDay(for: occurrenceStart)
        guard let previousDay = calendar.date(byAdding: .day, value: -1, to: occurrenceDayStart) else {
            events.remove(at: eventIndex)
            return
        }

        events[eventIndex].recurrenceEndDate = previousDay
        events[eventIndex].excludedOccurrenceStartDates.removeAll { $0 >= occurrenceStart }
        bumpEventRevision(at: eventIndex)
    }

    private func splitRecurringSeriesForFutureChange(at occurrenceStart: Date, eventIndex: Int) -> Int? {
        guard events.indices.contains(eventIndex),
              events[eventIndex].isRecurring
        else {
            return nil
        }

        let source = events[eventIndex]
        guard occurrenceStart > source.startDate,
              !occurrenceStart.isSameOccurrenceStart(as: source.startDate)
        else {
            return eventIndex
        }

        let calendar = recurrenceCalendar(for: source)
        let occurrenceDayStart = calendar.startOfDay(for: occurrenceStart)
        guard let previousDay = calendar.date(byAdding: .day, value: -1, to: occurrenceDayStart) else {
            return nil
        }

        let now = Date()
        let duration = max(source.isAllDay ? 24 * 3600 : 5 * 60, source.endDate.timeIntervalSince(source.startDate))
        var futureEvent = source
        futureEvent.id = "\(Self.eventIDPrefix)\(UUID().uuidString)"
        futureEvent.externalUID = "\(source.externalUID)#future-\(Int(occurrenceStart.timeIntervalSince1970))"
        futureEvent.remoteObjectURLString = ""
        futureEvent.remoteETag = ""
        futureEvent.sequence = source.sequence + 1
        futureEvent.startDate = occurrenceStart
        futureEvent.endDate = occurrenceEnd(
            for: source,
            occurrenceStart: occurrenceStart,
            fallbackDuration: duration,
            calendar: calendar
        )
        futureEvent.additionalOccurrenceStartDates = source.additionalOccurrenceStartDates
            .filter { $0 > occurrenceStart && !$0.isSameOccurrenceStart(as: occurrenceStart) }
            .uniqueOccurrenceStarts
            .sorted()
        futureEvent.excludedOccurrenceStartDates = source.excludedOccurrenceStartDates
            .filter { $0 > occurrenceStart && !$0.isSameOccurrenceStart(as: occurrenceStart) }
            .uniqueOccurrenceStarts
            .sorted()
        futureEvent.detachedOccurrences = source.detachedOccurrences
            .filter { $0.originalStartDate >= occurrenceStart || $0.originalStartDate.isSameOccurrenceStart(as: occurrenceStart) }
            .sorted { $0.originalStartDate < $1.originalStartDate }
        futureEvent.hasLocalProviderRecurrenceChanges = true
        futureEvent.createdAt = now
        futureEvent.updatedAt = now

        events[eventIndex].recurrenceEndDate = previousDay
        events[eventIndex].additionalOccurrenceStartDates.removeAll {
            $0 >= occurrenceStart || $0.isSameOccurrenceStart(as: occurrenceStart)
        }
        events[eventIndex].excludedOccurrenceStartDates.removeAll {
            $0 >= occurrenceStart || $0.isSameOccurrenceStart(as: occurrenceStart)
        }
        events[eventIndex].detachedOccurrences.removeAll {
            $0.originalStartDate >= occurrenceStart || $0.originalStartDate.isSameOccurrenceStart(as: occurrenceStart)
        }
        events[eventIndex].hasLocalProviderRecurrenceChanges = true
        bumpEventRevision(at: eventIndex, now: now)

        events.append(futureEvent)
        return events.count - 1
    }

    private func recurrenceEndLimit(for event: LocalCalendarEvent) -> Date? {
        guard let recurrenceEndDate = event.recurrenceEndDate else { return nil }
        let calendar = recurrenceCalendar(for: event)
        let endOfSelectedDay = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: recurrenceEndDate)
        )
        return endOfSelectedDay ?? recurrenceEndDate
    }

    private func load() {
        let decoder = JSONDecoder()

        if let data = UserDefaults.standard.data(forKey: Keys.calendars),
           let decoded = try? decoder.decode([LocalCalendar].self, from: data),
           !decoded.isEmpty {
            calendars = decoded
        } else {
            calendars = [Self.defaultCalendar]
        }

        let storedSelectedIDs = UserDefaults.standard.stringArray(forKey: Keys.selectedCalendarIDs) ?? []
        let knownCalendarIDs = Set(calendars.map(\.id))
        selectedCalendarIDs = Set(storedSelectedIDs).intersection(knownCalendarIDs)
        if selectedCalendarIDs.isEmpty {
            selectedCalendarIDs = knownCalendarIDs
        }

        if let data = UserDefaults.standard.data(forKey: Keys.events),
           let decoded = try? decoder.decode([LocalCalendarEvent].self, from: data) {
            events = decoded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        if let calendarData = try? encoder.encode(calendars) {
            UserDefaults.standard.set(calendarData, forKey: Keys.calendars)
        }
        if let eventData = try? encoder.encode(events) {
            UserDefaults.standard.set(eventData, forKey: Keys.events)
        }
    }

    private func saveSelectedCalendars() {
        UserDefaults.standard.set(Array(selectedCalendarIDs), forKey: Keys.selectedCalendarIDs)
    }

    private func preferredCalendarForNewEvents() -> LocalCalendar {
        calendars.first { selectedCalendarIDs.contains($0.id) }
            ?? calendars.first
            ?? Self.defaultCalendar
    }

    private func nextColorHex() -> String {
        let palette = ["#15A6C8", "#3B82F6", "#8B5CF6", "#22C55E", "#F59E0B", "#EF4444", "#EC4899"]
        let used = Set(calendars.map(\.colorHex))
        return palette.first { !used.contains($0) } ?? palette[calendars.count % palette.count]
    }

    private func roundedStartDate(for date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = components.minute ?? 0
        let roundedMinute = min(45, ((minute + 14) / 15) * 15)
        return calendar.date(
            bySettingHour: components.hour ?? 9,
            minute: roundedMinute,
            second: 0,
            of: date
        ) ?? date
    }

    private static let defaultCalendar = LocalCalendar(
        id: "\(calendarIDPrefix)primary",
        title: "Working Calendar",
        colorHex: "#15A6C8"
    )
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension LocalCalendarEvent {
    func isOccurrenceExcluded(_ occurrenceStart: Date) -> Bool {
        excludedOccurrenceStartDates.containsOccurrenceStart(occurrenceStart)
    }

    func detachedOccurrence(for occurrenceStart: Date) -> LocalDetachedOccurrence? {
        detachedOccurrences.first { $0.originalStartDate.isSameOccurrenceStart(as: occurrenceStart) }
    }
}

private extension Array where Element == Date {
    var uniqueOccurrenceStarts: [Date] {
        var result: [Date] = []
        for date in self where !result.containsOccurrenceStart(date) {
            result.append(date)
        }
        return result
    }

    func containsOccurrenceStart(_ date: Date) -> Bool {
        contains { $0.isSameOccurrenceStart(as: date) }
    }

    func containsOccurrenceStart(_ date: Date, isAllDay: Bool) -> Bool {
        contains { $0.isSameOccurrenceStart(as: date, isAllDay: isAllDay) }
    }
}

private extension Array where Element == Int {
    var normalizedWeekdays: [Int] {
        Array(Set(filter { (1...7).contains($0) })).sorted()
    }
}

private extension Date {
    var occurrenceKey: Int {
        Int(timeIntervalSince1970)
    }

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

private extension NSColor {
    convenience init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        guard value.count == 6, let intValue = Int(value, radix: 16) else {
            return nil
        }

        let red = CGFloat((intValue >> 16) & 0xff) / 255
        let green = CGFloat((intValue >> 8) & 0xff) / 255
        let blue = CGFloat(intValue & 0xff) / 255
        self.init(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }
}
