import Foundation

@main
struct VerifyProviderOnboarding {
    static func main() throws {
        try verifyCalDAVPresetCoverage()
        try verifyCalDAVPresetCopyAndURLs()
        try verifyCalDAVPresetDiscoveryIntegration()
        print("Provider onboarding invariant passed.")
    }

    private static func verifyCalDAVPresetCoverage() throws {
        let expected: [ProviderCalDAVPreset] = [
            .generic,
            .iCloud,
            .fastmail,
            .yahoo,
            .nextcloud,
            .radicale,
            .baikal
        ]
        try expect(
            ProviderCalDAVPreset.allCases == expected,
            "CalDAV onboarding should expose generic plus iCloud, Fastmail, Yahoo, Nextcloud, Radicale, and Baikal presets"
        )
    }

    private static func verifyCalDAVPresetCopyAndURLs() throws {
        for preset in ProviderCalDAVPreset.allCases {
            try expect(!preset.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "\(preset.rawValue) preset should have a title")
            try expect(!preset.titlePlaceholder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "\(preset.rawValue) preset should have a title placeholder")
            try expect(!preset.urlPlaceholder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "\(preset.rawValue) preset should have a URL placeholder")
            try expect(!preset.usernamePlaceholder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "\(preset.rawValue) preset should have a username placeholder")
            try expect(!preset.passwordPlaceholder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "\(preset.rawValue) preset should have a password placeholder")
            try expect(!preset.guidanceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "\(preset.rawValue) preset should have guidance text")
            try expect(preset.hasSuggestedURL == !preset.defaultURLString.isEmpty,
                       "\(preset.rawValue) suggested URL flag should match the default URL")

            if let defaultURL = preset.defaultURLString.nilIfBlank {
                let normalizedURL = try CalendarURLNormalizer.httpURL(from: defaultURL)
                try expect(normalizedURL.scheme == "https",
                           "\(preset.rawValue) default CalDAV URL should stay HTTPS")
                try expect(normalizedURL.absoluteString == defaultURL,
                           "\(preset.rawValue) default CalDAV URL should already be canonical")
            }
        }

        try expect(ProviderCalDAVPreset.iCloud.defaultURLString == "https://caldav.icloud.com/",
                   "iCloud preset should use Apple's CalDAV host")
        try expect(ProviderCalDAVPreset.fastmail.defaultURLString == "https://caldav.fastmail.com/",
                   "Fastmail preset should use Fastmail's CalDAV host")
        try expect(ProviderCalDAVPreset.yahoo.defaultURLString == "https://caldav.calendar.yahoo.com/",
                   "Yahoo preset should use Yahoo's CalDAV host")
        try expect(!ProviderCalDAVPreset.nextcloud.hasSuggestedURL,
                   "Nextcloud preset should avoid inventing a tenant-specific URL")
        try expect(!ProviderCalDAVPreset.radicale.hasSuggestedURL,
                   "Radicale preset should avoid inventing a tenant-specific URL")
        try expect(!ProviderCalDAVPreset.baikal.hasSuggestedURL,
                   "Baikal preset should avoid inventing a tenant-specific URL")
    }

    private static func verifyCalDAVPresetDiscoveryIntegration() throws {
        let canonicalPresets: [(ProviderCalDAVPreset, String)] = [
            (.iCloud, "https://caldav.icloud.com/"),
            (.fastmail, "https://caldav.fastmail.com/"),
            (.yahoo, "https://caldav.calendar.yahoo.com/")
        ]
        for (preset, expectedRoot) in canonicalPresets {
            let url = try requireURL(preset.defaultURLString)
            let candidates = CalDAVDiscovery.rootCandidates(for: url).map(\.absoluteString)
            try expect(candidates.first == expectedRoot,
                       "\(preset.rawValue) default URL should be tried before fallback discovery")
            try expect(candidates.contains("\(expectedRoot).well-known/caldav"),
                       "\(preset.rawValue) discovery should include the provider well-known endpoint")
        }

        let nextcloudCandidates = CalDAVDiscovery.rootCandidates(
            for: try requireURL(ProviderCalDAVPreset.nextcloud.urlPlaceholder)
        ).map(\.absoluteString)
        try expect(nextcloudCandidates.contains("https://cloud.example.com/remote.php/dav/"),
                   "Nextcloud preset placeholder should line up with common Nextcloud CalDAV discovery")

        let baikalCandidates = CalDAVDiscovery.rootCandidates(
            for: try requireURL(ProviderCalDAVPreset.baikal.urlPlaceholder)
        ).map(\.absoluteString)
        try expect(baikalCandidates.first == "https://calendar.example.com/dav.php/",
                   "Baikal preset should try the dashboard-provided DAV URL first")
        try expect(baikalCandidates.contains("https://calendar.example.com/html/dav.php/"),
                   "Baikal preset discovery should include the alternate html/dav.php path")
    }

    private static func requireURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else {
            throw ProviderOnboardingInvariantError("Invalid fixture URL \(value)")
        }
        return url
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw ProviderOnboardingInvariantError(message)
        }
    }
}

private struct ProviderOnboardingInvariantError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
