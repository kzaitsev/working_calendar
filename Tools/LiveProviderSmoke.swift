import Darwin
import Foundation

@main
struct LiveProviderSmoke {
    static func main() async {
        do {
            try await run()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            fflush(stdout)
            FileHandle.standardError.write(Data("Live provider smoke failed: \(message)\n".utf8))
            fflush(stderr)
            Darwin.exit(1)
        }
    }

    private static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let lookaheadDays = max(1, Int(environment["WC_LIVE_LOOKAHEAD_DAYS"] ?? "") ?? 7)
        let shouldPrintJSON = value("WC_LIVE_SMOKE_JSON", in: environment) == "1"
        let requirements = try LiveProviderSmokeRequirements(environment: environment)
        let googleRSVPProbe = try rsvpProbeInput(
            prefix: "WC_LIVE_GOOGLE",
            providerTitle: "Google",
            in: environment
        )
        let microsoftRSVPProbe = try rsvpProbeInput(
            prefix: "WC_LIVE_MICROSOFT",
            providerTitle: "Microsoft 365",
            in: environment
        )
        let calDAVRSVPProbe = try calDAVRSVPProbeInput(in: environment)
        let now = Date()
        let window = DateInterval(
            start: now,
            end: now.addingTimeInterval(TimeInterval(lookaheadDays * 24 * 60 * 60))
        )
        let storedSources = requirements.shouldUseStoredSources
            ? await StoredLiveProviderSources.load()
            : StoredLiveProviderSources()

        if requirements.shouldRunPreflight {
            try runPreflight(
                environment: environment,
                requirements: requirements,
                storedSources: storedSources,
                shouldPrintJSON: shouldPrintJSON
            )
            return
        }

        var reports: [ProviderDiagnosticReport] = []
        var configuredChecks = 0

        if let urlString = value("WC_LIVE_ICS_URL", in: environment) {
            configuredChecks += 1
            reports.append(try await smokeICS(urlString: urlString))
        } else if !storedSources.icsSubscriptions.isEmpty {
            for account in storedSources.icsSubscriptions {
                configuredChecks += 1
                reports.append(await storedSmokeReport(source: .icsSubscription, account: account) {
                    try await smokeICS(account: account)
                })
            }
        } else {
            reports.append(.skipped(source: .icsSubscription, requiredVariables: ["WC_LIVE_ICS_URL"]))
        }

        if let urlString = value("WC_LIVE_CALDAV_URL", in: environment),
           let username = value("WC_LIVE_CALDAV_USERNAME", in: environment),
           let password = value("WC_LIVE_CALDAV_PASSWORD", in: environment) {
            configuredChecks += 1
            reports.append(try await smokeCalDAV(
                urlString: urlString,
                username: username,
                password: password,
                window: window,
                shouldRunWriteSmoke: requirements.shouldRunWriteSmoke,
                rsvpProbe: calDAVRSVPProbe
            ))
        } else if !storedSources.calDAVAccounts.isEmpty {
            for account in storedSources.calDAVAccounts {
                configuredChecks += 1
                reports.append(await storedSmokeReport(source: .calDAV, account: account) {
                    try await smokeCalDAV(
                        account: account,
                        window: window,
                        shouldRunWriteSmoke: requirements.shouldRunWriteSmoke,
                        rsvpProbe: calDAVRSVPProbe
                    )
                })
            }
        } else {
            reports.append(.skipped(
                source: .calDAV,
                requiredVariables: ["WC_LIVE_CALDAV_URL", "WC_LIVE_CALDAV_USERNAME", "WC_LIVE_CALDAV_PASSWORD"]
            ))
        }

        if let auth = liveOAuthInput(
            service: .googleCalendar,
            accessTokenKey: "WC_LIVE_GOOGLE_ACCESS_TOKEN",
            clientIDKey: "WC_LIVE_GOOGLE_CLIENT_ID",
            refreshTokenKey: "WC_LIVE_GOOGLE_REFRESH_TOKEN",
            tenantKey: nil,
            in: environment
        ) {
            configuredChecks += 1
            reports.append(try await smokeGoogle(
                auth: auth,
                window: window,
                shouldRunWriteSmoke: requirements.shouldRunWriteSmoke,
                rsvpProbe: googleRSVPProbe
            ))
        } else if !storedSources.googleAccounts.isEmpty {
            for account in storedSources.googleAccounts {
                configuredChecks += 1
                reports.append(await storedOAuthSmokeReport(
                    source: .googleCalendar,
                    account: account,
                    service: .googleCalendar
                ) { credential in
                    try await smokeGoogle(
                        account: account,
                        auth: .credential(credential),
                        window: window,
                        shouldRunWriteSmoke: requirements.shouldRunWriteSmoke,
                        rsvpProbe: googleRSVPProbe
                    )
                })
            }
        } else {
            reports.append(.skipped(
                source: .googleCalendar,
                requiredVariables: [
                    "WC_LIVE_GOOGLE_ACCESS_TOKEN or WC_LIVE_GOOGLE_CLIENT_ID + WC_LIVE_GOOGLE_REFRESH_TOKEN"
                ]
            ))
        }

        if let auth = liveOAuthInput(
            service: .microsoft365,
            accessTokenKey: "WC_LIVE_MICROSOFT_ACCESS_TOKEN",
            clientIDKey: "WC_LIVE_MICROSOFT_CLIENT_ID",
            refreshTokenKey: "WC_LIVE_MICROSOFT_REFRESH_TOKEN",
            tenantKey: "WC_LIVE_MICROSOFT_TENANT",
            in: environment
        ) {
            configuredChecks += 1
            reports.append(try await smokeMicrosoft(
                auth: auth,
                window: window,
                shouldRunWriteSmoke: requirements.shouldRunWriteSmoke,
                rsvpProbe: microsoftRSVPProbe
            ))
        } else if !storedSources.microsoftAccounts.isEmpty {
            for account in storedSources.microsoftAccounts {
                configuredChecks += 1
                reports.append(await storedOAuthSmokeReport(
                    source: .microsoft365,
                    account: account,
                    service: .microsoft365
                ) { credential in
                    try await smokeMicrosoft(
                        account: account,
                        auth: .credential(credential),
                        window: window,
                        shouldRunWriteSmoke: requirements.shouldRunWriteSmoke,
                        rsvpProbe: microsoftRSVPProbe
                    )
                })
            }
        } else {
            reports.append(.skipped(
                source: .microsoft365,
                requiredVariables: [
                    "WC_LIVE_MICROSOFT_ACCESS_TOKEN or WC_LIVE_MICROSOFT_CLIENT_ID + WC_LIVE_MICROSOFT_REFRESH_TOKEN"
                ]
            ))
        }

