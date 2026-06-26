import Foundation

@main
struct VerifyCalDAVDiscovery {
    private typealias DAVPreviewResponse = (
        href: String,
        statusCode: Int?,
        properties: [String: String],
        privileges: Set<String>,
        allowsEventWrite: Bool,
        allowsResponses: Bool,
        supportsEvents: Bool
    )

    static func main() async throws {
        try verifyURLNormalization()
        try verifyDAVRedirectPolicy()
        try verifyCalDAVAuthenticationChallengePolicy()
        try verifyDiscoveryCandidates()
        try verifyDAVPropstatStatusParsing()
        try verifyDAVCalendarColorParsing()
        try verifyDAVCalendarTimezoneParsing()
        try verifyDAVCalendarPrivilegeParsing()
        try verifyDAVSupportedCalendarDataParsing()
        try verifyDAVMixedPropstatStatusDoesNotMaskCalendarData()
        try verifyDAVIncrementalSyncTreatsGoneAsDeleted()
        try verifyDAVIncrementalMultigetRaceTreatsGoneAsDeleted()
        try verifyDAVCalendarUserAddressSetParsing()
        try verifyDAVMultipleCalendarHomeSetParsing()
        try verifyDAVMultipleHomeCalendarAggregation()
        try verifyDAVScheduleOutboxURLParsing()
        try verifyAnnotatedICSMetadataBridge()
        try verifyAnnotatedICSMatchesSMTPAccountIdentity()
        try verifyAnnotatedICSUsesCollectionTimezoneForFloatingTimes()
        try await verifyCalDAVHTTPWriteFlow()
        print("CalDAV discovery invariant passed.")
    }

    private static func verifyURLNormalization() throws {
        let hostOnly = try CalendarURLNormalizer.httpURL(from: "cloud.example.com")
        try expect(hostOnly.scheme == "https", "Host-only CalDAV URLs should default to https")
        try expect(hostOnly.host == "cloud.example.com", "Host-only CalDAV URL should preserve the host")

        let secureCalDAV = try CalendarURLNormalizer.httpURL(from: "caldavs://cloud.example.com/remote.php/dav")
        try expect(secureCalDAV.absoluteString == "https://cloud.example.com/remote.php/dav",
                   "caldavs:// should normalize to https://")

        let plainCalDAV = try CalendarURLNormalizer.httpURL(from: "caldav://calendar.example.com/dav.php/")
        try expect(plainCalDAV.absoluteString == "http://calendar.example.com/dav.php/",
                   "caldav:// should normalize to http://")

        let webcal = try CalendarURLNormalizer.subscriptionURL(from: "webcal://calendar.example.com/team.ics")
        try expect(webcal.absoluteString == "https://calendar.example.com/team.ics",
                   "webcal:// should normalize to https://")
        let googleEmbed = try CalendarURLNormalizer.subscriptionURL(
            from: "https://calendar.google.com/calendar/embed?src=en.usa%23holiday%40group.v.calendar.google.com&ctz=UTC"
        )
        try expect(
            googleEmbed.absoluteString == "https://calendar.google.com/calendar/ical/en.usa%23holiday%40group.v.calendar.google.com/public/basic.ics",
            "Google Calendar embed URLs should normalize to the public iCal feed"
        )
        let googleCID = try CalendarURLNormalizer.subscriptionURL(
            from: "https://calendar.google.com/calendar/u/0?cid=team%40example.com"
        )
        try expect(
            googleCID.absoluteString == "https://calendar.google.com/calendar/ical/team%40example.com/public/basic.ics",
            "Google Calendar cid share URLs should normalize to the public iCal feed"
        )
        let icsURL = try requireURL("https://calendar.example.com/team.ics")
        let icalURL = try requireURL("https://calendar.example.com/team.ical")
        let icalendarURL = try requireURL("https://calendar.example.com/team.icalendar")
        let freeBusyURL = try requireURL("https://calendar.example.com/freebusy.ifb")
        let webcalsURL = try requireURL("webcals://calendar.example.com/team")
        let googleEmbedURL = try requireURL("https://calendar.google.com/calendar/embed?src=team%40example.com")
        let googlePlainURL = try requireURL("https://calendar.google.com/calendar/u/0")
        let webPageURL = try requireURL("https://calendar.example.com/team.html")
        let ftpCalendarURL = try requireURL("ftp://calendar.example.com/team.ics")
        try expect(CalendarURLNormalizer.isLikelySubscriptionURL(icsURL),
                   "External .ics links should be recognized as calendar subscriptions")
        try expect(CalendarURLNormalizer.isLikelySubscriptionURL(icalURL),
                   "External .ical links should be recognized as calendar subscriptions")
        try expect(CalendarURLNormalizer.isLikelySubscriptionURL(icalendarURL),
                   "External .icalendar links should be recognized as calendar subscriptions")
        try expect(CalendarURLNormalizer.isLikelySubscriptionURL(freeBusyURL),
                   "External .ifb free/busy links should be recognized as calendar subscriptions")
        try expect(CalendarURLNormalizer.isLikelySubscriptionURL(webcalsURL),
                   "webcals:// links should be recognized even without a calendar file extension")
        try expect(CalendarURLNormalizer.isLikelySubscriptionURL(googleEmbedURL),
                   "Google Calendar embed links with src should be recognized as calendar subscriptions")
        try expect(!CalendarURLNormalizer.isLikelySubscriptionURL(googlePlainURL),
                   "Google Calendar pages without a calendar id should not be treated as subscriptions")
        try expect(!CalendarURLNormalizer.isLikelySubscriptionURL(webPageURL),
                   "Plain web pages should not be treated as calendar subscriptions")
        try expect(!CalendarURLNormalizer.isLikelySubscriptionURL(ftpCalendarURL),
                   "Unsupported URL schemes should not be treated as calendar subscriptions")

        do {
            _ = try CalendarURLNormalizer.httpURL(from: "ftp://calendar.example.com/")
            throw CalDAVDiscoveryInvariantError("Unsupported CalDAV schemes must fail")
        } catch CalendarURLNormalizerError.unsupportedURLScheme {
            // Expected.
        }
    }

    private static func verifyDAVRedirectPolicy() throws {
        let client = CalDAVClient()
        let source = try requireURL("https://example.com/.well-known/caldav")
        let sameHost = try requireURL("https://example.com/dav/")
        let caldavSubdomain = try requireURL("https://caldav.example.com/dav/")
        let wwwSource = try requireURL("https://www.example.com/.well-known/caldav")
        let apexTarget = try requireURL("https://example.com/dav/")
        let downgrade = try requireURL("http://caldav.example.com/dav/")
        let unrelated = try requireURL("https://calendar.example.net/dav/")
        try expect(
            client.redirectAllowedPreview(from: source, to: sameHost),
            "CalDAV redirects should allow same-host discovery targets"
        )
        try expect(
            client.redirectAllowedPreview(from: source, to: caldavSubdomain),
            "CalDAV redirects should allow canonical CalDAV subdomains for the same account domain"
        )
        try expect(
            client.redirectAllowedPreview(from: wwwSource, to: apexTarget),
            "CalDAV redirects should allow www-to-apex canonicalization"
        )
        try expect(
            !client.redirectAllowedPreview(from: source, to: downgrade),
            "CalDAV redirects should reject https-to-http downgrades"
        )
        try expect(
            !client.redirectAllowedPreview(from: source, to: unrelated),
            "CalDAV redirects should reject unrelated cross-host targets"
        )
    }

    private static func verifyCalDAVAuthenticationChallengePolicy() throws {
        try expect(
            CalDAVAuthenticationPolicy.disposition(
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
                previousFailureCount: 0
            ) == .useCredential,
            "CalDAV Basic auth challenges should use the stored account credential"
        )
        try expect(
            CalDAVAuthenticationPolicy.disposition(
                authenticationMethod: NSURLAuthenticationMethodHTTPDigest,
                previousFailureCount: 0
            ) == .useCredential,
            "CalDAV Digest auth challenges should use the stored account credential"
        )
        try expect(
            CalDAVAuthenticationPolicy.disposition(
                authenticationMethod: NSURLAuthenticationMethodDefault,
                previousFailureCount: 0
            ) == .useCredential,
            "CalDAV default auth challenges should use the stored account credential"
        )
        try expect(
            CalDAVAuthenticationPolicy.disposition(
                authenticationMethod: NSURLAuthenticationMethodHTTPDigest,
                previousFailureCount: 1
            ) == .rejectProtectionSpace,
            "Repeated CalDAV auth failures should reject the protection space instead of looping"
        )
        try expect(
            CalDAVAuthenticationPolicy.disposition(
                authenticationMethod: NSURLAuthenticationMethodServerTrust,
                previousFailureCount: 0
            ) == .performDefaultHandling,
            "CalDAV should leave non-password auth challenges to URLSession default handling"
        )
    }

