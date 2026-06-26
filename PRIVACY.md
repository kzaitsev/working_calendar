# Privacy Policy

Effective date: June 26, 2026

Working Calendar is a native macOS calendar app operated by Kirill Zaitsev. This Privacy Policy explains what data the app accesses, how it is used, where it is stored, and how you can delete it.

This policy is written for the current desktop version of Working Calendar. If you use a modified build, fork, or third-party distribution, that version may behave differently.

## Summary

Working Calendar is designed as a local-first desktop app:

- The app does not run a hosted calendar service.
- The app does not sell your data.
- The app does not use your calendar data for advertising.
- The app does not use your calendar data to train AI models.
- Calendar data and app settings are stored on your Mac.
- Account secrets such as OAuth refresh tokens and CalDAV passwords are stored in macOS Keychain when available.

## Data the App Accesses

Depending on the sources you connect, Working Calendar may access and store the following data:

- Calendar account information, such as provider type, account title, calendar names, calendar IDs, and account email addresses or usernames.
- Calendar event data, such as titles, descriptions, start and end times, time zones, recurrence rules, status, availability, privacy labels, categories, reminders, locations, rooms/resources, attendees, organizers, RSVP/response status, meeting links, attachments metadata, and provider sync metadata.
- Meeting participation details, such as whether you accepted, declined, tentatively accepted, or have not responded to an invitation, and attendee response status when the provider supplies it.
- App configuration, such as enabled calendars, alert rules, auto-response rules, look-ahead windows, notification preferences, and local calendar settings.
- Credentials needed to sync with providers, such as CalDAV passwords or app-specific passwords, OAuth access tokens, OAuth refresh tokens, OAuth client IDs, optional OAuth desktop client secrets, provider URLs, sync tokens, ETags, change keys, and similar provider metadata.
- Imported calendar files and subscribed calendar URLs that you add to the app.

## How the App Uses Data

Working Calendar uses the data above to provide calendar features you choose to use, including:

- Showing agenda, day, week, and month calendar views.
- Syncing calendars with connected providers.
- Creating, updating, deleting, importing, and exporting events.
- Sending RSVP responses such as accept, maybe/tentative, or decline when you choose to do so or when a rule you configured performs that action.
- Running local alert rules and showing meeting alerts before events.
- Extracting join links for services such as Zoom, Google Meet, Microsoft Teams, Skype/Lync, Webex, and similar meeting providers.
- Displaying meeting details, attendees, rooms/resources, descriptions, locations, and response status.
- Applying local rules for alert severity, auto-response behavior, and display-location overrides.
- Keeping provider sync state so the app can refresh calendars efficiently.

## Google Calendar Data

If you connect Google Calendar, Working Calendar uses Google OAuth to request access to your calendar data. The current app requests Google Calendar read/write access so it can sync calendars, show events, create and update events, delete events when requested, and send RSVP responses.

Working Calendar's use and transfer of information received from Google APIs adheres to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements.

Working Calendar uses Google user data only to provide user-facing calendar functionality in the app. It does not use Google user data for advertising, sale, creditworthiness, lending, or AI model training.

## Microsoft 365, CalDAV, and Subscription Data

If you connect Microsoft 365, Working Calendar uses Microsoft OAuth to sync calendar data and perform calendar actions you request or configure.

If you connect CalDAV, Working Calendar uses the server URL, username, and password or app-specific password you provide to sync calendar data directly with that CalDAV server.

If you add an ICS or webcal subscription, Working Calendar downloads the calendar feed from the URL you provide and stores imported event data locally.

Each third-party provider also has its own privacy policy and terms. Working Calendar is not responsible for the privacy practices of Google, Microsoft, Apple, Fastmail, Yahoo, Nextcloud, or any other provider you connect.

## Where Data Is Stored

Working Calendar stores app data on your Mac using local macOS storage. Credentials are stored in macOS Keychain when available.

The app does not intentionally upload your calendar data to a Working Calendar server. Calendar data is sent to calendar providers only as needed to sync calendars or perform actions that you request or configure, such as creating an event, updating an event, deleting an event, or sending an RSVP.

## Data Sharing

Working Calendar does not sell or rent your personal data.

Working Calendar may share data only in these limited situations:

- With calendar providers you connect, to provide syncing and calendar actions.
- With macOS system services, such as Notification Center, Dock, Keychain, and local file handling, to provide app functionality.
- If you intentionally export a calendar file, share diagnostics, send logs, or otherwise provide data to someone.
- If required to comply with applicable law or a valid legal process.

## Analytics and Tracking

The current version of Working Calendar does not include third-party analytics, advertising SDKs, or cross-app tracking.

If crash reporting, analytics, or hosted services are added in the future, this policy should be updated before those features are released.

## Retention and Deletion

Working Calendar keeps local calendar data and settings until you delete them, remove a source, reset the app, or uninstall the app and delete its local data.

You can reduce or remove stored data by:

- Removing connected calendar sources in the app.
- Disabling or deleting local calendars and events.
- Deleting imported files or subscriptions from the app.
- Removing saved credentials from macOS Keychain.
- Deleting the app's local data from your Mac.
- Revoking OAuth access from your Google or Microsoft account security settings.

Provider-side calendar data remains with the provider until you delete it there or revoke access according to that provider's tools.

## Security

Working Calendar uses platform features such as macOS Keychain to protect credentials where possible. However, no software or storage method can be guaranteed to be perfectly secure. You are responsible for protecting access to your Mac, user account, backups, and connected calendar accounts.

## Children's Privacy

Working Calendar is not directed to children under 13, and it is not intended to knowingly collect personal information from children.

## International Use

Your calendar providers may process data in countries different from where you live. Working Calendar itself is a local desktop app, but provider sync requests are handled by the third-party services you connect.

## Changes to This Policy

This policy may be updated when the app changes. The effective date at the top of this document will be updated when material changes are made.

## Contact

For privacy questions, contact:

kirik910@gmail.com
