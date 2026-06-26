import Foundation

enum CalendarURLNormalizerError: Error {
    case emptyURL
    case unsupportedURLScheme
    case invalidURL
}

enum CalendarURLNormalizer {
    private static let calendarFileExtensions: Set<String> = [
        "ics",
        "ical",
        "icalendar",
        "ifb"
    ]
    private static let googleCalendarIDQueryItemNames: Set<String> = ["src", "cid"]
    private static let googleCalendarIDPathAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    static func subscriptionURL(from value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CalendarURLNormalizerError.emptyURL }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate) else {
            throw CalendarURLNormalizerError.invalidURL
        }

        let scheme = components.scheme?.lowercased()
        if scheme == "webcal" || scheme == "webcals" {
            components.scheme = "https"
        } else if scheme != "http" && scheme != "https" {
            throw CalendarURLNormalizerError.unsupportedURLScheme
        }

        if let googlePublicICalURL = googlePublicICalURL(from: components) {
            return googlePublicICalURL
        }

        guard components.host?.isEmpty == false, let url = components.url else {
            throw CalendarURLNormalizerError.invalidURL
        }

        return url
    }

    static func httpURL(from value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CalendarURLNormalizerError.emptyURL }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate) else {
            throw CalendarURLNormalizerError.invalidURL
        }

        let scheme = components.scheme?.lowercased()
        if scheme == "caldav" {
            components.scheme = "http"
        } else if scheme == "caldavs" {
            components.scheme = "https"
        } else if scheme != "http" && scheme != "https" {
            throw CalendarURLNormalizerError.unsupportedURLScheme
        }

        guard components.host?.isEmpty == false, let url = components.url else {
            throw CalendarURLNormalizerError.invalidURL
        }

        return url
    }

    static func isLikelySubscriptionURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "webcal" || scheme == "webcals" {
            return true
        }

        guard scheme == "http" || scheme == "https" else {
            return false
        }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           googlePublicICalURL(from: components) != nil {
            return true
        }

        return calendarFileExtensions.contains(url.pathExtension.lowercased())
    }

    private static func googlePublicICalURL(from components: URLComponents) -> URL? {
        guard isGoogleCalendarHost(components.host),
              let calendarID = googleCalendarID(from: components),
              let encodedCalendarID = calendarID.addingPercentEncoding(withAllowedCharacters: googleCalendarIDPathAllowed)
        else {
            return nil
        }

        var result = URLComponents()
        result.scheme = "https"
        result.host = "calendar.google.com"
        result.percentEncodedPath = "/calendar/ical/\(encodedCalendarID)/public/basic.ics"
        return result.url
    }

    private static func googleCalendarID(from components: URLComponents) -> String? {
        guard let queryItems = components.queryItems else { return nil }

        for item in queryItems {
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard googleCalendarIDQueryItemNames.contains(name),
                  let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else {
                continue
            }
            return value
        }

        return nil
    }

    private static func isGoogleCalendarHost(_ host: String?) -> Bool {
        switch host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "calendar.google.com", "www.calendar.google.com":
            return true
        default:
            return false
        }
    }
}
