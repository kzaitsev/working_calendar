import Foundation

struct ExternalCalendarOpenDeduper {
    static let defaultCoalescingWindow: TimeInterval = 5

    private let coalescingWindow: TimeInterval
    private var recentOpenDatesByKey: [String: Date] = [:]

    init(coalescingWindow: TimeInterval = Self.defaultCoalescingWindow) {
        self.coalescingWindow = max(0, coalescingWindow)
    }

    mutating func shouldProcess(_ url: URL, now: Date = Date()) -> Bool {
        let key = Self.dedupeKey(for: url)
        prune(now: now)

        if let lastOpenDate = recentOpenDatesByKey[key],
           now.timeIntervalSince(lastOpenDate) < coalescingWindow {
            return false
        }

        recentOpenDatesByKey[key] = now
        return true
    }

    static func dedupeKey(for url: URL) -> String {
        if url.isFileURL {
            return url.standardizedFileURL.path
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        switch components.scheme?.lowercased() {
        case "webcal", "webcals":
            components.scheme = "https"
        case let scheme:
            components.scheme = scheme
        }
        components.host = components.host?.lowercased()
        components.fragment = nil
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        return components.url?.absoluteString ?? url.absoluteString
    }

    private mutating func prune(now: Date) {
        recentOpenDatesByKey = recentOpenDatesByKey.filter { _, openDate in
            now.timeIntervalSince(openDate) < coalescingWindow
        }
    }
}