    private static func verifyDiscoveryCandidates() throws {
        let rootURL = try requireURL("https://cloud.example.com/")
        let rootCandidates = CalDAVDiscovery.rootCandidates(for: rootURL).map(\.absoluteString)
        try expect(rootCandidates == [
            "https://cloud.example.com/",
            "https://cloud.example.com/.well-known/caldav",
            "https://cloud.example.com/remote.php/dav/",
            "https://cloud.example.com/remote.php/caldav/",
            "https://cloud.example.com/dav.php/",
            "https://cloud.example.com/html/dav.php/",
            "https://cloud.example.com/dav/",
            "https://cloud.example.com/caldav/"
        ], "Root URL discovery candidates should include standard and common CalDAV entrypoints without duplicates")

        let directURL = try requireURL("https://cloud.example.com/custom/calendars/")
        let directCandidates = CalDAVDiscovery.rootCandidates(for: directURL).map(\.absoluteString)
        try expect(directCandidates.prefix(3) == [
            "https://cloud.example.com/custom/calendars/",
            "https://cloud.example.com/.well-known/caldav",
            "https://cloud.example.com/"
        ], "Specific CalDAV URLs should be tried before origin-level discovery")

        let iCloudCandidates = CalDAVDiscovery.rootCandidates(for: try requireURL("https://icloud.com/")).map(\.absoluteString)
        try expect(iCloudCandidates.prefix(4) == [
            "https://icloud.com/",
            "https://caldav.icloud.com/",
            "https://caldav.icloud.com/.well-known/caldav",
            "https://caldav.icloud.com/remote.php/dav/"
        ], "iCloud marketing host should add canonical CalDAV discovery candidates before generic origin probing")

        let fastmailCandidates = CalDAVDiscovery.rootCandidates(for: try requireURL("https://fastmail.com/")).map(\.absoluteString)
        try expect(fastmailCandidates.contains("https://caldav.fastmail.com/"),
                   "Fastmail host should add the canonical CalDAV root")
        try expect(fastmailCandidates.contains("https://caldav.fastmail.com/dav/"),
                   "Fastmail host should also try common DAV paths on the canonical CalDAV host")

        let yahooCandidates = CalDAVDiscovery.rootCandidates(for: try requireURL("https://calendar.yahoo.com/")).map(\.absoluteString)
        try expect(yahooCandidates.contains("https://caldav.calendar.yahoo.com/"),
                   "Yahoo calendar host should add the canonical CalDAV root")
        try expect(yahooCandidates.contains("https://caldav.calendar.yahoo.com/.well-known/caldav"),
                   "Yahoo calendar host should try well-known discovery on the canonical CalDAV host")
        try expect(Set(yahooCandidates).count == yahooCandidates.count,
                   "Provider CalDAV discovery candidates should not contain duplicates")
    }

    private static func verifyDAVPropstatStatusParsing() throws {
        let responses = try CalDAVClient().parsedDAVXMLPreview(from: propstatDeletedObjectXML)
        guard responses.count == 1, let response = responses.first else {
            throw CalDAVDiscoveryInvariantError("Expected one DAV response in propstat status fixture")
        }
        try expect(response.href == "/dav/calendars/me/work/deleted.ics",
                   "DAV parser should preserve the deleted object href")
        try expect(response.statusCode == 404,
                   "DAV parser should treat propstat 404 as the response status when no direct response status exists")
    }

    private static func verifyDAVCalendarColorParsing() throws {
        let responses = try CalDAVClient().parsedDAVXMLPreview(from: calendarColorXML)
        guard responses.count == 1, let response = responses.first else {
            throw CalDAVDiscoveryInvariantError("Expected one DAV response in calendar color fixture")
        }
        try expect(response.properties["displayname"] == "Work",
                   "DAV parser should preserve the calendar display name")
        try expect(response.properties["calendar-color"] == "#14B8A6FF",
                   "DAV parser should preserve namespaced calendar-color including alpha")
        try expect(response.properties["getctag"] == "\"color-ctag\"",
                   "DAV parser should preserve calendar ctag next to calendar-color")
    }

    private static func verifyDAVCalendarTimezoneParsing() throws {
        let client = CalDAVClient()
        let responses = try client.parsedDAVXMLPreview(from: calendarTimezoneXML)
        guard responses.count == 1, let response = responses.first else {
            throw CalDAVDiscoveryInvariantError("Expected one DAV response in calendar timezone fixture")
        }

        try expect(response.properties["calendar-timezone"]?.contains("X-LIC-LOCATION:America/New_York") == true,
                   "DAV parser should preserve collection calendar-timezone text")
        let timeZoneIdentifier = try client.calendarTimeZoneIdentifierPreview(from: calendarTimezoneXML)
        try expect(timeZoneIdentifier == "America/New_York",
                   "CalDAV discovery should resolve collection calendar-timezone X-LIC-LOCATION to an IANA timezone")
    }

    private static func verifyDAVCalendarPrivilegeParsing() throws {
        let responses = try CalDAVClient().parsedDAVXMLPreview(from: calendarPrivilegeXML)
        try expect(responses.count == 9, "Expected nine DAV privilege fixture responses")

        let readOnly = try requireResponse(responses, href: "/dav/calendars/me/readonly/")
        try expect(readOnly.supportsEvents, "Read-only calendar should still support VEVENT")
        try expect(readOnly.privileges == ["read"], "DAV parser should preserve read-only privileges")
        try expect(!readOnly.allowsEventWrite, "Read-only calendar should not allow event write")
        try expect(!readOnly.allowsResponses, "Read-only calendar should not allow response write-back")

        let bindOnly = try requireResponse(responses, href: "/dav/calendars/me/bind-only/")
        try expect(bindOnly.privileges == ["read", "bind"], "DAV parser should preserve bind-only privileges")
        try expect(!bindOnly.allowsEventWrite, "Bind-only privilege is not enough to edit existing event content")
        try expect(!bindOnly.allowsResponses, "Bind-only privilege is not enough to send RSVP replies")

        let writable = try requireResponse(responses, href: "/dav/calendars/me/writable/")
        try expect(writable.privileges.contains("write-content"), "DAV parser should preserve write-content privilege")
        try expect(writable.allowsEventWrite, "write-content should allow event write-back")
        try expect(writable.allowsResponses, "write-content should allow RSVP write-back through event updates")

        let mixedComponents = try requireResponse(responses, href: "/dav/calendars/me/mixed-components/")
        try expect(mixedComponents.supportsEvents, "VEVENT+VTODO calendars should still support VEVENT imports")
        try expect(mixedComponents.allowsEventWrite, "VEVENT+VTODO calendars should keep event write-back when writable")
        try expect(mixedComponents.allowsResponses, "VEVENT+VTODO calendars should keep RSVP write-back when writable")

        let scheduleReply = try requireResponse(responses, href: "/dav/calendars/me/schedule-reply/")
        try expect(scheduleReply.privileges.contains("schedule-send-reply"), "DAV parser should preserve schedule-send-reply privilege")
        try expect(!scheduleReply.allowsEventWrite, "schedule-send-reply should not imply direct event content write-back")
        try expect(scheduleReply.allowsResponses, "schedule-send-reply should allow RSVP write-back through the scheduling outbox")

        let tasksOnly = try requireResponse(responses, href: "/dav/calendars/me/tasks/")
        try expect(!tasksOnly.supportsEvents, "VTODO-only calendar should not support VEVENT")
        try expect(!tasksOnly.allowsEventWrite, "VTODO-only calendar should not be treated as an editable event calendar")
        try expect(!tasksOnly.allowsResponses, "VTODO-only calendar should not allow RSVP write-back")

        let freeBusyOnly = try requireResponse(responses, href: "/dav/calendars/me/freebusy/")
        try expect(!freeBusyOnly.supportsEvents, "VFREEBUSY-only calendar should not support editable VEVENT imports")
        try expect(!freeBusyOnly.allowsEventWrite, "VFREEBUSY-only calendar should not allow event write-back")
        try expect(!freeBusyOnly.allowsResponses, "VFREEBUSY-only calendar should not allow RSVP write-back")

        let timezoneOnly = try requireResponse(responses, href: "/dav/calendars/me/timezones/")
        try expect(!timezoneOnly.supportsEvents, "VTIMEZONE-only collection should not support editable VEVENT imports")
        try expect(!timezoneOnly.allowsEventWrite, "VTIMEZONE-only collection should not allow event write-back")
        try expect(!timezoneOnly.allowsResponses, "VTIMEZONE-only collection should not allow RSVP write-back")

        let emptyComponents = try requireResponse(responses, href: "/dav/calendars/me/empty-components/")
        try expect(!emptyComponents.supportsEvents, "Empty supported-calendar-component-set should not imply VEVENT support")
        try expect(!emptyComponents.allowsEventWrite, "Empty supported-calendar-component-set should not allow event write-back")
        try expect(!emptyComponents.allowsResponses, "Empty supported-calendar-component-set should not allow RSVP write-back")
    }

