import Foundation

@main
struct VerifyICSSubscription {
    @MainActor
    static func main() async throws {
        try verifyURLNormalization()
        try verifyWindows1251Decoding()
        try verifyWindows1251AliasDecoding()
        try verifyISOLatinCyrillicDecoding()
        try verifyIANACharsetDecoding()
        try verifyUnknownCharsetUTF8Fallback()
        try verifyConditionalHTTPRequest()
        try await verifyHTTPFetchTransportAndRetryAfter()
        try verifyNotModifiedHTTPResult()
        try verifyHTTPValidatorRecordingPolicy()
        try verifyFeedRefreshIntervalParsing()
        try verifyFeedRefreshIntervalRecordingPolicy()
        try verifyDuplicateSubscriptionURLsReuseExistingSource()
        try verifyAnnotationBridge()
        try verifyCalendarColorBridge()
        try verifyRefreshUpdatesAndPrunesMissingEvents()
        try verifyOwnedRefreshDoesNotCrossAccountPrefix()
        try verifyFreeBusySubscriptionBridge()
        try verifyReplyOnlyRefreshUpdatesExistingEvent()
        print("ICS subscription invariant passed.")
    }

    private static func verifyURLNormalization() throws {
        let webcal = try CalendarURLNormalizer.subscriptionURL(from: "webcals://calendar.example.com/team.ics")
        try expect(webcal.absoluteString == "https://calendar.example.com/team.ics",
                   "webcals:// subscription URLs should normalize to https://")

        let hostOnly = try CalendarURLNormalizer.subscriptionURL(from: "calendar.example.com/team.ics")
        try expect(hostOnly.absoluteString == "https://calendar.example.com/team.ics",
                   "Host-only subscription URLs should default to https://")

        let googleCID = try CalendarURLNormalizer.subscriptionURL(
            from: "https://www.calendar.google.com/calendar/u/0/r?cid=team.calendar%23fixture%40group.v.calendar.google.com"
        )
        try expect(
            googleCID.absoluteString == "https://calendar.google.com/calendar/ical/team.calendar%23fixture%40group.v.calendar.google.com/public/basic.ics",
            "Google public calendar cid links should normalize to the public iCal feed URL"
        )
        let googleShareURL = URL(string: "https://calendar.google.com/calendar/u/0/r?cid=team.calendar%23fixture%40group.v.calendar.google.com")!
        try expect(CalendarURLNormalizer.isLikelySubscriptionURL(googleShareURL),
                   "Google public calendar cid share links should be recognized as subscription URLs")
    }

    private static func verifyWindows1251Decoding() throws {
        let text = fixture(summary: "Планёрка")
        let encoding = try requireEncoding("windows-1251")
        guard let data = text.data(using: encoding) else {
            throw ICSSubscriptionInvariantError("Could not encode Windows-1251 fixture")
        }

        let decoded = CalendarSubscriptionDecoder.text(
            from: data,
            contentType: "text/calendar; charset=\"windows-1251\""
        )
        try expect(decoded?.contains("SUMMARY:Планёрка") == true,
                   "Windows-1251 ICS subscriptions should decode Cyrillic summaries")
    }

    private static func verifyISOLatinCyrillicDecoding() throws {
        let text = fixture(summary: "Синк")
        let encoding = try requireEncoding("iso-8859-5")
        guard let data = text.data(using: encoding) else {
            throw ICSSubscriptionInvariantError("Could not encode ISO-8859-5 fixture")
        }

        let decoded = CalendarSubscriptionDecoder.text(
            from: data,
            contentType: "text/calendar; charset=iso_8859-5"
        )
        try expect(decoded?.contains("SUMMARY:Синк") == true,
                   "ISO-8859-5 ICS subscriptions should decode Cyrillic summaries")
    }

    private static func verifyWindows1251AliasDecoding() throws {
        let text = fixture(summary: "Релиз")
        let encoding = try requireEncoding("windows-1251")
        guard let data = text.data(using: encoding) else {
            throw ICSSubscriptionInvariantError("Could not encode Windows-1251 alias fixture")
        }

        let decoded = CalendarSubscriptionDecoder.text(
            from: data,
            contentType: "text/calendar; charset=cp-1251"
        )
        try expect(decoded?.contains("SUMMARY:Релиз") == true,
                   "CP-1251 charset aliases should decode before Latin-1 fallback can produce mojibake")
    }

    private static func verifyIANACharsetDecoding() throws {
        let text = fixture(summary: "Календарь")
        let encoding = try requireEncoding("koi8-r")
        guard let data = text.data(using: encoding) else {
            throw ICSSubscriptionInvariantError("Could not encode KOI8-R fixture")
        }

        let decoded = CalendarSubscriptionDecoder.text(
            from: data,
            contentType: "text/calendar; charset=koi8-r"
        )
        try expect(decoded?.contains("SUMMARY:Календарь") == true,
                   "IANA charset lookup should decode KOI8-R ICS subscriptions")
    }

    private static func verifyUnknownCharsetUTF8Fallback() throws {
        let text = fixture(summary: "UTF-8 fallback")
        guard let data = text.data(using: .utf8) else {
            throw ICSSubscriptionInvariantError("Could not encode UTF-8 fixture")
        }

        let decoded = CalendarSubscriptionDecoder.text(
            from: data,
            contentType: "text/calendar; charset=x-calendar-fixture"
        )
        try expect(decoded?.contains("SUMMARY:UTF-8 fallback") == true,
                   "Unknown subscription charsets should still fall back to UTF-8")
    }

