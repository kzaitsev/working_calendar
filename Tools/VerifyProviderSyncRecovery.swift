import Foundation

@main
struct VerifyProviderSyncRecovery {
    @MainActor
    static func main() async throws {
        try verifyProviderRetryAfterParsing()
        try verifyProviderSyncCooldownRecording()
        try verifyProviderPaginationGuards()
        try await verifyProviderHTTPTransportPagination()
        try await verifyProviderHTTPAuthRecovery()
        try await verifyMicrosoftIdentityProfileAuthRecovery()
        try await verifyProviderHTTPMutationErrorMapping()
        try await verifyProviderHTTPPutEventFlow()
        try await verifyProviderHTTPResponseFlow()
        try verifyGoogleSyncFallbackSemantics()
        try verifyGoogleSyncStateTracksImportWindow()
        try verifyMicrosoftSyncFallbackSemantics()
        try verifyMicrosoftInitialSyncUsesCalendarViewDeltaWindow()
        try verifyMicrosoftDeltaStateTracksImportWindow()
        try verifyCalDAVSyncFallbackSemantics()
        try verifyCalDAVSchedulingReplyWriteBackFallbackSemantics()
        try verifyCalDAVIncrementalPayloadDoesNotPruneUnreportedObjects()
        try verifyProviderRangePruneKeepsRecurringSeriesOutsideWindow()
        try verifyProviderReplyOnlyObjectUpdatesCurrentUserResponse()
        try verifyPartialProviderAttendeeRefreshPreservesKnownAttendees()
        try verifyPartialProviderDetachedAttendeeRefreshPreservesKnownAttendees()
        try verifyProtectedProviderResponseSurvivesPendingRefresh()
        try verifySingleOccurrenceResponseSurvivesProviderRefreshAfterRemoteAck()
        try verifyProviderRequestUpdatesExistingUIDAcrossRemoteHref()
        try verifyProviderOrphanOccurrenceRequestUpdatesRecurringSeries()
        try verifyProviderBaseSeriesAbsorbsEarlierOrphanOccurrence()
        try verifyProviderBaseSeriesPrunesEarlierOrphanOccurrenceObject()
        try verifyProviderCancelObjectDeletesByUIDWhenHrefDiffers()
        try verifyProviderCancelObjectKeepsProtectedLocalWrite()
        try verifyProviderOccurrenceCancelUpdatesRecurringSeries()
        try verifyProviderOccurrenceCancelKeepsProtectedDetachedWrite()
        try verifyProviderAllDayOccurrenceCancelUpdatesRecurringSeries()
        try verifyProviderFutureOccurrenceCancelTruncatesRecurringSeries()
        try verifyProviderFutureOccurrenceCancelKeepsProtectedDetachedWrite()
        print("Provider sync recovery invariant passed.")
    }

    private static func verifyProviderRetryAfterParsing() throws {
        let url = try fixtureURL("https://graph.microsoft.com/v1.0/me/events")
        let now = try date("2026-07-01T09:00:00Z")

        let secondsResponse = try httpResponse(url: url, statusCode: 429, retryAfter: "180")
        try expect(ProviderRetryAfter.isRetryAfterStatus(secondsResponse.statusCode),
                   "HTTP 429 should be considered a provider retry-after status")
        try expect(ProviderRetryAfter.seconds(from: secondsResponse, now: now) == 180,
                   "Retry-After delay-seconds should be parsed as seconds")

        let dateResponse = try httpResponse(url: url, statusCode: 503, retryAfter: "Wed, 01 Jul 2026 09:05:00 GMT")
        try expect(ProviderRetryAfter.seconds(from: dateResponse, now: now) == 300,
                   "Retry-After HTTP-date should be converted into seconds from now")

        let cappedResponse = try httpResponse(url: url, statusCode: 429, retryAfter: "200000")
        try expect(ProviderRetryAfter.seconds(from: cappedResponse, now: now) == ProviderRetryAfter.maximumSeconds,
                   "Retry-After should be capped to avoid parking provider outbox forever")
        let negativeResponse = try httpResponse(url: url, statusCode: 429, retryAfter: "-1")
        try expect(ProviderRetryAfter.seconds(from: negativeResponse, now: now) == nil,
                   "Negative Retry-After values should be ignored")

        let googleError: ProviderRetryAfterError = GoogleCalendarClientError.retryAfter(90, url, "Rate limit exceeded")
        let microsoftError: ProviderRetryAfterError = MicrosoftGraphCalendarClientError.retryAfter(120, url, "Too many requests")
        let calDAVError: ProviderRetryAfterError = CalDAVClientError.retryAfter(150, url)
        try expect(googleError.providerRetryAfterSeconds == 90,
                   "Google retry-after errors should expose provider retry delay")
        try expect(microsoftError.providerRetryAfterSeconds == 120,
                   "Microsoft retry-after errors should expose provider retry delay")
        try expect(calDAVError.providerRetryAfterSeconds == 150,
                   "CalDAV retry-after errors should expose provider retry delay")
    }

    @MainActor
    private static func verifyProviderSyncCooldownRecording() throws {
        let store = CalendarProviderStore()
        let account = try store.addICSSubscription(
            title: "Provider sync cooldown fixture",
            urlString: "https://calendar.example.com/cooldown.ics"
        )
        defer { store.delete(account) }

        let url = try fixtureURL("https://www.googleapis.com/calendar/v3/calendars/work/events")
        let now = try date("2026-07-01T09:00:00Z")
        store.recordSync(accountID: account.id, summary: emptySummary(), at: now.addingTimeInterval(-60))
        store.recordSyncError(
            accountID: account.id,
            error: GoogleCalendarClientError.retryAfter(180, url, "Rate limit exceeded"),
            at: now
        )

        guard let coolingDown = store.accounts.first(where: { $0.id == account.id }) else {
            throw ProviderSyncRecoveryInvariantError("Missing provider sync cooldown fixture account")
        }
        try expect(coolingDown.syncNotBefore == now.addingTimeInterval(180),
                   "Retry-After sync errors should store an account-level sync cooldown")
        try expect(coolingDown.automaticSyncReadyDate() == now.addingTimeInterval(180),
                   "Provider cooldown should become the account automatic sync ready date when no stronger boundary exists")
        try expect(coolingDown.automaticSyncReadyDate(globalNotBefore: now.addingTimeInterval(300)) == now.addingTimeInterval(300),
                   "Global sync cadence should be able to push provider automatic sync later than cooldown")
        try expect(!coolingDown.isAutomaticSyncDue(at: now.addingTimeInterval(179)),
                   "Automatic provider sync should pause until the provider retry delay elapses")
        try expect(coolingDown.isAutomaticSyncDue(at: now.addingTimeInterval(180)),
                   "Automatic provider sync should resume when the provider retry delay elapses")

        let encoded = try JSONEncoder().encode(coolingDown)
        let decoded = try JSONDecoder().decode(CalendarProviderAccount.self, from: encoded)
        try expect(decoded.syncNotBefore == coolingDown.syncNotBefore,
                   "Provider sync cooldown should survive account persistence")

        store.recordSync(accountID: account.id, summary: emptySummary(), at: now.addingTimeInterval(181))
        guard let synced = store.accounts.first(where: { $0.id == account.id }) else {
            throw ProviderSyncRecoveryInvariantError("Missing provider sync cooldown fixture account after sync")
        }
        try expect(synced.syncNotBefore == nil,
                   "Successful provider sync should clear stored retry cooldown")

        store.recordICSRefreshInterval(accountID: account.id, seconds: 45 * 60, preservesMissing: false, at: now.addingTimeInterval(182))
        guard let subscriptionTTL = store.accounts.first(where: { $0.id == account.id }) else {
            throw ProviderSyncRecoveryInvariantError("Missing provider sync cooldown fixture account after TTL recording")
        }
        try expect(subscriptionTTL.automaticSyncReadyDate(globalNotBefore: now.addingTimeInterval(300)) == now.addingTimeInterval(181 + 45 * 60),
                   "ICS feed TTL should push automatic sync later than the global cadence")
    }

    private static func verifyProviderPaginationGuards() throws {
        let googleAccount = CalendarProviderAccount(
            id: "provider-google-pagination",
            kind: .googleCalendar,
            title: "Google Pagination",
            endpointURLString: "https://www.googleapis.com/calendar/v3",
            username: nil,
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: try date("2026-07-01T00:00:00Z"),
            updatedAt: try date("2026-07-01T00:00:00Z")
        )
        let googleClient = GoogleCalendarClient()
        let acceptedGooglePageCount = try googleClient.paginationValidationCountPreview(
            pageTokens: [nil, "page-2", "page-3"],
            account: googleAccount
        )
        try expect(acceptedGooglePageCount == 3,
                   "Google pagination guard should accept a finite sequence of unique page tokens")
        do {
            _ = try googleClient.paginationValidationCountPreview(
                pageTokens: [nil, " repeated-token ", "repeated-token"],
                account: googleAccount
            )
            throw ProviderSyncRecoveryInvariantError("Google pagination guard should reject repeated page tokens")
        } catch GoogleCalendarClientError.paginationLoop(let url) {
            try expect(url.absoluteString == "https://www.googleapis.com/calendar/v3",
                       "Google pagination loop errors should point at the provider endpoint")
        }
        do {
            let tooManyTokens: [String?] = (0...10_000).map { Optional(String($0)) }
            _ = try googleClient.paginationValidationCountPreview(
                pageTokens: tooManyTokens,
                account: googleAccount
            )
            throw ProviderSyncRecoveryInvariantError("Google pagination guard should reject unbounded page sequences")
        } catch GoogleCalendarClientError.paginationLimitExceeded {
        }

        let graphClient = MicrosoftGraphCalendarClient()
        let pageOne = try fixtureURL("https://graph.microsoft.com/v1.0/me/events?$skiptoken=one")
        let pageTwo = try fixtureURL("https://graph.microsoft.com/v1.0/me/events?$skiptoken=two")
        let acceptedGraphPageCount = try graphClient.graphPaginationValidationCountPreview(pageURLs: [pageOne, pageTwo])
        try expect(acceptedGraphPageCount == 2,
                   "Microsoft pagination guard should accept a finite sequence of unique nextLink URLs")
        do {
            _ = try graphClient.graphPaginationValidationCountPreview(pageURLs: [pageOne, pageTwo, pageTwo])
            throw ProviderSyncRecoveryInvariantError("Microsoft pagination guard should reject repeated nextLink URLs")
        } catch MicrosoftGraphCalendarClientError.paginationLoop(let url) {
            try expect(url == pageTwo,
                       "Microsoft pagination loop errors should identify the repeated nextLink URL")
        }
        do {
            let tooManyURLs = try (0...10_000).map {
                try fixtureURL("https://graph.microsoft.com/v1.0/me/events?$skiptoken=\($0)")
            }
            _ = try graphClient.graphPaginationValidationCountPreview(pageURLs: tooManyURLs)
            throw ProviderSyncRecoveryInvariantError("Microsoft pagination guard should reject unbounded nextLink sequences")
        } catch MicrosoftGraphCalendarClientError.paginationLimitExceeded {
        }
    }

