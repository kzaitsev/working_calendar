import AppKit
import Foundation

struct EventParticipant: Identifiable, Hashable {
    let id: String
    let name: String
    let email: String
    let type: String
    let role: String
    let status: EventResponseStatus
    let isCurrentUser: Bool
    let isRoomLike: Bool

    var displayName: String {
        if !name.isEmpty { return name }
        if !email.isEmpty { return email }
        return "Participant"
    }

    var searchableText: String {
        [name, email, type, role, status.rawValue]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum MeetingPlatform: String, CaseIterable, Hashable {
    case zoom
    case googleMeet
    case microsoftTeams
    case skypeForBusiness
    case webex
    case whereby
    case around
    case tuple
    case goToMeeting
    case blueJeans
    case ringCentral
    case amazonChime
    case slackHuddle
    case faceTime
    case jitsi
    case discord
    case online

    var title: String {
        switch self {
        case .zoom: return "Zoom"
        case .googleMeet: return "Google Meet"
        case .microsoftTeams: return "Microsoft Teams"
        case .skypeForBusiness: return "Skype/Lync"
        case .webex: return "Webex"
        case .whereby: return "Whereby"
        case .around: return "Around"
        case .tuple: return "Tuple"
        case .goToMeeting: return "GoTo Meeting"
        case .blueJeans: return "BlueJeans"
        case .ringCentral: return "RingCentral"
        case .amazonChime: return "Amazon Chime"
        case .slackHuddle: return "Slack Huddle"
        case .faceTime: return "FaceTime"
        case .jitsi: return "Jitsi"
        case .discord: return "Discord"
        case .online: return "Online"
        }
    }

    var symbolName: String {
        switch self {
        case .zoom, .googleMeet, .microsoftTeams, .skypeForBusiness, .webex, .whereby, .around, .tuple, .goToMeeting, .blueJeans, .ringCentral, .amazonChime, .slackHuddle, .faceTime, .jitsi, .discord:
            return "video.fill"
        case .online:
            return "link"
        }
    }

    init?(url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let text = url.absoluteString.lowercased()

        if ["zoommtg", "zoomus"].contains(scheme)
            || host.contains("zoom.us")
            || host.contains("zoom.com")
            || host.contains("zoomgov.com")
            || text.contains("zoom.us/j/") {
            self = .zoom
        } else if host == "meet.google.com" || host.hasSuffix(".meet.google.com") || text.contains("meet.google.com/") {
            self = .googleMeet
        } else if ["msteams", "ms-teams"].contains(scheme)
            || host.contains("teams.microsoft.com")
            || host.contains("teams.live.com")
            || host.contains("msteams.link") {
            self = .microsoftTeams
        } else if ["skype", "lync"].contains(scheme)
            || host.contains("meet.lync.com")
            || host.contains("join.skype.com") {
            self = .skypeForBusiness
        } else if ["webex", "wbx"].contains(scheme) || host.contains("webex.com") {
            self = .webex
        } else if host.contains("whereby.com") {
            self = .whereby
        } else if host.contains("around.co") {
            self = .around
        } else if host.contains("tuple.app") {
            self = .tuple
        } else if host.contains("gotomeeting.com") || host.contains("meet.goto.com") || host.contains("gotomeet.me") {
            self = .goToMeeting
        } else if host.contains("bluejeans.com") {
            self = .blueJeans
        } else if host.contains("ringcentral.com") {
            self = .ringCentral
        } else if ["chime"].contains(scheme) || host.contains("chime.aws") {
            self = .amazonChime
        } else if host.contains("huddles.slack.com") || text.contains("slack.com/huddle") {
            self = .slackHuddle
        } else if ["facetime"].contains(scheme) || host.contains("facetime.apple.com") {
            self = .faceTime
        } else if host.contains("meet.jit.si") || host.contains("jitsi.8x8.vc") {
            self = .jitsi
        } else if host.contains("discord.gg") || host.contains("discord.com") {
            self = .discord
        } else if ["http", "https", "facetime"].contains(scheme) {
            self = .online
        } else {
            return nil
        }
    }
}

struct MeetingMethod: Hashable {
    let platform: MeetingPlatform?
    let hasPhysicalLocation: Bool

    var title: String {
        switch (platform, hasPhysicalLocation) {
        case (.some(let platform), true):
            return "\(platform.title) + room"
        case (.some(let platform), false):
            return platform.title
        case (.none, true):
            return "In person"
        case (.none, false):
            return "Not specified"
        }
    }

    var symbolName: String {
        switch (platform, hasPhysicalLocation) {
        case (.some, true):
            return "rectangle.connected.to.line.below"
        case (.some(let platform), false):
            return platform.symbolName
        case (.none, true):
            return "person.2.fill"
        case (.none, false):
            return "questionmark.circle"
        }
    }

    var searchableText: String {
        [
            title,
            platform?.title ?? "",
            hasPhysicalLocation ? "in person office room переговорка" : ""
        ]
        .joined(separator: " ")
    }

    var isSpecified: Bool {
        platform != nil || hasPhysicalLocation
    }
}

enum CalendarEventAvailability: String, Codable, CaseIterable, Hashable, Identifiable {
    case busy
    case free

    var id: String { rawValue }

    var title: String {
        switch self {
        case .busy: return "Busy"
        case .free: return "Free"
        }
    }

    var symbolName: String {
        switch self {
        case .busy: return "circle.fill"
        case .free: return "circle"
        }
    }

    var isBusy: Bool {
        self == .busy
    }
}

enum CalendarEventStatus: String, Codable, CaseIterable, Hashable, Identifiable {
    case confirmed
    case tentative
    case cancelled
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .confirmed: return "Confirmed"
        case .tentative: return "Tentative"
        case .cancelled: return "Cancelled"
        case .unknown: return "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .confirmed: return "checkmark.circle"
        case .tentative: return "questionmark.circle"
        case .cancelled: return "xmark.circle"
        case .unknown: return "circle.dashed"
        }
    }

