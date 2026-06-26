import AppKit
import Combine
import Foundation

private struct CalDAVAccountSyncResult {
    let summary: LocalICSImportSummary
    let syncStates: [CalDAVCalendarSyncState]
    let accountIdentityEmails: [String]
}

private struct GoogleCalendarAccountSyncResult {
    let summary: LocalICSImportSummary
    let syncStates: [GoogleCalendarSyncState]
    let accountIdentityEmails: [String]
}

private struct MicrosoftGraphAccountSyncResult {
    let summary: LocalICSImportSummary
    let syncStates: [MicrosoftGraphSyncState]
    let accountIdentityEmails: [String]
}

private struct ResponseAttemptKey: Hashable {
    let eventID: String
    let ruleID: UUID
    let action: RuleResponseAction
    let scope: CalendarEventResponseScope
}

struct CalendarBackendInfo: Hashable {
    let sourceTitle: String
    let sourceKind: CalendarProviderKind
    let sourceKindTitle: String
    let isProviderBacked: Bool
    let isSourceEnabled: Bool
    let allowsEventWrite: Bool
    let allowsResponses: Bool
    let pendingOutboxCount: Int
    let attentionOutboxCount: Int
    let lastSyncAt: Date?
    let lastError: String?

    var storageText: String {
        isProviderBacked ? sourceTitle : "Stored locally"
    }

    static let local = CalendarBackendInfo(
        sourceTitle: "Working Calendar",
        sourceKind: .local,
        sourceKindTitle: CalendarProviderKind.local.title,
        isProviderBacked: false,
        isSourceEnabled: true,
        allowsEventWrite: true,
        allowsResponses: true,
        pendingOutboxCount: 0,
        attentionOutboxCount: 0,
        lastSyncAt: nil,
        lastError: nil
    )

    var capabilityText: String {
        if !isProviderBacked {
            return "App-owned"
        }
        if !isSourceEnabled {
            return "Source disabled"
        }
        if allowsEventWrite {
            return "Two-way"
        }
        if allowsResponses {
            return "Responses only"
        }
        return "Read-only"
    }
}

@MainActor
final class AppModel: ObservableObject {
    let localCalendarStore = LocalCalendarStore()
    let providerStore = CalendarProviderStore()
    let ruleStore = AlertRuleStore()

    @Published private(set) var activeAlert: MeetingAlert?
    @Published private(set) var isRunning = false
    @Published private(set) var providerSyncMessage: String?
    @Published private(set) var syncingProviderIDs: Set<String> = []
    @Published private(set) var isProviderSyncPassRunning = false
    @Published private(set) var isProviderOutboxProcessing = false
    @Published private(set) var lastProviderSyncAt: Date?
    @Published var lookAheadHours: Double = 12 {
        didSet { UserDefaults.standard.set(lookAheadHours, forKey: Keys.lookAheadHours) }
    }
    @Published var responseLookAheadHours: Double = 48 {
        didSet { UserDefaults.standard.set(responseLookAheadHours, forKey: Keys.responseLookAheadHours) }
    }
    @Published var providerSyncIntervalMinutes: Double = 5 {
        didSet { UserDefaults.standard.set(providerSyncIntervalMinutes, forKey: Keys.providerSyncIntervalMinutes) }
    }

    private let alertEngine = AlertEngine()
    private let dockIconService = DockIconService()
    private let notificationService = NotificationService()
    private let overlayController = MeetingAlertWindowController()
    private let calDAVClient = CalDAVClient()
    private let googleCalendarClient = GoogleCalendarClient()
    private let microsoftGraphClient = MicrosoftGraphCalendarClient()
    private var timer: Timer?
    private var responseAttempts: Set<ResponseAttemptKey> = []
    private var currentProviderActionFailureKind: ProviderOutboxFailureKind = .retryable
    private var currentProviderRetryAfterSeconds: Int?
    private var cancellables: Set<AnyCancellable> = []
    private var externalCalendarOpenDeduper = ExternalCalendarOpenDeduper()
    private let providerCredentialPassword: (String) -> String?

    private enum Keys {
        static let lookAheadHours = "appLookAheadHours"
        static let responseLookAheadHours = "appResponseLookAheadHours"
        static let providerSyncIntervalMinutes = "appProviderSyncIntervalMinutes"
    }

