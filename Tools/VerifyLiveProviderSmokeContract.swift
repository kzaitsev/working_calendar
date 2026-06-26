import Foundation

@main
struct VerifyLiveProviderSmokeContract {
    static func main() throws {
        try verifyRequiredSourceParsing()
        try verifyRequirementFlags()
        try verifyWriteProbeUpdateMutation()
        try verifyStrictFailures()
        try verifyMultiReportStrictFailures()
        try verifyPreflightFailures()
        try verifyPassingPreflightContract()
        try verifyPassingStrictContract()
        print("Live provider smoke contract invariant passed.")
    }

    private static func verifyRequiredSourceParsing() throws {
        let all = try LiveProviderSmokeRequirements.requiredSources(in: [
            "WC_LIVE_REQUIRE_SOURCES": " all "
        ])
        try expect(all == [.icsSubscription, .calDAV, .googleCalendar, .microsoft365],
                   "Strict source parser should expand all providers")

        let aliases = try LiveProviderSmokeRequirements.requiredSources(in: [
            "WC_LIVE_REQUIRE_SOURCES": "ics, cal-dav google-calendar\nm365"
        ])
        try expect(aliases == [.icsSubscription, .calDAV, .googleCalendar, .microsoft365],
                   "Strict source parser should accept documented aliases")

        do {
            _ = try LiveProviderSmokeRequirements.requiredSources(in: [
                "WC_LIVE_REQUIRE_SOURCES": "google,exchange"
            ])
            throw VerifyLiveProviderSmokeContractError("Unknown strict source aliases should fail")
        } catch let error as LiveProviderSmokeContractError {
            try expect(error.message.contains("Unknown WC_LIVE_REQUIRE_SOURCES value"),
                       "Unknown strict source errors should be actionable")
        }
    }

    private static func verifyRequirementFlags() throws {
        let explicitWrite = try LiveProviderSmokeRequirements(environment: [
            "WC_LIVE_WRITE_SMOKE": " yes ",
            "WC_LIVE_USE_STORED_SOURCES": "On",
            "WC_LIVE_PREFLIGHT": "true"
        ])
        try expect(explicitWrite.shouldRunWriteSmoke,
                   "Explicit live write smoke should accept yes as a true flag")
        try expect(!explicitWrite.shouldRequireWriteSmoke,
                   "Optional write smoke should not become a strict requirement")
        try expect(explicitWrite.shouldUseStoredSources,
                   "Stored-source live smoke should accept On as a true flag")
        try expect(explicitWrite.shouldRunPreflight,
                   "Live smoke preflight should accept true as a true flag")

        let strictWrite = try LiveProviderSmokeRequirements(environment: [
            "WC_LIVE_REQUIRE_WRITE_SMOKE": "true",
            "WC_LIVE_REQUIRE_RESPONSES": "on",
            "WC_LIVE_REQUIRE_RSVP_PROBE": "TRUE",
            "WC_LIVE_REQUIRE_REFRESH_OAUTH": "On"
        ])
        try expect(strictWrite.shouldRunWriteSmoke,
                   "Strict write smoke should automatically run a write probe")
        try expect(strictWrite.shouldRequireWriteSmoke,
                   "Strict write smoke should be recorded as required")
        try expect(strictWrite.shouldRequireResponses,
                   "Strict response capability should be recorded")
        try expect(strictWrite.shouldRequireRSVPProbe,
                   "Strict RSVP probe should be recorded")
        try expect(strictWrite.shouldRequireRefreshOAuth,
                   "Strict refresh-token OAuth should be recorded")

        let disabledWrite = try LiveProviderSmokeRequirements(environment: [
            "WC_LIVE_WRITE_SMOKE": "0",
            "WC_LIVE_REQUIRE_WRITE_SMOKE": "false",
            "WC_LIVE_REQUIRE_RESPONSES": "no",
            "WC_LIVE_REQUIRE_RSVP_PROBE": "off",
            "WC_LIVE_REQUIRE_REFRESH_OAUTH": "disabled",
            "WC_LIVE_USE_STORED_SOURCES": "0",
            "WC_LIVE_PREFLIGHT": "no"
        ])
        try expect(!disabledWrite.shouldRunWriteSmoke,
                   "False-like live smoke flags should not request a write probe")
        try expect(!disabledWrite.shouldRequireWriteSmoke,
                   "False-like strict write smoke flag should not be recorded")
        try expect(!disabledWrite.shouldRequireResponses,
                   "False-like response flag should not be recorded")
        try expect(!disabledWrite.shouldRequireRSVPProbe,
                   "False-like RSVP flag should not be recorded")
        try expect(!disabledWrite.shouldRequireRefreshOAuth,
                   "False-like refresh OAuth flag should not be recorded")
        try expect(!disabledWrite.shouldUseStoredSources,
                   "False-like stored-source flag should not be recorded")
        try expect(!disabledWrite.shouldRunPreflight,
                   "False-like preflight flag should not be recorded")
    }