    var searchableText: String {
        title
    }
}

enum CalendarEventPrivacy: String, Codable, CaseIterable, Hashable, Identifiable {
    case `public`
    case `private`
    case confidential

    var id: String { rawValue }

    var title: String {
        switch self {
        case .public: return "Public"
        case .private: return "Private"
        case .confidential: return "Confidential"
        }
    }

    var symbolName: String {
        switch self {
        case .public: return "globe"
        case .private: return "lock"
        case .confidential: return "lock.shield"
        }
    }

    var searchableText: String {
        title
    }
}

enum CalendarEventImportance: String, Codable, CaseIterable, Hashable, Identifiable {
    case low
    case normal
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }

    var symbolName: String {
        switch self {
        case .low: return "arrow.down.circle"
        case .normal: return "minus.circle"
        case .high: return "exclamationmark.circle"
        }
    }

    var searchableText: String {
        title
    }
}

func normalizedEventCategories(_ categories: [String]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []

    for category in categories {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let key = trimmed.lowercased()
        guard seen.insert(key).inserted else { continue }
        result.append(trimmed)
    }

    return result
}

func eventCategories(from text: String) -> [String] {
    normalizedEventCategories(text.split(separator: ",").map(String.init))
}

func normalizedReminderOffsets(_ offsets: [Int]) -> [Int] {
    Array(Set(offsets.filter { (0...40_320).contains($0) })).sorted()
}

func reminderOffsets(from text: String) -> [Int] {
    normalizedReminderOffsets(
        text
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    )
}

func reminderOffsetTitle(_ minutes: Int) -> String {
    if minutes == 0 {
        return "At start"
    }

    if minutes % (24 * 60) == 0 {
        let days = minutes / (24 * 60)
        return "\(days)d before"
    }

    if minutes % 60 == 0 {
        let hours = minutes / 60
        return "\(hours)h before"
    }

    return "\(minutes)m before"
}

func reminderOffsetsTitle(_ offsets: [Int]) -> String {
    normalizedReminderOffsets(offsets).map(reminderOffsetTitle).joined(separator: ", ")
}

struct CalendarEvent: Identifiable, Hashable {
    let id: String
    let eventIdentifier: String
    let calendarItemIdentifier: String
    let externalIdentifier: String
    let sequence: Int
    let title: String
    let startDate: Date
    let endDate: Date
    let occurrenceStartDate: Date
    let isAllDay: Bool
    let availability: CalendarEventAvailability
    let status: CalendarEventStatus
    let privacy: CalendarEventPrivacy
    let importance: CalendarEventImportance
    let categories: [String]
    let reminderOffsets: [Int]
    let timeZoneIdentifier: String?
    let isRecurring: Bool
    let isDetached: Bool
    let calendarID: String
    let calendarTitle: String
    let sourceTitle: String
    let calendarColor: NSColor
    let location: String?
    let notes: String?
    let url: URL?
    let responseStatus: EventResponseStatus
    let responseStatusIsExplicit: Bool
    let attendeeCount: Int
    let organizer: EventParticipant?
    let participants: [EventParticipant]

