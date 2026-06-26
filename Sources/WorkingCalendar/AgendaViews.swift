import SwiftUI

struct AgendaView: View {
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
            VStack(alignment: .leading, spacing: 22) {
                HeaderBar(
                    title: "Working Calendar",
                    subtitle: "\(unconfirmedEvents.count) unconfirmed · \(agendaEvents.count) upcoming",
                    actionTitle: "Refresh",
                    actionSystemImage: "arrow.clockwise"
                ) {
                    model.tick()
                }

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    NextMeetingPanel(
                        event: nextEvent,
                        displayLocation: nextEvent.flatMap { model.displayLocation(for: $0, now: context.date) },
                        now: context.date,
                        openDetails: { event in detailEvent = event }
                    )
                }

                if !unconfirmedEvents.isEmpty {
                    UnconfirmedMeetingsPanel(
                        events: unconfirmedEvents,
                        displayLocation: { event in model.displayLocation(for: event) },
                        openDetails: { event in detailEvent = event },
                        respond: { event in responseCandidate = event },
                        remove: { event in removalCandidate = event }
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "Upcoming", subtitle: "\(Int(model.lookAheadHours)) hour window")

                    if agendaEvents.isEmpty {
                        EmptyStateView(
                            systemImage: "moon.stars",
                            title: "No meetings in range",
                            subtitle: "Either your calendar is merciful or the enabled calendar set is quiet."
                        )
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(agendaEvents) { event in
                                EventRow(
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
            }
            .padding(28)
        }
        .confirmationDialog(
            removalCandidate.map { "Remove “\($0.title)”?" } ?? "Remove event?",
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
            editScopeCandidate.map { "Edit “\($0.title)”?" } ?? "Edit event?",
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
            responseCandidate.map { "Respond to “\($0.title)”?" } ?? "Respond to invite?",
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

struct UnconfirmedMeetingsPanel: View {
    let events: [CalendarEvent]
    let displayLocation: (CalendarEvent) -> String?
    let openDetails: (CalendarEvent) -> Void
    let respond: (CalendarEvent) -> Void
    let remove: (CalendarEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("\(events.count) unconfirmed", systemImage: "questionmark.circle.fill")
                    .font(.title3.bold())
                    .foregroundStyle(.orange)
                Spacer()
                Text("Accept, Maybe, or Decline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVStack(spacing: 8) {
                ForEach(events.prefix(5)) { event in
                    CompactInviteRow(event: event, displayLocation: displayLocation(event), openDetails: {
                        openDetails(event)
                    }, respond: {
                        respond(event)
                    }, remove: {
                        remove(event)
                    })
                }
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.24))
        )
    }
}

struct CompactInviteRow: View {
    let event: CalendarEvent
    let displayLocation: String?
    let openDetails: () -> Void
    let respond: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                CalendarDot(color: event.calendarColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(Formatters.eventRange(event))
                        Text("·")
                        Text(event.responseStatus.title)
                        Text("·")
                        MeetingMethodChip(method: event.meetingMethod)
                        if let displayLocation, !displayLocation.isEmpty {
                            Text("·")
                            Label(displayLocation, systemImage: "mappin.and.ellipse")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: openDetails)

            Spacer()

            Button(action: respond) {
                Label("Respond", systemImage: "checkmark.message")
            }
            .buttonStyle(.borderedProminent)

            Button(role: .destructive, action: remove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .help("Remove from Calendar")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct NextMeetingPanel: View {
    let event: CalendarEvent?
    let displayLocation: String?
    let now: Date
    let openDetails: (CalendarEvent) -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Next meeting")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if let event {
                        Text(event.title)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                    } else {
                        Text("Deep work window")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                    }
                }

                Spacer()

                if let event {
                    CountdownBadge(event: event, now: now)
                }
            }

            if let event {
                HStack(spacing: 16) {
                    CalendarDot(color: event.calendarColor)
                    Text(Formatters.eventRange(event))
                    MeetingMethodChip(method: event.meetingMethod)
                    Text(event.calendarTitle)
                        .foregroundStyle(.secondary)
                    if !event.availability.isBusy {
                        AvailabilityBadge(availability: event.availability)
                    }
                    if let displayLocation, !displayLocation.isEmpty {
                        Text(displayLocation)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if event.joinURL != nil {
                        Button {
                            model.openEventLink(event)
                        } label: {
                            Label("Join", systemImage: "video.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .font(.callout)
            } else {
                Text("No events are close enough to demand attention.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            if let event {
                openDetails(event)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16))
        )
    }
}

struct CountdownBadge: View {
    let event: CalendarEvent
    let now: Date

    var body: some View {
        if event.isAllDay {
            VStack(alignment: .trailing, spacing: 4) {
                Text("All day")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(event.isHappening(at: now) ? "today" : "upcoming")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.teal.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.teal)
        } else {
            let seconds = event.startDate.timeIntervalSince(now)
            let minutes = Int(ceil(seconds / 60))
            let label = labelText(minutes: minutes)

            VStack(alignment: .trailing, spacing: 4) {
                Text(label)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(event.isHappening(at: now) ? "live now" : "until start")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(countdownColor(minutes: minutes).opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(countdownColor(minutes: minutes))
        }
    }

    private func labelText(minutes: Int) -> String {
        if minutes > 0 { return "\(minutes)m" }
        if minutes == 0 { return "now" }
        return "+\(abs(minutes))m"
    }

    private func countdownColor(minutes: Int) -> Color {
        if minutes <= 1 { return .red }
        if minutes <= 5 { return .orange }
        return .teal
    }
}

struct EventRow: View {
    let event: CalendarEvent
    let displayLocation: String?
    let openDetails: () -> Void
    let join: () -> Void
    let canRespond: Bool
    let respond: () -> Void
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 14) {
                VStack(spacing: 3) {
                    Text(Formatters.weekday.string(from: event.startDate).uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(Formatters.eventStartLabel(event))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.72)
                }
                .frame(width: 66)

                CalendarDot(color: event.calendarColor)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(event.title)
                            .font(.headline)
                            .lineLimit(1)

                        if event.needsResponse {
                            ResponseStatusChip(status: event.responseStatus)
                        }

                        if !event.availability.isBusy {
                            AvailabilityBadge(availability: event.availability)
                        }

                        if event.isRecurring {
                            Image(systemName: "repeat")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .help("Recurring event")
                        }
                    }
                    HStack(spacing: 8) {
                        Text(event.calendarTitle)
                        Text("·")
                        Text(event.sourceTitle)
                        Text("·")
                        MeetingMethodChip(method: event.meetingMethod)
                        if event.attendeeCount > 0 {
                            Text("·")
                            Text("\(event.attendeeCount) attendees")
                        }
                        if let displayLocation, !displayLocation.isEmpty {
                            Text("·")
                            Label(displayLocation, systemImage: "mappin.and.ellipse")
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: openDetails)

            Spacer()

            if event.needsResponse && canRespond {
                Button(action: respond) {
                    Image(systemName: "checkmark.message")
                }
                .help("Respond in Calendar")
                .buttonStyle(.bordered)
            }

            if event.joinURL != nil {
                Button(action: join) {
                    Image(systemName: "video.fill")
                }
                .help("Open meeting link")
                .buttonStyle(.bordered)
            }

            if canRemove {
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                }
                .help("Remove from Calendar")
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ResponseStatusChip: View {
    let status: EventResponseStatus

    var body: some View {
        Text(status.responseDisplayTitle)
            .font(.caption2.weight(.bold))
            .foregroundStyle(status.detailColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(status.detailColor.opacity(0.15), in: Capsule())
    }
}

struct MeetingMethodChip: View {
    let method: MeetingMethod

    var body: some View {
        Label(method.title, systemImage: method.symbolName)
            .lineLimit(1)
    }
}

struct MeetingDetailView: View {
    let event: CalendarEvent
    let displayLocation: String?
    let backendInfo: CalendarBackendInfo
    let join: () -> Void
    let edit: (() -> Void)?
    let duplicate: (() -> Void)?
    let remove: (() -> Void)?
    let respond: ((CalendarEventResponse, CalendarEventResponseScope) -> Void)?
    @State private var responseCandidate: CalendarEventResponse?

    private var nonRoomParticipants: [EventParticipant] {
        event.participants.filter { !$0.isRoomLike }
    }

    private var groupedParticipants: [(EventResponseStatus, [EventParticipant])] {
        let order: [EventResponseStatus] = [.accepted, .tentative, .pending, .unknown, .declined, .delegated, .inProcess, .completed, .notInvited, .canceled]
        return order.compactMap { status in
            let people = nonRoomParticipants.filter { $0.status == status }
            return people.isEmpty ? nil : (status, people)
        }
    }

    private var remoteUpdateSummary: String? {
        guard backendInfo.isProviderBacked else { return nil }

        let attentionCount = backendInfo.attentionOutboxCount
        let waitingCount = max(0, backendInfo.pendingOutboxCount - attentionCount)
        var parts: [String] = []
        if attentionCount > 0 {
            parts.append("\(attentionCount) need attention")
        }
        if waitingCount > 0 {
            parts.append("\(waitingCount) pending")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var syncErrorText: String? {
        let text = backendInfo.lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                CalendarDot(color: event.calendarColor)
                    .padding(.top, 7)

                VStack(alignment: .leading, spacing: 8) {
                    Text(event.title)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .lineLimit(3)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        Text(Formatters.eventRange(event))
                        Text("·")
                        MeetingMethodChip(method: event.meetingMethod)
                        Text("·")
                        Text(event.calendarTitle)
                        if event.isRecurring {
                            Text("·")
                            Label("Recurring", systemImage: "repeat")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    if event.responseStatusIsExplicit {
                        ResponseStatusChip(status: event.responseStatus)
                    }

                    HStack(spacing: 8) {
                        if event.joinURL != nil {
                            Button(action: join) {
                                Label("Join", systemImage: "video.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if let edit {
                            Button(action: edit) {
                                Label("Edit", systemImage: "pencil")
                            }
                        }

                        if let duplicate {
                            Button(action: duplicate) {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                        }

                        if let remove {
                            Button(role: .destructive, action: remove) {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DetailSection(title: "How") {
                        DetailLine(
                            systemImage: event.meetingMethod.symbolName,
                            title: "Method",
                            value: event.meetingMethod.title
                        )

                        if let platform = event.meetingPlatform {
                            DetailLine(systemImage: platform.symbolName, title: "Provider", value: platform.title)
                        }

                        if let timeZoneIdentifier = event.timeZoneIdentifier, !timeZoneIdentifier.isEmpty {
                            DetailLine(systemImage: "globe", title: "Time Zone", value: timeZoneIdentifier)
                        }

                        DetailLine(
                            systemImage: event.availability.symbolName,
                            title: "Show As",
                            value: event.availability.title
                        )

                        if event.privacy != .public {
                            DetailLine(
                                systemImage: event.privacy.symbolName,
                                title: "Privacy",
                                value: event.privacy.title
                            )
                        }

                        if event.importance != .normal {
                            DetailLine(
                                systemImage: event.importance.symbolName,
                                title: "Importance",
                                value: event.importance.title
                            )
                        }

                        if !event.categories.isEmpty {
                            DetailLine(
                                systemImage: "tag",
                                title: "Categories",
                                value: event.categories.joined(separator: ", ")
                            )
                        }

                        if !event.reminderOffsets.isEmpty {
                            DetailLine(
                                systemImage: "alarm",
                                title: "Reminders",
                                value: reminderOffsetsTitle(event.reminderOffsets)
                            )
                        }

                        if event.status != .confirmed {
                            DetailLine(
                                systemImage: event.status.symbolName,
                                title: "Status",
                                value: event.status.title
                            )
                        }

                        if event.meetingPlatform != nil, event.physicalLocation != nil {
                            DetailMutedText("Looks hybrid: video link plus room/resource.")
                        }
                    }

                    DetailSection(title: "Source") {
                        DetailLine(systemImage: "calendar", title: "Calendar", value: event.calendarTitle)
                        DetailLine(systemImage: "tray.full", title: "Storage", value: backendInfo.storageText)
                        DetailLine(systemImage: backendInfo.isProviderBacked ? "link" : "internaldrive", title: "Source type", value: backendInfo.sourceKindTitle)
                        DetailLine(systemImage: "switch.2", title: "Capability", value: backendInfo.capabilityText)

                        if let remoteUpdateSummary {
                            DetailLine(systemImage: "arrow.triangle.2.circlepath", title: "Remote updates", value: remoteUpdateSummary)
                        }

                        if let lastSyncAt = backendInfo.lastSyncAt {
                            DetailLine(
                                systemImage: "clock.arrow.circlepath",
                                title: "Last sync",
                                value: lastSyncAt.formatted(date: .abbreviated, time: .shortened)
                            )
                        }

                        if let syncErrorText {
                            DetailLine(systemImage: "exclamationmark.triangle", title: "Sync error", value: syncErrorText)
                        }
                    }

                    DetailSection(title: "Where") {
                        if let displayLocation, !displayLocation.isEmpty {
                            DetailLine(systemImage: "mappin.and.ellipse", title: "Location", value: displayLocation)
                        } else {
                            DetailMutedText("No location")
                        }

                        if let rawLocation = event.location, !rawLocation.isEmpty, rawLocation != displayLocation {
                            DetailLine(systemImage: "calendar", title: "Raw calendar location", value: rawLocation)
                        }

                        ForEach(event.roomParticipants) { room in
                            ParticipantLine(participant: room, showStatus: true)
                        }
                    }

                    DetailSection(title: "Description") {
                        if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                            Text(notes)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            DetailMutedText("No description")
                        }
                    }

                    DetailSection(title: "Meeting Link") {
                        if let url = event.joinURL {
                            HStack {
                                Image(systemName: "link")
                                    .foregroundStyle(.secondary)
                                Text(url.absoluteString)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                                Spacer()
                                Button("Open", action: join)
                            }
                        } else {
                            DetailMutedText("No meeting link found")
                        }
                    }

                    DetailSection(title: "Organizer") {
                        if let organizer = event.organizer {
                            ParticipantLine(participant: organizer, showStatus: false)
                        } else {
                            DetailMutedText("No organizer exposed by Calendar")
                        }
                    }

                    DetailSection(title: "Participants") {
                        if nonRoomParticipants.isEmpty {
                            DetailMutedText("No participants exposed by Calendar")
                        } else {
                            HStack(spacing: 8) {
                                ParticipantCountChip(status: .accepted, participants: nonRoomParticipants)
                                ParticipantCountChip(status: .tentative, participants: nonRoomParticipants)
                                ParticipantCountChip(status: .pending, participants: nonRoomParticipants)
                                ParticipantCountChip(status: .declined, participants: nonRoomParticipants)
                                Spacer()
                            }

                            ForEach(groupedParticipants, id: \.0) { status, participants in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(status.title)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(status.detailColor)
                                        .textCase(.uppercase)

                                    ForEach(participants) { participant in
                                        ParticipantLine(participant: participant, showStatus: true)
                                    }
                                }
                                .padding(.top, 6)
                            }
                        }
                    }

                    if event.responseStatusIsExplicit {
                        DetailSection(title: "Your Response") {
                            DetailLine(
                                systemImage: "checkmark.message",
                                title: "Status",
                                value: event.responseStatus.responseDisplayTitle
                            )

                            if respond != nil {
                                HStack(spacing: 8) {
                                    Button("Accept") { responseCandidate = .accept }
                                    Button("Maybe") { responseCandidate = .maybe }
                                    Button("Decline", role: .destructive) { responseCandidate = .decline }
                                }
                            } else {
                                DetailMutedText("This source is read-only.")
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 760, height: 720)
        .confirmationDialog(
            responseCandidate.map { "\($0.title) “\(event.title)”?" } ?? "Respond to invite?",
            isPresented: Binding(
                get: { responseCandidate != nil },
                set: { if !$0 { responseCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let responseCandidate, let respond {
                if event.isRecurring {
                    Button("\(responseCandidate.title) This Event") {
                        respond(responseCandidate, .thisEvent)
                        self.responseCandidate = nil
                    }
                    Button("\(responseCandidate.title) All Events") {
                        respond(responseCandidate, .allEvents)
                        self.responseCandidate = nil
                    }
                } else {
                    Button(responseCandidate.title) {
                        respond(responseCandidate, .thisEvent)
                        self.responseCandidate = nil
                    }
                }
            }

            Button("Cancel", role: .cancel) {
                responseCandidate = nil
            }
        } message: {
            Text(responseMessage)
        }
    }

    private var responseMessage: String {
        if event.isRecurring {
            return "Choose whether this response applies only to this occurrence or to the whole recurring series."
        }

        return "Working Calendar will save this response locally and sync it through the connected provider when possible."
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

struct DetailLine: View {
    let systemImage: String
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }
}

struct DetailMutedText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

struct ParticipantLine: View {
    let participant: EventParticipant
    let showStatus: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: participant.isRoomLike ? "door.left.hand.open" : "person.crop.circle")
                .foregroundStyle(participant.isRoomLike ? .teal : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(participant.displayName)
                        .font(.callout.weight(.semibold))
                    if participant.isCurrentUser {
                        Text("you")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                    }
                }

                if !participant.email.isEmpty {
                    Text(participant.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Spacer()

            Text(participant.role)
                .font(.caption)
                .foregroundStyle(.secondary)

            if showStatus {
                Text(participant.status.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(participant.status.detailColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(participant.status.detailColor.opacity(0.12), in: Capsule())
            }
        }
    }
}

struct ParticipantCountChip: View {
    let status: EventResponseStatus
    let participants: [EventParticipant]

    private var count: Int {
        participants.filter { $0.status == status }.count
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.detailColor)
                .frame(width: 7, height: 7)
            Text("\(count) \(status.title)")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
    }
}

private extension EventResponseStatus {
    var responseDisplayTitle: String {
        switch self {
        case .notInvited:
            return "No invite"
        case .pending, .unknown, .inProcess:
            return "No reply"
        case .tentative:
            return "Maybe"
        case .accepted:
            return "Accepted"
        case .declined:
            return "Declined"
        case .delegated:
            return "Delegated"
        case .completed:
            return "Completed"
        case .canceled:
            return "Canceled"
        }
    }

    var detailColor: Color {
        switch self {
        case .accepted, .completed:
            return .green
        case .tentative:
            return .orange
        case .pending, .unknown, .inProcess:
            return .blue
        case .declined, .canceled:
            return .red
        case .delegated:
            return .purple
        case .notInvited:
            return .secondary
        }
    }
}
