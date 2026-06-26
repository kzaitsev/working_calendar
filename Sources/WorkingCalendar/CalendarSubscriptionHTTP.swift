import Foundation

struct ICSSubscriptionFetchResult {
    let text: String?
    let eTag: String?
    let lastModified: String?
    let refreshIntervalSeconds: Int?
    let preservesMissingValidators: Bool
    let preservesMissingRefreshInterval: Bool
}

protocol CalendarSubscriptionHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionCalendarSubscriptionHTTPTransport: CalendarSubscriptionHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

enum CalendarSubscriptionHTTP {
    static func fetch(
        account: CalendarProviderAccount,
        transport: CalendarSubscriptionHTTPTransport = URLSessionCalendarSubscriptionHTTPTransport()
    ) async throws -> ICSSubscriptionFetchResult {
        let request = try request(for: account)
        let (data, response) = try await transport.data(for: request)
        return try result(data: data, response: response)
    }

    static func request(for account: CalendarProviderAccount) throws -> URLRequest {
        guard let url = account.endpointURL else {
            throw CalendarProviderSyncError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("WorkingCalendar/1.0 (macOS; ICS)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/calendar, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("utf-8, utf-16, iso-8859-1", forHTTPHeaderField: "Accept-Charset")

        if let eTag = trimmedHeaderValue(account.httpETag) {
            request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = trimmedHeaderValue(account.httpLastModified) {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        return request
    }

    static func result(data: Data, response: URLResponse?) throws -> ICSSubscriptionFetchResult {
        let httpResponse = response as? HTTPURLResponse
        let eTag = httpResponse?.calendarSubscriptionHeaderValue(named: "ETag")
        let lastModified = httpResponse?.calendarSubscriptionHeaderValue(named: "Last-Modified")

        if let httpResponse, httpResponse.statusCode == 304 {
            return ICSSubscriptionFetchResult(
                text: nil,
                eTag: eTag,
                lastModified: lastModified,
                refreshIntervalSeconds: nil,
                preservesMissingValidators: true,
                preservesMissingRefreshInterval: true
            )
        }

        if let httpResponse, !(200...299).contains(httpResponse.statusCode) {
            if ProviderRetryAfter.isRetryAfterStatus(httpResponse.statusCode),
               let retryAfterSeconds = ProviderRetryAfter.seconds(from: httpResponse) {
                throw CalendarProviderSyncError.retryAfter(retryAfterSeconds)
            }
            throw CalendarProviderSyncError.httpStatus(httpResponse.statusCode)
        }

        if let text = CalendarSubscriptionDecoder.text(
            from: data,
            contentType: httpResponse?.calendarSubscriptionHeaderValue(named: "Content-Type")
        ) {
            return ICSSubscriptionFetchResult(
                text: text,
                eTag: eTag,
                lastModified: lastModified,
                refreshIntervalSeconds: CalendarSubscriptionRefreshInterval.seconds(from: text),
                preservesMissingValidators: false,
                preservesMissingRefreshInterval: false
            )
        }

        throw CalendarProviderSyncError.unsupportedEncoding
    }

    private static func trimmedHeaderValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

enum CalendarSubscriptionRefreshInterval {
    static func seconds(from text: String) -> Int? {
        for line in unfoldedLines(from: text) {
            guard let property = property(from: line),
                  property.name == "REFRESH-INTERVAL" || property.name == "X-PUBLISHED-TTL",
                  let seconds = seconds(fromDuration: property.value)
            else {
                continue
            }
            return seconds
        }
        return nil
    }

    private static func unfoldedLines(from text: String) -> [String] {
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

    private static func property(from line: String) -> (name: String, value: String)? {
        guard let separator = propertyValueSeparator(in: line) else { return nil }
        let name = line[..<separator]
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        let value = String(line[line.index(after: separator)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || value.isEmpty ? nil : (name, value)
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

    private static func seconds(fromDuration value: String) -> Int? {
        let duration = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard duration.hasPrefix("P") else { return nil }

        var total = 0
        var number = ""
        var isTimePart = false

        for character in duration.dropFirst() {
            if character == "T" {
                guard number.isEmpty else { return nil }
                isTimePart = true
                continue
            }

            if character.isNumber {
                number.append(character)
                continue
            }

            guard let value = Int(number), value >= 0 else { return nil }
            number.removeAll()

            switch character {
            case "W" where !isTimePart:
                total += value * 7 * 24 * 60 * 60
            case "D" where !isTimePart:
                total += value * 24 * 60 * 60
            case "H" where isTimePart:
                total += value * 60 * 60
            case "M" where isTimePart:
                total += value * 60
            case "S" where isTimePart:
                total += value
            default:
                return nil
            }
        }

        guard number.isEmpty, total > 0 else { return nil }
        return min(total, 30 * 24 * 60 * 60)
    }
}

enum CalendarProviderSyncError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case retryAfter(Int)
    case unsupportedEncoding

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The calendar subscription URL is no longer valid."
        case .httpStatus(let status):
            return "Calendar subscription returned HTTP \(status)."
        case .retryAfter(let seconds):
            return "Calendar subscription asked Working Calendar to retry in \(seconds) seconds."
        case .unsupportedEncoding:
            return "Calendar subscription data is not readable text."
        }
    }
}

extension CalendarProviderSyncError: ProviderRetryAfterError {
    var providerRetryAfterSeconds: Int? {
        guard case .retryAfter(let seconds) = self else { return nil }
        return seconds
    }
}

extension HTTPURLResponse {
    func calendarSubscriptionHeaderValue(named name: String) -> String? {
        for (key, value) in allHeaderFields {
            guard String(describing: key).caseInsensitiveCompare(name) == .orderedSame else { continue }
            let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }
}
