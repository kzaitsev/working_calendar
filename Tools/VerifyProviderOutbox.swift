import Foundation

@main
struct VerifyProviderOutbox {
    @MainActor
    static func main() throws {
        try verifyOutboxDedupeAndRetry()
        try verifyOutboxDedupeIsAccountScoped()
        try verifyProviderRetryAfterOverridesRetrySchedule()
        try verifyConflictStatePausesRetryButNotSync()
        try verifyBlockedStatePausesRetryButNotSync()
        try verifyBlockedLocalWritesAreProtectedFromProviderPruning()
        try verifyBlockedDetachedOccurrencesAreProtectedFromProviderPruning()
        try verifyDeleteCancelsUnsentProviderCreate()
        try verifyMoveSupersedesStaleMutations()
        try verifyDeleteCancelsUnsentLocalToProviderMove()
        try verifyResponseWaitsForPendingProviderCreate()
        try verifyResponseWaitsForPendingMove()
        try verifyLegacyOutboxDedupeRecovery()
        try verifyRemoteObjectURLNormalizationForProviderRemoval()
        try verifyProviderAccountIdentityNormalization()
        try verifyProviderStoreUsesInjectedDefaultsDomain()
        try verifyDuplicateCalDAVAccountReusesExistingSource()
        try verifyDuplicateOAuthProviderIdentityMatching()
        try verifyProviderIdentityAliasRecording()
        print("Provider outbox invariant passed.")
    }

    @MainActor
    private static func verifyProviderStoreUsesInjectedDefaultsDomain() throws {
        let userDefaults = InMemoryCalendarProviderDefaults()
        let otherUserDefaults = InMemoryCalendarProviderDefaults()

        let store = CalendarProviderStore(userDefaults: userDefaults)
        let saved = try store.addICSSubscription(
            title: "Injected Defaults Feed",
            urlString: "webcal://calendar.example.com/work.ics"
        )

        let reloadedStore = CalendarProviderStore(userDefaults: userDefaults)
        try expect(reloadedStore.accounts.contains(where: {
            $0.id == saved.id
                && $0.kind == .icsSubscription
                && $0.endpointURLString == "https://calendar.example.com/work.ics"
        }), "Provider accounts should reload from the injected defaults domain")

        let isolatedStore = CalendarProviderStore(userDefaults: otherUserDefaults)
        try expect(isolatedStore.accounts.isEmpty,
                   "Provider accounts should not leak between defaults domains")
    }

    @MainActor
    private static func verifyOutboxDedupeAndRetry() throws {
        let store = CalendarProviderStore()
        let accountID = "provider-outbox-fixture-\(UUID().uuidString)"
        let otherAccountID = "\(accountID)-other"
        defer {
            store.removeProviderOutboxItems(accountID: accountID)
            store.removeProviderOutboxItems(accountID: otherAccountID)
        }
        store.removeProviderOutboxItems(accountID: accountID)
        store.removeProviderOutboxItems(accountID: otherAccountID)

        let now = try date("2026-07-01T09:00:00Z")
        let event = localEvent(id: "provider-outbox-event", title: "Provider outbox fixture", now: now)
        var updatedEvent = event
        updatedEvent.title = "Provider outbox fixture updated"
        updatedEvent.sequence += 1
        updatedEvent.updatedAt = now.addingTimeInterval(60)

        store.enqueueProviderOutboxItem(.write(event: event, accountID: accountID, now: now))
        store.enqueueProviderOutboxItem(.write(event: updatedEvent, accountID: accountID, now: now.addingTimeInterval(1)))
        try expect(store.providerOutboxCount(accountID: accountID) == 1,
                   "Repeated writes for the same event should collapse to one queued mutation")
        try expect(store.dueProviderOutboxItems(now: now).first?.event.title == "Provider outbox fixture updated",
                   "The latest write payload should replace stale queued writes")

        store.enqueueProviderOutboxItem(.response(
            event: updatedEvent,
            accountID: accountID,
            response: .accept,
            scope: .thisEvent,
            occurrenceStartDate: now,
            occurrenceIsAllDay: false,
            hadLocalProviderRecurrenceChanges: false,
            now: now.addingTimeInterval(2)
        ))
        store.enqueueProviderOutboxItem(.response(
            event: updatedEvent,
            accountID: accountID,
            response: .accept,
            scope: .thisEvent,
            occurrenceStartDate: now,
            occurrenceIsAllDay: false,
            hadLocalProviderRecurrenceChanges: true,
            now: now.addingTimeInterval(3)
        ))
        try expect(store.providerOutboxCount(accountID: accountID) == 2,
                   "Duplicate RSVP operations should replace matching scope/occurrence entries")
        var responseItem = try requireStoredOutboxItem(store, accountID: accountID, operation: .response)
        try expect(responseItem.hadLocalProviderRecurrenceChanges == true,
                   "The latest RSVP payload should replace stale queued RSVP metadata")

        store.enqueueProviderOutboxItem(.response(
            event: updatedEvent,
            accountID: accountID,
            response: .maybe,
            scope: .thisEvent,
            occurrenceStartDate: now,
            occurrenceIsAllDay: false,
            hadLocalProviderRecurrenceChanges: false,
            now: now.addingTimeInterval(4)
        ))
        try expect(store.providerOutboxCount(accountID: accountID) == 2,
                   "Later RSVP values should replace earlier queued RSVP values for the same occurrence")
        responseItem = try requireStoredOutboxItem(store, accountID: accountID, operation: .response)
        try expect(responseItem.response == .maybe,
                   "The latest queued RSVP value should be the only response sent for that occurrence")

        store.enqueueProviderOutboxItem(.response(
            event: updatedEvent,
            accountID: accountID,
            response: .accept,
            scope: .allEvents,
            occurrenceStartDate: nil,
            occurrenceIsAllDay: false,
            hadLocalProviderRecurrenceChanges: false,
            now: now.addingTimeInterval(5)
        ))
        try expect(store.providerOutboxCount(accountID: accountID) == 3,
                   "Series RSVP and single-occurrence RSVP should remain distinct queued mutations")

        let otherEvent = localEvent(id: "provider-outbox-other-event", title: "Other account fixture", now: now)
        store.enqueueProviderOutboxItem(.write(event: otherEvent, accountID: otherAccountID, now: now))
        try expect(store.providerOutboxCount(accountID: otherAccountID) == 1,
                   "Fixture should have an independent outbox item for another account")

        store.enqueueProviderOutboxItem(.delete(event: updatedEvent, accountID: accountID, now: now.addingTimeInterval(5)))
        try expect(store.providerOutboxCount(accountID: accountID) == 1,
                   "Delete should remove stale queued write and RSVP mutations for the same event")
        let deleteItem = try requireOutboxItem(store, accountID: accountID, operation: .delete)
        try expect(deleteItem.event.remoteObjectURLString == updatedEvent.remoteObjectURLString,
                   "Delete should preserve the remote object URL needed by the provider")
        try expect(store.providerOutboxCount(accountID: otherAccountID) == 1,
                   "Mutating one provider account should not remove unrelated account outbox items")

        store.recordProviderOutboxFailure(id: deleteItem.id, error: " network down ", at: now)
        let retryingItem = try requireOutboxItem(store, accountID: accountID, operation: .delete)
        try expect(retryingItem.attemptCount == 1, "Failed outbox items should increment attempt count")
        try expect(retryingItem.lastError == "network down", "Failed outbox items should trim and store the provider error")
        try expect(retryingItem.failureKind == .retryable, "Failed outbox items should be marked retryable by default")
        try expect(retryingItem.nextRetryAt == now.addingTimeInterval(60),
                   "First outbox retry should be delayed instead of retried every tick")
        try expect(store.dueProviderOutboxItems(now: now.addingTimeInterval(59)).allSatisfy { !$0.accountIDs.contains(accountID) },
                   "Failed outbox item should not be due before its retry time")
        try expect(store.dueProviderOutboxItems(now: now.addingTimeInterval(60)).contains { $0.id == deleteItem.id },
                   "Failed outbox item should become due at its retry time")

        store.markProviderOutboxItemDue(id: deleteItem.id, at: now.addingTimeInterval(61))
        let manuallyDueItem = try requireOutboxItem(store, accountID: accountID, operation: .delete)
        try expect(manuallyDueItem.nextRetryAt == nil,
                   "Manual due marking should clear retry delay")
        try expect(manuallyDueItem.lastError == nil,
                   "Manual due marking should clear stale retry errors")
        try expect(manuallyDueItem.failureKind == nil,
                   "Manual due marking should clear retry failure markers")
        try expect(manuallyDueItem.attemptCount == 1,
                   "Manual due marking should preserve attempt history")
        try expect(manuallyDueItem.statusText.contains("queued for retry"),
                   "Manual due marking should show queued state instead of stale failure")

        store.removeProviderOutboxItems(accountID: accountID)
        try expect(store.providerOutboxCount(accountID: accountID) == 0,
                   "Account cleanup should remove only that account's provider outbox items")
        try expect(store.providerOutboxCount(accountID: otherAccountID) == 1,
                   "Account cleanup should preserve unrelated account provider outbox items")
    }