    private static func verifyWriteProbeUpdateMutation() throws {
        let createdAt = try fixedDate("2026-07-01T09:00:00Z")
        let updatedAt = try fixedDate("2026-07-01T09:05:00Z")
        let event = LocalCalendarEvent(
            id: "live-write-probe-event",
            externalUID: "live-write-probe-event@working-calendar-live-smoke",
            sequence: 0,
            calendarID: "local-calendar-live-write-probe",
            title: "[Working Calendar live smoke] create/update/delete probe",
            startDate: createdAt.addingTimeInterval(2 * 60 * 60),
            endDate: createdAt.addingTimeInterval(2 * 60 * 60 + 15 * 60),
            isAllDay: false,
            availability: .free,
            status: .confirmed,
            privacy: .public,
            importance: .low,
            categories: ["Working Calendar live smoke"],
            reminderOffsets: [],
            timeZoneIdentifier: "UTC",
            organizerName: "",
            organizerEmail: "",
            attendees: [],
            myResponseStatus: .notInvited,
            location: "",
            notes: "Created, updated, and deleted automatically by WC_LIVE_WRITE_SMOKE.",
            urlString: "",
            createdAt: createdAt,
            updatedAt: createdAt
        )

        let updatedEvent = LiveProviderWriteProbeMutation.updatedEvent(
            event,
            remoteObjectURLString: " https://calendar.example.com/live-write-probe.ics ",
            remoteETag: " \"etag-after-create\" ",
            now: updatedAt
        )

        try expect(updatedEvent.id == event.id,
                   "Live write update probe should preserve the local event identity")
        try expect(updatedEvent.externalUID == event.externalUID,
                   "Live write update probe should preserve the remote iCalendar UID")
        try expect(updatedEvent.remoteObjectURLString == "https://calendar.example.com/live-write-probe.ics",
                   "Live write update probe should carry the created remote object URL into the update")
        try expect(updatedEvent.remoteETag == "\"etag-after-create\"",
                   "Live write update probe should carry the created ETag/changeKey into the update")
        try expect(updatedEvent.sequence == event.sequence + 1,
                   "Live write update probe should increment sequence so providers receive a real event update")
        try expect(updatedEvent.updatedAt == updatedAt,
                   "Live write update probe should stamp the update time deterministically")
    }

    private static func verifyStrictFailures() throws {
        let requirements = try LiveProviderSmokeRequirements(environment: [
            "WC_LIVE_REQUIRE_SOURCES": "all",
            "WC_LIVE_REQUIRE_WRITE_SMOKE": "1",
            "WC_LIVE_REQUIRE_RESPONSES": "1",
            "WC_LIVE_REQUIRE_RSVP_PROBE": "1",
            "WC_LIVE_REQUIRE_REFRESH_OAUTH": "1"
        ])
        let microsoftNeedsReconnect = ProviderOAuthDiagnostic(
            service: .microsoft365,
            credential: oauthCredential(
                service: .microsoft365,
                refreshToken: nil,
                expiresAt: Date().addingTimeInterval(3600)
            )
        )
        let reports = [
            ProviderDiagnosticReport(
                source: .icsSubscription,
                status: .skipped,
                message: "set WC_LIVE_ICS_URL"
            ),
            ProviderDiagnosticReport(
                source: .calDAV,
                status: .passed,
                message: "",
                calendarCount: 1,
                responseCapableCalendarCount: 0,
                writeProbeCount: 0,
                responseProbeCount: 0
            ),
            ProviderDiagnosticReport(
                source: .googleCalendar,
                status: .passed,
                message: "",
                calendarCount: 1,
                responseCapableCalendarCount: 1,
                writeProbeCount: 0,
                responseProbeCount: 0
            ),
            ProviderDiagnosticReport(
                source: .microsoft365,
                status: .passed,
                message: "",
                oauth: microsoftNeedsReconnect,
                calendarCount: 1,
                responseCapableCalendarCount: 1,
                writeProbeCount: 1,
                responseProbeCount: 1
            )
        ]

        guard let failure = LiveProviderSmokeStrictContract.failure(
            reports: reports,
            requirements: requirements
        ) else {
            throw VerifyLiveProviderSmokeContractError("Incomplete strict reports should fail")
        }
        let message = failure.errorDescription ?? ""
        try expect(message.contains("ICS skipped: set WC_LIVE_ICS_URL"),
                   "Strict mode should fail skipped required sources")
        try expect(message.contains("CalDAV did not complete a live write probe"),
                   "Strict mode should require CalDAV write probes")
        try expect(message.contains("CalDAV did not expose a response-capable calendar"),
                   "Strict mode should require response-capable calendars")
        try expect(message.contains("CalDAV did not complete a live RSVP probe"),
                   "Strict mode should require live RSVP probes when opted in")
        try expect(message.contains("Google Calendar did not complete a live write probe"),
                   "Strict mode should require Google write probes")
        try expect(message.contains("Google Calendar did not use refresh-token OAuth credentials"),
                   "Strict mode should reject raw-token OAuth checks")
        try expect(message.contains("Microsoft 365 OAuth needs attention: OAuth reconnect"),
                   "Strict mode should fail OAuth credentials that need reconnect")
        try expect(message.contains("Microsoft 365 OAuth did not expose a refresh token"),
                   "Strict mode should require refresh-token presence")
    }