    init(providerCredentialPassword: @escaping (String) -> String? = CalendarCredentialStore.password) {
        self.providerCredentialPassword = providerCredentialPassword

        let storedLookAhead = UserDefaults.standard.double(forKey: Keys.lookAheadHours)
        if storedLookAhead > 0 {
            lookAheadHours = storedLookAhead
        }

        let storedResponseLookAhead = UserDefaults.standard.double(forKey: Keys.responseLookAheadHours)
        if storedResponseLookAhead > 0 {
            responseLookAheadHours = storedResponseLookAhead
        }

        let storedProviderSyncInterval = UserDefaults.standard.double(forKey: Keys.providerSyncIntervalMinutes)
        if storedProviderSyncInterval > 0 {
            providerSyncIntervalMinutes = storedProviderSyncInterval
        }

        localCalendarStore.$events
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                    self?.updateDockIcon()
                    self?.reconcileActiveAlert(now: Date())
                }
            }
            .store(in: &cancellables)

        localCalendarStore.$calendars
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                    self?.updateDockIcon()
                    self?.reconcileActiveAlert(now: Date())
                }
            }
            .store(in: &cancellables)

        localCalendarStore.$selectedCalendarIDs
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                    self?.updateDockIcon()
                    self?.reconcileActiveAlert(now: Date())
                }
            }
            .store(in: &cancellables)

        ruleStore.$rules
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                    self?.reconcileActiveAlert(now: Date())
                }
            }
            .store(in: &cancellables)

        providerStore.$accounts
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                    self?.updateDockIcon()
                    self?.reconcileActiveAlert(now: Date())
                }
            }
            .store(in: &cancellables)

        providerStore.$providerOutbox
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        updateDockIcon()
        notificationService.requestAuthorization()

        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
        Task { await syncProviderSources(force: true) }
    }

    func tick() {
        let now = Date()
        updateDockIcon()
        processAutomaticResponses(now: now)
        reconcileActiveAlert(now: now)
        processProviderOutboxIfNeeded(now: now)
        scheduleProviderSyncIfNeeded(now: now)

        let alerts = alertEngine.evaluate(
            events: alertEvents(now: now),
            rules: ruleStore.rules,
            now: now
        )

        guard let alert = alerts.first else { return }
        present(alert)
    }

    func present(_ alert: MeetingAlert) {
        activeAlert = alert
        notificationService.deliver(alert)

        guard alert.rule.stickyOverlay else {
            overlayController.hide()
            return
        }

        overlayController.show(
            alert: alert,
            dismiss: { [weak self] in self?.dismissActiveAlert() },
            snooze: { [weak self] in self?.snoozeActiveAlert(minutes: 3) },
            join: { [weak self] in self?.joinActiveAlert() }
        )
    }

    private func refreshActiveAlert(_ alert: MeetingAlert) {
        activeAlert = alert

        guard alert.rule.stickyOverlay else {
            overlayController.hide()
            return
        }

        overlayController.show(
            alert: alert,
            dismiss: { [weak self] in self?.dismissActiveAlert() },
            snooze: { [weak self] in self?.snoozeActiveAlert(minutes: 3) },
            join: { [weak self] in self?.joinActiveAlert() },
            requestAttention: false
        )
    }

    func dismissActiveAlert() {
        activeAlert = nil
        overlayController.hide()
    }

    func snoozeActiveAlert(minutes: Int) {
        guard let alert = activeAlert else { return }
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        alertEngine.snooze(eventID: alert.event.id, until: until)
        dismissActiveAlert()
    }

    func joinActiveAlert() {
        guard let url = activeAlert?.event.joinURL else { return }
        NSWorkspace.shared.open(url)
        dismissActiveAlert()
    }

    func openEventLink(_ event: CalendarEvent) {
        guard let url = event.joinURL else { return }
        NSWorkspace.shared.open(url)
    }

    func agendaEvents(now: Date = Date()) -> [CalendarEvent] {
        visibleEvents(localCalendarStore.events(inNextHours: lookAheadHours, now: now, includeAllDay: true))
    }

    func responseEvents(now: Date = Date()) -> [CalendarEvent] {
        visibleEvents(localCalendarStore.events(inNextHours: responseLookAheadHours, now: now))
            .filter { $0.needsResponse && canRespond(to: $0) }
    }

    func calendarEvents(from start: Date, to end: Date, includeAllDay: Bool = true) -> [CalendarEvent] {
        visibleEvents(localCalendarStore.events(from: start, to: end, includeAllDay: includeAllDay))
    }

    var writableCalendars: [LocalCalendar] {
        localCalendarStore.calendars.filter { isWritableCalendarID($0.id) }
    }

    func providerSidebarSyncText(now: Date = Date()) -> String? {
        guard !providerStore.accounts.isEmpty else { return nil }

        let enabledCount = providerStore.enabledSyncAccounts.count
        guard enabledCount > 0 else { return "Source sync paused" }

        if isProviderSyncPassRunning || !syncingProviderIDs.isEmpty {
            return "Syncing sources now"
        }

        if isProviderOutboxProcessing {
            return "Pushing remote updates"
        }

        let attentionCount = providerStore.conflictedProviderOutboxCount + providerStore.blockedProviderOutboxCount
        if attentionCount > 0 {
            return "\(attentionCount) remote update\(attentionCount == 1 ? "" : "s") need attention"
        }

        let pendingCount = providerStore.pendingProviderOutboxCount
        if pendingCount > 0 {
            return "\(pendingCount) pending remote update\(pendingCount == 1 ? "" : "s")"
        }

        guard let nextSyncAt = nextProviderSyncAt(now: now) else {
            return "Initial sync pending"
        }

        if nextSyncAt <= now {
            guard lastProviderSyncAt != nil else {
                return "Initial sync pending"
            }
            return "Sync due now"
        }

        return "Next sync \(nextSyncAt.formatted(date: .omitted, time: .shortened))"
    }

    func providerSettingsSummaryText(now: Date = Date()) -> String {
        let enabledCount = providerStore.enabledSyncAccounts.count
        if providerStore.accounts.isEmpty {
            return "Add ICS, webcal, CalDAV, Google, or Microsoft 365 sources from Calendars."
        }

        guard enabledCount > 0 else {
            return "0 enabled · source sync paused"
        }

        if isProviderSyncPassRunning || !syncingProviderIDs.isEmpty {
            return "\(enabledCount) enabled · syncing now"
        }

        if isProviderOutboxProcessing {
            return "\(enabledCount) enabled · pushing remote updates"
        }

        let attentionCount = providerStore.conflictedProviderOutboxCount + providerStore.blockedProviderOutboxCount
        if attentionCount > 0 {
            return "\(enabledCount) enabled · \(attentionCount) remote update\(attentionCount == 1 ? "" : "s") need attention"
        }

        let pendingCount = providerStore.pendingProviderOutboxCount
        if pendingCount > 0 {
            return "\(enabledCount) enabled · \(pendingCount) remote update\(pendingCount == 1 ? "" : "s") pending"
        }

        if let nextSyncAt = nextProviderSyncAt(now: now) {
            if nextSyncAt <= now {
                if let lastProviderSyncAt {
                    return "\(enabledCount) enabled · last sync \(lastProviderSyncAt.formatted(date: .abbreviated, time: .shortened)) · due now"
                }
                return "\(enabledCount) enabled · initial sync pending"
            }

            if let lastProviderSyncAt {
                return "\(enabledCount) enabled · last sync \(lastProviderSyncAt.formatted(date: .abbreviated, time: .shortened)) · next \(nextSyncAt.formatted(date: .omitted, time: .shortened))"
            }
            return "\(enabledCount) enabled · next \(nextSyncAt.formatted(date: .omitted, time: .shortened))"
        }

        return "\(enabledCount) enabled · initial sync pending"
    }

    func providerDiagnosticReports(now: Date = Date()) -> [ProviderDiagnosticReport] {
        let accountReports = providerStore.accounts.compactMap { account in
            providerDiagnosticReport(for: account, now: now)
        }
        let configuredSources = Set(providerStore.accounts.compactMap { account in
            providerDiagnosticSource(for: account.kind)
        })
        let onboardingReports = ProviderDiagnosticSource.allCases
            .filter { !configuredSources.contains($0) }
            .map(providerOnboardingDiagnosticReport(for:))

        return accountReports + onboardingReports
    }

    func displayLocation(for event: CalendarEvent, now: Date = Date()) -> String? {
        ruleStore.rules.first { rule in
            rule.enabled
                && !rule.locationOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && rule.matches(event, now: now)
        }?.locationOverride.trimmingCharacters(in: .whitespacesAndNewlines) ?? event.bestLocation
    }

    func respond(
        to event: CalendarEvent,
        with response: CalendarEventResponse,
        scope: CalendarEventResponseScope = .thisEvent
    ) {
        guard canRespond(to: event) else {
            providerSyncMessage = "\(event.calendarTitle): responses are read-only for this source"
            return
        }

        if localCalendarStore.contains(event) {
            let hadLocalProviderRecurrenceChanges = localCalendarStore.localEvent(for: event)?.hasLocalProviderRecurrenceChanges ?? false
            if let updatedEvent = localCalendarStore.respond(to: event, with: response, scope: scope) {
                enqueueProviderResponse(
                    for: updatedEvent,
                    sourceEvent: event,
                    response: response,
                    scope: scope,
                    hadLocalProviderRecurrenceChanges: hadLocalProviderRecurrenceChanges
                )
            }
            updateDockIcon()
            reconcileActiveAlert(now: Date())
            return
        }

    }

    func remove(_ event: CalendarEvent, scope: CalendarEventRemovalScope) {
        guard canEdit(event) else {
            providerSyncMessage = "\(event.calendarTitle): events are read-only for this source"
            return
        }

        if localCalendarStore.contains(event) {
            let localEvent = localCalendarStore.localEvent(for: event)
            localCalendarStore.remove(event, scope: scope)
            if let localEvent {
                if localEvent.isRecurring {
                    if let updatedEvent = localCalendarStore.localEvent(withID: localEvent.id) {
                        enqueueProviderWriteBack(for: updatedEvent)
                    } else {
                        enqueueProviderDelete(for: localEvent)
                    }
                } else {
                    enqueueProviderDelete(for: localEvent)
                }
            }
            updateDockIcon()
            return
        }

    }

    func draftForLocalEvent(on date: Date = Date()) -> LocalEventDraft {
        writableDraft(localCalendarStore.draft(for: date))
    }

    func draftForLocalEvent(start: Date, end: Date, isAllDay: Bool = false) -> LocalEventDraft {
        writableDraft(localCalendarStore.draft(start: start, end: end, isAllDay: isAllDay))
    }

    func draftForLocalEvent(_ event: CalendarEvent) -> LocalEventDraft? {
        guard canEdit(event) else { return nil }
        return localCalendarStore.draft(for: event)
    }

    func occurrenceDraftForLocalEvent(_ event: CalendarEvent) -> LocalEventDraft? {
        guard canEdit(event) else { return nil }
        return localCalendarStore.occurrenceDraft(for: event)
    }

    func duplicateDraftForLocalEvent(_ event: CalendarEvent) -> LocalEventDraft? {
        localCalendarStore.duplicateDraft(for: event).map(writableDraft)
    }

    func conflictCandidates(for draft: LocalEventDraft) -> [CalendarEvent] {
        let safeEnd = max(
            draft.endDate,
            draft.startDate.addingTimeInterval(draft.isAllDay ? 24 * 3600 : 5 * 60)
        )
        let fetchStart = Calendar.current.date(byAdding: .day, value: -1, to: draft.startDate) ?? draft.startDate
        let fetchEnd = Calendar.current.date(byAdding: .day, value: 1, to: safeEnd) ?? safeEnd

        return calendarEvents(from: fetchStart, to: fetchEnd, includeAllDay: true)
    }

    func canEdit(_ event: CalendarEvent) -> Bool {
        guard localCalendarStore.contains(event),
              isWritableCalendarID(event.calendarID),
              localCalendarStore.localEvent(for: event)?.isImportedRecurrenceSplitProjection != true
        else {
            return false
        }
        return true
    }

    private func canEditLocalEvent(_ event: LocalCalendarEvent) -> Bool {
        isWritableCalendarID(event.calendarID)
            && !event.isImportedRecurrenceSplitProjection
    }

    func needsDirectCalendarChangeConfirmation(for event: CalendarEvent) -> Bool {
        event.isRecurring
            || providerAccount(forCalendarID: event.calendarID) != nil
            || isProviderBackedCalendarID(event.calendarID)
    }

    func canRespond(to event: CalendarEvent) -> Bool {
        guard localCalendarStore.contains(event),
              canRespondInCalendar(event.calendarID),
              localCalendarStore.localEvent(for: event)?.isImportedRecurrenceSplitProjection != true
        else {
            return false
        }
        return true
    }

    func backendInfo(for calendar: LocalCalendar) -> CalendarBackendInfo {
        guard let account = providerAccount(forCalendarID: calendar.id) else {
            return .local
        }

        return CalendarBackendInfo(
            sourceTitle: account.title,
            sourceKind: account.kind,
            sourceKindTitle: account.kind.title,
            isProviderBacked: true,
            isSourceEnabled: account.enabled,
            allowsEventWrite: account.enabled && account.kind.supportsWriteBack && calendar.allowsEventWrite,
            allowsResponses: account.enabled && account.kind.supportsResponses && calendar.allowsResponses,
            pendingOutboxCount: providerStore.providerOutboxCount(accountID: account.id),
            attentionOutboxCount: providerStore.providerOutboxConflictCount(accountID: account.id)
                + providerStore.providerOutboxBlockedCount(accountID: account.id),
            lastSyncAt: account.lastSyncAt,
            lastError: account.lastError
        )
    }

    func backendInfo(forCalendarID calendarID: String) -> CalendarBackendInfo {
        guard let calendar = localCalendarStore.calendar(withID: calendarID) else {
            return .local
        }
        return backendInfo(for: calendar)
    }

    private func writableDraft(_ draft: LocalEventDraft) -> LocalEventDraft {
        guard isWritableCalendarID(draft.calendarID) else {
            var copy = draft
            copy.calendarID = preferredWritableCalendarID(fallback: draft.calendarID)
            return copy
        }

        return draft
    }

    private func preferredWritableCalendarID(fallback: String) -> String {
        if localCalendarStore.selectedCalendarIDs.contains(fallback), isWritableCalendarID(fallback) {
            return fallback
        }

        if let selectedWritable = localCalendarStore.calendars.first(where: {
            localCalendarStore.selectedCalendarIDs.contains($0.id) && isWritableCalendarID($0.id)
        }) {
            return selectedWritable.id
        }

        if let writable = localCalendarStore.calendars.first(where: { isWritableCalendarID($0.id) }) {
            return writable.id
        }

        return fallback
    }

    private func isWritableCalendarID(_ calendarID: String) -> Bool {
        guard let account = providerAccount(forCalendarID: calendarID) else {
            return !isProviderBackedCalendarID(calendarID)
        }
        let calendarAllowsWrite = localCalendarStore.calendar(withID: calendarID)?.allowsEventWrite ?? true
        return account.enabled && account.kind.supportsWriteBack && calendarAllowsWrite
    }

    private func canRespondInCalendar(_ calendarID: String) -> Bool {
        guard let account = providerAccount(forCalendarID: calendarID) else {
            return !isProviderBackedCalendarID(calendarID)
        }
        let calendarAllowsResponses = localCalendarStore.calendar(withID: calendarID)?.allowsResponses ?? true
        return account.enabled && account.kind.supportsResponses && calendarAllowsResponses
    }

    func saveLocalEvent(_ draft: LocalEventDraft) {
        let safeDraft = writableDraft(draft)
        let previousEvent = safeDraft.eventID.flatMap { localCalendarStore.localEvent(withID: $0) }
        if let previousEvent, !canEditLocalEvent(previousEvent) {
            providerSyncMessage = "\(previousEvent.title): events are read-only for this source"
            return
        }

        if let savedEvent = localCalendarStore.save(safeDraft) {
            if let previousEvent, previousEvent.calendarID != savedEvent.calendarID {
                enqueueProviderCalendarMove(from: previousEvent, to: savedEvent)
            } else {
                enqueueProviderWriteBack(for: savedEvent)
            }
        }
        updateDockIcon()
    }

    @discardableResult
    func addICSSubscription(title: String, urlString: String) async -> String? {
        do {
            let account = try providerStore.addICSSubscription(title: title, urlString: urlString)
            return await finishInitialProviderAdd(account)
        } catch {
            providerSyncMessage = error.localizedDescription
            return error.localizedDescription
        }
    }

    func handleExternalCalendarURL(_ url: URL) async {
        guard externalCalendarOpenDeduper.shouldProcess(url) else { return }

        do {
            if url.isFileURL {
                let summary = try importICSFile(at: url)
                providerSyncMessage = syncMessage(for: externalCalendarTitle(for: url), summary: summary)
                updateDockIcon()
                return
            }

            guard isExternalCalendarSubscriptionURL(url) else {
                providerSyncMessage = "Unsupported calendar link: \(url.absoluteString)"
                return
            }

            let title = externalCalendarTitle(for: url)
            if let error = await addICSSubscription(title: title, urlString: url.absoluteString) {
                providerSyncMessage = error
            }
        } catch {
            providerSyncMessage = error.localizedDescription
        }
    }

    @discardableResult
    func importICSFile(at url: URL) throws -> LocalICSImportSummary {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        guard let text = CalendarSubscriptionDecoder.text(from: data, contentType: nil) else {
            throw CalendarProviderSyncError.unsupportedEncoding
        }

        let cancellationTargets = LocalCalendarICSCodec.cancellationTargets(from: text)
        let deletedEvents = localCalendarStore.removeEvents(externalUIDs: cancellationTargets.eventUIDs)
        let deletedOccurrences = localCalendarStore.cancelOccurrences(cancellations: cancellationTargets.occurrences)
        let deletedCount = deletedEvents + deletedOccurrences
        let replies = LocalCalendarICSCodec.replies(from: text)
        let repliedCount = localCalendarStore.applyReplies(replies)

        if !replies.isEmpty {
            return LocalICSImportSummary(
                calendarsImported: 0,
                eventsImported: 0,
                eventsUpdated: repliedCount,
                eventsSkipped: 0,
                eventsDeleted: deletedCount
            )
        }

        do {
            var summary = try localCalendarStore.importICSText(text)
            summary.eventsDeleted += deletedCount
            return summary
        } catch LocalICSImportError.noEvents where !cancellationTargets.isEmpty {
            return LocalICSImportSummary(
                calendarsImported: 0,
                eventsImported: 0,
                eventsUpdated: 0,
                eventsSkipped: 0,
                eventsDeleted: deletedCount
            )
        }
    }

    @discardableResult
    func addCalDAVAccount(title: String, urlString: String, username: String, password: String) async -> String? {
        do {
            let account = try providerStore.addCalDAVAccount(
                title: title,
                urlString: urlString,
                username: username,
                password: password
            )
            return await finishInitialProviderAdd(account)
        } catch {
            providerSyncMessage = error.localizedDescription
            return error.localizedDescription
        }
    }

    @discardableResult
    func addGoogleCalendarAccount(title: String, accessToken: String) async -> String? {
        do {
            let account = try providerStore.addGoogleCalendarAccount(title: title, accessToken: accessToken)
            return await finishInitialProviderAdd(account)
        } catch {
            providerSyncMessage = error.localizedDescription
            return error.localizedDescription
        }
    }

    @discardableResult
    func addGoogleCalendarAccount(title: String, credential: OAuthCredential) async -> String? {
        do {
            let account = try providerStore.addGoogleCalendarAccount(title: title, credential: credential)
            return await finishInitialProviderAdd(account)
        } catch {
            providerSyncMessage = error.localizedDescription
            return error.localizedDescription
        }
    }

    @discardableResult
    func addMicrosoft365Account(title: String, accessToken: String) async -> String? {
        do {
            let account = try providerStore.addMicrosoft365Account(title: title, accessToken: accessToken)
            return await finishInitialProviderAdd(account)
        } catch {
            providerSyncMessage = error.localizedDescription
            return error.localizedDescription
        }
    }

    @discardableResult
    func addMicrosoft365Account(title: String, credential: OAuthCredential) async -> String? {
        do {
            let account = try providerStore.addMicrosoft365Account(title: title, credential: credential)
            return await finishInitialProviderAdd(account)
        } catch {
            providerSyncMessage = error.localizedDescription
            return error.localizedDescription
        }
    }

    private func finishInitialProviderAdd(_ account: CalendarProviderAccount) async -> String? {
        await syncProviderAccount(account, force: true)
        guard let syncedAccount = providerStore.accounts.first(where: { $0.id == account.id }) else {
            return nil
        }

        if let error = syncedAccount.lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            rollbackInitialProviderAccount(syncedAccount)
            providerSyncMessage = error
            return error
        }

        return await mergeDuplicateInitialOAuthProviderAccountIfNeeded(syncedAccount)
    }

    private func rollbackInitialProviderAccount(_ account: CalendarProviderAccount) {
        _ = localCalendarStore.deleteProviderCalendars(calendarIDs: providerCalendarIDs(ownedBy: account))
        providerStore.delete(account)
        updateDockIcon()
    }

    private func mergeDuplicateInitialOAuthProviderAccountIfNeeded(_ account: CalendarProviderAccount) async -> String? {
        guard account.kind == .googleCalendar || account.kind == .microsoft365 else { return nil }
        let identityEmails = CalendarProviderAccount.normalizedIdentityEmails(
            [account.identityEmail].compactMap { $0 } + account.identityEmailAliases
        )
        guard !identityEmails.isEmpty,
              let existingAccount = providerStore.accountMatchingIdentity(
                kind: account.kind,
                excluding: account.id,
                identityEmails: identityEmails
              )
        else {
            return nil
        }

        guard let credential = oauthCredential(for: account) else {
            let error = "\(account.title): could not reconnect existing source because the new credential is missing"
            providerSyncMessage = error
            return error
        }
        guard let existingCredentialKey = existingAccount.credentialKey else {
            let error = "\(existingAccount.title): credential storage is missing"
            providerSyncMessage = error
            return error
        }
        guard OAuthCredentialStore.saveCredential(credential, key: existingCredentialKey) else {
            let error = CalendarProviderStoreError.keychainSaveFailed.localizedDescription
            providerSyncMessage = error
            return error
        }

        if !existingAccount.enabled {
            providerStore.setAccount(existingAccount, enabled: true)
        }
        providerStore.resetSyncState(accountID: existingAccount.id)
        _ = localCalendarStore.deleteProviderCalendars(calendarIDs: providerCalendarIDs(ownedBy: account))
        providerStore.delete(account)
        updateDockIcon()

        guard let reconnectedAccount = providerStore.accounts.first(where: { $0.id == existingAccount.id }) else {
            return nil
        }
        await syncProviderAccount(reconnectedAccount, force: true)
        if let error = providerErrorMessage(for: reconnectedAccount.id) {
            return error
        }
        providerSyncMessage = "\(reconnectedAccount.title): reconnected existing source"
        return nil
    }

    func syncProviderSources(force: Bool = false) async {
        guard !isProviderSyncPassRunning else { return }
        isProviderSyncPassRunning = true
        let syncStartedAt = Date()
        defer {
            isProviderSyncPassRunning = false
            lastProviderSyncAt = Date()
        }

        await processProviderOutbox()

        for account in providerStore.enabledSyncAccounts where force || account.isAutomaticSyncDue(at: syncStartedAt) {
            await syncProviderAccount(account, force: force)
        }
    }

    func fullRefreshProviderAccount(_ account: CalendarProviderAccount) async {
        guard providerStore.accounts.contains(where: { $0.id == account.id }) else { return }
        await processProviderOutbox()
        guard !providerStore.hasSyncBlockingProviderOutboxItems(accountID: account.id) else {
            providerSyncMessage = providerOutboxPauseMessage(for: account)
            return
        }
        providerStore.resetSyncState(accountID: account.id)
        await syncProviderAccount(account, force: true)
    }

    func retryProviderOutboxNow() async {
        let conflictedItems = providerStore.providerOutbox.filter(\.isBlockedByConflict)
        let didSyncConflictedItems = await syncProviderAccountsBeforeConflictRetry(for: conflictedItems)
        if !conflictedItems.isEmpty && !didSyncConflictedItems {
            providerStore.markAllRetryableProviderOutboxItemsDue()
            await processProviderOutbox()
            return
        }
        providerStore.markAllProviderOutboxItemsDue()
        await processProviderOutbox()
    }

    func retryProviderOutboxItemNow(_ item: ProviderOutboxItem) async {
        if item.isBlockedByConflict {
            guard await syncProviderAccountsBeforeConflictRetry(for: [item]) else {
                providerSyncMessage = "\(item.eventTitle): sync failed before retry"
                return
            }
        }
        guard providerStore.providerOutbox.contains(where: { $0.id == item.id }) else { return }
        providerStore.markProviderOutboxItemDue(id: item.id)
        await processProviderOutbox()
    }

    private func syncProviderAccountsBeforeConflictRetry(for items: [ProviderOutboxItem]) async -> Bool {
        let accountIDs = providerStore.conflictRetryAccountIDs(for: items)
        guard !accountIDs.isEmpty else { return true }
        let accounts = accountIDs.compactMap { accountID in
            providerStore.accounts.first { $0.id == accountID }
        }
        guard accounts.count == accountIDs.count else { return false }
        var allSynced = true
        for account in accounts {
            providerSyncMessage = "\(account.title): syncing before retry"
            allSynced = await syncProviderAccount(account, force: true) && allSynced
        }
        return allSynced
    }

    func discardProviderOutboxItem(_ item: ProviderOutboxItem) {
        providerStore.removeProviderOutboxItem(id: item.id)
        providerSyncMessage = "\(item.eventTitle): pending provider \(item.operation.title) discarded"
    }

    func deleteProviderAccount(_ account: CalendarProviderAccount) {
        let deleted = localCalendarStore.deleteProviderCalendars(calendarIDs: providerCalendarIDs(ownedBy: account))
        if deleted.eventsDeleted > 0 || deleted.calendarsDeleted > 0 {
            providerSyncMessage = "\(account.title): removed \(deleted.calendarsDeleted) calendars, \(deleted.eventsDeleted) events"
        }

        providerStore.delete(account)
        updateDockIcon()
    }

    @discardableResult
    func updateICSSubscription(_ account: CalendarProviderAccount, title: String, urlString: String) async -> String? {
        do {
            let updatedAccount = try providerStore.updateICSSubscription(account, title: title, urlString: urlString)
            await fullRefreshProviderAccount(updatedAccount)
            return providerErrorMessage(for: updatedAccount.id)
        } catch {
            providerSyncMessage = error.localizedDescription
            return error.localizedDescription
        }
    }

    @discardableResult
    func updateCalDAVAccount(
        _ account: CalendarProviderAccount,
        title: String,
        urlString: String,
        username: String,
        password: String
    ) async -> String? {
        do {
            let updatedAccount = try providerStore.updateCalDAVAccount(
                account,
                title: title,
                urlString: urlString,
                username: username,
                password: password
            )
            await fullRefreshProviderAccount(updatedAccount)
            return providerErrorMessage(for: updatedAccount.id)
        } catch {
            providerSyncMessage = error.localizedDescription
            return error.localizedDescription
        }
    }

    @discardableResult
    func reconnectProviderAccount(_ account: CalendarProviderAccount, credential: OAuthCredential) async -> String? {
        guard let credentialKey = account.credentialKey else {
            let error = "\(account.title): credential storage is missing"
            providerSyncMessage = error
            return error
        }

        guard OAuthCredentialStore.saveCredential(credential, key: credentialKey) else {
            let error = CalendarProviderStoreError.keychainSaveFailed.localizedDescription
            providerSyncMessage = error
            return error
        }

        await syncProviderAccount(account, force: true)
        guard let syncedAccount = providerStore.accounts.first(where: { $0.id == account.id }),
              let error = syncedAccount.lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
              !error.isEmpty
        else {
            return nil
        }
        return error
    }

    private func providerErrorMessage(for accountID: String) -> String? {
        guard let syncedAccount = providerStore.accounts.first(where: { $0.id == accountID }),
              let error = syncedAccount.lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
              !error.isEmpty
        else {
            return nil
        }
        return error
    }

    func oauthCredential(for account: CalendarProviderAccount) -> OAuthCredential? {
        guard let credentialKey = account.credentialKey,
              let service = oauthService(for: account)
        else {
            return nil
        }
        return OAuthCredentialStore.credential(key: credentialKey, fallbackService: service)
    }

    func oauthService(for account: CalendarProviderAccount) -> OAuthServiceKind? {
        switch account.kind {
        case .googleCalendar:
            return .googleCalendar
        case .microsoft365:
            return .microsoft365
        case .local, .icsSubscription, .calDAV:
            return nil
        }
    }

    @discardableResult
    func syncProviderAccount(_ account: CalendarProviderAccount, force: Bool = true) async -> Bool {
        guard let account = providerStore.accounts.first(where: { $0.id == account.id }) else { return false }
        guard account.enabled else {
            providerSyncMessage = "\(account.title): account is disabled"
            return false
        }
        guard account.kind == .icsSubscription || account.kind == .calDAV || account.kind == .googleCalendar || account.kind == .microsoft365 else { return false }
        guard !syncingProviderIDs.contains(account.id) else { return false }
        let syncRequestedAt = Date()
        guard force || account.isAutomaticSyncDue(at: syncRequestedAt) else {
            if let syncNotBefore = account.syncNotBefore, syncNotBefore > syncRequestedAt {
                providerSyncMessage = "\(account.title): provider asked to retry after \(syncNotBefore.formatted(date: .omitted, time: .shortened))"
            }
            return false
        }
        await processProviderOutbox()
        guard !providerStore.hasSyncBlockingProviderOutboxItems(accountID: account.id) else {
            providerSyncMessage = providerOutboxPauseMessage(for: account)
            return false
        }

        syncingProviderIDs.insert(account.id)
        defer { syncingProviderIDs.remove(account.id) }

        do {
            let summary: LocalICSImportSummary
            var httpValidators: (eTag: String?, lastModified: String?, preservesMissing: Bool)?
            var icsRefreshInterval: (seconds: Int?, preservesMissing: Bool)?
            var calDAVSyncStates: [CalDAVCalendarSyncState]?
            var googleCalendarSyncStates: [GoogleCalendarSyncState]?
            var microsoftGraphSyncStates: [MicrosoftGraphSyncState]?
            switch account.kind {
            case .icsSubscription:
                let result = try await fetchICSSubscription(account)
                httpValidators = (result.eTag, result.lastModified, result.preservesMissingValidators)
                icsRefreshInterval = (result.refreshIntervalSeconds, result.preservesMissingRefreshInterval)
                if let text = result.text {
                    summary = try syncICSSubscriptionAccount(account, text: text)
                } else {
                    summary = LocalICSImportSummary(
                        calendarsImported: 0,
                        eventsImported: 0,
                        eventsUpdated: 0,
                        eventsSkipped: 0
                    )
                }
            case .calDAV:
                let result = try await syncCalDAVAccount(account)
                summary = result.summary
                calDAVSyncStates = result.syncStates
                if !result.accountIdentityEmails.isEmpty {
                    providerStore.recordAccountIdentityEmails(accountID: account.id, identityEmails: result.accountIdentityEmails)
                }
            case .googleCalendar:
                let result = try await syncGoogleCalendarAccount(account)
                summary = result.summary
                googleCalendarSyncStates = result.syncStates
                if !result.accountIdentityEmails.isEmpty {
                    providerStore.recordAccountIdentityEmails(accountID: account.id, identityEmails: result.accountIdentityEmails)
                }
            case .microsoft365:
                let result = try await syncMicrosoft365Account(account)
                summary = result.summary
                microsoftGraphSyncStates = result.syncStates
                if !result.accountIdentityEmails.isEmpty {
                    providerStore.recordAccountIdentityEmails(accountID: account.id, identityEmails: result.accountIdentityEmails)
                }
            case .local:
                return false
            }

            providerStore.recordSync(accountID: account.id, summary: summary, startedAt: syncRequestedAt)
            if let httpValidators {
                providerStore.recordHTTPValidators(
                    accountID: account.id,
                    eTag: httpValidators.eTag,
                    lastModified: httpValidators.lastModified,
                    preservesMissing: httpValidators.preservesMissing
                )
            }
            if let icsRefreshInterval {
                providerStore.recordICSRefreshInterval(
                    accountID: account.id,
                    seconds: icsRefreshInterval.seconds,
                    preservesMissing: icsRefreshInterval.preservesMissing
                )
            }
            if let calDAVSyncStates {
                providerStore.recordCalDAVSyncStates(accountID: account.id, states: calDAVSyncStates)
            }
            if let googleCalendarSyncStates {
                providerStore.recordGoogleCalendarSyncStates(accountID: account.id, states: googleCalendarSyncStates)
            }
            if let microsoftGraphSyncStates {
                providerStore.recordMicrosoftGraphSyncStates(accountID: account.id, states: microsoftGraphSyncStates)
            }
            providerSyncMessage = syncMessage(for: account.title, summary: summary)
            updateDockIcon()
            return true
        } catch {
            providerStore.recordSyncError(accountID: account.id, error: error, syncStartedAt: syncRequestedAt)
            providerSyncMessage = error.localizedDescription
            return false
        }
    }

    func moveLocalEvent(
        _ event: CalendarEvent,
        dayDelta: Int,
        minuteDelta: Int,
        scope: CalendarEventChangeScope = .thisEvent
    ) {
        guard canEdit(event) else {
            providerSyncMessage = "\(event.calendarTitle): events are read-only for this source"
            return
        }

        let updatedEvents = localCalendarStore.move(
            event,
            dayDelta: dayDelta,
            minuteDelta: minuteDelta,
            scope: scope
        )
        for updatedEvent in updatedEvents {
            enqueueProviderWriteBack(for: updatedEvent)
        }
        updateDockIcon()
    }

    func resizeLocalEvent(
        _ event: CalendarEvent,
        endMinuteDelta: Int,
        scope: CalendarEventChangeScope = .thisEvent
    ) {
        guard canEdit(event) else {
            providerSyncMessage = "\(event.calendarTitle): events are read-only for this source"
            return
        }

        let updatedEvents = localCalendarStore.resize(
            event,
            endMinuteDelta: endMinuteDelta,
            scope: scope
        )
        for updatedEvent in updatedEvents {
            enqueueProviderWriteBack(for: updatedEvent)
        }
        updateDockIcon()
    }

    func showTestAlert() {
        let now = Date()
        let event = CalendarEvent(
            id: "test-\(UUID().uuidString)",
            eventIdentifier: "test",
            calendarItemIdentifier: "test",
            externalIdentifier: "test",
            sequence: 0,
            title: "Critical customer sync",
            startDate: now.addingTimeInterval(60),
            endDate: now.addingTimeInterval(31 * 60),
            occurrenceStartDate: now.addingTimeInterval(60),
            isAllDay: false,
            availability: .busy,
            status: .confirmed,
            privacy: .public,
            importance: .high,
            categories: ["Test alert"],
            reminderOffsets: [1],
            timeZoneIdentifier: TimeZone.current.identifier,
            isRecurring: false,
            isDetached: false,
            calendarID: "test",
            calendarTitle: "Demo Calendar",
            sourceTitle: "Local",
            calendarColor: .systemRed,
            location: "https://meet.google.com/demo-demo-demo",
            notes: "This is a local test alert.",
            url: nil,
            responseStatus: .pending,
            responseStatusIsExplicit: true,
            attendeeCount: 3,
            organizer: EventParticipant(
                id: "organizer",
                name: "Demo Organizer",
                email: "organizer@example.com",
                type: "person",
                role: "chair",
                status: .accepted,
                isCurrentUser: false,
                isRoomLike: false
            ),
            participants: [
                EventParticipant(
                    id: "room",
                    name: "CY-Office-1st-Conference",
                    email: "cy-office-1st-conference@example.com",
                    type: "room",
                    role: "required",
                    status: .accepted,
                    isCurrentUser: false,
                    isRoomLike: true
                )
            ]
        )

        let rule = AlertRule(
            name: "Test critical alert",
            priority: .critical,
            leadMinutes: 1,
            repeatEverySeconds: 20,
            repeatCount: 1,
            stickyOverlay: true,
            systemNotification: true,
            playSound: true,
            speak: false,
            bounceDock: true
        )

        present(MeetingAlert(
            event: event,
            rule: rule,
            firedAt: now,
            fireIndex: 1,
            requiresRuleStoreMembership: false
        ))
    }

    private func reconcileActiveAlert(now: Date) {
        guard let activeAlert else { return }

        guard let liveEvent = alertEvents(now: now).first(where: { $0.id == activeAlert.event.id }) else {
            dismissActiveAlert()
            return
        }

        let liveRule: AlertRule
        if let storedRule = ruleStore.rules.first(where: { $0.id == activeAlert.rule.id }) {
            liveRule = storedRule
        } else if activeAlert.requiresRuleStoreMembership {
            dismissActiveAlert()
            return
        } else {
            liveRule = activeAlert.rule
        }

        let secondsUntilStart = liveEvent.startDate.timeIntervalSince(now)
        let alertWindow = TimeInterval(liveRule.leadMinutes * 60)
        let stillInWindow = liveEvent.endDate > now
            && secondsUntilStart <= alertWindow
            && secondsUntilStart >= -180

        if !stillInWindow || !liveRule.matches(liveEvent, now: now) {
            dismissActiveAlert()
            return
        }

        if liveEvent != activeAlert.event || liveRule != activeAlert.rule {
            refreshActiveAlert(MeetingAlert(
                id: activeAlert.id,
                event: liveEvent,
                rule: liveRule,
                firedAt: activeAlert.firedAt,
                fireIndex: activeAlert.fireIndex,
                requiresRuleStoreMembership: activeAlert.requiresRuleStoreMembership
            ))
        }
    }

    private func processAutomaticResponses(now: Date) {
        let responseEvents = responseEvents(now: now)
        let liveResponseEventIDs = Set(responseEvents.map(\.id))
        responseAttempts = responseAttempts.filter { key in
            liveResponseEventIDs.contains(key.eventID)
        }

        for event in responseEvents {
            for rule in ruleStore.rules where rule.enabled && rule.responseAction != .none && rule.matches(event, now: now) {
                guard let response = CalendarEventResponse(ruleAction: rule.responseAction) else { continue }
                guard localCalendarStore.contains(event) else { continue }

                let key = ResponseAttemptKey(
                    eventID: event.id,
                    ruleID: rule.id,
                    action: rule.responseAction,
                    scope: rule.responseScope
                )
                guard !responseAttempts.contains(key) else { continue }

                responseAttempts.insert(key)
                respond(to: event, with: response, scope: rule.responseScope)
                return
            }
        }
    }

    private func scheduleProviderSyncIfNeeded(now: Date) {
        guard !providerStore.enabledSyncAccounts.isEmpty,
              !isProviderSyncPassRunning,
              syncingProviderIDs.isEmpty
        else {
            return
        }

        guard let nextSyncAt = nextProviderSyncAt(now: now),
              nextSyncAt <= now
        else {
            return
        }

        Task { await syncProviderSources() }
    }

    private func nextProviderSyncAt(now: Date = Date()) -> Date? {
        let accounts = providerStore.enabledSyncAccounts
        guard !accounts.isEmpty else {
            return nil
        }

        let interval = TimeInterval(max(1, providerSyncIntervalMinutes) * 60)
        let nextReadyAt = accounts
            .map { providerReadyDate(for: $0, interval: interval) }
            .min()
        guard let nextReadyAt else { return nil }
        return nextReadyAt <= now ? now : nextReadyAt
    }

    private func providerDiagnosticReport(
        for account: CalendarProviderAccount,
        now: Date = Date()
    ) -> ProviderDiagnosticReport? {
        guard let source = providerDiagnosticSource(for: account.kind) else { return nil }

        let calendarIDs = providerCalendarIDs(ownedBy: account)
        let importedCalendars = localCalendarStore.calendars.filter { calendarIDs.contains($0.id) }
        let eventCount = localCalendarStore.events.filter { calendarIDs.contains($0.calendarID) }.count
        let writableCalendarCount = importedCalendars.filter(\.allowsEventWrite).count
        let responseCapableCalendarCount = importedCalendars.filter(\.allowsResponses).count
        let readOnlyCalendarCount = importedCalendars.filter {
            !$0.allowsEventWrite && !$0.allowsResponses
        }.count
        let syncStateCount = providerSyncStateCount(for: account)
        let httpValidatorCount = providerHTTPValidatorCount(for: account)
        let oauth = providerOAuthDiagnostic(for: account, now: now)
        let pendingOutboxCount = providerStore.providerOutboxCount(accountID: account.id)
        let attentionOutboxCount = providerStore.providerOutboxConflictCount(accountID: account.id)
            + providerStore.providerOutboxBlockedCount(accountID: account.id)
        let lastError = account.lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let localReadinessError = providerLocalReadinessError(for: account)
        let status: ProviderDiagnosticStatus
        let message: String

        if !account.enabled {
            status = .skipped
            message = "source disabled"
        } else if let localReadinessError {
            status = .failed
            message = localReadinessError
        } else if oauth?.status.needsAttention == true {
            status = .failed
            message = oauth?.status.title ?? "OAuth needs attention"
        } else if attentionOutboxCount > 0 {
            status = .failed
            message = "\(attentionOutboxCount) remote update\(attentionOutboxCount == 1 ? "" : "s") need attention"
        } else if !lastError.isEmpty {
            status = .failed
            message = lastError
        } else if pendingOutboxCount > 0 {
            status = .pending
            message = "\(pendingOutboxCount) remote update\(pendingOutboxCount == 1 ? "" : "s") pending"
        } else if account.lastSyncAt == nil {
            status = .pending
            message = "initial sync pending"
        } else if oauth?.status == .refreshDue {
            status = .pending
            message = "OAuth refresh due"
        } else {
            status = .passed
            message = account.syncSummaryText
        }

        return ProviderDiagnosticReport(
            source: source,
            status: status,
            message: message,
            accountID: account.id,
            accountTitle: account.title,
            isEnabled: account.enabled,
            lastSyncAt: account.lastSyncAt,
            lastSyncStartedAt: account.lastSyncStartedAt,
            lastSyncDurationSeconds: account.lastSyncDurationSeconds,
            lastSyncFailedAt: account.lastSyncFailedAt,
            nextSyncAt: providerNextSyncAt(for: account, now: now),
            oauth: oauth,
            calendarCount: importedCalendars.count,
            eventCount: eventCount,
            writableCalendarCount: writableCalendarCount,
            responseCapableCalendarCount: responseCapableCalendarCount,
            readOnlyCalendarCount: readOnlyCalendarCount,
            identityEmailCount: ([account.identityEmail].compactMap { $0 } + account.identityEmailAliases).count,
            syncStateCount: syncStateCount,
            httpValidatorCount: httpValidatorCount,
            refreshIntervalSeconds: account.icsRefreshIntervalSeconds,
            pendingOutboxCount: pendingOutboxCount,
            attentionOutboxCount: attentionOutboxCount
        )
    }

    private func providerOnboardingDiagnosticReport(for source: ProviderDiagnosticSource) -> ProviderDiagnosticReport {
        ProviderDiagnosticReport(
            source: source,
            status: .skipped,
            message: "No \(source.onboardingTitle) source connected. Add one from Calendars to enable standalone sync.",
            accountID: "provider-onboarding-\(source.rawValue)",
            accountTitle: source.onboardingTitle,
            isEnabled: false
        )
    }

    private func providerLocalReadinessError(for account: CalendarProviderAccount) -> String? {
        guard providerDiagnosticSource(for: account.kind) != nil else { return nil }

        switch account.kind {
        case .icsSubscription:
            do {
                _ = try CalendarURLNormalizer.subscriptionURL(from: account.endpointURLString)
            } catch {
                return "ICS/webcal URL invalid"
            }
            return nil
        case .calDAV:
            do {
                _ = try CalendarURLNormalizer.httpURL(from: account.endpointURLString)
            } catch {
                return "CalDAV URL invalid"
            }
        case .googleCalendar, .microsoft365:
            guard account.endpointURL != nil else {
                return "\(account.kind.title) URL invalid"
            }
            return nil
        case .local:
            return nil
        }

        guard account.username?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return "CalDAV username missing"
        }
        guard let credentialKey = account.credentialKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !credentialKey.isEmpty
        else {
            return "CalDAV credential key missing"
        }
        guard providerCredentialPassword(credentialKey)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return "CalDAV password missing in Keychain"
        }

        return nil
    }

    private func providerOAuthDiagnostic(
        for account: CalendarProviderAccount,
        now: Date
    ) -> ProviderOAuthDiagnostic? {
        guard let service = oauthService(for: account) else { return nil }
        return ProviderOAuthDiagnostic(
            service: service,
            credential: oauthCredential(for: account),
            now: now
        )
    }

    private func providerSyncStateCount(for account: CalendarProviderAccount) -> Int {
        switch account.kind {
        case .icsSubscription:
            return 0
        case .calDAV:
            return account.calDAVSyncStates.filter {
                !$0.syncToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !$0.cTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
        case .googleCalendar:
            return account.googleCalendarSyncStates.filter {
                !$0.syncToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
        case .microsoft365:
            return account.microsoftGraphSyncStates.filter {
                !$0.deltaLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
        case .local:
            return 0
        }
    }

    private func providerHTTPValidatorCount(for account: CalendarProviderAccount) -> Int {
        [
            account.httpETag,
            account.httpLastModified
        ].filter {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }.count
    }

    private func providerDiagnosticSource(for kind: CalendarProviderKind) -> ProviderDiagnosticSource? {
        switch kind {
        case .icsSubscription:
            return .icsSubscription
        case .calDAV:
            return .calDAV
        case .googleCalendar:
            return .googleCalendar
        case .microsoft365:
            return .microsoft365
        case .local:
            return nil
        }
    }

    private func providerNextSyncAt(for account: CalendarProviderAccount, now: Date = Date()) -> Date? {
        guard account.enabled else { return nil }
        let interval = TimeInterval(max(1, providerSyncIntervalMinutes) * 60)
        let readyAt = providerReadyDate(for: account, interval: interval)
        return readyAt <= now ? now : readyAt
    }

    private func providerReadyDate(for account: CalendarProviderAccount, interval: TimeInterval) -> Date {
        var readyAt = account.automaticSyncReadyDate(
            globalNotBefore: lastProviderSyncAt?.addingTimeInterval(interval)
        )

        if let accountLastSyncAt = account.lastSyncAt {
            let accountIntervalReadyAt = accountLastSyncAt.addingTimeInterval(interval)
            if accountIntervalReadyAt > readyAt {
                readyAt = accountIntervalReadyAt
            }
        }

        return readyAt
    }

    private func processProviderOutboxIfNeeded(now: Date) {
        guard !isProviderOutboxProcessing,
              !providerStore.dueProviderOutboxItems(now: now).isEmpty
        else {
            return
        }

        Task { await processProviderOutbox() }
    }

    private func providerOutboxPauseMessage(for account: CalendarProviderAccount) -> String {
        let count = providerStore.providerOutboxCount(accountID: account.id)
        return "\(account.title): \(count) pending remote update\(count == 1 ? "" : "s"); inbound sync paused"
    }

    private func enqueueProviderWriteBack(for event: LocalCalendarEvent) {
        guard let account = providerAccount(forCalendarID: event.calendarID),
              account.kind.supportsWriteBack
        else {
            return
        }
        guard isWritableCalendarID(event.calendarID) else {
            providerSyncMessage = "\(event.title): remote save skipped because events are read-only for this source"
            return
        }

        providerStore.enqueueProviderOutboxItem(.write(event: event, accountID: account.id))
        providerSyncMessage = "\(account.title): provider save queued"
        Task { await processProviderOutbox() }
    }

    private func enqueueProviderDelete(for event: LocalCalendarEvent) {
        guard let account = providerAccount(forCalendarID: event.calendarID),
              account.kind.supportsWriteBack
        else {
            return
        }
        guard isWritableCalendarID(event.calendarID) else {
            providerSyncMessage = "\(event.title): remote delete skipped because events are read-only for this source"
            return
        }

        let queued = providerStore.enqueueProviderOutboxItem(.delete(event: event, accountID: account.id))
        if queued {
            providerSyncMessage = "\(account.title): provider delete queued"
            Task { await processProviderOutbox() }
        } else {
            providerSyncMessage = "\(account.title): pending provider update cancelled"
        }
    }

    private func enqueueProviderCalendarMove(
        from previousEvent: LocalCalendarEvent,
        to savedEvent: LocalCalendarEvent
    ) {
        if isProviderBackedCalendarID(previousEvent.calendarID), !isWritableCalendarID(previousEvent.calendarID) {
            providerSyncMessage = "\(previousEvent.title): remote move skipped because the source calendar is read-only"
            return
        }
        if isProviderBackedCalendarID(savedEvent.calendarID), !isWritableCalendarID(savedEvent.calendarID) {
            providerSyncMessage = "\(savedEvent.title): remote move skipped because the destination calendar is read-only"
            return
        }

        let accountIDs = [
            providerAccount(forCalendarID: previousEvent.calendarID)?.id,
            providerAccount(forCalendarID: savedEvent.calendarID)?.id
        ].compactMap { $0 }

        guard !accountIDs.isEmpty else {
            enqueueProviderWriteBack(for: savedEvent)
            return
        }

        providerStore.enqueueProviderOutboxItem(.move(
            previousEvent: previousEvent,
            event: savedEvent,
            accountIDs: accountIDs
        ))
        providerSyncMessage = "\(savedEvent.title): provider move queued"
        Task { await processProviderOutbox() }
    }

    @discardableResult
    private func writeBackProviderRemoteObject(_ event: LocalCalendarEvent) async -> Bool {
        if calDAVAccount(forCalendarID: event.calendarID) != nil {
            return await writeBackCalDAVEvent(event)
        }
        if googleCalendarAccount(forCalendarID: event.calendarID) != nil {
            return await writeBackGoogleCalendarEvent(event)
        }
        if microsoft365Account(forCalendarID: event.calendarID) != nil {
            return await writeBackMicrosoft365Event(event)
        }
        if isProviderBackedCalendarID(event.calendarID) {
            providerSyncMessage = "Provider source is disabled or unavailable."
            return false
        }
        return true
    }

    private func deleteProviderRemoteObject(_ event: LocalCalendarEvent) async -> Bool {
        if calDAVAccount(forCalendarID: event.calendarID) != nil {
            return await deleteCalDAVEvent(event)
        }
        if googleCalendarAccount(forCalendarID: event.calendarID) != nil {
            return await deleteGoogleCalendarEvent(event)
        }
        if microsoft365Account(forCalendarID: event.calendarID) != nil {
            return await deleteMicrosoft365Event(event)
        }
        if isProviderBackedCalendarID(event.calendarID) {
            providerSyncMessage = "Provider source is disabled or unavailable."
            return false
        }
        return true
    }

    private func enqueueProviderResponse(
        for event: LocalCalendarEvent,
        sourceEvent: CalendarEvent,
        response: CalendarEventResponse,
        scope: CalendarEventResponseScope,
        hadLocalProviderRecurrenceChanges: Bool
    ) {
        let occurrenceStartDate = responseOccurrenceStartDate(for: sourceEvent, scope: scope)
        if let account = calDAVAccount(forCalendarID: event.calendarID) {
            enqueueProviderResponseOutbox(
                for: event,
                account: account,
                response: response,
                scope: scope,
                occurrenceStartDate: occurrenceStartDate,
                occurrenceIsAllDay: sourceEvent.isAllDay,
                hadLocalProviderRecurrenceChanges: hadLocalProviderRecurrenceChanges
            )
            return
        }

        if let account = googleCalendarAccount(forCalendarID: event.calendarID) {
            enqueueProviderResponseOutbox(
                for: event,
                account: account,
                response: response,
                scope: scope,
                occurrenceStartDate: occurrenceStartDate,
                occurrenceIsAllDay: sourceEvent.isAllDay,
                hadLocalProviderRecurrenceChanges: hadLocalProviderRecurrenceChanges
            )
            return
        }

        if let account = microsoft365Account(forCalendarID: event.calendarID) {
            enqueueProviderResponseOutbox(
                for: event,
                account: account,
                response: response,
                scope: scope,
                occurrenceStartDate: occurrenceStartDate,
                occurrenceIsAllDay: sourceEvent.isAllDay,
                hadLocalProviderRecurrenceChanges: hadLocalProviderRecurrenceChanges
            )
        }
    }

    private func enqueueProviderResponseOutbox(
        for event: LocalCalendarEvent,
        account: CalendarProviderAccount,
        response: CalendarEventResponse,
        scope: CalendarEventResponseScope,
        occurrenceStartDate: Date?,
        occurrenceIsAllDay: Bool,
        hadLocalProviderRecurrenceChanges: Bool
    ) {
        guard canRespondInCalendar(event.calendarID) else {
            providerSyncMessage = "\(event.title): remote response skipped because responses are read-only for this source"
            return
        }

        providerStore.enqueueProviderOutboxItem(.response(
            event: event,
            accountID: account.id,
            response: response,
            scope: scope,
            occurrenceStartDate: occurrenceStartDate,
            occurrenceIsAllDay: occurrenceIsAllDay,
            hadLocalProviderRecurrenceChanges: hadLocalProviderRecurrenceChanges
        ))
        providerSyncMessage = "\(account.title): provider response queued"
        Task { await processProviderOutbox() }
    }

    private func processProviderOutbox() async {
        guard !isProviderOutboxProcessing else { return }
        let dueItems = providerStore.dueProviderOutboxItems()
        guard !dueItems.isEmpty else { return }

        isProviderOutboxProcessing = true
        defer { isProviderOutboxProcessing = false }

        for item in dueItems {
            guard providerStore.providerOutbox.contains(where: { $0.id == item.id }) else {
                continue
            }

            providerSyncMessage = "\(item.eventTitle): provider \(item.operation.title) pending"
            currentProviderActionFailureKind = .retryable
            currentProviderRetryAfterSeconds = nil
            let succeeded = await executeProviderOutboxItem(item)
            if succeeded {
                providerStore.removeProviderOutboxItem(id: item.id)
            } else if currentProviderActionFailureKind == .conflict {
                providerStore.recordProviderOutboxConflict(
                    id: item.id,
                    error: currentProviderFailureMessage()
                )
            } else if currentProviderActionFailureKind == .blocked {
                providerStore.recordProviderOutboxBlocked(
                    id: item.id,
                    error: currentProviderFailureMessage()
                )
            } else {
                providerStore.recordProviderOutboxFailure(
                    id: item.id,
                    error: currentProviderFailureMessage(),
                    retryAfterSeconds: currentProviderRetryAfterSeconds
                )
            }
        }
    }

    private func executeProviderOutboxItem(_ item: ProviderOutboxItem) async -> Bool {
        switch item.operation {
        case .write:
            guard let currentEvent = localCalendarStore.localEvent(withID: item.eventID) else {
                return true
            }
            return await writeBackProviderRemoteObject(item.writePayload(usingCurrentEvent: currentEvent))
        case .delete:
            return await deleteProviderRemoteObject(item.event)
        case .move:
            return await executeProviderCalendarMove(item)
        case .response:
            return await executeProviderResponse(item)
        }
    }

    private func executeProviderResponse(_ item: ProviderOutboxItem) async -> Bool {
        guard let response = item.response,
              let scope = item.responseScope
        else {
            return true
        }

        let event = localCalendarStore.localEvent(withID: item.eventID) ?? item.event
        return await respondToProviderEvent(
            event,
            response: response,
            scope: scope,
            occurrenceStartDate: item.responseOccurrenceStartDate,
            occurrenceIsAllDay: item.responseOccurrenceIsAllDay ?? event.isAllDay,
            hadLocalProviderRecurrenceChanges: item.hadLocalProviderRecurrenceChanges ?? false
        )
    }

    private func executeProviderCalendarMove(_ item: ProviderOutboxItem) async -> Bool {
        guard let previousEvent = item.previousEvent else {
            guard let currentEvent = localCalendarStore.localEvent(withID: item.eventID) else {
                return true
            }
            return await writeBackProviderRemoteObject(currentEvent)
        }

        guard await deleteProviderRemoteObject(previousEvent) else {
            return false
        }

        guard let currentEvent = localCalendarStore.localEvent(withID: item.eventID) else {
            return true
        }

        localCalendarStore.clearRemoteBinding(eventID: currentEvent.id)
        var eventForNewCalendar = currentEvent
        eventForNewCalendar.remoteObjectURLString = ""
        eventForNewCalendar.remoteETag = ""
        return await writeBackProviderRemoteObject(eventForNewCalendar)
    }

    private func currentProviderFailureMessage() -> String {
        let message = providerSyncMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? "Provider operation failed. Working Calendar will retry." : message
    }

    @discardableResult
    private func recordProviderActionError(accountID: String, error: Error) -> Bool {
        currentProviderActionFailureKind = providerOutboxFailureKind(for: error)
        currentProviderRetryAfterSeconds = (error as? ProviderRetryAfterError)?.providerRetryAfterSeconds
        providerStore.recordSyncError(accountID: accountID, error: error)
        providerSyncMessage = error.localizedDescription
        return false
    }

    func providerOutboxFailureKind(for error: Error) -> ProviderOutboxFailureKind {
        switch error {
        case CalDAVClientError.preconditionFailed(_),
             GoogleCalendarClientError.remoteConflict(_),
             MicrosoftGraphCalendarClientError.remoteConflict(_):
            return .conflict
        case CalDAVClientError.httpStatus(let status, _) where isConflictProviderHTTPStatus(status):
            return .conflict
        case CalDAVClientError.missingCredentials,
             CalDAVClientError.calendarNotFound,
             CalDAVClientError.remoteObjectMissing,
             CalDAVClientError.scheduleOutboxNotFound,
             CalDAVClientError.replyAttendeeNotFound:
            return .blocked
        case CalDAVClientError.httpStatus(let status, _) where isBlockedProviderHTTPStatus(status):
            return .blocked
        case GoogleCalendarClientError.missingAccessToken,
             GoogleCalendarClientError.missingRefreshToken,
             GoogleCalendarClientError.calendarNotFound,
             GoogleCalendarClientError.remoteObjectMissing,
             GoogleCalendarClientError.invalidRemoteObject,
             GoogleCalendarClientError.invalidEventDate,
             GoogleCalendarClientError.selfAttendeeNotFound,
             GoogleCalendarClientError.unsupportedReminderOverrides:
            return .blocked
        case GoogleCalendarClientError.httpStatus(let status, _, _) where isConflictProviderHTTPStatus(status):
            return .conflict
        case GoogleCalendarClientError.httpStatus(let status, _, _) where isBlockedProviderHTTPStatus(status):
            return .blocked
        case MicrosoftGraphCalendarClientError.missingAccessToken,
             MicrosoftGraphCalendarClientError.missingRefreshToken,
             MicrosoftGraphCalendarClientError.calendarNotFound,
             MicrosoftGraphCalendarClientError.remoteObjectMissing,
             MicrosoftGraphCalendarClientError.invalidEventDate,
             MicrosoftGraphCalendarClientError.unsupportedRelativeRecurrenceOrdinal,
             MicrosoftGraphCalendarClientError.unsupportedNegativeRecurrenceMonthDay,
             MicrosoftGraphCalendarClientError.unsupportedMonthlyRecurrenceMonths,
             MicrosoftGraphCalendarClientError.unsupportedYearlyRecurrenceMonths,
             MicrosoftGraphCalendarClientError.unsupportedWeeklyRecurrenceSetPositions,
             MicrosoftGraphCalendarClientError.unsupportedAdditionalOccurrences,
             MicrosoftGraphCalendarClientError.unsupportedMultipleReminders:
            return .blocked
        case MicrosoftGraphCalendarClientError.httpStatus(let status, _, _) where isConflictProviderHTTPStatus(status):
            return .conflict
        case MicrosoftGraphCalendarClientError.httpStatus(let status, _, _) where isBlockedProviderHTTPStatus(status):
            return .blocked
        default:
            return .retryable
        }
    }

    private func isConflictProviderHTTPStatus(_ status: Int) -> Bool {
        [409, 412].contains(status)
    }

    private func isBlockedProviderHTTPStatus(_ status: Int) -> Bool {
        [400, 401, 403, 405, 501].contains(status)
    }

    private func updateDockIcon(now: Date = Date()) {
        dockIconService.update(
            date: now,
            upcomingCount: agendaEvents(now: now)
                .filter { $0.countsTowardDockUpcoming(at: now) }
                .count
        )
    }

    private func fetchICSSubscription(_ account: CalendarProviderAccount) async throws -> ICSSubscriptionFetchResult {
        try await CalendarSubscriptionHTTP.fetch(account: account)
    }

    private func syncICSSubscriptionAccount(_ account: CalendarProviderAccount, text: String) throws -> LocalICSImportSummary {
        try CalendarSubscriptionSyncer().sync(
            text: text,
            account: account,
            store: localCalendarStore,
            ownedCalendarIDs: providerCalendarIDs(ownedBy: account)
        )
    }

    private func cancelledOccurrences(fromICSText text: String) -> Set<LocalProviderOccurrenceCancellation> {
        LocalCalendarICSCodec.cancellationTargets(from: text).occurrences
    }

    @discardableResult
    private func writeBackCalDAVEvent(_ event: LocalCalendarEvent) async -> Bool {
        guard let account = calDAVAccount(forCalendarID: event.calendarID),
              let localCalendar = localCalendarStore.calendar(withID: event.calendarID)
        else {
            return false
        }

        do {
            let remoteCalendar = try await calDAVClient.calendarMatching(
                localCalendarID: event.calendarID,
                account: account
            )
            let writeResult = try await calDAVClient.putEvent(
                event,
                localCalendar: localCalendar,
                account: account,
                calendar: remoteCalendar
            )
            localCalendarStore.setRemoteObjectURL(
                eventID: event.id,
                remoteObjectURLString: writeResult.remoteObjectURL.absoluteString,
                remoteETag: writeResult.eTag
            )
            providerStore.recordProviderActionSuccess(accountID: account.id)
            providerSyncMessage = "\(account.title): event saved"
            return true
        } catch {
            return recordProviderActionError(accountID: account.id, error: error)
        }
    }

    @discardableResult
    private func deleteCalDAVEvent(_ event: LocalCalendarEvent) async -> Bool {
        guard let account = calDAVAccount(forCalendarID: event.calendarID) else {
            return false
        }
        guard let remoteObjectURL = URL(string: event.remoteObjectURLString),
              remoteObjectURL.scheme != nil
        else {
            return true
        }

        do {
            try await calDAVClient.deleteEventObject(
                account: account,
                remoteObjectURL: remoteObjectURL,
                remoteETag: event.remoteETag
            )
            providerStore.recordProviderActionSuccess(accountID: account.id)
            providerSyncMessage = "\(account.title): event deleted"
            return true
        } catch {
            return recordProviderActionError(accountID: account.id, error: error)
        }
    }

    private func calDAVAccount(forCalendarID calendarID: String) -> CalendarProviderAccount? {
        providerAccount(forCalendarID: calendarID, kind: .calDAV, enabledOnly: true)
    }

    private func googleCalendarAccount(forCalendarID calendarID: String) -> CalendarProviderAccount? {
        providerAccount(forCalendarID: calendarID, kind: .googleCalendar, enabledOnly: true)
    }

    private func microsoft365Account(forCalendarID calendarID: String) -> CalendarProviderAccount? {
        providerAccount(forCalendarID: calendarID, kind: .microsoft365, enabledOnly: true)
    }

    private func providerAccount(forCalendarID calendarID: String) -> CalendarProviderAccount? {
        providerAccount(forCalendarID: calendarID, kind: nil, enabledOnly: false)
    }

    private func providerAccount(
        forCalendarID calendarID: String,
        kind: CalendarProviderKind?,
        enabledOnly: Bool
    ) -> CalendarProviderAccount? {
        providerStore.accounts
            .compactMap { account -> (account: CalendarProviderAccount, prefixLength: Int)? in
                if let kind, account.kind != kind { return nil }
                if enabledOnly && !account.enabled { return nil }
                guard let prefix = providerCalendarIDPrefix(for: account),
                      calendarID.hasPrefix(prefix)
                else {
                    return nil
                }
                return (account, prefix.count)
            }
            .sorted { lhs, rhs in lhs.prefixLength > rhs.prefixLength }
            .first?
            .account
    }

    private func providerCalendarIDs(ownedBy account: CalendarProviderAccount) -> Set<String> {
        Set(localCalendarStore.calendars.compactMap { calendar in
            providerAccount(forCalendarID: calendar.id)?.id == account.id ? calendar.id : nil
        })
    }

    private func isProviderBackedCalendarID(_ calendarID: String) -> Bool {
        calendarID.hasPrefix("local-calendar-ics-")
            || calendarID.hasPrefix("local-calendar-caldav-")
            || calendarID.hasPrefix("local-calendar-google-")
            || calendarID.hasPrefix("local-calendar-microsoft365-")
    }

    private func providerCalendarIDPrefix(for account: CalendarProviderAccount) -> String? {
        switch account.kind {
        case .icsSubscription:
            return icsCalendarIDPrefix(for: account)
        case .calDAV:
            return "local-calendar-caldav-\(account.id)-"
        case .googleCalendar:
            return googleCalendarClient.localCalendarIDPrefix(for: account)
        case .microsoft365:
            return microsoftGraphClient.localCalendarIDPrefix(for: account)
        case .local:
            return nil
        }
    }

    private func icsCalendarIDPrefix(for account: CalendarProviderAccount) -> String {
        "local-calendar-ics-\(account.id)-"
    }

    private func providerImportWindow(now: Date = Date()) -> DateInterval {
        let calendar = Calendar.current
        let rawStart = calendar.date(byAdding: .day, value: -30, to: now) ?? now.addingTimeInterval(-30 * 24 * 3600)
        let rawEnd = calendar.date(byAdding: .month, value: 12, to: now) ?? now.addingTimeInterval(365 * 24 * 3600)
        let start = calendar.startOfDay(for: rawStart)
        let endDay = calendar.startOfDay(for: rawEnd)
        let end = calendar.date(byAdding: .day, value: 1, to: endDay) ?? rawEnd
        return DateInterval(start: start, end: end)
    }

    private func syncCalDAVAccount(_ account: CalendarProviderAccount) async throws -> CalDAVAccountSyncResult {
        let importWindow = providerImportWindow()
        let start = importWindow.start
        let end = importWindow.end
        var accountForSync = account
        let discoveredIdentityEmails = (try? await calDAVClient.fetchAccountIdentityEmails(account: account)) ?? []
        let fallbackIdentityEmails = CalendarProviderAccount.normalizedIdentityEmails([account.username ?? ""])
        let accountIdentityEmails = uniqueIdentityEmails(discoveredIdentityEmails + fallbackIdentityEmails)
        if !accountIdentityEmails.isEmpty {
            accountForSync.identityEmail = accountIdentityEmails[0]
            accountForSync.identityEmailAliases = Array(accountIdentityEmails.dropFirst())
        }
        let payloads = try await calDAVClient.fetchCalendarPayloads(
            account: accountForSync,
            startDate: start,
            endDate: end,
            syncStates: account.calDAVSyncStates
        )

        var aggregate = LocalICSImportSummary(
            calendarsImported: 0,
            eventsImported: 0,
            eventsUpdated: 0,
            eventsSkipped: 0
        )
        var seenRemoteObjectURLsByCalendarID: [String: Set<String>] = [:]
        var deletedRemoteObjectURLs: Set<String> = []
        var syncStates: [CalDAVCalendarSyncState] = []
        let ownedCalendarIDs = providerCalendarIDs(ownedBy: account)
        let protectedRemoteObjectURLs = providerStore.remoteObjectURLsProtectedFromPruning(accountID: account.id)
        let protectedResponseRemoteObjectURLs = providerStore.localResponseRemoteObjectURLsProtectedFromProviderRefresh(accountID: account.id)
        let protectedCalendarIDs = providerStore.calendarIDsProtectedFromPruning(accountID: account.id)

        for payload in payloads {
            syncStates.append(payload.syncState)
            deletedRemoteObjectURLs.formUnion(payload.deletedObjectHrefs)

            let calendarID = calDAVClient.localCalendarID(for: account, calendar: payload.calendar)
            if payload.reportsCompleteObjectSetForPruning {
                if seenRemoteObjectURLsByCalendarID[calendarID] == nil {
                    seenRemoteObjectURLsByCalendarID[calendarID] = []
                }
            }
            for object in payload.objects {
                if payload.reportsCompleteObjectSetForPruning {
                    seenRemoteObjectURLsByCalendarID[calendarID, default: []].insert(object.href.absoluteString)
                }
                let text = calDAVClient.annotatedICSText(
                    object: object,
                    calendar: payload.calendar,
                    account: accountForSync
                )
                let summary = try ProviderICSObjectSyncer().syncObject(
                    text: text,
                    protocolText: object.icsText,
                    remoteObjectURL: object.href.absoluteString,
                    calendarIDPrefix: providerCalendarIDPrefix(for: account) ?? "",
                    store: localCalendarStore,
                    ownedCalendarIDs: ownedCalendarIDs,
                    protectingRemoteObjectURLs: protectedRemoteObjectURLs,
                    preservingLocalResponsesForRemoteObjectURLs: protectedResponseRemoteObjectURLs
                )
                aggregate.calendarsImported += summary.calendarsImported
                aggregate.eventsImported += summary.eventsImported
                aggregate.eventsUpdated += summary.eventsUpdated
                aggregate.eventsSkipped += summary.eventsSkipped
                aggregate.eventsDeleted += summary.eventsDeleted
            }
        }
        aggregate.eventsDeleted += localCalendarStore.removeProviderEvents(
            remoteObjectURLs: deletedRemoteObjectURLs,
            calendarIDs: ownedCalendarIDs,
            protectingRemoteObjectURLs: protectedRemoteObjectURLs
        )

        for (calendarID, seenRemoteObjectURLs) in seenRemoteObjectURLsByCalendarID {
            aggregate.eventsDeleted += localCalendarStore.pruneProviderEvents(
                calendarID: calendarID,
                keepingRemoteObjectURLs: seenRemoteObjectURLs,
                pruneRange: DateInterval(start: start, end: end),
                protectingRemoteObjectURLs: protectedRemoteObjectURLs
            )
        }
        let discoveredCalendarIDs = Set(payloads.map { calDAVClient.localCalendarID(for: account, calendar: $0.calendar) })
        let deletedCalendars = localCalendarStore.pruneProviderCalendars(
            ownedCalendarIDs: ownedCalendarIDs,
            keepingCalendarIDs: discoveredCalendarIDs,
            protectingCalendarIDs: protectedCalendarIDs
        )
        aggregate.eventsDeleted += deletedCalendars.eventsDeleted

        return CalDAVAccountSyncResult(
            summary: aggregate,
            syncStates: syncStates,
            accountIdentityEmails: accountIdentityEmails
        )
    }

    private func uniqueIdentityEmails(_ values: [String]) -> [String] {
        CalendarProviderAccount.normalizedIdentityEmails(values)
    }

    private func syncGoogleCalendarAccount(_ account: CalendarProviderAccount) async throws -> GoogleCalendarAccountSyncResult {
        let importWindow = providerImportWindow()
        let start = importWindow.start
        let end = importWindow.end
        let payloads = try await googleCalendarClient.fetchCalendarPayloads(
            account: account,
            startDate: start,
            endDate: end,
            syncStates: account.googleCalendarSyncStates
        )
        let accountIdentityEmails = uniqueIdentityEmails(payloads.flatMap(\.accountIdentityEmails))
        var accountForSync = account
        if !accountIdentityEmails.isEmpty {
            accountForSync.identityEmail = accountIdentityEmails[0]
            accountForSync.identityEmailAliases = Array(accountIdentityEmails.dropFirst())
        }

        var aggregate = LocalICSImportSummary(
            calendarsImported: 0,
            eventsImported: 0,
            eventsUpdated: 0,
            eventsSkipped: 0
        )
        var seenRemoteObjectURLsByCalendarID: [String: Set<String>] = [:]
        var deletedRemoteObjectURLs: Set<String> = []
        var cancelledRemoteOccurrences: Set<LocalProviderRemoteOccurrenceCancellation> = []
        var syncStates: [GoogleCalendarSyncState] = []
        let protectedResponseRemoteObjectURLs = providerStore.localResponseRemoteObjectURLsProtectedFromProviderRefresh(accountID: account.id)

        for payload in payloads {
            if !payload.syncToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                syncStates.append(payload.syncState)
            }
            deletedRemoteObjectURLs.formUnion(payload.deletedRemoteObjectURLs)
            cancelledRemoteOccurrences.formUnion(payload.cancelledRemoteOccurrences)

            if !payload.isIncremental {
                let calendarID = googleCalendarClient.localCalendarID(for: account, googleCalendarID: payload.calendar.id)
                if seenRemoteObjectURLsByCalendarID[calendarID] == nil {
                    seenRemoteObjectURLsByCalendarID[calendarID] = []
                }
                seenRemoteObjectURLsByCalendarID[calendarID]?.formUnion(
                    googleCalendarClient.remoteObjectURLStringsForImportedEvents(
                        events: payload.events,
                        calendar: payload.calendar,
                        account: accountForSync
                    )
                )
            }

            let text: String
            do {
                text = try googleCalendarClient.annotatedICSText(
                    events: payload.events,
                    calendar: payload.calendar,
                    account: accountForSync
                )
            } catch GoogleCalendarClientError.invalidEventDate {
                if isDeleteOnlyGooglePayload(payload) {
                    continue
                }
                aggregate.eventsSkipped += payload.events.count
                continue
            }

            let summary: LocalICSImportSummary
            do {
                summary = try localCalendarStore.importICSText(
                    text,
                    preservingLocalResponsesForRemoteObjectURLs: protectedResponseRemoteObjectURLs
                )
            } catch LocalICSImportError.noEvents {
                if isDeleteOnlyGooglePayload(payload) {
                    continue
                }
                aggregate.eventsSkipped += payload.events.count
                continue
            }
            aggregate.calendarsImported += summary.calendarsImported
            aggregate.eventsImported += summary.eventsImported
            aggregate.eventsUpdated += summary.eventsUpdated
            aggregate.eventsSkipped += summary.eventsSkipped
        }
        let ownedCalendarIDs = providerCalendarIDs(ownedBy: account)
        let protectedRemoteObjectURLs = providerStore.remoteObjectURLsProtectedFromPruning(accountID: account.id)
        let protectedCalendarIDs = providerStore.calendarIDsProtectedFromPruning(accountID: account.id)
        aggregate.eventsDeleted += localCalendarStore.cancelProviderRemoteOccurrences(
            cancelledRemoteOccurrences,
            calendarIDs: ownedCalendarIDs,
            protectingRemoteObjectURLs: protectedRemoteObjectURLs
        )
        aggregate.eventsDeleted += localCalendarStore.removeProviderEvents(
            remoteObjectURLs: deletedRemoteObjectURLs,
            calendarIDs: ownedCalendarIDs,
            protectingRemoteObjectURLs: protectedRemoteObjectURLs
        )

        for (calendarID, seenRemoteObjectURLs) in seenRemoteObjectURLsByCalendarID {
            aggregate.eventsDeleted += localCalendarStore.pruneProviderEvents(
                calendarID: calendarID,
                keepingRemoteObjectURLs: seenRemoteObjectURLs,
                pruneRange: DateInterval(start: start, end: end),
                protectingRemoteObjectURLs: protectedRemoteObjectURLs
            )
        }
        let discoveredCalendarIDs = Set(payloads.map { googleCalendarClient.localCalendarID(for: account, googleCalendarID: $0.calendar.id) })
        let deletedCalendars = localCalendarStore.pruneProviderCalendars(
            ownedCalendarIDs: ownedCalendarIDs,
            keepingCalendarIDs: discoveredCalendarIDs,
            protectingCalendarIDs: protectedCalendarIDs
        )
        aggregate.eventsDeleted += deletedCalendars.eventsDeleted

        return GoogleCalendarAccountSyncResult(
            summary: aggregate,
            syncStates: syncStates,
            accountIdentityEmails: accountIdentityEmails
        )
    }

    private func syncMicrosoft365Account(_ account: CalendarProviderAccount) async throws -> MicrosoftGraphAccountSyncResult {
        let importWindow = providerImportWindow()
        let start = importWindow.start
        let end = importWindow.end
        var accountForSync = account
        let accountIdentityEmails = (try? await microsoftGraphClient.fetchAccountIdentityEmails(account: account)) ?? []
        if !accountIdentityEmails.isEmpty {
            accountForSync.identityEmail = accountIdentityEmails[0]
            accountForSync.identityEmailAliases = Array(accountIdentityEmails.dropFirst())
        }
        let payloads = try await microsoftGraphClient.fetchCalendarPayloads(
            account: accountForSync,
            startDate: start,
            endDate: end,
            syncStates: account.microsoftGraphSyncStates
        )

        var aggregate = LocalICSImportSummary(
            calendarsImported: 0,
            eventsImported: 0,
            eventsUpdated: 0,
            eventsSkipped: 0
        )
        var seenRemoteObjectURLsByCalendarID: [String: Set<String>] = [:]
        var deletedRemoteObjectURLs: Set<String> = []
        var cancelledDetachedOccurrenceRemoteObjectURLs: Set<String> = []
        var cancelledRemoteOccurrences: Set<LocalProviderRemoteOccurrenceCancellation> = []
        var syncStates: [MicrosoftGraphSyncState] = []
        let protectedResponseRemoteObjectURLs = providerStore.localResponseRemoteObjectURLsProtectedFromProviderRefresh(accountID: account.id)

        for payload in payloads {
            if !payload.deltaLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                syncStates.append(payload.syncState)
            }
            deletedRemoteObjectURLs.formUnion(payload.deletedRemoteObjectURLs)
            cancelledDetachedOccurrenceRemoteObjectURLs.formUnion(payload.cancelledDetachedOccurrenceRemoteObjectURLs)
            cancelledRemoteOccurrences.formUnion(payload.cancelledRemoteOccurrences)

            if !payload.isIncremental {
                let calendarID = microsoftGraphClient.localCalendarID(for: account, graphCalendarID: payload.calendar.id)
                if seenRemoteObjectURLsByCalendarID[calendarID] == nil {
                    seenRemoteObjectURLsByCalendarID[calendarID] = []
                }
                seenRemoteObjectURLsByCalendarID[calendarID]?.formUnion(
                    microsoftGraphClient.remoteObjectURLStringsForImportedEvents(
                        events: payload.events,
                        calendar: payload.calendar,
                        account: accountForSync
                    )
                )
            }

            let text: String
            do {
                text = try microsoftGraphClient.annotatedICSText(
                    events: payload.events,
                    calendar: payload.calendar,
                    account: accountForSync
                )
            } catch MicrosoftGraphCalendarClientError.invalidEventDate {
                if isDeleteOnlyMicrosoftGraphPayload(payload) {
                    continue
                }
                aggregate.eventsSkipped += payload.events.count
                continue
            }

            let summary: LocalICSImportSummary
            do {
                summary = try localCalendarStore.importICSText(
                    text,
                    preservingLocalResponsesForRemoteObjectURLs: protectedResponseRemoteObjectURLs
                )
            } catch LocalICSImportError.noEvents {
                if isDeleteOnlyMicrosoftGraphPayload(payload) {
                    continue
                }
                aggregate.eventsSkipped += payload.events.count
                continue
            }
            aggregate.calendarsImported += summary.calendarsImported
            aggregate.eventsImported += summary.eventsImported
            aggregate.eventsUpdated += summary.eventsUpdated
            aggregate.eventsSkipped += summary.eventsSkipped
        }
        let ownedCalendarIDs = providerCalendarIDs(ownedBy: account)
        let protectedRemoteObjectURLs = providerStore.remoteObjectURLsProtectedFromPruning(accountID: account.id)
        let protectedCalendarIDs = providerStore.calendarIDsProtectedFromPruning(accountID: account.id)
        aggregate.eventsDeleted += localCalendarStore.cancelProviderRemoteOccurrences(
            cancelledRemoteOccurrences,
            calendarIDs: ownedCalendarIDs,
            protectingRemoteObjectURLs: protectedRemoteObjectURLs
        )
        aggregate.eventsDeleted += localCalendarStore.cancelProviderDetachedOccurrences(
            remoteObjectURLs: cancelledDetachedOccurrenceRemoteObjectURLs,
            calendarIDs: ownedCalendarIDs,
            protectingRemoteObjectURLs: protectedRemoteObjectURLs
        )
        aggregate.eventsDeleted += localCalendarStore.removeProviderEvents(
            remoteObjectURLs: deletedRemoteObjectURLs,
            calendarIDs: ownedCalendarIDs,
            protectingRemoteObjectURLs: protectedRemoteObjectURLs
        )

        for (calendarID, seenRemoteObjectURLs) in seenRemoteObjectURLsByCalendarID {
            aggregate.eventsDeleted += localCalendarStore.pruneProviderEvents(
                calendarID: calendarID,
                keepingRemoteObjectURLs: seenRemoteObjectURLs,
                pruneRange: DateInterval(start: start, end: end),
                protectingRemoteObjectURLs: protectedRemoteObjectURLs
            )
        }
        let discoveredCalendarIDs = Set(payloads.map { microsoftGraphClient.localCalendarID(for: account, graphCalendarID: $0.calendar.id) })
        let deletedCalendars = localCalendarStore.pruneProviderCalendars(
            ownedCalendarIDs: ownedCalendarIDs,
            keepingCalendarIDs: discoveredCalendarIDs,
            protectingCalendarIDs: protectedCalendarIDs
        )
        aggregate.eventsDeleted += deletedCalendars.eventsDeleted

        return MicrosoftGraphAccountSyncResult(
            summary: aggregate,
            syncStates: syncStates,
            accountIdentityEmails: accountIdentityEmails
        )
    }

    private func isDeleteOnlyGooglePayload(_ payload: GoogleCalendarPayload) -> Bool {
        (!payload.deletedRemoteObjectURLs.isEmpty || !payload.cancelledRemoteOccurrences.isEmpty)
            && !payload.events.contains { !$0.isCancelled }
    }

    private func isDeleteOnlyMicrosoftGraphPayload(_ payload: MicrosoftGraphCalendarPayload) -> Bool {
        (!payload.deletedRemoteObjectURLs.isEmpty
         || !payload.cancelledDetachedOccurrenceRemoteObjectURLs.isEmpty
         || !payload.cancelledRemoteOccurrences.isEmpty)
            && !payload.events.contains { $0.shouldImport }
    }

    private func respondToProviderEvent(
        _ event: LocalCalendarEvent,
        response: CalendarEventResponse,
        scope: CalendarEventResponseScope,
        occurrenceStartDate: Date?,
        occurrenceIsAllDay: Bool,
        hadLocalProviderRecurrenceChanges: Bool
    ) async -> Bool {
        if googleCalendarAccount(forCalendarID: event.calendarID) != nil {
            return await respondToGoogleCalendarEvent(
                event,
                response: response,
                scope: scope,
                occurrenceStartDate: occurrenceStartDate,
                occurrenceIsAllDay: occurrenceIsAllDay,
                hadLocalProviderRecurrenceChanges: hadLocalProviderRecurrenceChanges
            )
        }
        if microsoft365Account(forCalendarID: event.calendarID) != nil {
            return await respondToMicrosoft365Event(
                event,
                response: response,
                scope: scope,
                occurrenceStartDate: occurrenceStartDate,
                occurrenceIsAllDay: occurrenceIsAllDay,
                hadLocalProviderRecurrenceChanges: hadLocalProviderRecurrenceChanges
            )
        }
        if calDAVAccount(forCalendarID: event.calendarID) != nil {
            return await respondToCalDAVEvent(
                event,
                response: response,
                scope: scope,
                occurrenceStartDate: occurrenceStartDate,
                occurrenceIsAllDay: occurrenceIsAllDay,
                hadLocalProviderRecurrenceChanges: hadLocalProviderRecurrenceChanges
            )
        }
        if isProviderBackedCalendarID(event.calendarID) {
            providerSyncMessage = "Provider source is disabled or unavailable."
            return false
        }
        return true
    }

    @discardableResult
    private func respondToCalDAVEvent(
        _ event: LocalCalendarEvent,
        response: CalendarEventResponse,
        scope: CalendarEventResponseScope,
        occurrenceStartDate: Date?,
        occurrenceIsAllDay: Bool,
        hadLocalProviderRecurrenceChanges: Bool
    ) async -> Bool {
        guard let account = calDAVAccount(forCalendarID: event.calendarID) else {
            return false
        }

        do {
            try await calDAVClient.respondToEvent(
                account: account,
                event: event,
                response: response,
                occurrenceStartDate: occurrenceStartDate,
                occurrenceIsAllDay: occurrenceIsAllDay
            )
            if scope == .allEvents && event.hasLocalProviderRecurrenceChanges {
                return await writeBackCalDAVEvent(event)
            }
            if occurrenceStartDate != nil && scope == .thisEvent && !hadLocalProviderRecurrenceChanges {
                localCalendarStore.clearLocalProviderRecurrenceChanges(eventID: event.id)
            }
            providerStore.recordProviderActionSuccess(accountID: account.id)
            providerSyncMessage = "\(account.title): \(scope == .allEvents ? "series response" : "response") sent"
            return true
        } catch let error as CalDAVClientError
            where error.allowsSchedulingReplyWriteBackFallback && canEditLocalEvent(event) {
            return await writeBackCalDAVEvent(event)
        } catch {
            return recordProviderActionError(accountID: account.id, error: error)
        }
    }

    @discardableResult
    private func writeBackGoogleCalendarEvent(_ event: LocalCalendarEvent) async -> Bool {
        guard let account = googleCalendarAccount(forCalendarID: event.calendarID),
              let localCalendar = localCalendarStore.calendar(withID: event.calendarID)
        else {
            return false
        }

        do {
            let writeResult = try await googleCalendarClient.putEvent(
                event,
                localCalendar: localCalendar,
                account: account
            )
            localCalendarStore.setRemoteObjectURL(
                eventID: event.id,
                remoteObjectURLString: writeResult.remoteObjectURLString,
                remoteETag: writeResult.remoteETag
            )
            providerStore.recordProviderActionSuccess(accountID: account.id)
            providerSyncMessage = "\(account.title): event saved"
            return true
        } catch {
            return recordProviderActionError(accountID: account.id, error: error)
        }
    }

    @discardableResult
    private func deleteGoogleCalendarEvent(_ event: LocalCalendarEvent) async -> Bool {
        guard let account = googleCalendarAccount(forCalendarID: event.calendarID) else {
            return false
        }
        guard !event.remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }

        do {
            try await googleCalendarClient.deleteEvent(
                account: account,
                remoteObjectURLString: event.remoteObjectURLString,
                remoteETag: event.remoteETag
            )
            providerStore.recordProviderActionSuccess(accountID: account.id)
            providerSyncMessage = "\(account.title): event deleted"
            return true
        } catch {
            return recordProviderActionError(accountID: account.id, error: error)
        }
    }

    @discardableResult
    private func respondToGoogleCalendarEvent(
        _ event: LocalCalendarEvent,
        response: CalendarEventResponse,
        scope: CalendarEventResponseScope,
        occurrenceStartDate: Date?,
        occurrenceIsAllDay: Bool,
        hadLocalProviderRecurrenceChanges: Bool
    ) async -> Bool {
        guard let account = googleCalendarAccount(forCalendarID: event.calendarID),
              !event.remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }

        do {
            let remoteETag = try await googleCalendarClient.respondToEvent(
                account: account,
                remoteObjectURLString: event.remoteObjectURLString,
                response: response,
                occurrenceStartDate: occurrenceStartDate,
                occurrenceIsAllDay: occurrenceIsAllDay,
                occurrenceTimeZoneIdentifier: event.timeZoneIdentifier
            )
            var eventForFollowUpWrite = event
            if let remoteETag {
                eventForFollowUpWrite.remoteETag = remoteETag
                localCalendarStore.setRemoteObjectURL(
                    eventID: event.id,
                    remoteObjectURLString: event.remoteObjectURLString,
                    remoteETag: remoteETag,
                    clearsLocalProviderRecurrenceChanges: false
                )
            }
            if scope == .allEvents && eventForFollowUpWrite.hasLocalProviderRecurrenceChanges {
                return await writeBackGoogleCalendarEvent(eventForFollowUpWrite)
            }
            if occurrenceStartDate != nil && scope == .thisEvent && !hadLocalProviderRecurrenceChanges {
                localCalendarStore.clearLocalProviderRecurrenceChanges(eventID: event.id)
            }
            providerStore.recordProviderActionSuccess(accountID: account.id)
            providerSyncMessage = "\(account.title): \(scope == .allEvents ? "series response" : "response") sent"
            return true
        } catch {
            return recordProviderActionError(accountID: account.id, error: error)
        }
    }

    @discardableResult
    private func writeBackMicrosoft365Event(_ event: LocalCalendarEvent) async -> Bool {
        guard let account = microsoft365Account(forCalendarID: event.calendarID),
              let localCalendar = localCalendarStore.calendar(withID: event.calendarID)
        else {
            return false
        }

        do {
            let writeResult = try await microsoftGraphClient.putEvent(
                event,
                localCalendar: localCalendar,
                account: account
            )
            localCalendarStore.setRemoteObjectURL(
                eventID: event.id,
                remoteObjectURLString: writeResult.remoteObjectURLString,
                remoteETag: writeResult.remoteETag
            )
            providerStore.recordProviderActionSuccess(accountID: account.id)
            providerSyncMessage = "\(account.title): event saved"
            return true
        } catch {
            return recordProviderActionError(accountID: account.id, error: error)
        }
    }

    @discardableResult
    private func respondToMicrosoft365Event(
        _ event: LocalCalendarEvent,
        response: CalendarEventResponse,
        scope: CalendarEventResponseScope,
        occurrenceStartDate: Date?,
        occurrenceIsAllDay: Bool,
        hadLocalProviderRecurrenceChanges: Bool
    ) async -> Bool {
        guard let account = microsoft365Account(forCalendarID: event.calendarID),
              !event.remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }

        do {
            let remoteETag = try await microsoftGraphClient.respondToEvent(
                account: account,
                remoteObjectURLString: event.remoteObjectURLString,
                response: response,
                occurrenceStartDate: occurrenceStartDate,
                occurrenceIsAllDay: occurrenceIsAllDay,
                occurrenceTimeZoneIdentifier: event.timeZoneIdentifier
            )
            var eventForFollowUpWrite = event
            if let remoteETag {
                eventForFollowUpWrite.remoteETag = remoteETag
                localCalendarStore.setRemoteObjectURL(
                    eventID: event.id,
                    remoteObjectURLString: event.remoteObjectURLString,
                    remoteETag: remoteETag,
                    clearsLocalProviderRecurrenceChanges: false
                )
            }
            if scope == .allEvents && eventForFollowUpWrite.hasLocalProviderRecurrenceChanges {
                return await writeBackMicrosoft365Event(eventForFollowUpWrite)
            }
            if occurrenceStartDate != nil && scope == .thisEvent && !hadLocalProviderRecurrenceChanges {
                localCalendarStore.clearLocalProviderRecurrenceChanges(eventID: event.id)
            }
            providerStore.recordProviderActionSuccess(accountID: account.id)
            providerSyncMessage = "\(account.title): \(scope == .allEvents ? "series response" : "response") sent"
            return true
        } catch {
            return recordProviderActionError(accountID: account.id, error: error)
        }
    }

    private func responseOccurrenceStartDate(
        for sourceEvent: CalendarEvent,
        scope: CalendarEventResponseScope
    ) -> Date? {
        guard scope == .thisEvent, sourceEvent.isRecurring else { return nil }
        return sourceEvent.occurrenceStartDate
    }

    @discardableResult
    private func deleteMicrosoft365Event(_ event: LocalCalendarEvent) async -> Bool {
        guard let account = microsoft365Account(forCalendarID: event.calendarID) else {
            return false
        }
        guard !event.remoteObjectURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }

        do {
            try await microsoftGraphClient.deleteEvent(
                account: account,
                remoteObjectURLString: event.remoteObjectURLString,
                remoteETag: event.remoteETag
            )
            providerStore.recordProviderActionSuccess(accountID: account.id)
            providerSyncMessage = "\(account.title): event deleted"
            return true
        } catch {
            return recordProviderActionError(accountID: account.id, error: error)
        }
    }

    private func syncMessage(for title: String, summary: LocalICSImportSummary) -> String {
        var parts: [String] = []
        if summary.eventsImported > 0 { parts.append("\(summary.eventsImported) imported") }
        if summary.eventsUpdated > 0 { parts.append("\(summary.eventsUpdated) updated") }
        if summary.eventsDeleted > 0 { parts.append("\(summary.eventsDeleted) removed") }
        if summary.eventsSkipped > 0 { parts.append("\(summary.eventsSkipped) skipped") }
        let details = parts.isEmpty ? "no changes" : parts.joined(separator: ", ")
        return "\(title): \(details)"
    }

    private func isExternalCalendarSubscriptionURL(_ url: URL) -> Bool {
        CalendarURLNormalizer.isLikelySubscriptionURL(url)
    }

    private func externalCalendarTitle(for url: URL) -> String {
        let fileTitle = url.deletingPathExtension().lastPathComponent
            .removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fileTitle.isEmpty {
            return fileTitle
        }

        let hostTitle = url.host?
            .replacingOccurrences(of: "www.", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return hostTitle.isEmpty ? "Imported Calendar" : hostTitle
    }

    private func alertEvents(now: Date) -> [CalendarEvent] {
        let fetchHours = max(lookAheadHours, responseLookAheadHours)
        return visibleEvents(localCalendarStore.events(inNextHours: fetchHours, now: now))
    }

    private func visibleEvents(_ events: [CalendarEvent]) -> [CalendarEvent] {
        events
            .filter { isVisibleCalendarID($0.calendarID) }
            .map(enrichedEvent)
    }

    private func isVisibleCalendarID(_ calendarID: String) -> Bool {
        guard let account = providerAccount(forCalendarID: calendarID) else {
            return !isProviderBackedCalendarID(calendarID)
        }

        return account.enabled
    }

    private func enrichedEvent(_ event: CalendarEvent) -> CalendarEvent {
        let sourceTitle = sourceTitle(forCalendarID: event.calendarID)
        guard event.sourceTitle != sourceTitle else { return event }
        return event.withSourceTitle(sourceTitle)
    }

    private func sourceTitle(forCalendarID calendarID: String) -> String {
        providerStore.accounts.first { account in
            providerCalendarIDPrefix(for: account).map { calendarID.hasPrefix($0) } ?? false
        }?.title ?? "Working Calendar"
    }

    private func base64URLEncode(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func stableIdentifierComponent(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return UUID().uuidString }

        var hash: UInt64 = 14695981039346656037
        for byte in trimmed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    private func escapeICSText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
    }
}


private extension CalendarEvent {
    func withSourceTitle(_ sourceTitle: String) -> CalendarEvent {
        CalendarEvent(
            id: id,
            eventIdentifier: eventIdentifier,
            calendarItemIdentifier: calendarItemIdentifier,
            externalIdentifier: externalIdentifier,
            sequence: sequence,
            title: title,
            startDate: startDate,
            endDate: endDate,
            occurrenceStartDate: occurrenceStartDate,
            isAllDay: isAllDay,
            availability: availability,
            status: status,
            privacy: privacy,
            importance: importance,
            categories: categories,
            reminderOffsets: reminderOffsets,
            timeZoneIdentifier: timeZoneIdentifier,
            isRecurring: isRecurring,
            isDetached: isDetached,
            calendarID: calendarID,
            calendarTitle: calendarTitle,
            sourceTitle: sourceTitle,
            calendarColor: calendarColor,
            location: location,
            notes: notes,
            url: url,
            responseStatus: responseStatus,
            responseStatusIsExplicit: responseStatusIsExplicit,
            attendeeCount: attendeeCount,
            organizer: organizer,
            participants: participants
        )
    }
}
