import Foundation

enum ProviderDiagnosticSource: String, Codable, CaseIterable, Hashable {
    case icsSubscription
    case calDAV
    case googleCalendar
    case microsoft365

    var title: String {
        switch self {
        case .icsSubscription: return "ICS"
        case .calDAV: return "CalDAV"
        case .googleCalendar: return "Google Calendar"
        case .microsoft365: return "Microsoft 365"
        }
    }

    var symbolName: String {
        switch self {
        case .icsSubscription: return "link"
        case .calDAV: return "server.rack"
        case .googleCalendar: return "g.circle"
        case .microsoft365: return "m.circle"
        }
    }

    var onboardingTitle: String {
        switch self {
        case .icsSubscription: return "ICS/webcal"
        case .calDAV: return "CalDAV"
        case .googleCalendar: return "Google Calendar"
        case .microsoft365: return "Microsoft 365"
        }
    }

    var onboardingSubtitle: String {
        switch self {
        case .icsSubscription:
            return "Subscribe to read-only .ics files, webcal links, and published Google calendar URLs."
        case .calDAV:
            return "Connect iCloud, Fastmail, Yahoo, Nextcloud, Radicale, Baikal, or a generic CalDAV server."
        case .googleCalendar:
            return "Connect Google Calendar with desktop OAuth, loopback browser sign-in, and background refresh tokens."
        case .microsoft365:
            return "Connect Microsoft 365 calendars with device-code OAuth and Graph sync."
        }
    }

    var onboardingActionTitle: String {
        "Add \(onboardingTitle)"
    }
}

enum ProviderDiagnosticStatus: String, Codable, Hashable {
    case passed
    case pending
    case skipped
    case failed

    var title: String {
        switch self {
        case .passed: return "OK"
        case .pending: return "Pending"
        case .skipped: return "Skipped"
        case .failed: return "Needs attention"
        }
    }
}

enum ProviderOAuthCredentialStatus: String, Codable, Hashable {
    case missingCredential
    case missingRefreshToken
    case refreshDue
    case missingScopes
    case ready

    var title: String {
        switch self {
        case .missingCredential: return "OAuth missing"
        case .missingRefreshToken: return "OAuth reconnect"
        case .refreshDue: return "OAuth refresh due"
        case .missingScopes: return "OAuth scopes missing"
        case .ready: return "OAuth ready"
        }
    }

    var needsAttention: Bool {
        switch self {
        case .missingCredential, .missingRefreshToken, .missingScopes:
            return true
        case .refreshDue, .ready:
            return false
        }
    }
}

struct ProviderOAuthDiagnostic: Codable, Hashable {
    var service: OAuthServiceKind
    var status: ProviderOAuthCredentialStatus
    var expiresAt: Date?
    var hasRefreshToken: Bool
    var grantedScopeCount: Int
    var missingScopeCount: Int

    init(
        service: OAuthServiceKind,
        credential: OAuthCredential?,
        now: Date = Date()
    ) {
        self.service = service

        guard let credential else {
            status = .missingCredential
            expiresAt = nil
            hasRefreshToken = false
            grantedScopeCount = 0
            missingScopeCount = service.requiredGrantedScopes.count
            return
        }

        let missingScopes = credential.missingRequiredScopes()
        expiresAt = credential.expiresAt
        hasRefreshToken = credential.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        grantedScopeCount = credential.scope.providerOAuthScopeTokens.count
        missingScopeCount = missingScopes.count

        if !missingScopes.isEmpty {
            status = .missingScopes
        } else if !hasRefreshToken {
            status = .missingRefreshToken
        } else if credential.expiresAt <= now.addingTimeInterval(90) {
            status = .refreshDue
        } else {
            status = .ready
        }
    }

    var needsAttention: Bool {
        status.needsAttention
    }
}