    private static func verifyDAVSupportedCalendarDataParsing() throws {
        let responses = try CalDAVClient().parsedDAVXMLPreview(from: supportedCalendarDataXML)
        try expect(responses.count == 5, "Expected five DAV supported-calendar-data fixture responses")

        let iCalendar20 = try requireResponse(responses, href: "/dav/calendars/me/icalendar20/")
        try expect(iCalendar20.supportsEvents, "text/calendar 2.0 collections should support VEVENT imports")
        try expect(iCalendar20.allowsEventWrite, "text/calendar 2.0 collections should remain writable when privileges allow it")

        let parameterizedICalendar20 = try requireResponse(responses, href: "/dav/calendars/me/icalendar20-charset/")
        try expect(parameterizedICalendar20.supportsEvents,
                   "text/calendar with content-type parameters should support VEVENT imports")
        try expect(parameterizedICalendar20.allowsEventWrite,
                   "text/calendar with content-type parameters should remain writable when privileges allow it")

        let jsonOnly = try requireResponse(responses, href: "/dav/calendars/me/json-only/")
        try expect(!jsonOnly.supportsEvents, "Non-iCalendar calendar-data collections should not be treated as event calendars")
        try expect(!jsonOnly.allowsEventWrite, "Non-iCalendar calendar-data collections should not allow event write-back")

        let emptyCalendarData = try requireResponse(responses, href: "/dav/calendars/me/empty-calendar-data/")
        try expect(!emptyCalendarData.supportsEvents, "Empty supported-calendar-data should not imply iCalendar support")
        try expect(!emptyCalendarData.allowsEventWrite, "Empty supported-calendar-data should not allow event write-back")
        try expect(!emptyCalendarData.allowsResponses, "Empty supported-calendar-data should not allow RSVP write-back")

        let oldVersion = try requireResponse(responses, href: "/dav/calendars/me/icalendar10/")
        try expect(!oldVersion.supportsEvents, "Unsupported iCalendar versions should not be treated as event calendars")
        try expect(!oldVersion.allowsResponses, "Unsupported iCalendar versions should not allow RSVP write-back")
    }

    private static func verifyDAVMixedPropstatStatusDoesNotMaskCalendarData() throws {
        let responses = try CalDAVClient().parsedDAVXMLPreview(from: mixedPropstatCalendarDataXML)
        guard responses.count == 1, let response = responses.first else {
            throw CalDAVDiscoveryInvariantError("Expected one DAV response in mixed propstat fixture")
        }
        try expect(response.href == "/dav/calendars/me/work/live.ics",
                   "DAV parser should preserve the live object href")
        try expect(response.statusCode == 200,
                   "DAV parser should let successful propstat calendar-data win over unrelated missing properties")
        try expect(response.properties["getetag"] == "\"live-etag\"",
                   "DAV parser should preserve getetag from the successful propstat")
        try expect(response.properties["calendar-data"]?.contains("UID:live-caldav@example.com") == true,
                   "DAV parser should preserve calendar-data from the successful propstat")
    }

    private static func verifyDAVIncrementalSyncTreatsGoneAsDeleted() throws {
        let calendarHref = try requireURL("https://caldav.example.com/dav/calendars/me/work/")
        let preview = try CalDAVClient().incrementalDAVSyncPreview(
            from: incrementalGoneSyncXML,
            calendarHref: calendarHref
        )

        try expect(preview.objects == ["https://caldav.example.com/dav/calendars/me/work/live.ics"],
                   "CalDAV incremental preview should keep live calendar-data objects")
        try expect(preview.deletedObjectHrefs == ["https://caldav.example.com/dav/calendars/me/work/gone.ics"],
                   "CalDAV incremental sync should treat 410 Gone objects as deleted")
    }

    private static func verifyDAVIncrementalMultigetRaceTreatsGoneAsDeleted() throws {
        let calendarHref = try requireURL("https://caldav.example.com/dav/calendars/me/work/")
        let preview = try CalDAVClient().incrementalDAVSyncWithMultigetPreview(
            syncText: incrementalMissingCalendarDataSyncXML,
            multigetText: incrementalMissingCalendarDataMultigetXML,
            calendarHref: calendarHref
        )

        try expect(preview.objects == [
            "https://caldav.example.com/dav/calendars/me/work/live-inline.ics",
            "https://caldav.example.com/dav/calendars/me/work/live-fetched.ics"
        ], "CalDAV incremental multiget fallback should keep inline and fetched live objects")
        try expect(preview.deletedObjectHrefs == ["https://caldav.example.com/dav/calendars/me/work/raced-away.ics"],
                   "CalDAV incremental multiget fallback should delete objects that disappear before calendar-multiget")
    }

    private static func verifyDAVCalendarUserAddressSetParsing() throws {
        let responses = try CalDAVClient().parsedDAVXMLPreview(from: calendarUserAddressSetXML)
        guard responses.count == 1, let response = responses.first else {
            throw CalDAVDiscoveryInvariantError("Expected one DAV response in calendar-user-address-set fixture")
        }

        let addresses = response.properties["calendar-user-address-set.hrefs"]?
            .split(separator: "\n")
            .map(String.init) ?? []

        try expect(addresses == [
            "urn:uuid:principal-fixture",
            "mailto:me%2Bcalendar%40example.com",
            "MAILTO:ALIAS%40EXAMPLE.COM"
        ], "DAV parser should preserve all principal calendar-user-address-set hrefs")

        let identityEmail = try CalDAVClient().calendarUserIdentityEmailPreview(from: calendarUserAddressSetXML)
        try expect(identityEmail == "me+calendar@example.com",
                   "CalDAV identity discovery should skip non-email principal URNs and percent-decode the first mailto address")
    }

    private static func verifyDAVMultipleCalendarHomeSetParsing() throws {
        let responses = try CalDAVClient().parsedDAVXMLPreview(from: multipleCalendarHomeSetXML)
        guard responses.count == 1, let response = responses.first else {
            throw CalDAVDiscoveryInvariantError("Expected one DAV response in multi calendar-home-set fixture")
        }

        let homes = response.properties["calendar-home-set.hrefs"]?
            .split(separator: "\n")
            .map(String.init) ?? []

        try expect(response.properties["calendar-home-set.href"] == "/dav/calendars/primary/",
                   "DAV parser should keep the first calendar-home-set href for compatibility")
        try expect(homes == [
            "/dav/calendars/primary/",
            "/dav/calendars/archive"
        ], "DAV parser should preserve every calendar-home-set href in order")

        let resolvedHomes = try CalDAVClient().calendarHomeURLStringsPreview(
            from: multipleCalendarHomeSetXML,
            principalURL: try requireURL("https://caldav.example.com/dav/principals/users/me/")
        )
        try expect(resolvedHomes == [
            "https://caldav.example.com/dav/calendars/primary/",
            "https://caldav.example.com/dav/calendars/archive/"
        ], "CalDAV discovery should resolve and canonicalize every calendar-home-set URL")
    }

