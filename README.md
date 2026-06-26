# Working Calendar

A native macOS calendar companion for people who live in terminals and still need to catch meetings.

## What it does

- Keeps its own local calendar store instead of depending on macOS Calendar or EventKit.
- Syncs provider sources directly: ICS/webcal subscriptions, CalDAV accounts, Google Calendar, and Microsoft 365.
- Lets you enable or mute local calendars and provider calendars.
- Shows a focused agenda and full calendar grid with day/week/month views, click-to-create, drag/resize, and recurring edit scopes.
- Stores custom rules for alerts, auto-responses, and display-location overrides.
- Can trigger macOS notifications, sounds, spoken warnings, Dock bouncing, and a sticky floating overlay.
- Draws its own Dock icon with today's date, weekday, and a custom active/upcoming timed-meeting counter.
- Extracts Zoom, Google Meet, Teams, Skype/Lync, Webex, and other meeting links from events.
- Imports and exports standard `.ics` files.
- Registers for `.ics` files and `webcal://` / `webcals://` links so calendar files and subscriptions can be opened directly into the app.

## Provider support

| Source | Sync | Write events | RSVP | Notes |
| --- | --- | --- | --- | --- |
| Local calendars | Local only | Yes | Yes | Stored inside Working Calendar. Good for private/manual events. |
| ICS/webcal | One-way import | No | No | Read-only subscriptions for shared or published calendars, with HTTP validators and charset-aware text decoding. |
| CalDAV | Two-way | Yes | Yes | Works with standard CalDAV servers, including iCloud, Fastmail, Yahoo, Nextcloud, Radicale, Baikal, and generic URLs. Accepts `http(s)` and `caldav(s)` URLs, tries standard discovery plus common DAV entrypoints, and supports Basic/Digest HTTP auth challenges. |
| Google Calendar | Two-way | Yes | Yes | OAuth provider with incremental sync and retryable outbound updates. |
| Microsoft 365 | Two-way | Yes | Yes | OAuth provider with delta sync and retryable outbound updates. |

## Run

```sh
make run
```

The first launch will ask for Notification permission. Calendar access is configured inside the app by adding local calendars or provider sources.

## Policies

- [Privacy Policy](PRIVACY.md)
- [Terms of Service](TERMS.md)

## Verify

```sh
make verify
```

