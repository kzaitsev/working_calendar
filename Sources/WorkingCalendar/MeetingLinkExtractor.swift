import Foundation

enum MeetingLinkExtractor {
    private static let preferredHosts = [
        "zoom.us",
        "zoom.com",
        "zoomgov.com",
        "meet.google.com",
        "teams.microsoft.com",
        "teams.live.com",
        "msteams.link",
        "meet.lync.com",
        "join.skype.com",
        "webex.com",
        "whereby.com",
        "around.co",
        "tuple.app",
        "gotomeeting.com",
        "meet.goto.com",
        "gotomeet.me",
        "bluejeans.com",
        "ringcentral.com",
        "chime.aws",
        "huddles.slack.com",
        "facetime.apple.com",
        "meet.jit.si",
        "jitsi.8x8.vc",
        "discord.gg",
        "discord.com"
    ]
    private static let preferredURLFragments = [
        "slack.com/huddle"
    ]
    private static let meetingSchemes: Set<String> = [
        "zoommtg",
        "zoomus",
        "msteams",
        "ms-teams",
        "skype",
        "lync",
        "webex",
        "wbx",
        "chime",
        "facetime"
    ]

    static func bestLink(eventURL: URL?, textFields: [String]) -> URL? {
        let candidates = distinct(
            ([eventURL].compactMap { $0 } + links(in: textFields.joined(separator: "\n")))
                .map(normalizedMeetingURL)
                .filter(isSupportedMeetingURL)
        )

        return candidates.first(where: isPreferredMeetingURL) ?? candidates.first
    }

    static func preferredLink(eventURL: URL?, textFields: [String]) -> URL? {
        distinct(
            ([eventURL].compactMap { $0 } + links(in: textFields.joined(separator: "\n")))
                .map(normalizedMeetingURL)
                .filter(isSupportedMeetingURL)
        ).first(where: isPreferredMeetingURL)
    }

    static func firstMeetingURLString(in text: String) -> String? {
        bestLink(eventURL: nil, textFields: [text])?.absoluteString
    }

    private static func links(in text: String) -> [URL] {
        let normalized = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")

        var urls: [URL] = []

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            urls.append(contentsOf: detector.matches(in: normalized, options: [], range: range).compactMap(\.url))
        }

        urls.append(contentsOf: customSchemeLinks(in: normalized))
        return distinct(urls)
    }

    private static func customSchemeLinks(in text: String) -> [URL] {
        let schemes = meetingSchemes
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let pattern = #"\b(?:"# + schemes + #"):(?://|/)?[^\s<>"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            let rawValue = String(text[matchRange])
            return URL(string: trimmedURLCandidate(rawValue))
        }
    }

    private static func trimmedURLCandidate(_ value: String) -> String {
        let trailingCharacters = CharacterSet(charactersIn: ".,;!?)\\]}>")
        return value.trimmingCharacters(in: trailingCharacters)
    }

    private static func normalizedMeetingURL(_ url: URL) -> URL {
        var current = url
        var seen = Set<String>()

        for _ in 0..<3 {
            let key = current.absoluteString
            guard seen.insert(key).inserted,
                  let unwrapped = redirectTargetURL(from: current) else {
                return current
            }
            current = unwrapped
        }

        return current
    }

    private static func redirectTargetURL(from url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        let queryItems = components.queryItems ?? []

        if host.hasSuffix("safelinks.protection.outlook.com") {
            return decodedURLValue(named: "url", in: queryItems)
        }

        if host == "google.com" || host.hasSuffix(".google.com"),
           path == "/url" || path == "/search" {
            return decodedURLValue(named: "url", in: queryItems)
                ?? decodedURLValue(named: "q", in: queryItems)
        }

        if host == "l.facebook.com" || host == "lm.facebook.com" {
            return decodedURLValue(named: "u", in: queryItems)
        }

        if host.hasSuffix("slack-redir.net") {
            return decodedURLValue(named: "url", in: queryItems)
        }

        return nil
    }

    private static func decodedURLValue(named name: String, in queryItems: [URLQueryItem]) -> URL? {
        guard let rawValue = queryItems.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value else {
            return nil
        }

        let candidates = [
            rawValue,
            rawValue.removingPercentEncoding
        ].compactMap { $0 }

        return candidates.lazy
            .map(trimmedURLCandidate)
            .compactMap(URL.init(string:))
            .first(where: isSupportedMeetingURL)
    }

    private static func isSupportedMeetingURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return ["http", "https"].contains(scheme) || meetingSchemes.contains(scheme)
    }

    private static func isPreferredMeetingURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if meetingSchemes.contains(scheme) {
            return true
        }

        let host = url.host?.lowercased() ?? ""
        let text = url.absoluteString.lowercased()
        return preferredHosts.contains { host.contains($0) }
            || preferredURLFragments.contains { text.contains($0) }
    }

    private static func distinct(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            seen.insert(url.absoluteString).inserted
        }
    }
}