struct ProviderDiagnosticReport: Codable, Hashable, Identifiable {
    var source: ProviderDiagnosticSource
    var status: ProviderDiagnosticStatus
    var message: String
    var accountID: String?
    var accountTitle: String?
    var isEnabled: Bool
    var lastSyncAt: Date?
    var lastSyncStartedAt: Date?
    var lastSyncDurationSeconds: Double?
    var lastSyncFailedAt: Date?
    var nextSyncAt: Date?
    var oauth: ProviderOAuthDiagnostic?
    var calendarCount: Int
    var eventCount: Int
    var objectCount: Int
    var writableCalendarCount: Int
    var responseCapableCalendarCount: Int
    var readOnlyCalendarCount: Int
    var identityEmailCount: Int
    var syncStateCount: Int
    var httpValidatorCount: Int
    var refreshIntervalSeconds: Int?
    var writeProbeCount: Int
    var responseProbeCount: Int
    var pendingOutboxCount: Int
    var attentionOutboxCount: Int

    var id: String {
        accountID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "\(source.rawValue)-\(accountTitle ?? "")"
    }

    init(
        source: ProviderDiagnosticSource,
        status: ProviderDiagnosticStatus,
        message: String,
        accountID: String? = nil,
        accountTitle: String? = nil,
        isEnabled: Bool = true,
        lastSyncAt: Date? = nil,
        lastSyncStartedAt: Date? = nil,
        lastSyncDurationSeconds: Double? = nil,
        lastSyncFailedAt: Date? = nil,
        nextSyncAt: Date? = nil,
        oauth: ProviderOAuthDiagnostic? = nil,
        calendarCount: Int = 0,
        eventCount: Int = 0,
        objectCount: Int = 0,
        writableCalendarCount: Int = 0,
        responseCapableCalendarCount: Int = 0,
        readOnlyCalendarCount: Int = 0,
        identityEmailCount: Int = 0,
        syncStateCount: Int = 0,
        httpValidatorCount: Int = 0,
        refreshIntervalSeconds: Int? = nil,
        writeProbeCount: Int = 0,
        responseProbeCount: Int = 0,
        pendingOutboxCount: Int = 0,
        attentionOutboxCount: Int = 0
    ) {
        self.source = source
        self.status = status
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.accountTitle = accountTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.isEnabled = isEnabled
        self.lastSyncAt = lastSyncAt
        self.lastSyncStartedAt = lastSyncStartedAt
        self.lastSyncDurationSeconds = lastSyncDurationSeconds.map { max(0, $0) }
        self.lastSyncFailedAt = lastSyncFailedAt
        self.nextSyncAt = nextSyncAt
        self.oauth = oauth
        self.calendarCount = max(0, calendarCount)
        self.eventCount = max(0, eventCount)
        self.objectCount = max(0, objectCount)
        self.writableCalendarCount = max(0, writableCalendarCount)
        self.responseCapableCalendarCount = max(0, responseCapableCalendarCount)
        self.readOnlyCalendarCount = max(0, readOnlyCalendarCount)
        self.identityEmailCount = max(0, identityEmailCount)
        self.syncStateCount = max(0, syncStateCount)
        self.httpValidatorCount = max(0, httpValidatorCount)
        self.refreshIntervalSeconds = refreshIntervalSeconds.map { max(0, $0) }
        self.writeProbeCount = max(0, writeProbeCount)
        self.responseProbeCount = max(0, responseProbeCount)
        self.pendingOutboxCount = max(0, pendingOutboxCount)
        self.attentionOutboxCount = max(0, attentionOutboxCount)
    }

    var needsAttention: Bool {
        status == .failed || attentionOutboxCount > 0 || oauth?.status.needsAttention == true
    }

    var isOnboardingReport: Bool {
        accountID?.hasPrefix("provider-onboarding-") == true
    }

    var summaryLine: String {
        let detail = message.isEmpty ? defaultMessage : message
        let accountPrefix = accountTitle.map { "\($0) - " } ?? ""
        return "\(source.title) \(status.rawValue): \(accountPrefix)\(detail)"
    }