`make verify` builds the app and checks the standalone-calendar invariants: no EventKit/macOS Calendar dependency, no direct provider writes outside the retryable provider outbox, app registration and deduplicated open routing for `.ics`/`.ifb` files plus `webcal://` and `webcals://` links, iCalendar `REQUEST`/`REPLY`/`REFRESH`/`CANCEL` handling including same-UID invite updates, one-off iTIP `ADD` occurrence merges, orphan `RECURRENCE-ID` occurrence updates, `VFREEBUSY` free/busy placeholders, `VTODO`/`VJOURNAL` component isolation, `DURATION` events, date-only all-day events, all-day `RDATE`/`EXDATE` recurrences, `RDATE;VALUE=PERIOD` custom occurrence durations, daily interval `COUNT` recurrences, monthly and yearly `BYSETPOS` recurrence rules, guarded imports for unknown RRULE components, `VALARM` reminders, timezone-safe `TZID` round-trips including floating timed `X-WR-TIMEZONE` events and Outlook/Exchange Windows timezone IDs, RFC6868 parameter escaping, stale `SEQUENCE` protection, `RESOURCES` room/resource import, `COMMENT`/`CONTACT` notes and join-link preservation, structured `RELATED-TO` relationship round-trips, URI `ATTACH` attachment round-trips and join-link preservation, `GEO` coordinate round-trips, and `RANGE=THISANDFUTURE` cancellations, ICS/webcal URL normalization including Google public `src`/`cid` share links, HTTP transport, validators, Retry-After cooldowns, Cyrillic charset decoding, Apple structured-location title/noise handling, Outlook busy/all-day/importance/counter-proposal metadata import, standard iTIP `COUNTER`/`DECLINECOUNTER` import, read-only subscription metadata, subscription `VFREEBUSY` metadata/pruning, subscription cancelled-occurrence bridging, and subscription refresh/prune behavior, CalDAV URL normalization/discovery fallbacks, Basic/Digest auth challenge handling, mixed `VEVENT`/`VTODO` calendar discovery, service-only and empty CalDAV capability isolation, parameterized CalDAV `supported-calendar-data` parsing, multiple `calendar-home-set` discovery, server `.ics` metadata bridging, and CalDAV HTTP PUT/DELETE precondition, collision-safe object naming, retry-after, delete-gone, and schedule-outbox RSVP behavior, provider-to-iCalendar bridge handling for cancelled recurring occurrences plus Google and Microsoft 365 RSVP/meeting metadata, Google working-location, explicit public visibility, attachments, attachment write-back, attachment meeting links, private relationship/GEO metadata round-trips including detached occurrence writes, and out-of-office/focus-time labels and write-back semantics, Google partial-attendee write-back semantics, Microsoft 365 personal sensitivity, room/location identity, open-extension relationship/GEO metadata round-trips including detailed recurring exceptions and detached occurrence writes, reference attachments, detailed exception reference attachments, reference attachment write-back, attachment meeting links, and new-time-proposal write-back semantics, remote object URL normalization, remote ETag/changeKey preservation, read-only provider calendar capability flags, CalDAV/Google/Microsoft recurring write payloads for base series and detached occurrences, Google base-path-preserving write URLs, Google/Microsoft provider URL path encoding, OAuth device-code, granted-scope, and refresh-token behavior, stale provider sync cursor recovery semantics, Google page-token and Microsoft nextLink pagination guards, provider HTTP 401 refresh-token retry behavior including Microsoft profile identity lookup, provider mutation conflict/retry-after/delete-gone mapping, provider HTTP put-event create/conflict/open-extension behavior, provider HTTP update preconditions and structured metadata extension fallback, provider HTTP recurring-occurrence Maybe/RSVP behavior, durable provider outbox dedupe/retry/move behavior and recovery guidance for retry/conflict/provider-blocked states, CalDAV onboarding presets for iCloud, Fastmail, Yahoo, Nextcloud, Radicale, and Baikal, live provider smoke audit-tool compilation and strict-contract checks, calendar-grid recurring edits that preserve single-occurrence `RECURRENCE-ID` overrides, split this-and-future changes, handle recurring removal scopes, Dock upcoming badge semantics, exact alert-state pruning by event id, and calendar-grid overnight/overlap layout stability without EventKit.

## Live Provider Smoke

```sh
make live-provider-smoke
```

The live smoke tool is opt-in. By default it stores no credentials and only uses environment variables for the current run:

```sh
WC_LIVE_ICS_URL="https://example.com/calendar.ics" \
WC_LIVE_CALDAV_URL="https://caldav.example.com/" \
WC_LIVE_CALDAV_USERNAME="name@example.com" \
WC_LIVE_CALDAV_PASSWORD="app-password" \
WC_LIVE_GOOGLE_ACCESS_TOKEN="ya29..." \
WC_LIVE_MICROSOFT_ACCESS_TOKEN="eyJ..." \
WC_LIVE_LOOKAHEAD_DAYS=7 \
make live-provider-smoke
```

Google and Microsoft can also be checked through the background OAuth path by providing refresh credentials instead of raw access tokens:

```sh
WC_LIVE_GOOGLE_CLIENT_ID="google-client-id" \
WC_LIVE_GOOGLE_REFRESH_TOKEN="google-refresh-token" \
WC_LIVE_MICROSOFT_CLIENT_ID="microsoft-client-id" \
WC_LIVE_MICROSOFT_REFRESH_TOKEN="microsoft-refresh-token" \
WC_LIVE_MICROSOFT_TENANT="common" \
make live-provider-smoke
```