    var joinURL: URL? {
        MeetingLinkExtractor.bestLink(eventURL: url, textFields: [title, location, notes].compactMap { $0 })
    }

    var meetingPlatform: MeetingPlatform? {
        joinURL.flatMap(MeetingPlatform.init(url:))
    }

    var meetingMethod: MeetingMethod {
        MeetingMethod(platform: meetingPlatform, hasPhysicalLocation: physicalLocation != nil)
    }

    var durationMinutes: Int {
        max(0, Int(endDate.timeIntervalSince(startDate) / 60))
    }

    var searchableText: String {
        let responseText = responseStatusIsExplicit
            ? [responseStatus.title, gridResponseBadge?.title ?? ""].joined(separator: " ")
            : ""
        return [
            title,
            calendarTitle,
            sourceTitle,
            location ?? "",
            notes ?? "",
            participantText,
            roomText,
            organizer?.searchableText ?? "",
            meetingMethod.searchableText,
            status.searchableText,
            responseText,
            privacy.searchableText,
            importance.searchableText,
            categories.joined(separator: " "),
            reminderOffsetsTitle(reminderOffsets),
            joinURL?.absoluteString ?? ""
        ]
        .joined(separator: " ")
    }

    var roomParticipants: [EventParticipant] {
        participants.filter(\.isRoomLike)
    }

    var participantText: String {
        participants.map(\.searchableText).joined(separator: " ")
    }

    var roomText: String {
        roomParticipants.map(\.searchableText).joined(separator: " ")
    }

    var organizerText: String {
        organizer?.searchableText ?? ""
    }

    var physicalLocation: String? {
        let rawLocation = location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rooms = roomParticipants.map(\.displayName).filter { !$0.isEmpty }
        let roomLocation = rooms.isEmpty ? nil : rooms.joined(separator: ", ")

        if let rawLocation, !rawLocation.isEmpty, !rawLocation.looksLikeMeetingURL {
            return rawLocation
        }

        return roomLocation
    }

    var bestLocation: String? {
        physicalLocation
    }

    var needsResponse: Bool {
        responseStatusIsExplicit && responseStatus.requiresAttention
    }

    var gridResponseBadge: CalendarGridResponseBadge? {
        guard responseStatusIsExplicit else { return nil }
        return CalendarGridResponseBadge(status: responseStatus)
    }

    var didNotRespondByCurrentUser: Bool {
        responseStatusIsExplicit && responseStatus == .pending
    }

    var isAcceptedByCurrentUser: Bool {
        responseStatusIsExplicit && responseStatus == .accepted
    }

    var isDeclinedByCurrentUser: Bool {
        responseStatusIsExplicit && responseStatus == .declined
    }

    var isTentativeByCurrentUser: Bool {
        responseStatusIsExplicit && responseStatus == .tentative
    }

    func minutesUntilStart(from date: Date = Date()) -> Int {
        Int(ceil(startDate.timeIntervalSince(date) / 60))
    }

    func isHappening(at date: Date = Date()) -> Bool {
        startDate <= date && endDate >= date
    }

    func countsTowardDockUpcoming(at date: Date = Date()) -> Bool {
        guard !isAllDay,
              endDate > date,
              status != .cancelled
        else {
            return false
        }

        return !(responseStatusIsExplicit && (responseStatus == .declined || responseStatus == .canceled))
    }

    func gridVenueText(displayLocation: String?) -> String {
        if let displayLocation = displayLocation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayLocation.isEmpty {
            return displayLocation
        }

        if meetingMethod.isSpecified {
            return meetingMethod.title
        }

        return calendarTitle
    }
}

enum EventResponseStatus: String, Codable, CaseIterable, Hashable, Identifiable {
    case notInvited
    case unknown
    case pending
    case accepted
    case declined
    case tentative
    case delegated
    case completed
    case inProcess
    case canceled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notInvited: return "Not invited"
        case .unknown: return "Unknown"
        case .pending: return "Pending"
        case .accepted: return "Accepted"
        case .declined: return "Declined"
        case .tentative: return "Tentative"
        case .delegated: return "Delegated"
        case .completed: return "Completed"
        case .inProcess: return "In process"
        case .canceled: return "Canceled"
        }
    }

    var requiresAttention: Bool {
        switch self {
        case .unknown, .pending, .inProcess:
            return true
        default:
            return false
        }
    }

    var isResolvedResponse: Bool {
        self != .notInvited && !requiresAttention
    }

}

