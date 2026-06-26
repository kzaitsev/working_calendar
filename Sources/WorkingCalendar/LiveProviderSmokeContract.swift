import Foundation

struct LiveProviderSmokeRequirements: Hashable {
    var requiredSources: Set<ProviderDiagnosticSource>
    var shouldRequireWriteSmoke: Bool
    var shouldRequireResponses: Bool
    var shouldRequireRSVPProbe: Bool
    var shouldRequireRefreshOAuth: Bool
    var shouldRunWriteSmoke: Bool
    var shouldUseStoredSources: Bool
    var shouldRunPreflight: Bool

    init(environment: [String: String]) throws {
        requiredSources = try Self.requiredSources(in: environment)
        shouldRequireWriteSmoke = Self.flag("WC_LIVE_REQUIRE_WRITE_SMOKE", in: environment)
        shouldRequireResponses = Self.flag("WC_LIVE_REQUIRE_RESPONSES", in: environment)
        shouldRequireRSVPProbe = Self.flag("WC_LIVE_REQUIRE_RSVP_PROBE", in: environment)
        shouldRequireRefreshOAuth = Self.flag("WC_LIVE_REQUIRE_REFRESH_OAUTH", in: environment)
        shouldRunWriteSmoke = Self.flag("WC_LIVE_WRITE_SMOKE", in: environment) || shouldRequireWriteSmoke
        shouldUseStoredSources = Self.flag("WC_LIVE_USE_STORED_SOURCES", in: environment)
        shouldRunPreflight = Self.flag("WC_LIVE_PREFLIGHT", in: environment)
    }