Any source without its variables is skipped. The live smoke tool stores no credentials; refresh tokens are used in memory for the current run only. Set `WC_LIVE_USE_STORED_SOURCES=1` to fall back to the enabled provider sources already saved in Working Calendar when env credentials for a source are absent. That mode reads the app's local provider accounts and existing Keychain credentials, reports each saved source separately, and still does not print credential values.

Before touching remote providers, run a no-network/no-write preflight against saved app sources:

```sh
WC_LIVE_SMOKE_JSON=1 make live-provider-smoke-preflight
```

The preflight target defaults to `WC_LIVE_USE_STORED_SOURCES=1`, `WC_LIVE_REQUIRE_SOURCES=all`, and `WC_LIVE_REQUIRE_REFRESH_OAUTH=1`. It checks saved account URLs, CalDAV usernames and Keychain passwords, and Google/Microsoft OAuth credential readiness without fetching calendars or creating events.

By default live smoke does not write provider data. Set `WC_LIVE_WRITE_SMOKE=1` to additionally create, update, and immediately delete a short free test event on each configured writable CalDAV, Google, or Microsoft source. Set `WC_LIVE_SMOKE_JSON=1` to print the structured diagnostic reports as JSON after the human-readable summary, including writable, response-capable, read-only, incremental sync-state, HTTP-validator, subscription refresh cadence, OAuth health, and live write-probe counts.

Boolean live-smoke flags accept `1`, `true`, `yes`, or `on`.

To live-test RSVP write-back on a real invitation, point the smoke test at an existing event where the authenticated user is an attendee:

```sh
WC_LIVE_CALDAV_RSVP_OBJECT_URL="https://caldav.example.com/calendars/user/work/event.ics" \
WC_LIVE_CALDAV_RSVP_RESPONSE="maybe" \
WC_LIVE_GOOGLE_RSVP_CALENDAR_ID="primary" \
WC_LIVE_GOOGLE_RSVP_EVENT_ID="provider-event-id" \
WC_LIVE_GOOGLE_RSVP_RESPONSE="maybe" \
WC_LIVE_REQUIRE_RSVP_PROBE=1 \
make live-provider-smoke
```

Microsoft uses the same shape with `WC_LIVE_MICROSOFT_RSVP_CALENDAR_ID`, `WC_LIVE_MICROSOFT_RSVP_EVENT_ID`, and `WC_LIVE_MICROSOFT_RSVP_RESPONSE`. CalDAV RSVP probes search the fetched lookahead window for the object URL, import that object in memory, and send a scheduling reply through the server outbox. Accepted response values are `accept`, `maybe`, and `decline`.

For a release-style provider audit, use strict mode:

```sh
WC_LIVE_SMOKE_JSON=1 make live-provider-smoke-strict
```

`live-provider-smoke-strict` defaults to `WC_LIVE_REQUIRE_SOURCES=all`, `WC_LIVE_REQUIRE_WRITE_SMOKE=1`, `WC_LIVE_REQUIRE_RESPONSES=1`, and `WC_LIVE_REQUIRE_REFRESH_OAUTH=1`, so it fails if ICS, CalDAV, Google, or Microsoft 365 are skipped, if CalDAV/Google/Microsoft cannot create, update, and delete a live probe event, if they expose no response-capable calendar for RSVP write-back, or if Google/Microsoft were checked only with raw access tokens instead of refresh-token OAuth credentials. Override `WC_LIVE_REQUIRE_SOURCES` with a comma-separated subset such as `ics,caldav,google`.

To run the strict audit against already saved app sources, opt in explicitly:

```sh
WC_LIVE_USE_STORED_SOURCES=1 WC_LIVE_SMOKE_JSON=1 make live-provider-smoke-strict
```