        for report in reports {
            print(report.summaryLine)
        }

        let strictRequirementError = LiveProviderSmokeStrictContract.failure(
            reports: reports,
            requirements: requirements
        )

        guard configuredChecks > 0 else {
            print("No live provider credentials configured; live provider smoke skipped.")
            if shouldPrintJSON {
                print(try ProviderDiagnosticJSON.encode(reports))
            }
            if let strictRequirementError {
                throw strictRequirementError
            }
            return
        }

        print("Live provider smoke completed for \(configuredChecks) configured source(s).")
        if shouldPrintJSON {
            print(try ProviderDiagnosticJSON.encode(reports))
        }
        if let strictRequirementError {
            throw strictRequirementError
        }
    }

    private static func storedSmokeReport(
        source: ProviderDiagnosticSource,
        account: CalendarProviderAccount,
        operation: () async throws -> ProviderDiagnosticReport
    ) async -> ProviderDiagnosticReport {
        do {
            return try await operation()
        } catch {
            return failedStoredReport(source: source, account: account, error: error)
        }
    }

    private static func storedOAuthSmokeReport(
        source: ProviderDiagnosticSource,
        account: CalendarProviderAccount,
        service: OAuthServiceKind,
        operation: (OAuthCredential) async throws -> ProviderDiagnosticReport
    ) async -> ProviderDiagnosticReport {
        guard let credentialKey = account.credentialKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !credentialKey.isEmpty,
              let credential = OAuthCredentialStore.credential(key: credentialKey, fallbackService: service)
        else {
            return ProviderDiagnosticReport(
                source: source,
                status: .failed,
                message: "saved source is missing OAuth credentials in Keychain",
                accountID: account.id,
                accountTitle: account.title,
                isEnabled: account.enabled
            )
        }
        return await storedSmokeReport(source: source, account: account) {
            try await operation(credential)
        }
    }

    private static func failedStoredReport(
        source: ProviderDiagnosticSource,
        account: CalendarProviderAccount,
        error: Error
    ) -> ProviderDiagnosticReport {
        let message = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        return ProviderDiagnosticReport(
            source: source,
            status: .failed,
            message: message,
            accountID: account.id,
            accountTitle: account.title,
            isEnabled: account.enabled
        )
    }

    private static func runPreflight(
        environment: [String: String],
        requirements: LiveProviderSmokeRequirements,
        storedSources: StoredLiveProviderSources,
        shouldPrintJSON: Bool
    ) throws {
        let reports = preflightReports(
            environment: environment,
            requirements: requirements,
            storedSources: storedSources
        )

        for report in reports {
            print(report.summaryLine)
        }

        if shouldPrintJSON {
            print(try ProviderDiagnosticJSON.encode(reports))
        }

        if let error = LiveProviderSmokePreflightContract.failure(
            reports: reports,
            requirements: requirements
        ) {
            throw error
        }

        let checkedCount = reports.filter { $0.status != .skipped }.count
        guard checkedCount > 0 else {
            print("No live provider sources configured; preflight skipped.")
            return
        }
        print("Live provider preflight completed for \(checkedCount) source(s); no network requests or provider writes were performed.")
    }

    private static func preflightReports(
        environment: [String: String],
        requirements: LiveProviderSmokeRequirements,
        storedSources: StoredLiveProviderSources
    ) -> [ProviderDiagnosticReport] {
        var reports: [ProviderDiagnosticReport] = []

        reports.append(contentsOf: preflightICSReports(
            environment: environment,
            requirements: requirements,
            storedSources: storedSources
        ))
        reports.append(contentsOf: preflightCalDAVReports(
            environment: environment,
            requirements: requirements,
            storedSources: storedSources
        ))
        reports.append(contentsOf: preflightOAuthReports(
            source: .googleCalendar,
            service: .googleCalendar,
            accessTokenKey: "WC_LIVE_GOOGLE_ACCESS_TOKEN",
            clientIDKey: "WC_LIVE_GOOGLE_CLIENT_ID",
            refreshTokenKey: "WC_LIVE_GOOGLE_REFRESH_TOKEN",
            tenantKey: nil,
            storedAccounts: storedSources.googleAccounts,
            environment: environment,
            requirements: requirements
        ))
        reports.append(contentsOf: preflightOAuthReports(
            source: .microsoft365,
            service: .microsoft365,
            accessTokenKey: "WC_LIVE_MICROSOFT_ACCESS_TOKEN",
            clientIDKey: "WC_LIVE_MICROSOFT_CLIENT_ID",
            refreshTokenKey: "WC_LIVE_MICROSOFT_REFRESH_TOKEN",
            tenantKey: "WC_LIVE_MICROSOFT_TENANT",
            storedAccounts: storedSources.microsoftAccounts,
            environment: environment,
            requirements: requirements
        ))

        return reports
    }

    private static func preflightICSReports(
        environment: [String: String],
        requirements: LiveProviderSmokeRequirements,
        storedSources: StoredLiveProviderSources
    ) -> [ProviderDiagnosticReport] {
        if let urlString = value("WC_LIVE_ICS_URL", in: environment) {
            return [preflightURLReport(
                source: .icsSubscription,
                accountID: "env-ics",
                accountTitle: "Environment ICS",
                urlString: urlString,
                normalizer: CalendarURLNormalizer.subscriptionURL(from:),
                readyMessage: "preflight ready: env subscription URL is valid"
            )]
        }

        guard !storedSources.icsSubscriptions.isEmpty else {
            return [missingPreflightSourceReport(
                source: .icsSubscription,
                requiredVariables: ["WC_LIVE_ICS_URL"],
                savedSourceDescription: "ICS/webcal subscription",
                requirements: requirements
            )]
        }

        return storedSources.icsSubscriptions.map { account in
            preflightURLReport(
                source: .icsSubscription,
                accountID: account.id,
                accountTitle: account.title,
                isEnabled: account.enabled,
                urlString: account.endpointURLString,
                normalizer: CalendarURLNormalizer.subscriptionURL(from:),
                readyMessage: "preflight ready: saved subscription URL is valid"
            )
        }
    }

    private static func preflightCalDAVReports(
        environment: [String: String],
        requirements: LiveProviderSmokeRequirements,
        storedSources: StoredLiveProviderSources
    ) -> [ProviderDiagnosticReport] {
        let urlString = value("WC_LIVE_CALDAV_URL", in: environment)
        let username = value("WC_LIVE_CALDAV_USERNAME", in: environment)
        let password = value("WC_LIVE_CALDAV_PASSWORD", in: environment)
        let envConfiguredCount = [urlString, username, password].compactMap { $0 }.count
        if envConfiguredCount > 0 {
            guard let urlString,
                  let username,
                  password != nil
            else {
                return [ProviderDiagnosticReport(
                    source: .calDAV,
                    status: .failed,
                    message: "preflight needs WC_LIVE_CALDAV_URL, WC_LIVE_CALDAV_USERNAME, and WC_LIVE_CALDAV_PASSWORD together",
                    accountID: "env-caldav",
                    accountTitle: "Environment CalDAV"
                )]
            }
            var report = preflightURLReport(
                source: .calDAV,
                accountID: "env-caldav",
                accountTitle: "Environment CalDAV",
                urlString: urlString,
                normalizer: CalendarURLNormalizer.httpURL(from:),
                readyMessage: "preflight ready: env URL, username, and password are present"
            )
            if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                report = ProviderDiagnosticReport(
                    source: .calDAV,
                    status: .failed,
                    message: "preflight needs a non-empty CalDAV username",
                    accountID: "env-caldav",
                    accountTitle: "Environment CalDAV"
                )
            }
            return [report]
        }

        guard !storedSources.calDAVAccounts.isEmpty else {
            return [missingPreflightSourceReport(
                source: .calDAV,
                requiredVariables: ["WC_LIVE_CALDAV_URL", "WC_LIVE_CALDAV_USERNAME", "WC_LIVE_CALDAV_PASSWORD"],
                savedSourceDescription: "CalDAV account",
                requirements: requirements
            )]
        }

        return storedSources.calDAVAccounts.map { account in
            if value(in: account.username) == nil {
                return ProviderDiagnosticReport(
                    source: .calDAV,
                    status: .failed,
                    message: "saved source is missing a CalDAV username",
                    accountID: account.id,
                    accountTitle: account.title,
                    isEnabled: account.enabled
                )
            }
            guard let credentialKey = value(in: account.credentialKey) else {
                return ProviderDiagnosticReport(
                    source: .calDAV,
                    status: .failed,
                    message: "saved source is missing a CalDAV credential key",
                    accountID: account.id,
                    accountTitle: account.title,
                    isEnabled: account.enabled
                )
            }
            guard value(in: CalendarCredentialStore.password(key: credentialKey)) != nil else {
                return ProviderDiagnosticReport(
                    source: .calDAV,
                    status: .failed,
                    message: "saved source is missing a CalDAV password in Keychain",
                    accountID: account.id,
                    accountTitle: account.title,
                    isEnabled: account.enabled
                )
            }
            return preflightURLReport(
                source: .calDAV,
                accountID: account.id,
                accountTitle: account.title,
                isEnabled: account.enabled,
                urlString: account.endpointURLString,
                normalizer: CalendarURLNormalizer.httpURL(from:),
                readyMessage: "preflight ready: saved URL, username, and Keychain password are present"
            )
        }
    }

    private static func preflightOAuthReports(
        source: ProviderDiagnosticSource,
        service: OAuthServiceKind,
        accessTokenKey: String,
        clientIDKey: String,
        refreshTokenKey: String,
        tenantKey: String?,
        storedAccounts: [CalendarProviderAccount],
        environment: [String: String],
        requirements: LiveProviderSmokeRequirements
    ) -> [ProviderDiagnosticReport] {
        if let auth = liveOAuthInput(
            service: service,
            accessTokenKey: accessTokenKey,
            clientIDKey: clientIDKey,
            refreshTokenKey: refreshTokenKey,
            tenantKey: tenantKey,
            in: environment
        ) {
            switch auth {
            case .accessToken:
                return [ProviderDiagnosticReport(
                    source: source,
                    status: requirements.shouldRequireRefreshOAuth ? .failed : .pending,
                    message: requirements.shouldRequireRefreshOAuth
                        ? "preflight needs refresh-token OAuth credentials for strict provider audit"
                        : "preflight ready: env access token is present",
                    accountID: "env-\(service.rawValue)",
                    accountTitle: "Environment \(source.title)"
                )]
            case .credential(let credential):
                return [preflightOAuthReport(
                    source: source,
                    accountID: "env-\(service.rawValue)",
                    accountTitle: "Environment \(source.title)",
                    credential: credential,
                    readyMessage: "preflight ready: env refresh-token OAuth credentials are present"
                )]
            }
        }

        guard !storedAccounts.isEmpty else {
            return [missingPreflightSourceReport(
                source: source,
                requiredVariables: ["\(accessTokenKey) or \(clientIDKey) + \(refreshTokenKey)"],
                savedSourceDescription: "\(source.title) account",
                requirements: requirements
            )]
        }

        return storedAccounts.map { account in
            guard let credentialKey = value(in: account.credentialKey),
                  let credential = OAuthCredentialStore.credential(key: credentialKey, fallbackService: service)
            else {
                return ProviderDiagnosticReport(
                    source: source,
                    status: .failed,
                    message: "saved source is missing OAuth credentials in Keychain",
                    accountID: account.id,
                    accountTitle: account.title,
                    isEnabled: account.enabled
                )
            }
            return preflightOAuthReport(
                source: source,
                accountID: account.id,
                accountTitle: account.title,
                isEnabled: account.enabled,
                credential: credential,
                readyMessage: "preflight ready: saved OAuth credentials are present"
            )
        }
    }

    private static func missingPreflightSourceReport(
        source: ProviderDiagnosticSource,
        requiredVariables: [String],
        savedSourceDescription: String,
        requirements: LiveProviderSmokeRequirements
    ) -> ProviderDiagnosticReport {
        var message = "set \(requiredVariables.joined(separator: ", "))"
        if requirements.shouldUseStoredSources {
            message += " or add/enable a saved \(savedSourceDescription) in Working Calendar"
        }
        return ProviderDiagnosticReport(
            source: source,
            status: .skipped,
            message: message
        )
    }

    private static func preflightURLReport(
        source: ProviderDiagnosticSource,
        accountID: String,
        accountTitle: String,
        isEnabled: Bool = true,
        urlString: String,
        normalizer: (String) throws -> URL,
        readyMessage: String
    ) -> ProviderDiagnosticReport {
        do {
            _ = try normalizer(urlString)
            return ProviderDiagnosticReport(
                source: source,
                status: .pending,
                message: readyMessage,
                accountID: accountID,
                accountTitle: accountTitle,
                isEnabled: isEnabled
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return ProviderDiagnosticReport(
                source: source,
                status: .failed,
                message: "preflight URL is invalid: \(message)",
                accountID: accountID,
                accountTitle: accountTitle,
                isEnabled: isEnabled
            )
        }
    }

    private static func preflightOAuthReport(
        source: ProviderDiagnosticSource,
        accountID: String,
        accountTitle: String,
        isEnabled: Bool = true,
        credential: OAuthCredential,
        readyMessage: String
    ) -> ProviderDiagnosticReport {
        let diagnostic = ProviderOAuthDiagnostic(service: credential.service, credential: credential)
        return ProviderDiagnosticReport(
            source: source,
            status: diagnostic.needsAttention ? .failed : .pending,
            message: diagnostic.needsAttention ? "preflight OAuth needs attention: \(diagnostic.status.title)" : readyMessage,
            accountID: accountID,
            accountTitle: accountTitle,
            isEnabled: isEnabled,
            oauth: diagnostic
        )
    }

    private static func smokeICS(urlString: String) async throws -> ProviderDiagnosticReport {
        let url = try CalendarURLNormalizer.subscriptionURL(from: urlString)
        let account = providerAccount(
            id: "live-smoke-ics",
            kind: .icsSubscription,
            title: "Live ICS Smoke",
            endpointURLString: url.absoluteString
        )
        return try await smokeICS(account: account)
    }

    private static func smokeICS(account: CalendarProviderAccount) async throws -> ProviderDiagnosticReport {
        let url = try CalendarURLNormalizer.subscriptionURL(from: account.endpointURLString)
        var normalizedAccount = account
        normalizedAccount.endpointURLString = url.absoluteString
        let result = try await CalendarSubscriptionHTTP.fetch(account: normalizedAccount)
        let validatorCount = [result.eTag, result.lastModified].filter {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }.count
        guard let text = result.text else {
            return ProviderDiagnosticReport(
                source: .icsSubscription,
                status: .passed,
                message: "feed returned not-modified",
                accountID: account.id,
                accountTitle: account.title,
                isEnabled: account.enabled,
                httpValidatorCount: validatorCount,
                refreshIntervalSeconds: result.refreshIntervalSeconds
            )
        }
        guard text.range(of: "BEGIN:VCALENDAR", options: [.caseInsensitive]) != nil else {
            throw LiveProviderSmokeError("ICS smoke failed: response did not look like VCALENDAR data.")
        }
        return ProviderDiagnosticReport(
            source: .icsSubscription,
            status: .passed,
            message: "fetched \(text.utf8.count) bytes from \(url.host ?? "feed")",
            accountID: account.id,
            accountTitle: account.title,
            isEnabled: account.enabled,
            httpValidatorCount: validatorCount,
            refreshIntervalSeconds: result.refreshIntervalSeconds
        )
    }

    private static func smokeCalDAV(
        urlString: String,
        username: String,
        password: String,
        window: DateInterval,
        shouldRunWriteSmoke: Bool,
        rsvpProbe: LiveCalDAVRSVPProbeInput?
    ) async throws -> ProviderDiagnosticReport {
        let url = try CalendarURLNormalizer.httpURL(from: urlString)
        let credentialKey = "live-smoke-caldav-password"
        let account = providerAccount(
            id: "live-smoke-caldav",
            kind: .calDAV,
            title: "Live CalDAV Smoke",
            endpointURLString: url.absoluteString,
            username: username,
            credentialKey: credentialKey
        )
        let client = CalDAVClient(passwordProvider: { key in
            key == credentialKey ? password : nil
        })
        return try await smokeCalDAV(
            account: account,
            client: client,
            window: window,
            shouldRunWriteSmoke: shouldRunWriteSmoke,
            rsvpProbe: rsvpProbe
        )
    }

    private static func smokeCalDAV(
        account: CalendarProviderAccount,
        window: DateInterval,
        shouldRunWriteSmoke: Bool,
        rsvpProbe: LiveCalDAVRSVPProbeInput?
    ) async throws -> ProviderDiagnosticReport {
        try await smokeCalDAV(
            account: account,
            client: CalDAVClient(),
            window: window,
            shouldRunWriteSmoke: shouldRunWriteSmoke,
            rsvpProbe: rsvpProbe
        )
    }

    private static func smokeCalDAV(
        account: CalendarProviderAccount,
        client: CalDAVClient,
        window: DateInterval,
        shouldRunWriteSmoke: Bool,
        rsvpProbe: LiveCalDAVRSVPProbeInput?
    ) async throws -> ProviderDiagnosticReport {
        let identityEmails = (try? await client.fetchAccountIdentityEmails(account: account)) ?? []
        let payloads = try await client.fetchCalendarPayloads(
            account: account,
            startDate: window.start,
            endDate: window.end
        )
        let objectCount = payloads.reduce(0) { $0 + $1.objects.count }
        let writableCount = payloads.filter(\.calendar.allowsEventWrite).count
        let responseCount = payloads.filter(\.calendar.allowsResponses).count
        let readOnlyCount = payloads.filter {
            !$0.calendar.allowsEventWrite && !$0.calendar.allowsResponses
        }.count
        let syncStateCount = payloads.filter {
            !$0.syncState.syncToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.syncState.cTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let writeProbeCount = shouldRunWriteSmoke
            ? try await runCalDAVWriteProbe(account: account, client: client, payloads: payloads)
            : 0
        let responseProbeCount = try await runCalDAVRSVPProbe(
            account: account,
            client: client,
            payloads: payloads,
            probe: rsvpProbe
        )
        return ProviderDiagnosticReport(
            source: .calDAV,
            status: .passed,
            message: "",
            accountID: account.id,
            accountTitle: account.title,
            isEnabled: account.enabled,
            calendarCount: payloads.count,
            objectCount: objectCount,
            writableCalendarCount: writableCount,
            responseCapableCalendarCount: responseCount,
            readOnlyCalendarCount: readOnlyCount,
            identityEmailCount: identityEmails.count,
            syncStateCount: syncStateCount,
            writeProbeCount: writeProbeCount,
            responseProbeCount: responseProbeCount
        )
    }

    private static func smokeGoogle(
        auth: LiveOAuthInput,
        window: DateInterval,
        shouldRunWriteSmoke: Bool,
        rsvpProbe: LiveRSVPProbeInput?
    ) async throws -> ProviderDiagnosticReport {
        let account = providerAccount(
            id: "live-smoke-google",
            kind: .googleCalendar,
            title: "Live Google Smoke",
            endpointURLString: "https://www.googleapis.com/calendar/v3"
        )
        return try await smokeGoogle(
            account: account,
            auth: auth,
            window: window,
            shouldRunWriteSmoke: shouldRunWriteSmoke,
            rsvpProbe: rsvpProbe
        )
    }

    private static func smokeGoogle(
        account: CalendarProviderAccount,
        auth: LiveOAuthInput,
        window: DateInterval,
        shouldRunWriteSmoke: Bool,
        rsvpProbe: LiveRSVPProbeInput?
    ) async throws -> ProviderDiagnosticReport {
        let tokenBox: LiveOAuthTokenBox?
        let accessTokenProvider: CalendarProviderAccessTokenProvider
        switch auth {
        case .accessToken(let accessToken):
            tokenBox = nil
            accessTokenProvider = { _, service, forceRefresh in
                guard service == .googleCalendar else {
                    throw LiveProviderSmokeError("Google smoke requested unexpected OAuth service \(service.rawValue).")
                }
                guard !forceRefresh else {
                    throw LiveProviderSmokeError(
                        "Google smoke cannot refresh a raw access token; set WC_LIVE_GOOGLE_CLIENT_ID and WC_LIVE_GOOGLE_REFRESH_TOKEN."
                    )
                }
                return accessToken
            }
        case .credential(let credential):
            let box = LiveOAuthTokenBox(credential: credential)
            tokenBox = box
            accessTokenProvider = { account, service, forceRefresh in
                try await box.accessToken(account: account, service: service, forceRefresh: forceRefresh)
            }
        }
        let client = GoogleCalendarClient(accessTokenProvider: accessTokenProvider)
        let payloads = try await client.fetchCalendarPayloads(
            account: account,
            startDate: window.start,
            endDate: window.end
        )
        let eventCount = payloads.reduce(0) { $0 + $1.events.count }
        let writableCount = payloads.filter(\.calendar.allowsEventWrite).count
        let responseCount = payloads.filter(\.calendar.allowsResponses).count
        let readOnlyCount = payloads.filter {
            !$0.calendar.allowsEventWrite && !$0.calendar.allowsResponses
        }.count
        let syncStateCount = payloads.filter {
            !$0.syncToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let writeProbeCount = shouldRunWriteSmoke
            ? try await runGoogleWriteProbe(account: account, client: client, payloads: payloads)
            : 0
        let responseProbeCount = try await runGoogleRSVPProbe(
            account: account,
            client: client,
            probe: rsvpProbe
        )
        return ProviderDiagnosticReport(
            source: .googleCalendar,
            status: .passed,
            message: "",
            accountID: account.id,
            accountTitle: account.title,
            isEnabled: account.enabled,
            oauth: tokenBox?.diagnostic,
            calendarCount: payloads.count,
            eventCount: eventCount,
            writableCalendarCount: writableCount,
            responseCapableCalendarCount: responseCount,
            readOnlyCalendarCount: readOnlyCount,
            syncStateCount: syncStateCount,
            writeProbeCount: writeProbeCount,
            responseProbeCount: responseProbeCount
        )
    }

    private static func smokeMicrosoft(
        auth: LiveOAuthInput,
        window: DateInterval,
        shouldRunWriteSmoke: Bool,
        rsvpProbe: LiveRSVPProbeInput?
    ) async throws -> ProviderDiagnosticReport {
        let account = providerAccount(
            id: "live-smoke-microsoft",
            kind: .microsoft365,
            title: "Live Microsoft Smoke",
            endpointURLString: "https://graph.microsoft.com/v1.0"
        )
        return try await smokeMicrosoft(
            account: account,
            auth: auth,
            window: window,
            shouldRunWriteSmoke: shouldRunWriteSmoke,
            rsvpProbe: rsvpProbe
        )
    }

    private static func smokeMicrosoft(
        account: CalendarProviderAccount,
        auth: LiveOAuthInput,
        window: DateInterval,
        shouldRunWriteSmoke: Bool,
        rsvpProbe: LiveRSVPProbeInput?
    ) async throws -> ProviderDiagnosticReport {
        let tokenBox: LiveOAuthTokenBox?
        let accessTokenProvider: CalendarProviderAccessTokenProvider
        switch auth {
        case .accessToken(let accessToken):
            tokenBox = nil
            accessTokenProvider = { _, service, forceRefresh in
                guard service == .microsoft365 else {
                    throw LiveProviderSmokeError("Microsoft smoke requested unexpected OAuth service \(service.rawValue).")
                }
                guard !forceRefresh else {
                    throw LiveProviderSmokeError(
                        "Microsoft smoke cannot refresh a raw access token; set WC_LIVE_MICROSOFT_CLIENT_ID and WC_LIVE_MICROSOFT_REFRESH_TOKEN."
                    )
                }
                return accessToken
            }
        case .credential(let credential):
            let box = LiveOAuthTokenBox(credential: credential)
            tokenBox = box
            accessTokenProvider = { account, service, forceRefresh in
                try await box.accessToken(account: account, service: service, forceRefresh: forceRefresh)
            }
        }
        let client = MicrosoftGraphCalendarClient(accessTokenProvider: accessTokenProvider)
        let identityEmails = try await client.fetchAccountIdentityEmails(account: account)
        let payloads = try await client.fetchCalendarPayloads(
            account: account,
            startDate: window.start,
            endDate: window.end
        )
        let eventCount = payloads.reduce(0) { $0 + $1.events.count }
        let writableCount = payloads.filter(\.calendar.allowsEventWrite).count
        let responseCount = payloads.filter(\.calendar.allowsResponses).count
        let readOnlyCount = payloads.filter {
            !$0.calendar.allowsEventWrite && !$0.calendar.allowsResponses
        }.count
        let syncStateCount = payloads.filter {
            !$0.deltaLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let writeProbeCount = shouldRunWriteSmoke
            ? try await runMicrosoftWriteProbe(account: account, client: client, payloads: payloads)
            : 0
        let responseProbeCount = try await runMicrosoftRSVPProbe(
            account: account,
            client: client,
            probe: rsvpProbe
        )
        return ProviderDiagnosticReport(
            source: .microsoft365,
            status: .passed,
            message: "",
            accountID: account.id,
            accountTitle: account.title,
            isEnabled: account.enabled,
            oauth: tokenBox?.diagnostic,
            calendarCount: payloads.count,
            eventCount: eventCount,
            writableCalendarCount: writableCount,
            responseCapableCalendarCount: responseCount,
            readOnlyCalendarCount: readOnlyCount,
            identityEmailCount: identityEmails.count,
            syncStateCount: syncStateCount,
            writeProbeCount: writeProbeCount,
            responseProbeCount: responseProbeCount
        )
    }

    private static func runGoogleRSVPProbe(
        account: CalendarProviderAccount,
        client: GoogleCalendarClient,
        probe: LiveRSVPProbeInput?
    ) async throws -> Int {
        guard let probe else { return 0 }
        let remoteObjectURLString = remoteObjectURLString(
            scheme: "google",
            accountID: account.id,
            calendarID: probe.calendarID,
            eventID: probe.eventID
        )
        _ = try await client.respondToEvent(
            account: account,
            remoteObjectURLString: remoteObjectURLString,
            response: probe.response
        )
        return 1
    }

    private static func runMicrosoftRSVPProbe(
        account: CalendarProviderAccount,
        client: MicrosoftGraphCalendarClient,
        probe: LiveRSVPProbeInput?
    ) async throws -> Int {
        guard let probe else { return 0 }
        let remoteObjectURLString = remoteObjectURLString(
            scheme: "microsoft365",
            accountID: account.id,
            calendarID: probe.calendarID,
            eventID: probe.eventID
        )
        _ = try await client.respondToEvent(
            account: account,
            remoteObjectURLString: remoteObjectURLString,
            response: probe.response
        )
        return 1
    }

    private static func runCalDAVWriteProbe(
        account: CalendarProviderAccount,
        client: CalDAVClient,
        payloads: [CalDAVCalendarPayload]
    ) async throws -> Int {
        guard let payload = payloads.first(where: \.calendar.allowsEventWrite) else {
            throw LiveProviderSmokeError("CalDAV live write smoke requested, but no writable calendar was discovered.")
        }
        let localCalendar = LocalCalendar(
            id: client.localCalendarID(for: account, calendar: payload.calendar),
            title: payload.calendar.displayName,
            colorHex: payload.calendar.colorHex,
            allowsEventWrite: true,
            allowsResponses: payload.calendar.allowsResponses
        )
        let event = liveWriteProbeEvent(calendarID: localCalendar.id)
        var remoteObjectURL: URL?
        var remoteETag = ""
        do {
            let result = try await client.putEvent(
                event,
                localCalendar: localCalendar,
                account: account,
                calendar: payload.calendar
            )
            remoteObjectURL = result.remoteObjectURL
            remoteETag = result.eTag
            let updatedEvent = LiveProviderWriteProbeMutation.updatedEvent(
                event,
                remoteObjectURLString: result.remoteObjectURL.absoluteString,
                remoteETag: result.eTag
            )
            let updateResult = try await client.putEvent(
                updatedEvent,
                localCalendar: localCalendar,
                account: account,
                calendar: payload.calendar
            )
            remoteObjectURL = updateResult.remoteObjectURL
            remoteETag = updateResult.eTag
            try await client.deleteEventObject(
                account: account,
                remoteObjectURL: updateResult.remoteObjectURL,
                remoteETag: updateResult.eTag
            )
            return 1
        } catch {
            if let remoteObjectURL {
                try? await client.deleteEventObject(
                    account: account,
                    remoteObjectURL: remoteObjectURL,
                    remoteETag: remoteETag
                )
            }
            throw error
        }
    }

    private static func runCalDAVRSVPProbe(
        account: CalendarProviderAccount,
        client: CalDAVClient,
        payloads: [CalDAVCalendarPayload],
        probe: LiveCalDAVRSVPProbeInput?
    ) async throws -> Int {
        guard let probe else { return 0 }
        guard let match = calDAVObject(
            matching: probe.objectURLString,
            in: payloads
        ) else {
            throw LiveProviderSmokeError(
                "CalDAV RSVP probe object was not found in the fetched lookahead window: \(probe.objectURLString)"
            )
        }

        let annotatedText = client.annotatedICSText(
            object: match.object,
            calendar: match.payload.calendar,
            account: account
        )
        let imported = try LocalCalendarICSCodec.import(annotatedText)
        guard let event = imported.events.first(where: {
            normalizedRemoteObjectURL($0.remoteObjectURLString) == normalizedRemoteObjectURL(match.object.href.absoluteString)
        }) ?? imported.events.first else {
            throw LiveProviderSmokeError("CalDAV RSVP probe object did not import as an event.")
        }
        try await client.respondToEvent(
            account: account,
            event: event,
            response: probe.response,
            occurrenceStartDate: nil,
            occurrenceIsAllDay: false
        )
        return 1
    }

    private static func calDAVObject(
        matching objectURLString: String,
        in payloads: [CalDAVCalendarPayload]
    ) -> (payload: CalDAVCalendarPayload, object: CalDAVCalendarObject)? {
        let normalizedTarget = normalizedRemoteObjectURL(objectURLString)
        guard !normalizedTarget.isEmpty else { return nil }
        for payload in payloads {
            if let object = payload.objects.first(where: {
                normalizedRemoteObjectURL($0.href.absoluteString) == normalizedTarget
            }) {
                return (payload, object)
            }
        }
        return nil
    }

    private static func runGoogleWriteProbe(
        account: CalendarProviderAccount,
        client: GoogleCalendarClient,
        payloads: [GoogleCalendarPayload]
    ) async throws -> Int {
        guard let payload = payloads.first(where: \.calendar.allowsEventWrite) else {
            throw LiveProviderSmokeError("Google live write smoke requested, but no writable calendar was discovered.")
        }
        let localCalendar = LocalCalendar(
            id: client.localCalendarID(for: account, googleCalendarID: payload.calendar.id),
            title: payload.calendar.summary,
            colorHex: payload.calendar.backgroundColor,
            allowsEventWrite: true,
            allowsResponses: payload.calendar.allowsResponses
        )
        let event = liveWriteProbeEvent(calendarID: localCalendar.id)
        var remoteObjectURLString = ""
        var remoteETag = ""
        do {
            let result = try await client.putEvent(event, localCalendar: localCalendar, account: account)
            remoteObjectURLString = result.remoteObjectURLString
            remoteETag = result.remoteETag
            let updatedEvent = LiveProviderWriteProbeMutation.updatedEvent(
                event,
                remoteObjectURLString: result.remoteObjectURLString,
                remoteETag: result.remoteETag
            )
            let updateResult = try await client.putEvent(updatedEvent, localCalendar: localCalendar, account: account)
            remoteObjectURLString = updateResult.remoteObjectURLString
            remoteETag = updateResult.remoteETag
            try await client.deleteEvent(
                account: account,
                remoteObjectURLString: updateResult.remoteObjectURLString,
                remoteETag: updateResult.remoteETag
            )
            return 1
        } catch {
            if !remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? await client.deleteEvent(
                    account: account,
                    remoteObjectURLString: remoteObjectURLString,
                    remoteETag: remoteETag
                )
            }
            throw error
        }
    }

    private static func runMicrosoftWriteProbe(
        account: CalendarProviderAccount,
        client: MicrosoftGraphCalendarClient,
        payloads: [MicrosoftGraphCalendarPayload]
    ) async throws -> Int {
        guard let payload = payloads.first(where: \.calendar.allowsEventWrite) else {
            throw LiveProviderSmokeError("Microsoft 365 live write smoke requested, but no writable calendar was discovered.")
        }
        let localCalendar = LocalCalendar(
            id: client.localCalendarID(for: account, graphCalendarID: payload.calendar.id),
            title: payload.calendar.name,
            colorHex: payload.calendar.colorHex,
            allowsEventWrite: true,
            allowsResponses: payload.calendar.allowsResponses
        )
        let event = liveWriteProbeEvent(calendarID: localCalendar.id)
        var remoteObjectURLString = ""
        var remoteETag = ""
        do {
            let result = try await client.putEvent(event, localCalendar: localCalendar, account: account)
            remoteObjectURLString = result.remoteObjectURLString
            remoteETag = result.remoteETag
            let updatedEvent = LiveProviderWriteProbeMutation.updatedEvent(
                event,
                remoteObjectURLString: result.remoteObjectURLString,
                remoteETag: result.remoteETag
            )
            let updateResult = try await client.putEvent(updatedEvent, localCalendar: localCalendar, account: account)
            remoteObjectURLString = updateResult.remoteObjectURLString
            remoteETag = updateResult.remoteETag
            try await client.deleteEvent(
                account: account,
                remoteObjectURLString: updateResult.remoteObjectURLString,
                remoteETag: updateResult.remoteETag
            )
            return 1
        } catch {
            if !remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? await client.deleteEvent(
                    account: account,
                    remoteObjectURLString: remoteObjectURLString,
                    remoteETag: remoteETag
                )
            }
            throw error
        }
    }

    private static func liveWriteProbeEvent(calendarID: String) -> LocalCalendarEvent {
        let now = Date()
        let startDate = now.addingTimeInterval(2 * 60 * 60)
        let endDate = startDate.addingTimeInterval(15 * 60)
        let uniqueID = "live-smoke-\(UUID().uuidString.lowercased())"
        return LocalCalendarEvent(
            id: uniqueID,
            externalUID: "\(uniqueID)@working-calendar-live-smoke",
            sequence: 0,
            calendarID: calendarID,
            title: "[Working Calendar live smoke] create/update/delete probe",
            startDate: startDate,
            endDate: endDate,
            isAllDay: false,
            availability: .free,
            status: .confirmed,
            privacy: .public,
            importance: .low,
            categories: ["Working Calendar live smoke"],
            reminderOffsets: [],
            timeZoneIdentifier: TimeZone.current.identifier,
            organizerName: "",
            organizerEmail: "",
            attendees: [],
            myResponseStatus: .notInvited,
            location: "",
            notes: "Created, updated, and deleted automatically by WC_LIVE_WRITE_SMOKE.",
            urlString: "",
            createdAt: now,
            updatedAt: now
        )
    }

    private static func providerAccount(
        id: String,
        kind: CalendarProviderKind,
        title: String,
        endpointURLString: String,
        username: String? = nil,
        credentialKey: String? = nil
    ) -> CalendarProviderAccount {
        let now = Date()
        return CalendarProviderAccount(
            id: id,
            kind: kind,
            title: title,
            endpointURLString: endpointURLString,
            username: username,
            credentialKey: credentialKey,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func value(_ key: String, in environment: [String: String]) -> String? {
        value(in: environment[key])
    }

    private static func value(in rawValue: String?) -> String? {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func rsvpProbeInput(
        prefix: String,
        providerTitle: String,
        in environment: [String: String]
    ) throws -> LiveRSVPProbeInput? {
        let calendarID = value("\(prefix)_RSVP_CALENDAR_ID", in: environment)
        let eventID = value("\(prefix)_RSVP_EVENT_ID", in: environment)
        let responseText = value("\(prefix)_RSVP_RESPONSE", in: environment)
        let configuredCount = [calendarID, eventID, responseText].compactMap { $0 }.count
        guard configuredCount > 0 else { return nil }
        guard let calendarID, let eventID, let responseText else {
            throw LiveProviderSmokeError(
                "\(providerTitle) RSVP probe needs \(prefix)_RSVP_CALENDAR_ID, \(prefix)_RSVP_EVENT_ID, and \(prefix)_RSVP_RESPONSE."
            )
        }
        guard let response = CalendarEventResponse(liveRSVPValue: responseText) else {
            throw LiveProviderSmokeError(
                "\(providerTitle) RSVP probe response must be accept, maybe, or decline."
            )
        }
        return LiveRSVPProbeInput(
            calendarID: calendarID,
            eventID: eventID,
            response: response
        )
    }

    private static func calDAVRSVPProbeInput(in environment: [String: String]) throws -> LiveCalDAVRSVPProbeInput? {
        let objectURLString = value("WC_LIVE_CALDAV_RSVP_OBJECT_URL", in: environment)
        let responseText = value("WC_LIVE_CALDAV_RSVP_RESPONSE", in: environment)
        let configuredCount = [objectURLString, responseText].compactMap { $0 }.count
        guard configuredCount > 0 else { return nil }
        guard let objectURLString, let responseText else {
            throw LiveProviderSmokeError(
                "CalDAV RSVP probe needs WC_LIVE_CALDAV_RSVP_OBJECT_URL and WC_LIVE_CALDAV_RSVP_RESPONSE."
            )
        }
        guard URL(string: objectURLString) != nil else {
            throw LiveProviderSmokeError("CalDAV RSVP object URL is invalid.")
        }
        guard let response = CalendarEventResponse(liveRSVPValue: responseText) else {
            throw LiveProviderSmokeError("CalDAV RSVP probe response must be accept, maybe, or decline.")
        }
        return LiveCalDAVRSVPProbeInput(
            objectURLString: objectURLString,
            response: response
        )
    }

    private static func liveOAuthInput(
        service: OAuthServiceKind,
        accessTokenKey: String,
        clientIDKey: String,
        refreshTokenKey: String,
        tenantKey: String?,
        in environment: [String: String]
    ) -> LiveOAuthInput? {
        if let accessToken = value(accessTokenKey, in: environment) {
            return .accessToken(accessToken)
        }
        guard let clientID = value(clientIDKey, in: environment),
              let refreshToken = value(refreshTokenKey, in: environment)
        else {
            return nil
        }
        let tenant = tenantKey.flatMap { value($0, in: environment) }
        return .credential(OAuthCredential(
            accessToken: "",
            refreshToken: refreshToken,
            expiresAt: .distantPast,
            tokenType: "Bearer",
            scope: service.scopes,
            clientID: clientID,
            tenant: service.usesTenant ? service.normalizedTenant(tenant) : nil,
            service: service
        ))
    }

    private static func remoteObjectURLString(
        scheme: String,
        accountID: String,
        calendarID: String,
        eventID: String
    ) -> String {
        "\(scheme)://\(accountID)/\(base64URLEncode(calendarID))/\(base64URLEncode(eventID))"
    }

    private static func base64URLEncode(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func normalizedRemoteObjectURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let absoluteString = URL(string: trimmed)?.absoluteString ?? trimmed
        return absoluteString.hasSuffix("/") ? String(absoluteString.dropLast()) : absoluteString
    }
}

private enum LiveOAuthInput {
    case accessToken(String)
    case credential(OAuthCredential)
}

private struct StoredLiveProviderSources {
    var icsSubscriptions: [CalendarProviderAccount] = []
    var calDAVAccounts: [CalendarProviderAccount] = []
    var googleAccounts: [CalendarProviderAccount] = []
    var microsoftAccounts: [CalendarProviderAccount] = []

    static func load() async -> StoredLiveProviderSources {
        await MainActor.run {
            let userDefaults = UserDefaults(suiteName: CalendarProviderStore.appDefaultsSuiteName) ?? .standard
            let store = CalendarProviderStore(userDefaults: userDefaults)
            let accounts = store.enabledSyncAccounts
            return StoredLiveProviderSources(
                icsSubscriptions: accounts.filter { $0.kind == .icsSubscription },
                calDAVAccounts: accounts.filter { $0.kind == .calDAV },
                googleAccounts: accounts.filter { $0.kind == .googleCalendar },
                microsoftAccounts: accounts.filter { $0.kind == .microsoft365 }
            )
        }
    }
}

private struct LiveRSVPProbeInput {
    var calendarID: String
    var eventID: String
    var response: CalendarEventResponse
}

private struct LiveCalDAVRSVPProbeInput {
    var objectURLString: String
    var response: CalendarEventResponse
}

private extension CalendarEventResponse {
    init?(liveRSVPValue value: String) {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "accept", "accepted", "yes":
            self = .accept
        case "maybe", "tentative":
            self = .maybe
        case "decline", "declined", "no":
            self = .decline
        default:
            return nil
        }
    }
}

private final class LiveOAuthTokenBox {
    private var credential: OAuthCredential
    private let client: OAuthDeviceFlowClient

    init(
        credential: OAuthCredential,
        client: OAuthDeviceFlowClient = OAuthDeviceFlowClient()
    ) {
        self.credential = credential
        self.client = client
    }

    var diagnostic: ProviderOAuthDiagnostic {
        ProviderOAuthDiagnostic(service: credential.service, credential: credential)
    }

    func accessToken(
        account: CalendarProviderAccount,
        service: OAuthServiceKind,
        forceRefresh: Bool
    ) async throws -> String {
        guard service == credential.service else {
            throw LiveProviderSmokeError(
                "\(account.title) requested unexpected OAuth service \(service.rawValue)."
            )
        }

        if forceRefresh || credential.shouldRefresh || credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            credential = try await client.refresh(credential)
        }

        let accessToken = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            throw OAuthDeviceFlowError.missingAccessToken
        }
        return accessToken
    }
}

private extension ProviderDiagnosticReport {
    static func skipped(source: ProviderDiagnosticSource, requiredVariables: [String]) -> ProviderDiagnosticReport {
        ProviderDiagnosticReport(
            source: source,
            status: .skipped,
            message: "set \(requiredVariables.joined(separator: ", "))"
        )
    }
}

private struct LiveProviderSmokeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