    @MainActor
    private static func verifyOutboxDedupeIsAccountScoped() throws {
        let store = CalendarProviderStore()
        let firstAccountID = "provider-outbox-account-scope-a-\(UUID().uuidString)"
        let secondAccountID = "\(firstAccountID)-b"
        defer {
            store.removeProviderOutboxItems(accountID: firstAccountID)
            store.removeProviderOutboxItems(accountID: secondAccountID)
        }

        let now = try date("2026-07-01T09:00:00Z")
        let event = localEvent(id: "provider-outbox-account-scope-event", title: "Account scoped outbox fixture", now: now)
        var editedEvent = event
        editedEvent.title = "Account scoped outbox fixture edited"
        editedEvent.updatedAt = now.addingTimeInterval(60)

        store.enqueueProviderOutboxItem(.write(event: event, accountID: firstAccountID, now: now))
        store.enqueueProviderOutboxItem(.write(event: event, accountID: secondAccountID, now: now.addingTimeInterval(1)))
        try expect(store.providerOutbox.filter { $0.eventID == event.id && $0.operation == .write }.count == 2,
                   "Outbox writes for different provider accounts should not dedupe each other")

        store.enqueueProviderOutboxItem(.write(event: editedEvent, accountID: firstAccountID, now: now.addingTimeInterval(2)))
        let firstWrite = try requireStoredOutboxItem(store, accountID: firstAccountID, operation: .write)
        let secondWrite = try requireStoredOutboxItem(store, accountID: secondAccountID, operation: .write)
        try expect(firstWrite.event.title == editedEvent.title,
                   "Repeated writes should replace only the matching account payload")
        try expect(secondWrite.event.title == event.title,
                   "Replacing one account write should preserve unrelated account payloads")

        store.enqueueProviderOutboxItem(.delete(event: editedEvent, accountID: firstAccountID, now: now.addingTimeInterval(3)))
        let firstDelete = try requireStoredOutboxItem(store, accountID: firstAccountID, operation: .delete)
        try expect(firstDelete.event.title == editedEvent.title,
                   "Delete should replace stale writes for the same provider account")
        let preservedSecondWrite = try requireStoredOutboxItem(store, accountID: secondAccountID, operation: .write)
        try expect(preservedSecondWrite.event.title == event.title,
                   "Delete should not remove unrelated account outbox writes for the same local event")
    }

    @MainActor
    private static func verifyProviderRetryAfterOverridesRetrySchedule() throws {
        let store = CalendarProviderStore()
        let accountID = "provider-outbox-retry-after-\(UUID().uuidString)"
        defer { store.removeProviderOutboxItems(accountID: accountID) }
        store.removeProviderOutboxItems(accountID: accountID)

        let now = try date("2026-07-01T09:00:00Z")
        let event = localEvent(id: "provider-outbox-retry-after-event", title: "Provider retry-after fixture", now: now)
        store.enqueueProviderOutboxItem(.write(event: event, accountID: accountID, now: now))
        let queuedItem = try requireStoredOutboxItem(store, accountID: accountID, operation: .write)
        try expect(queuedItem.recoveryAction == .queued,
                   "Fresh provider outbox items should report that Working Calendar will sync them automatically")

        store.recordProviderOutboxFailure(
            id: queuedItem.id,
            error: " rate limited ",
            at: now,
            retryAfterSeconds: 180
        )
        let providerDelayedItem = try requireStoredOutboxItem(store, accountID: accountID, operation: .write)
        try expect(providerDelayedItem.attemptCount == 1,
                   "Provider retry-after failures should still record the failed attempt")
        try expect(providerDelayedItem.lastError == "rate limited",
                   "Provider retry-after failures should trim and store the provider error")
        try expect(providerDelayedItem.nextRetryAt == now.addingTimeInterval(180),
                   "Provider Retry-After should override the first exponential retry delay")
        try expect(providerDelayedItem.recoveryAction == .automaticRetry,
                   "Provider retry-after failures should expose an automatic retry recovery action")
        try expect(providerDelayedItem.recoverySummaryText.contains("Waiting"),
                   "Provider retry-after recovery copy should explain that the item is waiting")
        try expect(store.dueProviderOutboxItems(now: now.addingTimeInterval(179)).allSatisfy { $0.id != queuedItem.id },
                   "Provider Retry-After should keep the outbox item paused until the provider delay elapses")
        try expect(store.dueProviderOutboxItems(now: now.addingTimeInterval(180)).contains { $0.id == queuedItem.id },
                   "Provider Retry-After should make the outbox item due exactly at the provider delay")

        store.recordProviderOutboxFailure(
            id: queuedItem.id,
            error: " network down ",
            at: now.addingTimeInterval(180)
        )
        let exponentialItem = try requireStoredOutboxItem(store, accountID: accountID, operation: .write)
        try expect(exponentialItem.attemptCount == 2,
                   "A second provider outbox failure should increment attempt history")
        try expect(exponentialItem.nextRetryAt == now.addingTimeInterval(300),
                   "A later failure without Retry-After should return to exponential retry scheduling")
        store.markProviderOutboxItemDue(id: queuedItem.id, at: now.addingTimeInterval(301))
        let manualRetryItem = try requireStoredOutboxItem(store, accountID: accountID, operation: .write)
        try expect(manualRetryItem.recoveryAction == .retryNow,
                   "Manually due provider failures should expose a ready-to-retry recovery action")
    }