    private var defaultMessage: String {
        switch status {
        case .passed:
            let calendarText = "\(calendarCount) calendar(s)"
            let eventText = eventCount > 0 ? ", \(eventCount) event(s)" : ""
            let objectText = objectCount > 0 ? ", \(objectCount) object(s)" : ""
            let writableText = writableCalendarCount > 0 ? ", \(writableCalendarCount) writable" : ""
            let responseText = responseCapableCalendarCount > 0 ? ", \(responseCapableCalendarCount) response-capable" : ""
            let readOnlyText = readOnlyCalendarCount > 0 ? ", \(readOnlyCalendarCount) read-only" : ""
            let identityText = identityEmailCount > 0 ? ", \(identityEmailCount) identity email(s)" : ""
            let syncStateText = syncStateCount > 0 ? ", \(syncStateCount) sync state(s)" : ""
            let validatorText = httpValidatorCount > 0 ? ", \(httpValidatorCount) validator(s)" : ""
            let refreshIntervalText = refreshIntervalSeconds.map { $0 > 0 ? ", refresh every \(Self.durationText(seconds: $0))" : "" } ?? ""
            let writeProbeText = writeProbeCount > 0 ? ", \(writeProbeCount) write probe(s)" : ""
            let responseProbeText = responseProbeCount > 0 ? ", \(responseProbeCount) response probe(s)" : ""
            return "\(calendarText)\(eventText)\(objectText)\(writableText)\(responseText)\(readOnlyText)\(identityText)\(syncStateText)\(validatorText)\(refreshIntervalText)\(writeProbeText)\(responseProbeText)"
        case .pending:
            if pendingOutboxCount > 0 {
                return "\(pendingOutboxCount) remote update(s) pending"
            }
            return "waiting for sync"
        case .skipped:
            return isEnabled ? "not configured" : "source disabled"
        case .failed:
            if attentionOutboxCount > 0 {
                return "\(attentionOutboxCount) remote update(s) need attention"
            }
            return "diagnostic failed"
        }
    }

    private static func durationText(seconds: Int) -> String {
        let units = [
            (suffix: "d", value: 24 * 60 * 60),
            (suffix: "h", value: 60 * 60),
            (suffix: "m", value: 60),
            (suffix: "s", value: 1)
        ]
        var remaining = max(0, seconds)
        var parts: [String] = []

        for unit in units {
            let count = remaining / unit.value
            guard count > 0 else { continue }
            parts.append("\(count)\(unit.suffix)")
            remaining -= count * unit.value
        }

        return parts.isEmpty ? "0s" : parts.joined(separator: " ")
    }
}

