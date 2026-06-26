import SwiftUI

enum WorkspaceSettingsPanel: String, Identifiable {
    case calendars
    case rules
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendars: return "Calendars"
        case .rules: return "Rules"
        case .settings: return "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .calendars: return "calendar"
        case .rules: return "bell.badge"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var presentedPanel: WorkspaceSettingsPanel?
    @State private var pendingProviderSourceSetupIntent: ProviderSourceSetupIntent?

    var body: some View {
        ZStack {
            AppBackground()

            HStack(spacing: 0) {
                WorkspaceAgendaRail()
                    .frame(width: 360)

                WorkspaceSplitDivider()

                CalendarGridView(
                    openCalendars: { presentedPanel = .calendars },
                    openRules: { presentedPanel = .rules },
                    openSettings: { presentedPanel = .settings }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1180, minHeight: 720)
        .onOpenURL { url in
            Task { await model.handleExternalCalendarURL(url) }
        }
        .sheet(item: $presentedPanel) { panel in
            WorkspaceSettingsSheet(
                panel: panel,
                pendingProviderSourceSetupIntent: $pendingProviderSourceSetupIntent,
                openPanel: { presentedPanel = $0 }
            )
        }
    }
}

struct WorkspaceSplitDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.8))
            .frame(width: 1)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.white.opacity(0.32))
                    .frame(width: 1)
                    .offset(x: 1)
            }
            .ignoresSafeArea(edges: .vertical)
    }
}

struct WorkspaceSettingsSheet: View {
    let panel: WorkspaceSettingsPanel
    @Binding var pendingProviderSourceSetupIntent: ProviderSourceSetupIntent?
    let openPanel: (WorkspaceSettingsPanel) -> Void

    var body: some View {
        switch panel {
        case .calendars:
            CalendarsView(pendingProviderSourceSetupIntent: $pendingProviderSourceSetupIntent)
                .frame(minWidth: 980, minHeight: 700)
        case .rules:
            RulesView()
                .frame(minWidth: 980, minHeight: 700)
        case .settings:
            SettingsView { intent in
                pendingProviderSourceSetupIntent = intent.shouldPresentAddSource ? intent : nil
                openPanel(.calendars)
            }
            .frame(minWidth: 980, minHeight: 700)
        }
    }
}

struct WorkspaceAgendaRail: View {
    @EnvironmentObject private var model: AppModel
    @State private var removalCandidate: CalendarEvent?
    @State private var responseCandidate: CalendarEvent?
    @State private var detailEvent: CalendarEvent?
    @State private var editingDraft: LocalEventDraft?
    @State private var editScopeCandidate: CalendarEvent?

    private var nextEvent: CalendarEvent? {
        let upcoming = model.agendaEvents().filter { $0.endDate > Date() }
        return upcoming.first { !$0.isAllDay } ?? upcoming.first
    }

    private var unconfirmedEvents: [CalendarEvent] {
        model.responseEvents()
    }