    private static func verifyDAVMultipleHomeCalendarAggregation() throws {
        let client = CalDAVClient()
        let homeURLs = [
            try requireURL("https://caldav.example.com/dav/calendars/primary/"),
            try requireURL("https://caldav.example.com/dav/calendars/archive/")
        ]
        let calendars = try client.aggregatedCalendarCollectionURLStringsPreview(homeFixtures: [
            (homeURL: homeURLs[0], xml: primaryHomeCalendarCollectionXML),
            (homeURL: homeURLs[1], xml: archiveHomeCalendarCollectionXML)
        ])
        try expect(calendars == [
            "https://caldav.example.com/dav/calendars/primary/work/",
            "https://caldav.example.com/dav/calendars/primary/shared/",
            "https://caldav.example.com/dav/calendars/archive/old-work/"
        ], "CalDAV discovery should aggregate VEVENT calendars across every calendar-home-set and de-duplicate repeated hrefs")
    }

    private static func verifyDAVScheduleOutboxURLParsing() throws {
        let responses = try CalDAVClient().parsedDAVXMLPreview(from: scheduleOutboxURLXML)
        guard responses.count == 1, let response = responses.first else {
            throw CalDAVDiscoveryInvariantError("Expected one DAV response in schedule-outbox fixture")
        }
        try expect(response.properties["schedule-outbox-URL.href"] == "/dav/principals/users/me/outbox/",
                   "DAV parser should preserve the CalDAV schedule-outbox URL href")
    }