    @MainActor
    private static func verifyProviderAccountIdentityNormalization() throws {
        let now = try date("2026-07-01T08:00:00Z")
        let account = CalendarProviderAccount(
            id: "provider-identity-normalization",
            kind: .googleCalendar,
            title: "Identity Normalization",
            endpointURLString: "https://www.googleapis.com/calendar/v3",
            username: nil,
            identityEmail: "mailto:ME%2Bcalendar%40example.com?subject=calendar",
            identityEmailAliases: [
                "SMTP:ALIAS%40example.com?subject=calendar#fragment",
                "alias@example.com",
                "mailto:ME%2Bcalendar%40example.com"
            ],
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

        try expect(account.identityEmail == "me+calendar@example.com",
                   "Provider account init should normalize primary identity email")
        try expect(account.identityEmailAliases == ["alias@example.com"],
                   "Provider account init should normalize aliases and remove primary duplicates")
        try expect(
            CalendarProviderAccount.normalizedIdentityEmails([
                "mailto:ME%2Bcalendar%40example.com?subject=calendar",
                "SMTP:ALIAS%40example.com?subject=calendar#fragment",
                "alias@example.com",
                "not-an-email",
                "mailto:SECOND%40example.com#fragment"
            ]) == ["me+calendar@example.com", "alias@example.com", "second@example.com"],
            "Shared provider identity normalizer should canonicalize mailto, smtp, percent-encoding, and duplicates"
        )

        let legacyJSON = """
        {
          "id": "provider-identity-legacy",
          "kind": "microsoft365",
          "title": "Legacy Identity",
          "endpointURLString": "https://graph.microsoft.com/v1.0",
          "username": null,
          "identityEmail": "SMTP:PRIMARY%40example.com?subject=calendar#fragment",
          "identityEmailAliases": [
            "mailto:ALIAS%40example.com?subject=calendar",
            "alias@example.com",
            "smtp:PRIMARY%40example.com?subject=calendar#fragment"
          ],
          "credentialKey": null,
          "enabled": true,
          "importedEventCount": 0,
          "updatedEventCount": 0,
          "skippedEventCount": 0,
          "deletedEventCount": 0,
          "calDAVSyncStates": [],
          "googleCalendarSyncStates": [],
          "microsoftGraphSyncStates": [],
          "lastSyncAt": null,
          "lastError": null,
          "createdAt": \(now.timeIntervalSinceReferenceDate),
          "updatedAt": \(now.timeIntervalSinceReferenceDate)
        }
        """
        let decoded = try JSONDecoder().decode(CalendarProviderAccount.self, from: Data(legacyJSON.utf8))
        try expect(decoded.identityEmail == "primary@example.com",
                   "Provider account decode should normalize legacy primary identity email")
        try expect(decoded.identityEmailAliases == ["alias@example.com"],
                   "Provider account decode should normalize legacy aliases and remove primary duplicates")
    }

    @MainActor
    private static func verifyDuplicateCalDAVAccountReusesExistingSource() throws {
        resetProviderStorage()
        let credentialStore = InMemoryCalendarCredentialStore()
        let store = CalendarProviderStore(credentialStore: credentialStore)
        let first = try store.addCalDAVAccount(
            title: "Work CalDAV",
            urlString: "caldavs://DAV.EXAMPLE.com/remote.php/dav/",
            username: "ME@example.com",
            password: "first-password"
        )
        store.setAccount(first, enabled: false)
        defer {
            if let account = store.accounts.first(where: { $0.id == first.id }) {
                store.delete(account)
            }
            resetProviderStorage()
        }

        let duplicate = try store.addCalDAVAccount(
            title: "Work CalDAV Reconnected",
            urlString: "https://dav.example.com/remote.php/dav/",
            username: "mailto:me%40example.com",
            password: "second-password"
        )

        try expect(store.accounts.count == 1,
                   "Adding the same normalized CalDAV account should reuse the existing provider source")
        try expect(duplicate.id == first.id,
                   "Duplicate CalDAV add should return the existing provider source")
        try expect(duplicate.enabled,
                   "Duplicate CalDAV add should re-enable a disabled source")
        try expect(duplicate.title == "Work CalDAV Reconnected",
                   "Duplicate CalDAV add with a non-empty title should refresh the source title")
        try expect(duplicate.endpointURLString == "https://dav.example.com/remote.php/dav/",
                   "Duplicate CalDAV source should keep the canonical normalized endpoint URL")
        try expect(duplicate.username == "mailto:me%40example.com",
                   "Duplicate CalDAV reconnect should preserve the newly entered username form for display/auth")
        guard let credentialKey = duplicate.credentialKey else {
            throw ProviderOutboxInvariantError("Duplicate CalDAV source should keep a credential key")
        }
        try expect(credentialStore.passwords[credentialKey] == "second-password",
                   "Duplicate CalDAV reconnect should update the existing credential key")
    }

    @MainActor
    private static func verifyDuplicateOAuthProviderIdentityMatching() throws {
        resetProviderStorage()
        let credentialStore = InMemoryCalendarCredentialStore()
        let store = CalendarProviderStore(credentialStore: credentialStore)
        defer { resetProviderStorage() }

        let googleExisting = try store.addGoogleCalendarAccount(
            title: "Work Google",
            accessToken: "first-google-token"
        )
        store.recordAccountIdentityEmails(
            accountID: googleExisting.id,
            identityEmails: ["primary@example.com", "alias@example.com"]
        )
        store.setAccount(googleExisting, enabled: false)

        let googleIncoming = try store.addGoogleCalendarAccount(
            title: "Work Google Reconnect",
            accessToken: "second-google-token"
        )
        let googleMatch = store.accountMatchingIdentity(
            kind: .googleCalendar,
            excluding: googleIncoming.id,
            identityEmails: ["SMTP:ALIAS%40example.com?subject=calendar#fragment"]
        )
        try expect(googleMatch?.id == googleExisting.id,
                   "Incoming Google identity aliases should match an existing Google provider source")

        let microsoftExisting = try store.addMicrosoft365Account(
            title: "Work Microsoft",
            accessToken: "first-microsoft-token"
        )
        store.recordAccountIdentityEmails(
            accountID: microsoftExisting.id,
            identityEmails: ["owner@example.com", "m365.alias@example.com"]
        )
        let microsoftIncoming = try store.addMicrosoft365Account(
            title: "Work Microsoft Reconnect",
            accessToken: "second-microsoft-token"
        )
        let microsoftMatch = store.accountMatchingIdentity(
            kind: .microsoft365,
            excluding: microsoftIncoming.id,
            identityEmails: ["mailto:M365.ALIAS%40example.com?subject=calendar"]
        )
        try expect(microsoftMatch?.id == microsoftExisting.id,
                   "Incoming Microsoft identity aliases should match an existing Microsoft provider source")

        let crossKindMatch = store.accountMatchingIdentity(
            kind: .microsoft365,
            excluding: microsoftIncoming.id,
            identityEmails: ["alias@example.com"]
        )
        try expect(crossKindMatch == nil,
                   "Duplicate OAuth identity matching should not cross provider kinds")

        let emptyMatch = store.accountMatchingIdentity(
            kind: .googleCalendar,
            excluding: googleIncoming.id,
            identityEmails: ["not-an-email"]
        )
        try expect(emptyMatch == nil,
                   "Duplicate OAuth identity matching should ignore unusable identity values")
    }

    @MainActor
    private static func verifyProviderIdentityAliasRecording() throws {
        let store = CalendarProviderStore()
        let account = try store.addICSSubscription(
            title: "Identity alias fixture",
            urlString: "https://calendar.example.com/identity-alias.ics"
        )
        defer { store.delete(account) }

        store.recordAccountIdentityEmails(
            accountID: account.id,
            identityEmails: [
                "mailto:PRIMARY%40example.com?subject=calendar",
                "alias@example.com",
                "SMTP:ALIAS%40example.com?subject=calendar#fragment",
                "second.alias@example.com"
            ],
            at: try date("2026-07-01T09:00:00Z")
        )

        guard let recorded = store.accounts.first(where: { $0.id == account.id }) else {
            throw ProviderOutboxInvariantError("Expected identity alias fixture account to remain stored")
        }
        try expect(recorded.identityEmail == "primary@example.com",
                   "Provider identity recording should normalize the primary identity email")
        try expect(recorded.identityEmailAliases == ["alias@example.com", "second.alias@example.com"],
                   "Provider identity recording should preserve normalized unique aliases")

        let updatedAt = recorded.updatedAt
        store.recordAccountIdentityEmails(
            accountID: account.id,
            identityEmails: ["primary@example.com", "alias@example.com", "second.alias@example.com"],
            at: try date("2026-07-01T10:00:00Z")
        )
        try expect(store.accounts.first(where: { $0.id == account.id })?.updatedAt == updatedAt,
                   "Provider identity recording should not touch updatedAt when identities do not change")
    }

    @MainActor
    private static func verifyConflictStatePausesRetryButNotSync() throws {
        let store = CalendarProviderStore()
        let accountID = "provider-outbox-conflict-\(UUID().uuidString)"
        let retryableAccountID = "\(accountID)-retryable"
        defer {
            store.removeProviderOutboxItems(accountID: accountID)
            store.removeProviderOutboxItems(accountID: retryableAccountID)
        }
        store.removeProviderOutboxItems(accountID: accountID)
        store.removeProviderOutboxItems(accountID: retryableAccountID)

        let now = try date("2026-07-01T09:00:00Z")
        let event = localEvent(id: "provider-outbox-conflict-event", title: "Provider conflict fixture", now: now)
        store.enqueueProviderOutboxItem(.write(event: event, accountID: accountID, now: now))
        let queuedItem = try requireStoredOutboxItem(store, accountID: accountID, operation: .write)

        store.recordProviderOutboxConflict(
            id: queuedItem.id,
            error: " remote changed ",
            at: now.addingTimeInterval(10)
        )
        let conflictItem = try requireStoredOutboxItem(store, accountID: accountID, operation: .write)
        try expect(conflictItem.attemptCount == 1, "Conflicted outbox items should record the failed attempt")
        try expect(conflictItem.lastError == "remote changed", "Conflicted outbox items should trim and store the provider error")
        try expect(conflictItem.failureKind == .conflict, "Conflicted outbox items should keep an explicit conflict marker")
        try expect(conflictItem.isBlockedByConflict, "Conflicted outbox items should report conflict blocking")
        try expect(conflictItem.nextRetryAt == nil, "Conflicted outbox items should not schedule blind automatic retries")
        try expect(conflictItem.statusText.contains("remote conflict"), "Conflicted outbox status should distinguish remote conflicts")
        try expect(conflictItem.recoveryAction == .syncThenRetry,
                   "Conflicted outbox items should tell the UI to sync the source before retrying")
        try expect(conflictItem.recoveryHelpText.contains("remote event changed"),
                   "Conflict recovery help should explain why sync must happen before retry")
        try expect(
            !store.dueProviderOutboxItems(now: .distantFuture).contains { $0.id == conflictItem.id },
            "Conflicted outbox items should not be due for automatic retry"
        )
        try expect(store.hasProviderOutboxItems(accountID: accountID),
                   "Conflicted outbox items should remain visible in the outbox")
        try expect(!store.hasSyncBlockingProviderOutboxItems(accountID: accountID),
                   "Conflicted outbox items should not block inbound sync needed to fetch the remote version")
        try expect(store.providerOutboxConflictCount(accountID: accountID) == 1,
                   "Provider conflict count should include conflicted outbox items")
        try expect(store.conflictedProviderOutboxCount >= 1,
                   "Global conflict count should include conflicted outbox items")
        var multiAccountConflictItem = conflictItem
        let secondaryAccountID = "\(accountID)-secondary"
        multiAccountConflictItem.accountIDs = [secondaryAccountID, accountID, accountID]
        let retryableItem = ProviderOutboxItem.write(
            event: localEvent(id: "provider-outbox-conflict-retryable", title: "Retryable fixture", now: now),
            accountID: "\(accountID)-retryable",
            now: now
        )
        try expect(
            store.conflictRetryAccountIDs(for: [retryableItem, multiAccountConflictItem]) == [accountID, secondaryAccountID].sorted(),
            "Conflict retry should sync only conflicted account IDs, de-duped and sorted"
        )
        store.enqueueProviderOutboxItem(retryableItem)
        let storedRetryableItem = try requireStoredOutboxItem(store, accountID: retryableAccountID, operation: .write)
        store.recordProviderOutboxFailure(
            id: storedRetryableItem.id,
            error: "network down",
            at: now.addingTimeInterval(11)
        )
        store.markAllRetryableProviderOutboxItemsDue(at: now.addingTimeInterval(12))
        let dueRetryableItem = try requireStoredOutboxItem(store, accountID: retryableAccountID, operation: .write)
        let stillConflictedItem = try requireStoredOutboxItem(store, accountID: accountID, operation: .write)
        try expect(dueRetryableItem.nextRetryAt == nil,
                   "Retry-all fallback should make retryable failures due")
        try expect(dueRetryableItem.failureKind == nil,
                   "Retry-all fallback should clear retryable failure markers")
        try expect(stillConflictedItem.isBlockedByConflict,
                   "Retry-all fallback should leave conflicted items blocked until pre-sync succeeds")
        try expect(!store.dueProviderOutboxItems(now: .distantFuture).contains { $0.id == stillConflictedItem.id },
                   "Retry-all fallback should not make conflicted items due without pre-sync")
        store.removeProviderOutboxItems(accountID: retryableAccountID)

        let encodedConflict = try JSONEncoder().encode(conflictItem)
        let decodedConflict = try JSONDecoder().decode(ProviderOutboxItem.self, from: encodedConflict)
        try expect(decodedConflict.failureKind == .conflict,
                   "Conflict marker should survive provider outbox persistence")
        try expect(decodedConflict.isBlockedByConflict,
                   "Decoded conflicted outbox items should remain blocked by conflict")

        var syncedRemoteEvent = event
        syncedRemoteEvent.title = "Remote provider version after sync"
        syncedRemoteEvent.notes = "Remote notes after sync"
        syncedRemoteEvent.calendarID = "\(event.calendarID)-synced"
        syncedRemoteEvent.remoteObjectURLString = "caldav://calendar.example.com/work/conflict-event-new.ics"
        syncedRemoteEvent.remoteETag = "\"fresh-remote-etag\""
        let retryPayload = conflictItem.writePayload(usingCurrentEvent: syncedRemoteEvent)
        try expect(retryPayload.title == event.title,
                   "Manual conflict retry should keep the queued local write payload")
        try expect(retryPayload.notes == event.notes,
                   "Manual conflict retry should keep queued local notes instead of the synced remote body")
        try expect(retryPayload.calendarID == syncedRemoteEvent.calendarID,
                   "Manual conflict retry should use the current synced calendar binding")
        try expect(retryPayload.remoteObjectURLString == syncedRemoteEvent.remoteObjectURLString,
                   "Manual conflict retry should use the current synced remote object URL")
        try expect(retryPayload.remoteETag == "\"fresh-remote-etag\"",
                   "Manual conflict retry should use the current synced ETag")

        store.markProviderOutboxItemDue(id: conflictItem.id, at: now.addingTimeInterval(20))
        let retryItem = try requireStoredOutboxItem(store, accountID: accountID, operation: .write)
        try expect(retryItem.failureKind == nil, "Manual retry should clear the conflict marker")
        try expect(retryItem.lastError == nil, "Manual retry should clear the stale conflict error")
        try expect(retryItem.attemptCount == 1, "Manual retry should preserve the failed conflict attempt count")
        try expect(retryItem.recoveryAction == .retryNow,
                   "Manual conflict retry should expose a ready-to-retry recovery action")
        try expect(retryItem.statusText.contains("queued for retry"),
                   "Manual retry should show queued state instead of stale conflict")
        try expect(store.hasSyncBlockingProviderOutboxItems(accountID: accountID),
                   "Manually retried outbox items should block inbound sync again until sent or failed")
        try expect(store.dueProviderOutboxItems(now: now.addingTimeInterval(20)).contains { $0.id == retryItem.id },
                   "Manual retry should make a formerly conflicted item due")

        var editedAfterConflict = event
        editedAfterConflict.title = "Provider conflict fixture edited again"
        editedAfterConflict.notes = "Fresh local edit after conflict"
        editedAfterConflict.updatedAt = now.addingTimeInterval(30)
        store.recordProviderOutboxConflict(
            id: retryItem.id,
            error: " remote changed again ",
            at: now.addingTimeInterval(31)
        )
        let secondConflictItem = try requireStoredOutboxItem(store, accountID: accountID, operation: .write)
        try expect(secondConflictItem.isBlockedByConflict,
                   "Fixture should have a conflicted item before a fresh local edit")
        store.enqueueProviderOutboxItem(.write(event: editedAfterConflict, accountID: accountID, now: now.addingTimeInterval(32)))
        let replacementItem = try requireStoredOutboxItem(store, accountID: accountID, operation: .write)
        try expect(replacementItem.event.title == "Provider conflict fixture edited again",
                   "A fresh local edit should replace the stale conflicted write payload")
        try expect(replacementItem.lastError == nil,
                   "A fresh local edit should clear stale conflict errors")
        try expect(replacementItem.failureKind == nil,
                   "A fresh local edit should clear stale conflict markers")
        try expect(replacementItem.attemptCount == 0,
                   "A fresh local edit should reset stale conflict attempt history")
        try expect(store.dueProviderOutboxItems(now: now.addingTimeInterval(32)).contains { $0.id == replacementItem.id },
                   "A fresh local edit after conflict should be due as a normal queued write")
    }

    @MainActor
    private static func verifyBlockedStatePausesRetryButNotSync() throws {
        let store = CalendarProviderStore()
        let accountID = "provider-outbox-blocked-\(UUID().uuidString)"
        let retryableAccountID = "\(accountID)-retryable"
        defer {
            store.removeProviderOutboxItems(accountID: accountID)
            store.removeProviderOutboxItems(accountID: retryableAccountID)
        }
        store.removeProviderOutboxItems(accountID: accountID)
        store.removeProviderOutboxItems(accountID: retryableAccountID)

        let now = try date("2026-07-01T09:00:00Z")
        let event = localEvent(id: "provider-outbox-blocked-event", title: "Provider blocked fixture", now: now)
        store.enqueueProviderOutboxItem(.write(event: event, accountID: accountID, now: now))
        let queuedItem = try requireStoredOutboxItem(store, accountID: accountID, operation: .write)

        store.recordProviderOutboxBlocked(
            id: queuedItem.id,
            error: " provider rejected this update ",
            at: now.addingTimeInterval(10)
        )
        let blockedItem = try requireStoredOutboxItem(store, accountID: accountID, operation: .write)
        try expect(blockedItem.attemptCount == 1, "Blocked outbox items should record the failed attempt")
        try expect(blockedItem.lastError == "provider rejected this update", "Blocked outbox items should trim and store the provider error")
        try expect(blockedItem.failureKind == .blocked, "Blocked outbox items should keep an explicit blocked marker")
        try expect(blockedItem.isBlockedByProviderRejection, "Blocked outbox items should report provider rejection blocking")
        try expect(blockedItem.recoveryAction == .editOrFixAccess,
                   "Provider-blocked outbox items should tell the UI to edit the event or fix source access")
        try expect(blockedItem.recoveryHelpText.contains("provider permissions"),
                   "Provider-blocked recovery help should mention source permissions")
        try expect(store.providerOutboxBlockedCount(accountID: accountID) == 1,
                   "Provider-blocked outbox items should be counted separately from normal pending updates")
        try expect(store.providerOutboxConflictCount(accountID: accountID) == 0,
                   "Provider-blocked outbox items should not be counted as remote conflicts")
        try expect(store.blockedProviderOutboxCount == 1,
                   "Global provider-blocked outbox count should include blocked provider rejections")
        try expect(blockedItem.nextRetryAt == nil, "Blocked outbox items should not schedule blind automatic retries")
        try expect(blockedItem.statusText.contains("blocked by provider"), "Blocked outbox status should distinguish provider rejections")
        try expect(
            !store.dueProviderOutboxItems(now: .distantFuture).contains { $0.id == blockedItem.id },
            "Blocked outbox items should not be due for automatic retry"
        )
        try expect(store.hasProviderOutboxItems(accountID: accountID),
                   "Blocked outbox items should remain visible in the outbox")
        try expect(!store.hasSyncBlockingProviderOutboxItems(accountID: accountID),
                   "Blocked outbox items should not block inbound sync that may refresh provider capabilities")

        let retryableItem = ProviderOutboxItem.write(
            event: localEvent(id: "provider-outbox-blocked-retryable", title: "Retryable blocked fixture", now: now),
            accountID: retryableAccountID,
            now: now
        )
        store.enqueueProviderOutboxItem(retryableItem)
        let storedRetryableItem = try requireStoredOutboxItem(store, accountID: retryableAccountID, operation: .write)
        store.recordProviderOutboxFailure(
            id: storedRetryableItem.id,
            error: "network down",
            at: now.addingTimeInterval(11)
        )
        store.markAllRetryableProviderOutboxItemsDue(at: now.addingTimeInterval(12))
        let dueRetryableItem = try requireStoredOutboxItem(store, accountID: retryableAccountID, operation: .write)
        let stillBlockedItem = try requireStoredOutboxItem(store, accountID: accountID, operation: .write)
        try expect(dueRetryableItem.nextRetryAt == nil,
                   "Retry-all fallback should make retryable failures due")
        try expect(dueRetryableItem.failureKind == nil,
                   "Retry-all fallback should clear retryable failure markers")
        try expect(stillBlockedItem.isBlockedByProviderRejection,
                   "Retry-all fallback should leave provider-blocked items blocked until a manual retry")
        try expect(store.providerOutboxBlockedCount(accountID: accountID) == 1,
                   "Retry-all fallback should keep provider-blocked counts intact")
        try expect(!store.dueProviderOutboxItems(now: .distantFuture).contains { $0.id == stillBlockedItem.id },
                   "Retry-all fallback should not make provider-blocked items due automatically")

        let encodedBlocked = try JSONEncoder().encode(blockedItem)
        let decodedBlocked = try JSONDecoder().decode(ProviderOutboxItem.self, from: encodedBlocked)
        try expect(decodedBlocked.failureKind == .blocked,
                   "Blocked marker should survive provider outbox persistence")
        try expect(decodedBlocked.isBlockedByProviderRejection,
                   "Decoded blocked outbox items should remain blocked by provider rejection")

        store.markProviderOutboxItemDue(id: blockedItem.id, at: now.addingTimeInterval(20))
        let retryItem = try requireStoredOutboxItem(store, accountID: accountID, operation: .write)
        try expect(retryItem.failureKind == nil, "Manual retry should clear the blocked marker")
        try expect(retryItem.lastError == nil, "Manual retry should clear blocked provider errors")
        try expect(retryItem.recoveryAction == .retryNow,
                   "Manual retry for provider-blocked items should expose a ready-to-retry recovery action")
        try expect(store.providerOutboxBlockedCount(accountID: accountID) == 0,
                   "Manual retry should remove provider-blocked items from blocked counts")
        try expect(retryItem.nextRetryAt == nil, "Manual retry should make blocked items due immediately")
        try expect(store.hasSyncBlockingProviderOutboxItems(accountID: accountID),
                   "Manually retried blocked outbox items should block inbound sync again until sent or failed")
        try expect(store.dueProviderOutboxItems(now: now.addingTimeInterval(21)).contains { $0.id == retryItem.id },
                   "Manually retried blocked outbox items should become due")
    }

    @MainActor
    private static func verifyBlockedLocalWritesAreProtectedFromProviderPruning() throws {
        resetProviderStorage()
        resetLocalCalendarStorage()
        defer {
            resetProviderStorage()
            resetLocalCalendarStorage()
        }

        let providerStore = CalendarProviderStore()
        let localStore = LocalCalendarStore()
        let accountID = "provider-prune-protection-\(UUID().uuidString)"
        let calendarID = "local-calendar-caldav-\(accountID)-work"
        let now = try date("2026-07-01T09:00:00Z")
        let storedURL = "https://caldav.example.com:443/dav/calendars/me/work/blocked-write.ics"
        let providerURL = "https://caldav.example.com/dav/calendars/me/work/blocked-write.ics"

        let importSummary = try localStore.importICSText("""
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Provider Outbox Fixture//EN
        BEGIN:VEVENT
        UID:blocked-provider-write@example.com
        DTSTAMP:20260701T090000Z
        DTSTART:20260701T090000Z
        DTEND:20260701T093000Z
        SUMMARY:Blocked provider write fixture
        X-WORKING-CALENDAR-ID:\(calendarID)
        X-WORKING-CALENDAR-TITLE:Protected Provider Calendar
        X-WORKING-CALENDAR-COLOR:#0A84FF
        X-WORKING-REMOTE-OBJECT-URL:\(storedURL)
        X-WORKING-REMOTE-ETAG:"blocked-write-etag"
        END:VEVENT
        END:VCALENDAR
        """)
        try expect(importSummary.eventsImported == 1,
                   "Expected blocked provider write fixture to import")
        guard let savedEvent = localStore.events.first(where: { $0.calendarID == calendarID }) else {
            throw ProviderOutboxInvariantError("Expected blocked provider write fixture after import")
        }
        localStore.setRemoteObjectURL(
            eventID: savedEvent.id,
            remoteObjectURLString: storedURL,
            remoteETag: "\"blocked-write-etag\""
        )
        guard let protectedEvent = localStore.events.first(where: { $0.id == savedEvent.id }),
              localStore.calendars.contains(where: { $0.id == calendarID })
        else {
            throw ProviderOutboxInvariantError("Expected blocked provider write fixture after remote binding")
        }

        providerStore.enqueueProviderOutboxItem(.write(event: protectedEvent, accountID: accountID, now: now))
        let writeItem = try requireStoredOutboxItem(providerStore, accountID: accountID, operation: .write)
        providerStore.recordProviderOutboxBlocked(
            id: writeItem.id,
            error: "provider rejected unsupported recurrence",
            at: now.addingTimeInterval(1)
        )

        let protectedRemoteObjectURLs = providerStore.remoteObjectURLsProtectedFromPruning(accountID: accountID)
        let protectedCalendarIDs = providerStore.calendarIDsProtectedFromPruning(accountID: accountID)
        try expect(protectedRemoteObjectURLs.contains(providerURL),
                   "Blocked provider writes should expose their remote object URL for prune protection")
        try expect(protectedCalendarIDs.contains(calendarID),
                   "Blocked provider writes should expose their calendar ID for prune protection")
        try expect(!providerStore.hasSyncBlockingProviderOutboxItems(accountID: accountID),
                   "Blocked provider writes should still allow sync so conflicts can be inspected")

        try expect(
            localStore.removeProviderEvents(
                remoteObjectURLs: [providerURL],
                calendarIDs: [calendarID],
                protectingRemoteObjectURLs: protectedRemoteObjectURLs
            ) == 0,
            "Provider deleted-object removal should keep a blocked local write protected by outbox"
        )
        try expect(localStore.events.count == 1,
                   "Blocked local provider writes should survive protected deleted-object removal")

        try expect(
            localStore.pruneProviderEvents(
                calendarID: calendarID,
                keepingRemoteObjectURLs: [],
                pruneRange: DateInterval(
                    start: now.addingTimeInterval(-60),
                    end: now.addingTimeInterval(60 * 60)
                ),
                protectingRemoteObjectURLs: protectedRemoteObjectURLs
            ) == 0,
            "Provider range pruning should keep a blocked local write protected by outbox"
        )
        try expect(localStore.events.count == 1,
                   "Blocked local provider writes should survive protected range pruning")

        let protectedCalendarPrune = localStore.pruneProviderCalendars(
            ownedCalendarIDs: [calendarID],
            keepingCalendarIDs: [],
            protectingCalendarIDs: protectedCalendarIDs
        )
        try expect(protectedCalendarPrune.calendarsDeleted == 0 && protectedCalendarPrune.eventsDeleted == 0,
                   "Provider calendar pruning should keep a calendar with a blocked local write protected by outbox")
        try expect(localStore.calendars.contains { $0.id == calendarID },
                   "Protected provider calendar should survive calendar pruning")
        try expect(localStore.events.count == 1,
                   "Events in a protected provider calendar should survive calendar pruning")

        let unprotectedCalendarPrune = localStore.pruneProviderCalendars(
            ownedCalendarIDs: [calendarID],
            keepingCalendarIDs: []
        )
        try expect(unprotectedCalendarPrune.calendarsDeleted == 1 && unprotectedCalendarPrune.eventsDeleted == 1,
                   "Unprotected provider calendar pruning should remove missing calendars and their events")
        try expect(!localStore.calendars.contains { $0.id == calendarID },
                   "Unprotected provider calendar pruning should remove the missing calendar")
        try expect(localStore.events.isEmpty,
                   "Unprotected provider calendar pruning should remove events in the missing calendar")

        let restoredSummary = try localStore.importICSText("""
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Provider Outbox Fixture//EN
        BEGIN:VEVENT
        UID:blocked-provider-write-restored@example.com
        DTSTAMP:20260701T090000Z
        DTSTART:20260701T090000Z
        DTEND:20260701T093000Z
        SUMMARY:Blocked provider write fixture restored
        X-WORKING-CALENDAR-ID:\(calendarID)
        X-WORKING-CALENDAR-TITLE:Protected Provider Calendar
        X-WORKING-CALENDAR-COLOR:#0A84FF
        X-WORKING-REMOTE-OBJECT-URL:\(storedURL)
        X-WORKING-REMOTE-ETAG:"blocked-write-etag"
        END:VEVENT
        END:VCALENDAR
        """)
        try expect(restoredSummary.eventsImported == 1,
                   "Expected blocked provider write fixture to restore before unprotected event pruning")

        try expect(
            localStore.pruneProviderEvents(
                calendarID: calendarID,
                keepingRemoteObjectURLs: [],
                pruneRange: DateInterval(
                    start: now.addingTimeInterval(-60),
                    end: now.addingTimeInterval(60 * 60)
                )
            ) == 1,
            "Unprotected provider pruning should still remove missing remote objects")
        try expect(localStore.events.isEmpty,
                   "Unprotected pruning should remove the missing provider object")
    }

    @MainActor
    private static func verifyBlockedDetachedOccurrencesAreProtectedFromProviderPruning() throws {
        resetProviderStorage()
        resetLocalCalendarStorage()
        defer {
            resetProviderStorage()
            resetLocalCalendarStorage()
        }

        let providerStore = CalendarProviderStore()
        let localStore = LocalCalendarStore()
        let accountID = "provider-detached-prune-protection-\(UUID().uuidString)"
        let calendarID = "local-calendar-microsoft365-\(accountID)-work"
        let baseURL = "https://graph.microsoft.com/v1.0/me/calendars/work/events/base"
        let detachedURL = "https://graph.microsoft.com/v1.0/me/calendars/work/events/detached-20260708"
        let originalStart = try date("2026-07-08T09:00:00Z")
        let pruneRange = DateInterval(
            start: try date("2026-07-08T00:00:00Z"),
            end: try date("2026-07-09T00:00:00Z")
        )

        let importSummary = try localStore.importICSText("""
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Working Calendar//Provider Outbox Fixture//EN
        BEGIN:VEVENT
        UID:blocked-detached-provider-write@example.com
        DTSTAMP:20260701T090000Z
        DTSTART:20260701T090000Z
        DTEND:20260701T093000Z
        RRULE:FREQ=WEEKLY;COUNT=3
        SUMMARY:Blocked detached base fixture
        X-WORKING-CALENDAR-ID:\(calendarID)
        X-WORKING-CALENDAR-TITLE:Protected Detached Calendar
        X-WORKING-CALENDAR-COLOR:#5E5CE6
        X-WORKING-REMOTE-OBJECT-URL:\(baseURL)
        X-WORKING-REMOTE-ETAG:"blocked-detached-base-etag"
        END:VEVENT
        BEGIN:VEVENT
        UID:blocked-detached-provider-write@example.com
        RECURRENCE-ID:20260708T090000Z
        DTSTAMP:20260701T091000Z
        DTSTART:20260708T100000Z
        DTEND:20260708T103000Z
        SUMMARY:Blocked detached moved fixture
        X-WORKING-CALENDAR-ID:\(calendarID)
        X-WORKING-CALENDAR-TITLE:Protected Detached Calendar
        X-WORKING-CALENDAR-COLOR:#5E5CE6
        X-WORKING-REMOTE-OBJECT-URL:\(detachedURL)
        END:VEVENT
        END:VCALENDAR
        """)
        try expect(importSummary.eventsImported == 1,
                   "Expected blocked detached provider fixture to import as one recurring event")
        guard let protectedEvent = localStore.events.first(where: { $0.calendarID == calendarID }) else {
            throw ProviderOutboxInvariantError("Expected blocked detached provider fixture event")
        }
        try expect(protectedEvent.detachedOccurrences.count == 1,
                   "Expected blocked detached provider fixture to include one detached occurrence")

        providerStore.enqueueProviderOutboxItem(.write(event: protectedEvent, accountID: accountID))
        let writeItem = try requireStoredOutboxItem(providerStore, accountID: accountID, operation: .write)
        providerStore.recordProviderOutboxConflict(
            id: writeItem.id,
            error: "remote changed",
            at: try date("2026-07-01T09:05:00Z")
        )

        let protectedRemoteObjectURLs = providerStore.remoteObjectURLsProtectedFromPruning(accountID: accountID)
        try expect(protectedRemoteObjectURLs.contains(baseURL),
                   "Blocked recurring writes should protect the base remote object URL")
        try expect(protectedRemoteObjectURLs.contains(detachedURL),
                   "Blocked recurring writes should protect detached occurrence remote object URLs")

        try expect(
            localStore.removeProviderEvents(
                remoteObjectURLs: [detachedURL],
                calendarIDs: [calendarID],
                protectingRemoteObjectURLs: protectedRemoteObjectURLs
            ) == 0,
            "Provider deleted-object removal should keep protected detached occurrences")
        try expect(localStore.events.first?.detachedOccurrences.count == 1,
                   "Protected detached occurrence should survive deleted-object removal")

        try expect(
            localStore.pruneProviderEvents(
                calendarID: calendarID,
                keepingRemoteObjectURLs: [baseURL],
                pruneRange: pruneRange,
                protectingRemoteObjectURLs: protectedRemoteObjectURLs
            ) == 0,
            "Provider range pruning should keep protected detached occurrences")
        try expect(localStore.events.first?.detachedOccurrences.count == 1,
                   "Protected detached occurrence should survive range pruning")

        try expect(
            localStore.cancelProviderDetachedOccurrences(
                remoteObjectURLs: [detachedURL],
                calendarIDs: [calendarID],
                protectingRemoteObjectURLs: protectedRemoteObjectURLs
            ) == 0,
            "Provider detached cancellation should keep protected detached occurrences")
        try expect(localStore.events.first?.detachedOccurrences.count == 1,
                   "Protected detached occurrence should survive detached cancellation")
        try expect(localStore.events.first?.excludedOccurrenceStartDates.contains { sameInstant($0, originalStart) } == false,
                   "Protected detached cancellation should not add an exclusion for the occurrence")

        let remoteOccurrenceCancellation: Set<LocalProviderRemoteOccurrenceCancellation> = [
            LocalProviderRemoteOccurrenceCancellation(
                masterRemoteObjectURLString: baseURL,
                occurrenceStartDate: originalStart
            )
        ]
        try expect(
            localStore.cancelProviderRemoteOccurrences(
                remoteOccurrenceCancellation,
                calendarIDs: [calendarID],
                protectingRemoteObjectURLs: protectedRemoteObjectURLs
            ) == 0,
            "Provider occurrence cancellation should keep protected recurring occurrences")
        try expect(localStore.events.first?.detachedOccurrences.count == 1,
                   "Protected detached occurrence should survive master occurrence cancellation")
        try expect(localStore.events.first?.excludedOccurrenceStartDates.contains { sameInstant($0, originalStart) } == false,
                   "Protected master occurrence cancellation should not add an exclusion")

        try expect(
            localStore.cancelProviderDetachedOccurrences(
                remoteObjectURLs: [detachedURL],
                calendarIDs: [calendarID]
            ) == 1,
            "Unprotected provider detached cancellation should still remove detached occurrences")
        try expect(localStore.events.first?.detachedOccurrences.isEmpty == true,
                   "Unprotected detached cancellation should remove the detached occurrence")
        try expect(localStore.events.first?.excludedOccurrenceStartDates.contains { sameInstant($0, originalStart) } == true,
                   "Unprotected detached cancellation should exclude the cancelled original occurrence")
    }

    @MainActor
    private static func verifyMoveSupersedesStaleMutations() throws {
        let store = CalendarProviderStore()
        let sourceAccountID = "provider-outbox-move-source-\(UUID().uuidString)"
        let destinationAccountID = "\(sourceAccountID)-destination"
        let otherAccountID = "\(sourceAccountID)-other"
        defer {
            store.removeProviderOutboxItems(accountID: sourceAccountID)
            store.removeProviderOutboxItems(accountID: destinationAccountID)
            store.removeProviderOutboxItems(accountID: otherAccountID)
        }
        store.removeProviderOutboxItems(accountID: sourceAccountID)
        store.removeProviderOutboxItems(accountID: destinationAccountID)
        store.removeProviderOutboxItems(accountID: otherAccountID)

        let now = try date("2026-07-01T09:00:00Z")
        let previousEvent = localEvent(
            id: "provider-outbox-move-event",
            title: "Provider move fixture",
            calendarID: "local-calendar-google-\(sourceAccountID)-source",
            remoteObjectURLString: "google://\(sourceAccountID)/source/event",
            remoteETag: "\"source-etag\"",
            now: now
        )
        var movedEvent = previousEvent
        movedEvent.calendarID = "local-calendar-microsoft365-\(destinationAccountID)-destination"
        movedEvent.title = "Provider move fixture moved"
        movedEvent.sequence += 1
        movedEvent.updatedAt = now.addingTimeInterval(120)

        store.enqueueProviderOutboxItem(.write(event: previousEvent, accountID: sourceAccountID, now: now))
        store.enqueueProviderOutboxItem(.response(
            event: previousEvent,
            accountID: sourceAccountID,
            response: .maybe,
            scope: .thisEvent,
            occurrenceStartDate: now,
            occurrenceIsAllDay: false,
            hadLocalProviderRecurrenceChanges: true,
            now: now.addingTimeInterval(1)
        ))
        store.enqueueProviderOutboxItem(.move(
            previousEvent: previousEvent,
            event: movedEvent,
            accountIDs: [destinationAccountID, sourceAccountID, sourceAccountID],
            now: now.addingTimeInterval(2)
        ))

        try expect(store.providerOutboxCount(accountID: sourceAccountID) == 1,
                   "Move should supersede stale writes and responses for the moved event")
        try expect(store.providerOutboxCount(accountID: destinationAccountID) == 1,
                   "Move should be queued for the destination provider account")
        let moveItem = try requireOutboxItem(store, accountID: sourceAccountID, operation: .move)
        try expect(moveItem.accountIDs == [destinationAccountID, sourceAccountID].sorted(),
                   "Move should keep a sorted unique account set")
        try expect(moveItem.previousEvent?.calendarID == previousEvent.calendarID,
                   "Move should preserve the source calendar needed for remote delete")
        try expect(moveItem.previousEvent?.remoteObjectURLString == previousEvent.remoteObjectURLString,
                   "Move should preserve the source remote object URL needed for remote delete")
        try expect(moveItem.previousEvent?.remoteETag == "\"source-etag\"",
                   "Move should preserve the source ETag needed for conflict-safe delete")
        try expect(moveItem.event.calendarID == movedEvent.calendarID,
                   "Move should preserve the destination calendar needed for remote create")
        try expect(moveItem.event.title == "Provider move fixture moved",
                   "Move should preserve the latest destination event payload")

        var editedMovedEvent = movedEvent
        editedMovedEvent.title = "Provider move fixture moved and edited"
        editedMovedEvent.sequence += 1
        editedMovedEvent.updatedAt = now.addingTimeInterval(180)
        store.enqueueProviderOutboxItem(.write(
            event: editedMovedEvent,
            accountID: destinationAccountID,
            now: now.addingTimeInterval(3)
        ))
        try expect(store.providerOutbox.filter { $0.eventID == movedEvent.id }.count == 1,
                   "Write after a pending move should fold into the move instead of queuing a stale follow-up write")
        let updatedMoveItem = try requireOutboxItem(store, accountID: destinationAccountID, operation: .move)
        try expect(updatedMoveItem.event.title == "Provider move fixture moved and edited",
                   "Write after a pending move should refresh the move destination payload")
        try expect(updatedMoveItem.previousEvent?.remoteObjectURLString == previousEvent.remoteObjectURLString,
                   "Write folding should preserve the source remote object URL needed for move deletion")

        store.enqueueProviderOutboxItem(.response(
            event: editedMovedEvent,
            accountID: destinationAccountID,
            response: .accept,
            scope: .allEvents,
            occurrenceStartDate: nil,
            occurrenceIsAllDay: false,
            hadLocalProviderRecurrenceChanges: false,
            now: now.addingTimeInterval(3.5)
        ))
        try expect(store.providerOutbox.filter { $0.eventID == movedEvent.id }.count == 2,
                   "Response after a pending move should wait behind the move before the final delete")

        let otherEvent = localEvent(id: "provider-outbox-move-other", title: "Other move fixture", now: now)
        store.enqueueProviderOutboxItem(.write(event: otherEvent, accountID: otherAccountID, now: now.addingTimeInterval(4)))
        try expect(store.providerOutboxCount(accountID: otherAccountID) == 1,
                   "Move cleanup should not remove unrelated account mutations")

        store.enqueueProviderOutboxItem(.delete(event: editedMovedEvent, accountID: destinationAccountID, now: now.addingTimeInterval(5)))
        try expect(store.providerOutboxCount(accountID: sourceAccountID) == 1,
                   "Delete after an unsent move should keep the source account delete needed to remove the remote object")
        try expect(store.providerOutboxCount(accountID: destinationAccountID) == 0,
                   "Delete after an unsent move should cancel the destination create instead of deleting a non-existent destination object")
        let deleteItem = try requireOutboxItem(store, accountID: sourceAccountID, operation: .delete)
        try expect(deleteItem.event.id == movedEvent.id, "Final delete should target the moved event")
        try expect(deleteItem.event.calendarID == previousEvent.calendarID,
                   "Final delete after an unsent move should target the source provider calendar")
        try expect(deleteItem.event.remoteObjectURLString == previousEvent.remoteObjectURLString,
                   "Final delete after an unsent move should preserve the source remote object URL")
        try expect(deleteItem.event.remoteETag == previousEvent.remoteETag,
                   "Final delete after an unsent move should preserve the source remote ETag")
        try expect(deleteItem.accountIDs == [sourceAccountID],
                   "Final delete after an unsent move should be scoped to the source provider account")
        try expect(!store.providerOutbox.contains {
            $0.operation == .response && $0.eventID == movedEvent.id && $0.accountIDs.contains(destinationAccountID)
        }, "Final delete after an unsent move should remove destination responses waiting for that move")
    }

    @MainActor
    private static func verifyDeleteCancelsUnsentProviderCreate() throws {
        let store = CalendarProviderStore()
        let accountID = "provider-outbox-unsent-create-\(UUID().uuidString)"
        defer { store.removeProviderOutboxItems(accountID: accountID) }
        store.removeProviderOutboxItems(accountID: accountID)

        let now = try date("2026-07-01T09:00:00Z")
        let event = localEvent(
            id: "provider-outbox-unsent-create-event",
            title: "Unsent provider create fixture",
            calendarID: "local-calendar-google-\(accountID)-primary",
            remoteObjectURLString: "",
            remoteETag: "",
            now: now
        )

        try expect(store.enqueueProviderOutboxItem(.write(event: event, accountID: accountID, now: now)),
                   "Unsent provider create should queue a write")
        try expect(store.providerOutboxCount(accountID: accountID) == 1,
                   "Unsent provider create fixture should start with one queued write")
        try expect(!store.enqueueProviderOutboxItem(.delete(event: event, accountID: accountID, now: now.addingTimeInterval(60))),
                   "Deleting an unsent provider create should cancel queued remote work instead of queuing a no-op delete")
        try expect(store.providerOutboxCount(accountID: accountID) == 0,
                   "Deleting an unsent provider create should remove the queued write")
        try expect(!store.hasProviderOutboxItems(accountID: accountID),
                   "Deleting an unsent provider create should not leave provider sync paused")
    }

    @MainActor
    private static func verifyDeleteCancelsUnsentLocalToProviderMove() throws {
        let store = CalendarProviderStore()
        let destinationAccountID = "provider-outbox-local-move-destination-\(UUID().uuidString)"
        defer {
            store.removeProviderOutboxItems(accountID: destinationAccountID)
        }
        store.removeProviderOutboxItems(accountID: destinationAccountID)

        let now = try date("2026-07-01T09:00:00Z")
        let localEvent = localEvent(
            id: "provider-outbox-local-to-provider-move",
            title: "Local to provider move fixture",
            calendarID: "local-calendar-manual-source",
            remoteObjectURLString: "",
            remoteETag: "",
            now: now
        )
        var movedEvent = localEvent
        movedEvent.calendarID = "local-calendar-google-\(destinationAccountID)-destination"
        movedEvent.title = "Local to provider move fixture moved"
        movedEvent.updatedAt = now.addingTimeInterval(60)

        store.enqueueProviderOutboxItem(.move(
            previousEvent: localEvent,
            event: movedEvent,
            accountIDs: [destinationAccountID],
            now: now
        ))
        try expect(store.providerOutboxCount(accountID: destinationAccountID) == 1,
                   "Local-to-provider move should queue a destination provider create")

        store.enqueueProviderOutboxItem(.delete(
            event: movedEvent,
            accountID: destinationAccountID,
            now: now.addingTimeInterval(120)
        ))
        try expect(store.providerOutboxCount(accountID: destinationAccountID) == 0,
                   "Deleting a local-to-provider move before sync should cancel the unsent provider create")
        try expect(!store.hasProviderOutboxItems(accountID: destinationAccountID),
                   "Cancelled local-to-provider moves should not leave a no-op delete that pauses provider sync")
    }

    @MainActor
    private static func verifyResponseWaitsForPendingProviderCreate() throws {
        let store = CalendarProviderStore()
        let accountID = "provider-outbox-create-response-\(UUID().uuidString)"
        let unrelatedAccountID = "\(accountID)-unrelated"
        defer {
            store.removeProviderOutboxItems(accountID: accountID)
            store.removeProviderOutboxItems(accountID: unrelatedAccountID)
        }
        store.removeProviderOutboxItems(accountID: accountID)
        store.removeProviderOutboxItems(accountID: unrelatedAccountID)

        let now = try date("2026-07-01T09:00:00Z")
        let event = localEvent(
            id: "provider-outbox-create-response-event",
            title: "Provider create response fixture",
            calendarID: "local-calendar-google-\(accountID)-primary",
            remoteObjectURLString: "",
            remoteETag: "",
            now: now
        )
        store.enqueueProviderOutboxItem(.write(event: event, accountID: accountID, now: now))
        store.enqueueProviderOutboxItem(.response(
            event: event,
            accountID: accountID,
            response: .accept,
            scope: .thisEvent,
            occurrenceStartDate: event.startDate,
            occurrenceIsAllDay: false,
            hadLocalProviderRecurrenceChanges: false,
            now: now.addingTimeInterval(1)
        ))
        store.enqueueProviderOutboxItem(.response(
            event: event,
            accountID: unrelatedAccountID,
            response: .maybe,
            scope: .thisEvent,
            occurrenceStartDate: event.startDate,
            occurrenceIsAllDay: false,
            hadLocalProviderRecurrenceChanges: false,
            now: now.addingTimeInterval(2)
        ))

        let dueBeforeCreateCompletes = store.dueProviderOutboxItems(now: now.addingTimeInterval(3))
        try expect(dueBeforeCreateCompletes.contains { $0.operation == .write && $0.eventID == event.id },
                   "Pending provider creates should remain due")
        try expect(!dueBeforeCreateCompletes.contains {
            $0.operation == .response && $0.eventID == event.id && $0.accountIDs.contains(accountID)
        }, "Provider responses should wait until a pending create has a remote object")
        try expect(dueBeforeCreateCompletes.contains {
            $0.operation == .response && $0.eventID == event.id && $0.accountIDs.contains(unrelatedAccountID)
        }, "Pending provider creates should not delay responses for unrelated provider accounts")

        let writeItem = try requireStoredOutboxItem(store, accountID: accountID, operation: .write)
        store.removeProviderOutboxItem(id: writeItem.id)
        let dueAfterCreateCompletes = store.dueProviderOutboxItems(now: now.addingTimeInterval(3))
        try expect(dueAfterCreateCompletes.contains {
            $0.operation == .response && $0.eventID == event.id && $0.accountIDs.contains(accountID)
        }, "Provider responses should become due after the pending create leaves the outbox")
    }

    @MainActor
    private static func verifyResponseWaitsForPendingMove() throws {
        let store = CalendarProviderStore()
        let sourceAccountID = "provider-outbox-move-response-source-\(UUID().uuidString)"
        let destinationAccountID = "\(sourceAccountID)-destination"
        let unrelatedAccountID = "\(sourceAccountID)-unrelated"
        defer {
            store.removeProviderOutboxItems(accountID: sourceAccountID)
            store.removeProviderOutboxItems(accountID: destinationAccountID)
            store.removeProviderOutboxItems(accountID: unrelatedAccountID)
        }
        store.removeProviderOutboxItems(accountID: sourceAccountID)
        store.removeProviderOutboxItems(accountID: destinationAccountID)
        store.removeProviderOutboxItems(accountID: unrelatedAccountID)

        let now = try date("2026-07-01T09:00:00Z")
        let previousEvent = localEvent(
            id: "provider-outbox-move-response-event",
            title: "Provider move response fixture",
            calendarID: "local-calendar-google-\(sourceAccountID)-source",
            remoteObjectURLString: "google://\(sourceAccountID)/source/event",
            remoteETag: "\"source-etag\"",
            now: now
        )
        var movedEvent = previousEvent
        movedEvent.calendarID = "local-calendar-microsoft365-\(destinationAccountID)-destination"
        movedEvent.remoteObjectURLString = ""
        movedEvent.remoteETag = ""
        movedEvent.title = "Provider move response fixture moved"
        movedEvent.sequence += 1
        movedEvent.updatedAt = now.addingTimeInterval(60)

        store.enqueueProviderOutboxItem(.move(
            previousEvent: previousEvent,
            event: movedEvent,
            accountIDs: [sourceAccountID, destinationAccountID],
            now: now
        ))
        store.enqueueProviderOutboxItem(.response(
            event: movedEvent,
            accountID: destinationAccountID,
            response: .accept,
            scope: .allEvents,
            occurrenceStartDate: nil,
            occurrenceIsAllDay: false,
            hadLocalProviderRecurrenceChanges: false,
            now: now.addingTimeInterval(1)
        ))
        store.enqueueProviderOutboxItem(.response(
            event: movedEvent,
            accountID: unrelatedAccountID,
            response: .maybe,
            scope: .allEvents,
            occurrenceStartDate: nil,
            occurrenceIsAllDay: false,
            hadLocalProviderRecurrenceChanges: false,
            now: now.addingTimeInterval(2)
        ))

        let dueBeforeMoveCompletes = store.dueProviderOutboxItems(now: now.addingTimeInterval(3))
        try expect(dueBeforeMoveCompletes.contains { $0.operation == .move && $0.eventID == movedEvent.id },
                   "Pending provider moves should remain due")
        try expect(!dueBeforeMoveCompletes.contains {
            $0.operation == .response && $0.eventID == movedEvent.id && $0.accountIDs.contains(destinationAccountID)
        },
                   "Provider responses should wait until a pending move creates the destination remote event")
        try expect(dueBeforeMoveCompletes.contains {
            $0.operation == .response && $0.eventID == movedEvent.id && $0.accountIDs.contains(unrelatedAccountID)
        },
                   "Pending provider moves should not delay responses for unrelated provider accounts")

        let moveItem = try requireStoredOutboxItem(store, accountID: sourceAccountID, operation: .move)
        store.removeProviderOutboxItem(id: moveItem.id)

        let dueAfterMoveCompletes = store.dueProviderOutboxItems(now: now.addingTimeInterval(3))
        try expect(dueAfterMoveCompletes.contains { $0.operation == .response && $0.eventID == movedEvent.id },
                   "Provider responses should become due after the pending move leaves the outbox")
    }

    @MainActor
    private static func verifyLegacyOutboxDedupeRecovery() throws {
        let now = try date("2026-07-01T09:00:00Z")
        let event = localEvent(id: "provider-outbox-legacy-event", title: "Legacy outbox fixture", now: now)
        let encoded = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "operation": "response",
          "eventID": "\(event.id)",
          "accountIDs": ["provider-outbox-legacy"],
          "event": \(try json(event)),
          "response": "maybe",
          "responseScope": "thisEvent",
          "responseOccurrenceStartDate": \(event.startDate.timeIntervalSinceReferenceDate),
          "createdAt": \(now.timeIntervalSinceReferenceDate),
          "updatedAt": \(now.timeIntervalSinceReferenceDate),
          "attemptCount": 0,
          "dedupeKey": " "
        }
        """
        let item = try JSONDecoder().decode(ProviderOutboxItem.self, from: Data(encoded.utf8))
        try expect(item.dedupeKey == "response:\(event.id):thisEvent:\(Int(event.startDate.timeIntervalSinceReferenceDate))",
                   "Legacy blank outbox dedupe keys should be regenerated on decode")

        let legacyGlobalJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000002",
          "operation": "write",
          "eventID": "\(event.id)",
          "event": \(try json(event)),
          "createdAt": \(now.addingTimeInterval(1).timeIntervalSinceReferenceDate),
          "updatedAt": \(now.addingTimeInterval(1).timeIntervalSinceReferenceDate),
          "attemptCount": 0,
          "dedupeKey": "write:\(event.id)"
        }
        """
        let legacyGlobalItem = try JSONDecoder().decode(ProviderOutboxItem.self, from: Data(legacyGlobalJSON.utf8))
        let store = CalendarProviderStore()
        let legacyAccountID = "provider-outbox-legacy"
        defer { store.removeProviderOutboxItems(accountID: legacyAccountID) }

        store.enqueueProviderOutboxItem(legacyGlobalItem)
        try expect(store.providerOutboxCount(accountID: legacyAccountID) == 1,
                   "Legacy outbox items without account IDs should remain visible for account badges")
        try expect(store.hasProviderOutboxItems(accountID: legacyAccountID),
                   "Legacy outbox items without account IDs should be reported for provider accounts")
        try expect(store.hasSyncBlockingProviderOutboxItems(accountID: legacyAccountID),
                   "Queued legacy outbox items without account IDs should still block sync")
        try expect(store.dueProviderOutboxItems(now: now.addingTimeInterval(2)).contains { $0.id == legacyGlobalItem.id },
                   "Legacy outbox items without account IDs should remain due for processing")
        store.removeProviderOutboxItems(accountID: legacyAccountID)
        try expect(!store.providerOutbox.contains { $0.id == legacyGlobalItem.id },
                   "Account cleanup should remove legacy outbox items without account IDs")
    }