    private static func verifyMultiReportStrictFailures() throws {
        let requirements = try LiveProviderSmokeRequirements(environment: [
            "WC_LIVE_REQUIRE_SOURCES": "google",
            "WC_LIVE_REQUIRE_WRITE_SMOKE": "1",
            "WC_LIVE_REQUIRE_RESPONSES": "1",
            "WC_LIVE_REQUIRE_REFRESH_OAUTH": "1"
        ])
        let reports = [
            passingTwoWayReport(source: .googleCalendar, oauth: readyOAuthDiagnostic(service: .googleCalendar)),
            ProviderDiagnosticReport(
                source: .googleCalendar,
                status: .failed,
                message: "token rejected",
                accountID: "saved-google-broken",
                accountTitle: "Broken Google"
            ),
            ProviderDiagnosticReport(
                source: .googleCalendar,
                status: .passed,
                message: "",
                accountID: "saved-google-readonly",
                accountTitle: "Read-only Google",
                oauth: readyOAuthDiagnostic(service: .googleCalendar),
                calendarCount: 1,
                responseCapableCalendarCount: 0,
                writeProbeCount: 0
            )
        ]

        guard let failure = LiveProviderSmokeStrictContract.failure(
            reports: reports,
            requirements: requirements
        ) else {
            throw VerifyLiveProviderSmokeContractError("Multi-report strict audits should fail hidden account problems")
        }
        let message = failure.errorDescription ?? ""
        try expect(message.contains("Google Calendar Broken Google failed: token rejected"),
                   "Strict mode should not hide failed saved accounts behind a passing account")
        try expect(message.contains("Google Calendar Read-only Google did not complete a live write probe"),
                   "Strict mode should evaluate write probes per saved account report")
        try expect(message.contains("Google Calendar Read-only Google did not expose a response-capable calendar"),
                   "Strict mode should evaluate response capability per saved account report")
    }

    private static func verifyPreflightFailures() throws {
        let requirements = try LiveProviderSmokeRequirements(environment: [
            "WC_LIVE_PREFLIGHT": "1",
            "WC_LIVE_REQUIRE_SOURCES": "caldav,google,microsoft",
            "WC_LIVE_REQUIRE_REFRESH_OAUTH": "1"
        ])
        let reports = [
            ProviderDiagnosticReport(
                source: .calDAV,
                status: .failed,
                message: "saved source is missing a CalDAV password in Keychain",
                accountID: "saved-caldav",
                accountTitle: "Office CalDAV"
            ),
            ProviderDiagnosticReport(
                source: .googleCalendar,
                status: .pending,
                message: "preflight ready: env access token is present",
                accountID: "env-google",
                accountTitle: "Environment Google Calendar"
            ),
            ProviderDiagnosticReport(
                source: .microsoft365,
                status: .skipped,
                message: "set WC_LIVE_MICROSOFT_ACCESS_TOKEN"
            )
        ]

        guard let failure = LiveProviderSmokePreflightContract.failure(
            reports: reports,
            requirements: requirements
        ) else {
            throw VerifyLiveProviderSmokeContractError("Incomplete preflight reports should fail")
        }
        let message = failure.errorDescription ?? ""
        try expect(message.contains("CalDAV Office CalDAV failed: saved source is missing a CalDAV password in Keychain"),
                   "Preflight should fail saved CalDAV sources without local Keychain passwords")
        try expect(message.contains("Google Calendar Environment Google Calendar did not provide refresh-token OAuth credentials"),
                   "Preflight should reject raw OAuth access tokens when refresh OAuth is required")
        try expect(message.contains("Microsoft 365 skipped: set WC_LIVE_MICROSOFT_ACCESS_TOKEN"),
                   "Preflight should fail skipped required providers")
    }