struct CalendarGridResponseBadge: Hashable {
    let title: String
    let compactTitle: String
    let symbolName: String
    let color: NSColor
    let requiresAttention: Bool

    init(status: EventResponseStatus) {
        requiresAttention = status.requiresAttention

        switch status {
        case .notInvited:
            title = "No invite"
            compactTitle = "No invite"
            symbolName = "person.crop.circle.badge.questionmark"
            color = .secondaryLabelColor
        case .unknown, .pending, .inProcess:
            title = "No reply"
            compactTitle = "No reply"
            symbolName = "envelope.badge"
            color = .systemBlue
        case .accepted:
            title = "Accepted"
            compactTitle = "Yes"
            symbolName = "checkmark.circle.fill"
            color = .systemGreen
        case .declined:
            title = "Declined"
            compactTitle = "No"
            symbolName = "xmark.circle.fill"
            color = .systemRed
        case .tentative:
            title = "Maybe"
            compactTitle = "Maybe"
            symbolName = "questionmark.circle.fill"
            color = .systemOrange
        case .delegated:
            title = "Delegated"
            compactTitle = "Delegated"
            symbolName = "arrowshape.turn.up.right.circle.fill"
            color = .systemPurple
        case .completed:
            title = "Completed"
            compactTitle = "Done"
            symbolName = "checkmark.seal.fill"
            color = .systemGreen
        case .canceled:
            title = "Canceled"
            compactTitle = "Canceled"
            symbolName = "xmark.octagon.fill"
            color = .systemRed
        }
    }
}

enum AlertPriority: String, Codable, CaseIterable, Identifiable {
    case normal
    case important
    case critical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .important: return "Important"
        case .critical: return "Critical"
        }
    }

    var symbolName: String {
        switch self {
        case .normal: return "bell"
        case .important: return "bell.badge"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }

    var accentColor: NSColor {
        switch self {
        case .normal: return NSColor.systemTeal
        case .important: return NSColor.systemOrange
        case .critical: return NSColor.systemRed
        }
    }
}

enum CalendarEventResponse: String, Codable, CaseIterable, Identifiable {
    case accept
    case maybe
    case decline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accept: return "Accept"
        case .maybe: return "Maybe"
        case .decline: return "Decline"
        }
    }

    var responseStatus: EventResponseStatus {
        switch self {
        case .accept: return .accepted
        case .maybe: return .tentative
        case .decline: return .declined
        }
    }

    init?(ruleAction: RuleResponseAction) {
        switch ruleAction {
        case .none:
            return nil
        case .accept:
            self = .accept
        case .maybe:
            self = .maybe
        case .decline:
            self = .decline
        }
    }
}

enum CalendarEventRemovalScope: String, CaseIterable, Identifiable {
    case thisEvent
    case futureEvents
    case allEvents

    var id: String { rawValue }
}

enum CalendarEventChangeScope: String, CaseIterable, Identifiable {
    case thisEvent
    case futureEvents
    case allEvents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisEvent: return "This Event"
        case .futureEvents: return "This and Future Events"
        case .allEvents: return "All Events"
        }
    }
}

enum CalendarEventResponseScope: String, Codable, CaseIterable, Identifiable {
    case thisEvent
    case allEvents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisEvent: return "This Event"
        case .allEvents: return "All Events"
        }
    }

    var ruleTitle: String {
        switch self {
        case .thisEvent: return "this occurrence"
        case .allEvents: return "whole series"
        }
    }
}

enum RuleResponseAction: String, Codable, CaseIterable, Identifiable {
    case none
    case accept
    case maybe
    case decline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Do not respond"
        case .accept: return "Accept"
        case .maybe: return "Maybe"
        case .decline: return "Decline"
        }
    }

    var symbolName: String {
        switch self {
        case .none: return "minus.circle"
        case .accept: return "checkmark.circle"
        case .maybe: return "questionmark.circle"
        case .decline: return "xmark.circle"
        }
    }

    var responseStatus: EventResponseStatus? {
        switch self {
        case .none: return nil
        case .accept: return .accepted
        case .maybe: return .tentative
        case .decline: return .declined
        }
    }
}