    @MainActor
    private static func verifyRemoteObjectURLNormalizationForProviderRemoval() throws {
        resetLocalCalendarStorage()
        let store = LocalCalendarStore()
        let start = try date("2026-07-01T09:00:00Z")
        var draft = store.draft(start: start, end: start.addingTimeInterval(30 * 60))
        draft.title = "Remote URL normalization fixture"
        guard let event = store.save(draft) else {
            throw ProviderOutboxInvariantError("Expected remote URL normalization fixture to save")
        }

        let storedURL = "https://caldav.example.com:443/dav/calendars/me/work/event.ics"
        let providerURL = "https://caldav.example.com/dav/calendars/me/work/event.ics"
        store.setRemoteObjectURL(
            eventID: event.id,
            remoteObjectURLString: storedURL,
            remoteETag: "\"remote-url-normalization-etag\""
        )
        try expect(store.events.count == 1, "Expected one fixture event before provider removal")
        try expect(store.removeProviderEvents(remoteObjectURLs: [providerURL]) == 1,
                   "Provider removal should normalize default HTTPS ports before comparing remote object URLs")
        try expect(store.events.isEmpty, "Expected normalized provider removal to delete the fixture event")

        let encodedStore = LocalCalendarStore()
        var encodedDraft = encodedStore.draft(start: start, end: start.addingTimeInterval(30 * 60))
        encodedDraft.title = "Remote URL percent encoding fixture"
        guard let encodedEvent = encodedStore.save(encodedDraft) else {
            throw ProviderOutboxInvariantError("Expected remote URL percent encoding fixture to save")
        }
        encodedStore.setRemoteObjectURL(
            eventID: encodedEvent.id,
            remoteObjectURLString: "https://caldav.example.com/dav/work/%7Euser/Project%20Sync%2fAgenda.ics?token=%7Ealpha%2fbeta",
            remoteETag: "\"remote-url-percent-normalization-etag\""
        )
        try expect(
            encodedStore.removeProviderEvents(
                remoteObjectURLs: [
                    "https://caldav.example.com/dav/work/~user/Project%20Sync%2FAgenda.ics?token=~alpha%2Fbeta"
                ]
            ) == 1,
            "Provider removal should normalize unreserved percent escapes and percent-escape hex case"
        )
        try expect(encodedStore.events.isEmpty,
                   "Expected percent-normalized provider removal to delete the fixture event")

        resetLocalCalendarStorage()
        let pruneStore = LocalCalendarStore()
        var pruneDraft = pruneStore.draft(start: start, end: start.addingTimeInterval(30 * 60))
        pruneDraft.title = "Remote URL prune normalization fixture"
        guard let pruneEvent = pruneStore.save(pruneDraft) else {
            throw ProviderOutboxInvariantError("Expected remote URL prune normalization fixture to save")
        }
        pruneStore.setRemoteObjectURL(
            eventID: pruneEvent.id,
            remoteObjectURLString: storedURL,
            remoteETag: "\"remote-url-prune-normalization-etag\""
        )
        try expect(
            pruneStore.pruneProviderEvents(
                calendarIDPrefix: "local-calendar-",
                keepingRemoteObjectURLs: [providerURL]
            ) == 0,
            "Provider pruning should normalize default HTTPS ports before comparing remote object URLs"
        )
        try expect(pruneStore.events.count == 1, "Expected normalized provider pruning to keep the fixture event")

        resetLocalCalendarStorage()
        let reservedStore = LocalCalendarStore()
        var reservedDraft = reservedStore.draft(start: start, end: start.addingTimeInterval(30 * 60))
        reservedDraft.title = "Remote URL reserved escape fixture"
        guard let reservedEvent = reservedStore.save(reservedDraft) else {
            throw ProviderOutboxInvariantError("Expected remote URL reserved escape fixture to save")
        }
        reservedStore.setRemoteObjectURL(
            eventID: reservedEvent.id,
            remoteObjectURLString: "https://caldav.example.com/dav/work/a%2Fb.ics",
            remoteETag: "\"remote-url-reserved-escape-etag\""
        )
        try expect(
            reservedStore.removeProviderEvents(
                remoteObjectURLs: ["https://caldav.example.com/dav/work/a/b.ics"]
            ) == 0,
            "Provider removal should not collapse escaped reserved path separators into literal slashes"
        )
        try expect(reservedStore.events.count == 1,
                   "Expected reserved escaped path segment to remain distinct from a literal slash path")
        resetLocalCalendarStorage()
    }