    private var agendaEvents: [CalendarEvent] {
        model.agendaEvents()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Agenda")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text("\(unconfirmedEvents.count) unconfirmed · \(agendaEvents.count) upcoming")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    AgendaRailNextCard(
                        event: nextEvent,
                        displayLocation: nextEvent.flatMap { model.displayLocation(for: $0, now: context.date) },
                        now: context.date,
                        openDetails: { event in detailEvent = event },
                        join: { event in model.openEventLink(event) }
                    )
                }

                if !unconfirmedEvents.isEmpty {
                    AgendaRailSection(title: "Needs Response", count: unconfirmedEvents.count, color: .orange) {
                        ForEach(unconfirmedEvents.prefix(4)) { event in
                            AgendaRailEventRow(
                                event: event,
                                displayLocation: model.displayLocation(for: event),
                                openDetails: { detailEvent = event },
                                join: { model.openEventLink(event) },
                                canRespond: model.canRespond(to: event),
                                respond: { responseCandidate = event },
                                canRemove: model.canEdit(event),
                                remove: { removalCandidate = event }
                            )
                        }
                    }
                }

                AgendaRailSection(title: "Upcoming", count: agendaEvents.count, color: .blue) {
                    if agendaEvents.isEmpty {
                        Text("No meetings in range.")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        ForEach(agendaEvents.prefix(14)) { event in
                            AgendaRailEventRow(
                                event: event,
                                displayLocation: model.displayLocation(for: event),
                                openDetails: { detailEvent = event },
                                join: { model.openEventLink(event) },
                                canRespond: model.canRespond(to: event),
                                respond: { responseCandidate = event },
                                canRemove: model.canEdit(event),
                                remove: { removalCandidate = event }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .padding(.top, 54)
        }
        .background(AgendaRailBackground())
        .confirmationDialog(
            removalCandidate.map { "Remove \"\($0.title)\"?" } ?? "Remove event?",
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let event = removalCandidate {
                Button("This Event", role: .destructive) {
                    model.remove(event, scope: .thisEvent)
                    removalCandidate = nil
                    detailEvent = nil
                }

                if event.isRecurring {
                    Button("This and Future Events", role: .destructive) {
                        model.remove(event, scope: .futureEvents)
                        removalCandidate = nil
                        detailEvent = nil
                    }

                    Button("All Events", role: .destructive) {
                        model.remove(event, scope: .allEvents)
                        removalCandidate = nil
                        detailEvent = nil
                    }
                }
            }

            Button("Cancel", role: .cancel) {
                removalCandidate = nil
            }
        } message: {
            Text(removalCandidate.map(removalMessage(for:)) ?? "This removes the event from Working Calendar.")
        }
        .confirmationDialog(
            editScopeCandidate.map { "Edit \"\($0.title)\"?" } ?? "Edit event?",
            isPresented: Binding(
                get: { editScopeCandidate != nil },
                set: { if !$0 { editScopeCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let event = editScopeCandidate {
                Button("This Event") {
                    editingDraft = model.occurrenceDraftForLocalEvent(event)
                    editScopeCandidate = nil
                    detailEvent = nil
                }

                Button("All Events") {
                    editingDraft = model.draftForLocalEvent(event)
                    editScopeCandidate = nil
                    detailEvent = nil
                }
            }

            Button("Cancel", role: .cancel) {
                editScopeCandidate = nil
            }
        } message: {
            Text("Choose whether to detach this occurrence or edit the whole local series.")
        }
        .confirmationDialog(
            responseCandidate.map { "Respond to \"\($0.title)\"?" } ?? "Respond to invite?",
            isPresented: Binding(
                get: { responseCandidate != nil },
                set: { if !$0 { responseCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let event = responseCandidate {
                if event.isRecurring {
                    Button("Accept This Event") {
                        respondAndClose(event, with: .accept, scope: .thisEvent)
                    }
                    Button("Accept All Events") {
                        respondAndClose(event, with: .accept, scope: .allEvents)
                    }
                    Button("Maybe This Event") {
                        respondAndClose(event, with: .maybe, scope: .thisEvent)
                    }
                    Button("Maybe All Events") {
                        respondAndClose(event, with: .maybe, scope: .allEvents)
                    }
                    Button("Decline This Event", role: .destructive) {
                        respondAndClose(event, with: .decline, scope: .thisEvent)
                    }
                    Button("Decline All Events", role: .destructive) {
                        respondAndClose(event, with: .decline, scope: .allEvents)
                    }
                } else {
                    Button("Accept") {
                        respondAndClose(event, with: .accept, scope: .thisEvent)
                    }
                    Button("Maybe") {
                        respondAndClose(event, with: .maybe, scope: .thisEvent)
                    }
                    Button("Decline", role: .destructive) {
                        respondAndClose(event, with: .decline, scope: .thisEvent)
                    }
                }
            }

            Button("Cancel", role: .cancel) {
                responseCandidate = nil
            }
        } message: {
            Text(responseCandidate.map(responseMessage(for:)) ?? "Working Calendar will save this response locally and sync it through the connected provider when possible.")
        }
        .sheet(item: $detailEvent) { event in
            MeetingDetailView(
                event: event,
                displayLocation: model.displayLocation(for: event),
                backendInfo: model.backendInfo(forCalendarID: event.calendarID),
                join: { model.openEventLink(event) },
                edit: model.canEdit(event) ? {
                    if event.isRecurring {
                        editScopeCandidate = event
                    } else {
                        editingDraft = model.draftForLocalEvent(event)
                        detailEvent = nil
                    }
                } : nil,
                duplicate: model.duplicateDraftForLocalEvent(event).map { draft in
                    {
                        editingDraft = draft
                        detailEvent = nil
                    }
                },
                remove: model.canEdit(event) ? {
                    removalCandidate = event
                } : nil,
                respond: model.canRespond(to: event) ? { response, scope in
                    model.respond(to: event, with: response, scope: scope)
                } : nil
            )
        }
        .sheet(item: $editingDraft) { draft in
            LocalEventEditorView(
                draft: draft,
                calendars: model.writableCalendars,
                backendInfoForCalendarID: { model.backendInfo(forCalendarID: $0) },
                conflictsForDraft: { model.conflictCandidates(for: $0) },
                save: { updatedDraft in
                    model.saveLocalEvent(updatedDraft)
                    editingDraft = nil
                },
                cancel: {
                    editingDraft = nil
                }
            )
        }
    }

    private func removalMessage(for event: CalendarEvent) -> String {
        let scope = event.isRecurring
            ? "Choose whether to remove only this occurrence, this and future occurrences, or the whole series."
            : "This removes the event."
        if model.needsDirectCalendarChangeConfirmation(for: event) {
            return "\(scope) Working Calendar will sync the deletion back to \(event.sourceTitle) when possible."
        }
        return "\(scope) Working Calendar will delete it from the local store."
    }

    private func respondAndClose(
        _ event: CalendarEvent,
        with response: CalendarEventResponse,
        scope: CalendarEventResponseScope
    ) {
        model.respond(to: event, with: response, scope: scope)
        responseCandidate = nil
    }

    private func responseMessage(for event: CalendarEvent) -> String {
        if event.isRecurring {
            return "Choose whether this response applies only to this occurrence or to the whole recurring series. Working Calendar will sync it through the connected provider when possible."
        }

        return "Working Calendar will save this response locally and sync it through the connected provider when possible."
    }
}

struct AgendaRailBackground: View {
    var body: some View {
        Color(nsColor: .controlBackgroundColor)
            .overlay(.ultraThinMaterial)
        .ignoresSafeArea()
    }
}

struct AgendaRailSection<Content: View>: View {
    let title: String
    let count: Int
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.18), in: Capsule())
            }

            VStack(spacing: 8) {
                content
            }
        }
    }
}

struct AgendaRailNextCard: View {
    let event: CalendarEvent?
    let displayLocation: String?
    let now: Date
    let openDetails: (CalendarEvent) -> Void
    let join: (CalendarEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Next")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Text(event?.title ?? "Deep work window")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                }

                Spacer()

                if let event {
                    CountdownBadge(event: event, now: now)
                }
            }

            if let event {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        CalendarDot(color: event.calendarColor)
                        Text(Formatters.eventRange(event))
                        Spacer()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        MeetingMethodChip(method: event.meetingMethod)
                        if let displayLocation, !displayLocation.isEmpty {
                            Text("·")
                            Label(displayLocation, systemImage: "mappin.and.ellipse")
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if event.joinURL != nil {
                        Button {
                            join(event)
                        } label: {
                            Label("Join", systemImage: "video.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            } else {
                Text("No event is close enough to demand attention.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            if let event {
                openDetails(event)
            }
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
    }
}

struct AgendaRailEventRow: View {
    let event: CalendarEvent
    let displayLocation: String?
    let openDetails: () -> Void
    let join: () -> Void
    let canRespond: Bool
    let respond: () -> Void
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 4) {
                Text(Formatters.weekday.string(from: event.startDate).uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(Formatters.eventStartLabel(event))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.72)
            }
            .frame(width: 48)

            CalendarDot(color: event.calendarColor)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 5) {
                Text(event.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    MeetingMethodChip(method: event.meetingMethod)
                    if event.needsResponse {
                        ResponseStatusChip(status: event.responseStatus)
                    }
                    if event.joinURL != nil {
                        Image(systemName: "video.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let displayLocation, !displayLocation.isEmpty {
                    Label(displayLocation, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if event.needsResponse && canRespond {
                        Button(action: respond) {
                            Image(systemName: "checkmark.message")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Respond")
                    }

                    if event.joinURL != nil {
                        Button(action: join) {
                            Image(systemName: "video.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Join")
                    }

                    if canRemove {
                        Button(role: .destructive, action: remove) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Remove")
                    }
                }
                .opacity(event.needsResponse || event.joinURL != nil || canRemove ? 1 : 0)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(perform: openDetails)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }
}

struct StatusLine: View {
    let symbolName: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .foregroundStyle(color)
                .frame(width: 15)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct AppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .controlBackgroundColor),
                Color(nsColor: .underPageBackgroundColor)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
