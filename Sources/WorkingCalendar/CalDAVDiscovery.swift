import Foundation

enum CalDAVDiscovery {
    static func rootCandidates(for accountURL: URL) -> [URL] {
        var candidates: [URL] = []
        appendUnique(accountURL, to: &candidates)
        for url in providerRootURLs(for: accountURL) {
            appendUnique(url, to: &candidates)
            appendUnique(originURL(for: url, path: "/.well-known/caldav"), to: &candidates)
            for commonURL in commonRootURLs(for: url) {
                appendUnique(commonURL, to: &candidates)
            }
        }
        appendUnique(originURL(for: accountURL, path: "/.well-known/caldav"), to: &candidates)
        appendUnique(originURL(for: accountURL, path: "/"), to: &candidates)
        for url in commonRootURLs(for: accountURL) {
            appendUnique(url, to: &candidates)
        }
        return candidates
    }

    private static func providerRootURLs(for url: URL) -> [URL] {
        let host = normalizedHost(for: url)
        let rootStrings: [String]

        switch host {
        case "icloud.com", "calendar.icloud.com":
            rootStrings = ["https://caldav.icloud.com/"]
        case "fastmail.com", "calendar.fastmail.com":
            rootStrings = ["https://caldav.fastmail.com/"]
        case "yahoo.com", "calendar.yahoo.com":
            rootStrings = ["https://caldav.calendar.yahoo.com/"]
        default:
            rootStrings = []
        }

        return rootStrings.compactMap(URL.init(string:))
    }

    private static func normalizedHost(for url: URL) -> String {
        let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func commonRootURLs(for url: URL) -> [URL] {
        [
            "/remote.php/dav/",
            "/remote.php/caldav/",
            "/dav.php/",
            "/html/dav.php/",
            "/dav/",
            "/caldav/"
        ].compactMap { originURL(for: url, path: $0) }
    }

    private static func originURL(for url: URL, path: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil
        else {
            return nil
        }

        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func appendUnique(_ url: URL?, to candidates: inout [URL]) {
        guard let url else { return }
        guard !candidates.contains(where: { $0.absoluteString == url.absoluteString }) else { return }
        candidates.append(url)
    }
}
