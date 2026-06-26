import Foundation

@main
struct VerifyProviderDiagnostics {
    @MainActor
    static func main() throws {
        try verifySummaryLines()
        try verifyJSONEncoding()
        try verifyNegativeCountsAreClamped()
        try verifyProviderCoverageSummary()
        try verifyProviderPreflightReadinessSummary()
        try verifyProviderPreflightCommand()
        try verifyProviderSourceSetupIntent()
        try verifyProviderDiagnosticSourceOnboardingMetadata()
        try verifyCalendarsProviderSourceShortcuts()
        try verifyProviderHealthOnboardingActions()
        try verifyProviderSourceURLValidator()
        try verifyOAuthDiagnosticStatus()
        try verifyProviderStoreSyncTelemetry()
        try verifyEmptyProviderStoreDiagnostics()
        try verifyPartialProviderStoreDiagnostics()
        try verifyAppModelProviderDiagnostics()
        print("Provider diagnostics invariant passed.")
    }

    private static func verifySummaryLines() throws {
        let passed = ProviderDiagnosticReport(
            source: .googleCalendar,
            status: .passed,
            message: "",
            calendarCount: 3,
            eventCount: 12,
            writableCalendarCount: 2
        )
        try expect(
            passed.summaryLine == "Google Calendar passed: 3 calendar(s), 12 event(s), 2 writable",
            "Passed diagnostics should summarize provider counts"
        )

        let capabilitySummary = ProviderDiagnosticReport(
            source: .calDAV,
            status: .passed,
            message: "",
            calendarCount: 4,
            eventCount: 9,
            writableCalendarCount: 2,
            responseCapableCalendarCount: 3,
            readOnlyCalendarCount: 1,
            syncStateCount: 2,
            httpValidatorCount: 1,
            writeProbeCount: 1,
            responseProbeCount: 1
        )
        try expect(
            capabilitySummary.summaryLine == "CalDAV passed: 4 calendar(s), 9 event(s), 2 writable, 3 response-capable, 1 read-only, 2 sync state(s), 1 validator(s), 1 write probe(s), 1 response probe(s)",
            "Passed diagnostics should summarize provider calendar capabilities"
        )

        let subscriptionSummary = ProviderDiagnosticReport(
            source: .icsSubscription,
            status: .passed,
            message: "",
            calendarCount: 1,
            eventCount: 2,
            httpValidatorCount: 2,
            refreshIntervalSeconds: 90 * 60
        )
        try expect(
            subscriptionSummary.summaryLine == "ICS passed: 1 calendar(s), 2 event(s), 2 validator(s), refresh every 1h 30m",
            "ICS diagnostics should summarize feed validators and refresh cadence"
        )

        let skipped = ProviderDiagnosticReport(
            source: .calDAV,
            status: .skipped,
            message: "set WC_LIVE_CALDAV_URL, WC_LIVE_CALDAV_USERNAME, WC_LIVE_CALDAV_PASSWORD"
        )
        try expect(
            skipped.summaryLine == "CalDAV skipped: set WC_LIVE_CALDAV_URL, WC_LIVE_CALDAV_USERNAME, WC_LIVE_CALDAV_PASSWORD",
            "Skipped diagnostics should name required environment variables"
        )

        let failed = ProviderDiagnosticReport(
            source: .microsoft365,
            status: .failed,
            message: "token expired"
        )
        try expect(
            failed.summaryLine == "Microsoft 365 failed: token expired",
            "Failed diagnostics should preserve the provider error summary"
        )
    }