enum RuleConditionMode: String, Codable, CaseIterable, Identifiable {
    case all
    case any
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .any: return "Any"
        case .none: return "None"
        }
    }

    var sentence: String {
        switch self {
        case .all: return "If all conditions match"
        case .any: return "If any condition matches"
        case .none: return "If none of these match"
        }
    }
}

enum RuleConditionField: String, Codable, CaseIterable, Identifiable {
    case title
    case calendar
    case account
    case importance
    case categories
    case reminders
    case location
    case notes
    case participant
    case participantName
    case participantEmail
    case organizer
    case organizerEmail
    case room
    case roomName
    case roomEmail
    case anyText
    case meetingLink
    case meetingMethod
    case meetingProvider
    case responseStatus
    case myResponse
    case iAccepted
    case iMaybe
    case iDeclined
    case iDidNotRespond
    case needsMyResponse
    case minutesUntilStart
    case durationMinutes
    case isRecurring
    case hasAttendees

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: return "Title"
        case .calendar: return "Calendar"
        case .account: return "Account"
        case .importance: return "Importance"
        case .categories: return "Categories"
        case .reminders: return "Reminders"
        case .location: return "Location"
        case .notes: return "Notes"
        case .participant: return "Participant"
        case .participantName: return "Participant name"
        case .participantEmail: return "Participant email"
        case .organizer: return "Organizer"
        case .organizerEmail: return "Organizer email"
        case .room: return "Room/resource"
        case .roomName: return "Room name"
        case .roomEmail: return "Room email"
        case .anyText: return "Any text"
        case .meetingLink: return "Meeting link"
        case .meetingMethod: return "Meeting method"
        case .meetingProvider: return "Meeting provider"
        case .responseStatus: return "Response status"
        case .myResponse: return "My response"
        case .iAccepted: return "I accepted"
        case .iMaybe: return "I said maybe"
        case .iDeclined: return "I declined"
        case .iDidNotRespond: return "I did not respond"
        case .needsMyResponse: return "Needs my response"
        case .minutesUntilStart: return "Minutes until start"
        case .durationMinutes: return "Duration minutes"
        case .isRecurring: return "Recurring"
        case .hasAttendees: return "Has attendees"
        }
    }

    var isNumeric: Bool {
        self == .minutesUntilStart || self == .durationMinutes
    }

    var isBoolean: Bool {
        self == .isRecurring
            || self == .hasAttendees
            || self == .iAccepted
            || self == .iMaybe
            || self == .iDeclined
            || self == .iDidNotRespond
            || self == .needsMyResponse
    }

    var suggestedPlaceholder: String {
        switch self {
        case .responseStatus, .myResponse: return "pending, tentative, accepted..."
        case .minutesUntilStart: return "10"
        case .durationMinutes: return "30"
        case .isRecurring, .hasAttendees, .iAccepted, .iMaybe, .iDeclined, .iDidNotRespond, .needsMyResponse: return "true"
        case .room, .roomName: return "CY-Office-1st-Conference"
        case .roomEmail: return "room@example.com"
        case .participant, .participantName: return "Person or room name"
        case .participantEmail, .organizerEmail: return "name@example.com"
        case .meetingMethod: return "Zoom + room"
        case .meetingProvider: return "Zoom, Google Meet, Teams..."
        case .importance: return "high, normal, low"
        case .categories: return "customer, prod, Google color 5..."
        case .reminders: return "5m before, 1h before..."
        default: return "Text to match"
        }
    }
}

enum RuleConditionComparison: String, Codable, CaseIterable, Identifiable {
    case contains
    case doesNotContain
    case isEqualTo
    case isNotEqualTo
    case exists
    case doesNotExist
    case isLessThanOrEqualTo
    case isGreaterThanOrEqualTo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contains: return "contains"
        case .doesNotContain: return "does not contain"
        case .isEqualTo: return "is"
        case .isNotEqualTo: return "is not"
        case .exists: return "exists"
        case .doesNotExist: return "does not exist"
        case .isLessThanOrEqualTo: return "is at most"
        case .isGreaterThanOrEqualTo: return "is at least"
        }
    }
}

struct RulePredicate: Identifiable, Codable, Equatable {
    var id: UUID
    var field: RuleConditionField
    var comparison: RuleConditionComparison
    var value: String