    private static func verifyAnnotatedICSMetadataBridge() throws {
        let account = CalendarProviderAccount(
            id: "caldav-fixture-account",
            kind: .calDAV,
            title: "me@example.com",
            endpointURLString: "https://caldav.example.com/dav/",
            username: "me@example.com",
            identityEmail: "me@example.com",
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let calendar = CalDAVCalendar(
            href: try requireURL("https://caldav.example.com/dav/calendars/me/work/"),
            displayName: "CalDAV Work",
            colorHex: "#14B8A6",
            timeZoneIdentifier: "",
            syncToken: "sync-token-1",
            cTag: "ctag-1",
            allowsEventWrite: true,
            allowsResponses: true
        )
        let object = CalDAVCalendarObject(
            href: try requireURL("https://caldav.example.com/dav/calendars/me/work/caldav-event.ics"),
            icsText: calDAVObjectICS,
            eTag: "\"caldav-etag-1\""
        )
        let client = CalDAVClient()
        let text = client.annotatedICSText(object: object, calendar: calendar, account: account)

        try expect(text.contains("X-WORKING-MY-RESPONSE:tentative"), "CalDAV bridge should preserve the current user response")
        try expect(text.contains("X-WORKING-CURRENT-USER=TRUE"), "CalDAV bridge should mark the current user attendee")
        try expect(text.contains("X-WORKING-REMOTE-ETAG:\"caldav-etag-1\""), "CalDAV bridge should preserve the remote ETag")

        let imported = try LocalCalendarICSCodec.import(text)
        guard imported.events.count == 1, let event = imported.events.first else {
            throw CalDAVDiscoveryInvariantError("CalDAV bridge should import exactly one event")
        }

        try expect(event.calendarID == client.localCalendarID(for: account, calendar: calendar), "CalDAV bridge should attach the app-owned local calendar id")
        try expect(event.remoteObjectURLString == object.href.absoluteString, "CalDAV bridge should preserve the remote object URL")
        try expect(event.remoteETag == "\"caldav-etag-1\"", "CalDAV bridge should preserve the remote object ETag")
        try expect(event.myResponseStatus == .tentative, "CalDAV bridge should import my tentative response")
        try expect(event.organizerEmail == "owner@example.com", "CalDAV bridge should import organizer email")
        try expect(event.urlString == "https://meet.example.com/caldav", "CalDAV bridge should import the meeting URL")
        try expect(event.location == "CY-Office-1st-Conference", "CalDAV bridge should import location")
        try expect(event.reminderOffsets == [15], "CalDAV bridge should import VALARM reminders")
        try expect(event.attendees.contains { $0.email == "me@example.com" && $0.isCurrentUser && $0.status == .tentative },
                   "CalDAV bridge should mark the current user attendee from ATTENDEE EMAIL and mailto value variants")
        try expect(event.attendees.contains { $0.email == "teammate@example.com" && $0.status == .pending },
                   "CalDAV bridge should preserve pending attendees")
        try expect(event.attendees.contains { $0.email == "cy-office-1st-conference@example.com" && $0.isRoomLike },
                   "CalDAV bridge should preserve resource room attendees")
    }

    private static func verifyAnnotatedICSMatchesSMTPAccountIdentity() throws {
        let account = CalendarProviderAccount(
            id: "caldav-smtp-identity-account",
            kind: .calDAV,
            title: "CalDAV",
            endpointURLString: "https://caldav.example.com/dav/",
            username: "SMTP:ME%40example.com",
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let calendar = CalDAVCalendar(
            href: try requireURL("https://caldav.example.com/dav/calendars/me/work/"),
            displayName: "CalDAV Work",
            colorHex: "#14B8A6",
            timeZoneIdentifier: "",
            syncToken: "sync-token-smtp",
            cTag: "ctag-smtp",
            allowsEventWrite: true,
            allowsResponses: true
        )
        let object = CalDAVCalendarObject(
            href: try requireURL("https://caldav.example.com/dav/calendars/me/work/smtp-identity.ics"),
            icsText: calDAVObjectICS,
            eTag: "\"smtp-identity-etag\""
        )

        let text = CalDAVClient().annotatedICSText(object: object, calendar: calendar, account: account)
        try expect(text.contains("X-WORKING-MY-RESPONSE:tentative"),
                   "CalDAV bridge should match raw SMTP account usernames when deriving my response")
        try expect(text.contains("ATTENDEE;CN=Me;EMAIL=me%40example.com;PARTSTAT=TENTATIVE;ROLE=REQ-PARTICIPANT;X-WORKING-CURRENT-USER=TRUE:mailto:me%40example.com?subject=calendar"),
                   "CalDAV bridge should mark the attendee matched through an SMTP account username as current user")
    }

    private static func verifyAnnotatedICSUsesCollectionTimezoneForFloatingTimes() throws {
        let account = CalendarProviderAccount(
            id: "caldav-floating-timezone-account",
            kind: .calDAV,
            title: "CalDAV",
            endpointURLString: "https://caldav.example.com/dav/",
            username: "me@example.com",
            identityEmail: "me@example.com",
            credentialKey: nil,
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let calendar = CalDAVCalendar(
            href: try requireURL("https://caldav.example.com/dav/calendars/me/floating/"),
            displayName: "Floating CalDAV",
            colorHex: "#0EA5E9",
            timeZoneIdentifier: "America/New_York",
            syncToken: "sync-token-floating",
            cTag: "ctag-floating",
            allowsEventWrite: true,
            allowsResponses: true
        )
        let object = CalDAVCalendarObject(
            href: try requireURL("https://caldav.example.com/dav/calendars/me/floating/floating-event.ics"),
            icsText: floatingCalDAVObjectICS,
            eTag: "\"floating-etag\""
        )

        let text = CalDAVClient().annotatedICSText(object: object, calendar: calendar, account: account)
        try expect(text.contains("X-WR-TIMEZONE:America/New_York"),
                   "CalDAV bridge should inject collection timezone when the object has floating times")

        let imported = try LocalCalendarICSCodec.import(text)
        guard imported.events.count == 1, let event = imported.events.first else {
            throw CalDAVDiscoveryInvariantError("Floating timezone CalDAV bridge should import exactly one event")
        }

        try expect(event.timeZoneIdentifier == "America/New_York",
                   "Floating CalDAV events should inherit the collection timezone")
        try expect(sameInstant(event.startDate, "2026-07-01T13:00:00Z"),
                   "Floating CalDAV DTSTART should parse in the collection timezone, not the machine timezone")
        try expect(sameInstant(event.endDate, "2026-07-01T13:30:00Z"),
                   "Floating CalDAV DTEND should parse in the collection timezone, not the machine timezone")
    }

    private static func verifyCalDAVHTTPWriteFlow() async throws {
        let start = try date("2026-07-01T09:00:00Z")
        let end = try date("2026-07-01T09:30:00Z")
        let account = calDAVHTTPFixtureAccount(createdAt: start)
        let calendar = CalDAVCalendar(
            href: try requireURL("https://caldav.example.com/dav/calendars/me/work/"),
            displayName: "CalDAV Work",
            colorHex: "#14B8A6",
            timeZoneIdentifier: "UTC",
            syncToken: "sync-token-http",
            cTag: "ctag-http",
            allowsEventWrite: true,
            allowsResponses: true
        )

        let createTransport = CalDAVHTTPFixtureTransport(responses: [
            .empty(statusCode: 201, headers: ["ETag": "\"created-caldav-etag\""])
        ])
        let createClient = CalDAVClient(
            transport: createTransport,
            passwordProvider: fixedCalDAVPasswordProvider(key: "caldav-http-password", password: "secret")
        )
        let localCalendar = LocalCalendar(
            id: createClient.localCalendarID(for: account, calendar: calendar),
            title: calendar.displayName,
            colorHex: calendar.colorHex
        )
        let createEvent = calDAVWriteEvent(
            id: "caldav-create",
            calendarID: localCalendar.id,
            title: "CalDAV create fixture",
            start: start,
            end: end
        )
        let createResult = try await createClient.putEvent(
            createEvent,
            localCalendar: localCalendar,
            account: account,
            calendar: calendar
        )
        try expect(createResult.remoteObjectURL.absoluteString == "https://caldav.example.com/dav/calendars/me/work/caldav-create.ics",
                   "CalDAV create should target a deterministic object URL")
        try expect(createResult.eTag == "\"created-caldav-etag\"",
                   "CalDAV create should preserve the server ETag")
        let createRequest = try requireOnly(createTransport.requests, context: "CalDAV create requests")
        try expect(createRequest.httpMethod == "PUT", "CalDAV create should use PUT")
        try expect(createRequest.value(forHTTPHeaderField: "If-None-Match") == "*",
                   "CalDAV create should protect against overwriting an existing object")
        try expect(createRequest.value(forHTTPHeaderField: "Authorization") == nil,
                   "CalDAV create should wait for URLSession auth challenges instead of sending preemptive Basic auth")
        try expect(createTransport.usedAuthenticationDelegates == [true],
                   "CalDAV create should provide an auth challenge delegate for Basic/Digest servers")
        try expect(createRequest.value(forHTTPHeaderField: "Content-Type") == "text/calendar; charset=utf-8",
                   "CalDAV create should send an iCalendar content type")
        try expect(requestBodyString(createRequest).contains("SUMMARY:CalDAV create fixture"),
                   "CalDAV create should upload the local event as iCalendar")

        let collisionTransport = CalDAVHTTPFixtureTransport(responses: [
            .empty(statusCode: 201, headers: ["ETag": "\"collision-one-etag\""]),
            .empty(statusCode: 201, headers: ["ETag": "\"collision-two-etag\""])
        ])
        let collisionClient = CalDAVClient(
            transport: collisionTransport,
            passwordProvider: fixedCalDAVPasswordProvider(key: "caldav-http-password", password: "secret")
        )
        var slashUIDEvent = calDAVWriteEvent(
            id: "caldav-collision-slash",
            calendarID: localCalendar.id,
            title: "CalDAV collision slash fixture",
            start: start,
            end: end
        )
        slashUIDEvent.externalUID = "same/room"
        var queryUIDEvent = calDAVWriteEvent(
            id: "caldav-collision-query",
            calendarID: localCalendar.id,
            title: "CalDAV collision query fixture",
            start: start,
            end: end
        )
        queryUIDEvent.externalUID = "same?room"

        let slashUIDResult = try await collisionClient.putEvent(
            slashUIDEvent,
            localCalendar: localCalendar,
            account: account,
            calendar: calendar
        )
        let queryUIDResult = try await collisionClient.putEvent(
            queryUIDEvent,
            localCalendar: localCalendar,
            account: account,
            calendar: calendar
        )
        try expect(slashUIDResult.remoteObjectURL != queryUIDResult.remoteObjectURL,
                   "CalDAV create object names should not collide after UID sanitization")
        try expect(slashUIDResult.remoteObjectURL.lastPathComponent.hasPrefix("same-room-"),
                   "CalDAV create should keep a readable sanitized stem for slash UIDs")
        try expect(queryUIDResult.remoteObjectURL.lastPathComponent.hasPrefix("same-room-"),
                   "CalDAV create should keep a readable sanitized stem for query UIDs")
        try expect(!slashUIDResult.remoteObjectURL.lastPathComponent.contains("/"),
                   "CalDAV create object names should not contain raw slash characters")
        try expect(!queryUIDResult.remoteObjectURL.lastPathComponent.contains("?"),
                   "CalDAV create object names should not contain raw query characters")
        try expect(collisionTransport.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "If-None-Match") == "*"
        }, "CalDAV collision-safe creates should still protect against overwriting existing objects")

        let updateTransport = CalDAVHTTPFixtureTransport(responses: [
            .empty(statusCode: 204, headers: ["ETag": "\"updated-caldav-etag\""])
        ])
        let updateClient = CalDAVClient(
            transport: updateTransport,
            passwordProvider: fixedCalDAVPasswordProvider(key: "caldav-http-password", password: "secret")
        )
        var updateEvent = calDAVWriteEvent(
            id: "caldav-update",
            calendarID: localCalendar.id,
            title: "CalDAV update fixture",
            start: start,
            end: end
        )
        updateEvent.remoteObjectURLString = "https://caldav.example.com/dav/calendars/me/work/existing.ics"
        updateEvent.remoteETag = "\"existing-caldav-etag\""
        let updateResult = try await updateClient.putEvent(
            updateEvent,
            localCalendar: localCalendar,
            account: account,
            calendar: calendar
        )
        try expect(updateResult.remoteObjectURL.absoluteString == updateEvent.remoteObjectURLString,
                   "CalDAV update should keep the existing object URL")
        try expect(updateResult.eTag == "\"updated-caldav-etag\"",
                   "CalDAV update should preserve the updated server ETag")
        let updateRequest = try requireOnly(updateTransport.requests, context: "CalDAV update requests")
        try expect(updateRequest.httpMethod == "PUT", "CalDAV update should use PUT")
        try expect(updateRequest.value(forHTTPHeaderField: "If-Match") == "\"existing-caldav-etag\"",
                   "CalDAV update should send the remote ETag precondition")
        try expect(updateRequest.value(forHTTPHeaderField: "Authorization") == nil,
                   "CalDAV update should wait for URLSession auth challenges instead of sending preemptive Basic auth")
        try expect(updateTransport.usedAuthenticationDelegates == [true],
                   "CalDAV update should provide an auth challenge delegate for Basic/Digest servers")
        try expect(requestBodyString(updateRequest).contains("SUMMARY:CalDAV update fixture"),
                   "CalDAV update should upload the edited event as iCalendar")

        let deleteGoneTransport = CalDAVHTTPFixtureTransport(responses: [
            .empty(statusCode: 404)
        ])
        let deleteGoneClient = CalDAVClient(
            transport: deleteGoneTransport,
            passwordProvider: fixedCalDAVPasswordProvider(key: "caldav-http-password", password: "secret")
        )
        try await deleteGoneClient.deleteEventObject(
            account: account,
            remoteObjectURL: try requireURL("https://caldav.example.com/dav/calendars/me/work/gone.ics"),
            remoteETag: "\"gone-caldav-etag\""
        )
        let deleteGoneRequest = try requireOnly(deleteGoneTransport.requests, context: "CalDAV delete gone requests")
        try expect(deleteGoneRequest.httpMethod == "DELETE", "CalDAV delete should use DELETE")
        try expect(deleteGoneRequest.value(forHTTPHeaderField: "If-Match") == "\"gone-caldav-etag\"",
                   "CalDAV delete should send the remote ETag precondition")
        try expect(deleteGoneTransport.usedAuthenticationDelegates == [true],
                   "CalDAV delete should provide an auth challenge delegate for Basic/Digest servers")

        let deleteConflictTransport = CalDAVHTTPFixtureTransport(responses: [
            .empty(statusCode: 412)
        ])
        let deleteConflictClient = CalDAVClient(
            transport: deleteConflictTransport,
            passwordProvider: fixedCalDAVPasswordProvider(key: "caldav-http-password", password: "secret")
        )
        do {
            try await deleteConflictClient.deleteEventObject(
                account: account,
                remoteObjectURL: try requireURL("https://caldav.example.com/dav/calendars/me/work/conflict.ics"),
                remoteETag: "\"conflict-caldav-etag\""
            )
            throw CalDAVDiscoveryInvariantError("CalDAV DELETE 412 should surface as a precondition failure")
        } catch CalDAVClientError.preconditionFailed(let url) {
            try expect(url.absoluteString == "https://caldav.example.com/dav/calendars/me/work/conflict.ics",
                       "CalDAV DELETE 412 should report the failed object URL")
        }

        let deleteRetryTransport = CalDAVHTTPFixtureTransport(responses: [
            .empty(statusCode: 429, headers: ["Retry-After": "75"])
        ])
        let deleteRetryClient = CalDAVClient(
            transport: deleteRetryTransport,
            passwordProvider: fixedCalDAVPasswordProvider(key: "caldav-http-password", password: "secret")
        )
        do {
            try await deleteRetryClient.deleteEventObject(
                account: account,
                remoteObjectURL: try requireURL("https://caldav.example.com/dav/calendars/me/work/retry.ics"),
                remoteETag: "\"retry-caldav-etag\""
            )
            throw CalDAVDiscoveryInvariantError("CalDAV DELETE 429 should surface provider Retry-After")
        } catch CalDAVClientError.retryAfter(let seconds, let url) {
            try expect(seconds == 75, "CalDAV DELETE 429 should preserve Retry-After seconds")
            try expect(url.absoluteString == "https://caldav.example.com/dav/calendars/me/work/retry.ics",
                       "CalDAV DELETE 429 should report the failed object URL")
        }

        let replyTransport = CalDAVHTTPFixtureTransport(responses: [
            .xml("""
            <?xml version="1.0" encoding="utf-8"?>
            <d:multistatus xmlns:d="DAV:">
              <d:response>
                <d:href>/dav/</d:href>
                <d:propstat>
                  <d:prop>
                    <d:current-user-principal>
                      <d:href>/dav/principals/users/me/</d:href>
                    </d:current-user-principal>
                  </d:prop>
                  <d:status>HTTP/1.1 200 OK</d:status>
                </d:propstat>
              </d:response>
            </d:multistatus>
            """),
            .xml("""
            <?xml version="1.0" encoding="utf-8"?>
            <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
              <d:response>
                <d:href>/dav/principals/users/me/</d:href>
                <d:propstat>
                  <d:prop>
                    <c:schedule-outbox-URL>
                      <d:href>/dav/principals/users/me/outbox/</d:href>
                    </c:schedule-outbox-URL>
                  </d:prop>
                  <d:status>HTTP/1.1 200 OK</d:status>
                </d:propstat>
              </d:response>
            </d:multistatus>
            """),
            .empty(statusCode: 200)
        ])
        let replyClient = CalDAVClient(
            transport: replyTransport,
            passwordProvider: fixedCalDAVPasswordProvider(key: "caldav-http-password", password: "secret")
        )
        var replyEvent = calDAVWriteEvent(
            id: "caldav-rsvp",
            calendarID: localCalendar.id,
            title: "CalDAV RSVP fixture",
            start: start,
            end: end
        )
        replyEvent.sequence = 7
        replyEvent.organizerName = "Owner"
        replyEvent.organizerEmail = "owner@example.com"
        replyEvent.attendees = [
            LocalEventAttendee(
                name: "Me",
                email: "me@example.com",
                status: .pending,
                type: "person",
                role: "required",
                rsvp: true,
                isCurrentUser: true
            )
        ]
        try await replyClient.respondToEvent(
            account: account,
            event: replyEvent,
            response: .maybe,
            occurrenceStartDate: nil,
            occurrenceIsAllDay: false
        )
        try expect(replyTransport.requests.map(\.httpMethod) == ["PROPFIND", "PROPFIND", "POST"],
                   "CalDAV RSVP should discover the schedule outbox then POST the iTIP reply")
        try expect(replyTransport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil },
                   "CalDAV RSVP discovery and POST should wait for URLSession auth challenges instead of sending preemptive Basic auth")
        try expect(replyTransport.usedAuthenticationDelegates == [true, true, true],
                   "CalDAV RSVP discovery and POST should provide auth challenge delegates for Basic/Digest servers")
        try expect(replyTransport.requests[0].url?.absoluteString == "https://caldav.example.com/dav/",
                   "CalDAV RSVP should start schedule-outbox discovery at the account endpoint")
        try expect(replyTransport.requests[0].value(forHTTPHeaderField: "Depth") == "0",
                   "CalDAV current-user-principal discovery should be depth 0")
        try expect(requestBodyString(replyTransport.requests[0]).contains("current-user-principal"),
                   "CalDAV RSVP should request current-user-principal during outbox discovery")
        try expect(replyTransport.requests[1].url?.absoluteString == "https://caldav.example.com/dav/principals/users/me/",
                   "CalDAV RSVP should request the schedule outbox from the principal URL")
        try expect(requestBodyString(replyTransport.requests[1]).contains("schedule-outbox-URL"),
                   "CalDAV RSVP should request schedule-outbox-URL from the principal")
        try expect(replyTransport.requests[2].url?.absoluteString == "https://caldav.example.com/dav/principals/users/me/outbox/",
                   "CalDAV RSVP should POST to the discovered schedule outbox")
        try expect(replyTransport.requests[2].value(forHTTPHeaderField: "Content-Type") == "text/calendar; charset=utf-8",
                   "CalDAV RSVP should send an iCalendar reply content type")
        let replyBody = unfoldedText(requestBodyString(replyTransport.requests[2]))
        try expect(replyBody.contains("METHOD:REPLY"), "CalDAV RSVP POST should send an iTIP reply")
        try expect(replyBody.contains("UID:caldav-rsvp"), "CalDAV RSVP POST should target the event UID")
        try expect(replyBody.contains("SEQUENCE:7"), "CalDAV RSVP POST should preserve the event sequence")
        try expect(replyBody.contains("PARTSTAT=TENTATIVE"), "CalDAV Maybe should be sent as TENTATIVE")
        try expect(replyBody.contains("mailto:me@example.com"), "CalDAV RSVP POST should target the current attendee")
        try expect(!replyBody.contains("X-WORKING-"), "CalDAV RSVP POST should not leak private Working Calendar metadata")
    }

