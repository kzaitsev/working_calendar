import Foundation

enum ProviderCalDAVPreset: String, CaseIterable, Identifiable {
    case generic
    case iCloud
    case fastmail
    case yahoo
    case nextcloud
    case radicale
    case baikal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .generic: return "Generic"
        case .iCloud: return "iCloud"
        case .fastmail: return "Fastmail"
        case .yahoo: return "Yahoo"
        case .nextcloud: return "Nextcloud"
        case .radicale: return "Radicale"
        case .baikal: return "Baikal"
        }
    }

    var defaultURLString: String {
        switch self {
        case .generic, .nextcloud, .radicale, .baikal: return ""
        case .iCloud: return "https://caldav.icloud.com/"
        case .fastmail: return "https://caldav.fastmail.com/"
        case .yahoo: return "https://caldav.calendar.yahoo.com/"
        }
    }

    var titlePlaceholder: String {
        switch self {
        case .generic: return "Work CalDAV"
        case .iCloud: return "iCloud Calendar"
        case .fastmail: return "Fastmail Calendar"
        case .yahoo: return "Yahoo Calendar"
        case .nextcloud: return "Nextcloud Calendar"
        case .radicale: return "Radicale Calendar"
        case .baikal: return "Baikal Calendar"
        }
    }

    var urlPlaceholder: String {
        switch self {
        case .generic: return "https://caldav.example.com/"
        case .iCloud: return "https://caldav.icloud.com/"
        case .fastmail: return "https://caldav.fastmail.com/"
        case .yahoo: return "https://caldav.calendar.yahoo.com/"
        case .nextcloud: return "https://cloud.example.com/"
        case .radicale: return "https://calendar.example.com/"
        case .baikal: return "https://calendar.example.com/dav.php/"
        }
    }

    var usernamePlaceholder: String {
        switch self {
        case .generic, .fastmail, .yahoo, .nextcloud, .radicale, .baikal:
            return "name@example.com"
        case .iCloud:
            return "apple@example.com"
        }
    }

    var passwordPlaceholder: String {
        switch self {
        case .generic, .fastmail, .yahoo, .nextcloud, .radicale, .baikal:
            return "App password"
        case .iCloud:
            return "App-specific password"
        }
    }

    var guidanceText: String {
        switch self {
        case .generic:
            return "Use the CalDAV server or account root URL. http(s), caldav(s), and standard CalDAV discovery locations are supported."
        case .iCloud:
            return "Use your Apple Account email and an app-specific password."
        case .fastmail:
            return "Use your full Fastmail email address and an app password."
        case .yahoo:
            return "Use your Yahoo email address and an app password."
        case .nextcloud:
            return "Paste the Nextcloud base URL; discovery will find the calendar home."
        case .radicale:
            return "Use your Radicale server root URL. Working Calendar will discover calendars through standard CalDAV."
        case .baikal:
            return "Use the Baikal CalDAV URL from its dashboard, commonly /dav.php/ or /html/dav.php/."
        }
    }

    var hasSuggestedURL: Bool {
        !defaultURLString.isEmpty
    }
}