    private static func verifyProviderHTTPTransportPagination() async throws {
        let start = try date("2026-07-01T00:00:00Z")
        let end = try date("2026-08-01T00:00:00Z")

        let googleAccount = CalendarProviderAccount(
            id: "provider-google-http-pagination",
            kind: .googleCalendar,
            title: "Google HTTP Pagination",
            endpointURLString: "https://www.googleapis.com/calendar/v3",
            username: nil,
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: start,
            updatedAt: start
        )
        let googleTransport = ProviderHTTPFixtureTransport(responses: [
            .json("""
            {
              "items": [
                {
                  "id": "primary",
                  "summary": "Primary",
                  "backgroundColor": "#0A84FF",
                  "accessRole": "owner",
                  "primary": true
                }
              ],
              "nextPageToken": "calendar-page-2"
            }
            """),
            .json("""
            {
              "items": [
                {
                  "id": "team",
                  "summary": "Team",
                  "backgroundColor": "#30D158",
                  "accessRole": "reader"
                }
              ]
            }
            """),
            .json("""
            {
              "items": [
                {
                  "id": "event-page-1",
                  "etag": "\\"etag-page-1\\"",
                  "status": "confirmed",
                  "summary": "Page one event",
                  "iCalUID": "event-page-1@example.com",
                  "updated": "2026-07-02T09:00:00Z",
                  "start": { "dateTime": "2026-07-02T09:00:00Z" },
                  "end": { "dateTime": "2026-07-02T09:30:00Z" }
                }
              ],
              "nextPageToken": "event-page-2"
            }
            """),
            .json("""
            {
              "items": [
                {
                  "id": "event-page-2",
                  "etag": "\\"etag-page-2\\"",
                  "status": "confirmed",
                  "summary": "Page two event",
                  "iCalUID": "event-page-2@example.com",
                  "updated": "2026-07-03T09:00:00Z",
                  "start": { "dateTime": "2026-07-03T09:00:00Z" },
                  "end": { "dateTime": "2026-07-03T09:30:00Z" }
                }
              ],
              "nextSyncToken": "primary-sync-token"
            }
            """),
            .json("""
            {
              "items": [],
              "nextSyncToken": "team-sync-token"
            }
            """)
        ])
        let googleClient = GoogleCalendarClient(
            transport: googleTransport,
            accessTokenProvider: { _, service, forceRefresh in
                try expect(service == .googleCalendar, "Google provider token lookup should request the Google OAuth service")
                try expect(forceRefresh == false, "Successful Google fixture fetch should not force-refresh the access token")
                return "fixture-google-token"
            }
        )
        let googlePayloads = try await googleClient.fetchCalendarPayloads(
            account: googleAccount,
            startDate: start,
            endDate: end
        )
        try expect(googlePayloads.count == 2,
                   "Google paginated HTTP fixture should import both calendars from calendarList pages")
        guard let primaryPayload = googlePayloads.first(where: { $0.calendar.id == "primary" }) else {
            throw ProviderSyncRecoveryInvariantError("Missing primary Google payload")
        }
        try expect(primaryPayload.events.map(\.id) == ["event-page-1", "event-page-2"],
                   "Google paginated HTTP fixture should aggregate events across event pages")
        try expect(primaryPayload.syncToken == "primary-sync-token",
                   "Google paginated HTTP fixture should keep the final nextSyncToken")
        try expect(googleTransport.requests.count == 5,
                   "Google paginated HTTP fixture should issue two calendar pages and three event pages")
        try expect(googleTransport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-google-token" },
                   "Google provider transport should receive authorized requests")
        try expect(googleTransport.requests.contains { queryItems(for: $0)["pageToken"] == "calendar-page-2" },
                   "Google provider transport should request the second calendarList page")
        try expect(googleTransport.requests.contains { queryItems(for: $0)["pageToken"] == "event-page-2" },
                   "Google provider transport should request the second events page")

        let graphAccount = CalendarProviderAccount(
            id: "provider-graph-http-pagination",
            kind: .microsoft365,
            title: "Graph HTTP Pagination",
            endpointURLString: "https://graph.microsoft.com/v1.0",
            username: nil,
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: start,
            updatedAt: start
        )
        let graphTransport = ProviderHTTPFixtureTransport(responses: [
            .json("""
            {
              "value": [
                {
                  "id": "work",
                  "name": "Work",
                  "color": "auto",
                  "canEdit": true
                }
              ],
              "@odata.nextLink": "https://graph.microsoft.com/v1.0/me/calendars?$skiptoken=calendar-page-2"
            }
            """),
            .json("""
            {
              "value": []
            }
            """),
            .json("""
            {
              "value": [],
              "@odata.nextLink": "https://graph.microsoft.com/v1.0/me/calendars/work/calendarView/delta?$skiptoken=event-page-2"
            }
            """),
            .json("""
            {
              "value": [],
              "@odata.deltaLink": "https://graph.microsoft.com/v1.0/me/calendars/work/calendarView/delta?$deltatoken=final"
            }
            """),
            .json("""
            {
              "value": []
            }
            """)
        ])
        let graphClient = MicrosoftGraphCalendarClient(
            transport: graphTransport,
            accessTokenProvider: { _, service, forceRefresh in
                try expect(service == .microsoft365, "Microsoft provider token lookup should request the Microsoft OAuth service")
                try expect(forceRefresh == false, "Successful Microsoft fixture fetch should not force-refresh the access token")
                return "fixture-graph-token"
            }
        )
        let graphPayloads = try await graphClient.fetchCalendarPayloads(
            account: graphAccount,
            startDate: start,
            endDate: end
        )
        let graphPayload = try requireOnly(graphPayloads, context: "Microsoft paginated HTTP fixture")
        try expect(graphPayload.calendar.id == "work",
                   "Microsoft paginated HTTP fixture should import the calendar from the first calendars page")
        try expect(graphPayload.events.isEmpty,
                   "Microsoft paginated HTTP fixture should keep an empty event set without inventing events")
        try expect(graphPayload.deltaLink == "https://graph.microsoft.com/v1.0/me/calendars/work/calendarView/delta?$deltatoken=final",
                   "Microsoft paginated HTTP fixture should keep the final deltaLink after nextLink traversal")
        try expect(graphTransport.requests.count == 5,
                   "Microsoft paginated HTTP fixture should issue two calendar pages, two delta pages, and one calendarView scan")
        try expect(graphTransport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-graph-token" },
                   "Microsoft provider transport should receive authorized requests")
        try expect(graphTransport.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Prefer") == "IdType=\"ImmutableId\", outlook.timezone=\"UTC\", outlook.body-content-type=\"text\""
        }, "Microsoft provider transport should preserve Graph Prefer headers")
        try expect(graphTransport.requests.contains { $0.url?.absoluteString.contains("$skiptoken=calendar-page-2") == true },
                   "Microsoft provider transport should follow paginated calendars nextLink URLs")
        try expect(graphTransport.requests.contains { $0.url?.absoluteString.contains("$skiptoken=event-page-2") == true },
                   "Microsoft provider transport should follow paginated delta nextLink URLs")
    }

    private static func verifyProviderHTTPAuthRecovery() async throws {
        let start = try date("2026-07-01T00:00:00Z")
        let end = try date("2026-08-01T00:00:00Z")

        let googleAccount = CalendarProviderAccount(
            id: "provider-google-http-auth-recovery",
            kind: .googleCalendar,
            title: "Google HTTP Auth Recovery",
            endpointURLString: "https://www.googleapis.com/calendar/v3",
            username: nil,
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: start,
            updatedAt: start
        )
        let googleTransport = ProviderHTTPFixtureTransport(responses: [
            .json(#"{ "error": { "message": "Invalid Credentials" } }"#, statusCode: 401),
            .json("""
            {
              "items": [
                {
                  "id": "primary",
                  "summary": "Primary",
                  "backgroundColor": "#0A84FF",
                  "accessRole": "owner",
                  "primary": true
                }
              ]
            }
            """),
            .json("""
            {
              "items": [],
              "nextSyncToken": "google-auth-recovery-sync-token"
            }
            """)
        ])
        var googleForceRefreshFlags: [Bool] = []
        var googleDidForceRefresh = false
        let googleClient = GoogleCalendarClient(
            transport: googleTransport,
            accessTokenProvider: { _, service, forceRefresh in
                try expect(service == .googleCalendar, "Google auth recovery should request the Google OAuth service")
                googleForceRefreshFlags.append(forceRefresh)
                if forceRefresh {
                    googleDidForceRefresh = true
                    return "fresh-google-token"
                }
                return googleDidForceRefresh ? "fresh-google-token" : "stale-google-token"
            }
        )
        let googlePayloads = try await googleClient.fetchCalendarPayloads(
            account: googleAccount,
            startDate: start,
            endDate: end
        )
        let googlePayload = try requireOnly(googlePayloads, context: "Google auth recovery payload")
        try expect(googlePayload.syncToken == "google-auth-recovery-sync-token",
                   "Google auth recovery should continue the sync after refreshing credentials")
        try expect(googleForceRefreshFlags == [false, true, false],
                   "Google auth recovery should force-refresh exactly once after the first 401")
        try expect(
            googleTransport.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
                "Bearer stale-google-token",
                "Bearer fresh-google-token",
                "Bearer fresh-google-token"
            ],
            "Google auth recovery should retry the failed request and keep using the refreshed token"
        )
        try expect(googleTransport.requests.count == 3,
                   "Google auth recovery should retry the failed calendarList request once before continuing")

        let graphAccount = CalendarProviderAccount(
            id: "provider-graph-http-auth-recovery",
            kind: .microsoft365,
            title: "Graph HTTP Auth Recovery",
            endpointURLString: "https://graph.microsoft.com/v1.0",
            username: nil,
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: start,
            updatedAt: start
        )
        let graphTransport = ProviderHTTPFixtureTransport(responses: [
            .json(#"{ "error": { "message": "InvalidAuthenticationToken" } }"#, statusCode: 401),
            .json("""
            {
              "value": [
                {
                  "id": "work",
                  "name": "Work",
                  "color": "auto",
                  "canEdit": true
                }
              ]
            }
            """),
            .json("""
            {
              "value": [],
              "@odata.deltaLink": "https://graph.microsoft.com/v1.0/me/calendars/work/calendarView/delta?$deltatoken=auth-recovery"
            }
            """),
            .json("""
            {
              "value": []
            }
            """)
        ])
        var graphForceRefreshFlags: [Bool] = []
        var graphDidForceRefresh = false
        let graphClient = MicrosoftGraphCalendarClient(
            transport: graphTransport,
            accessTokenProvider: { _, service, forceRefresh in
                try expect(service == .microsoft365, "Microsoft auth recovery should request the Microsoft OAuth service")
                graphForceRefreshFlags.append(forceRefresh)
                if forceRefresh {
                    graphDidForceRefresh = true
                    return "fresh-graph-token"
                }
                return graphDidForceRefresh ? "fresh-graph-token" : "stale-graph-token"
            }
        )
        let graphPayloads = try await graphClient.fetchCalendarPayloads(
            account: graphAccount,
            startDate: start,
            endDate: end
        )
        let graphPayload = try requireOnly(graphPayloads, context: "Microsoft auth recovery payload")
        try expect(graphPayload.deltaLink == "https://graph.microsoft.com/v1.0/me/calendars/work/calendarView/delta?$deltatoken=auth-recovery",
                   "Microsoft auth recovery should continue the sync after refreshing credentials")
        try expect(graphForceRefreshFlags == [false, true, false, false],
                   "Microsoft auth recovery should force-refresh exactly once after the first 401")
        try expect(
            graphTransport.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
                "Bearer stale-graph-token",
                "Bearer fresh-graph-token",
                "Bearer fresh-graph-token",
                "Bearer fresh-graph-token"
            ],
            "Microsoft auth recovery should retry the failed request and keep using the refreshed token"
        )
        try expect(graphTransport.requests.count == 4,
                   "Microsoft auth recovery should retry the failed calendars request once before continuing")
    }

    private static func verifyMicrosoftIdentityProfileAuthRecovery() async throws {
        let now = try date("2026-07-01T09:00:00Z")
        let account = CalendarProviderAccount(
            id: "provider-graph-identity-auth-recovery",
            kind: .microsoft365,
            title: "Graph Identity Auth Recovery",
            endpointURLString: "https://graph.microsoft.com/v1.0",
            username: nil,
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: now,
            updatedAt: now
        )
        let transport = ProviderHTTPFixtureTransport(responses: [
            .json(#"{ "error": { "message": "InvalidAuthenticationToken" } }"#, statusCode: 401),
            .json("""
            {
              "mail": "Me@Example.com",
              "userPrincipalName": "me@example.com",
              "otherMails": ["Alias@Example.com", "mailto:ME%2Bcalendar%40example.com?subject=calendar"],
              "proxyAddresses": ["SMTP:Me@Example.com", "smtp:Second.Alias@Example.com"]
            }
            """)
        ])
        var forceRefreshFlags: [Bool] = []
        var didForceRefresh = false
        let client = MicrosoftGraphCalendarClient(
            transport: transport,
            accessTokenProvider: { _, service, forceRefresh in
                try expect(service == .microsoft365, "Microsoft identity lookup should request the Microsoft OAuth service")
                forceRefreshFlags.append(forceRefresh)
                if forceRefresh {
                    didForceRefresh = true
                    return "fresh-identity-token"
                }
                return didForceRefresh ? "fresh-identity-token" : "stale-identity-token"
            }
        )

        let identityEmails = try await client.fetchAccountIdentityEmails(account: account)
        try expect(identityEmails == [
            "me@example.com",
            "alias@example.com",
            "me+calendar@example.com",
            "second.alias@example.com"
        ], "Microsoft profile identity lookup should normalize mail, UPN, aliases, proxy addresses, and duplicates")
        try expect(forceRefreshFlags == [false, true],
                   "Microsoft profile identity lookup should force-refresh exactly once after a stale token")
        try expect(
            transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
                "Bearer stale-identity-token",
                "Bearer fresh-identity-token"
            ],
            "Microsoft profile identity lookup should retry with the refreshed token"
        )
        try expect(transport.requests.allSatisfy { $0.url?.path == "/v1.0/me" },
                   "Microsoft profile identity lookup should target the Graph /me endpoint")
        try expect(transport.requests.allSatisfy {
            queryItems(for: $0)["$select"] == "mail,userPrincipalName,otherMails,proxyAddresses"
        }, "Microsoft profile identity lookup should request all identity alias fields")
    }

    private static func verifyProviderHTTPMutationErrorMapping() async throws {
        let start = try date("2026-07-01T00:00:00Z")
        let googleAccount = CalendarProviderAccount(
            id: "provider-google-http-mutation-errors",
            kind: .googleCalendar,
            title: "Google HTTP Mutation Errors",
            endpointURLString: "https://www.googleapis.com/calendar/v3",
            username: nil,
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: start,
            updatedAt: start
        )
        let googleRemoteURL = providerRemoteObjectURL(
            scheme: "google",
            accountID: googleAccount.id,
            calendarID: "primary",
            eventID: "event-delete"
        )
        let googleGoneTransport = ProviderHTTPFixtureTransport(responses: [
            .json(#"{ "error": { "message": "Gone" } }"#, statusCode: 410)
        ])
        let googleGoneClient = GoogleCalendarClient(
            transport: googleGoneTransport,
            accessTokenProvider: fixedAccessTokenProvider(token: "google-token", service: .googleCalendar)
        )
        try await googleGoneClient.deleteEvent(
            account: googleAccount,
            remoteObjectURLString: googleRemoteURL,
            remoteETag: "\"gone-etag\""
        )
        try expect(googleGoneTransport.requests.first?.httpMethod == "DELETE",
                   "Google delete gone fixture should exercise the DELETE mutation path")
        try expect(googleGoneTransport.requests.first?.value(forHTTPHeaderField: "If-Match") == "\"gone-etag\"",
                   "Google delete gone fixture should send the remote ETag precondition")

        let googleConflictTransport = ProviderHTTPFixtureTransport(responses: [
            .json(#"{ "error": { "message": "Precondition failed" } }"#, statusCode: 412)
        ])
        let googleConflictClient = GoogleCalendarClient(
            transport: googleConflictTransport,
            accessTokenProvider: fixedAccessTokenProvider(token: "google-token", service: .googleCalendar)
        )
        do {
            try await googleConflictClient.deleteEvent(
                account: googleAccount,
                remoteObjectURLString: googleRemoteURL,
                remoteETag: "\"conflict-etag\""
            )
            throw ProviderSyncRecoveryInvariantError("Google DELETE 412 should surface as a remote conflict")
        } catch GoogleCalendarClientError.remoteConflict(let url) {
            try expect(url.absoluteString.contains("/calendars/primary/events/event-delete"),
                       "Google DELETE 412 should report the failed provider event URL")
        }

        let googleRetryTransport = ProviderHTTPFixtureTransport(responses: [
            .json(#"{ "error": { "message": "Rate limit" } }"#, statusCode: 429, headers: ["Retry-After": "120"])
        ])
        let googleRetryClient = GoogleCalendarClient(
            transport: googleRetryTransport,
            accessTokenProvider: fixedAccessTokenProvider(token: "google-token", service: .googleCalendar)
        )
        do {
            try await googleRetryClient.deleteEvent(
                account: googleAccount,
                remoteObjectURLString: googleRemoteURL,
                remoteETag: "\"retry-etag\""
            )
            throw ProviderSyncRecoveryInvariantError("Google DELETE 429 should surface provider Retry-After")
        } catch GoogleCalendarClientError.retryAfter(let seconds, let url, let message) {
            try expect(seconds == 120, "Google DELETE 429 should preserve Retry-After seconds")
            try expect(url.absoluteString.contains("/calendars/primary/events/event-delete"),
                       "Google DELETE 429 should report the failed provider event URL")
            try expect(message == "Rate limit", "Google DELETE 429 should decode the provider error message")
        }

        let graphAccount = CalendarProviderAccount(
            id: "provider-graph-http-mutation-errors",
            kind: .microsoft365,
            title: "Graph HTTP Mutation Errors",
            endpointURLString: "https://graph.microsoft.com/v1.0",
            username: nil,
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: start,
            updatedAt: start
        )
        let graphRemoteURL = providerRemoteObjectURL(
            scheme: "microsoft365",
            accountID: graphAccount.id,
            calendarID: "work",
            eventID: "event-delete"
        )
        let graphGoneTransport = ProviderHTTPFixtureTransport(responses: [
            .json(#"{ "error": { "message": "Gone" } }"#, statusCode: 404)
        ])
        let graphGoneClient = MicrosoftGraphCalendarClient(
            transport: graphGoneTransport,
            accessTokenProvider: fixedAccessTokenProvider(token: "graph-token", service: .microsoft365)
        )
        try await graphGoneClient.deleteEvent(
            account: graphAccount,
            remoteObjectURLString: graphRemoteURL,
            remoteETag: "gone-change-key"
        )
        try expect(graphGoneTransport.requests.first?.httpMethod == "DELETE",
                   "Microsoft delete gone fixture should exercise the DELETE mutation path")
        try expect(graphGoneTransport.requests.first?.value(forHTTPHeaderField: "If-Match") == "gone-change-key",
                   "Microsoft delete gone fixture should send the remote changeKey precondition")

        let graphConflictTransport = ProviderHTTPFixtureTransport(responses: [
            .json(#"{ "error": { "message": "Precondition failed" } }"#, statusCode: 412)
        ])
        let graphConflictClient = MicrosoftGraphCalendarClient(
            transport: graphConflictTransport,
            accessTokenProvider: fixedAccessTokenProvider(token: "graph-token", service: .microsoft365)
        )
        do {
            try await graphConflictClient.deleteEvent(
                account: graphAccount,
                remoteObjectURLString: graphRemoteURL,
                remoteETag: "conflict-change-key"
            )
            throw ProviderSyncRecoveryInvariantError("Microsoft DELETE 412 should surface as a remote conflict")
        } catch MicrosoftGraphCalendarClientError.remoteConflict(let url) {
            try expect(url.absoluteString.contains("/calendars/work/events/event-delete"),
                       "Microsoft DELETE 412 should report the failed Graph event URL")
        }

        let graphRetryTransport = ProviderHTTPFixtureTransport(responses: [
            .json(#"{ "error": { "message": "Too many requests" } }"#, statusCode: 503, headers: ["Retry-After": "90"])
        ])
        let graphRetryClient = MicrosoftGraphCalendarClient(
            transport: graphRetryTransport,
            accessTokenProvider: fixedAccessTokenProvider(token: "graph-token", service: .microsoft365)
        )
        do {
            try await graphRetryClient.deleteEvent(
                account: graphAccount,
                remoteObjectURLString: graphRemoteURL,
                remoteETag: "retry-change-key"
            )
            throw ProviderSyncRecoveryInvariantError("Microsoft DELETE 503 should surface provider Retry-After")
        } catch MicrosoftGraphCalendarClientError.retryAfter(let seconds, let url, let message) {
            try expect(seconds == 90, "Microsoft DELETE 503 should preserve Retry-After seconds")
            try expect(url.absoluteString.contains("/calendars/work/events/event-delete"),
                       "Microsoft DELETE 503 should report the failed Graph event URL")
            try expect(message == "Too many requests",
                       "Microsoft DELETE 503 should decode the provider error message")
        }
    }

    private static func verifyProviderHTTPPutEventFlow() async throws {
        let start = try date("2026-07-01T10:00:00Z")
        let end = try date("2026-07-01T10:30:00Z")

        let googleAccount = CalendarProviderAccount(
            id: "provider-google-http-put",
            kind: .googleCalendar,
            title: "Google HTTP Put",
            endpointURLString: "https://www.googleapis.com/calendar/v3",
            username: nil,
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: start,
            updatedAt: start
        )
        let googleTransport = ProviderHTTPFixtureTransport(responses: [
            .json(#"{ "error": { "message": "Already exists" } }"#, statusCode: 409),
            .json(#"{ "id": "abcde123", "etag": "\"existing-etag\"" }"#)
        ])
        let googleClient = GoogleCalendarClient(
            transport: googleTransport,
            accessTokenProvider: fixedAccessTokenProvider(token: "google-put-token", service: .googleCalendar)
        )
        let googleCalendar = LocalCalendar(
            id: googleClient.localCalendarID(for: googleAccount, googleCalendarID: "primary"),
            title: "Primary",
            colorHex: "#0A84FF"
        )
        let googleEvent = providerWriteEvent(
            id: "abcde123",
            calendarID: googleCalendar.id,
            title: "Google put fixture",
            start: start,
            end: end
        )
        let googleWrite = try await googleClient.putEvent(
            googleEvent,
            localCalendar: googleCalendar,
            account: googleAccount
        )
        try expect(googleWrite.remoteObjectURLString == providerRemoteObjectURL(
            scheme: "google",
            accountID: googleAccount.id,
            calendarID: "primary",
            eventID: "abcde123"
        ), "Google put-event create conflict should bind to the existing remote event URL")
        try expect(googleWrite.remoteETag == "\"existing-etag\"",
                   "Google put-event create conflict should preserve the existing remote ETag")
        try expect(googleTransport.requests.map(\.httpMethod) == ["POST", "GET"],
                   "Google put-event create conflict should POST then fetch the existing event")
        try expect(googleTransport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer google-put-token" },
                   "Google put-event requests should be authorized")
        try expect(googleTransport.requests[0].url?.path.contains("/calendars/primary/events") == true,
                   "Google put-event create should target the provider calendar events collection")
        try expect(googleTransport.requests[1].url?.path.contains("/calendars/primary/events/abcde123") == true,
                   "Google put-event conflict fallback should fetch the deterministic event id")
        try expect(queryItems(for: googleTransport.requests[0])["conferenceDataVersion"] == "1",
                   "Google put-event create should request conference data write support")
        let googleBody = try jsonObject(from: googleTransport.requests[0])
        try expect(googleBody["id"] as? String == "abcde123",
                   "Google put-event create should send the deterministic provider event id")
        try expect(googleBody["summary"] as? String == "Google put fixture",
                   "Google put-event create should send the local event title")

        let graphAccount = CalendarProviderAccount(
            id: "provider-graph-http-put",
            kind: .microsoft365,
            title: "Graph HTTP Put",
            endpointURLString: "https://graph.microsoft.com/v1.0",
            username: nil,
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: start,
            updatedAt: start
        )
        let graphTransport = ProviderHTTPFixtureTransport(responses: [
            .json(#"{ "id": "graph-created", "changeKey": "created-change-key" }"#),
            .json(#"{ "error": { "message": "Extension missing" } }"#, statusCode: 404)
        ])
        let graphClient = MicrosoftGraphCalendarClient(
            transport: graphTransport,
            accessTokenProvider: fixedAccessTokenProvider(token: "graph-put-token", service: .microsoft365)
        )
        let graphCalendar = LocalCalendar(
            id: graphClient.localCalendarID(for: graphAccount, graphCalendarID: "work"),
            title: "Work",
            colorHex: "#30D158"
        )
        let graphEvent = providerWriteEvent(
            id: "graph-put-event",
            calendarID: graphCalendar.id,
            title: "Microsoft put fixture",
            start: start,
            end: end
        )
        let graphWrite = try await graphClient.putEvent(
            graphEvent,
            localCalendar: graphCalendar,
            account: graphAccount
        )
        try expect(graphWrite.remoteObjectURLString == providerRemoteObjectURL(
            scheme: "microsoft365",
            accountID: graphAccount.id,
            calendarID: "work",
            eventID: "graph-created"
        ), "Microsoft put-event create should bind to the created remote event URL")
        try expect(graphWrite.remoteETag == "created-change-key",
                   "Microsoft put-event create should preserve the Graph changeKey")
        try expect(graphTransport.requests.map(\.httpMethod) == ["POST", "PATCH"],
                   "Microsoft put-event create should POST the event then attempt the Working Calendar open extension PATCH")
        try expect(graphTransport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer graph-put-token" },
                   "Microsoft put-event requests should be authorized")
        try expect(graphTransport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Prefer")?.contains("IdType=\"ImmutableId\"") == true },
                   "Microsoft put-event requests should ask Graph for immutable ids")
        try expect(graphTransport.requests[0].url?.path.contains("/me/calendars/work/events") == true,
                   "Microsoft put-event create should target the provider calendar events collection")
        try expect(graphTransport.requests[1].url?.path.contains("/me/calendars/work/events/graph-created/extensions/dev.codex.workingCalendar") == true,
                   "Microsoft put-event create should attempt the Working Calendar open extension path")
        let graphBody = try jsonObject(from: graphTransport.requests[0])
        try expect(graphBody["subject"] as? String == "Microsoft put fixture",
                   "Microsoft put-event create should send the local event title")
        let extensionBody = try jsonObject(from: graphTransport.requests[1])
        try expect(extensionBody["extensionName"] as? String == "dev.codex.workingCalendar",
                   "Microsoft open extension PATCH should identify the Working Calendar extension")
        try expect(extensionBody["relatedEventsJSON"] as? String == "[]",
                   "Microsoft open extension PATCH should encode empty related-events metadata")

        let googleUpdateTransport = ProviderHTTPFixtureTransport(responses: [
            .json(#"{ "id": "google-existing", "etag": "\"google-updated-etag\"" }"#)
        ])
        let googleUpdateClient = GoogleCalendarClient(
            transport: googleUpdateTransport,
            accessTokenProvider: fixedAccessTokenProvider(token: "google-update-token", service: .googleCalendar)
        )
        var googleUpdateEvent = providerWriteEvent(
            id: "google-local-update",
            calendarID: googleCalendar.id,
            title: "Google update fixture",
            start: start,
            end: end
        )
        googleUpdateEvent.remoteObjectURLString = providerRemoteObjectURL(
            scheme: "google",
            accountID: googleAccount.id,
            calendarID: "primary",
            eventID: "google-existing"
        )
        googleUpdateEvent.remoteETag = "\"google-existing-etag\""
        googleUpdateEvent.relatedEvents = [
            LocalEventRelationship(relationType: "PARENT", externalUID: "parent-google-update@example.com")
        ]
        googleUpdateEvent.geoCoordinate = LocalEventGeoCoordinate(latitude: 35.1855659, longitude: 33.3822764)
        let googleUpdateWrite = try await googleUpdateClient.putEvent(
            googleUpdateEvent,
            localCalendar: googleCalendar,
            account: googleAccount
        )
        try expect(googleUpdateWrite.remoteObjectURLString == googleUpdateEvent.remoteObjectURLString,
                   "Google put-event update should keep the existing remote event URL")
        try expect(googleUpdateWrite.remoteETag == "\"google-updated-etag\"",
                   "Google put-event update should keep the provider response ETag")
        try expect(googleUpdateTransport.requests.map(\.httpMethod) == ["PATCH"],
                   "Google put-event update should use a single PATCH request")
        try expect(googleUpdateTransport.requests[0].value(forHTTPHeaderField: "If-Match") == "\"google-existing-etag\"",
                   "Google put-event update should send the remote ETag precondition")
        try expect(googleUpdateTransport.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer google-update-token",
                   "Google put-event update should be authorized")
        try expect(googleUpdateTransport.requests[0].url?.path.contains("/calendars/primary/events/google-existing") == true,
                   "Google put-event update should target the existing provider event")
        let googleUpdateBody = try jsonObject(from: googleUpdateTransport.requests[0])
        try expect(googleUpdateBody["summary"] as? String == "Google update fixture",
                   "Google put-event update should send the updated title")
        let googleUpdateExtendedProperties = try jsonObject(named: "extendedProperties", in: googleUpdateBody)
        let googleUpdatePrivateProperties = try jsonObject(named: "private", in: googleUpdateExtendedProperties)
        let googleUpdateRelationships = try decodedRelationships(
            from: googleUpdatePrivateProperties,
            key: "workingCalendar.relatedEvents"
        )
        try expect(googleUpdateRelationships == googleUpdateEvent.relatedEvents,
                   "Google put-event update should preserve structured relationship metadata")
        let googleUpdateGeo = try decodedGeoCoordinate(
            from: googleUpdatePrivateProperties,
            key: "workingCalendar.geoCoordinate"
        )
        try expect(googleUpdateGeo == googleUpdateEvent.geoCoordinate,
                   "Google put-event update should preserve structured GEO metadata")

        let graphUpdateTransport = ProviderHTTPFixtureTransport(responses: [
            .json(#"{ "id": "graph-existing", "changeKey": "graph-updated-change-key" }"#),
            .json(#"{ "error": { "message": "Extension missing" } }"#, statusCode: 404),
            .json(#"{ }"#, statusCode: 201)
        ])
        let graphUpdateClient = MicrosoftGraphCalendarClient(
            transport: graphUpdateTransport,
            accessTokenProvider: fixedAccessTokenProvider(token: "graph-update-token", service: .microsoft365)
        )
        var graphUpdateEvent = providerWriteEvent(
            id: "graph-local-update",
            calendarID: graphCalendar.id,
            title: "Microsoft update fixture",
            start: start,
            end: end
        )
        graphUpdateEvent.remoteObjectURLString = providerRemoteObjectURL(
            scheme: "microsoft365",
            accountID: graphAccount.id,
            calendarID: "work",
            eventID: "graph-existing"
        )
        graphUpdateEvent.remoteETag = "graph-existing-change-key"
        graphUpdateEvent.relatedEvents = [
            LocalEventRelationship(relationType: "PARENT", externalUID: "parent-graph-update@example.com")
        ]
        graphUpdateEvent.geoCoordinate = LocalEventGeoCoordinate(latitude: 35.1855659, longitude: 33.3822764)
        let graphUpdateWrite = try await graphUpdateClient.putEvent(
            graphUpdateEvent,
            localCalendar: graphCalendar,
            account: graphAccount
        )
        try expect(graphUpdateWrite.remoteObjectURLString == graphUpdateEvent.remoteObjectURLString,
                   "Microsoft put-event update should keep the existing remote event URL")
        try expect(graphUpdateWrite.remoteETag == "graph-updated-change-key",
                   "Microsoft put-event update should keep the provider response changeKey")
        try expect(graphUpdateTransport.requests.map(\.httpMethod) == ["PATCH", "PATCH", "POST"],
                   "Microsoft put-event update should PATCH the event, try the extension PATCH, then POST missing local metadata")
        try expect(graphUpdateTransport.requests[0].value(forHTTPHeaderField: "If-Match") == "graph-existing-change-key",
                   "Microsoft put-event update should send the remote changeKey precondition")
        try expect(graphUpdateTransport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer graph-update-token" },
                   "Microsoft put-event update requests should be authorized")
        try expect(graphUpdateTransport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Prefer")?.contains("IdType=\"ImmutableId\"") == true },
                   "Microsoft put-event update requests should ask Graph for immutable ids")
        try expect(graphUpdateTransport.requests[0].url?.path.contains("/me/calendars/work/events/graph-existing") == true,
                   "Microsoft put-event update should target the existing provider event")
        try expect(graphUpdateTransport.requests[1].url?.path.contains("/me/calendars/work/events/graph-existing/extensions/dev.codex.workingCalendar") == true,
                   "Microsoft put-event update should try to patch the Working Calendar open extension")
        try expect(graphUpdateTransport.requests[2].url?.path.contains("/me/calendars/work/events/graph-existing/extensions") == true,
                   "Microsoft put-event update should create a missing Working Calendar open extension when local metadata exists")
        let graphUpdateBody = try jsonObject(from: graphUpdateTransport.requests[0])
        try expect(graphUpdateBody["subject"] as? String == "Microsoft update fixture",
                   "Microsoft put-event update should send the updated title")
        let graphExtensionCreateBody = try jsonObject(from: graphUpdateTransport.requests[2])
        try expect(graphExtensionCreateBody["extensionName"] as? String == "dev.codex.workingCalendar",
                   "Microsoft open extension POST should identify the Working Calendar extension")
        let graphUpdateRelationships = try decodedRelationships(
            from: graphExtensionCreateBody,
            key: "relatedEventsJSON"
        )
        try expect(graphUpdateRelationships == graphUpdateEvent.relatedEvents,
                   "Microsoft open extension POST should preserve structured relationship metadata")
        let graphUpdateGeo = try decodedGeoCoordinate(
            from: graphExtensionCreateBody,
            key: "geoCoordinateJSON"
        )
        try expect(graphUpdateGeo == graphUpdateEvent.geoCoordinate,
                   "Microsoft open extension POST should preserve structured GEO metadata")
    }

    private static func verifyProviderHTTPResponseFlow() async throws {
        let occurrenceStart = try date("2026-07-01T10:00:00Z")

        let googleAccount = CalendarProviderAccount(
            id: "provider-google-http-response",
            kind: .googleCalendar,
            title: "Google HTTP Response",
            endpointURLString: "https://www.googleapis.com/calendar/v3",
            username: "me@example.com",
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: occurrenceStart,
            updatedAt: occurrenceStart
        )
        let googleTransport = ProviderHTTPFixtureTransport(responses: [
            .json("""
            {
              "items": [
                {
                  "id": "google-occurrence",
                  "etag": "\\"google-occurrence-before\\"",
                  "status": "confirmed",
                  "summary": "Google occurrence RSVP",
                  "iCalUID": "google-rsvp-series@example.com",
                  "recurringEventId": "google-master",
                  "originalStartTime": { "dateTime": "2026-07-01T10:00:00Z" },
                  "start": { "dateTime": "2026-07-01T10:00:00Z" },
                  "end": { "dateTime": "2026-07-01T10:30:00Z" }
                }
              ]
            }
            """),
            .json("""
            {
              "id": "google-occurrence",
              "etag": "\\"google-occurrence-before\\"",
              "status": "confirmed",
              "summary": "Google occurrence RSVP",
              "iCalUID": "google-rsvp-series@example.com",
              "attendees": [
                {
                  "email": "me@example.com",
                  "displayName": "Me",
                  "responseStatus": "needsAction",
                  "self": true
                },
                {
                  "email": "teammate@example.com",
                  "displayName": "Teammate",
                  "responseStatus": "accepted",
                  "optional": true
                }
              ]
            }
            """),
            .json(#"{ "id": "google-occurrence", "etag": "\"google-occurrence-after\"" }"#)
        ])
        let googleClient = GoogleCalendarClient(
            transport: googleTransport,
            accessTokenProvider: fixedAccessTokenProvider(token: "google-response-token", service: .googleCalendar)
        )
        let googleResponseETag = try await googleClient.respondToEvent(
            account: googleAccount,
            remoteObjectURLString: providerRemoteObjectURL(
                scheme: "google",
                accountID: googleAccount.id,
                calendarID: "primary",
                eventID: "google-master"
            ),
            response: .maybe,
            occurrenceStartDate: occurrenceStart,
            occurrenceIsAllDay: false,
            occurrenceTimeZoneIdentifier: "UTC"
        )
        try expect(googleResponseETag == nil,
                   "Google single-occurrence response should not replace the master ETag")
        try expect(googleTransport.requests.map(\.httpMethod) == ["GET", "GET", "PATCH"],
                   "Google occurrence response should locate the instance, fetch it, then PATCH the attendee response")
        try expect(googleTransport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer google-response-token" },
                   "Google occurrence response requests should be authorized")
        try expect(googleTransport.requests[0].url?.path.contains("/calendars/primary/events/google-master/instances") == true,
                   "Google occurrence response should query the master event instances")
        try expect(queryItems(for: googleTransport.requests[0])["showDeleted"] == "false",
                   "Google occurrence response instance lookup should ignore deleted instances")
        try expect(googleTransport.requests[1].url?.path.contains("/calendars/primary/events/google-occurrence") == true,
                   "Google occurrence response should fetch the matched occurrence before patching attendees")
        try expect(googleTransport.requests[2].url?.path.contains("/calendars/primary/events/google-occurrence") == true,
                   "Google occurrence response should patch the matched occurrence")
        try expect(queryItems(for: googleTransport.requests[2])["sendUpdates"] == "all",
                   "Google occurrence response should notify attendees through sendUpdates=all")
        let googlePatchBody = try jsonObject(from: googleTransport.requests[2])
        try expect(googlePatchBody["attendeesOmitted"] as? Bool == true,
                   "Google response PATCH should preserve partial attendee semantics")
        let googlePatchedAttendees = try jsonArray(named: "attendees", in: googlePatchBody)
        let googleSelfAttendee = try requireOnly(googlePatchedAttendees, context: "Google response patched attendees")
        try expect(googleSelfAttendee["email"] as? String == "me@example.com",
                   "Google response PATCH should target the current user attendee")
        try expect(googleSelfAttendee["responseStatus"] as? String == "tentative",
                   "Google Maybe response should be encoded as tentative")

        let graphAccount = CalendarProviderAccount(
            id: "provider-graph-http-response",
            kind: .microsoft365,
            title: "Graph HTTP Response",
            endpointURLString: "https://graph.microsoft.com/v1.0",
            username: "me@example.com",
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: occurrenceStart,
            updatedAt: occurrenceStart
        )
        let graphTransport = ProviderHTTPFixtureTransport(responses: [
            .json("""
            {
              "value": [
                {
                  "id": "graph-occurrence",
                  "changeKey": "graph-occurrence-before",
                  "subject": "Graph occurrence RSVP",
                  "start": { "dateTime": "2026-07-01T10:00:00", "timeZone": "UTC" },
                  "end": { "dateTime": "2026-07-01T10:30:00", "timeZone": "UTC" },
                  "isAllDay": false,
                  "type": "occurrence",
                  "seriesMasterId": "graph-master",
                  "originalStart": "2026-07-01T10:00:00Z"
                }
              ]
            }
            """),
            .json(#"{ }"#, statusCode: 202)
        ])
        let graphClient = MicrosoftGraphCalendarClient(
            transport: graphTransport,
            accessTokenProvider: fixedAccessTokenProvider(token: "graph-response-token", service: .microsoft365)
        )
        let graphResponseETag = try await graphClient.respondToEvent(
            account: graphAccount,
            remoteObjectURLString: providerRemoteObjectURL(
                scheme: "microsoft365",
                accountID: graphAccount.id,
                calendarID: "work",
                eventID: "graph-master"
            ),
            response: .maybe,
            occurrenceStartDate: occurrenceStart,
            occurrenceIsAllDay: false,
            occurrenceTimeZoneIdentifier: "UTC"
        )
        try expect(graphResponseETag == nil,
                   "Microsoft single-occurrence response should not replace the master changeKey")
        try expect(graphTransport.requests.map(\.httpMethod) == ["GET", "POST"],
                   "Microsoft occurrence response should locate the instance then POST the response action")
        try expect(graphTransport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer graph-response-token" },
                   "Microsoft occurrence response requests should be authorized")
        try expect(graphTransport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Prefer")?.contains("IdType=\"ImmutableId\"") == true },
                   "Microsoft occurrence response requests should ask Graph for immutable ids")
        try expect(graphTransport.requests[0].url?.path.contains("/me/calendars/work/events/graph-master/instances") == true,
                   "Microsoft occurrence response should query the master event instances")
        try expect(graphTransport.requests[1].url?.path.contains("/me/calendars/work/events/graph-occurrence/tentativelyAccept") == true,
                   "Microsoft Maybe response should target the matched occurrence with tentativelyAccept")
        let graphResponseBody = try jsonObject(from: graphTransport.requests[1])
        try expect(graphResponseBody["comment"] as? String == "",
                   "Microsoft response action should send an empty comment")
        try expect(graphResponseBody["sendResponse"] as? Bool == true,
                   "Microsoft response action should send provider attendee notifications")
    }

    private static func verifyGoogleSyncFallbackSemantics() throws {
        let url = try fixtureURL("https://www.googleapis.com/calendar/v3/calendars/work/events")
        try expect(GoogleCalendarClientError.httpStatus(410, url, "Sync token is no longer valid").allowsFullSyncFallback,
                   "Google 410 should fall back to a full sync when an incremental sync token expires")
        try expect(GoogleCalendarClientError.httpStatus(400, url, "Invalid sync token").allowsFullSyncFallback,
                   "Google 400 should fall back to a full sync when an incremental sync token is rejected")
        try expect(!GoogleCalendarClientError.httpStatus(401, url, "Unauthorized").allowsFullSyncFallback,
                   "Google 401 should remain an auth error, not a full sync fallback")
        try expect(!GoogleCalendarClientError.missingRefreshToken.allowsFullSyncFallback,
                   "Google credentials without refresh tokens should require reconnect, not a full sync fallback")
        try expect(GoogleCalendarClientError.missingRefreshToken.localizedDescription.localizedCaseInsensitiveContains("reconnect"),
                   "Google missing refresh token should explain that the account needs reconnecting")
        try expect(!GoogleCalendarClientError.remoteConflict(url).allowsFullSyncFallback,
                   "Google write conflicts should not be treated as sync cursor expiry")
        try expect(!GoogleCalendarClientError.paginationLoop(url).allowsFullSyncFallback,
                   "Google pagination loops should not be hidden by a full sync fallback")
    }

    private static func verifyGoogleSyncStateTracksImportWindow() throws {
        let start = try date("2026-07-01T00:00:00Z")
        let end = try date("2026-08-01T00:00:00Z")
        let state = GoogleCalendarSyncState(
            googleCalendarID: "primary",
            syncToken: "google-sync-token",
            windowStartDate: start,
            windowEndDate: end
        )

        try expect(state.coversWindow(startDate: start, endDate: end),
                   "Google sync state should be reusable for the exact synchronized window")
        try expect(state.coversWindow(startDate: start.addingTimeInterval(24 * 60 * 60), endDate: end),
                   "Google sync state should be reusable for a narrower window it already covers")
        try expect(!state.coversWindow(startDate: start.addingTimeInterval(-1), endDate: end),
                   "Google sync state should not be reused when the desired window starts before the synchronized range")
        try expect(!state.coversWindow(startDate: start, endDate: end.addingTimeInterval(1)),
                   "Google sync state should not be reused when the desired window extends past the synchronized range")
        try expect(!GoogleCalendarSyncState(googleCalendarID: "primary", syncToken: state.syncToken).coversWindow(startDate: start, endDate: end),
                   "Legacy Google sync states without a recorded window should force a full sync")

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(GoogleCalendarSyncState.self, from: encoded)
        try expect(decoded.windowStartDate == start && decoded.windowEndDate == end,
                   "Google sync window should survive account persistence")

        let legacyJSON = """
        {
          "googleCalendarID": "primary",
          "syncToken": "legacy-google-sync-token"
        }
        """
        let legacy = try JSONDecoder().decode(GoogleCalendarSyncState.self, from: Data(legacyJSON.utf8))
        try expect(!legacy.coversWindow(startDate: start, endDate: end),
                   "Decoded legacy Google sync states should not be trusted for window-aware incremental sync")
    }

    private static func verifyMicrosoftSyncFallbackSemantics() throws {
        let url = try fixtureURL("https://graph.microsoft.com/v1.0/me/calendars/work/events/delta")
        try expect(MicrosoftGraphCalendarClientError.httpStatus(410, url, "Delta token expired").allowsFullSyncFallback,
                   "Microsoft 410 should fall back to a full sync when a delta link expires")
        try expect(MicrosoftGraphCalendarClientError.httpStatus(400, url, "Invalid delta token").allowsFullSyncFallback,
                   "Microsoft 400 should fall back to a full sync when a delta link is rejected")
        try expect(!MicrosoftGraphCalendarClientError.httpStatus(401, url, "Unauthorized").allowsFullSyncFallback,
                   "Microsoft 401 should remain an auth error, not a full sync fallback")
        try expect(!MicrosoftGraphCalendarClientError.missingRefreshToken.allowsFullSyncFallback,
                   "Microsoft credentials without refresh tokens should require reconnect, not a full sync fallback")
        try expect(MicrosoftGraphCalendarClientError.missingRefreshToken.localizedDescription.localizedCaseInsensitiveContains("reconnect"),
                   "Microsoft missing refresh token should explain that the account needs reconnecting")
        try expect(!MicrosoftGraphCalendarClientError.remoteConflict(url).allowsFullSyncFallback,
                   "Microsoft write conflicts should not be treated as delta expiry")
        try expect(!MicrosoftGraphCalendarClientError.paginationLimitExceeded(url).allowsFullSyncFallback,
                   "Microsoft pagination limits should not be hidden by a full sync fallback")
    }

    private static func verifyMicrosoftInitialSyncUsesCalendarViewDeltaWindow() throws {
        let account = CalendarProviderAccount(
            id: "provider-microsoft-delta-window",
            kind: .microsoft365,
            title: "Microsoft Delta Window",
            endpointURLString: "https://graph.microsoft.com/v1.0",
            username: nil,
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: try date("2026-07-01T00:00:00Z"),
            updatedAt: try date("2026-07-01T00:00:00Z")
        )

        let url = try MicrosoftGraphCalendarClient().calendarViewDeltaURLPreview(
            account: account,
            calendarID: "work/shared calendar",
            startDate: try date("2026-07-01T00:00:00Z"),
            endDate: try date("2026-08-01T00:00:00Z")
        )
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ProviderSyncRecoveryInvariantError("Could not parse Microsoft calendarView delta URL")
        }
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })

        try expect(
            components.percentEncodedPath == "/v1.0/me/calendars/work%2Fshared%20calendar/calendarView/delta",
            "Microsoft initial sync should target calendarView/delta for a bounded calendar window"
        )
        try expect(query["startDateTime"] == "2026-07-01T00:00:00Z",
                   "Microsoft calendarView delta should include the import window start")
        try expect(query["endDateTime"] == "2026-08-01T00:00:00Z",
                   "Microsoft calendarView delta should include the import window end")
        try expect(query["$top"] == nil,
                   "Microsoft calendarView delta should not rely on events/delta paging query parameters")
        try expect(!url.absoluteString.contains("/events/delta"),
                   "Microsoft initial sync should not fall back to unbounded events/delta")
    }

    private static func verifyMicrosoftDeltaStateTracksImportWindow() throws {
        let start = try date("2026-07-01T00:00:00Z")
        let end = try date("2026-08-01T00:00:00Z")
        let state = MicrosoftGraphSyncState(
            graphCalendarID: "work",
            deltaLink: "https://graph.microsoft.com/v1.0/me/calendars/work/calendarView/delta?$deltatoken=abc",
            windowStartDate: start,
            windowEndDate: end
        )

        try expect(state.coversWindow(startDate: start, endDate: end),
                   "Microsoft delta state should be reusable for the exact synchronized window")
        try expect(state.coversWindow(startDate: start.addingTimeInterval(24 * 60 * 60), endDate: end),
                   "Microsoft delta state should be reusable for a narrower window it already covers")
        try expect(!state.coversWindow(startDate: start.addingTimeInterval(-1), endDate: end),
                   "Microsoft delta state should not be reused when the desired window starts before the synchronized range")
        try expect(!state.coversWindow(startDate: start, endDate: end.addingTimeInterval(1)),
                   "Microsoft delta state should not be reused when the desired window extends past the synchronized range")
        try expect(!MicrosoftGraphSyncState(graphCalendarID: "work", deltaLink: state.deltaLink).coversWindow(startDate: start, endDate: end),
                   "Legacy Microsoft delta states without a recorded window should force a full calendarView sync")

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(MicrosoftGraphSyncState.self, from: encoded)
        try expect(decoded.windowStartDate == start && decoded.windowEndDate == end,
                   "Microsoft delta sync window should survive account persistence")

        let legacyJSON = """
        {
          "graphCalendarID": "work",
          "deltaLink": "https://graph.microsoft.com/v1.0/me/calendars/work/events/delta?$deltatoken=legacy"
        }
        """
        let legacy = try JSONDecoder().decode(MicrosoftGraphSyncState.self, from: Data(legacyJSON.utf8))
        try expect(!legacy.coversWindow(startDate: start, endDate: end),
                   "Decoded legacy Microsoft delta states should not be trusted for window-aware calendarView sync")
    }

    private static func verifyCalDAVSyncFallbackSemantics() throws {
        let url = try fixtureURL("https://caldav.example.com/calendars/work/")
        for status in [400, 403, 405, 409, 501] {
            try expect(CalDAVClientError.httpStatus(status, url).allowsFullSyncFallback,
                       "CalDAV \(status) should fall back to full calendar-query when sync-collection is unavailable or stale")
        }
        try expect(CalDAVClientError.discoveryFailed.allowsFullSyncFallback,
                   "CalDAV discovery retry path should allow fallback across candidate roots")
        try expect(!CalDAVClientError.httpStatus(401, url).allowsFullSyncFallback,
                   "CalDAV 401 should remain a credentials error, not a full sync fallback")
        try expect(!CalDAVClientError.preconditionFailed(url).allowsFullSyncFallback,
                   "CalDAV write precondition failures should not be treated as stale sync cursors")
        try expect(!CalDAVClientError.missingCredentials.allowsFullSyncFallback,
                   "CalDAV missing credentials should not be hidden by full sync fallback")
    }

    private static func verifyCalDAVSchedulingReplyWriteBackFallbackSemantics() throws {
        let outboxURL = try fixtureURL("https://caldav.example.com/principals/me/outbox/")
        try expect(CalDAVClientError.scheduleOutboxNotFound.allowsSchedulingReplyWriteBackFallback,
                   "Missing CalDAV schedule outbox should allow writable-event RSVP fallback")
        for status in [400, 403, 404, 405, 501] {
            try expect(CalDAVClientError.httpStatus(status, outboxURL).allowsSchedulingReplyWriteBackFallback,
                       "CalDAV scheduling POST \(status) should allow writable-event RSVP fallback")
        }
        try expect(!CalDAVClientError.httpStatus(401, outboxURL).allowsSchedulingReplyWriteBackFallback,
                   "CalDAV scheduling 401 should stay an auth error, not writable-event fallback")
        try expect(!CalDAVClientError.preconditionFailed(outboxURL).allowsSchedulingReplyWriteBackFallback,
                   "CalDAV write conflicts should not be hidden as scheduling fallback")
        try expect(!CalDAVClientError.replyAttendeeNotFound.allowsSchedulingReplyWriteBackFallback,
                   "Missing current attendee should not be hidden as scheduling fallback")
        try expect(!CalDAVClientError.missingCredentials.allowsSchedulingReplyWriteBackFallback,
                   "CalDAV missing credentials should not be hidden as scheduling fallback")
    }

    @MainActor
    private static func verifyCalDAVIncrementalPayloadDoesNotPruneUnreportedObjects() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let importSummary = try store.importICSText(caldavIncrementalPruneBaseICS)
        try expect(importSummary.eventsImported == 2, "Expected two CalDAV provider objects before incremental sync")

        let calendar = CalDAVCalendar(
            href: try fixtureURL("https://caldav.example.com/calendars/work/"),
            displayName: "CalDAV Work",
            colorHex: "#0A84FF",
            syncToken: "sync-token-2",
            cTag: "\"ctag-2\"",
            allowsEventWrite: true,
            allowsResponses: true
        )
        let incrementalPayload = CalDAVCalendarPayload(
            calendar: calendar,
            objects: [
                CalDAVCalendarObject(
                    href: try fixtureURL("https://caldav.example.com/calendars/work/changed.ics"),
                    icsText: caldavIncrementalChangedObjectICS,
                    eTag: "\"changed-2\""
                )
            ],
            deletedObjectHrefs: [],
            isIncremental: true
        )
        try expect(!incrementalPayload.reportsCompleteObjectSetForPruning,
                   "CalDAV incremental payloads should not be treated as complete object lists for pruning")

        let updateSummary = try ProviderICSObjectSyncer().syncObject(
            text: caldavIncrementalChangedObjectICS,
            protocolText: caldavIncrementalChangedObjectICS,
            remoteObjectURL: "https://caldav.example.com/calendars/work/changed.ics",
            calendarIDPrefix: "local-calendar-caldav-test-",
            store: store,
            ownedCalendarIDs: ["local-calendar-caldav-test-calendar"]
        )
        try expect(updateSummary.eventsUpdated == 1, "Incremental CalDAV object should update the changed event")
        if incrementalPayload.reportsCompleteObjectSetForPruning {
            _ = store.pruneProviderEvents(
                calendarID: "local-calendar-caldav-test-calendar",
                keepingRemoteObjectURLs: Set(incrementalPayload.objects.map { $0.href.absoluteString }),
                pruneRange: DateInterval(
                    start: try date("2026-07-01T00:00:00Z"),
                    end: try date("2026-07-02T00:00:00Z")
                )
            )
        }
        try expect(store.events.count == 2,
                   "CalDAV incremental sync should keep unreported provider objects unless they are explicit tombstones")
        try expect(store.events.contains { $0.title == "CalDAV incremental unchanged" },
                   "CalDAV incremental sync should preserve unchanged unreported events")

        let fullPayload = CalDAVCalendarPayload(
            calendar: calendar,
            objects: incrementalPayload.objects,
            deletedObjectHrefs: [],
            isIncremental: false
        )
        try expect(fullPayload.reportsCompleteObjectSetForPruning,
                   "CalDAV full payloads should be complete enough for range pruning")
        if fullPayload.reportsCompleteObjectSetForPruning {
            _ = store.pruneProviderEvents(
                calendarID: "local-calendar-caldav-test-calendar",
                keepingRemoteObjectURLs: Set(fullPayload.objects.map { $0.href.absoluteString }),
                pruneRange: DateInterval(
                    start: try date("2026-07-01T00:00:00Z"),
                    end: try date("2026-07-02T00:00:00Z")
                )
            )
        }
        try expect(store.events.count == 1,
                   "CalDAV full payload pruning should remove provider objects missing from the full object list")
        try expect(store.events.first?.title == "CalDAV incremental changed updated",
                   "CalDAV full payload pruning should keep the reported changed object")
    }

    @MainActor
    private static func verifyProviderRangePruneKeepsRecurringSeriesOutsideWindow() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let summary = try store.importICSText(providerRangePruneRecurringICS)
        try expect(summary.eventsImported == 1, "Expected provider range-prune recurring fixture to import")
        try expect(store.events.count == 1, "Expected one recurring event before range prune")

        let emptyReportedObjects: Set<String> = []
        let emptyWindowPrune = store.pruneProviderEvents(
            calendarID: "local-calendar-caldav-test-calendar",
            keepingRemoteObjectURLs: emptyReportedObjects,
            pruneRange: DateInterval(
                start: try date("2026-07-06T00:00:00Z"),
                end: try date("2026-07-07T00:00:00Z")
            )
        )
        try expect(emptyWindowPrune == 0,
                   "Provider range prune should keep recurring series with no occurrence inside the synced window")
        try expect(store.events.count == 1,
                   "Recurring provider series should survive empty range prune windows it does not occur in")

        let occurrenceWindowPrune = store.pruneProviderEvents(
            calendarID: "local-calendar-caldav-test-calendar",
            keepingRemoteObjectURLs: emptyReportedObjects,
            pruneRange: DateInterval(
                start: try date("2026-07-12T00:00:00Z"),
                end: try date("2026-07-13T00:00:00Z")
            )
        )
        try expect(occurrenceWindowPrune == 1,
                   "Provider range prune should remove missing recurring series when an occurrence falls inside the synced window")
        try expect(store.events.isEmpty,
                   "Missing recurring provider series should be removed when its occurrence is absent from the complete range response")
    }

    @MainActor
    private static func verifyProviderReplyOnlyObjectUpdatesCurrentUserResponse() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let importSummary = try store.importICSText(providerReplyBaseEventICS)
        try expect(importSummary.eventsImported == 1, "Expected provider base event to import before applying a reply")

        let pendingEvent = try requireOnly(
            store.events(
                from: try date("2026-07-01T00:00:00Z"),
                to: try date("2026-07-02T00:00:00Z")
            ),
            context: "pending provider event"
        )
        let pendingRule = RulePredicate(field: .iDidNotRespond, comparison: .isEqualTo, value: "true")
        let acceptedRule = RulePredicate(field: .iAccepted, comparison: .isEqualTo, value: "true")
        try expect(pendingEvent.responseStatus == .pending, "Expected base event to start with pending current-user response")
        try expect(pendingRule.matches(pendingEvent), "Expected pending event to match did-not-respond rules")

        let replySummary = try ProviderICSObjectSyncer().syncObject(
            text: providerReplyOnlyICS,
            remoteObjectURL: "https://caldav.example.com/calendars/work/reply-object.ics",
            calendarIDPrefix: "local-calendar-caldav-test-",
            store: store
        )
        try expect(replySummary.eventsImported == 0, "Reply-only provider object should not import a synthetic event")
        try expect(replySummary.eventsUpdated == 1, "Reply-only provider object should update the existing event RSVP")
        try expect(replySummary.eventsDeleted == 0, "Reply-only provider object should not delete the existing event")
        try expect(store.events.count == 1, "Reply-only provider object should keep the original provider event")

        let acceptedEvent = try requireOnly(
            store.events(
                from: try date("2026-07-01T00:00:00Z"),
                to: try date("2026-07-02T00:00:00Z")
            ),
            context: "accepted provider event"
        )
        try expect(acceptedEvent.responseStatus == .accepted,
                   "Expected METHOD:REPLY to update the current user's response status")
        try expect(!pendingRule.matches(acceptedEvent),
                   "Accepted provider reply should stop matching did-not-respond rules")
        try expect(acceptedRule.matches(acceptedEvent),
                   "Accepted provider reply should match accepted-response rules")
    }

    @MainActor
    private static func verifyPartialProviderAttendeeRefreshPreservesKnownAttendees() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let importSummary = try store.importICSText(providerPartialAttendeesBaseICS)
        try expect(importSummary.eventsImported == 1, "Expected full provider attendee fixture to import")

        let initialEvent = try requireOnly(
            store.events(
                from: try date("2026-07-01T00:00:00Z"),
                to: try date("2026-07-02T00:00:00Z")
            ),
            context: "full provider attendee event"
        )
        try expect(initialEvent.participants.contains { $0.email == "teammate@example.com" },
                   "Full provider attendee fixture should include teammate before partial refresh")
        try expect(initialEvent.participants.contains { $0.email == "cy-office-1st-conference@example.com" && $0.isRoomLike },
                   "Full provider attendee fixture should include room attendee before partial refresh")

        let refreshSummary = try store.importICSText(providerPartialAttendeesRefreshICS)
        try expect(refreshSummary.eventsUpdated == 1,
                   "Partial provider attendee refresh should update the existing event")

        let refreshedEvent = try requireOnly(
            store.events(
                from: try date("2026-07-01T00:00:00Z"),
                to: try date("2026-07-02T00:00:00Z")
            ),
            context: "partial provider attendee event"
        )
        try expect(refreshedEvent.title == "Provider partial attendees fixture updated",
                   "Partial attendee refresh should still update event details")
        try expect(refreshedEvent.responseStatus == .accepted,
                   "Partial attendee refresh should apply the returned current-user response")
        try expect(refreshedEvent.participants.contains {
            $0.email == "me@example.com" && $0.isCurrentUser && $0.status == .accepted
        }, "Partial attendee refresh should update the current user's attendee status")
        try expect(refreshedEvent.participants.contains {
            $0.email == "teammate@example.com" && $0.status == .accepted
        }, "Partial attendee refresh should preserve known non-current attendees omitted by the provider")
        try expect(refreshedEvent.participants.contains {
            $0.email == "cy-office-1st-conference@example.com" && $0.isRoomLike
        }, "Partial attendee refresh should preserve known room attendees omitted by the provider")
    }

    @MainActor
    private static func verifyPartialProviderDetachedAttendeeRefreshPreservesKnownAttendees() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let importSummary = try store.importICSText(providerPartialDetachedAttendeesBaseICS)
        try expect(importSummary.eventsImported == 1, "Expected recurring partial-detached attendee fixture to import")

        let initialOccurrence = try requireOnly(
            store.events(
                from: try date("2026-07-15T00:00:00Z"),
                to: try date("2026-07-16T00:00:00Z")
            ),
            context: "full provider detached attendee occurrence"
        )
        try expect(initialOccurrence.title == "Provider partial detached occurrence moved",
                   "Fixture should expose the moved detached occurrence before partial refresh")
        try expect(initialOccurrence.participants.contains { $0.email == "teammate@example.com" },
                   "Full detached attendee fixture should include teammate before partial refresh")
        try expect(initialOccurrence.participants.contains { $0.email == "cy-office-1st-conference@example.com" && $0.isRoomLike },
                   "Full detached attendee fixture should include room attendee before partial refresh")

        let refreshSummary = try store.importICSText(providerPartialDetachedAttendeesRefreshICS)
        try expect(refreshSummary.eventsUpdated == 1,
                   "Partial detached attendee refresh should update the recurring series")

        let refreshedOccurrence = try requireOnly(
            store.events(
                from: try date("2026-07-15T00:00:00Z"),
                to: try date("2026-07-16T00:00:00Z")
            ),
            context: "partial provider detached attendee occurrence"
        )
        try expect(refreshedOccurrence.title == "Provider partial detached occurrence updated",
                   "Partial detached attendee refresh should still update occurrence details")
        try expect(refreshedOccurrence.responseStatus == .accepted,
                   "Partial detached attendee refresh should apply the returned current-user response")
        try expect(refreshedOccurrence.participants.contains {
            $0.email == "me@example.com" && $0.isCurrentUser && $0.status == .accepted
        }, "Partial detached attendee refresh should update the current user's attendee status")
        try expect(refreshedOccurrence.participants.contains {
            $0.email == "teammate@example.com" && $0.status == .accepted
        }, "Partial detached attendee refresh should preserve omitted known attendees")
        try expect(refreshedOccurrence.participants.contains {
            $0.email == "cy-office-1st-conference@example.com" && $0.isRoomLike
        }, "Partial detached attendee refresh should preserve omitted room attendees")

        let untouchedOccurrence = try requireOnly(
            store.events(
                from: try date("2026-07-22T00:00:00Z"),
                to: try date("2026-07-23T00:00:00Z")
            ),
            context: "untouched provider partial-detached occurrence"
        )
        try expect(untouchedOccurrence.responseStatus == .pending,
                   "Partial detached attendee refresh should not update other generated occurrences")
    }

    @MainActor
    private static func verifyProtectedProviderResponseSurvivesPendingRefresh() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let importSummary = try store.importICSText(providerReplyBaseEventICS)
        try expect(importSummary.eventsImported == 1, "Expected provider base event to import before local RSVP")

        let pendingEvent = try requireOnly(
            store.events(
                from: try date("2026-07-01T00:00:00Z"),
                to: try date("2026-07-02T00:00:00Z")
            ),
            context: "pending provider event before local RSVP"
        )
        let pendingRule = RulePredicate(field: .iDidNotRespond, comparison: .isEqualTo, value: "true")
        let acceptedRule = RulePredicate(field: .iAccepted, comparison: .isEqualTo, value: "true")
        try expect(pendingRule.matches(pendingEvent), "Expected pending provider event to match did-not-respond before local RSVP")

        guard let acceptedLocalEvent = store.respond(to: pendingEvent, with: .accept) else {
            throw ProviderSyncRecoveryInvariantError("Expected local RSVP to update the provider-backed event")
        }

        let accountID = "provider-response-refresh-protection"
        let providerStore = CalendarProviderStore()
        let outboxItem = ProviderOutboxItem.response(
            event: acceptedLocalEvent,
            accountID: accountID,
            response: .accept,
            scope: .thisEvent,
            occurrenceStartDate: nil,
            occurrenceIsAllDay: false,
            hadLocalProviderRecurrenceChanges: false,
            now: try date("2026-07-01T08:59:00Z")
        )
        providerStore.enqueueProviderOutboxItem(outboxItem)
        defer { providerStore.removeProviderOutboxItem(id: outboxItem.id) }
        providerStore.recordProviderOutboxBlocked(
            id: outboxItem.id,
            error: "Provider rejected the response fixture",
            at: try date("2026-07-01T09:00:00Z")
        )

        let protectedResponseRemoteObjectURLs = providerStore.localResponseRemoteObjectURLsProtectedFromProviderRefresh(accountID: accountID)
        try expect(protectedResponseRemoteObjectURLs.contains("https://caldav.example.com/calendars/work/base-object.ics"),
                   "Blocked provider response should protect its remote object from response rollback during refresh")

        let refreshSummary = try store.importICSText(
            providerReplyPendingRefreshHigherSequenceICS,
            preservingLocalResponsesForRemoteObjectURLs: protectedResponseRemoteObjectURLs
        )
        try expect(refreshSummary.eventsUpdated == 1,
                   "Higher-sequence provider refresh should still update event details")

        let refreshedEvent = try requireOnly(
            store.events(
                from: try date("2026-07-01T00:00:00Z"),
                to: try date("2026-07-02T00:00:00Z")
            ),
            context: "provider event after protected pending refresh"
        )
        try expect(refreshedEvent.title == "Provider reply fixture organizer update",
                   "Protected response refresh should not block legitimate provider event updates")
        try expect(refreshedEvent.responseStatus == .accepted,
                   "Protected local Accept should survive a provider refresh that still reports pending")
        try expect(!pendingRule.matches(refreshedEvent),
                   "Protected local Accept should not keep matching did-not-respond rules after refresh")
        try expect(acceptedRule.matches(refreshedEvent),
                   "Protected local Accept should keep matching accepted-response rules after refresh")
    }

    @MainActor
    private static func verifySingleOccurrenceResponseSurvivesProviderRefreshAfterRemoteAck() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let importSummary = try store.importICSText(providerRecurringReplyBaseEventICS)
        try expect(importSummary.eventsImported == 1, "Expected recurring provider RSVP fixture to import")

        let selectedOccurrence = try requireOnly(
            store.events(
                from: try date("2026-07-15T00:00:00Z"),
                to: try date("2026-07-16T00:00:00Z")
            ),
            context: "selected recurring occurrence before local RSVP"
        )
        let pendingRule = RulePredicate(field: .iDidNotRespond, comparison: .isEqualTo, value: "true")
        let acceptedRule = RulePredicate(field: .iAccepted, comparison: .isEqualTo, value: "true")
        try expect(selectedOccurrence.responseStatus == .pending,
                   "Expected selected recurring occurrence to start pending")
        try expect(pendingRule.matches(selectedOccurrence),
                   "Expected selected recurring occurrence to match did-not-respond before local RSVP")

        guard let acceptedSeries = store.respond(to: selectedOccurrence, with: .accept, scope: .thisEvent) else {
            throw ProviderSyncRecoveryInvariantError("Expected local single-occurrence RSVP to update the recurring series")
        }
        store.clearLocalProviderRecurrenceChanges(eventID: acceptedSeries.id)
        try expect(store.events.first?.hasLocalProviderRecurrenceChanges == false,
                   "Remote ack simulation should clear structural local recurrence-change protection")

        let refreshSummary = try store.importICSText(providerRecurringReplyPendingRefreshHigherSequenceICS)
        try expect(refreshSummary.eventsUpdated == 1,
                   "Higher-sequence recurring provider refresh should update the base series")

        let refreshedOccurrences = store.events(
            from: try date("2026-07-08T00:00:00Z"),
            to: try date("2026-07-23T00:00:00Z")
        )
        let acceptedOccurrence = try requireOnly(
            refreshedOccurrences.filter { sameInstant($0.startDate, "2026-07-15T09:00:00Z") },
            context: "accepted occurrence after provider refresh"
        )
        let untouchedOccurrence = try requireOnly(
            refreshedOccurrences.filter { sameInstant($0.startDate, "2026-07-22T09:00:00Z") },
            context: "untouched occurrence after provider refresh"
        )

        try expect(acceptedOccurrence.title == "Provider recurring reply fixture organizer update",
                   "Provider refresh should still update recurring event details")
        try expect(acceptedOccurrence.responseStatus == .accepted,
                   "Local single-occurrence Accept should survive a provider refresh that still reports pending")
        try expect(!pendingRule.matches(acceptedOccurrence),
                   "Accepted single occurrence should not match did-not-respond after provider refresh")
        try expect(acceptedRule.matches(acceptedOccurrence),
                   "Accepted single occurrence should keep matching accepted-response rules after provider refresh")
        try expect(untouchedOccurrence.responseStatus == .pending,
                   "Unanswered occurrences in the same series should remain pending")
        try expect(pendingRule.matches(untouchedOccurrence),
                   "Untouched occurrence should continue to match did-not-respond rules")
        try expect(store.events.first?.hasLocalProviderRecurrenceChanges == false,
                   "Response-only detached RSVP preservation should not re-mark the series as structurally edited")
    }

    @MainActor
    private static func verifyProviderRequestUpdatesExistingUIDAcrossRemoteHref() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let importSummary = try store.importICSText(providerRequestBaseEventICS)
        try expect(importSummary.eventsImported == 1, "Expected provider REQUEST base event to import")
        try expect(store.events.count == 1, "Expected one provider event before same-UID REQUEST update")

        let updateSummary = try ProviderICSObjectSyncer().syncObject(
            text: providerRequestUpdateICS,
            protocolText: providerRequestUpdateProtocolICS,
            remoteObjectURL: "https://caldav.example.com/calendars/work/request-update-object.ics",
            calendarIDPrefix: "local-calendar-caldav-test-",
            store: store
        )

        try expect(updateSummary.eventsImported == 0, "Same-UID provider REQUEST should not import a duplicate across href changes")
        try expect(updateSummary.eventsUpdated == 1, "Same-UID provider REQUEST should update the existing provider event")
        try expect(store.events.count == 1, "Same-UID provider REQUEST should keep a single event")
        let updatedEvent = try requireOnly(
            store.events(
                from: try date("2026-07-03T00:00:00Z"),
                to: try date("2026-07-04T00:00:00Z")
            ),
            context: "updated provider REQUEST event"
        )
        try expect(updatedEvent.title == "Provider REQUEST fixture updated",
                   "Same-UID provider REQUEST should replace event details")
        try expect(store.events.first?.remoteObjectURLString == "https://caldav.example.com/calendars/work/request-update-object.ics",
                   "Same-UID provider REQUEST should move the remote binding to the latest provider href")

        let staleSummary = try ProviderICSObjectSyncer().syncObject(
            text: providerRequestStaleUpdateICS,
            protocolText: providerRequestStaleUpdateProtocolICS,
            remoteObjectURL: "https://caldav.example.com/calendars/work/request-stale-object.ics",
            calendarIDPrefix: "local-calendar-caldav-test-",
            store: store
        )

        try expect(staleSummary.eventsImported == 0, "Stale same-UID provider REQUEST should not import a duplicate")
        try expect(staleSummary.eventsUpdated == 0, "Stale same-UID provider REQUEST should not update the existing event")
        try expect(staleSummary.eventsSkipped == 1, "Stale same-UID provider REQUEST should be skipped")
        let eventAfterStaleUpdate = try requireOnly(
            store.events(
                from: try date("2026-07-03T00:00:00Z"),
                to: try date("2026-07-04T00:00:00Z")
            ),
            context: "provider REQUEST event after stale update"
        )
        try expect(eventAfterStaleUpdate.title == "Provider REQUEST fixture updated",
                   "Stale same-UID provider REQUEST should not roll back event details")
    }

    @MainActor
    private static func verifyProviderOrphanOccurrenceRequestUpdatesRecurringSeries() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let importSummary = try store.importICSText(providerOrphanOccurrenceBaseICS)
        try expect(importSummary.eventsImported == 1, "Expected provider recurring fixture to import before orphan occurrence update")
        try expect(store.events.count == 1, "Expected one recurring provider event before orphan occurrence update")

        let updateSummary = try ProviderICSObjectSyncer().syncObject(
            text: providerOrphanOccurrenceUpdateICS,
            protocolText: providerOrphanOccurrenceUpdateProtocolICS,
            remoteObjectURL: "https://caldav.example.com/calendars/work/orphan-occurrence-object.ics",
            calendarIDPrefix: "local-calendar-caldav-test-",
            store: store
        )

        try expect(updateSummary.eventsImported == 0, "Orphan provider RECURRENCE-ID update should not import a duplicate event")
        try expect(updateSummary.eventsUpdated == 1, "Orphan provider RECURRENCE-ID update should update one recurring series")
        try expect(store.events.count == 1, "Orphan provider RECURRENCE-ID update should keep a single base event")
        guard let event = store.events.first else {
            throw ProviderSyncRecoveryInvariantError("Expected recurring provider event after orphan occurrence update")
        }
        try expect(event.detachedOccurrences.count == 1,
                   "Orphan provider RECURRENCE-ID update should create one detached occurrence")

        let occurrences = store.events(
            from: try date("2026-07-06T00:00:00Z"),
            to: try date("2026-07-21T00:00:00Z")
        )
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-07-06T09:00:00Z") },
                   "Orphan provider RECURRENCE-ID update should keep the first recurrence")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-07-13T10:00:00Z") && $0.title == "Provider orphan occurrence moved" },
                   "Orphan provider RECURRENCE-ID update should expose the moved detached occurrence")
        try expect(!occurrences.contains { sameInstant($0.startDate, "2026-07-13T09:00:00Z") },
                   "Orphan provider RECURRENCE-ID update should hide the original occurrence start")
    }

    @MainActor
    private static func verifyProviderBaseSeriesAbsorbsEarlierOrphanOccurrence() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let calendarIDPrefix = "local-calendar-caldav-test-"
        let orphanObjectURL = "https://caldav.example.com/calendars/work/orphan-first-occurrence.ics"
        let baseObjectURL = "https://caldav.example.com/calendars/work/orphan-first-base.ics"

        let orphanSummary = try ProviderICSObjectSyncer().syncObject(
            text: providerOrphanFirstOccurrenceICS,
            protocolText: providerOrphanFirstOccurrenceProtocolICS,
            remoteObjectURL: orphanObjectURL,
            calendarIDPrefix: calendarIDPrefix,
            store: store
        )
        try expect(orphanSummary.eventsImported == 1,
                   "Provider orphan occurrence should import as a temporary standalone event when no base series exists")
        try expect(store.events.count == 1, "Expected one temporary orphan event before the base series arrives")

        let baseSummary = try ProviderICSObjectSyncer().syncObject(
            text: providerOrphanFirstBaseSeriesICS,
            protocolText: providerOrphanFirstBaseSeriesProtocolICS,
            remoteObjectURL: baseObjectURL,
            calendarIDPrefix: calendarIDPrefix,
            store: store
        )

        try expect(baseSummary.eventsImported == 1, "Provider base series should import after an orphan occurrence")
        try expect(baseSummary.eventsDeleted == 1,
                   "Provider base series import should remove the temporary standalone orphan occurrence")
        try expect(store.events.count == 1,
                   "Provider base series should absorb the earlier orphan occurrence instead of leaving a duplicate")
        guard let event = store.events.first else {
            throw ProviderSyncRecoveryInvariantError("Expected provider base series after orphan absorption")
        }
        try expect(event.detachedOccurrences.count == 1,
                   "Provider base series should keep the earlier orphan as a detached occurrence")
        try expect(event.detachedOccurrences.first?.remoteObjectURLString == orphanObjectURL,
                   "Absorbed detached occurrence should keep the separate provider object URL")

        let occurrences = store.events(
            from: try date("2026-08-03T00:00:00Z"),
            to: try date("2026-08-18T00:00:00Z")
        )
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-08-03T09:00:00Z") },
                   "Provider base series should keep generated occurrences before the moved orphan")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-08-10T10:00:00Z") && $0.title == "Provider orphan-first occurrence moved" },
                   "Provider base series should expose the absorbed moved occurrence")
        try expect(!occurrences.contains { sameInstant($0.startDate, "2026-08-10T09:00:00Z") },
                   "Provider base series should hide the original slot for the absorbed orphan occurrence")

        let removedDetachedObjects = store.removeProviderEvents(remoteObjectURLs: [orphanObjectURL])
        try expect(removedDetachedObjects == 1,
                   "Deleting the separate provider object should remove the absorbed detached occurrence")
        try expect(store.events.count == 1,
                   "Deleting the detached provider object should keep the base recurring series")
        guard let restoredEvent = store.events.first else {
            throw ProviderSyncRecoveryInvariantError("Expected base series after detached provider object deletion")
        }
        try expect(restoredEvent.remoteObjectURLString == baseObjectURL,
                   "Deleting the detached provider object should not clear the base provider binding")
        try expect(restoredEvent.detachedOccurrences.isEmpty,
                   "Deleting the detached provider object should remove the absorbed override")

        let restoredOccurrences = store.events(
            from: try date("2026-08-03T00:00:00Z"),
            to: try date("2026-08-18T00:00:00Z")
        )
        try expect(restoredOccurrences.contains { sameInstant($0.startDate, "2026-08-10T09:00:00Z") && $0.title == "Provider orphan-first base fixture" },
                   "Deleting the detached provider object should restore the generated base occurrence")
        try expect(!restoredOccurrences.contains { sameInstant($0.startDate, "2026-08-10T10:00:00Z") },
                   "Deleting the detached provider object should remove the moved occurrence override")
    }

    @MainActor
    private static func verifyProviderBaseSeriesPrunesEarlierOrphanOccurrenceObject() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let calendarIDPrefix = "local-calendar-caldav-test-"
        let orphanObjectURL = "https://caldav.example.com/calendars/work/orphan-first-occurrence.ics"
        let baseObjectURL = "https://caldav.example.com/calendars/work/orphan-first-base.ics"

        _ = try ProviderICSObjectSyncer().syncObject(
            text: providerOrphanFirstOccurrenceICS,
            protocolText: providerOrphanFirstOccurrenceProtocolICS,
            remoteObjectURL: orphanObjectURL,
            calendarIDPrefix: calendarIDPrefix,
            store: store
        )
        _ = try ProviderICSObjectSyncer().syncObject(
            text: providerOrphanFirstBaseSeriesICS,
            protocolText: providerOrphanFirstBaseSeriesProtocolICS,
            remoteObjectURL: baseObjectURL,
            calendarIDPrefix: calendarIDPrefix,
            store: store
        )

        let prunedDetachedObjects = store.pruneProviderEvents(
            calendarIDPrefix: calendarIDPrefix,
            keepingRemoteObjectURLs: [baseObjectURL],
            pruneRange: DateInterval(
                start: try date("2026-08-01T00:00:00Z"),
                end: try date("2026-08-20T00:00:00Z")
            )
        )

        try expect(prunedDetachedObjects == 1,
                   "Provider range prune should remove absorbed detached occurrences whose object URL disappeared")
        try expect(store.events.count == 1,
                   "Provider range prune should keep the base recurring series object")
        try expect(store.events.first?.detachedOccurrences.isEmpty == true,
                   "Provider range prune should remove the absorbed detached occurrence override")
    }

    @MainActor
    private static func verifyProviderCancelObjectDeletesByUIDWhenHrefDiffers() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let importSummary = try store.importICSText(providerCancelBaseEventICS)
        try expect(importSummary.eventsImported == 1, "Expected provider cancel fixture to import the base event")
        try expect(store.events.count == 1, "Expected one provider event before applying full cancellation")

        let cancelSummary = try ProviderICSObjectSyncer().syncObject(
            text: providerFullCancelICS,
            remoteObjectURL: "https://caldav.example.com/calendars/work/cancel-object.ics",
            calendarIDPrefix: "local-calendar-caldav-test-",
            store: store
        )

        try expect(cancelSummary.eventsImported == 0, "Full provider cancellation should not import an event")
        try expect(cancelSummary.eventsDeleted == 1,
                   "Full provider cancellation should delete the existing event by UID even when href differs")
        try expect(store.events.isEmpty, "Full provider cancellation should remove the matching provider event")
    }

    @MainActor
    private static func verifyProviderCancelObjectKeepsProtectedLocalWrite() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let importSummary = try store.importICSText(providerCancelBaseEventICS)
        try expect(importSummary.eventsImported == 1, "Expected provider cancel fixture to import the base event")
        guard let protectedRemoteObjectURL = store.events.first?.remoteObjectURLString else {
            throw ProviderSyncRecoveryInvariantError("Expected provider cancel fixture to keep a remote object URL")
        }

        let cancelSummary = try ProviderICSObjectSyncer().syncObject(
            text: providerFullCancelICS,
            remoteObjectURL: "https://caldav.example.com/calendars/work/cancel-object.ics",
            calendarIDPrefix: "local-calendar-caldav-test-",
            store: store,
            protectingRemoteObjectURLs: [protectedRemoteObjectURL]
        )

        try expect(cancelSummary.eventsImported == 0, "Protected full cancellation should not import an event")
        try expect(cancelSummary.eventsDeleted == 0,
                   "Protected full cancellation should not delete a locally blocked provider event")
        try expect(store.events.count == 1,
                   "Protected full cancellation should keep the matching provider event")
    }

    @MainActor
    private static func verifyProviderOccurrenceCancelUpdatesRecurringSeries() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let importSummary = try store.importICSText(providerRecurringCancelBaseICS)
        try expect(importSummary.eventsImported == 1, "Expected provider recurring cancel fixture to import the base series")
        try expect(store.events.count == 1, "Expected one recurring provider event before occurrence cancellation")
        try expect(store.events.first?.detachedOccurrences.count == 2,
                   "Expected fixture to start with two detached occurrences")

        let cancelSummary = try ProviderICSObjectSyncer().syncObject(
            text: providerOccurrenceCancelICS,
            remoteObjectURL: "https://caldav.example.com/calendars/work/occurrence-cancel.ics",
            calendarIDPrefix: "local-calendar-caldav-test-",
            store: store
        )

        try expect(cancelSummary.eventsImported == 0, "Occurrence cancellation should not import a synthetic event")
        try expect(cancelSummary.eventsDeleted == 1, "Occurrence cancellation should report one removed occurrence")
        guard let event = store.events.first else {
            throw ProviderSyncRecoveryInvariantError("Expected recurring provider event to remain after occurrence cancellation")
        }
        try expect(event.detachedOccurrences.count == 1,
                   "Occurrence cancellation should remove only the detached override for the cancelled recurrence")
        try expect(event.detachedOccurrences.contains { sameInstant($0.originalStartDate, "2026-07-22T09:00:00Z") },
                   "Occurrence cancellation should keep unrelated later detached overrides")
        try expect(event.excludedOccurrenceStartDates.contains { sameInstant($0, "2026-07-08T09:00:00Z") },
                   "Occurrence cancellation should add an EXDATE-equivalent exclusion")

        let occurrences = store.events(
            from: try date("2026-07-01T00:00:00Z"),
            to: try date("2026-07-23T00:00:00Z")
        )
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-07-01T09:00:00Z") },
                   "Occurrence cancellation should keep the first recurrence")
        try expect(!occurrences.contains { sameInstant($0.startDate, "2026-07-08T09:00:00Z") },
                   "Occurrence cancellation should hide the cancelled recurrence")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-07-15T09:00:00Z") },
                   "Occurrence cancellation should keep later recurrences")
    }

    @MainActor
    private static func verifyProviderOccurrenceCancelKeepsProtectedDetachedWrite() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let importSummary = try store.importICSText(providerRecurringCancelBaseICS)
        try expect(importSummary.eventsImported == 1, "Expected provider recurring cancel fixture to import the base series")
        try expect(store.events.count == 1,
                   "Expected one recurring provider event before protected occurrence cancellation")
        guard let protectedRemoteObjectURL = store.events.first?.detachedOccurrences.first(where: {
            sameInstant($0.originalStartDate, "2026-07-08T09:00:00Z")
        })?.remoteObjectURLString else {
            throw ProviderSyncRecoveryInvariantError("Expected recurring cancel fixture to keep a protected detached remote object URL")
        }
        try expect(protectedRemoteObjectURL == "https://caldav.example.com/calendars/work/recurring-object-20260708.ics",
                   "Expected July 8 detached occurrence to keep its provider remote object URL")
        let targets = LocalCalendarICSCodec.cancellationTargets(from: providerOccurrenceCancelICS)
        try expect(targets.eventUIDs.isEmpty,
                   "Expected provider occurrence cancellation fixture not to parse as a full event cancellation")
        try expect(targets.occurrences.contains { sameInstant($0.occurrenceStartDate, "2026-07-08T09:00:00Z") },
                   "Expected provider occurrence cancellation fixture to target the July 8 occurrence")

        let cancelSummary = try ProviderICSObjectSyncer().syncObject(
            text: providerOccurrenceCancelICS,
            remoteObjectURL: "https://caldav.example.com/calendars/work/occurrence-cancel.ics",
            calendarIDPrefix: "local-calendar-caldav-test-",
            store: store,
            protectingRemoteObjectURLs: [protectedRemoteObjectURL]
        )

        try expect(cancelSummary.eventsImported == 0, "Protected occurrence cancellation should not import a synthetic event")
        try expect(cancelSummary.eventsDeleted == 0,
                   "Protected occurrence cancellation should not remove a locally blocked detached occurrence")
        guard let event = store.events.first else {
            throw ProviderSyncRecoveryInvariantError("Expected recurring provider event to remain after protected occurrence cancellation")
        }
        try expect(event.detachedOccurrences.count == 2,
                   "Protected occurrence cancellation should keep the detached override")
        try expect(!event.excludedOccurrenceStartDates.contains { sameInstant($0, "2026-07-08T09:00:00Z") },
                   "Protected occurrence cancellation should not add an exclusion")
    }

    @MainActor
    private static func verifyProviderAllDayOccurrenceCancelUpdatesRecurringSeries() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let importSummary = try store.importICSText(providerAllDayRecurringCancelBaseICS)
        try expect(importSummary.eventsImported == 1, "Expected provider all-day recurring cancel fixture to import the base series")
        try expect(store.events.count == 1, "Expected one all-day recurring provider event before occurrence cancellation")
        try expect(store.events.first?.isAllDay == true, "Expected all-day cancellation fixture to import as all-day")
        try expect(store.events.first?.detachedOccurrences.count == 1,
                   "Expected all-day fixture to start with one detached occurrence")

        let targets = LocalCalendarICSCodec.cancellationTargets(from: providerAllDayOccurrenceCancelICS)
        try expect(targets.occurrences.contains { sameLocalDay($0.occurrenceStartDate, "2026-07-08") && !$0.appliesToFutureOccurrences },
                   "Expected all-day occurrence cancellation target to parse as the original all-day date")

        let cancelSummary = try ProviderICSObjectSyncer().syncObject(
            text: providerAllDayOccurrenceCancelICS,
            remoteObjectURL: "https://caldav.example.com/calendars/work/all-day-occurrence-cancel.ics",
            calendarIDPrefix: "local-calendar-caldav-test-",
            store: store
        )

        try expect(cancelSummary.eventsImported == 0, "All-day occurrence cancellation should not import a synthetic event")
        try expect(cancelSummary.eventsDeleted == 1, "All-day occurrence cancellation should report one removed occurrence")
        guard let event = store.events.first else {
            throw ProviderSyncRecoveryInvariantError("Expected all-day recurring provider event to remain after occurrence cancellation")
        }
        try expect(event.detachedOccurrences.isEmpty,
                   "All-day occurrence cancellation should remove any detached override for the cancelled recurrence")
        try expect(event.excludedOccurrenceStartDates.contains { sameLocalDay($0, "2026-07-08") },
                   "All-day occurrence cancellation should add a date-only EXDATE-equivalent exclusion")

        let occurrences = store.events(
            from: try date("2026-07-01T00:00:00Z"),
            to: try date("2026-07-25T00:00:00Z"),
            includeAllDay: true
        )
        try expect(occurrences.contains { sameLocalDay($0.startDate, "2026-07-01") },
                   "All-day occurrence cancellation should keep the first recurrence")
        try expect(!occurrences.contains { sameLocalDay($0.startDate, "2026-07-08") },
                   "All-day occurrence cancellation should hide the cancelled original recurrence")
        try expect(!occurrences.contains { sameLocalDay($0.startDate, "2026-07-09") },
                   "All-day occurrence cancellation should remove the moved detached occurrence")
        try expect(occurrences.contains { sameLocalDay($0.startDate, "2026-07-15") },
                   "All-day occurrence cancellation should keep later recurrences")
    }

    @MainActor
    private static func verifyProviderFutureOccurrenceCancelTruncatesRecurringSeries() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let importSummary = try store.importICSText(providerRecurringCancelBaseICS)
        try expect(importSummary.eventsImported == 1, "Expected provider recurring cancel fixture to import the base series")
        let targets = LocalCalendarICSCodec.cancellationTargets(from: providerFutureOccurrenceCancelICS)
        try expect(targets.occurrences.contains { sameInstant($0.occurrenceStartDate, "2026-07-15T09:00:00Z") && $0.appliesToFutureOccurrences },
                   "Expected future cancellation target to parse as July 15 this-and-future")

        let cancelSummary = try ProviderICSObjectSyncer().syncObject(
            text: providerFutureOccurrenceCancelICS,
            remoteObjectURL: "https://caldav.example.com/calendars/work/future-cancel.ics",
            calendarIDPrefix: "local-calendar-caldav-test-",
            store: store
        )

        try expect(cancelSummary.eventsImported == 0, "This-and-future cancellation should not import a synthetic event")
        try expect(cancelSummary.eventsDeleted == 1, "This-and-future cancellation should report one truncated series")
        guard let event = store.events.first else {
            throw ProviderSyncRecoveryInvariantError("Expected recurring provider event to remain after future cancellation")
        }
        try expect(event.detachedOccurrences.count == 1,
                   "This-and-future cancellation should keep one detached override before the cutoff")
        try expect(event.detachedOccurrences.allSatisfy { $0.originalStartDate < (try! date("2026-07-15T09:00:00Z")) },
                   "This-and-future cancellation should remove detached overrides at and after the cancellation")
        let occurrences = store.events(
            from: try date("2026-07-01T00:00:00Z"),
            to: try date("2026-07-30T00:00:00Z")
        )
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-07-01T09:00:00Z") },
                   "This-and-future cancellation should keep occurrences before the cutoff")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-07-08T10:00:00Z") },
                   "This-and-future cancellation should keep detached occurrences before the cutoff")
        try expect(!occurrences.contains { sameInstant($0.startDate, "2026-07-15T09:00:00Z") },
                   "This-and-future cancellation should remove the cutoff occurrence")
        try expect(!occurrences.contains { sameInstant($0.startDate, "2026-07-22T09:00:00Z") },
                   "This-and-future cancellation should remove later occurrences")
    }

    @MainActor
    private static func verifyProviderFutureOccurrenceCancelKeepsProtectedDetachedWrite() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let importSummary = try store.importICSText(providerRecurringCancelBaseICS)
        try expect(importSummary.eventsImported == 1, "Expected provider recurring cancel fixture to import the base series")
        try expect(store.events.count == 1,
                   "Expected one recurring provider event before protected future occurrence cancellation")
        guard let protectedRemoteObjectURL = store.events.first?.detachedOccurrences.first(where: {
            sameInstant($0.originalStartDate, "2026-07-22T09:00:00Z")
        })?.remoteObjectURLString else {
            throw ProviderSyncRecoveryInvariantError("Expected recurring cancel fixture to keep a protected future detached remote object URL")
        }
        try expect(protectedRemoteObjectURL == "https://caldav.example.com/calendars/work/recurring-object-20260722.ics",
                   "Expected July 22 detached occurrence to keep its provider remote object URL")
        let targets = LocalCalendarICSCodec.cancellationTargets(from: providerFutureOccurrenceCancelICS)
        try expect(targets.eventUIDs.isEmpty,
                   "Expected provider future cancellation fixture not to parse as a full event cancellation")
        try expect(targets.occurrences.contains { sameInstant($0.occurrenceStartDate, "2026-07-15T09:00:00Z") && $0.appliesToFutureOccurrences },
                   "Expected provider future cancellation fixture to target July 15 this-and-future")

        let cancelSummary = try ProviderICSObjectSyncer().syncObject(
            text: providerFutureOccurrenceCancelICS,
            remoteObjectURL: "https://caldav.example.com/calendars/work/future-cancel.ics",
            calendarIDPrefix: "local-calendar-caldav-test-",
            store: store,
            protectingRemoteObjectURLs: [protectedRemoteObjectURL]
        )

        try expect(cancelSummary.eventsImported == 0, "Protected this-and-future cancellation should not import a synthetic event")
        try expect(cancelSummary.eventsDeleted == 0,
                   "Protected this-and-future cancellation should not truncate across a locally blocked detached occurrence")
        guard let event = store.events.first else {
            throw ProviderSyncRecoveryInvariantError("Expected recurring provider event to remain after protected future cancellation")
        }
        try expect(event.detachedOccurrences.count == 2,
                   "Protected this-and-future cancellation should keep detached overrides")
        let cutoff = try date("2026-07-15T09:00:00Z")
        try expect(event.recurrenceEndDate == nil || event.recurrenceEndDate! > cutoff,
                   "Protected this-and-future cancellation should not shorten the recurring series")
    }

    private static func fixtureURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else {
            throw ProviderSyncRecoveryInvariantError("Invalid fixture URL \(value)")
        }
        return url
    }

    private static func httpResponse(url: URL, statusCode: Int, retryAfter: String) throws -> HTTPURLResponse {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Retry-After": retryAfter]
        ) else {
            throw ProviderSyncRecoveryInvariantError("Could not create HTTP response fixture")
        }
        return response
    }

    private static func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            throw ProviderSyncRecoveryInvariantError("Invalid date fixture \(value)")
        }
        return date
    }

    private static func requireOnly(_ events: [CalendarEvent], context: String) throws -> CalendarEvent {
        guard events.count == 1, let event = events.first else {
            throw ProviderSyncRecoveryInvariantError("Expected exactly one \(context), got \(events.count)")
        }
        return event
    }

    private static func requireOnly<T>(_ values: [T], context: String) throws -> T {
        guard values.count == 1, let value = values.first else {
            throw ProviderSyncRecoveryInvariantError("Expected exactly one \(context), got \(values.count)")
        }
        return value
    }

    private static func sameInstant(_ date: Date, _ expected: String) -> Bool {
        guard let expectedDate = try? Self.date(expected) else { return false }
        return abs(date.timeIntervalSince(expectedDate)) < 1
    }

    private static func sameLocalDay(_ date: Date, _ expectedDay: String) -> Bool {
        localDayFormatter.string(from: date) == expectedDay
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func emptySummary() -> LocalICSImportSummary {
        LocalICSImportSummary(
            calendarsImported: 0,
            eventsImported: 0,
            eventsUpdated: 0,
            eventsSkipped: 0,
            eventsDeleted: 0
        )
    }

    private static func providerWriteEvent(
        id: String,
        calendarID: String,
        title: String,
        start: Date,
        end: Date
    ) -> LocalCalendarEvent {
        LocalCalendarEvent(
            id: id,
            calendarID: calendarID,
            title: title,
            startDate: start,
            endDate: end,
            isAllDay: false,
            timeZoneIdentifier: "UTC",
            location: "",
            notes: "",
            urlString: "",
            createdAt: start,
            updatedAt: start
        )
    }

    private static func resetLocalCalendarStorage() {
        UserDefaults.standard.removeObject(forKey: "localCalendars")
        UserDefaults.standard.removeObject(forKey: "localCalendarEvents")
        UserDefaults.standard.removeObject(forKey: "selectedLocalCalendarIDs")
    }

    private static func queryItems(for request: URLRequest) -> [String: String] {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return [:]
        }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            result[item.name] = item.value ?? ""
        }
        return result
    }

    private static func jsonObject(from request: URLRequest) throws -> [String: Any] {
        guard let body = request.httpBody else {
            throw ProviderSyncRecoveryInvariantError("Expected JSON request body for \(request.url?.absoluteString ?? "<nil>")")
        }
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ProviderSyncRecoveryInvariantError("Expected top-level JSON object for \(request.url?.absoluteString ?? "<nil>")")
        }
        return object
    }

    private static func jsonObject(named name: String, in object: [String: Any]) throws -> [String: Any] {
        guard let nested = object[name] as? [String: Any] else {
            throw ProviderSyncRecoveryInvariantError("Expected JSON object '\(name)'")
        }
        return nested
    }

    private static func jsonArray(named name: String, in object: [String: Any]) throws -> [[String: Any]] {
        guard let array = object[name] as? [[String: Any]] else {
            throw ProviderSyncRecoveryInvariantError("Expected JSON array '\(name)'")
        }
        return array
    }

    private static func decodedRelationships(
        from object: [String: Any],
        key: String
    ) throws -> [LocalEventRelationship] {
        guard let value = object[key] as? String,
              let data = value.data(using: .utf8) else {
            throw ProviderSyncRecoveryInvariantError("Expected encoded relationship metadata '\(key)'")
        }
        return normalizedEventRelationships(try JSONDecoder().decode([LocalEventRelationship].self, from: data))
    }

    private static func decodedGeoCoordinate(
        from object: [String: Any],
        key: String
    ) throws -> LocalEventGeoCoordinate {
        guard let value = object[key] as? String,
              let data = value.data(using: .utf8) else {
            throw ProviderSyncRecoveryInvariantError("Expected encoded GEO metadata '\(key)'")
        }
        return try JSONDecoder().decode(LocalEventGeoCoordinate.self, from: data)
    }

    private static func providerRemoteObjectURL(
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

    private static func fixedAccessTokenProvider(
        token: String,
        service expectedService: OAuthServiceKind
    ) -> CalendarProviderAccessTokenProvider {
        { _, service, _ in
            guard service == expectedService else {
                throw ProviderSyncRecoveryInvariantError("Expected \(expectedService) token lookup, got \(service)")
            }
            return token
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw ProviderSyncRecoveryInvariantError(message)
        }
    }

    private static let localDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let caldavIncrementalPruneBaseICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//CalDAV Incremental Prune Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:caldav-incremental-changed@example.com
    SEQUENCE:1
    DTSTAMP:20260625T080000Z
    DTSTART:20260701T090000Z
    DTEND:20260701T093000Z
    SUMMARY:CalDAV incremental changed
    X-WORKING-CALENDAR-ID:local-calendar-caldav-test-calendar
    X-WORKING-CALENDAR-TITLE:CalDAV Test
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/changed.ics
    END:VEVENT
    BEGIN:VEVENT
    UID:caldav-incremental-unchanged@example.com
    SEQUENCE:1
    DTSTAMP:20260625T080000Z
    DTSTART:20260701T100000Z
    DTEND:20260701T103000Z
    SUMMARY:CalDAV incremental unchanged
    X-WORKING-CALENDAR-ID:local-calendar-caldav-test-calendar
    X-WORKING-CALENDAR-TITLE:CalDAV Test
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/unchanged.ics
    END:VEVENT
    END:VCALENDAR
    """

    private static let caldavIncrementalChangedObjectICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//CalDAV Incremental Prune Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:caldav-incremental-changed@example.com
    SEQUENCE:2
    DTSTAMP:20260625T081000Z
    DTSTART:20260701T090500Z
    DTEND:20260701T093500Z
    SUMMARY:CalDAV incremental changed updated
    X-WORKING-CALENDAR-ID:local-calendar-caldav-test-calendar
    X-WORKING-CALENDAR-TITLE:CalDAV Test
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/changed.ics
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerReplyBaseEventICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Reply Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:provider-reply-current-user@example.com
    DTSTAMP:20260625T080000Z
    DTSTART:20260701T090000Z
    DTEND:20260701T093000Z
    SUMMARY:Provider reply fixture
    X-WORKING-CALENDAR-ID:local-calendar-caldav-test-calendar
    X-WORKING-CALENDAR-TITLE:CalDAV Test
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/base-object.ics
    X-WORKING-MY-RESPONSE:pending
    ATTENDEE;CN=Me;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;X-WORKING-CURRENT-USER=TRUE:mailto:me@example.com
    ATTENDEE;CN=Teammate;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:teammate@example.com
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerReplyOnlyICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Reply Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REPLY
    BEGIN:VEVENT
    UID:provider-reply-current-user@example.com
    DTSTAMP:20260625T081500Z
    DTSTART:20260701T090000Z
    DTEND:20260701T093000Z
    ATTENDEE;CN=Me;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:me@example.com
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerPartialAttendeesBaseICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Partial Attendees Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:provider-partial-attendees@example.com
    SEQUENCE:1
    DTSTAMP:20260625T080000Z
    DTSTART:20260701T110000Z
    DTEND:20260701T113000Z
    SUMMARY:Provider partial attendees fixture
    X-WORKING-CALENDAR-ID:local-calendar-google-test-calendar
    X-WORKING-CALENDAR-TITLE:Google Test
    X-WORKING-REMOTE-OBJECT-URL:https://google.example.com/calendars/work/partial-attendees
    X-WORKING-MY-RESPONSE:pending
    ATTENDEE;CN=Me;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;X-WORKING-CURRENT-USER=TRUE:mailto:me@example.com
    ATTENDEE;CN=Teammate;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:teammate@example.com
    ATTENDEE;CN=CY-Office-1st-Conference;CUTYPE=RESOURCE;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:cy-office-1st-conference@example.com
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerPartialAttendeesRefreshICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Partial Attendees Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:provider-partial-attendees@example.com
    SEQUENCE:2
    DTSTAMP:20260625T081000Z
    DTSTART:20260701T110000Z
    DTEND:20260701T113000Z
    SUMMARY:Provider partial attendees fixture updated
    CATEGORIES:Google attendees omitted
    X-WORKING-CALENDAR-ID:local-calendar-google-test-calendar
    X-WORKING-CALENDAR-TITLE:Google Test
    X-WORKING-REMOTE-OBJECT-URL:https://google.example.com/calendars/work/partial-attendees
    X-WORKING-MY-RESPONSE:accepted
    ATTENDEE;CN=Me;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;X-WORKING-CURRENT-USER=TRUE:mailto:me@example.com
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerPartialDetachedAttendeesBaseICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Partial Detached Attendees Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:provider-partial-detached-attendees@example.com
    SEQUENCE:1
    DTSTAMP:20260625T080000Z
    DTSTART:20260708T110000Z
    DTEND:20260708T113000Z
    RRULE:FREQ=WEEKLY;COUNT=3
    SUMMARY:Provider partial detached attendees fixture
    X-WORKING-CALENDAR-ID:local-calendar-google-test-calendar
    X-WORKING-CALENDAR-TITLE:Google Test
    X-WORKING-REMOTE-OBJECT-URL:https://google.example.com/calendars/work/partial-detached-master
    X-WORKING-MY-RESPONSE:pending
    ATTENDEE;CN=Me;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;X-WORKING-CURRENT-USER=TRUE:mailto:me@example.com
    ATTENDEE;CN=Teammate;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:teammate@example.com
    ATTENDEE;CN=CY-Office-1st-Conference;CUTYPE=RESOURCE;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:cy-office-1st-conference@example.com
    END:VEVENT
    BEGIN:VEVENT
    UID:provider-partial-detached-attendees@example.com
    RECURRENCE-ID:20260715T110000Z
    SEQUENCE:1
    DTSTAMP:20260625T080000Z
    DTSTART:20260715T120000Z
    DTEND:20260715T123000Z
    SUMMARY:Provider partial detached occurrence moved
    X-WORKING-CALENDAR-ID:local-calendar-google-test-calendar
    X-WORKING-CALENDAR-TITLE:Google Test
    X-WORKING-REMOTE-OBJECT-URL:https://google.example.com/calendars/work/partial-detached-20260715
    X-WORKING-MY-RESPONSE:pending
    ATTENDEE;CN=Me;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;X-WORKING-CURRENT-USER=TRUE:mailto:me@example.com
    ATTENDEE;CN=Teammate;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:teammate@example.com
    ATTENDEE;CN=CY-Office-1st-Conference;CUTYPE=RESOURCE;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:cy-office-1st-conference@example.com
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerPartialDetachedAttendeesRefreshICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Partial Detached Attendees Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:provider-partial-detached-attendees@example.com
    SEQUENCE:2
    DTSTAMP:20260625T081000Z
    DTSTART:20260708T110000Z
    DTEND:20260708T113000Z
    RRULE:FREQ=WEEKLY;COUNT=3
    SUMMARY:Provider partial detached attendees fixture
    X-WORKING-CALENDAR-ID:local-calendar-google-test-calendar
    X-WORKING-CALENDAR-TITLE:Google Test
    X-WORKING-REMOTE-OBJECT-URL:https://google.example.com/calendars/work/partial-detached-master
    X-WORKING-MY-RESPONSE:pending
    ATTENDEE;CN=Me;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;X-WORKING-CURRENT-USER=TRUE:mailto:me@example.com
    ATTENDEE;CN=Teammate;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:teammate@example.com
    ATTENDEE;CN=CY-Office-1st-Conference;CUTYPE=RESOURCE;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:cy-office-1st-conference@example.com
    END:VEVENT
    BEGIN:VEVENT
    UID:provider-partial-detached-attendees@example.com
    RECURRENCE-ID:20260715T110000Z
    SEQUENCE:2
    DTSTAMP:20260625T081000Z
    DTSTART:20260715T120000Z
    DTEND:20260715T123000Z
    SUMMARY:Provider partial detached occurrence updated
    CATEGORIES:Google attendees omitted
    X-WORKING-CALENDAR-ID:local-calendar-google-test-calendar
    X-WORKING-CALENDAR-TITLE:Google Test
    X-WORKING-REMOTE-OBJECT-URL:https://google.example.com/calendars/work/partial-detached-20260715
    X-WORKING-MY-RESPONSE:accepted
    ATTENDEE;CN=Me;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;X-WORKING-CURRENT-USER=TRUE:mailto:me@example.com
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerReplyPendingRefreshHigherSequenceICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Reply Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:provider-reply-current-user@example.com
    SEQUENCE:20
    DTSTAMP:20260625T090000Z
    DTSTART:20260701T090000Z
    DTEND:20260701T093000Z
    SUMMARY:Provider reply fixture organizer update
    X-WORKING-CALENDAR-ID:local-calendar-caldav-test-calendar
    X-WORKING-CALENDAR-TITLE:CalDAV Test
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/base-object.ics
    X-WORKING-MY-RESPONSE:pending
    ATTENDEE;CN=Me;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;X-WORKING-CURRENT-USER=TRUE:mailto:me@example.com
    ATTENDEE;CN=Teammate;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:teammate@example.com
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerRecurringReplyBaseEventICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Recurring Reply Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:provider-recurring-reply-current-user@example.com
    SEQUENCE:1
    DTSTAMP:20260625T080000Z
    DTSTART:20260708T090000Z
    DTEND:20260708T093000Z
    RRULE:FREQ=WEEKLY;COUNT=3
    SUMMARY:Provider recurring reply fixture
    X-WORKING-CALENDAR-ID:local-calendar-caldav-test-calendar
    X-WORKING-CALENDAR-TITLE:CalDAV Test
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/recurring-reply-base-object.ics
    X-WORKING-MY-RESPONSE:pending
    ATTENDEE;CN=Me;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;X-WORKING-CURRENT-USER=TRUE:mailto:me@example.com
    ATTENDEE;CN=Teammate;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:teammate@example.com
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerRecurringReplyPendingRefreshHigherSequenceICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Recurring Reply Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:provider-recurring-reply-current-user@example.com
    SEQUENCE:20
    DTSTAMP:20260625T090000Z
    DTSTART:20260708T090000Z
    DTEND:20260708T093000Z
    RRULE:FREQ=WEEKLY;COUNT=3
    SUMMARY:Provider recurring reply fixture organizer update
    X-WORKING-CALENDAR-ID:local-calendar-caldav-test-calendar
    X-WORKING-CALENDAR-TITLE:CalDAV Test
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/recurring-reply-base-object.ics
    X-WORKING-MY-RESPONSE:pending
    ATTENDEE;CN=Me;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;X-WORKING-CURRENT-USER=TRUE:mailto:me@example.com
    ATTENDEE;CN=Teammate;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:teammate@example.com
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerRequestBaseEventICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Request Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    UID:provider-request-update@example.com
    SEQUENCE:2
    DTSTAMP:20260625T110000Z
    DTSTART:20260703T090000Z
    DTEND:20260703T093000Z
    SUMMARY:Provider REQUEST fixture
    X-WORKING-CALENDAR-ID:local-calendar-caldav-test-calendar
    X-WORKING-CALENDAR-TITLE:CalDAV Test
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/request-base-object.ics
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerRequestUpdateICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Request Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    UID:provider-request-update@example.com
    SEQUENCE:3
    DTSTAMP:20260625T111000Z
    DTSTART:20260703T100000Z
    DTEND:20260703T103000Z
    SUMMARY:Provider REQUEST fixture updated
    X-WORKING-CALENDAR-ID:local-calendar-caldav-test-calendar
    X-WORKING-CALENDAR-TITLE:CalDAV Test
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/request-update-object.ics
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerRequestUpdateProtocolICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Request Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    UID:provider-request-update@example.com
    SEQUENCE:3
    DTSTAMP:20260625T111000Z
    DTSTART:20260703T100000Z
    DTEND:20260703T103000Z
    SUMMARY:Provider REQUEST fixture updated
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerRangePruneRecurringICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Range Prune Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:provider-range-prune-recurring@example.com
    DTSTAMP:20260625T111000Z
    DTSTART:20260705T090000Z
    DTEND:20260705T093000Z
    RRULE:FREQ=WEEKLY;BYDAY=SU
    SUMMARY:Provider range prune recurring fixture
    X-WORKING-CALENDAR-ID:local-calendar-caldav-test-calendar
    X-WORKING-CALENDAR-TITLE:CalDAV Test
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/range-prune-recurring.ics
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerRequestStaleUpdateICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Request Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    UID:provider-request-update@example.com
    SEQUENCE:1
    DTSTAMP:20260625T105000Z
    DTSTART:20260703T080000Z
    DTEND:20260703T083000Z
    SUMMARY:Provider REQUEST fixture stale
    X-WORKING-CALENDAR-ID:local-calendar-caldav-test-calendar
    X-WORKING-CALENDAR-TITLE:CalDAV Test
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/request-stale-object.ics
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerRequestStaleUpdateProtocolICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Request Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    UID:provider-request-update@example.com
    SEQUENCE:1
    DTSTAMP:20260625T105000Z
    DTSTART:20260703T080000Z
    DTEND:20260703T083000Z
    SUMMARY:Provider REQUEST fixture stale
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerOrphanOccurrenceBaseICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Orphan Occurrence Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:provider-orphan-occurrence@example.com
    SEQUENCE:1
    DTSTAMP:20260625T120000Z
    DTSTART:20260706T090000Z
    DTEND:20260706T093000Z
    RRULE:FREQ=WEEKLY;COUNT=3;BYDAY=MO
    SUMMARY:Provider orphan occurrence fixture
    X-WORKING-CALENDAR-ID:local-calendar-caldav-test-calendar
    X-WORKING-CALENDAR-TITLE:CalDAV Test
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/orphan-base-object.ics
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerOrphanOccurrenceUpdateICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Orphan Occurrence Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    UID:provider-orphan-occurrence@example.com
    SEQUENCE:2
    DTSTAMP:20260625T121000Z
    RECURRENCE-ID:20260713T090000Z
    DTSTART:20260713T100000Z
    DTEND:20260713T104500Z
    SUMMARY:Provider orphan occurrence moved
    X-WORKING-CALENDAR-ID:local-calendar-caldav-test-calendar
    X-WORKING-CALENDAR-TITLE:CalDAV Test
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/orphan-occurrence-object.ics
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerOrphanOccurrenceUpdateProtocolICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Orphan Occurrence Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    UID:provider-orphan-occurrence@example.com
    SEQUENCE:2
    DTSTAMP:20260625T121000Z
    RECURRENCE-ID:20260713T090000Z
    DTSTART:20260713T100000Z
    DTEND:20260713T104500Z
    SUMMARY:Provider orphan occurrence moved
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerOrphanFirstOccurrenceICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Orphan First Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    UID:provider-orphan-first@example.com
    SEQUENCE:2
    DTSTAMP:20260625T122000Z
    RECURRENCE-ID:20260810T090000Z
    DTSTART:20260810T100000Z
    DTEND:20260810T104500Z
    SUMMARY:Provider orphan-first occurrence moved
    X-WORKING-CALENDAR-ID:local-calendar-caldav-test-calendar
    X-WORKING-CALENDAR-TITLE:CalDAV Test
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/orphan-first-occurrence.ics
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerOrphanFirstOccurrenceProtocolICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Orphan First Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    UID:provider-orphan-first@example.com
    SEQUENCE:2
    DTSTAMP:20260625T122000Z
    RECURRENCE-ID:20260810T090000Z
    DTSTART:20260810T100000Z
    DTEND:20260810T104500Z
    SUMMARY:Provider orphan-first occurrence moved
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerOrphanFirstBaseSeriesICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Orphan First Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:provider-orphan-first@example.com
    SEQUENCE:1
    DTSTAMP:20260625T121500Z
    DTSTART:20260803T090000Z
    DTEND:20260803T093000Z
    RRULE:FREQ=WEEKLY;COUNT=3;BYDAY=MO
    SUMMARY:Provider orphan-first base fixture
    X-WORKING-CALENDAR-ID:local-calendar-caldav-test-calendar
    X-WORKING-CALENDAR-TITLE:CalDAV Test
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/orphan-first-base.ics
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerOrphanFirstBaseSeriesProtocolICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Orphan First Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:provider-orphan-first@example.com
    SEQUENCE:1
    DTSTAMP:20260625T121500Z
    DTSTART:20260803T090000Z
    DTEND:20260803T093000Z
    RRULE:FREQ=WEEKLY;COUNT=3;BYDAY=MO
    SUMMARY:Provider orphan-first base fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerCancelBaseEventICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Cancel Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:provider-full-cancel@example.com
    DTSTAMP:20260625T090000Z
    DTSTART:20260702T090000Z
    DTEND:20260702T093000Z
    SUMMARY:Provider full cancel fixture
    X-WORKING-CALENDAR-ID:local-calendar-caldav-test-calendar
    X-WORKING-CALENDAR-TITLE:CalDAV Test
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/base-object.ics
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerFullCancelICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Cancel Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:CANCEL
    BEGIN:VEVENT
    UID:provider-full-cancel@example.com
    DTSTAMP:20260625T091500Z
    STATUS:CANCELLED
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerRecurringCancelBaseICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Occurrence Cancel Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:provider-occurrence-cancel@example.com
    DTSTAMP:20260625T100000Z
    DTSTART:20260701T090000Z
    DTEND:20260701T093000Z
    RRULE:FREQ=WEEKLY;UNTIL=20260722T090000Z;BYDAY=WE
    SUMMARY:Provider occurrence cancel fixture
    X-WORKING-CALENDAR-ID:local-calendar-caldav-test-calendar
    X-WORKING-CALENDAR-TITLE:CalDAV Test
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/recurring-object.ics
    END:VEVENT
    BEGIN:VEVENT
    UID:provider-occurrence-cancel@example.com
    RECURRENCE-ID:20260708T090000Z
    DTSTAMP:20260625T101000Z
    DTSTART:20260708T100000Z
    DTEND:20260708T104500Z
    SUMMARY:Provider occurrence cancel fixture moved
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/recurring-object-20260708.ics
    END:VEVENT
    BEGIN:VEVENT
    UID:provider-occurrence-cancel@example.com
    RECURRENCE-ID:20260722T090000Z
    DTSTAMP:20260625T101500Z
    DTSTART:20260722T100000Z
    DTEND:20260722T104500Z
    SUMMARY:Provider occurrence cancel fixture moved later
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/recurring-object-20260722.ics
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerOccurrenceCancelICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Occurrence Cancel Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:CANCEL
    BEGIN:VEVENT
    UID:provider-occurrence-cancel@example.com
    DTSTAMP:20260625T102000Z
    RECURRENCE-ID:20260708T090000Z
    STATUS:CANCELLED
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerAllDayRecurringCancelBaseICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync All-day Occurrence Cancel Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:provider-all-day-occurrence-cancel@example.com
    DTSTAMP:20260625T100000Z
    DTSTART;VALUE=DATE:20260701
    DTEND;VALUE=DATE:20260702
    RRULE:FREQ=WEEKLY;COUNT=3
    SUMMARY:Provider all-day occurrence cancel fixture
    X-WORKING-CALENDAR-ID:local-calendar-caldav-test-calendar
    X-WORKING-CALENDAR-TITLE:CalDAV Test
    X-WORKING-REMOTE-OBJECT-URL:https://caldav.example.com/calendars/work/all-day-recurring-object.ics
    END:VEVENT
    BEGIN:VEVENT
    UID:provider-all-day-occurrence-cancel@example.com
    RECURRENCE-ID;VALUE=DATE:20260708
    DTSTAMP:20260625T101000Z
    DTSTART;VALUE=DATE:20260709
    DTEND;VALUE=DATE:20260710
    SUMMARY:Provider all-day occurrence cancel fixture moved
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerAllDayOccurrenceCancelICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync All-day Occurrence Cancel Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:CANCEL
    BEGIN:VEVENT
    UID:provider-all-day-occurrence-cancel@example.com
    DTSTAMP:20260625T102000Z
    RECURRENCE-ID;VALUE=DATE:20260708
    STATUS:CANCELLED
    END:VEVENT
    END:VCALENDAR
    """

    private static let providerFutureOccurrenceCancelICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//Provider Sync Occurrence Cancel Fixture//EN
    CALSCALE:GREGORIAN
    METHOD:CANCEL
    BEGIN:VEVENT
    UID:provider-occurrence-cancel@example.com
    DTSTAMP:20260625T103000Z
    RECURRENCE-ID;RANGE=THISANDFUTURE:20260715T090000Z
    STATUS:CANCELLED
    END:VEVENT
    END:VCALENDAR
    """
}

private struct ProviderSyncRecoveryInvariantError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private final class ProviderHTTPFixtureTransport: CalendarProviderHTTPTransport {
    struct FixtureResponse {
        let data: Data
        let statusCode: Int
        let headers: [String: String]

        static func json(_ text: String, statusCode: Int = 200, headers: [String: String] = [:]) -> FixtureResponse {
            FixtureResponse(
                data: Data(text.utf8),
                statusCode: statusCode,
                headers: ["Content-Type": "application/json"].merging(headers) { _, new in new }
            )
        }
    }

    private var responses: [FixtureResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [FixtureResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw ProviderSyncRecoveryInvariantError("Unexpected provider HTTP request to \(request.url?.absoluteString ?? "<nil>")")
        }
        let response = responses.removeFirst()
        guard let url = request.url,
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: response.headers
              )
        else {
            throw ProviderSyncRecoveryInvariantError("Could not create provider HTTP fixture response")
        }
        return (response.data, httpResponse)
    }
}