    private static let calDAVObjectICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//CalDAV Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:caldav-metadata@example.com
    DTSTAMP:20260625T104500Z
    LAST-MODIFIED:20260625T104500Z
    DTSTART;TZID=Asia/Nicosia:20260701T120000
    DTEND;TZID=Asia/Nicosia:20260701T123000
    SUMMARY:CalDAV metadata fixture
    LOCATION:CY-Office-1st-Conference
    DESCRIPTION:Discuss CalDAV bridge metadata
    URL:https://meet.example.com/caldav
    ORGANIZER;CN=Owner:mailto:owner%40example.com
    ATTENDEE;CN=Me;EMAIL=me%40example.com;PARTSTAT=TENTATIVE;ROLE=REQ-PARTICIPANT:mailto:me%40example.com?subject=calendar
    ATTENDEE;CN=Teammate;PARTSTAT=NEEDS-ACTION;ROLE=REQ-PARTICIPANT:mailto:teammate@example.com
    ATTENDEE;CN=CY-Office-1st-Conference;CUTYPE=RESOURCE;PARTSTAT=ACCEPTED;ROLE=REQ-PARTICIPANT:mailto:cy-office-1st-conference@example.com
    BEGIN:VALARM
    ACTION:DISPLAY
    DESCRIPTION:CalDAV reminder
    TRIGGER:-PT15M
    END:VALARM
    END:VEVENT
    END:VCALENDAR
    """

    private static let floatingCalDAVObjectICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Working Calendar//CalDAV Floating Timezone Fixture//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:caldav-floating-timezone@example.com
    DTSTAMP:20260625T104500Z
    DTSTART:20260701T090000
    DTEND:20260701T093000
    SUMMARY:Floating CalDAV timezone fixture
    END:VEVENT
    END:VCALENDAR
    """