    init(
        id: UUID = UUID(),
        field: RuleConditionField = .title,
        comparison: RuleConditionComparison = .contains,
        value: String = ""
    ) {
        self.id = id
        self.field = field
        self.comparison = comparison
        self.value = value
    }

    func matches(_ event: CalendarEvent, now: Date = Date()) -> Bool {
        if field.isNumeric {
            return compare(number: numericValue(for: event, now: now), to: Double(value) ?? 0)
        }

        if field.isBoolean {
            let wanted = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let boolValue = booleanValue(for: event)
            let expected = !["false", "no", "0", "off"].contains(wanted)
            return comparison == .isNotEqualTo ? boolValue != expected : boolValue == expected
        }

        let text = textValue(for: event)
        let needle = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalized = text.lowercased()

        switch comparison {
        case .contains:
            guard !needle.isEmpty else { return false }
            return normalized.contains(needle)
        case .doesNotContain:
            guard !needle.isEmpty else { return false }
            return !normalized.contains(needle)
        case .isEqualTo:
            guard !needle.isEmpty else { return false }
            return normalized == needle
        case .isNotEqualTo:
            guard !needle.isEmpty else { return false }
            return normalized != needle
        case .exists:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .doesNotExist:
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .isLessThanOrEqualTo, .isGreaterThanOrEqualTo:
            return false
        }
    }

    private func textValue(for event: CalendarEvent) -> String {
        switch field {
        case .title: return event.title
        case .calendar: return event.calendarTitle
        case .account: return event.sourceTitle
        case .importance: return event.importance.rawValue
        case .categories: return event.categories.joined(separator: " ")
        case .reminders: return reminderOffsetsTitle(event.reminderOffsets)
        case .location: return event.location ?? ""
        case .notes: return event.notes ?? ""
        case .participant: return event.participantText
        case .participantName: return event.participants.map(\.displayName).joined(separator: " ")
        case .participantEmail: return event.participants.map(\.email).joined(separator: " ")
        case .organizer: return event.organizerText
        case .organizerEmail: return event.organizer?.email ?? ""
        case .room: return event.roomText
        case .roomName: return event.roomParticipants.map(\.displayName).joined(separator: " ")
        case .roomEmail: return event.roomParticipants.map(\.email).joined(separator: " ")
        case .anyText: return event.searchableText
        case .meetingLink: return event.joinURL?.absoluteString ?? ""
        case .meetingMethod: return event.meetingMethod.searchableText
        case .meetingProvider: return event.meetingPlatform?.title ?? ""
        case .responseStatus, .myResponse: return event.responseStatus.rawValue
        case .minutesUntilStart, .durationMinutes, .isRecurring, .hasAttendees, .iAccepted, .iMaybe, .iDeclined, .iDidNotRespond, .needsMyResponse:
            return ""
        }
    }

    private func numericValue(for event: CalendarEvent, now: Date) -> Double {
        switch field {
        case .minutesUntilStart:
            return Double(event.minutesUntilStart(from: now))
        case .durationMinutes:
            return Double(event.durationMinutes)
        default:
            return 0
        }
    }

    private func booleanValue(for event: CalendarEvent) -> Bool {
        switch field {
        case .isRecurring:
            return event.isRecurring
        case .hasAttendees:
            return event.attendeeCount > 0
        case .iAccepted:
            return event.isAcceptedByCurrentUser
        case .iMaybe:
            return event.isTentativeByCurrentUser
        case .iDeclined:
            return event.isDeclinedByCurrentUser
        case .iDidNotRespond:
            return event.didNotRespondByCurrentUser
        case .needsMyResponse:
            return event.needsResponse
        default:
            return false
        }
    }

    private func compare(number: Double, to target: Double) -> Bool {
        switch comparison {
        case .isLessThanOrEqualTo:
            return number <= target
        case .isGreaterThanOrEqualTo:
            return number >= target
        case .isEqualTo:
            return number == target
        case .isNotEqualTo:
            return number != target
        default:
            return false
        }
    }
}

struct RuleConditionGroup: Identifiable, Codable, Equatable {
    var id: UUID
    var mode: RuleConditionMode
    var conditions: [RuleCondition]

    init(id: UUID = UUID(), mode: RuleConditionMode = .all, conditions: [RuleCondition] = []) {
        self.id = id
        self.mode = mode
        self.conditions = conditions
    }

