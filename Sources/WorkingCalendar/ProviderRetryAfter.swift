import Foundation

protocol ProviderRetryAfterError {
    var providerRetryAfterSeconds: Int? { get }
}

enum ProviderRetryAfter {
    static let maximumSeconds = 24 * 60 * 60
    private static let retryAfterHeaderName = "Retry-After"

    static func isRetryAfterStatus(_ status: Int) -> Bool {
        status == 429 || status == 503
    }

    static func seconds(from response: HTTPURLResponse, now: Date = Date()) -> Int? {
        guard let rawValue = headerValue(named: retryAfterHeaderName, in: response) else {
            return nil
        }

        let text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let seconds = Int(text) {
            return boundedSeconds(seconds)
        }

        guard let retryDate = httpDate(from: text) else {
            return nil
        }

        return boundedSeconds(Int(ceil(retryDate.timeIntervalSince(now))))
    }

    private static func boundedSeconds(_ seconds: Int) -> Int? {
        guard seconds > 0 else { return nil }
        return min(seconds, maximumSeconds)
    }

    private static func headerValue(named name: String, in response: HTTPURLResponse) -> String? {
        if let directValue = response.value(forHTTPHeaderField: name) {
            return directValue
        }

        let lowercasedName = name.lowercased()
        for (key, value) in response.allHeaderFields {
            guard String(describing: key).lowercased() == lowercasedName else { continue }
            return String(describing: value)
        }
        return nil
    }

    private static func httpDate(from text: String) -> Date? {
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy"
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }
}