    private static func localEvent(id: String, title: String, now: Date) -> LocalCalendarEvent {
        localEvent(
            id: id,
            title: title,
            calendarID: "local-calendar-caldav-provider-outbox-fixture-work",
            remoteObjectURLString: "caldav://calendar.example.com/work/\(id).ics",
            remoteETag: "\"etag-\(id)\"",
            now: now
        )
    }

    private static func localEvent(
        id: String,
        title: String,
        calendarID: String,
        remoteObjectURLString: String,
        remoteETag: String,
        now: Date
    ) -> LocalCalendarEvent {
        LocalCalendarEvent(
            id: id,
            externalUID: "\(id)@example.com",
            remoteObjectURLString: remoteObjectURLString,
            remoteETag: remoteETag,
            sequence: 1,
            calendarID: calendarID,
            title: title,
            startDate: now,
            endDate: now.addingTimeInterval(30 * 60),
            isAllDay: false,
            location: "CY-Office-1st-Conference",
            notes: "Provider outbox invariant fixture",
            urlString: "https://meet.example.com/\(id)",
            recurrenceFrequency: .weekly,
            recurrenceInterval: 1,
            recurrenceWeekdays: [4],
            recurrenceEndDate: now.addingTimeInterval(14 * 24 * 3600),
            createdAt: now,
            updatedAt: now
        )
    }