enum ProviderDiagnosticJSON {
    static func encode(_ reports: [ProviderDiagnosticReport]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(reports)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

struct ProviderCoverageSummary: Hashable {
    let enabledSourceCount: Int
    let configuredSourceCount: Int
    let totalSourceCount: Int
    let missingSources: [ProviderDiagnosticSource]
    let disabledSources: [ProviderDiagnosticSource]
    let attentionReportCount: Int

    init(reports: [ProviderDiagnosticReport]) {
        let accountReports = reports.filter { !$0.isOnboardingReport }
        let configuredSources = Set(accountReports.map(\.source))
        let enabledSources = Set(accountReports.filter(\.isEnabled).map(\.source))

        totalSourceCount = ProviderDiagnosticSource.allCases.count
        configuredSourceCount = configuredSources.count
        enabledSourceCount = enabledSources.count
        missingSources = ProviderDiagnosticSource.allCases.filter { !configuredSources.contains($0) }
        disabledSources = ProviderDiagnosticSource.allCases.filter {
            configuredSources.contains($0) && !enabledSources.contains($0)
        }
        attentionReportCount = accountReports.filter(\.needsAttention).count
    }

    var titleText: String {
        "\(enabledSourceCount)/\(totalSourceCount) source types enabled"
    }

    var detailText: String {
        var blockers: [String] = []
        if !missingSources.isEmpty {
            blockers.append("Missing \(Self.sourceList(missingSources))")
        }
        if !disabledSources.isEmpty {
            blockers.append("Disabled \(Self.sourceList(disabledSources))")
        }

        if !blockers.isEmpty {
            return "\(blockers.joined(separator: " · ")) · strict preflight requires all \(totalSourceCount) supported source types enabled."
        }

        if attentionReportCount > 0 {
            return "\(attentionReportCount) saved source\(attentionReportCount == 1 ? "" : "s") need attention before strict preflight."
        }

        return "All supported source types are enabled; run saved-source preflight before live sync."
    }

    var isStrictCoverageComplete: Bool {
        missingSources.isEmpty && disabledSources.isEmpty
    }

    var needsAttention: Bool {
        attentionReportCount > 0
    }

    private static func sourceList(_ sources: [ProviderDiagnosticSource]) -> String {
        sources.map(\.onboardingTitle).joined(separator: ", ")
    }
}

struct ProviderPreflightReadinessSummary: Hashable {
    static let savedSourceRequirements = try! LiveProviderSmokeRequirements(environment: [
        "WC_LIVE_PREFLIGHT": "1",
        "WC_LIVE_USE_STORED_SOURCES": "1",
        "WC_LIVE_REQUIRE_SOURCES": "all",
        "WC_LIVE_REQUIRE_REFRESH_OAUTH": "1"
    ])

    let failureMessages: [String]

    init(reports: [ProviderDiagnosticReport]) {
        failureMessages = LiveProviderSmokePreflightContract.failureMessages(
            reports: reports,
            requirements: Self.savedSourceRequirements
        )
    }

    var isReady: Bool {
        failureMessages.isEmpty
    }

    var titleText: String {
        isReady ? "Saved-source preflight ready" : "Saved-source preflight blocked"
    }

    var detailText: String {
        guard !isReady else {
            return "All required source types and refresh-token OAuth credentials are ready for no-network preflight."
        }

        return "\(failureMessages.count) issue\(failureMessages.count == 1 ? "" : "s") must be fixed before strict saved-source preflight can pass."
    }

    func failurePreview(limit: Int = 3) -> [String] {
        Array(failureMessages.prefix(max(0, limit)))
    }

    func hiddenFailureCount(limit: Int = 3) -> Int {
        max(0, failureMessages.count - max(0, limit))
    }
}

enum ProviderPreflightCommand {
    static let shellCommand = "WC_LIVE_SMOKE_JSON=1 make live-provider-smoke-preflight"

    static let detailText = "No network fetches or provider writes. Checks saved source URLs, CalDAV Keychain passwords, and OAuth refresh credentials."

    static func statusText(savedSourceCount: Int) -> String {
        let safeCount = max(0, savedSourceCount)
        guard safeCount > 0 else {
            return "Add a protocol source first, then run saved-source preflight."
        }

        return "\(safeCount) saved provider source\(safeCount == 1 ? "" : "s") ready for saved-source preflight."
    }
}

enum ProviderSourceURLValidator {
    static func validationMessage(kind: CalendarProviderKind, urlString: String) -> String? {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return nil }

        do {
            switch kind {
            case .icsSubscription:
                _ = try CalendarURLNormalizer.subscriptionURL(from: trimmedURL)
            case .calDAV:
                _ = try CalendarURLNormalizer.httpURL(from: trimmedURL)
            case .local, .googleCalendar, .microsoft365:
                return nil
            }
        } catch {
            switch kind {
            case .icsSubscription:
                return "Enter an http(s), webcal, or Google public calendar URL."
            case .calDAV:
                return "Enter an http(s), caldav, or caldavs server URL."
            case .local, .googleCalendar, .microsoft365:
                return nil
            }
        }

        return nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var providerOAuthScopeTokens: [String] {
        split { character in
            character == " " || character == "\n" || character == "\t" || character == ","
        }
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
}