    func matches(_ event: CalendarEvent, now: Date = Date()) -> Bool {
        guard !conditions.isEmpty else { return true }

        switch mode {
        case .all:
            return conditions.allSatisfy { $0.matches(event, now: now) }
        case .any:
            return conditions.contains { $0.matches(event, now: now) }
        case .none:
            return !conditions.contains { $0.matches(event, now: now) }
        }
    }
}

enum RuleCondition: Codable, Equatable, Identifiable {
    case predicate(RulePredicate)
    case group(RuleConditionGroup)

    var id: UUID {
        switch self {
        case .predicate(let predicate): return predicate.id
        case .group(let group): return group.id
        }
    }

    func matches(_ event: CalendarEvent, now: Date = Date()) -> Bool {
        switch self {
        case .predicate(let predicate):
            return predicate.matches(event, now: now)
        case .group(let group):
            return group.matches(event, now: now)
        }
    }

    static func predicate(
        field: RuleConditionField,
        comparison: RuleConditionComparison,
        value: String
    ) -> RuleCondition {
        .predicate(RulePredicate(field: field, comparison: comparison, value: value))
    }
}

struct AlertRule: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var enabled: Bool
    var priority: AlertPriority
    var responseAction: RuleResponseAction
    var responseScope: CalendarEventResponseScope
    var locationOverride: String
    var condition: RuleConditionGroup?
    var calendarID: String?
    var titleKeywords: String
    var leadMinutes: Int
    var repeatEverySeconds: Int
    var repeatCount: Int
    var stickyOverlay: Bool
    var systemNotification: Bool
    var playSound: Bool
    var speak: Bool
    var bounceDock: Bool

    init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        priority: AlertPriority,
        responseAction: RuleResponseAction = .none,
        responseScope: CalendarEventResponseScope = .thisEvent,
        locationOverride: String = "",
        condition: RuleConditionGroup? = nil,
        calendarID: String? = nil,
        titleKeywords: String = "",
        leadMinutes: Int,
        repeatEverySeconds: Int,
        repeatCount: Int,
        stickyOverlay: Bool,
        systemNotification: Bool,
        playSound: Bool,
        speak: Bool,
        bounceDock: Bool
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.priority = priority
        self.responseAction = responseAction
        self.responseScope = responseScope
        self.locationOverride = locationOverride
        self.condition = condition
        self.calendarID = calendarID
        self.titleKeywords = titleKeywords
        self.leadMinutes = leadMinutes
        self.repeatEverySeconds = repeatEverySeconds
        self.repeatCount = repeatCount
        self.stickyOverlay = stickyOverlay
        self.systemNotification = systemNotification
        self.playSound = playSound
        self.speak = speak
        self.bounceDock = bounceDock
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case enabled
        case priority
        case responseAction
        case responseScope
        case locationOverride
        case condition
        case calendarID
        case titleKeywords
        case leadMinutes
        case repeatEverySeconds
        case repeatCount
        case stickyOverlay
        case systemNotification
        case playSound
        case speak
        case bounceDock
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Rule"
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        priority = try container.decodeIfPresent(AlertPriority.self, forKey: .priority) ?? .normal
        responseAction = try container.decodeIfPresent(RuleResponseAction.self, forKey: .responseAction) ?? .none
        responseScope = try container.decodeIfPresent(CalendarEventResponseScope.self, forKey: .responseScope) ?? .thisEvent
        locationOverride = try container.decodeIfPresent(String.self, forKey: .locationOverride) ?? ""
        condition = try container.decodeIfPresent(RuleConditionGroup.self, forKey: .condition)
        calendarID = try container.decodeIfPresent(String.self, forKey: .calendarID)
        titleKeywords = try container.decodeIfPresent(String.self, forKey: .titleKeywords) ?? ""
        leadMinutes = try container.decodeIfPresent(Int.self, forKey: .leadMinutes) ?? 5
        repeatEverySeconds = try container.decodeIfPresent(Int.self, forKey: .repeatEverySeconds) ?? 90
        repeatCount = try container.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 2
        stickyOverlay = try container.decodeIfPresent(Bool.self, forKey: .stickyOverlay) ?? false
        systemNotification = try container.decodeIfPresent(Bool.self, forKey: .systemNotification) ?? true
        playSound = try container.decodeIfPresent(Bool.self, forKey: .playSound) ?? true
        speak = try container.decodeIfPresent(Bool.self, forKey: .speak) ?? false
        bounceDock = try container.decodeIfPresent(Bool.self, forKey: .bounceDock) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(priority, forKey: .priority)
        try container.encode(responseAction, forKey: .responseAction)
        try container.encode(responseScope, forKey: .responseScope)
        try container.encode(locationOverride, forKey: .locationOverride)
        try container.encodeIfPresent(condition, forKey: .condition)
        try container.encodeIfPresent(calendarID, forKey: .calendarID)
        try container.encode(titleKeywords, forKey: .titleKeywords)
        try container.encode(leadMinutes, forKey: .leadMinutes)
        try container.encode(repeatEverySeconds, forKey: .repeatEverySeconds)
        try container.encode(repeatCount, forKey: .repeatCount)
        try container.encode(stickyOverlay, forKey: .stickyOverlay)
        try container.encode(systemNotification, forKey: .systemNotification)
        try container.encode(playSound, forKey: .playSound)
        try container.encode(speak, forKey: .speak)
        try container.encode(bounceDock, forKey: .bounceDock)
    }

    static let defaults: [AlertRule] = [
        AlertRule(
            name: "Every meeting",
            priority: .normal,
            condition: RuleConditionGroup(mode: .all),
            leadMinutes: 5,
            repeatEverySeconds: 90,
            repeatCount: 2,
            stickyOverlay: false,
            systemNotification: true,
            playSound: true,
            speak: false,
            bounceDock: false
        ),
        AlertRule(
            name: "Important words",
            priority: .important,
            condition: RuleConditionGroup(
                mode: .any,
                conditions: ["1:1", "interview", "customer", "demo", "incident", "prod", "hiring"].map {
                    RuleCondition.predicate(field: .anyText, comparison: .contains, value: $0)
                }
            ),
            leadMinutes: 10,
            repeatEverySeconds: 45,
            repeatCount: 4,
            stickyOverlay: true,
            systemNotification: true,
            playSound: true,
            speak: false,
            bounceDock: true
        ),
        AlertRule(
            name: "Critical starts now",
            priority: .critical,
            condition: RuleConditionGroup(
                mode: .any,
                conditions: ["incident", "prod", "launch", "customer", "interview"].map {
                    RuleCondition.predicate(field: .anyText, comparison: .contains, value: $0)
                }
            ),
            leadMinutes: 2,
            repeatEverySeconds: 20,
            repeatCount: 6,
            stickyOverlay: true,
            systemNotification: true,
            playSound: true,
            speak: true,
            bounceDock: true
        )
    ]

    func matches(_ event: CalendarEvent, now: Date = Date()) -> Bool {
        guard enabled else { return false }
        if condition == nil, let calendarID, calendarID != event.calendarID {
            return false
        }
        return effectiveCondition.matches(event, now: now)
    }

    var effectiveCondition: RuleConditionGroup {
        if let condition { return condition }

        var conditions: [RuleCondition] = []

        let keywords = titleKeywords
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !keywords.isEmpty {
            conditions.append(.group(RuleConditionGroup(
                mode: .any,
                conditions: keywords.map { .predicate(field: .anyText, comparison: .contains, value: $0) }
            )))
        }

        return RuleConditionGroup(mode: .all, conditions: conditions)
    }
}

struct MeetingAlert: Identifiable, Equatable {
    let id: UUID
    let event: CalendarEvent
    let rule: AlertRule
    let firedAt: Date
    let fireIndex: Int
    let requiresRuleStoreMembership: Bool

    init(
        id: UUID = UUID(),
        event: CalendarEvent,
        rule: AlertRule,
        firedAt: Date,
        fireIndex: Int,
        requiresRuleStoreMembership: Bool = true
    ) {
        self.id = id
        self.event = event
        self.rule = rule
        self.firedAt = firedAt
        self.fireIndex = fireIndex
        self.requiresRuleStoreMembership = requiresRuleStoreMembership
    }

    var startsText: String {
        let minutes = event.minutesUntilStart(from: firedAt)
        if minutes > 1 { return "Starts in \(minutes) min" }
        if minutes == 1 { return "Starts in 1 min" }
        if minutes == 0 { return "Starts now" }
        return "Started \(abs(minutes)) min ago"
    }

    var displayLocation: String? {
        let override = rule.locationOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return override }
        return event.bestLocation
    }
}

private extension String {
    var looksLikeMeetingURL: Bool {
        MeetingLinkExtractor.bestLink(eventURL: nil, textFields: [self]) != nil
    }
}