    private static func verifyConditionalHTTPRequest() throws {
        var account = subscriptionAccount(id: "subscription-http-request-account")
        account.httpETag = "  \"subscription-v1\"  "
        account.httpLastModified = "  Thu, 25 Jun 2026 10:00:00 GMT  "

        let request = try CalendarSubscriptionHTTP.request(for: account)

        try expect(request.url?.absoluteString == "https://calendar.example.com/team.ics",
                   "Subscription HTTP request should use the normalized account endpoint")
        try expect(request.value(forHTTPHeaderField: "User-Agent") == "WorkingCalendar/1.0 (macOS; ICS)",
                   "Subscription HTTP request should identify the app")
        try expect(request.value(forHTTPHeaderField: "Accept") == "text/calendar, text/plain, */*",
                   "Subscription HTTP request should prefer calendar payloads")
        try expect(request.value(forHTTPHeaderField: "Accept-Charset") == "utf-8, utf-16, iso-8859-1",
                   "Subscription HTTP request should advertise readable calendar encodings")
        try expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"subscription-v1\"",
                   "Subscription HTTP request should send stored ETags as conditional validators")
        try expect(request.value(forHTTPHeaderField: "If-Modified-Since") == "Thu, 25 Jun 2026 10:00:00 GMT",
                   "Subscription HTTP request should send stored Last-Modified validators")
    }

    @MainActor
    private static func verifyHTTPFetchTransportAndRetryAfter() async throws {
        var account = subscriptionAccount(id: "subscription-http-fetch-account")
        account.httpETag = "\"subscription-v1\""

        let transport = ICSSubscriptionHTTPFixtureTransport(responses: [
            .text(
                fixture(summary: "Fetched subscription event"),
                statusCode: 200,
                headers: [
                    "Content-Type": "text/calendar; charset=utf-8",
                    "ETag": "\"subscription-v2\"",
                    "Last-Modified": "Thu, 25 Jun 2026 11:00:00 GMT"
                ]
            )
        ])
        let result = try await CalendarSubscriptionHTTP.fetch(account: account, transport: transport)
        let request = try requireOnly(transport.requests, context: "subscription fetch requests")
        try expect(request.url?.absoluteString == "https://calendar.example.com/team.ics",
                   "Subscription fetch transport should receive the normalized feed URL")
        try expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"subscription-v1\"",
                   "Subscription fetch transport should receive conditional validator headers")
        try expect(result.text?.contains("SUMMARY:Fetched subscription event") == true,
                   "Subscription fetch transport should decode the returned iCalendar text")
        try expect(result.eTag == "\"subscription-v2\"",
                   "Subscription fetch transport should expose returned ETag validators")
        try expect(result.lastModified == "Thu, 25 Jun 2026 11:00:00 GMT",
                   "Subscription fetch transport should expose returned Last-Modified validators")

        let retryTransport = ICSSubscriptionHTTPFixtureTransport(responses: [
            .text("", statusCode: 429, headers: ["Retry-After": "120"])
        ])
        do {
            _ = try await CalendarSubscriptionHTTP.fetch(account: account, transport: retryTransport)
            throw ICSSubscriptionInvariantError("Subscription HTTP 429 should surface provider Retry-After")
        } catch CalendarProviderSyncError.retryAfter(let seconds) {
            try expect(seconds == 120, "Subscription HTTP 429 should preserve Retry-After seconds")
        }

        resetProviderStorage()
        let store = CalendarProviderStore()
        let storedAccount = try store.addICSSubscription(
            title: "Retry Fixture",
            urlString: "https://calendar.example.com/retry.ics"
        )
        let now = try date("2026-07-01T09:00:00Z")
        store.recordSyncError(
            accountID: storedAccount.id,
            error: CalendarProviderSyncError.retryAfter(120),
            at: now
        )
        guard let coolingDown = store.accounts.first(where: { $0.id == storedAccount.id }) else {
            throw ICSSubscriptionInvariantError("Missing subscription retry fixture account")
        }
        try expect(coolingDown.syncNotBefore == now.addingTimeInterval(120),
                   "Subscription Retry-After should set an account sync cooldown")
        try expect(!coolingDown.isAutomaticSyncDue(at: now.addingTimeInterval(119)),
                   "Subscription Retry-After should pause automatic sync until the cooldown expires")
        try expect(coolingDown.isAutomaticSyncDue(at: now.addingTimeInterval(120)),
                   "Subscription Retry-After should allow automatic sync after the cooldown expires")
    }

    private static func verifyNotModifiedHTTPResult() throws {
        let url = try CalendarURLNormalizer.subscriptionURL(from: "https://calendar.example.com/team.ics")
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 304,
            httpVersion: "HTTP/1.1",
            headerFields: ["eTaG": " \"subscription-v2\" "]
        ) else {
            throw ICSSubscriptionInvariantError("Could not create 304 response fixture")
        }

        let result = try CalendarSubscriptionHTTP.result(
            data: Data("ignored".utf8),
            response: response
        )

        try expect(result.text == nil,
                   "304 subscription refresh should not produce text to re-import")
        try expect(result.eTag == "\"subscription-v2\"",
                   "304 subscription refresh should still expose returned ETag validators")
        try expect(result.lastModified == nil,
                   "304 subscription refresh should tolerate missing Last-Modified validators")
        try expect(result.preservesMissingValidators,
                   "304 subscription refresh should preserve cached validators that were not returned")
    }

    @MainActor
    private static func verifyHTTPValidatorRecordingPolicy() throws {
        let store = CalendarProviderStore()
        let account = try store.addICSSubscription(
            title: "Validator Fixture",
            urlString: "https://calendar.example.com/team.ics"
        )

        store.recordHTTPValidators(
            accountID: account.id,
            eTag: "\"old\"",
            lastModified: "Thu, 25 Jun 2026 09:00:00 GMT",
            preservesMissing: false
        )
        store.recordHTTPValidators(
            accountID: account.id,
            eTag: "\"new\"",
            lastModified: nil,
            preservesMissing: true
        )

        guard let preserved = store.accounts.first(where: { $0.id == account.id }) else {
            throw ICSSubscriptionInvariantError("Missing validator fixture account")
        }
        try expect(preserved.httpETag == "\"new\"",
                   "Returned subscription ETag should replace the previous validator")
        try expect(preserved.httpLastModified == "Thu, 25 Jun 2026 09:00:00 GMT",
                   "Missing Last-Modified on 304 should preserve the previous validator")

        store.recordHTTPValidators(
            accountID: account.id,
            eTag: nil,
            lastModified: nil,
            preservesMissing: false
        )
        guard let cleared = store.accounts.first(where: { $0.id == account.id }) else {
            throw ICSSubscriptionInvariantError("Missing validator fixture account after clear")
        }
        try expect(cleared.httpETag == nil,
                   "Missing subscription ETag on fresh 2xx responses should clear stale validators")
        try expect(cleared.httpLastModified == nil,
                   "Missing Last-Modified on fresh 2xx responses should clear stale validators")
    }

    @MainActor
    private static func verifyFeedRefreshIntervalParsing() throws {
        let refreshIntervalFixture = """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Subscription TTL Fixture//EN
        REFRESH-INTERVAL;VALUE=DURATION:PT45M
        X-PUBLISHED-TTL:PT2H
        END:VCALENDAR
        """
        try expect(CalendarSubscriptionRefreshInterval.seconds(from: refreshIntervalFixture) == 45 * 60,
                   "Subscription feeds should prefer REFRESH-INTERVAL over X-PUBLISHED-TTL")

        let publishedTTLFixture = """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Subscription TTL Fixture//EN
        X-PUBLISHED-TTL:P1DT30M
        END:VCALENDAR
        """
        try expect(CalendarSubscriptionRefreshInterval.seconds(from: publishedTTLFixture) == (24 * 60 + 30) * 60,
                   "Subscription feeds should parse X-PUBLISHED-TTL day and minute durations")

        let result = try CalendarSubscriptionHTTP.result(
            data: Data(refreshIntervalFixture.utf8),
            response: HTTPURLResponse(
                url: try CalendarURLNormalizer.subscriptionURL(from: "https://calendar.example.com/team.ics"),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/calendar; charset=utf-8"]
            )
        )
        try expect(result.refreshIntervalSeconds == 45 * 60,
                   "Subscription HTTP result should expose feed refresh intervals from decoded text")
        try expect(!result.preservesMissingRefreshInterval,
                   "Fresh subscription payloads should be allowed to clear stale refresh intervals")
    }

    @MainActor
    private static func verifyFeedRefreshIntervalRecordingPolicy() throws {
        let store = CalendarProviderStore()
        let account = try store.addICSSubscription(
            title: "Refresh TTL Fixture",
            urlString: "https://calendar.example.com/ttl.ics"
        )

        let syncedAt = try date("2026-07-01T09:00:00Z")
        store.recordSync(accountID: account.id, summary: emptySummary(), at: syncedAt)
        store.recordICSRefreshInterval(accountID: account.id, seconds: 45 * 60, preservesMissing: false)
        guard let withTTL = store.accounts.first(where: { $0.id == account.id }) else {
            throw ICSSubscriptionInvariantError("Missing refresh interval fixture account")
        }
        try expect(withTTL.icsRefreshIntervalSeconds == 45 * 60,
                   "Subscription refresh interval should be stored on the account")
        try expect(!withTTL.isAutomaticSyncDue(at: syncedAt.addingTimeInterval(44 * 60)),
                   "Automatic sync should respect the feed refresh interval before it is due")
        try expect(withTTL.isAutomaticSyncDue(at: syncedAt.addingTimeInterval(45 * 60)),
                   "Automatic sync should allow the subscription once the feed refresh interval is due")

        store.recordICSRefreshInterval(accountID: account.id, seconds: nil, preservesMissing: true)
        guard let preservedTTL = store.accounts.first(where: { $0.id == account.id }) else {
            throw ICSSubscriptionInvariantError("Missing refresh interval fixture account after preserve")
        }
        try expect(preservedTTL.icsRefreshIntervalSeconds == 45 * 60,
                   "304 subscription refreshes should preserve missing feed refresh intervals")

        store.recordICSRefreshInterval(accountID: account.id, seconds: nil, preservesMissing: false)
        guard let clearedTTL = store.accounts.first(where: { $0.id == account.id }) else {
            throw ICSSubscriptionInvariantError("Missing refresh interval fixture account after clear")
        }
        try expect(clearedTTL.icsRefreshIntervalSeconds == nil,
                   "Fresh subscription payloads without TTL should clear stale refresh intervals")
        try expect(clearedTTL.isAutomaticSyncDue(at: syncedAt.addingTimeInterval(60)),
                   "Subscriptions without feed refresh intervals should follow the global sync cadence")
    }

    @MainActor
    private static func verifyDuplicateSubscriptionURLsReuseExistingSource() throws {
        resetProviderStorage()
        let store = CalendarProviderStore()
        let first = try store.addICSSubscription(
            title: "US Holidays",
            urlString: "https://calendar.google.com/calendar/embed?src=en.usa%23holiday%40group.v.calendar.google.com&ctz=UTC"
        )
        store.setAccount(first, enabled: false)

        let duplicate = try store.addICSSubscription(
            title: "Google Holidays",
            urlString: "https://calendar.google.com/calendar/ical/en.usa%23holiday%40group.v.calendar.google.com/public/basic.ics"
        )

        try expect(store.accounts.count == 1,
                   "Adding the same normalized ICS subscription should reuse the existing provider source")
        try expect(duplicate.id == first.id,
                   "Duplicate subscription add should return the existing provider source")
        try expect(duplicate.enabled,
                   "Duplicate subscription add should re-enable a previously disabled source")
        try expect(duplicate.title == "Google Holidays",
                   "Duplicate subscription add with a non-empty title should refresh the source title")
        try expect(
            duplicate.endpointURLString == "https://calendar.google.com/calendar/ical/en.usa%23holiday%40group.v.calendar.google.com/public/basic.ics",
            "Duplicate subscription source should keep the canonical normalized feed URL"
        )

        let unchangedTitle = try store.addICSSubscription(
            title: "   ",
            urlString: "HTTPS://calendar.google.com/calendar/ical/en.usa%23holiday%40group.v.calendar.google.com/public/basic.ics"
        )
        try expect(store.accounts.count == 1,
                   "Case-only URL differences should still reuse the existing subscription source")
        try expect(unchangedTitle.title == "Google Holidays",
                   "Blank duplicate titles should not erase the existing source title")

        let cidDuplicate = try store.addICSSubscription(
            title: "Google Holidays CID",
            urlString: "https://calendar.google.com/calendar/u/0/r?cid=en.usa%23holiday%40group.v.calendar.google.com"
        )
        try expect(store.accounts.count == 1,
                   "Google cid share links should reuse the same normalized public iCal subscription source")
        try expect(cidDuplicate.id == first.id,
                   "Google cid share duplicate add should return the existing provider source")
        try expect(
            cidDuplicate.endpointURLString == "https://calendar.google.com/calendar/ical/en.usa%23holiday%40group.v.calendar.google.com/public/basic.ics",
            "Google cid share duplicate should keep the canonical public iCal feed URL"
        )
    }

    @MainActor
    private static func verifyAnnotationBridge() throws {
        let account = subscriptionAccount()
        let annotator = CalendarSubscriptionAnnotator()
        let calendarIDPrefix = annotator.calendarIDPrefix(for: account)
        let annotated = annotator.annotatedText(subscriptionBridgeFixture, account: account)

        try expect(annotated.remoteObjectURLs.count == 1,
                   "Subscription annotation should keep one live remote object URL")
        try expect(annotated.cancelledRemoteObjectURLs.count == 1,
                   "Subscription annotation should track cancelled detached remote object URLs")
        try expect(annotated.cancelledOccurrences.count == 1,
                   "Subscription annotation should expose cancelled recurring occurrences")
        try expect(annotated.text.contains("X-WORKING-CALENDAR-ALLOWS-EVENT-WRITE:FALSE"),
                   "ICS subscriptions should import as read-only calendars")
        try expect(annotated.text.contains("X-WORKING-CALENDAR-ALLOWS-RESPONSES:FALSE"),
                   "ICS subscriptions should not expose invite responses")

        let store = LocalCalendarStore()
        store.deleteProviderCalendars(calendarIDPrefix: calendarIDPrefix)
        defer {
            store.deleteProviderCalendars(calendarIDPrefix: calendarIDPrefix)
        }
        let summary = try store.importICSText(annotated.text)
        try expect(summary.calendarsImported == 1, "Subscription sync should import one calendar")
        try expect(summary.eventsImported == 1, "Subscription sync should import the recurring master event")

        let cancelledCount = store.cancelProviderOccurrences(
            calendarIDPrefix: calendarIDPrefix,
            cancellations: annotated.cancelledOccurrences
        )
        try expect(cancelledCount == 1, "Subscription sync should apply the cancelled occurrence to the recurring master")

        guard let calendar = store.calendars.first(where: { $0.id.hasPrefix(calendarIDPrefix) }) else {
            throw ICSSubscriptionInvariantError("Subscription sync should create a local calendar")
        }
        try expect(calendar.id.hasPrefix(calendarIDPrefix),
                   "Subscription calendar IDs should be namespaced by account")
        try expect(calendar.allowsEventWrite == false,
                   "Imported subscription calendar should remain read-only in the store")
        try expect(calendar.allowsResponses == false,
                   "Imported subscription calendar should not allow attendee responses")

        guard let event = store.events.first(where: {
            $0.calendarID == calendar.id && $0.remoteObjectURLString.hasPrefix("ics://\(account.id)/")
        }) else {
            throw ICSSubscriptionInvariantError("Subscription sync should create a local event")
        }
        try expect(event.calendarID == calendar.id,
                   "Subscription event should be linked to the imported subscription calendar")
        try expect(event.remoteObjectURLString.hasPrefix("ics://\(account.id)/"),
                   "Subscription events should keep stable synthetic remote object URLs")
        try expect(event.recurrenceFrequency == .weekly,
                   "Subscription RRULE should survive annotation and import")
        try expect(event.excludedOccurrenceStartDates.contains { sameInstant($0, "2026-07-08T09:00:00Z") },
                   "Cancelled subscription occurrences should become local recurrence exclusions")

        let occurrences = store.events(
            from: try date("2026-07-01T00:00:00Z"),
            to: try date("2026-07-22T00:00:00Z")
        ).filter { $0.calendarID == calendar.id && $0.calendarItemIdentifier == event.id }
        try expect(occurrences.count == 2,
                   "Subscription recurring event should expand without the cancelled occurrence")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-07-01T09:00:00Z") },
                   "Subscription recurring event should keep the first occurrence")
        try expect(occurrences.contains { sameInstant($0.startDate, "2026-07-15T09:00:00Z") },
                   "Subscription recurring event should keep the occurrence after the cancellation")
        try expect(!occurrences.contains { sameInstant($0.startDate, "2026-07-08T09:00:00Z") },
                   "Subscription recurring event should hide the cancelled occurrence")
    }

    @MainActor
    private static func verifyCalendarColorBridge() throws {
        let account = subscriptionAccount(id: "subscription-color-account")
        let annotator = CalendarSubscriptionAnnotator()
        let calendarIDPrefix = annotator.calendarIDPrefix(for: account)
        let store = LocalCalendarStore()
        store.deleteProviderCalendars(calendarIDPrefix: calendarIDPrefix)
        defer {
            store.deleteProviderCalendars(calendarIDPrefix: calendarIDPrefix)
        }

        let annotated = annotator.annotatedText(subscriptionColorFixture, account: account)
        try expect(annotated.text.contains("X-WORKING-CALENDAR-COLOR:#22C55E"),
                   "Subscription annotation should preserve feed-level calendar color")
        let summary = try store.importICSText(annotated.text)
        try expect(summary.calendarsImported == 1, "Subscription color fixture should import one calendar")

        guard let calendar = store.calendars.first(where: { $0.id.hasPrefix(calendarIDPrefix) }) else {
            throw ICSSubscriptionInvariantError("Subscription color sync should create a local calendar")
        }
        try expect(calendar.colorHex == "#22C55E",
                   "Subscription calendar should keep the feed-level X-WR-CALCOLOR")
    }

    @MainActor
    private static func verifyRefreshUpdatesAndPrunesMissingEvents() throws {
        let account = subscriptionAccount(id: "subscription-refresh-account")
        let annotator = CalendarSubscriptionAnnotator()
        let calendarIDPrefix = annotator.calendarIDPrefix(for: account)
        let store = LocalCalendarStore()
        store.deleteProviderCalendars(calendarIDPrefix: calendarIDPrefix)
        defer {
            store.deleteProviderCalendars(calendarIDPrefix: calendarIDPrefix)
        }

        let firstSync = annotator.annotatedText(subscriptionRefreshInitialFixture, account: account)
        try expect(firstSync.remoteObjectURLs.count == 2,
                   "Initial subscription refresh fixture should expose two live remote object URLs")
        let firstSummary = try store.importICSText(firstSync.text)
        try expect(firstSummary.eventsImported == 2,
                   "Initial subscription refresh should import both events")
        try expect(store.pruneProviderEvents(calendarIDPrefix: calendarIDPrefix, keepingRemoteObjectURLs: firstSync.remoteObjectURLs) == 0,
                   "Initial subscription refresh should not prune freshly imported events")

        let firstKeepURL = try requireRemoteObjectURL(
            in: store,
            calendarIDPrefix: calendarIDPrefix,
            uid: "subscription-refresh-keep@example.com"
        )

        let secondSync = annotator.annotatedText(subscriptionRefreshUpdatedFixture, account: account)
        try expect(secondSync.remoteObjectURLs.count == 1,
                   "Updated subscription refresh fixture should expose one live remote object URL")
        try expect(secondSync.remoteObjectURLs.contains(firstKeepURL),
                   "Subscription refresh should keep a stable synthetic URL for the same UID")
        let secondSummary = try store.importICSText(secondSync.text)
        let prunedCount = store.pruneProviderEvents(
            calendarIDPrefix: calendarIDPrefix,
            keepingRemoteObjectURLs: secondSync.remoteObjectURLs
        )

        try expect(secondSummary.eventsUpdated == 1,
                   "Subscription refresh should update the existing event with the same remote object URL")
        try expect(prunedCount == 1,
                   "Subscription refresh should prune events that disappeared from the feed")
        let subscriptionEvents = store.events.filter { $0.calendarID.hasPrefix(calendarIDPrefix) }
        try expect(subscriptionEvents.count == 1,
                   "Subscription refresh should leave exactly one event after prune")
        guard let event = subscriptionEvents.first else {
            throw ICSSubscriptionInvariantError("Subscription refresh should leave an updated event")
        }
        try expect(event.externalUID == "subscription-refresh-keep@example.com",
                   "Subscription refresh should keep the surviving UID")
        try expect(event.title == "Updated subscription meeting",
                   "Subscription refresh should update event fields from the latest feed")
        try expect(event.remoteObjectURLString == firstKeepURL,
                   "Subscription refresh should keep the same synthetic remote object URL after update")
        try expect(!store.events.contains { $0.externalUID == "subscription-refresh-drop@example.com" },
                   "Subscription refresh should remove the event missing from the latest feed")
    }

    @MainActor
    private static func verifyOwnedRefreshDoesNotCrossAccountPrefix() throws {
        let shortAccount = subscriptionAccount(id: "subscription-owned")
        let longAccount = subscriptionAccount(id: "subscription-owned-extra")
        let annotator = CalendarSubscriptionAnnotator()
        let syncer = CalendarSubscriptionSyncer()
        let store = LocalCalendarStore()
        let shortPrefix = annotator.calendarIDPrefix(for: shortAccount)
        let longPrefix = annotator.calendarIDPrefix(for: longAccount)
        store.deleteProviderCalendars(calendarIDPrefix: shortPrefix)
        store.deleteProviderCalendars(calendarIDPrefix: longPrefix)
        defer {
            store.deleteProviderCalendars(calendarIDPrefix: shortPrefix)
            store.deleteProviderCalendars(calendarIDPrefix: longPrefix)
        }

        let shortInitial = singleSubscriptionEventFixture(
            uid: "subscription-owned-drop@example.com",
            summary: "Short account disappearing event"
        )
        let longInitial = singleSubscriptionEventFixture(
            uid: "subscription-owned-extra-keep@example.com",
            summary: "Long account surviving event"
        )
        let shortOwnedCalendarIDs = annotator.annotatedText(shortInitial, account: shortAccount).calendarIDs

        let shortImportSummary = try syncer.sync(text: shortInitial, account: shortAccount, store: store)
        let longImportSummary = try syncer.sync(text: longInitial, account: longAccount, store: store)
        try expect(shortImportSummary.eventsImported == 1,
                   "Expected short owned subscription fixture to import")
        try expect(longImportSummary.eventsImported == 1,
                   "Expected long owned subscription fixture to import")

        let shortUpdated = singleSubscriptionEventFixture(
            uid: "subscription-owned-new@example.com",
            summary: "Short account replacement event"
        )
        let summary = try syncer.sync(
            text: shortUpdated,
            account: shortAccount,
            store: store,
            ownedCalendarIDs: shortOwnedCalendarIDs
        )

        try expect(summary.eventsDeleted == 1,
                   "Owned subscription refresh should prune the disappeared event for that account")
        try expect(!store.events.contains { $0.externalUID == "subscription-owned-drop@example.com" },
                   "Owned subscription refresh should remove the short account's disappeared event")
        try expect(store.events.contains { $0.externalUID == "subscription-owned-extra-keep@example.com" && $0.calendarID.hasPrefix(longPrefix) },
                   "Owned subscription refresh should preserve a longer account-id namespace")
        try expect(store.events.contains { $0.externalUID == "subscription-owned-new@example.com" && $0.calendarID.hasPrefix(shortPrefix) },
                   "Owned subscription refresh should import the short account replacement event")
    }

    @MainActor
    private static func verifyFreeBusySubscriptionBridge() throws {
        let account = subscriptionAccount(id: "subscription-freebusy-account")
        let annotator = CalendarSubscriptionAnnotator()
        let calendarIDPrefix = annotator.calendarIDPrefix(for: account)
        let syncer = CalendarSubscriptionSyncer()
        let store = LocalCalendarStore()
        store.deleteProviderCalendars(calendarIDPrefix: calendarIDPrefix)
        defer {
            store.deleteProviderCalendars(calendarIDPrefix: calendarIDPrefix)
        }

        let firstAnnotation = annotator.annotatedText(subscriptionFreeBusyInitialFixture, account: account)
        try expect(firstAnnotation.remoteObjectURLs.count == 2,
                   "Free/busy subscription annotation should expose one remote object URL per FREEBUSY period")
        try expect(firstAnnotation.text.contains("BEGIN:VFREEBUSY"),
                   "Free/busy subscription annotation should keep the VFREEBUSY component")
        try expect(firstAnnotation.text.contains("X-WORKING-CALENDAR-ALLOWS-EVENT-WRITE:FALSE"),
                   "Free/busy subscription calendars should import as read-only")
        let firstSummary = try syncer.sync(
            text: subscriptionFreeBusyInitialFixture,
            account: account,
            store: store
        )
        try expect(firstSummary.eventsImported == 2,
                   "Initial free/busy subscription sync should import each FREEBUSY period")

        guard let calendar = store.calendars.first(where: { $0.id.hasPrefix(calendarIDPrefix) }) else {
            throw ICSSubscriptionInvariantError("Free/busy subscription sync should create a local calendar")
        }
        try expect(calendar.allowsEventWrite == false,
                   "Free/busy subscription calendar should remain read-only in the store")
        try expect(calendar.allowsResponses == false,
                   "Free/busy subscription calendar should not allow attendee responses")

        let importedFreeBusyEvents = store.events
            .filter { $0.calendarID.hasPrefix(calendarIDPrefix) }
            .sorted { $0.startDate < $1.startDate }
        try expect(importedFreeBusyEvents.count == 2,
                   "Initial free/busy subscription sync should leave two local placeholder events")
        try expect(importedFreeBusyEvents.allSatisfy {
            $0.remoteObjectURLString.hasPrefix("ics://\(account.id)/") && $0.remoteObjectURLString.contains("/freebusy-")
        }, "Free/busy placeholders should keep synthetic period-level remote object URLs")
        try expect(importedFreeBusyEvents.map(\.title) == ["Busy", "Tentative"],
                   "FREEBUSY FBTYPE values should map to readable placeholder titles")
        let survivingURL = importedFreeBusyEvents[0].remoteObjectURLString

        let secondAnnotation = annotator.annotatedText(subscriptionFreeBusyUpdatedFixture, account: account)
        try expect(secondAnnotation.remoteObjectURLs == [survivingURL],
                   "Updated free/busy subscription annotation should keep the surviving period URL stable")
        let secondSummary = try syncer.sync(
            text: subscriptionFreeBusyUpdatedFixture,
            account: account,
            store: store
        )
        try expect(secondSummary.eventsDeleted == 1,
                   "Free/busy subscription refresh should prune periods missing from the latest feed")

        let remainingFreeBusyEvents = store.events.filter { $0.calendarID.hasPrefix(calendarIDPrefix) }
        try expect(remainingFreeBusyEvents.count == 1,
                   "Free/busy subscription refresh should leave only the surviving period")
        try expect(remainingFreeBusyEvents.first?.remoteObjectURLString == survivingURL,
                   "Free/busy subscription refresh should keep the surviving period remote object URL")
        try expect(remainingFreeBusyEvents.first.map { sameInstant($0.startDate, "2026-07-04T10:00:00Z") } == true,
                   "Free/busy subscription refresh should keep the surviving period date")
    }

    @MainActor
    private static func verifyReplyOnlyRefreshUpdatesExistingEvent() throws {
        let account = subscriptionAccount(id: "subscription-reply-account")
        let annotator = CalendarSubscriptionAnnotator()
        let calendarIDPrefix = annotator.calendarIDPrefix(for: account)
        let syncer = CalendarSubscriptionSyncer()
        let store = LocalCalendarStore()
        store.deleteProviderCalendars(calendarIDPrefix: calendarIDPrefix)
        defer {
            store.deleteProviderCalendars(calendarIDPrefix: calendarIDPrefix)
        }

        let initialSummary = try syncer.sync(
            text: subscriptionReplyInitialFixture,
            account: account,
            store: store
        )
        try expect(initialSummary.eventsImported == 1,
                   "Subscription reply fixture should first import the base event")
        let beforeReply = try requireSubscriptionEvent(
            in: store,
            calendarIDPrefix: calendarIDPrefix,
            uid: "subscription-reply@example.com"
        )
        try expect(beforeReply.attendees.contains { $0.email == "teammate@example.com" && $0.status == .pending },
                   "Subscription base event should start with a pending attendee")

        let replySummary = try syncer.sync(
            text: subscriptionReplyOnlyFixture,
            account: account,
            store: store
        )
        try expect(replySummary.eventsImported == 0,
                   "Reply-only subscription refresh should not import a synthetic event")
        try expect(replySummary.eventsUpdated == 1,
                   "Reply-only subscription refresh should update the existing event")
        try expect(replySummary.eventsDeleted == 0,
                   "Reply-only subscription refresh should not prune existing events")

        let subscriptionEvents = store.events.filter { $0.calendarID.hasPrefix(calendarIDPrefix) }
        try expect(subscriptionEvents.count == 1,
                   "Reply-only subscription refresh should keep the existing event")
        let repliedEvent = try requireSubscriptionEvent(
            in: store,
            calendarIDPrefix: calendarIDPrefix,
            uid: "subscription-reply@example.com"
        )
        try expect(repliedEvent.attendees.contains { $0.email == "teammate@example.com" && $0.status == .accepted },
                   "Reply-only subscription refresh should apply the attendee PARTSTAT")
    }

    private static func fixture(summary: String) -> String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Subscription Fixture//EN
        CALSCALE:GREGORIAN
        BEGIN:VEVENT
        UID:subscription-fixture@example.com
        DTSTAMP:20260625T110000Z
        DTSTART:20260701T090000Z
        DTEND:20260701T093000Z
        SUMMARY:\(summary)
        END:VEVENT
        END:VCALENDAR
        """
    }

    private static func singleSubscriptionEventFixture(uid: String, summary: String) -> String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Owned Subscription Fixture//EN
        CALSCALE:GREGORIAN
        BEGIN:VEVENT
        UID:\(uid)
        DTSTAMP:20260625T110000Z
        DTSTART:20260701T100000Z
        DTEND:20260701T103000Z
        SUMMARY:\(summary)
        END:VEVENT
        END:VCALENDAR
        """
    }

    private static var subscriptionBridgeFixture: String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Subscription Bridge Fixture//EN
        CALSCALE:GREGORIAN
        BEGIN:VEVENT
        UID:subscription-series@example.com
        DTSTAMP:20260625T110000Z
        DTSTART:20260701T090000Z
        DTEND:20260701T093000Z
        RRULE:FREQ=WEEKLY;COUNT=3
        SUMMARY:Subscription recurring fixture
        END:VEVENT
        BEGIN:VEVENT
        UID:subscription-series@example.com
        DTSTAMP:20260625T110500Z
        RECURRENCE-ID:20260708T090000Z
        DTSTART:20260708T090000Z
        DTEND:20260708T093000Z
        STATUS:CANCELLED
        SUMMARY:Subscription recurring fixture
        END:VEVENT
        END:VCALENDAR
        """
    }

    private static var subscriptionRefreshInitialFixture: String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Subscription Refresh Fixture//EN
        CALSCALE:GREGORIAN
        BEGIN:VEVENT
        UID:subscription-refresh-keep@example.com
        DTSTAMP:20260625T110000Z
        DTSTART:20260701T100000Z
        DTEND:20260701T103000Z
        SUMMARY:Original subscription meeting
        END:VEVENT
        BEGIN:VEVENT
        UID:subscription-refresh-drop@example.com
        DTSTAMP:20260625T110000Z
        DTSTART:20260701T110000Z
        DTEND:20260701T113000Z
        SUMMARY:Deleted subscription meeting
        END:VEVENT
        END:VCALENDAR
        """
    }

    private static var subscriptionColorFixture: String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Subscription Color Fixture//EN
        CALSCALE:GREGORIAN
        X-WR-CALCOLOR:#22C55E
        BEGIN:VEVENT
        UID:subscription-color@example.com
        DTSTAMP:20260625T110000Z
        DTSTART:20260702T100000Z
        DTEND:20260702T103000Z
        SUMMARY:Color subscription meeting
        END:VEVENT
        END:VCALENDAR
        """
    }

    private static var subscriptionRefreshUpdatedFixture: String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Subscription Refresh Fixture//EN
        CALSCALE:GREGORIAN
        BEGIN:VEVENT
        UID:subscription-refresh-keep@example.com
        DTSTAMP:20260625T120000Z
        LAST-MODIFIED:20260625T120000Z
        SEQUENCE:1
        DTSTART:20260701T100000Z
        DTEND:20260701T104500Z
        SUMMARY:Updated subscription meeting
        END:VEVENT
        END:VCALENDAR
        """
    }

    private static var subscriptionFreeBusyInitialFixture: String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Subscription Freebusy Fixture//EN
        CALSCALE:GREGORIAN
        X-WR-CALCOLOR:#0EA5E9
        BEGIN:VFREEBUSY
        UID:subscription-freebusy@example.com
        DTSTAMP:20260625T110000Z
        ORGANIZER;CN=Ops:mailto:ops@example.com
        FREEBUSY;FBTYPE=BUSY:20260704T100000Z/20260704T103000Z
        FREEBUSY;FBTYPE=BUSY-TENTATIVE:20260704T110000Z/20260704T113000Z
        END:VFREEBUSY
        END:VCALENDAR
        """
    }

    private static var subscriptionFreeBusyUpdatedFixture: String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Subscription Freebusy Fixture//EN
        CALSCALE:GREGORIAN
        X-WR-CALCOLOR:#0EA5E9
        BEGIN:VFREEBUSY
        UID:subscription-freebusy@example.com
        DTSTAMP:20260625T120000Z
        ORGANIZER;CN=Ops:mailto:ops@example.com
        FREEBUSY;FBTYPE=BUSY:20260704T100000Z/20260704T103000Z
        END:VFREEBUSY
        END:VCALENDAR
        """
    }

    private static var subscriptionReplyInitialFixture: String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Subscription Reply Fixture//EN
        CALSCALE:GREGORIAN
        METHOD:PUBLISH
        BEGIN:VEVENT
        UID:subscription-reply@example.com
        DTSTAMP:20260625T110000Z
        DTSTART:20260703T100000Z
        DTEND:20260703T103000Z
        SUMMARY:Subscription reply target
        ORGANIZER;CN=Owner:mailto:owner@example.com
        ATTENDEE;CN=Teammate;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:teammate@example.com
        END:VEVENT
        END:VCALENDAR
        """
    }

    private static var subscriptionReplyOnlyFixture: String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Subscription Reply Fixture//EN
        CALSCALE:GREGORIAN
        METHOD:REPLY
        BEGIN:VEVENT
        UID:subscription-reply@example.com
        DTSTAMP:20260625T111000Z
        ATTENDEE;CN=Teammate;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:teammate@example.com
        END:VEVENT
        END:VCALENDAR
        """
    }

    private static func subscriptionAccount() -> CalendarProviderAccount {
        subscriptionAccount(id: "subscription-fixture-account")
    }

    private static func subscriptionAccount(id: String) -> CalendarProviderAccount {
        let now = Date(timeIntervalSince1970: 1_782_394_400)
        return CalendarProviderAccount(
            id: id,
            kind: .icsSubscription,
            title: "Fixture Subscription",
            endpointURLString: "https://calendar.example.com/team.ics",
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
    }

    @MainActor
    private static func requireRemoteObjectURL(
        in store: LocalCalendarStore,
        calendarIDPrefix: String,
        uid: String
    ) throws -> String {
        guard let event = store.events.first(where: {
            $0.calendarID.hasPrefix(calendarIDPrefix) && $0.externalUID == uid
        }) else {
            throw ICSSubscriptionInvariantError("Missing subscription event with UID \(uid)")
        }
        return event.remoteObjectURLString
    }

    @MainActor
    private static func requireSubscriptionEvent(
        in store: LocalCalendarStore,
        calendarIDPrefix: String,
        uid: String
    ) throws -> LocalCalendarEvent {
        guard let event = store.events.first(where: {
            $0.calendarID.hasPrefix(calendarIDPrefix) && $0.externalUID == uid
        }) else {
            throw ICSSubscriptionInvariantError("Missing subscription event with UID \(uid)")
        }
        return event
    }

    private static func requireEncoding(_ charset: String) throws -> String.Encoding {
        guard let encoding = CalendarSubscriptionDecoder.stringEncoding(forCharset: charset) else {
            throw ICSSubscriptionInvariantError("Missing encoding for \(charset)")
        }
        return encoding
    }

    private static func requireOnly<T>(_ values: [T], context: String) throws -> T {
        guard values.count == 1, let value = values.first else {
            throw ICSSubscriptionInvariantError("Expected one \(context), got \(values.count)")
        }
        return value
    }

    private static func resetProviderStorage() {
        UserDefaults.standard.removeObject(forKey: "calendarProviderAccounts")
        UserDefaults.standard.removeObject(forKey: "calendarProviderOutbox")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw ICSSubscriptionInvariantError(message)
        }
    }

    private static func sameInstant(_ lhs: Date, _ rhs: String) -> Bool {
        guard let rhsDate = ISO8601DateFormatter().date(from: rhs) else { return false }
        return abs(lhs.timeIntervalSince(rhsDate)) < 0.5
    }

    private static func date(_ value: String) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            throw ICSSubscriptionInvariantError("Could not parse date fixture \(value)")
        }
        return date
    }

    private static func emptySummary() -> LocalICSImportSummary {
        LocalICSImportSummary(
            calendarsImported: 0,
            eventsImported: 0,
            eventsUpdated: 0,
            eventsSkipped: 0
        )
    }
}

private struct ICSSubscriptionInvariantError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private final class ICSSubscriptionHTTPFixtureTransport: CalendarSubscriptionHTTPTransport {
    struct FixtureResponse {
        let data: Data
        let statusCode: Int
        let headers: [String: String]

        static func text(_ text: String, statusCode: Int, headers: [String: String] = [:]) -> FixtureResponse {
            FixtureResponse(data: Data(text.utf8), statusCode: statusCode, headers: headers)
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
            throw ICSSubscriptionInvariantError("Unexpected subscription HTTP request to \(request.url?.absoluteString ?? "<nil>")")
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
            throw ICSSubscriptionInvariantError("Could not create subscription HTTP fixture response")
        }
        return (response.data, httpResponse)
    }
}