    private static let propstatDeletedObjectXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:response>
        <d:href>/dav/calendars/me/work/deleted.ics</d:href>
        <d:propstat>
          <d:prop>
            <d:getetag />
            <c:calendar-data />
          </d:prop>
          <d:status>HTTP/1.1 404 Not Found</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    private static let calendarColorXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus
      xmlns:d="DAV:"
      xmlns:cs="http://calendarserver.org/ns/"
      xmlns:ical="http://apple.com/ns/ical/">
      <d:response>
        <d:href>/dav/calendars/me/work/</d:href>
        <d:propstat>
          <d:prop>
            <d:displayname>Work</d:displayname>
            <cs:getctag>"color-ctag"</cs:getctag>
            <ical:calendar-color>#14B8A6FF</ical:calendar-color>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    private static let calendarTimezoneXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:response>
        <d:href>/dav/calendars/me/timezone/</d:href>
        <d:propstat>
          <d:prop>
            <d:displayname>Timezone</d:displayname>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <c:calendar-timezone>BEGIN:VCALENDAR&#10;BEGIN:VTIMEZONE&#10;X-LIC-LOCATION:America/New_York&#10;BEGIN:STANDARD&#10;DTSTART:20260101T000000&#10;TZOFFSETFROM:-0500&#10;TZOFFSETTO:-0500&#10;END:STANDARD&#10;END:VTIMEZONE&#10;END:VCALENDAR</c:calendar-timezone>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    private static let calendarPrivilegeXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus
      xmlns:d="DAV:"
      xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:response>
        <d:href>/dav/calendars/me/readonly/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <d:current-user-privilege-set>
              <d:privilege><d:read /></d:privilege>
            </d:current-user-privilege-set>
            <c:supported-calendar-component-set>
              <c:comp name="VEVENT" />
            </c:supported-calendar-component-set>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/me/bind-only/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <d:current-user-privilege-set>
              <d:privilege><d:read /></d:privilege>
              <d:privilege><d:bind /></d:privilege>
            </d:current-user-privilege-set>
            <c:supported-calendar-component-set>
              <c:comp name="VEVENT" />
            </c:supported-calendar-component-set>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/me/writable/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <d:current-user-privilege-set>
              <d:privilege><d:read /></d:privilege>
              <d:privilege><d:write-content /></d:privilege>
            </d:current-user-privilege-set>
            <c:supported-calendar-component-set>
              <c:comp name="VEVENT" />
            </c:supported-calendar-component-set>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/me/mixed-components/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <d:current-user-privilege-set>
              <d:privilege><d:write /></d:privilege>
            </d:current-user-privilege-set>
            <c:supported-calendar-component-set>
              <c:comp name="VEVENT" />
              <c:comp name="VTODO" />
            </c:supported-calendar-component-set>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/me/tasks/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <d:current-user-privilege-set>
              <d:privilege><d:write /></d:privilege>
            </d:current-user-privilege-set>
            <c:supported-calendar-component-set>
              <c:comp name="VTODO" />
            </c:supported-calendar-component-set>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/me/schedule-reply/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <d:current-user-privilege-set>
              <d:privilege><d:read /></d:privilege>
              <d:privilege><c:schedule-send-reply /></d:privilege>
            </d:current-user-privilege-set>
            <c:supported-calendar-component-set>
              <c:comp name=" vevent " />
            </c:supported-calendar-component-set>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/me/freebusy/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <d:current-user-privilege-set>
              <d:privilege><d:write /></d:privilege>
            </d:current-user-privilege-set>
            <c:supported-calendar-component-set>
              <c:comp name="VFREEBUSY" />
            </c:supported-calendar-component-set>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/me/empty-components/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <d:current-user-privilege-set>
              <d:privilege><d:write /></d:privilege>
            </d:current-user-privilege-set>
            <c:supported-calendar-component-set />
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/me/timezones/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <d:current-user-privilege-set>
              <d:privilege><d:write /></d:privilege>
            </d:current-user-privilege-set>
            <c:supported-calendar-component-set>
              <c:comp name="VTIMEZONE" />
            </c:supported-calendar-component-set>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    private static let supportedCalendarDataXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:response>
        <d:href>/dav/calendars/me/icalendar20/</d:href>
        <d:propstat>
          <d:prop>
            <d:current-user-privilege-set>
              <d:privilege><d:read /></d:privilege>
              <d:privilege><d:write-content /></d:privilege>
            </d:current-user-privilege-set>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <c:supported-calendar-component-set>
              <c:comp name="VEVENT" />
            </c:supported-calendar-component-set>
            <c:supported-calendar-data>
              <c:calendar-data content-type="text/calendar" version="2.0" />
            </c:supported-calendar-data>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/me/icalendar20-charset/</d:href>
        <d:propstat>
          <d:prop>
            <d:current-user-privilege-set>
              <d:privilege><d:read /></d:privilege>
              <d:privilege><d:write-content /></d:privilege>
            </d:current-user-privilege-set>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <c:supported-calendar-component-set>
              <c:comp name="VEVENT" />
            </c:supported-calendar-component-set>
            <c:supported-calendar-data>
              <c:calendar-data content-type="text/calendar; charset=utf-8" version="2.0" />
            </c:supported-calendar-data>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/me/empty-calendar-data/</d:href>
        <d:propstat>
          <d:prop>
            <d:current-user-privilege-set>
              <d:privilege><d:read /></d:privilege>
              <d:privilege><d:write-content /></d:privilege>
            </d:current-user-privilege-set>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <c:supported-calendar-component-set>
              <c:comp name="VEVENT" />
            </c:supported-calendar-component-set>
            <c:supported-calendar-data />
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/me/json-only/</d:href>
        <d:propstat>
          <d:prop>
            <d:current-user-privilege-set>
              <d:privilege><d:read /></d:privilege>
              <d:privilege><d:write-content /></d:privilege>
            </d:current-user-privilege-set>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <c:supported-calendar-component-set>
              <c:comp name="VEVENT" />
            </c:supported-calendar-component-set>
            <c:supported-calendar-data>
              <c:calendar-data content-type="application/calendar+json" version="1.0" />
            </c:supported-calendar-data>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/me/icalendar10/</d:href>
        <d:propstat>
          <d:prop>
            <d:current-user-privilege-set>
              <d:privilege><d:read /></d:privilege>
              <d:privilege><d:write-content /></d:privilege>
            </d:current-user-privilege-set>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <c:supported-calendar-component-set>
              <c:comp name="VEVENT" />
            </c:supported-calendar-component-set>
            <c:supported-calendar-data>
              <c:calendar-data content-type="text/calendar" version="1.0" />
            </c:supported-calendar-data>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    private static let mixedPropstatCalendarDataXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:response>
        <d:href>/dav/calendars/me/work/live.ics</d:href>
        <d:propstat>
          <d:prop>
            <d:getetag>"live-etag"</d:getetag>
            <c:calendar-data>BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:live-caldav@example.com
    DTSTAMP:20260625T120000Z
    DTSTART:20260701T090000Z
    DTEND:20260701T093000Z
    SUMMARY:Live CalDAV object
    END:VEVENT
    END:VCALENDAR</c:calendar-data>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
        <d:propstat>
          <d:prop>
            <d:displayname />
          </d:prop>
          <d:status>HTTP/1.1 404 Not Found</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    private static let calendarUserAddressSetXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:response>
        <d:href>/dav/principals/users/me/</d:href>
        <d:propstat>
          <d:prop>
            <c:calendar-user-address-set>
              <d:href>urn:uuid:principal-fixture</d:href>
              <d:href>mailto:me%2Bcalendar%40example.com</d:href>
              <d:href>MAILTO:ALIAS%40EXAMPLE.COM</d:href>
            </c:calendar-user-address-set>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    private static let multipleCalendarHomeSetXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:response>
        <d:href>/dav/principals/users/me/</d:href>
        <d:propstat>
          <d:prop>
            <c:calendar-home-set>
              <d:href>/dav/calendars/primary/</d:href>
              <d:href>/dav/calendars/archive</d:href>
            </c:calendar-home-set>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    private static let incrementalGoneSyncXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:response>
        <d:href>/dav/calendars/me/work/live.ics</d:href>
        <d:propstat>
          <d:prop>
            <d:getetag>"live-etag"</d:getetag>
            <c:calendar-data>BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:live-sync-caldav@example.com
    DTSTAMP:20260625T120000Z
    DTSTART:20260701T090000Z
    DTEND:20260701T093000Z
    SUMMARY:Live CalDAV sync object
    END:VEVENT
    END:VCALENDAR</c:calendar-data>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/me/work/gone.ics</d:href>
        <d:status>HTTP/1.1 410 Gone</d:status>
      </d:response>
    </d:multistatus>
    """

    private static let incrementalMissingCalendarDataSyncXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:response>
        <d:href>/dav/calendars/me/work/live-inline.ics</d:href>
        <d:propstat>
          <d:prop>
            <d:getetag>"live-inline-etag"</d:getetag>
            <c:calendar-data>BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:live-inline-caldav@example.com
    DTSTAMP:20260625T120000Z
    DTSTART:20260701T090000Z
    DTEND:20260701T093000Z
    SUMMARY:Live inline CalDAV sync object
    END:VEVENT
    END:VCALENDAR</c:calendar-data>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/me/work/live-fetched.ics</d:href>
        <d:propstat>
          <d:prop>
            <d:getetag>"live-fetched-etag"</d:getetag>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/me/work/raced-away.ics</d:href>
        <d:propstat>
          <d:prop>
            <d:getetag>"raced-away-etag"</d:getetag>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    private static let incrementalMissingCalendarDataMultigetXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:response>
        <d:href>/dav/calendars/me/work/live-fetched.ics</d:href>
        <d:propstat>
          <d:prop>
            <d:getetag>"live-fetched-etag-2"</d:getetag>
            <c:calendar-data>BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:live-fetched-caldav@example.com
    DTSTAMP:20260625T121000Z
    DTSTART:20260702T090000Z
    DTEND:20260702T093000Z
    SUMMARY:Live fetched CalDAV sync object
    END:VEVENT
    END:VCALENDAR</c:calendar-data>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/me/work/raced-away.ics</d:href>
        <d:status>HTTP/1.1 404 Not Found</d:status>
      </d:response>
    </d:multistatus>
    """

    private static let primaryHomeCalendarCollectionXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:response>
        <d:href>/dav/calendars/primary/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection /></d:resourcetype>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/primary/work/</d:href>
        <d:propstat>
          <d:prop>
            <d:displayname>Work</d:displayname>
            <d:current-user-privilege-set>
              <d:privilege><d:read /></d:privilege>
              <d:privilege><d:write-content /></d:privilege>
            </d:current-user-privilege-set>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <c:supported-calendar-component-set>
              <c:comp name="VEVENT" />
            </c:supported-calendar-component-set>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/primary/shared/</d:href>
        <d:propstat>
          <d:prop>
            <d:displayname>Shared</d:displayname>
            <d:current-user-privilege-set>
              <d:privilege><d:read /></d:privilege>
            </d:current-user-privilege-set>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <c:supported-calendar-component-set>
              <c:comp name="VEVENT" />
            </c:supported-calendar-component-set>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    private static let archiveHomeCalendarCollectionXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:response>
        <d:href>/dav/calendars/primary/shared/</d:href>
        <d:propstat>
          <d:prop>
            <d:displayname>Shared duplicate</d:displayname>
            <d:current-user-privilege-set>
              <d:privilege><d:read /></d:privilege>
            </d:current-user-privilege-set>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <c:supported-calendar-component-set>
              <c:comp name="VEVENT" />
            </c:supported-calendar-component-set>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/archive/old-work/</d:href>
        <d:propstat>
          <d:prop>
            <d:displayname>Old Work</d:displayname>
            <d:current-user-privilege-set>
              <d:privilege><d:read /></d:privilege>
            </d:current-user-privilege-set>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <c:supported-calendar-component-set>
              <c:comp name="VEVENT" />
            </c:supported-calendar-component-set>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/calendars/archive/tasks/</d:href>
        <d:propstat>
          <d:prop>
            <d:displayname>Tasks</d:displayname>
            <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
            <c:supported-calendar-component-set>
              <c:comp name="VTODO" />
            </c:supported-calendar-component-set>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    private static let scheduleOutboxURLXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:response>
        <d:href>/dav/principals/users/me/</d:href>
        <d:propstat>
          <d:prop>
            <c:schedule-outbox-URL>
              <d:href>/dav/principals/users/me/outbox/</d:href>
            </c:schedule-outbox-URL>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    private static func requireURL(_ string: String) throws -> URL {
        guard let url = URL(string: string) else {
            throw CalDAVDiscoveryInvariantError("Invalid fixture URL: \(string)")
        }
        return url
    }

    private static func requireResponse(_ responses: [DAVPreviewResponse], href: String) throws -> DAVPreviewResponse {
        guard let response = responses.first(where: { $0.href == href }) else {
            throw CalDAVDiscoveryInvariantError("Missing DAV response for \(href)")
        }
        return response
    }

    private static func requireOnly<T>(_ values: [T], context: String) throws -> T {
        guard values.count == 1, let value = values.first else {
            throw CalDAVDiscoveryInvariantError("Expected one \(context), got \(values.count)")
        }
        return value
    }

    private static func calDAVHTTPFixtureAccount(createdAt: Date) -> CalendarProviderAccount {
        CalendarProviderAccount(
            id: "caldav-http-write-account",
            kind: .calDAV,
            title: "CalDAV HTTP Write",
            endpointURLString: "https://caldav.example.com/dav/",
            username: "me@example.com",
            credentialKey: "caldav-http-password",
            enabled: true,
            importedEventCount: 0,
            updatedEventCount: 0,
            skippedEventCount: 0,
            lastSyncAt: nil,
            lastError: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private static func calDAVWriteEvent(
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

    private static func fixedCalDAVPasswordProvider(key expectedKey: String, password: String) -> CalDAVPasswordProvider {
        { key in key == expectedKey ? password : nil }
    }

    private static func requestBodyString(_ request: URLRequest) -> String {
        request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func unfoldedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\n ", with: "")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw CalDAVDiscoveryInvariantError(message)
        }
    }

    private static func sameInstant(_ lhs: Date, _ rhs: String) -> Bool {
        guard let rhsDate = ISO8601DateFormatter().date(from: rhs) else { return false }
        return abs(lhs.timeIntervalSince(rhsDate)) < 0.5
    }

    private static func date(_ value: String) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            throw CalDAVDiscoveryInvariantError("Invalid fixture date: \(value)")
        }
        return date
    }
}

private struct CalDAVDiscoveryInvariantError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private final class CalDAVHTTPFixtureTransport: CalDAVHTTPTransport {
    struct FixtureResponse {
        let data: Data
        let statusCode: Int
        let headers: [String: String]

        static func empty(statusCode: Int, headers: [String: String] = [:]) -> FixtureResponse {
            FixtureResponse(data: Data(), statusCode: statusCode, headers: headers)
        }

        static func xml(_ text: String, statusCode: Int = 207, headers: [String: String] = [:]) -> FixtureResponse {
            FixtureResponse(
                data: Data(text.utf8),
                statusCode: statusCode,
                headers: ["Content-Type": "application/xml"].merging(headers) { _, new in new }
            )
        }
    }

    private var responses: [FixtureResponse]
    private(set) var requests: [URLRequest] = []
    private(set) var usedAuthenticationDelegates: [Bool] = []

    init(responses: [FixtureResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest, delegate: URLSessionTaskDelegate?) async throws -> (Data, URLResponse) {
        requests.append(request)
        usedAuthenticationDelegates.append(delegate != nil)
        guard !responses.isEmpty else {
            throw CalDAVDiscoveryInvariantError("Unexpected CalDAV HTTP request to \(request.url?.absoluteString ?? "<nil>")")
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
            throw CalDAVDiscoveryInvariantError("Could not create CalDAV HTTP fixture response")
        }
        return (response.data, httpResponse)
    }
}
