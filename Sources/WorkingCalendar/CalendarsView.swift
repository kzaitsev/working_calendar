import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CalendarsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var providerStore: CalendarProviderStore
    @Binding private var pendingProviderSourceSetupIntent: ProviderSourceSetupIntent?
    @State private var searchText = ""
    @State private var localCalendarDraft: LocalCalendarDraft?
    @State private var isAddingSource = false
    @State private var preferredAddSource: ProviderDiagnosticSource?
    @State private var editProviderCandidate: CalendarProviderAccount?
    @State private var deleteProviderCandidate: CalendarProviderAccount?
    @State private var reconnectProviderCandidate: CalendarProviderAccount?
    @State private var deleteLocalCalendarCandidate: LocalCalendar?
    @State private var discardOutboxCandidate: ProviderOutboxItem?
    @State private var fileMessage: String?

    private static let icsContentType = UTType(filenameExtension: "ics") ?? .plainText

    init(pendingProviderSourceSetupIntent: Binding<ProviderSourceSetupIntent?> = .constant(nil)) {
        _pendingProviderSourceSetupIntent = pendingProviderSourceSetupIntent
    }

    private var visibleMessage: String? {
        fileMessage ?? model.providerSyncMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HeaderBar(
                title: "Calendars",
                subtitle: "\(appOwnedCalendars.count) app · \(providerBackedCalendars.count) synced · \(providerStore.accounts.count) sources",
                actionTitle: "Refresh",
                actionSystemImage: "arrow.clockwise"
            ) {
                Task { await model.syncProviderSources(force: true) }
            }

            HStack(spacing: 10) {
                Label("\(model.agendaEvents().count) upcoming", systemImage: "calendar.badge.clock")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Label("\(providerStore.accounts.count) sources", systemImage: "link")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if providerAttentionCount > 0 {
                    Label("\(providerAttentionCount) attention", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                if retryableProviderOutboxCount > 0 {
                    Label("\(retryableProviderOutboxCount) pending", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                TextField("Search calendars", text: $searchText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(width: 260)

                Spacer()

                if let visibleMessage {
                    Text(visibleMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 260, alignment: .trailing)
                }

                Button {
                    preferredAddSource = nil
                    isAddingSource = true
                } label: {
                    Label("Add Source", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Button {
                    importICS()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Button {
                    exportICS()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(model.localCalendarStore.events.isEmpty)

                Button {
                    localCalendarDraft = model.localCalendarStore.newCalendarDraft()
                } label: {
                    Label("New Local Calendar", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    LocalCalendarAccountSection(
                        title: "App Calendars",
                        subtitle: "\(appOwnedEventCount) app-owned events · \(filteredAppOwnedCalendars.count) calendars",
                        badgeTitle: "Working Calendar",
                        accentColor: .teal,
                        calendars: filteredAppOwnedCalendars,
                        edit: { calendar in localCalendarDraft = model.localCalendarStore.draft(for: calendar) },
                        delete: { calendar in deleteLocalCalendarCandidate = calendar }
                    )

                    if !filteredProviderBackedCalendars.isEmpty {
                        LocalCalendarAccountSection(
                            title: "Synced Calendars",
                            subtitle: "\(filteredProviderBackedCalendars.count) calendars imported from provider sources",
                            badgeTitle: "Sources",
                            accentColor: .blue,
                            calendars: filteredProviderBackedCalendars,
                            edit: { calendar in localCalendarDraft = model.localCalendarStore.draft(for: calendar) },
                            delete: { calendar in deleteLocalCalendarCandidate = calendar }
                        )
                    }

                    ProviderAccountSection(
                        accounts: filteredProviderAccounts,
                        add: { source in
                            preferredAddSource = source
                            isAddingSource = true
                        },
                        sync: { account in Task { await model.syncProviderAccount(account) } },
                        fullRefresh: { account in Task { await model.fullRefreshProviderAccount(account) } },
                        edit: { account in editProviderCandidate = account },
                        reconnect: { account in reconnectProviderCandidate = account },
                        toggle: { account in
                            providerStore.setAccount(account, enabled: !account.enabled)
                            if !account.enabled {
                                Task { await model.syncProviderAccount(account) }
                            }
                        },
                        delete: { account in deleteProviderCandidate = account }
                    )

                    if !providerStore.providerOutbox.isEmpty {
                        ProviderOutboxSection(
                            items: providerStore.providerOutbox,
                            accounts: providerStore.accounts,
                            retryAll: { Task { await model.retryProviderOutboxNow() } },
                            retry: { item in Task { await model.retryProviderOutboxItemNow(item) } },
                            discard: { item in discardOutboxCandidate = item }
                        )
                    }

                }
                .padding(.bottom, 20)
            }
        }
        .padding(28)
        .onAppear {
            presentPendingAddSourceIfNeeded()
        }
        .onChange(of: pendingProviderSourceSetupIntent) { _, _ in
            presentPendingAddSourceIfNeeded()
        }
        .sheet(isPresented: $isAddingSource) {
            ProviderSourceEditorView(
                preferredSource: preferredAddSource,
                saveICS: { title, urlString in
                    let error = await model.addICSSubscription(title: title, urlString: urlString)
                    if error == nil {
                        isAddingSource = false
                        preferredAddSource = nil
                    }
                    return error
                },
                saveCalDAV: { title, urlString, username, password in
                    let error = await model.addCalDAVAccount(
                        title: title,
                        urlString: urlString,
                        username: username,
                        password: password
                    )
                    if error == nil {
                        isAddingSource = false
                        preferredAddSource = nil
                    }
                    return error
                },
                saveGoogle: { title, credential in
                    let error = await model.addGoogleCalendarAccount(title: title, credential: credential)
                    if error == nil {
                        isAddingSource = false
                        preferredAddSource = nil
                    }
                    return error
                },
                saveMicrosoft365: { title, credential in
                    let error = await model.addMicrosoft365Account(title: title, credential: credential)
                    if error == nil {
                        isAddingSource = false
                        preferredAddSource = nil
                    }
                    return error
                },
                cancel: {
                    isAddingSource = false
                    preferredAddSource = nil
                }
            )
        }
        .sheet(item: $editProviderCandidate) { account in
            ProviderSourceEditView(
                account: account,
                saveICS: { title, urlString in
                    let error = await model.updateICSSubscription(account, title: title, urlString: urlString)
                    if error == nil {
                        editProviderCandidate = nil
                    }
                    return error
                },
                saveCalDAV: { title, urlString, username, password in
                    let error = await model.updateCalDAVAccount(
                        account,
                        title: title,
                        urlString: urlString,
                        username: username,
                        password: password
                    )
                    if error == nil {
                        editProviderCandidate = nil
                    }
                    return error
                },
                cancel: {
                    editProviderCandidate = nil
                }
            )
        }
        .sheet(item: $reconnectProviderCandidate) { account in
            ProviderReconnectView(
                account: account,
                existingCredential: model.oauthCredential(for: account),
                save: { credential in
                    let error = await model.reconnectProviderAccount(account, credential: credential)
                    if error == nil {
                        reconnectProviderCandidate = nil
                    }
                    return error
                },
                cancel: {
                    reconnectProviderCandidate = nil
                }
            )
        }
        .sheet(item: $localCalendarDraft) { draft in
            LocalCalendarEditorView(
                draft: draft,
                save: { updatedDraft in
                    model.localCalendarStore.saveCalendar(updatedDraft)
                    localCalendarDraft = nil
                },
                cancel: {
                    localCalendarDraft = nil
                }
            )
        }
        .confirmationDialog(
            deleteLocalCalendarCandidate.map { "Delete “\($0.title)”?" } ?? "Delete calendar?",
            isPresented: Binding(
                get: { deleteLocalCalendarCandidate != nil },
                set: { if !$0 { deleteLocalCalendarCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let calendar = deleteLocalCalendarCandidate {
                Button("Delete Calendar", role: .destructive) {
                    model.localCalendarStore.deleteCalendar(calendar)
                    deleteLocalCalendarCandidate = nil
                }
            }

            Button("Cancel", role: .cancel) {
                deleteLocalCalendarCandidate = nil
            }
        } message: {
            Text("Events from this calendar will move to another local calendar so they are not lost.")
        }
        .confirmationDialog(
            deleteProviderCandidate.map { "Delete “\($0.title)”?" } ?? "Delete source?",
            isPresented: Binding(
                get: { deleteProviderCandidate != nil },
                set: { if !$0 { deleteProviderCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let account = deleteProviderCandidate {
                Button("Delete Source", role: .destructive) {
                    model.deleteProviderAccount(account)
                    deleteProviderCandidate = nil
                }
            }

            Button("Cancel", role: .cancel) {
                deleteProviderCandidate = nil
            }
        } message: {
            Text("Working Calendar will stop syncing this source and remove calendars and events imported from it.")
        }
        .confirmationDialog(
            discardOutboxCandidate.map { "Discard pending \($0.operation.title)?" } ?? "Discard pending update?",
            isPresented: Binding(
                get: { discardOutboxCandidate != nil },
                set: { if !$0 { discardOutboxCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let item = discardOutboxCandidate {
                Button("Discard Pending Update", role: .destructive) {
                    model.discardProviderOutboxItem(item)
                    discardOutboxCandidate = nil
                }
            }

            Button("Cancel", role: .cancel) {
                discardOutboxCandidate = nil
            }
        } message: {
            Text(discardOutboxCandidate.map { "The local event stays in Working Calendar; only this pending provider \($0.operation.title) is removed." } ?? "The local event stays in Working Calendar.")
        }
    }

    private var filteredLocalCalendars: [LocalCalendar] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.localCalendarStore.calendars }
        return model.localCalendarStore.calendars.filter { calendar in
            calendar.title.lowercased().contains(query)
                || model.backendInfo(for: calendar).sourceTitle.lowercased().contains(query)
                || model.backendInfo(for: calendar).sourceKindTitle.lowercased().contains(query)
                || "working calendar local stored synced provider".contains(query)
        }
    }

    private var appOwnedCalendars: [LocalCalendar] {
        model.localCalendarStore.calendars.filter { !model.backendInfo(for: $0).isProviderBacked }
    }

    private var providerBackedCalendars: [LocalCalendar] {
        model.localCalendarStore.calendars.filter { model.backendInfo(for: $0).isProviderBacked }
    }

    private var filteredAppOwnedCalendars: [LocalCalendar] {
        filteredLocalCalendars.filter { !model.backendInfo(for: $0).isProviderBacked }
    }

    private var filteredProviderBackedCalendars: [LocalCalendar] {
        filteredLocalCalendars.filter { model.backendInfo(for: $0).isProviderBacked }
    }

    private var appOwnedEventCount: Int {
        let appOwnedCalendarIDs = Set(filteredAppOwnedCalendars.map(\.id))
        return model.localCalendarStore.events.filter { appOwnedCalendarIDs.contains($0.calendarID) }.count
    }

    private var providerAttentionCount: Int {
        providerStore.conflictedProviderOutboxCount + providerStore.blockedProviderOutboxCount
    }

    private var retryableProviderOutboxCount: Int {
        max(0, providerStore.pendingProviderOutboxCount - providerAttentionCount)
    }

    private var filteredProviderAccounts: [CalendarProviderAccount] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return providerStore.accounts }

        return providerStore.accounts.filter { account in
            account.title.lowercased().contains(query)
                || account.kind.title.lowercased().contains(query)
                || account.endpointURLString.lowercased().contains(query)
                || (account.identityEmail?.lowercased().contains(query) ?? false)
                || account.identityEmailAliases.contains { $0.lowercased().contains(query) }
                || (account.username?.lowercased().contains(query) ?? false)
        }
    }

    private func importICS() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.icsContentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let summary = try model.importICSFile(at: url)
            if summary.eventsUpdated > 0 || summary.eventsSkipped > 0 {
                fileMessage = "Imported \(summary.eventsImported), updated \(summary.eventsUpdated), skipped \(summary.eventsSkipped)"
            } else {
                fileMessage = "Imported \(summary.eventsImported) events"
            }
        } catch {
            fileMessage = error.localizedDescription
        }
    }

    private func exportICS() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.icsContentType]
        panel.nameFieldStringValue = "Working Calendar.ics"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let text = model.localCalendarStore.exportICSText()
            try text.write(to: url, atomically: true, encoding: .utf8)
            fileMessage = "Exported \(model.localCalendarStore.events.count) events"
        } catch {
            fileMessage = error.localizedDescription
        }
    }

    private func presentPendingAddSourceIfNeeded() {
        guard let intent = pendingProviderSourceSetupIntent else { return }
        if case .addSource(let source) = intent {
            preferredAddSource = source
            isAddingSource = true
        }
        pendingProviderSourceSetupIntent = nil
    }
}

struct ProviderAccountSection: View {
    let accounts: [CalendarProviderAccount]
    let add: (ProviderDiagnosticSource?) -> Void
    let sync: (CalendarProviderAccount) -> Void
    let fullRefresh: (CalendarProviderAccount) -> Void
    let edit: (CalendarProviderAccount) -> Void
    let reconnect: (CalendarProviderAccount) -> Void
    let toggle: (CalendarProviderAccount) -> Void
    let delete: (CalendarProviderAccount) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 290, maximum: 380), spacing: 12, alignment: .topLeading)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AccountBadge(title: "Sources")

                VStack(alignment: .leading, spacing: 2) {
                    Text("External Sources")
                        .font(.headline)
                    Text("\(accounts.count) protocol sources")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    add(nil)
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 2)

            if accounts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "link")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 34, height: 34)
                            .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text("No provider sources yet")
                                .font(.callout.weight(.semibold))
                            Text("Add a direct protocol source; Working Calendar syncs these into its own local store.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            add(nil)
                        } label: {
                            Label("Add Source", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(ProviderDiagnosticSource.allCases, id: \.self) { source in
                            ProviderSourceShortcutButton(source: source) {
                                add(source)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.blue.opacity(0.16))
                )
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(accounts) { account in
                        ProviderAccountTile(
                            account: account,
                            sync: { sync(account) },
                            fullRefresh: { fullRefresh(account) },
                            edit: { edit(account) },
                            reconnect: { reconnect(account) },
                            toggle: { toggle(account) },
                            delete: { delete(account) }
                        )
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.blue.opacity(0.16))
                )
            }
        }
    }
}

struct ProviderSourceShortcutButton: View {
    let source: ProviderDiagnosticSource
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: source.symbolName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(source.onboardingActionTitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(source.onboardingSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(Color.white.opacity(0.46), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.14))
        )
        .help(source.onboardingSubtitle)
    }
}

struct ProviderAccountTile: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var providerStore: CalendarProviderStore
    let account: CalendarProviderAccount
    let sync: () -> Void
    let fullRefresh: () -> Void
    let edit: () -> Void
    let reconnect: () -> Void
    let toggle: () -> Void
    let delete: () -> Void

    private var isSyncing: Bool {
        model.syncingProviderIDs.contains(account.id)
    }

    private var pendingOutboxCount: Int {
        providerStore.providerOutboxCount(accountID: account.id)
    }

    private var conflictOutboxCount: Int {
        providerStore.providerOutboxConflictCount(accountID: account.id)
    }

    private var blockedOutboxCount: Int {
        providerStore.providerOutboxBlockedCount(accountID: account.id)
    }

    private var statusText: String {
        if conflictOutboxCount > 0 {
            return "\(conflictOutboxCount) remote conflict\(conflictOutboxCount == 1 ? "" : "s")"
        }

        if blockedOutboxCount > 0 {
            return "\(blockedOutboxCount) provider blocked update\(blockedOutboxCount == 1 ? "" : "s")"
        }

        if pendingOutboxCount > 0 {
            return "\(pendingOutboxCount) pending remote update\(pendingOutboxCount == 1 ? "" : "s")"
        }

        if let error = account.lastError, !error.isEmpty {
            return error
        }

        if let lastSyncAt = account.lastSyncAt {
            return "\(account.syncSummaryText) · \(lastSyncAt.formatted(date: .abbreviated, time: .shortened))"
        }

        return account.enabled ? "Ready to sync" : "Disabled"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    Image(systemName: account.kind.symbolName)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(tileAccent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(account.title)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)

                            Text(account.kind.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(tileAccent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(tileAccent.opacity(0.12), in: Capsule())
                        }

                        Text(sourceDetailText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(sourceHelpText)

                        HStack(spacing: 6) {
                            Text(account.capabilityText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(account.kind.supportsWriteBack ? Color.green : Color.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    (account.kind.supportsWriteBack ? Color.green : Color.secondary)
                                        .opacity(0.12),
                                    in: Capsule()
                                )

                            Text(statusText)
                                .font(.caption)
                                .foregroundStyle(statusColor)
                                .lineLimit(1)
                                .help(statusHelpText)

                            if let recoveryHint {
                                Text(recoveryHint.title)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.red.opacity(0.12), in: Capsule())
                                    .help(recoveryHint.help)
                            }

                            if let oauthHealth {
                                Text(oauthHealth.title)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(oauthHealth.color)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(oauthHealth.color.opacity(0.12), in: Capsule())
                                    .help(oauthHealth.help)
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    SwitchPill(isOn: account.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)

            VStack(spacing: 6) {
                Button(action: sync) {
                    Image(systemName: isSyncing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(!account.enabled || isSyncing)
                .help(isSyncing ? "Syncing" : "Sync source")

                Button(action: fullRefresh) {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .buttonStyle(.bordered)
                .disabled(!account.enabled || isSyncing)
                .help("Full refresh source")

                if account.kind == .icsSubscription || account.kind == .calDAV {
                    Button(action: edit) {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSyncing)
                    .help("Edit source")
                }

                if account.kind == .googleCalendar || account.kind == .microsoft365 {
                    Button(action: reconnect) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSyncing)
                    .help("Reconnect account")
                }

                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .help("Delete source")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(tileBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(account.enabled ? tileAccent.opacity(0.28) : Color.primary.opacity(0.06))
        )
        .opacity(account.enabled ? 1 : 0.68)
    }

    private var tileAccent: Color {
        if conflictOutboxCount > 0 || blockedOutboxCount > 0 || account.lastError != nil {
            return .red
        }
        if pendingOutboxCount > 0 {
            return .orange
        }
        return .blue
    }

    private var tileBackground: Color {
        account.enabled ? tileAccent.opacity(0.09) : Color.white.opacity(0.42)
    }

    private var statusHelpText: String {
        if blockedOutboxCount > 0 {
            return "The provider rejected a local update because of provider limits or permissions. The local event is still stored in Working Calendar; edit it or reconnect/check access before retrying."
        }

        if pendingOutboxCount > 0 {
            return "Remote changes are queued locally and will retry before inbound sync overwrites them."
        }

        if let error = account.lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return recoveryHint?.help ?? error
        }

        if account.lastSyncAt != nil {
            return "Last provider sync result for this source."
        }

        return account.enabled ? "This source is enabled and ready for the next sync." : "This source is disabled."
    }

    private var statusColor: Color {
        if conflictOutboxCount > 0 || blockedOutboxCount > 0 {
            return .red
        }
        if pendingOutboxCount > 0 {
            return .orange
        }
        return account.lastError == nil ? .secondary : .red
    }

    private var recoveryHint: ProviderRecoveryHint? {
        guard let error = account.lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
              !error.isEmpty
        else {
            return nil
        }

        let lowercased = error.lowercased()
        if lowercased.contains("401")
            || lowercased.contains("unauthorized")
            || lowercased.contains("access token")
            || lowercased.contains("refresh token")
            || lowercased.contains("credential")
            || lowercased.contains("keychain") {
            return ProviderRecoveryHint(
                title: account.kind == .calDAV ? "Check credentials" : "Reconnect",
                help: account.kind == .calDAV
                    ? "Check the username and app password for this CalDAV source."
                    : "Reconnect this OAuth source so Working Calendar can refresh provider access."
            )
        }

        if lowercased.contains("403") || lowercased.contains("read-only") || lowercased.contains("forbidden") {
            return ProviderRecoveryHint(
                title: "Check access",
                help: "The provider refused write or read access. Check calendar permissions for this account."
            )
        }

        if lowercased.contains("discover") || lowercased.contains("url") || lowercased.contains("404") {
            return ProviderRecoveryHint(
                title: "Check URL",
                help: "Check the server URL. For CalDAV, a provider root URL is usually enough because discovery is automatic."
            )
        }

        if lowercased.contains("changed remotely") || lowercased.contains("conflict") || lowercased.contains("412") {
            return ProviderRecoveryHint(
                title: "Sync first",
                help: "The event changed remotely. Run a source sync, then retry the pending update."
            )
        }

        return ProviderRecoveryHint(
            title: "Needs attention",
            help: error
        )
    }

    private var sourceDetailText: String {
        let endpoint = endpointTitle
        let identity = account.identityEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let username = account.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let aliasCount = account.identityEmailAliases.count
        let identityText = aliasCount > 0 ? "\(identity) +\(aliasCount) aliases" : identity

        switch account.kind {
        case .googleCalendar, .microsoft365:
            return identity.isEmpty ? endpoint : "\(identityText) · \(endpoint)"
        case .calDAV:
            return username.isEmpty ? endpoint : "\(username) · \(endpoint)"
        case .icsSubscription, .local:
            return account.endpointURLString
        }
    }

    private var sourceHelpText: String {
        let identity = account.identityEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let username = account.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let aliasText = account.identityEmailAliases.isEmpty ? "" : " aliases: \(account.identityEmailAliases.joined(separator: ", "))"
        let accountPart = identity.isEmpty ? username : "\(identity)\(aliasText)"
        return accountPart.isEmpty
            ? account.endpointURLString
            : "\(accountPart) · \(account.endpointURLString)"
    }

    private var endpointTitle: String {
        guard let host = account.endpointURL?.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            return account.endpointURLString
        }

        return host
    }

    private var oauthHealth: OAuthHealthBadge? {
        guard account.kind == .googleCalendar || account.kind == .microsoft365 else { return nil }
        guard let credential = model.oauthCredential(for: account) else {
            return OAuthHealthBadge(
                title: "Reconnect needed",
                color: .red,
                help: "Working Calendar cannot read this source's OAuth credential from Keychain."
            )
        }

        guard credential.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return OAuthHealthBadge(
                title: "Reconnect for refresh",
                color: .orange,
                help: "This source has no refresh token; reconnect it so sync can continue after the access token expires."
            )
        }

        if credential.shouldRefresh {
            return OAuthHealthBadge(
                title: "Refresh due",
                color: .orange,
                help: "The access token is near expiry; the next provider request will refresh it."
            )
        }

        return OAuthHealthBadge(
            title: "OAuth ready",
            color: .green,
            help: "OAuth refresh token is available for background sync."
        )
    }
}

private struct OAuthHealthBadge {
    let title: String
    let color: Color
    let help: String
}

private struct ProviderRecoveryHint {
    let title: String
    let help: String
}

struct ProviderOutboxSection: View {
    @EnvironmentObject private var model: AppModel
    let items: [ProviderOutboxItem]
    let accounts: [CalendarProviderAccount]
    let retryAll: () -> Void
    let retry: (ProviderOutboxItem) -> Void
    let discard: (ProviderOutboxItem) -> Void

    private var sortedItems: [ProviderOutboxItem] {
        items.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(sectionTitle, systemImage: sectionSymbolName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(sectionAccentColor)

                Spacer()

                Button(action: retryAll) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.isProviderOutboxProcessing)
                .help("Retry pending remote updates")
            }

            LazyVStack(spacing: 8) {
                ForEach(sortedItems) { item in
                    ProviderOutboxRow(
                        item: item,
                        accountTitle: accountTitle(for: item),
                        retry: { retry(item) },
                        discard: { discard(item) }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accountTitle(for item: ProviderOutboxItem) -> String {
        let accountTitles = item.accountIDs.compactMap { accountID in
            accounts.first(where: { $0.id == accountID })?.title
        }
        return accountTitles.isEmpty ? "Provider" : accountTitles.joined(separator: ", ")
    }

    private var conflictCount: Int {
        items.filter(\.isBlockedByConflict).count
    }

    private var blockedCount: Int {
        items.filter(\.isBlockedByProviderRejection).count
    }

    private var attentionCount: Int {
        conflictCount + blockedCount
    }

    private var sectionTitle: String {
        if conflictCount > 0 && conflictCount == items.count {
            return "\(conflictCount) Remote Conflict\(conflictCount == 1 ? "" : "s")"
        }
        if blockedCount > 0 && blockedCount == items.count {
            return "\(blockedCount) Provider Blocked Update\(blockedCount == 1 ? "" : "s")"
        }
        if attentionCount > 0 {
            return "\(attentionCount) Need Attention · \(items.count) Pending Remote Update\(items.count == 1 ? "" : "s")"
        }
        return "\(items.count) Pending Remote Update\(items.count == 1 ? "" : "s")"
    }

    private var sectionSymbolName: String {
        attentionCount > 0 ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath"
    }

    private var sectionAccentColor: Color {
        attentionCount > 0 ? .red : .orange
    }
}

struct ProviderOutboxRow: View {
    @EnvironmentObject private var model: AppModel
    let item: ProviderOutboxItem
    let accountTitle: String
    let retry: () -> Void
    let discard: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.headline)
                .foregroundStyle(accentColor)
                .frame(width: 30, height: 30)
                .background(accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(item.eventTitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)

                    Text(item.operation.title.capitalized)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(accentColor.opacity(0.12), in: Capsule())
                }

                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(detailColor)
                    .lineLimit(1)

                Text(item.recoverySummaryText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(recoveryColor)
                    .lineLimit(1)
                    .help(item.recoveryHelpText)
            }

            Spacer(minLength: 8)

            Text(accountTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .trailing)

            Button(action: retry) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(model.isProviderOutboxProcessing)
            .help(retryHelpText)

            Button(role: .destructive, action: discard) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(model.isProviderOutboxProcessing)
            .help("Discard pending update")
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }

    private var detailText: String {
        var parts = [item.statusText]
        if item.attemptCount > 0 {
            parts.append("\(item.attemptCount) attempt\(item.attemptCount == 1 ? "" : "s")")
        }
        if let nextRetryAt = item.nextRetryAt {
            parts.append("Retry \(nextRetryAt.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private var symbolName: String {
        if item.isBlockedByConflict {
            return "exclamationmark.triangle.fill"
        }
        if item.isBlockedByProviderRejection {
            return "exclamationmark.octagon.fill"
        }
        return item.operation.symbolName
    }

    private var accentColor: Color {
        (item.isBlockedByConflict || item.isBlockedByProviderRejection) ? .red : item.operation.accentColor
    }

    private var detailColor: Color {
        if item.isBlockedByConflict || item.isBlockedByProviderRejection { return .red }
        return item.lastError == nil ? .secondary : .red
    }

    private var retryHelpText: String {
        item.recoveryHelpText
    }

    private var recoveryColor: Color {
        if item.isBlockedByConflict || item.isBlockedByProviderRejection {
            return .red
        }
        if item.nextRetryAt != nil || item.attemptCount > 0 {
            return .orange
        }
        return .secondary
    }
}

private extension ProviderOutboxOperation {
    var symbolName: String {
        switch self {
        case .write: return "square.and.arrow.up"
        case .delete: return "trash"
        case .move: return "arrow.left.arrow.right"
        case .response: return "checkmark.message"
        }
    }

    var accentColor: Color {
        switch self {
        case .write: return .blue
        case .delete: return .red
        case .move: return .orange
        case .response: return .green
        }
    }
}

struct ProviderHintRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 70, alignment: .trailing)
                .padding(.top, 1)

            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}

struct ProviderSourceEditorView: View {
    private enum SourceKind: String, CaseIterable, Identifiable {
        case ics
        case calDAV
        case google
        case microsoft365

        var id: String { rawValue }

        var title: String {
            switch self {
            case .ics: return "ICS"
            case .calDAV: return "CalDAV"
            case .google: return "Google"
            case .microsoft365: return "Microsoft 365"
            }
        }

        var oauthService: OAuthServiceKind? {
            switch self {
            case .google:
                return .googleCalendar
            case .microsoft365:
                return .microsoft365
            case .ics, .calDAV:
                return nil
            }
        }

        init(preferredSource: ProviderDiagnosticSource?) {
            switch preferredSource {
            case .icsSubscription:
                self = .ics
            case .calDAV:
                self = .calDAV
            case .googleCalendar:
                self = .google
            case .microsoft365:
                self = .microsoft365
            case nil:
                self = .ics
            }
        }
    }

    @State private var sourceKind: SourceKind = .ics
    @State private var calDAVPreset: ProviderCalDAVPreset = .generic
    @State private var title = ""
    @State private var urlString = ""
    @State private var username = ""
    @State private var password = ""
    @State private var oauthClientID = ""
    @State private var oauthClientSecret = ""
    @State private var oauthTenant = "common"
    @State private var oauthAuthorization: OAuthDeviceAuthorization?
    @State private var oauthBrowserURL: URL?
    @State private var oauthMessage: String?
    @State private var oauthImportMessage: String?
    @State private var isAuthorizing = false
    @State private var sourceMessage: String?
    @State private var isSaving = false
    let saveICS: (String, String) async -> String?
    let saveCalDAV: (String, String, String, String) async -> String?
    let saveGoogle: (String, OAuthCredential) async -> String?
    let saveMicrosoft365: (String, OAuthCredential) async -> String?
    let cancel: () -> Void

    init(
        preferredSource: ProviderDiagnosticSource? = nil,
        saveICS: @escaping (String, String) async -> String?,
        saveCalDAV: @escaping (String, String, String, String) async -> String?,
        saveGoogle: @escaping (String, OAuthCredential) async -> String?,
        saveMicrosoft365: @escaping (String, OAuthCredential) async -> String?,
        cancel: @escaping () -> Void
    ) {
        let initialSourceKind = SourceKind(preferredSource: preferredSource)
        _sourceKind = State(initialValue: initialSourceKind)
        _oauthClientID = State(initialValue: initialSourceKind.oauthService?.defaultClientID ?? "")
        self.saveICS = saveICS
        self.saveCalDAV = saveCalDAV
        self.saveGoogle = saveGoogle
        self.saveMicrosoft365 = saveMicrosoft365
        self.cancel = cancel
    }

    private var canSave: Bool {
        let hasURL = !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch sourceKind {
        case .ics:
            return hasURL && sourceURLValidationMessage == nil
        case .calDAV:
            return hasURL
                && sourceURLValidationMessage == nil
                && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !password.isEmpty
        case .google:
            return !effectiveOAuthClientID.isEmpty
                && oauthClientIDValidationMessage == nil
        case .microsoft365:
            return !effectiveOAuthClientID.isEmpty
                && oauthClientIDValidationMessage == nil
                && !oauthTenant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var oauthClientIDValidationMessage: String? {
        guard let oauthService = sourceKind.oauthService else { return nil }
        return oauthService.clientIDValidationMessage(for: effectiveOAuthClientID)
    }

    private var effectiveOAuthClientID: String {
        let typedClientID = oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedClientID.isEmpty {
            return typedClientID
        }
        return sourceKind.oauthService?.defaultClientID ?? ""
    }

    private var sourceURLValidationMessage: String? {
        switch sourceKind {
        case .ics:
            return ProviderSourceURLValidator.validationMessage(kind: .icsSubscription, urlString: urlString)
        case .calDAV:
            return ProviderSourceURLValidator.validationMessage(kind: .calDAV, urlString: urlString)
        case .google, .microsoft365:
            return nil
        }
    }

    private var actionTitle: String {
        if isSaving { return "Adding" }
        if isAuthorizing { return "Waiting" }
        switch sourceKind {
        case .google, .microsoft365:
            return "Connect"
        case .ics, .calDAV:
            return "Add"
        }
    }

    private var namePlaceholder: String {
        switch sourceKind {
        case .ics: return "Team calendar"
        case .calDAV: return calDAVPreset.titlePlaceholder
        case .google: return "Work Google"
        case .microsoft365: return "Work Microsoft 365"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Add Source")
                    .font(.title2.bold())
                Spacer()
                Button("Cancel", action: cancel)
                Button(actionTitle) {
                    switch sourceKind {
                    case .ics, .calDAV:
                        Task { await saveCurrentSource() }
                    case .google:
                        Task { await connectOAuth(service: .googleCalendar) }
                    case .microsoft365:
                        Task { await connectOAuth(service: .microsoft365) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || isAuthorizing || isSaving)
            }

            VStack(alignment: .leading, spacing: 14) {
                LocalCalendarEditorRow(label: "Type") {
                    Picker("Source type", selection: $sourceKind) {
                        ForEach(SourceKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                LocalCalendarEditorRow(label: "Name") {
                    TextField(namePlaceholder, text: $title)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                if sourceKind == .ics || sourceKind == .calDAV {
                    if sourceKind == .calDAV {
                        LocalCalendarEditorRow(label: "Provider") {
                            Picker("CalDAV provider", selection: $calDAVPreset) {
                                ForEach(ProviderCalDAVPreset.allCases) { preset in
                                    Text(preset.title).tag(preset)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }

                    LocalCalendarEditorRow(label: "URL") {
                        HStack(spacing: 8) {
                            TextField(sourceKind == .ics ? "https://example.com/calendar.ics" : calDAVPreset.urlPlaceholder, text: $urlString)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .help(sourceKind == .calDAV ? "A server root URL is fine; Working Calendar also tries /.well-known/caldav and common CalDAV entrypoints." : "Paste an ICS or webcal subscription URL.")

                            if sourceKind == .calDAV && calDAVPreset.hasSuggestedURL {
                                Button {
                                    urlString = calDAVPreset.defaultURLString
                                } label: {
                                    Label("Use URL", systemImage: "arrow.turn.down.left")
                                }
                                .buttonStyle(.bordered)
                                .help("Use \(calDAVPreset.defaultURLString)")
                            }
                        }
                    }

                    if let sourceURLValidationMessage {
                        ProviderHintRow(text: sourceURLValidationMessage)
                    }
                }

                if sourceKind == .calDAV {
                    ProviderHintRow(text: calDAVPreset.guidanceText)

                    LocalCalendarEditorRow(label: "Username") {
                        TextField(calDAVPreset.usernamePlaceholder, text: $username)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }

                    LocalCalendarEditorRow(label: "Password") {
                        SecureField(calDAVPreset.passwordPlaceholder, text: $password)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }

                if let oauthService = sourceKind.oauthService {
                    ProviderHintRow(text: oauthService.onboardingGuidanceText)

                    if oauthService == .googleCalendar {
                        LocalCalendarEditorRow(label: "OAuth JSON") {
                            HStack(spacing: 10) {
                                Button {
                                    importGoogleOAuthClientJSON()
                                } label: {
                                    Label("Import Desktop JSON", systemImage: "doc.badge.gearshape")
                                }
                                .buttonStyle(.bordered)
                                .help("Import the downloaded Google Desktop OAuth JSON and fill client_id/client_secret locally.")

                                if let oauthImportMessage {
                                    Text(oauthImportMessage)
                                        .font(.caption)
                                        .foregroundStyle(Color.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }

                    LocalCalendarEditorRow(label: "Client ID") {
                        TextField(oauthService.clientIDPlaceholder, text: $oauthClientID)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .help(oauthService.onboardingGuidanceText)
                    }

                    if oauthService.usesClientSecret {
                        LocalCalendarEditorRow(label: "Client Secret") {
                            SecureField(oauthService.clientSecretPlaceholder, text: $oauthClientSecret)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .help(oauthService.clientSecretGuidanceText)
                        }

                        ProviderHintRow(text: oauthService.clientSecretGuidanceText)
                    }

                    if let oauthClientIDValidationMessage {
                        ProviderHintRow(text: oauthClientIDValidationMessage)
                    }

                    if oauthService.usesTenant {
                        LocalCalendarEditorRow(label: "Tenant") {
                            TextField(oauthService.tenantPlaceholder, text: $oauthTenant)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .help(oauthService.tenantGuidanceText)
                        }
                        ProviderHintRow(text: oauthService.tenantGuidanceText)
                    }

                    if let oauthAuthorization {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Text(oauthAuthorization.userCode)
                                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                Button {
                                    NSWorkspace.shared.open(oauthAuthorization.verificationURLComplete ?? oauthAuthorization.verificationURL)
                                } label: {
                                    Label("Open", systemImage: "safari")
                                }
                            }

                            Text(oauthAuthorization.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 4)
                    }

                    if let oauthBrowserURL, oauthAuthorization == nil {
                        HStack(spacing: 10) {
                            Button {
                                NSWorkspace.shared.open(oauthBrowserURL)
                            } label: {
                                Label("Open Browser", systemImage: "safari")
                            }
                            .buttonStyle(.bordered)

                            Text("Complete Google sign-in in the browser, then return here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }

                    if let oauthMessage {
                        Text(oauthMessage)
                            .font(.caption)
                            .foregroundStyle(isAuthorizing ? Color.secondary : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let sourceMessage {
                    Text(sourceMessage)
                        .font(.caption)
                        .foregroundStyle(isSaving ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(24)
        .frame(width: 580)
        .onChange(of: sourceKind) { oldKind, newKind in
            oauthAuthorization = nil
            oauthBrowserURL = nil
            oauthMessage = nil
            oauthImportMessage = nil
            sourceMessage = nil
            isAuthorizing = false
            isSaving = false
            applyDefaultOAuthClientID(oldService: oldKind.oauthService, newService: newKind.oauthService)
            if newKind.oauthService?.usesClientSecret != true {
                oauthClientSecret = ""
            }
            if newKind == .calDAV {
                applyCalDAVPreset(oldPreset: .generic, newPreset: calDAVPreset)
            }
        }
        .onChange(of: calDAVPreset) { oldPreset, newPreset in
            applyCalDAVPreset(oldPreset: oldPreset, newPreset: newPreset)
        }
    }

    private func applyCalDAVPreset(oldPreset: ProviderCalDAVPreset, newPreset: ProviderCalDAVPreset) {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousDefault = oldPreset.defaultURLString
        let shouldReplaceURL = trimmedURL.isEmpty || (!previousDefault.isEmpty && trimmedURL == previousDefault)

        if shouldReplaceURL {
            urlString = newPreset.defaultURLString
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty || trimmedTitle == oldPreset.titlePlaceholder {
            title = newPreset == .generic ? "" : newPreset.titlePlaceholder
        }
    }

    private func applyDefaultOAuthClientID(oldService: OAuthServiceKind?, newService: OAuthServiceKind?) {
        let trimmedClientID = oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldDefaultClientID = oldService?.defaultClientID ?? ""
        if trimmedClientID.isEmpty || (!oldDefaultClientID.isEmpty && trimmedClientID == oldDefaultClientID) {
            oauthClientID = newService?.defaultClientID ?? ""
        }
    }

    private func importGoogleOAuthClientJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose the downloaded Google Desktop OAuth JSON."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let configuration = try GoogleOAuthClientConfiguration.load(from: url)
            oauthClientID = configuration.clientID
            oauthClientSecret = configuration.clientSecret ?? ""
            oauthImportMessage = configuration.clientSecret == nil
                ? "Imported client_id. No client_secret was present in this Desktop JSON."
                : "Imported Desktop OAuth client_id and client_secret."
            oauthMessage = nil
        } catch {
            oauthImportMessage = error.localizedDescription
        }
    }

    private func saveCurrentSource() async {
        isSaving = true
        sourceMessage = "Adding source..."

        let error: String?
        switch sourceKind {
        case .ics:
            error = await saveICS(title, urlString)
        case .calDAV:
            error = await saveCalDAV(title, urlString, username, password)
        case .google, .microsoft365:
            error = nil
        }

        if let error {
            sourceMessage = error
            isSaving = false
        }
    }

    private func connectOAuth(service: OAuthServiceKind) async {
        let clientID = effectiveOAuthClientID
        let tenant = service == .microsoft365
            ? oauthTenant.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let clientSecret = service.usesClientSecret
            ? normalizedOptional(oauthClientSecret)
            : nil

        isAuthorizing = true
        oauthAuthorization = nil
        oauthBrowserURL = nil
        oauthMessage = "Requesting sign-in code..."

        do {
            let client = OAuthDeviceFlowClient()
            if service == .googleCalendar {
                oauthMessage = "Opening Google sign-in in the browser..."
                let authorization = try await client.requestLoopbackAuthorization(service: service, clientID: clientID)
                oauthBrowserURL = authorization.authorizationURL
                NSWorkspace.shared.open(authorization.authorizationURL)

                let credential = try await client.token(authorization: authorization, clientSecret: clientSecret)
                oauthMessage = "Connected. Syncing calendars..."

                if let error = await saveGoogle(title, credential) {
                    oauthMessage = error
                    isAuthorizing = false
                }
                return
            }

            let authorization = try await client.requestAuthorization(
                service: service,
                clientID: clientID,
                tenant: tenant
            )
            oauthAuthorization = authorization
            oauthMessage = "Waiting for confirmation in the browser..."
            NSWorkspace.shared.open(authorization.verificationURLComplete ?? authorization.verificationURL)

            let credential = try await client.pollForToken(authorization: authorization)
            oauthMessage = "Connected. Syncing calendars..."

            switch service {
            case .googleCalendar:
                if let error = await saveGoogle(title, credential) {
                    oauthMessage = error
                    isAuthorizing = false
                }
            case .microsoft365:
                if let error = await saveMicrosoft365(title, credential) {
                    oauthMessage = error
                    isAuthorizing = false
                }
            }
        } catch {
            oauthMessage = error.localizedDescription
            isAuthorizing = false
        }
    }

    private func normalizedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ProviderSourceEditView: View {
    let account: CalendarProviderAccount
    let saveICS: (String, String) async -> String?
    let saveCalDAV: (String, String, String, String) async -> String?
    let cancel: () -> Void

    @State private var title: String
    @State private var urlString: String
    @State private var username: String
    @State private var password = ""
    @State private var sourceMessage: String?
    @State private var isSaving = false

    init(
        account: CalendarProviderAccount,
        saveICS: @escaping (String, String) async -> String?,
        saveCalDAV: @escaping (String, String, String, String) async -> String?,
        cancel: @escaping () -> Void
    ) {
        self.account = account
        self.saveICS = saveICS
        self.saveCalDAV = saveCalDAV
        self.cancel = cancel
        _title = State(initialValue: account.title)
        _urlString = State(initialValue: account.endpointURLString)
        _username = State(initialValue: account.username ?? "")
    }

    private var canSave: Bool {
        guard !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard sourceURLValidationMessage == nil else { return false }
        if account.kind == .calDAV {
            return !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return account.kind == .icsSubscription
    }

    private var sourceURLValidationMessage: String? {
        ProviderSourceURLValidator.validationMessage(kind: account.kind, urlString: urlString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Edit Source")
                    .font(.title2.bold())
                Spacer()
                Button("Cancel", action: cancel)
                Button(isSaving ? "Saving" : "Save") {
                    Task { await saveCurrentSource() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || isSaving)
            }

            VStack(alignment: .leading, spacing: 14) {
                LocalCalendarEditorRow(label: "Source") {
                    HStack(spacing: 8) {
                        Image(systemName: account.kind.symbolName)
                            .foregroundStyle(.secondary)
                        Text(account.kind.title)
                            .font(.callout.weight(.semibold))
                        Text(account.capabilityText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LocalCalendarEditorRow(label: "Name") {
                    TextField(account.kind == .calDAV ? "Work CalDAV" : "Team calendar", text: $title)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                LocalCalendarEditorRow(label: "URL") {
                    TextField(
                        account.kind == .calDAV ? "https://caldav.example.com/" : "https://example.com/calendar.ics",
                        text: $urlString
                    )
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                if let sourceURLValidationMessage {
                    ProviderHintRow(text: sourceURLValidationMessage)
                }

                if account.kind == .calDAV {
                    ProviderHintRow(text: "Leave the password blank to keep the existing CalDAV credential. Saving runs a full refresh with the updated account settings.")

                    LocalCalendarEditorRow(label: "Username") {
                        TextField("name@example.com", text: $username)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }

                    LocalCalendarEditorRow(label: "Password") {
                        SecureField("New app password", text: $password)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                } else {
                    ProviderHintRow(text: "Saving keeps the source identity and refreshes this ICS/webcal subscription from the new URL.")
                }

                if let sourceMessage {
                    Text(sourceMessage)
                        .font(.caption)
                        .foregroundStyle(isSaving ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(24)
        .frame(width: 580)
    }

    private func saveCurrentSource() async {
        isSaving = true
        sourceMessage = "Saving source..."

        let error: String?
        switch account.kind {
        case .icsSubscription:
            error = await saveICS(title, urlString)
        case .calDAV:
            error = await saveCalDAV(title, urlString, username, password)
        case .local, .googleCalendar, .microsoft365:
            error = "This source type cannot be edited here."
        }

        if let error {
            sourceMessage = error
            isSaving = false
        }
    }
}

struct ProviderReconnectView: View {
    let account: CalendarProviderAccount
    let existingCredential: OAuthCredential?
    let save: (OAuthCredential) async -> String?
    let cancel: () -> Void

    @State private var oauthClientID: String
    @State private var oauthClientSecret: String
    @State private var oauthTenant: String
    @State private var oauthAuthorization: OAuthDeviceAuthorization?
    @State private var oauthBrowserURL: URL?
    @State private var oauthMessage: String?
    @State private var oauthImportMessage: String?
    @State private var isAuthorizing = false

    init(
        account: CalendarProviderAccount,
        existingCredential: OAuthCredential?,
        save: @escaping (OAuthCredential) async -> String?,
        cancel: @escaping () -> Void
    ) {
        self.account = account
        self.existingCredential = existingCredential
        self.save = save
        self.cancel = cancel
        let fallbackService: OAuthServiceKind?
        switch account.kind {
        case .googleCalendar:
            fallbackService = .googleCalendar
        case .microsoft365:
            fallbackService = .microsoft365
        case .local, .icsSubscription, .calDAV:
            fallbackService = nil
        }
        let storedClientID = existingCredential?.clientID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _oauthClientID = State(initialValue: storedClientID.isEmpty ? fallbackService?.defaultClientID ?? "" : storedClientID)
        _oauthClientSecret = State(initialValue: existingCredential?.clientSecret ?? "")
        _oauthTenant = State(initialValue: existingCredential?.tenant?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? existingCredential?.tenant ?? "common"
            : "common")
    }

    private var service: OAuthServiceKind? {
        switch account.kind {
        case .googleCalendar:
            return .googleCalendar
        case .microsoft365:
            return .microsoft365
        case .local, .icsSubscription, .calDAV:
            return nil
        }
    }

    private var canConnect: Bool {
        guard let service else { return false }
        if effectiveOAuthClientID.isEmpty { return false }
        if oauthClientIDValidationMessage != nil { return false }
        if service.usesTenant && oauthTenant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return true
    }

    private var oauthClientIDValidationMessage: String? {
        guard let service else { return nil }
        return service.clientIDValidationMessage(for: effectiveOAuthClientID)
    }

    private var effectiveOAuthClientID: String {
        let typedClientID = oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedClientID.isEmpty {
            return typedClientID
        }
        return service?.defaultClientID ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Reconnect")
                    .font(.title2.bold())
                Spacer()
                Button("Cancel", action: cancel)
                Button(isAuthorizing ? "Waiting" : "Connect") {
                    Task { await connectOAuth() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canConnect || isAuthorizing)
            }

            VStack(alignment: .leading, spacing: 14) {
                LocalCalendarEditorRow(label: "Source") {
                    HStack(spacing: 8) {
                        Image(systemName: account.kind.symbolName)
                            .foregroundStyle(.secondary)
                        Text(account.title)
                            .font(.callout.weight(.semibold))
                        Text(account.kind.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let onboardingGuidanceText = service?.onboardingGuidanceText {
                    ProviderHintRow(text: onboardingGuidanceText)
                }

                if service == .googleCalendar {
                    LocalCalendarEditorRow(label: "OAuth JSON") {
                        HStack(spacing: 10) {
                            Button {
                                importGoogleOAuthClientJSON()
                            } label: {
                                Label("Import Desktop JSON", systemImage: "doc.badge.gearshape")
                            }
                            .buttonStyle(.bordered)
                            .help("Import the downloaded Google Desktop OAuth JSON and fill client_id/client_secret locally.")

                            if let oauthImportMessage {
                                Text(oauthImportMessage)
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }

                LocalCalendarEditorRow(label: "Client ID") {
                    TextField(service?.clientIDPlaceholder ?? "OAuth client ID", text: $oauthClientID)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .help(service?.onboardingGuidanceText ?? "Enter the OAuth client ID for this source.")
                }

                if let oauthClientIDValidationMessage {
                    ProviderHintRow(text: oauthClientIDValidationMessage)
                }

                if service?.usesClientSecret == true {
                    LocalCalendarEditorRow(label: "Client Secret") {
                        SecureField(service?.clientSecretPlaceholder ?? "Optional client_secret", text: $oauthClientSecret)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .help(service?.clientSecretGuidanceText ?? "Enter a client_secret only if the OAuth provider requires it.")
                    }

                    if let clientSecretGuidanceText = service?.clientSecretGuidanceText, !clientSecretGuidanceText.isEmpty {
                        ProviderHintRow(text: clientSecretGuidanceText)
                    }
                }

                if service?.usesTenant == true {
                    LocalCalendarEditorRow(label: "Tenant") {
                        TextField(service?.tenantPlaceholder ?? "common", text: $oauthTenant)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .help(service?.tenantGuidanceText ?? "Enter the Microsoft tenant.")
                    }

                    if let tenantGuidanceText = service?.tenantGuidanceText, !tenantGuidanceText.isEmpty {
                        ProviderHintRow(text: tenantGuidanceText)
                    }
                }

                if let oauthAuthorization {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Text(oauthAuthorization.userCode)
                                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Button {
                                NSWorkspace.shared.open(oauthAuthorization.verificationURLComplete ?? oauthAuthorization.verificationURL)
                            } label: {
                                Label("Open", systemImage: "safari")
                            }
                        }

                        Text(oauthAuthorization.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                }

                if let oauthBrowserURL, oauthAuthorization == nil {
                    HStack(spacing: 10) {
                        Button {
                            NSWorkspace.shared.open(oauthBrowserURL)
                        } label: {
                            Label("Open Browser", systemImage: "safari")
                        }
                        .buttonStyle(.bordered)

                        Text("Complete Google sign-in in the browser, then return here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }

                if let oauthMessage {
                    Text(oauthMessage)
                        .font(.caption)
                        .foregroundStyle(isAuthorizing ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(24)
        .frame(width: 580)
    }

    private func connectOAuth() async {
        guard let service else { return }

        isAuthorizing = true
        oauthAuthorization = nil
        oauthBrowserURL = nil
        oauthMessage = "Requesting sign-in code..."
        let clientSecret = service.usesClientSecret
            ? normalizedOptional(oauthClientSecret)
            : nil

        do {
            let client = OAuthDeviceFlowClient()
            if service == .googleCalendar {
                oauthMessage = "Opening Google sign-in in the browser..."
                let authorization = try await client.requestLoopbackAuthorization(
                    service: service,
                    clientID: effectiveOAuthClientID
                )
                oauthBrowserURL = authorization.authorizationURL
                NSWorkspace.shared.open(authorization.authorizationURL)

                let credential = try await client.token(authorization: authorization, clientSecret: clientSecret)
                oauthMessage = "Connected. Syncing calendars..."
                if let error = await save(credential) {
                    oauthMessage = error
                    isAuthorizing = false
                }
                return
            }

            let authorization = try await client.requestAuthorization(
                service: service,
                clientID: effectiveOAuthClientID,
                tenant: service == .microsoft365 ? oauthTenant.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            )
            oauthAuthorization = authorization
            oauthMessage = "Waiting for confirmation in the browser..."
            NSWorkspace.shared.open(authorization.verificationURLComplete ?? authorization.verificationURL)

            let credential = try await client.pollForToken(authorization: authorization)
            oauthMessage = "Connected. Syncing calendars..."
            if let error = await save(credential) {
                oauthMessage = error
                isAuthorizing = false
            }
        } catch {
            oauthMessage = error.localizedDescription
            isAuthorizing = false
        }
    }

    private func importGoogleOAuthClientJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose the downloaded Google Desktop OAuth JSON."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let configuration = try GoogleOAuthClientConfiguration.load(from: url)
            oauthClientID = configuration.clientID
            oauthClientSecret = configuration.clientSecret ?? ""
            oauthImportMessage = configuration.clientSecret == nil
                ? "Imported client_id. No client_secret was present in this Desktop JSON."
                : "Imported Desktop OAuth client_id and client_secret."
            oauthMessage = nil
        } catch {
            oauthImportMessage = error.localizedDescription
        }
    }

    private func normalizedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct LocalCalendarAccountSection: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let subtitle: String
    let badgeTitle: String
    let accentColor: Color
    let calendars: [LocalCalendar]
    let edit: (LocalCalendar) -> Void
    let delete: (LocalCalendar) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 12, alignment: .topLeading)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AccountBadge(title: badgeTitle)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(calendars.isEmpty ? "None" : "\(calendars.count)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(accentColor.opacity(0.12), in: Capsule())
            }
            .padding(.horizontal, 2)

            if calendars.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "calendar")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(accentColor)
                        .frame(width: 34, height: 34)
                        .background(accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("No calendars here")
                            .font(.callout.weight(.semibold))
                        Text("Change the search or add a local calendar/source.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(accentColor.opacity(0.18))
                )
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(calendars) { calendar in
                        LocalCalendarTile(calendar: calendar, edit: {
                            edit(calendar)
                        }, delete: {
                            delete(calendar)
                        })
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(accentColor.opacity(0.18))
                )
            }
        }
    }
}

struct LocalCalendarTile: View {
    @EnvironmentObject private var model: AppModel
    let calendar: LocalCalendar
    let edit: () -> Void
    let delete: () -> Void

    private var isEnabled: Bool {
        model.localCalendarStore.selectedCalendarIDs.contains(calendar.id)
    }

    private var eventCount: Int {
        model.localCalendarStore.events.filter { $0.calendarID == calendar.id }.count
    }

    private var backendInfo: CalendarBackendInfo {
        model.backendInfo(for: calendar)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.localCalendarStore.setCalendar(calendar, enabled: !isEnabled)
            } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: calendar.color))
                        .frame(width: 8, height: 42)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(calendar.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text("\(eventCount) events · \(backendInfo.storageText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if let syncStatusText {
                            Text(syncStatusText)
                                .font(.caption2)
                                .foregroundStyle(backendInfo.lastError == nil ? Color.secondary : Color.red)
                                .lineLimit(1)
                        }

                        HStack(spacing: 6) {
                            Text(backendInfo.capabilityText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(backendInfo.allowsEventWrite ? Color.green : Color.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background((backendInfo.allowsEventWrite ? Color.green : Color.secondary).opacity(0.12), in: Capsule())

                            if backendInfo.isProviderBacked {
                                Text(backendInfo.sourceKindTitle)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.blue)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.blue.opacity(0.12), in: Capsule())
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    SwitchPill(isOn: isEnabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)

            VStack(spacing: 6) {
                Button(action: edit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.bordered)
                .disabled(backendInfo.isProviderBacked)
                .help(backendInfo.isProviderBacked ? "Provider calendars are managed by their source" : "Edit local calendar")

                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(model.localCalendarStore.calendars.count <= 1 || backendInfo.isProviderBacked)
                .help(deleteHelpText)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .background(tileBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .opacity(isEnabled ? 1 : 0.68)
    }

    private var tileBackground: Color {
        isEnabled ? Color(nsColor: calendar.color).opacity(0.11) : Color.white.opacity(0.42)
    }

    private var borderColor: Color {
        isEnabled ? Color(nsColor: calendar.color).opacity(0.35) : Color.primary.opacity(0.06)
    }

    private var syncStatusText: String? {
        guard backendInfo.isProviderBacked else { return nil }
        if let error = backendInfo.lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return error
        }
        if let lastSyncAt = backendInfo.lastSyncAt {
            return "Synced \(lastSyncAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return backendInfo.isSourceEnabled ? "Not synced yet" : "Source disabled"
    }

    private var deleteHelpText: String {
        if backendInfo.isProviderBacked {
            return "Delete the source account to remove provider calendars"
        }
        if model.localCalendarStore.calendars.count <= 1 {
            return "Keep at least one local calendar"
        }
        return "Delete local calendar"
    }
}

struct LocalCalendarEditorView: View {
    @State private var draft: LocalCalendarDraft
    let save: (LocalCalendarDraft) -> Void
    let cancel: () -> Void

    private let colorChoices = ["#15A6C8", "#3B82F6", "#8B5CF6", "#22C55E", "#F59E0B", "#EF4444", "#EC4899"]

    init(draft: LocalCalendarDraft, save: @escaping (LocalCalendarDraft) -> Void, cancel: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(draft.calendarID == nil ? "New Local Calendar" : "Edit Local Calendar")
                    .font(.title2.bold())
                Spacer()
                Button("Cancel", action: cancel)
                Button("Save") {
                    save(draft)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            VStack(alignment: .leading, spacing: 14) {
                LocalCalendarEditorRow(label: "Name") {
                    TextField("Calendar name", text: $draft.title)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Color")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        ForEach(colorChoices, id: \.self) { colorHex in
                            Button {
                                draft.colorHex = colorHex
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color(hexString: colorHex))
                                        .frame(width: 26, height: 26)

                                    if draft.colorHex.caseInsensitiveCompare(colorHex) == .orderedSame {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .help(colorHex)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct LocalCalendarEditorRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)

            content

            Spacer(minLength: 0)
        }
    }
}

private extension Color {
    init(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        guard value.count == 6, let intValue = Int(value, radix: 16) else {
            self = .teal
            return
        }

        self = Color(
            red: Double((intValue >> 16) & 0xff) / 255,
            green: Double((intValue >> 8) & 0xff) / 255,
            blue: Double(intValue & 0xff) / 255
        )
    }
}

struct AccountBadge: View {
    let title: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
                .frame(width: 36, height: 36)
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var iconName: String {
        let lowercased = title.lowercased()
        if lowercased.contains("icloud") { return "icloud" }
        if lowercased.contains("google") { return "g.circle" }
        if lowercased.contains("@") { return "at" }
        if lowercased.contains("subscribed") { return "calendar.badge.plus" }
        return "person.crop.circle"
    }
}

struct SwitchPill: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.22))
            Circle()
                .fill(Color.white)
                .padding(3)
                .shadow(color: .black.opacity(0.16), radius: 2, x: 0, y: 1)
        }
        .frame(width: 42, height: 24)
    }
}