    private static func resetLocalCalendarStorage() {
        UserDefaults.standard.removeObject(forKey: "localCalendars")
        UserDefaults.standard.removeObject(forKey: "localCalendarEvents")
        UserDefaults.standard.removeObject(forKey: "selectedLocalCalendarIDs")
    }

    private static func resetProviderStorage() {
        UserDefaults.standard.removeObject(forKey: "calendarProviderAccounts")
        UserDefaults.standard.removeObject(forKey: "calendarProviderOutbox")
    }

    @MainActor
    private static func requireOutboxItem(
        _ store: CalendarProviderStore,
        accountID: String,
        operation: ProviderOutboxOperation
    ) throws -> ProviderOutboxItem {
        let matches = store.dueProviderOutboxItems(now: .distantFuture).filter {
            $0.accountIDs.contains(accountID) && $0.operation == operation
        }
        guard matches.count == 1, let item = matches.first else {
            throw ProviderOutboxInvariantError("Expected exactly one \(operation.rawValue) outbox item for \(accountID), got \(matches.count)")
        }
        return item
    }

    @MainActor
    private static func requireStoredOutboxItem(
        _ store: CalendarProviderStore,
        accountID: String,
        operation: ProviderOutboxOperation
    ) throws -> ProviderOutboxItem {
        let matches = store.providerOutbox.filter {
            $0.accountIDs.contains(accountID) && $0.operation == operation
        }
        guard matches.count == 1, let item = matches.first else {
            throw ProviderOutboxInvariantError("Expected exactly one stored \(operation.rawValue) outbox item for \(accountID), got \(matches.count)")
        }
        return item
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProviderOutboxInvariantError("Could not encode fixture JSON")
        }
        return text
    }

    private static func date(_ value: String) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            throw ProviderOutboxInvariantError("Could not parse date fixture \(value)")
        }
        return date
    }

    private static func sameInstant(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 0.5
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw ProviderOutboxInvariantError(message)
        }
    }
}

private struct ProviderOutboxInvariantError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private final class InMemoryCalendarCredentialStore: CalendarCredentialStoring {
    private(set) var passwords: [String: String] = [:]

    func savePassword(_ password: String, key: String) -> Bool {
        passwords[key] = password
        return true
    }

    func deletePassword(key: String) {
        passwords.removeValue(forKey: key)
    }
}

private final class InMemoryCalendarProviderDefaults: CalendarProviderDefaultsStoring {
    private var values: [String: Any] = [:]

    func data(forKey defaultName: String) -> Data? {
        values[defaultName] as? Data
    }

    func set(_ value: Any?, forKey defaultName: String) {
        guard let value else {
            values.removeValue(forKey: defaultName)
            return
        }
        values[defaultName] = value
    }
}