    private static func verifyPassingPreflightContract() throws {
        let requirements = try LiveProviderSmokeRequirements(environment: [
            "WC_LIVE_PREFLIGHT": "1",
            "WC_LIVE_REQUIRE_SOURCES": "all",
            "WC_LIVE_REQUIRE_REFRESH_OAUTH": "1"
        ])
        let reports = [
            preflightReadyReport(source: .icsSubscription, accountTitle: "Saved ICS", oauth: nil),
            preflightReadyReport(source: .calDAV, accountTitle: "Saved CalDAV", oauth: nil),
            preflightReadyReport(source: .googleCalendar, accountTitle: "Saved Google", oauth: readyOAuthDiagnostic(service: .googleCalendar)),
            preflightReadyReport(source: .microsoft365, accountTitle: "Saved Microsoft", oauth: readyOAuthDiagnostic(service: .microsoft365))
        ]

        try expect(
            LiveProviderSmokePreflightContract.failure(reports: reports, requirements: requirements) == nil,
            "Complete preflight reports should pass without requiring live network write evidence"
        )
    }

    private static func verifyPassingStrictContract() throws {
        let requirements = try LiveProviderSmokeRequirements(environment: [
            "WC_LIVE_REQUIRE_SOURCES": "all",
            "WC_LIVE_REQUIRE_WRITE_SMOKE": "1",
            "WC_LIVE_REQUIRE_RESPONSES": "1",
            "WC_LIVE_REQUIRE_RSVP_PROBE": "1",
            "WC_LIVE_REQUIRE_REFRESH_OAUTH": "1"
        ])
        let reports = [
            ProviderDiagnosticReport(
                source: .icsSubscription,
                status: .passed,
                message: "fetched feed"
            ),
            passingTwoWayReport(source: .calDAV, oauth: nil),
            passingTwoWayReport(source: .googleCalendar, oauth: readyOAuthDiagnostic(service: .googleCalendar)),
            passingTwoWayReport(source: .microsoft365, oauth: readyOAuthDiagnostic(service: .microsoft365))
        ]

        try expect(
            LiveProviderSmokeStrictContract.failure(reports: reports, requirements: requirements) == nil,
            "Complete strict reports should pass"
        )
    }

    private static func passingTwoWayReport(
        source: ProviderDiagnosticSource,
        oauth: ProviderOAuthDiagnostic?
    ) -> ProviderDiagnosticReport {
        ProviderDiagnosticReport(
            source: source,
            status: .passed,
            message: "",
            oauth: oauth,
            calendarCount: 1,
            writableCalendarCount: 1,
            responseCapableCalendarCount: 1,
            writeProbeCount: 1,
            responseProbeCount: 1
        )
    }

    private static func preflightReadyReport(
        source: ProviderDiagnosticSource,
        accountTitle: String,
        oauth: ProviderOAuthDiagnostic?
    ) -> ProviderDiagnosticReport {
        ProviderDiagnosticReport(
            source: source,
            status: .pending,
            message: "preflight ready",
            accountID: "preflight-\(source.rawValue)",
            accountTitle: accountTitle,
            oauth: oauth
        )
    }

    private static func readyOAuthDiagnostic(service: OAuthServiceKind) -> ProviderOAuthDiagnostic {
        ProviderOAuthDiagnostic(
            service: service,
            credential: oauthCredential(
                service: service,
                refreshToken: "refresh-token",
                expiresAt: Date().addingTimeInterval(3600)
            )
        )
    }

    private static func oauthCredential(
        service: OAuthServiceKind,
        refreshToken: String?,
        expiresAt: Date
    ) -> OAuthCredential {
        OAuthCredential(
            accessToken: "access-token",
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            tokenType: "Bearer",
            scope: service.scopes,
            clientID: "client-id",
            tenant: service.usesTenant ? service.defaultTenant : nil,
            service: service
        )
    }

    private static func fixedDate(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            throw VerifyLiveProviderSmokeContractError("Invalid fixture date \(value)")
        }
        return date
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw VerifyLiveProviderSmokeContractError(message)
        }
    }
}

private struct VerifyLiveProviderSmokeContractError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