    static func requiredSources(in environment: [String: String]) throws -> Set<ProviderDiagnosticSource> {
        guard let rawValue = value("WC_LIVE_REQUIRE_SOURCES", in: environment) else {
            return []
        }
        if rawValue.lowercased() == "all" {
            return [.icsSubscription, .calDAV, .googleCalendar, .microsoft365]
        }

        var result: Set<ProviderDiagnosticSource> = []
        for token in rawValue.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { continue }
            switch normalized {
            case "ics", "webcal", "subscription", "ics-subscription":
                result.insert(.icsSubscription)
            case "caldav", "cal-dav":
                result.insert(.calDAV)
            case "google", "googlecalendar", "google-calendar":
                result.insert(.googleCalendar)
            case "microsoft", "microsoft365", "m365", "graph", "msgraph":
                result.insert(.microsoft365)
            default:
                throw LiveProviderSmokeContractError(
                    "Unknown WC_LIVE_REQUIRE_SOURCES value '\(token)'. Use all, ics, caldav, google, or microsoft365."
                )
            }
        }
        return result
    }

    private static func flag(_ key: String, in environment: [String: String]) -> Bool {
        switch value(key, in: environment)?.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func value(_ key: String, in environment: [String: String]) -> String? {
        let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

enum LiveProviderSmokeStrictContract {
    static func failure(
        reports: [ProviderDiagnosticReport],
        requirements: LiveProviderSmokeRequirements
    ) -> LiveProviderSmokeStrictFailure? {
        let failures = failureMessages(reports: reports, requirements: requirements)
        return failures.isEmpty ? nil : LiveProviderSmokeStrictFailure(failures: failures)
    }

    static func failureMessages(
        reports: [ProviderDiagnosticReport],
        requirements: LiveProviderSmokeRequirements
    ) -> [String] {
        var failures: [String] = []

        for requiredSource in requirements.requiredSources {
            let sourceReports = reports.filter { $0.source == requiredSource }
            guard !sourceReports.isEmpty else {
                failures.append("\(requiredSource.title) did not produce a diagnostic report")
                continue
            }

            for report in sourceReports where report.status == .failed {
                failures.append("\(liveProviderSmokeReportSubject(report)) failed: \(report.message)")
            }

            if sourceReports.allSatisfy({ $0.status == .skipped }),
               let report = sourceReports.first {
                failures.append("\(requiredSource.title) skipped: \(report.message)")
            }
        }

        if requirements.shouldRequireWriteSmoke {
            for source in [ProviderDiagnosticSource.calDAV, .googleCalendar, .microsoft365] {
                for report in reports where report.source == source && report.status == .passed {
                    if report.writeProbeCount < 1 {
                        failures.append("\(liveProviderSmokeReportSubject(report)) did not complete a live write probe")
                    }
                }
            }
        }

        if requirements.shouldRequireResponses {
            for source in [ProviderDiagnosticSource.calDAV, .googleCalendar, .microsoft365] {
                for report in reports where report.source == source && report.status == .passed {
                    if report.responseCapableCalendarCount < 1 {
                        failures.append("\(liveProviderSmokeReportSubject(report)) did not expose a response-capable calendar")
                    }
                }
            }
        }

        if requirements.shouldRequireRSVPProbe {
            for source in [ProviderDiagnosticSource.calDAV, .googleCalendar, .microsoft365] {
                for report in reports where report.source == source && report.status == .passed {
                    if report.responseProbeCount < 1 {
                        failures.append("\(liveProviderSmokeReportSubject(report)) did not complete a live RSVP probe")
                    }
                }
            }
        }

        if requirements.shouldRequireRefreshOAuth {
            for source in [ProviderDiagnosticSource.googleCalendar, .microsoft365] {
                for report in reports where report.source == source && report.status == .passed {
                    guard let oauth = report.oauth else {
                        failures.append("\(liveProviderSmokeReportSubject(report)) did not use refresh-token OAuth credentials")
                        continue
                    }
                    if oauth.needsAttention {
                        failures.append("\(liveProviderSmokeReportSubject(report)) OAuth needs attention: \(oauth.status.title)")
                    }
                    if !oauth.hasRefreshToken {
                        failures.append("\(liveProviderSmokeReportSubject(report)) OAuth did not expose a refresh token")
                    }
                }
            }
        }

        return failures
    }
}

enum LiveProviderSmokePreflightContract {
    static func failure(
        reports: [ProviderDiagnosticReport],
        requirements: LiveProviderSmokeRequirements
    ) -> LiveProviderSmokeStrictFailure? {
        let failures = failureMessages(reports: reports, requirements: requirements)
        return failures.isEmpty ? nil : LiveProviderSmokeStrictFailure(failures: failures)
    }

    static func failureMessages(
        reports: [ProviderDiagnosticReport],
        requirements: LiveProviderSmokeRequirements
    ) -> [String] {
        var failures: [String] = []

        for requiredSource in requirements.requiredSources {
            let sourceReports = reports.filter { $0.source == requiredSource }
            guard !sourceReports.isEmpty else {
                failures.append("\(requiredSource.title) did not produce a preflight report")
                continue
            }

            for report in sourceReports where report.status == .failed {
                failures.append("\(liveProviderSmokeReportSubject(report)) failed: \(report.message)")
            }

            if sourceReports.allSatisfy({ $0.status == .skipped }),
               let report = sourceReports.first {
                failures.append("\(requiredSource.title) skipped: \(report.message)")
            }
        }

        if requirements.shouldRequireRefreshOAuth {
            for source in [ProviderDiagnosticSource.googleCalendar, .microsoft365] {
                for report in reports where report.source == source && report.status != .skipped {
                    guard let oauth = report.oauth else {
                        failures.append("\(liveProviderSmokeReportSubject(report)) did not provide refresh-token OAuth credentials")
                        continue
                    }
                    if oauth.needsAttention {
                        failures.append("\(liveProviderSmokeReportSubject(report)) OAuth needs attention: \(oauth.status.title)")
                    }
                    if !oauth.hasRefreshToken {
                        failures.append("\(liveProviderSmokeReportSubject(report)) OAuth did not expose a refresh token")
                    }
                }
            }
        }

        return failures
    }
}

private func liveProviderSmokeReportSubject(_ report: ProviderDiagnosticReport) -> String {
    guard let accountTitle = report.accountTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
          !accountTitle.isEmpty
    else {
        return report.source.title
    }
    return "\(report.source.title) \(accountTitle)"
}

struct LiveProviderSmokeStrictFailure: LocalizedError, Equatable {
    var failures: [String]

    var errorDescription: String? {
        "Strict live provider smoke failed: \(failures.joined(separator: "; "))"
    }
}

struct LiveProviderSmokeContractError: LocalizedError, Equatable {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

enum LiveProviderWriteProbeMutation {
    static func updatedEvent(
        _ event: LocalCalendarEvent,
        remoteObjectURLString: String,
        remoteETag: String,
        now: Date = Date()
    ) -> LocalCalendarEvent {
        var updatedEvent = event
        updatedEvent.remoteObjectURLString = remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedEvent.remoteETag = remoteETag.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedEvent.sequence += 1
        updatedEvent.title = "[Working Calendar live smoke] updated write probe"
        updatedEvent.notes = "Updated automatically by WC_LIVE_WRITE_SMOKE before delete cleanup."
        updatedEvent.updatedAt = now
        return updatedEvent
    }
}