    private static func verifyJSONEncoding() throws {
        let reports = [
            ProviderDiagnosticReport(
                source: .icsSubscription,
                status: .passed,
                message: "fetched 1024 bytes",
                objectCount: 1,
                refreshIntervalSeconds: 2700
            ),
            ProviderDiagnosticReport(
                source: .microsoft365,
                status: .skipped,
                message: "set WC_LIVE_MICROSOFT_ACCESS_TOKEN"
            )
        ]
        let text = try ProviderDiagnosticJSON.encode(reports)
        try expect(text.contains(#""source" : "icsSubscription""#),
                   "Diagnostics JSON should include source identifiers")
        try expect(text.contains(#""status" : "skipped""#),
                   "Diagnostics JSON should include statuses")
        try expect(text.contains(#""refreshIntervalSeconds" : 2700"#),
                   "Diagnostics JSON should include subscription refresh cadence")
        let decoded = try JSONDecoder().decode([ProviderDiagnosticReport].self, from: Data(text.utf8))
        try expect(decoded == reports, "Diagnostics JSON should round-trip reports")
    }

    private static func verifyNegativeCountsAreClamped() throws {
        let report = ProviderDiagnosticReport(
            source: .calDAV,
            status: .passed,
            message: "  ",
            lastSyncDurationSeconds: -7,
            calendarCount: -1,
            eventCount: -2,
            objectCount: -3,
            writableCalendarCount: -4,
            responseCapableCalendarCount: -5,
            readOnlyCalendarCount: -6,
            identityEmailCount: -5,
            syncStateCount: -6,
            httpValidatorCount: -7,
            refreshIntervalSeconds: -8,
            writeProbeCount: -9,
            responseProbeCount: -10
        )
        try expect(report.calendarCount == 0, "Calendar count should be non-negative")
        try expect(report.eventCount == 0, "Event count should be non-negative")
        try expect(report.objectCount == 0, "Object count should be non-negative")
        try expect(report.writableCalendarCount == 0, "Writable calendar count should be non-negative")
        try expect(report.responseCapableCalendarCount == 0, "Response-capable calendar count should be non-negative")
        try expect(report.readOnlyCalendarCount == 0, "Read-only calendar count should be non-negative")
        try expect(report.lastSyncDurationSeconds == 0, "Sync duration should be non-negative")
        try expect(report.identityEmailCount == 0, "Identity email count should be non-negative")
        try expect(report.syncStateCount == 0, "Sync state count should be non-negative")
        try expect(report.httpValidatorCount == 0, "HTTP validator count should be non-negative")
        try expect(report.refreshIntervalSeconds == 0, "Refresh interval should be non-negative")
        try expect(report.writeProbeCount == 0, "Write probe count should be non-negative")
        try expect(report.responseProbeCount == 0, "Response probe count should be non-negative")
        try expect(report.pendingOutboxCount == 0, "Pending outbox count should be non-negative")
        try expect(report.attentionOutboxCount == 0, "Attention outbox count should be non-negative")
        try expect(report.summaryLine == "CalDAV passed: 0 calendar(s)",
                   "Blank messages should fall back to deterministic summaries")
    }

    private static func verifyProviderCoverageSummary() throws {
        let emptyReports = ProviderDiagnosticSource.allCases.map { source in
            onboardingReport(source)
        }
        let emptySummary = ProviderCoverageSummary(reports: emptyReports)
        try expect(emptySummary.enabledSourceCount == 0,
                   "Empty provider coverage should have no enabled source types")
        try expect(emptySummary.configuredSourceCount == 0,
                   "Empty provider coverage should have no configured source types")
        try expect(emptySummary.missingSources == ProviderDiagnosticSource.allCases,
                   "Empty provider coverage should list every supported source as missing")
        try expect(emptySummary.titleText == "0/4 source types enabled",
                   "Coverage title should expose enabled source count")

        let partialSummary = ProviderCoverageSummary(reports: [
            report(source: .googleCalendar, status: .pending, accountID: "google-1"),
            onboardingReport(.icsSubscription),
            onboardingReport(.calDAV),
            onboardingReport(.microsoft365)
        ])
        try expect(partialSummary.enabledSourceCount == 1,
                   "Partial provider coverage should count enabled source types")
        try expect(partialSummary.missingSources == [.icsSubscription, .calDAV, .microsoft365],
                   "Partial provider coverage should preserve missing source order")
        try expect(partialSummary.detailText.contains("Missing ICS/webcal, CalDAV, Microsoft 365"),
                   "Partial provider coverage should name missing source types")
        try expect(!partialSummary.isStrictCoverageComplete,
                   "Partial provider coverage should not be strict-preflight complete")

        let disabledSummary = ProviderCoverageSummary(reports: [
            report(source: .calDAV, status: .skipped, accountID: "caldav-disabled", isEnabled: false),
            onboardingReport(.icsSubscription),
            onboardingReport(.googleCalendar),
            onboardingReport(.microsoft365)
        ])
        try expect(disabledSummary.disabledSources == [.calDAV],
                   "Disabled provider coverage should distinguish disabled configured sources")
        try expect(disabledSummary.detailText.contains("Disabled CalDAV"),
                   "Disabled provider coverage should name disabled source types")

        let readySummary = ProviderCoverageSummary(reports: ProviderDiagnosticSource.allCases.map { source in
            report(source: source, status: .passed, accountID: "ready-\(source.rawValue)")
        })
        try expect(readySummary.enabledSourceCount == 4,
                   "Complete provider coverage should count all enabled source types")
        try expect(readySummary.isStrictCoverageComplete,
                   "Complete provider coverage should be strict-preflight complete")
        try expect(!readySummary.needsAttention,
                   "Complete passing provider coverage should not need attention")
        try expect(readySummary.detailText.contains("All supported source types are enabled"),
                   "Complete provider coverage should steer users to saved-source preflight")

        let failedSummary = ProviderCoverageSummary(reports: [
            report(source: .icsSubscription, status: .passed, accountID: "ics-ready"),
            report(source: .calDAV, status: .failed, message: "CalDAV password missing", accountID: "caldav-failed"),
            report(source: .googleCalendar, status: .passed, accountID: "google-ready"),
            report(source: .microsoft365, status: .passed, accountID: "microsoft-ready")
        ])
        try expect(failedSummary.isStrictCoverageComplete,
                   "Coverage can be complete while individual sources still need attention")
        try expect(failedSummary.needsAttention,
                   "Failed provider reports should make coverage need attention")
        try expect(failedSummary.detailText.contains("1 saved source need attention"),
                   "Coverage should summarize saved sources needing attention")
    }

    private static func verifyProviderPreflightReadinessSummary() throws {
        let emptyReports = ProviderDiagnosticSource.allCases.map { source in
            onboardingReport(source)
        }
        let emptySummary = ProviderPreflightReadinessSummary(reports: emptyReports)
        try expect(!emptySummary.isReady,
                   "Empty saved-source preflight should be blocked")
        try expect(emptySummary.titleText == "Saved-source preflight blocked",
                   "Blocked preflight should have an explicit title")
        try expect(emptySummary.failureMessages.count == ProviderDiagnosticSource.allCases.count,
                   "Empty saved-source preflight should fail every required source")
        try expect(emptySummary.failureMessages.contains { $0.contains("ICS skipped") },
                   "Empty saved-source preflight should surface exact skipped-source failures")

        let missingOAuthSummary = ProviderPreflightReadinessSummary(reports: [
            report(source: .icsSubscription, status: .pending, accountID: "ics-ready"),
            report(source: .calDAV, status: .pending, accountID: "caldav-ready"),
            report(source: .googleCalendar, status: .pending, accountID: "google-without-oauth"),
            oauthReport(source: .microsoft365, service: .microsoft365, accountID: "microsoft-ready")
        ])
        try expect(!missingOAuthSummary.isReady,
                   "Saved-source preflight should require refresh-token OAuth diagnostics")
        try expect(missingOAuthSummary.failureMessages.contains { $0.contains("Google Calendar") && $0.contains("refresh-token OAuth credentials") },
                   "Saved-source preflight should reuse exact OAuth credential failure text")

        let readySummary = ProviderPreflightReadinessSummary(reports: [
            report(source: .icsSubscription, status: .pending, accountID: "ics-ready"),
            report(source: .calDAV, status: .pending, accountID: "caldav-ready"),
            oauthReport(source: .googleCalendar, service: .googleCalendar, accountID: "google-ready"),
            oauthReport(source: .microsoft365, service: .microsoft365, accountID: "microsoft-ready")
        ])
        try expect(readySummary.isReady,
                   "Saved-source preflight should be ready when every required source is locally ready")
        try expect(readySummary.titleText == "Saved-source preflight ready",
                   "Ready preflight should have an explicit title")
        try expect(readySummary.detailText.contains("All required source types"),
                   "Ready preflight should summarize required source readiness")
        try expect(readySummary.failurePreview().isEmpty,
                   "Ready preflight should not produce failure previews")
    }

    private static func verifyProviderPreflightCommand() throws {
        try expect(
            ProviderPreflightCommand.shellCommand == "WC_LIVE_SMOKE_JSON=1 make live-provider-smoke-preflight",
            "Settings preflight command should match the saved-source preflight make target"
        )
        try expect(
            ProviderPreflightCommand.detailText.contains("No network fetches"),
            "Preflight detail should make no-network behavior explicit"
        )
        try expect(
            ProviderPreflightCommand.detailText.contains("OAuth refresh credentials"),
            "Preflight detail should mention OAuth credential readiness"
        )
        try expect(
            ProviderPreflightCommand.statusText(savedSourceCount: 0).contains("Add a protocol source"),
            "Empty-source preflight status should steer users toward source onboarding"
        )
        try expect(
            ProviderPreflightCommand.statusText(savedSourceCount: 1).contains("1 saved provider source"),
            "Single-source preflight status should use the singular label"
        )
        try expect(
            ProviderPreflightCommand.statusText(savedSourceCount: 3).contains("3 saved provider sources"),
            "Multi-source preflight status should use the plural label"
        )
    }

    private static func verifyProviderSourceSetupIntent() throws {
        let emptyIntent = ProviderSourceSetupIntent.settingsIntent(sourceCount: 0)
        try expect(emptyIntent == .addSource(nil),
                   "Settings should open source onboarding when no providers are saved")
        try expect(emptyIntent.shouldPresentAddSource,
                   "Add-source intent should present the add-source sheet")
        try expect(emptyIntent.preferredSource == nil,
                   "Generic settings Add Source should not force a provider type")
        try expect(emptyIntent.actionTitle == "Add Source",
                   "Empty provider settings action should be Add Source")
        try expect(emptyIntent.actionSystemImage == "plus",
                   "Empty provider settings action should use the add icon")

        let calDAVIntent = ProviderSourceSetupIntent.addSource(.calDAV)
        try expect(calDAVIntent.shouldPresentAddSource,
                   "Source-specific Add Source intents should present onboarding")
        try expect(calDAVIntent.preferredSource == .calDAV,
                   "Source-specific Add Source intents should preserve preferred provider type")
        try expect(calDAVIntent.actionTitle == "Add Source",
                   "Source-specific provider settings action should still be Add Source")

        let existingIntent = ProviderSourceSetupIntent.settingsIntent(sourceCount: 2)
        try expect(existingIntent == .manageSources,
                   "Settings should manage existing provider sources instead of opening Add Source")
        try expect(!existingIntent.shouldPresentAddSource,
                   "Manage-sources intent should only navigate to provider management")
        try expect(existingIntent.actionTitle == "Manage Sources",
                   "Existing provider settings action should be Manage Sources")
        try expect(existingIntent.actionSystemImage == "slider.horizontal.3",
                   "Existing provider settings action should use the management icon")
    }

    private static func verifyProviderDiagnosticSourceOnboardingMetadata() throws {
        for source in ProviderDiagnosticSource.allCases {
            try expect(!source.onboardingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "\(source.rawValue) onboarding should have a title")
            try expect(!source.onboardingSubtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "\(source.rawValue) onboarding should have a subtitle")
            try expect(source.onboardingActionTitle.contains(source.onboardingTitle),
                       "\(source.rawValue) onboarding action should include the source title")
        }

        try expect(ProviderDiagnosticSource.icsSubscription.onboardingSubtitle.contains(".ics"),
                   "ICS onboarding should explicitly mention .ics files")
        try expect(ProviderDiagnosticSource.icsSubscription.onboardingSubtitle.localizedCaseInsensitiveContains("webcal"),
                   "ICS onboarding should explicitly mention webcal links")
        try expect(ProviderDiagnosticSource.calDAV.onboardingSubtitle.contains("iCloud"),
                   "CalDAV onboarding should name popular CalDAV providers")
        try expect(ProviderDiagnosticSource.calDAV.onboardingSubtitle.contains("Nextcloud"),
                   "CalDAV onboarding should name self-hosted CalDAV providers")
        try expect(ProviderDiagnosticSource.googleCalendar.onboardingSubtitle.localizedCaseInsensitiveContains("OAuth"),
                   "Google onboarding should mention OAuth")
        try expect(ProviderDiagnosticSource.microsoft365.onboardingSubtitle.localizedCaseInsensitiveContains("Graph"),
                   "Microsoft onboarding should mention Graph sync")
    }

    private static func verifyCalendarsProviderSourceShortcuts() throws {
        let source = try String(contentsOfFile: "Sources/WorkingCalendar/CalendarsView.swift", encoding: .utf8)
        try expect(source.contains("ProviderSourceShortcutButton"),
                   "Calendars empty source state should expose provider source shortcut buttons")
        try expect(source.contains("ForEach(ProviderDiagnosticSource.allCases"),
                   "Calendars empty source state should render every supported provider source type")
        try expect(source.contains("add(source)"),
                   "Calendars source shortcuts should open onboarding with a source-specific preference")
        try expect(source.contains("source.onboardingActionTitle"),
                   "Calendars source shortcuts should use shared onboarding action copy")
        try expect(source.contains("source.onboardingSubtitle"),
                   "Calendars source shortcuts should use shared onboarding subtitle copy")
    }

    private static func verifyProviderHealthOnboardingActions() throws {
        let onboardingRow = SettingsProviderHealthRow(
            report: onboardingReport(.calDAV),
            addSource: {}
        )
        try expect(onboardingRow.shouldShowAddSourceAction,
                   "Provider health onboarding rows should expose Add Source actions")

        let onboardingWithoutAction = SettingsProviderHealthRow(report: onboardingReport(.icsSubscription))
        try expect(!onboardingWithoutAction.shouldShowAddSourceAction,
                   "Provider health rows should not show Add Source when no action is wired")

        let accountRow = SettingsProviderHealthRow(
            report: report(source: .googleCalendar, status: .pending, accountID: "google-real"),
            addSource: {}
        )
        try expect(!accountRow.shouldShowAddSourceAction,
                   "Real provider account health rows should not show onboarding Add Source actions")
    }

    private static func verifyProviderSourceURLValidator() throws {
        try expect(
            ProviderSourceURLValidator.validationMessage(kind: .icsSubscription, urlString: "webcal://calendar.example.com/team.ics") == nil,
            "ICS source validation should accept webcal subscriptions"
        )
        try expect(
            ProviderSourceURLValidator.validationMessage(kind: .icsSubscription, urlString: "calendar.example.com/team.ics") == nil,
            "ICS source validation should accept host-only subscription URLs normalized by sync"
        )
        try expect(
            ProviderSourceURLValidator.validationMessage(kind: .icsSubscription, urlString: "ftp://calendar.example.com/team.ics")?.contains("webcal") == true,
            "ICS source validation should reject unsupported URL schemes before saving"
        )
        try expect(
            ProviderSourceURLValidator.validationMessage(kind: .calDAV, urlString: "caldavs://calendar.example.com/dav") == nil,
            "CalDAV source validation should accept caldavs URLs"
        )
        try expect(
            ProviderSourceURLValidator.validationMessage(kind: .calDAV, urlString: "calendar.example.com") == nil,
            "CalDAV source validation should accept host-only server URLs normalized by discovery"
        )
        try expect(
            ProviderSourceURLValidator.validationMessage(kind: .calDAV, urlString: "ftp://calendar.example.com")?.contains("caldav") == true,
            "CalDAV source validation should reject unsupported URL schemes before saving"
        )
        try expect(
            ProviderSourceURLValidator.validationMessage(kind: .googleCalendar, urlString: "not-a-url") == nil,
            "OAuth provider source validation should leave OAuth endpoints to provider setup"
        )
    }

    private static func verifyOAuthDiagnosticStatus() throws {
        let now = try localDate(year: 2026, month: 7, day: 1, hour: 9)

        let missing = ProviderOAuthDiagnostic(
            service: .googleCalendar,
            credential: nil,
            now: now
        )
        try expect(missing.status == .missingCredential, "Missing OAuth credentials should be surfaced")
        try expect(missing.needsAttention, "Missing OAuth credentials should need attention")
        try expect(missing.missingScopeCount == OAuthServiceKind.googleCalendar.requiredGrantedScopes.count,
                   "Missing OAuth diagnostics should report required scope count")

        let ready = ProviderOAuthDiagnostic(
            service: .googleCalendar,
            credential: oauthCredential(service: .googleCalendar, expiresAt: now.addingTimeInterval(3600)),
            now: now
        )
        try expect(ready.status == .ready, "Valid OAuth credentials should be ready")
        try expect(!ready.needsAttention, "Ready OAuth credentials should not need attention")
        try expect(ready.hasRefreshToken, "Ready OAuth credentials should include a refresh token")
        try expect(ready.missingScopeCount == 0, "Ready OAuth credentials should include required scopes")

        let missingRefresh = ProviderOAuthDiagnostic(
            service: .microsoft365,
            credential: oauthCredential(
                service: .microsoft365,
                refreshToken: nil,
                expiresAt: now.addingTimeInterval(3600)
            ),
            now: now
        )
        try expect(missingRefresh.status == .missingRefreshToken,
                   "OAuth credentials without refresh tokens should ask for reconnect")
        try expect(missingRefresh.needsAttention,
                   "OAuth credentials without refresh tokens should need attention")

        let refreshDue = ProviderOAuthDiagnostic(
            service: .googleCalendar,
            credential: oauthCredential(service: .googleCalendar, expiresAt: now.addingTimeInterval(30)),
            now: now
        )
        try expect(refreshDue.status == .refreshDue, "OAuth credentials near expiry should be marked refresh due")
        try expect(!refreshDue.needsAttention, "Refresh-due OAuth credentials can be refreshed automatically")

        let missingScopes = ProviderOAuthDiagnostic(
            service: .microsoft365,
            credential: oauthCredential(
                service: .microsoft365,
                scope: "User.Read",
                expiresAt: now.addingTimeInterval(3600)
            ),
            now: now
        )
        try expect(missingScopes.status == .missingScopes,
                   "OAuth credentials without required granted scopes should ask for reconnect")
        try expect(missingScopes.missingScopeCount == 1,
                   "OAuth diagnostics should count missing required scopes")
    }

    @MainActor
    private static func verifyProviderStoreSyncTelemetry() throws {
        resetCalendarStorage()
        defer { resetCalendarStorage() }

        let now = try localDate(year: 2026, month: 7, day: 1, hour: 9)
        let account = providerAccount(
            id: "provider-diagnostics-telemetry",
            kind: .calDAV,
            title: "Telemetry CalDAV",
            enabled: true,
            identityEmail: nil,
            identityEmailAliases: [],
            lastSyncAt: nil,
            lastSyncStartedAt: nil,
            lastSyncDurationSeconds: nil,
            lastSyncFailedAt: nil,
            lastError: nil,
            now: now
        )
        UserDefaults.standard.set(try JSONEncoder().encode([account]), forKey: "calendarProviderAccounts")

        let store = CalendarProviderStore()
        let startedAt = now.addingTimeInterval(-4.25)
        store.recordSync(
            accountID: account.id,
            summary: LocalICSImportSummary(
                calendarsImported: 1,
                eventsImported: 2,
                eventsUpdated: 3,
                eventsSkipped: 4,
                eventsDeleted: 5
            ),
            startedAt: startedAt,
            at: now
        )
        let syncedAccount = try requireAccount(store, accountID: account.id)
        try expect(syncedAccount.lastSyncStartedAt == startedAt,
                   "Successful sync should persist the sync start timestamp")
        try expect(syncedAccount.lastSyncDurationSeconds == 4.25,
                   "Successful sync should persist duration")
        try expect(syncedAccount.lastSyncFailedAt == nil,
                   "Successful sync should clear prior failure timestamp")

        let failedAt = now.addingTimeInterval(20)
        let failedStart = failedAt.addingTimeInterval(-2)
        store.recordSyncError(
            accountID: account.id,
            error: ProviderDiagnosticsFixtureError("timeout"),
            syncStartedAt: failedStart,
            at: failedAt
        )
        let failedAccount = try requireAccount(store, accountID: account.id)
        try expect(failedAccount.lastSyncStartedAt == failedStart,
                   "Failed sync should persist the failing start timestamp")
        try expect(failedAccount.lastSyncDurationSeconds == 2,
                   "Failed sync should persist duration")
        try expect(failedAccount.lastSyncFailedAt == failedAt,
                   "Failed sync should persist failure timestamp")
        try expect(failedAccount.lastSyncAt == now,
                   "Failed sync should not erase the last successful sync timestamp")
    }

    @MainActor
    private static func verifyEmptyProviderStoreDiagnostics() throws {
        resetCalendarStorage()
        defer { resetCalendarStorage() }

        let model = AppModel()
        let reports = model.providerDiagnosticReports()

        try expect(reports.count == ProviderDiagnosticSource.allCases.count,
                   "Empty provider stores should expose onboarding diagnostics for every supported source")
        try expect(Set(reports.map(\.source)) == Set(ProviderDiagnosticSource.allCases),
                   "Empty provider diagnostics should cover ICS, CalDAV, Google, and Microsoft")

        for report in reports {
            try expect(report.status == .skipped,
                       "Empty provider diagnostics should mark \(report.source.title) as skipped")
            try expect(!report.isEnabled,
                       "Empty provider diagnostics should not look like enabled sources")
            try expect(report.accountID == "provider-onboarding-\(report.source.rawValue)",
                       "Empty provider diagnostics should have stable onboarding identities")
            try expect(report.message.contains("Add one from Calendars"),
                       "Empty provider diagnostics should point users to source onboarding")
        }
    }

    @MainActor
    private static func verifyPartialProviderStoreDiagnostics() throws {
        resetCalendarStorage()
        defer { resetCalendarStorage() }

        let now = try localDate(year: 2026, month: 7, day: 1, hour: 9)
        let googleAccount = providerAccount(
            id: "provider-diagnostics-google-only",
            kind: .googleCalendar,
            title: "Google Only",
            enabled: true,
            identityEmail: "me@example.com",
            identityEmailAliases: [],
            credentialKey: "missing-google-oauth-\(UUID().uuidString)",
            lastSyncAt: nil,
            lastSyncStartedAt: nil,
            lastSyncDurationSeconds: nil,
            lastSyncFailedAt: nil,
            lastError: nil,
            now: now
        )
        UserDefaults.standard.set(try JSONEncoder().encode([googleAccount]), forKey: "calendarProviderAccounts")

        let model = AppModel()
        let reports = model.providerDiagnosticReports(now: now)

        try expect(reports.count == ProviderDiagnosticSource.allCases.count,
                   "Partial provider stores should show connected sources plus missing provider onboarding rows")
        let googleReport = try requireReport(reports, accountID: googleAccount.id)
        try expect(googleReport.source == .googleCalendar,
                   "Partial provider diagnostics should include the connected Google source")
        try expect(!reports.contains { $0.accountID == "provider-onboarding-googleCalendar" },
                   "Connected provider kinds should not also show onboarding rows")

        for missingSource in [ProviderDiagnosticSource.icsSubscription, .calDAV, .microsoft365] {
            let report = try requireReport(reports, accountID: "provider-onboarding-\(missingSource.rawValue)")
            try expect(report.source == missingSource,
                       "Missing \(missingSource.title) diagnostics should preserve source kind")
            try expect(report.status == .skipped,
                       "Missing \(missingSource.title) diagnostics should be skipped onboarding rows")
            try expect(!report.isEnabled,
                       "Missing \(missingSource.title) onboarding rows should not look enabled")
        }
    }

    @MainActor
    private static func verifyAppModelProviderDiagnostics() throws {
        resetCalendarStorage()
        defer { resetCalendarStorage() }

        let now = try localDate(year: 2026, month: 7, day: 1, hour: 9)
        let syncedCalDAVCredentialKey = "provider-diagnostics-synced-caldav-password-\(UUID().uuidString)"
        let failedCalDAVCredentialKey = "provider-diagnostics-failed-caldav-password-\(UUID().uuidString)"
        let missingCalDAVCredentialKey = "provider-diagnostics-missing-caldav-password-\(UUID().uuidString)"
        let calDAVPasswords = [
            syncedCalDAVCredentialKey: "synced-password",
            failedCalDAVCredentialKey: "failed-password"
        ]

        let syncedAccount = providerAccount(
            id: "provider-diagnostics-synced-caldav",
            kind: .calDAV,
            title: "Work CalDAV",
            enabled: true,
            identityEmail: "Me@Example.COM",
            identityEmailAliases: ["smtp:alias@example.com"],
            credentialKey: syncedCalDAVCredentialKey,
            lastSyncAt: now.addingTimeInterval(-60),
            lastSyncStartedAt: now.addingTimeInterval(-65),
            lastSyncDurationSeconds: 5,
            lastSyncFailedAt: nil,
            calDAVSyncStates: [
                CalDAVCalendarSyncState(calendarHrefString: "/calendars/primary/", syncToken: "caldav-primary-token", cTag: ""),
                CalDAVCalendarSyncState(calendarHrefString: "/calendars/team/", syncToken: "", cTag: "team-ctag"),
                CalDAVCalendarSyncState(calendarHrefString: "/calendars/empty/", syncToken: " ", cTag: " ")
            ],
            lastError: nil,
            now: now
        )
        let missingOAuthAccount = providerAccount(
            id: "provider-diagnostics-missing-oauth",
            kind: .microsoft365,
            title: "Missing OAuth M365",
            enabled: true,
            identityEmail: nil,
            identityEmailAliases: [],
            credentialKey: "missing-oauth-\(UUID().uuidString)",
            lastSyncAt: now.addingTimeInterval(-120),
            lastSyncStartedAt: now.addingTimeInterval(-124),
            lastSyncDurationSeconds: 4,
            lastSyncFailedAt: nil,
            lastError: nil,
            now: now
        )
        let failedAccount = providerAccount(
            id: "provider-diagnostics-caldav",
            kind: .calDAV,
            title: "Team CalDAV",
            enabled: true,
            identityEmail: nil,
            identityEmailAliases: [],
            credentialKey: failedCalDAVCredentialKey,
            lastSyncAt: nil,
            lastSyncStartedAt: now.addingTimeInterval(-20),
            lastSyncDurationSeconds: 8,
            lastSyncFailedAt: now.addingTimeInterval(-12),
            calDAVSyncStates: [
                CalDAVCalendarSyncState(calendarHrefString: "/calendars/work/", syncToken: "caldav-token", cTag: "ctag"),
                CalDAVCalendarSyncState(calendarHrefString: "/calendars/empty/", syncToken: " ", cTag: " ")
            ],
            lastError: "  401 unauthorized  ",
            now: now
        )
        let missingCalDAVPasswordAccount = providerAccount(
            id: "provider-diagnostics-missing-caldav-password",
            kind: .calDAV,
            title: "Missing CalDAV Password",
            enabled: true,
            identityEmail: nil,
            identityEmailAliases: [],
            credentialKey: missingCalDAVCredentialKey,
            lastSyncAt: nil,
            lastSyncStartedAt: nil,
            lastSyncDurationSeconds: nil,
            lastSyncFailedAt: nil,
            lastError: nil,
            now: now
        )
        let invalidICSAccount = providerAccount(
            id: "provider-diagnostics-invalid-ics-url",
            kind: .icsSubscription,
            title: "Invalid ICS URL",
            enabled: true,
            identityEmail: nil,
            identityEmailAliases: [],
            overrideEndpointURLString: "ftp://calendar.example.com/work.ics",
            lastSyncAt: nil,
            lastSyncStartedAt: nil,
            lastSyncDurationSeconds: nil,
            lastSyncFailedAt: nil,
            lastError: nil,
            now: now
        )
        let invalidCalDAVAccount = providerAccount(
            id: "provider-diagnostics-invalid-caldav-url",
            kind: .calDAV,
            title: "Invalid CalDAV URL",
            enabled: true,
            identityEmail: nil,
            identityEmailAliases: [],
            credentialKey: syncedCalDAVCredentialKey,
            overrideEndpointURLString: "ftp://caldav.example.com/",
            lastSyncAt: nil,
            lastSyncStartedAt: nil,
            lastSyncDurationSeconds: nil,
            lastSyncFailedAt: nil,
            lastError: nil,
            now: now
        )
        let icsAccount = providerAccount(
            id: "provider-diagnostics-ics",
            kind: .icsSubscription,
            title: "Team ICS",
            enabled: true,
            identityEmail: nil,
            identityEmailAliases: [],
            lastSyncAt: now.addingTimeInterval(-180),
            lastSyncStartedAt: now.addingTimeInterval(-184),
            lastSyncDurationSeconds: 4,
            lastSyncFailedAt: nil,
            httpETag: "\"ics-v1\"",
            httpLastModified: "Thu, 25 Jun 2026 10:00:00 GMT",
            icsRefreshIntervalSeconds: 1800,
            lastError: nil,
            now: now
        )
        let disabledAccount = providerAccount(
            id: "provider-diagnostics-microsoft",
            kind: .microsoft365,
            title: "Disabled M365",
            enabled: false,
            identityEmail: nil,
            identityEmailAliases: [],
            lastSyncAt: nil,
            lastSyncStartedAt: nil,
            lastSyncDurationSeconds: nil,
            lastSyncFailedAt: nil,
            lastError: nil,
            now: now
        )
        UserDefaults.standard.set(
            try JSONEncoder().encode([
                syncedAccount,
                missingOAuthAccount,
                failedAccount,
                missingCalDAVPasswordAccount,
                invalidICSAccount,
                invalidCalDAVAccount,
                icsAccount,
                disabledAccount
            ]),
            forKey: "calendarProviderAccounts"
        )

        let model = AppModel(providerCredentialPassword: { calDAVPasswords[$0] })
        let calendarID = "local-calendar-caldav-\(syncedAccount.id)-primary"
        let responseOnlyCalendarID = "local-calendar-caldav-\(syncedAccount.id)-responses"
        let readOnlyCalendarID = "local-calendar-caldav-\(syncedAccount.id)-readonly"
        let importSummary = try model.localCalendarStore.importICSText(providerCalendarICS(
            writableCalendarID: calendarID,
            responseOnlyCalendarID: responseOnlyCalendarID,
            readOnlyCalendarID: readOnlyCalendarID
        ))
        try expect(importSummary.eventsImported == 3, "Expected provider diagnostics fixture events to import")

        var reports = model.providerDiagnosticReports(now: now)
        let syncedReport = try requireReport(reports, accountID: syncedAccount.id)
        try expect(syncedReport.status == .passed, "Synced account without errors should pass diagnostics")
        try expect(syncedReport.calendarCount == 3, "Diagnostics should count imported provider calendars")
        try expect(syncedReport.eventCount == 3, "Diagnostics should count imported provider events")
        try expect(syncedReport.writableCalendarCount == 1, "Diagnostics should count writable imported calendars")
        try expect(syncedReport.responseCapableCalendarCount == 2,
                   "Diagnostics should count response-capable imported calendars")
        try expect(syncedReport.readOnlyCalendarCount == 1,
                   "Diagnostics should count fully read-only imported calendars")
        try expect(syncedReport.identityEmailCount == 2, "Diagnostics should count primary identity plus aliases")
        try expect(syncedReport.summaryLine.contains("Work CalDAV"), "Account diagnostics should include the source title")
        try expect(syncedReport.nextSyncAt == now.addingTimeInterval(240),
                   "Provider diagnostics should preserve the account sync interval after app restart")
        try expect(syncedReport.lastSyncStartedAt == now.addingTimeInterval(-65),
                   "Provider diagnostics should include last sync start time")
        try expect(syncedReport.lastSyncDurationSeconds == 5,
                   "Provider diagnostics should include last sync duration")
        try expect(syncedReport.syncStateCount == 2,
                   "Provider diagnostics should count non-empty CalDAV sync states")
        try expect(syncedReport.oauth == nil,
                   "CalDAV diagnostics should not include OAuth health")

        let missingOAuthReport = try requireReport(reports, accountID: missingOAuthAccount.id)
        try expect(missingOAuthReport.status == .failed,
                   "Missing OAuth credentials should fail provider diagnostics")
        try expect(missingOAuthReport.message == "OAuth missing",
                   "Missing OAuth diagnostics should explain reconnect need")
        try expect(missingOAuthReport.oauth?.status == .missingCredential,
                   "Missing OAuth diagnostics should expose structured status")
        try expect(missingOAuthReport.needsAttention,
                   "Missing OAuth diagnostics should need attention")

        let missingCalDAVPasswordReport = try requireReport(reports, accountID: missingCalDAVPasswordAccount.id)
        try expect(missingCalDAVPasswordReport.status == .failed,
                   "Missing CalDAV Keychain password should fail provider diagnostics before network sync")
        try expect(missingCalDAVPasswordReport.message == "CalDAV password missing in Keychain",
                   "Missing CalDAV password diagnostics should explain the local credential issue")
        try expect(missingCalDAVPasswordReport.needsAttention,
                   "Missing CalDAV password diagnostics should need attention")

        let invalidICSReport = try requireReport(reports, accountID: invalidICSAccount.id)
        try expect(invalidICSReport.status == .failed,
                   "Invalid ICS/webcal URLs should fail app diagnostics before fetch")
        try expect(invalidICSReport.message == "ICS/webcal URL invalid",
                   "Invalid ICS/webcal diagnostics should explain the local URL issue")

        let invalidCalDAVReport = try requireReport(reports, accountID: invalidCalDAVAccount.id)
        try expect(invalidCalDAVReport.status == .failed,
                   "Invalid CalDAV URLs should fail app diagnostics before discovery")
        try expect(invalidCalDAVReport.message == "CalDAV URL invalid",
                   "Invalid CalDAV diagnostics should explain the local URL issue")

        let failedReport = try requireReport(reports, accountID: failedAccount.id)
        try expect(failedReport.status == .failed, "Provider lastError should fail diagnostics")
        try expect(failedReport.message == "401 unauthorized", "Provider diagnostics should trim persisted errors")
        try expect(failedReport.needsAttention, "Failed provider diagnostics should need attention")
        try expect(failedReport.lastSyncFailedAt == now.addingTimeInterval(-12),
                   "Provider diagnostics should include last failed sync timestamp")
        try expect(failedReport.lastSyncDurationSeconds == 8,
                   "Provider diagnostics should include failed sync duration")
        try expect(failedReport.syncStateCount == 1,
                   "Provider diagnostics should count non-empty CalDAV sync states")

        let icsReport = try requireReport(reports, accountID: icsAccount.id)
        try expect(icsReport.httpValidatorCount == 2,
                   "Provider diagnostics should count persisted ICS HTTP validators")
        try expect(icsReport.refreshIntervalSeconds == 1800,
                   "Provider diagnostics should preserve ICS refresh intervals")
        try expect(icsReport.syncStateCount == 0,
                   "ICS diagnostics should use validators rather than sync states")

        let disabledReport = try requireReport(reports, accountID: disabledAccount.id)
        try expect(disabledReport.status == .skipped, "Disabled sources should be marked skipped")
        try expect(!disabledReport.isEnabled, "Disabled source diagnostics should preserve enabled state")
        try expect(disabledReport.nextSyncAt == nil, "Disabled sources should not advertise a next sync time")

        let pendingEvent = localProviderEvent(
            id: "provider-diagnostics-pending-event",
            title: "Pending provider write",
            calendarID: calendarID,
            now: now
        )
        try expect(model.providerStore.enqueueProviderOutboxItem(.write(
            event: pendingEvent,
            accountID: syncedAccount.id,
            now: now
        )), "Expected diagnostics fixture outbox item to enqueue")
        reports = model.providerDiagnosticReports(now: now)
        let pendingReport = try requireReport(reports, accountID: syncedAccount.id)
        try expect(pendingReport.status == .pending, "Pending provider outbox should make diagnostics pending")
        try expect(pendingReport.pendingOutboxCount == 1, "Diagnostics should include pending provider outbox count")
        try expect(pendingReport.message == "1 remote update pending",
                   "Pending diagnostics should explain queued remote updates")

        guard let pendingItem = model.providerStore.providerOutbox.first else {
            throw ProviderDiagnosticsInvariantError("Expected provider diagnostics outbox fixture")
        }
        model.providerStore.recordProviderOutboxBlocked(
            id: pendingItem.id,
            error: "provider rejected fixture",
            at: now.addingTimeInterval(5)
        )
        reports = model.providerDiagnosticReports(now: now)
        let blockedReport = try requireReport(reports, accountID: syncedAccount.id)
        try expect(blockedReport.status == .failed,
                   "Blocked provider outbox should be surfaced as failed diagnostics")
        try expect(blockedReport.attentionOutboxCount == 1,
                   "Diagnostics should count provider outbox items needing attention")
        try expect(blockedReport.needsAttention,
                   "Blocked provider outbox diagnostics should need attention")
    }

    private static func requireReport(
        _ reports: [ProviderDiagnosticReport],
        accountID: String
    ) throws -> ProviderDiagnosticReport {
        guard let report = reports.first(where: { $0.accountID == accountID }) else {
            throw ProviderDiagnosticsInvariantError("Missing provider diagnostic report for \(accountID)")
        }
        return report
    }

    private static func onboardingReport(_ source: ProviderDiagnosticSource) -> ProviderDiagnosticReport {
        ProviderDiagnosticReport(
            source: source,
            status: .skipped,
            message: "No \(source.onboardingTitle) source connected.",
            accountID: "provider-onboarding-\(source.rawValue)",
            accountTitle: source.onboardingTitle,
            isEnabled: false
        )
    }

    private static func report(
        source: ProviderDiagnosticSource,
        status: ProviderDiagnosticStatus,
        message: String = "",
        accountID: String,
        isEnabled: Bool = true
    ) -> ProviderDiagnosticReport {
        ProviderDiagnosticReport(
            source: source,
            status: status,
            message: message,
            accountID: accountID,
            accountTitle: source.title,
            isEnabled: isEnabled
        )
    }

    private static func oauthReport(
        source: ProviderDiagnosticSource,
        service: OAuthServiceKind,
        accountID: String
    ) -> ProviderDiagnosticReport {
        let now = Date(timeIntervalSince1970: 0)
        return ProviderDiagnosticReport(
            source: source,
            status: .pending,
            message: "preflight ready",
            accountID: accountID,
            accountTitle: source.title,
            oauth: ProviderOAuthDiagnostic(
                service: service,
                credential: oauthCredential(service: service, expiresAt: now.addingTimeInterval(3600)),
                now: now
            )
        )
    }

    @MainActor
    private static func requireAccount(
        _ store: CalendarProviderStore,
        accountID: String
    ) throws -> CalendarProviderAccount {
        guard let account = store.accounts.first(where: { $0.id == accountID }) else {
            throw ProviderDiagnosticsInvariantError("Missing provider account \(accountID)")
        }
        return account
    }

    private static func providerAccount(
        id: String,
        kind: CalendarProviderKind,
        title: String,
        enabled: Bool,
        identityEmail: String?,
        identityEmailAliases: [String],
        credentialKey: String? = nil,
        overrideEndpointURLString: String? = nil,
        username: String? = nil,
        lastSyncAt: Date?,
        lastSyncStartedAt: Date? = nil,
        lastSyncDurationSeconds: Double? = nil,
        lastSyncFailedAt: Date? = nil,
        httpETag: String? = nil,
        httpLastModified: String? = nil,
        icsRefreshIntervalSeconds: Int? = nil,
        calDAVSyncStates: [CalDAVCalendarSyncState] = [],
        googleCalendarSyncStates: [GoogleCalendarSyncState] = [],
        microsoftGraphSyncStates: [MicrosoftGraphSyncState] = [],
        lastError: String?,
        now: Date
    ) -> CalendarProviderAccount {
        CalendarProviderAccount(
            id: id,
            kind: kind,
            title: title,
            endpointURLString: overrideEndpointURLString ?? endpointURLString(for: kind),
            username: username ?? (kind == .calDAV ? "me@example.com" : nil),
            identityEmail: identityEmail,
            identityEmailAliases: identityEmailAliases,
            credentialKey: credentialKey,
            enabled: enabled,
            importedEventCount: lastSyncAt == nil ? 0 : 1,
            updatedEventCount: 0,
            skippedEventCount: 0,
            httpETag: httpETag,
            httpLastModified: httpLastModified,
            icsRefreshIntervalSeconds: icsRefreshIntervalSeconds,
            calDAVSyncStates: calDAVSyncStates,
            googleCalendarSyncStates: googleCalendarSyncStates,
            microsoftGraphSyncStates: microsoftGraphSyncStates,
            lastSyncAt: lastSyncAt,
            lastSyncStartedAt: lastSyncStartedAt,
            lastSyncDurationSeconds: lastSyncDurationSeconds,
            lastSyncFailedAt: lastSyncFailedAt,
            lastError: lastError,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func oauthCredential(
        service: OAuthServiceKind,
        scope: String? = nil,
        refreshToken: String? = "refresh-token",
        expiresAt: Date
    ) -> OAuthCredential {
        OAuthCredential(
            accessToken: "access-token",
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            tokenType: "Bearer",
            scope: scope ?? service.scopes,
            clientID: "client-id",
            tenant: service.defaultTenant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : service.defaultTenant,
            service: service
        )
    }

    private static func endpointURLString(for kind: CalendarProviderKind) -> String {
        switch kind {
        case .local:
            return "working-calendar://local"
        case .icsSubscription:
            return "https://calendar.example.com/work.ics"
        case .calDAV:
            return "https://caldav.example.com/"
        case .googleCalendar:
            return "https://www.googleapis.com/calendar/v3"
        case .microsoft365:
            return "https://graph.microsoft.com/v1.0"
        }
    }

    private static func providerCalendarICS(
        writableCalendarID: String,
        responseOnlyCalendarID: String,
        readOnlyCalendarID: String
    ) -> String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Provider Diagnostics Fixture//EN
        CALSCALE:GREGORIAN
        BEGIN:VEVENT
        UID:provider-diagnostics-writable@example.com
        DTSTAMP:20260701T090000Z
        DTSTART:20260701T100000Z
        DTEND:20260701T103000Z
        SUMMARY:Diagnostics writable event
        X-WORKING-CALENDAR-ID:\(writableCalendarID)
        X-WORKING-CALENDAR-TITLE:Imported Work Google
        X-WORKING-CALENDAR-COLOR:#2563EB
        X-WORKING-CALENDAR-ALLOWS-EVENT-WRITE:TRUE
        X-WORKING-CALENDAR-ALLOWS-RESPONSES:TRUE
        X-WORKING-REMOTE-OBJECT-URL:google://diagnostics/primary/event
        END:VEVENT
        BEGIN:VEVENT
        UID:provider-diagnostics-response-only@example.com
        DTSTAMP:20260701T090000Z
        DTSTART:20260701T110000Z
        DTEND:20260701T113000Z
        SUMMARY:Diagnostics response-only event
        X-WORKING-CALENDAR-ID:\(responseOnlyCalendarID)
        X-WORKING-CALENDAR-TITLE:Imported RSVP Google
        X-WORKING-CALENDAR-COLOR:#0EA5E9
        X-WORKING-CALENDAR-ALLOWS-EVENT-WRITE:FALSE
        X-WORKING-CALENDAR-ALLOWS-RESPONSES:TRUE
        X-WORKING-REMOTE-OBJECT-URL:google://diagnostics/responses/event
        END:VEVENT
        BEGIN:VEVENT
        UID:provider-diagnostics-readonly@example.com
        DTSTAMP:20260701T090000Z
        DTSTART:20260701T120000Z
        DTEND:20260701T123000Z
        SUMMARY:Diagnostics read-only event
        X-WORKING-CALENDAR-ID:\(readOnlyCalendarID)
        X-WORKING-CALENDAR-TITLE:Imported Read-only Google
        X-WORKING-CALENDAR-COLOR:#64748B
        X-WORKING-CALENDAR-ALLOWS-EVENT-WRITE:FALSE
        X-WORKING-CALENDAR-ALLOWS-RESPONSES:FALSE
        X-WORKING-REMOTE-OBJECT-URL:google://diagnostics/readonly/event
        END:VEVENT
        END:VCALENDAR
        """
    }

    private static func localProviderEvent(
        id: String,
        title: String,
        calendarID: String,
        now: Date
    ) -> LocalCalendarEvent {
        LocalCalendarEvent(
            id: id,
            externalUID: "\(id)@example.com",
            remoteObjectURLString: "google://diagnostics/primary/\(id)",
            remoteETag: "\"etag-\(id)\"",
            sequence: 1,
            calendarID: calendarID,
            title: title,
            startDate: now.addingTimeInterval(3600),
            endDate: now.addingTimeInterval(5400),
            isAllDay: false,
            availability: .busy,
            status: .confirmed,
            privacy: .public,
            importance: .normal,
            categories: [],
            reminderOffsets: [],
            timeZoneIdentifier: TimeZone.current.identifier,
            organizerName: "",
            organizerEmail: "",
            attendees: [],
            myResponseStatus: .notInvited,
            location: "",
            notes: "",
            urlString: "",
            createdAt: now,
            updatedAt: now
        )
    }

    private static func resetCalendarStorage() {
        UserDefaults.standard.removeObject(forKey: "localCalendars")
        UserDefaults.standard.removeObject(forKey: "localCalendarEvents")
        UserDefaults.standard.removeObject(forKey: "selectedLocalCalendarIDs")
        UserDefaults.standard.removeObject(forKey: "calendarProviderAccounts")
        UserDefaults.standard.removeObject(forKey: "calendarProviderOutbox")
        UserDefaults.standard.removeObject(forKey: "appProviderSyncIntervalMinutes")
    }

    private static func localDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0
    ) throws -> Date {
        var components = DateComponents()
        components.calendar = Calendar.current
        components.timeZone = TimeZone.current
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        guard let date = components.date else {
            throw ProviderDiagnosticsInvariantError("Invalid date fixture")
        }
        return date
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw ProviderDiagnosticsInvariantError(message)
        }
    }
}

private struct ProviderDiagnosticsInvariantError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private struct ProviderDiagnosticsFixtureError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
