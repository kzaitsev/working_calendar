import SwiftUI
import UniformTypeIdentifiers

enum CalendarGridMode: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        }
    }
}

struct CalendarGridView: View {
    @EnvironmentObject private var model: AppModel
    let openCalendars: (() -> Void)?
    let openRules: (() -> Void)?
    let openSettings: (() -> Void)?
    @State private var mode: CalendarGridMode = .week
    @State private var focusedDate = Date()
    @State private var gridEvents: [CalendarEvent] = []
    @State private var searchText = ""
    @State private var detailEvent: CalendarEvent?
    @State private var editingDraft: LocalEventDraft?
    @State private var editScopeCandidate: CalendarEvent?
    @State private var removalCandidate: CalendarEvent?
    @State private var pendingGridChange: PendingCalendarGridChange?

    init(
        openCalendars: (() -> Void)? = nil,
        openRules: (() -> Void)? = nil,
        openSettings: (() -> Void)? = nil
    ) {
        self.openCalendars = openCalendars
        self.openRules = openRules
        self.openSettings = openSettings
    }

    private var visibleInterval: DateInterval {
        CalendarGridDates.visibleInterval(for: focusedDate, mode: mode)
    }

    private var visibleDays: [Date] {
        CalendarGridDates.visibleDays(for: focusedDate, mode: mode)
    }

    private var title: String {
        CalendarGridDates.title(for: focusedDate, mode: mode)
    }

    private var visibleEvents: [CalendarEvent] {
        let tokens = searchText
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        guard !tokens.isEmpty else { return gridEvents }

        return gridEvents.filter { event in
            let haystack = event.searchableText.lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CalendarGridHeader(
                title: title,
                mode: $mode,
                focusedDate: $focusedDate,
                searchText: $searchText,
                visibleEventCount: visibleEvents.count,
                totalEventCount: gridEvents.count,
                previous: { shiftFocusedDate(-1) },
                next: { shiftFocusedDate(1) },
                today: { focusedDate = Date() },
                add: { editingDraft = model.draftForLocalEvent(on: focusedDate) },
                refresh: {
                    model.tick()
                    refreshGridEvents()
                },
                openCalendars: openCalendars,
                openRules: openRules,
                openSettings: openSettings
            )

            TimelineView(.periodic(from: .now, by: 60)) { context in
                Group {
                    switch mode {
                    case .day, .week:
                        TimeCalendarGrid(
                            days: visibleDays,
                            events: visibleEvents,
                            now: context.date,
                            displayLocation: { event in model.displayLocation(for: event, now: context.date) },
                            openDetails: { event in detailEvent = event },
                            canEdit: { event in model.canEdit(event) },
                            moveEvent: { event, dayDelta, minuteDelta in
                                requestGridMove(event, dayDelta: dayDelta, minuteDelta: minuteDelta)
                            },
                            resizeEvent: { event, endMinuteDelta in
                                requestGridResize(event, endMinuteDelta: endMinuteDelta)
                            },
                            createEvent: { start, end in
                                editingDraft = model.draftForLocalEvent(start: start, end: end)
                            },
                            createAllDayEvent: { day in
                                let start = Calendar.current.startOfDay(for: day)
                                let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 3600)
                                editingDraft = model.draftForLocalEvent(start: start, end: end, isAllDay: true)
                            }
                        )
                    case .month:
                        MonthCalendarGrid(
                            monthDate: focusedDate,
                            days: visibleDays,
                            events: visibleEvents,
                            openDetails: { event in detailEvent = event },
                            canEdit: { event in model.canEdit(event) },
                            moveEvent: { event, targetDay in
                                let sourceDay = Calendar.current.startOfDay(for: event.startDate)
                                let destinationDay = Calendar.current.startOfDay(for: targetDay)
                                let dayDelta = Calendar.current.dateComponents([.day], from: sourceDay, to: destinationDay).day ?? 0
                                requestGridMove(event, dayDelta: dayDelta, minuteDelta: 0)
                            },
                            createEvent: { day in
                                let start = Calendar.current.startOfDay(for: day)
                                let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 3600)
                                editingDraft = model.draftForLocalEvent(start: start, end: end, isAllDay: true)
                            }
                        )
                    }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: refreshGridEvents)
        .onChange(of: focusedDate) { _, _ in refreshGridEvents() }
        .onChange(of: mode) { _, _ in refreshGridEvents() }
        .onReceive(model.localCalendarStore.$events) { _ in refreshGridEvents() }
        .onReceive(model.localCalendarStore.$calendars) { _ in refreshGridEvents() }
        .onReceive(model.localCalendarStore.$selectedCalendarIDs) { _ in refreshGridEvents() }
        .onReceive(model.providerStore.$accounts) { _ in refreshGridEvents() }
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
                    refreshGridEvents()
                },
                cancel: {
                    editingDraft = nil
                }
            )
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
            removalCandidate.map { "Delete “\($0.title)”?" } ?? "Delete event?",
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let event = removalCandidate {
                Button(event.isRecurring ? "This Event" : "Delete Event", role: .destructive) {
                    model.remove(event, scope: .thisEvent)
                    removalCandidate = nil
                    detailEvent = nil
                    refreshGridEvents()
                }

                if event.isRecurring {
                    Button("This and Future Events", role: .destructive) {
                        model.remove(event, scope: .futureEvents)
                        removalCandidate = nil
                        detailEvent = nil
                        refreshGridEvents()
                    }

                    Button("All Events", role: .destructive) {
                        model.remove(event, scope: .allEvents)
                        removalCandidate = nil
                        detailEvent = nil
                        refreshGridEvents()
                    }
                }
            }

            Button("Cancel", role: .cancel) {
                removalCandidate = nil
            }
        } message: {
            Text(removalCandidate.map(removalMessage(for:)) ?? "This deletes the event from Working Calendar.")
        }
        .confirmationDialog(
            pendingGridChange?.title ?? "Update event?",
            isPresented: Binding(
                get: { pendingGridChange != nil },
                set: { if !$0 { pendingGridChange = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let change = pendingGridChange {
                if change.event.isRecurring {
                    Button(change.actionTitle(for: .thisEvent)) {
                        commitGridChange(change, scope: .thisEvent)
                        pendingGridChange = nil
                    }

                    Button(change.actionTitle(for: .futureEvents)) {
                        commitGridChange(change, scope: .futureEvents)
                        pendingGridChange = nil
                    }

                    Button(change.actionTitle(for: .allEvents)) {
                        commitGridChange(change, scope: .allEvents)
                        pendingGridChange = nil
                    }
                } else {
                    Button(change.actionTitle(for: .thisEvent)) {
                        commitGridChange(change, scope: .thisEvent)
                        pendingGridChange = nil
                    }
                }
            }

            Button("Cancel", role: .cancel) {
                pendingGridChange = nil
            }
        } message: {
            if let change = pendingGridChange {
                Text(change.message)
            }
        }
    }

    private func requestGridMove(_ event: CalendarEvent, dayDelta: Int, minuteDelta: Int) {
        guard dayDelta != 0 || minuteDelta != 0 else { return }
        let change = PendingCalendarGridChange.move(event: event, dayDelta: dayDelta, minuteDelta: minuteDelta)
        if model.needsDirectCalendarChangeConfirmation(for: event) {
            pendingGridChange = change
        } else {
            commitGridChange(change)
        }
    }

    private func requestGridResize(_ event: CalendarEvent, endMinuteDelta: Int) {
        guard endMinuteDelta != 0 else { return }
        let change = PendingCalendarGridChange.resize(event: event, endMinuteDelta: endMinuteDelta)
        if model.needsDirectCalendarChangeConfirmation(for: event) {
            pendingGridChange = change
        } else {
            commitGridChange(change)
        }
    }

    private func commitGridChange(
        _ change: PendingCalendarGridChange,
        scope: CalendarEventChangeScope = .thisEvent
    ) {
        switch change {
        case .move(let event, let dayDelta, let minuteDelta):
            model.moveLocalEvent(event, dayDelta: dayDelta, minuteDelta: minuteDelta, scope: scope)
        case .resize(let event, let endMinuteDelta):
            model.resizeLocalEvent(event, endMinuteDelta: endMinuteDelta, scope: scope)
        }
        refreshGridEvents()
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

    private func refreshGridEvents() {
        let fetchInterval = CalendarGridDates.fetchInterval(for: focusedDate, mode: mode)
        gridEvents = model.calendarEvents(
            from: fetchInterval.start,
            to: fetchInterval.end,
            includeAllDay: true
        )
    }

    private func shiftFocusedDate(_ amount: Int) {
        let component: Calendar.Component
        switch mode {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }

        focusedDate = Calendar.current.date(byAdding: component, value: amount, to: focusedDate) ?? focusedDate
    }
}

private enum PendingCalendarGridChange: Identifiable {
    case move(event: CalendarEvent, dayDelta: Int, minuteDelta: Int)
    case resize(event: CalendarEvent, endMinuteDelta: Int)

    var id: String {
        switch self {
        case .move(let event, let dayDelta, let minuteDelta):
            return "move-\(event.id)-\(dayDelta)-\(minuteDelta)"
        case .resize(let event, let endMinuteDelta):
            return "resize-\(event.id)-\(endMinuteDelta)"
        }
    }

    var title: String {
        switch self {
        case .move(let event, _, _):
            return "Move \"\(event.title)\"?"
        case .resize(let event, _):
            return "Resize \"\(event.title)\"?"
        }
    }

    var message: String {
        if event.isRecurring {
            return "\(changeSummary) Choose whether this applies only to this occurrence, this and future events, or all events in the series. \(syncSummary)"
        }
        return "\(changeSummary) \(syncSummary)"
    }

    var event: CalendarEvent {
        switch self {
        case .move(let event, _, _), .resize(let event, _):
            return event
        }
    }

    func actionTitle(for scope: CalendarEventChangeScope) -> String {
        switch (self, scope) {
        case (.move, .thisEvent):
            return event.isRecurring ? "Move This Event" : "Move Event"
        case (.move, .futureEvents):
            return "Move This and Future Events"
        case (.move, .allEvents):
            return "Move All Events"
        case (.resize, .thisEvent):
            return event.isRecurring ? "Resize This Event" : "Resize Event"
        case (.resize, .futureEvents):
            return "Resize This and Future Events"
        case (.resize, .allEvents):
            return "Resize All Events"
        }
    }

    private var changeSummary: String {
        switch self {
        case .move(_, let dayDelta, let minuteDelta):
            return "Move by \(deltaSummary(dayDelta: dayDelta, minuteDelta: minuteDelta))."
        case .resize(_, let endMinuteDelta):
            return "Change the end time \(minuteDeltaSummary(endMinuteDelta))."
        }
    }

    private var syncSummary: String {
        let target = event.isRecurring ? "the selected scope" : "this event"
        if event.sourceTitle == "Working Calendar" {
            return "Working Calendar will update \(target)."
        }
        return "Working Calendar will update \(target) and sync it back to \(event.sourceTitle) when possible."
    }

    private func deltaSummary(dayDelta: Int, minuteDelta: Int) -> String {
        var parts: [String] = []
        if dayDelta != 0 {
            parts.append("\(abs(dayDelta)) \(abs(dayDelta) == 1 ? "day" : "days") \(dayDelta > 0 ? "later" : "earlier")")
        }
        if minuteDelta != 0 {
            parts.append(minuteDeltaSummary(minuteDelta))
        }
        return parts.isEmpty ? "no time" : parts.joined(separator: " and ")
    }

    private func minuteDeltaSummary(_ minutes: Int) -> String {
        let absoluteMinutes = abs(minutes)
        let unit = absoluteMinutes == 1 ? "minute" : "minutes"
        return "\(absoluteMinutes) \(unit) \(minutes > 0 ? "later" : "earlier")"
    }
}

struct CalendarGridHeader: View {
    let title: String
    @Binding var mode: CalendarGridMode
    @Binding var focusedDate: Date
    @Binding var searchText: String
    let visibleEventCount: Int
    let totalEventCount: Int
    let previous: () -> Void
    let next: () -> Void
    let today: () -> Void
    let add: () -> Void
    let refresh: () -> Void
    let openCalendars: (() -> Void)?
    let openRules: (() -> Void)?
    let openSettings: (() -> Void)?

    @State private var isShowingDatePicker = false

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasSettingsMenu: Bool {
        openCalendars != nil || openRules != nil || openSettings != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    isShowingDatePicker = true
                } label: {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 23, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.76)
                        Image(systemName: "calendar")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Jump to date")
                .popover(isPresented: $isShowingDatePicker, arrowEdge: .bottom) {
                    CalendarDateJumpPopover(
                        focusedDate: $focusedDate,
                        close: { isShowingDatePicker = false }
                    )
                }

                Spacer()

                Picker("", selection: $mode) {
                    ForEach(CalendarGridMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 230)

                HStack(spacing: 6) {
                    Button(action: previous) {
                        Image(systemName: "chevron.left")
                    }
                    .help("Previous")

                    Button("Today", action: today)
                        .help("Today")

                    Button(action: next) {
                        Image(systemName: "chevron.right")
                    }
                    .help("Next")
                }
                .buttonStyle(.bordered)

                Button(action: add) {
                    Label("New Event", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Button(action: refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)

                if hasSettingsMenu {
                    Menu {
                        if let openCalendars {
                            Button(action: openCalendars) {
                                Label("Calendar Sources", systemImage: WorkspaceSettingsPanel.calendars.symbolName)
                            }
                        }

                        if let openRules {
                            Button(action: openRules) {
                                Label("Rules", systemImage: WorkspaceSettingsPanel.rules.symbolName)
                            }
                        }

                        if openCalendars != nil || openRules != nil {
                            Divider()
                        }

                        if let openSettings {
                            Button(action: openSettings) {
                                Label("Settings", systemImage: WorkspaceSettingsPanel.settings.symbolName)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .help("Manage calendars, rules, and settings")
                }
            }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search events, people, rooms", text: $searchText)
                        .textFieldStyle(.plain)

                    if isSearching {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(width: 320)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if isSearching {
                    Text("\(visibleEventCount) of \(totalEventCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.09), in: Capsule())
                }

                Spacer()
            }
        }
    }
}

struct CalendarDateJumpPopover: View {
    @Binding var focusedDate: Date
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Jump to Date", systemImage: "calendar")
                    .font(.headline)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close")
            }

            DatePicker(
                "",
                selection: Binding(
                    get: { focusedDate },
                    set: { date in
                        focusedDate = Calendar.current.startOfDay(for: date)
                        close()
                    }
                ),
                displayedComponents: [.date]
            )
            .labelsHidden()
            .datePickerStyle(.graphical)
            .frame(width: 280)

            HStack {
                Text(Formatters.date.string(from: focusedDate))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Today") {
                    focusedDate = Date()
                    close()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(width: 310)
    }
}

struct TimeCalendarGrid: View {
    let days: [Date]
    let events: [CalendarEvent]
    let now: Date
    let displayLocation: (CalendarEvent) -> String?
    let openDetails: (CalendarEvent) -> Void
    let canEdit: (CalendarEvent) -> Bool
    let moveEvent: (CalendarEvent, Int, Int) -> Void
    let resizeEvent: (CalendarEvent, Int) -> Void
    let createEvent: (Date, Date) -> Void
    let createAllDayEvent: (Date) -> Void

    @State private var selectionPreview: TimeGridSelection?
    @State private var didInitialScroll = false

    private let gutterWidth: CGFloat = 58
    private let hourHeight: CGFloat = 68
    private let headerHeight: CGFloat = 116
    private var gridHeight: CGFloat { 24 * hourHeight }

    private var allDayEvents: [CalendarEvent] {
        events.filter(\.isAllDay)
    }

    private var timedEvents: [CalendarEvent] {
        events.filter { !$0.isAllDay }
    }

    var body: some View {
        GeometryReader { geometry in
            let dayCount = max(days.count, 1)
            let availableWidth = max(gutterWidth + CGFloat(dayCount), geometry.size.width)
            let dayWidth = max(1, (availableWidth - gutterWidth) / CGFloat(dayCount))
            let contentWidth = gutterWidth + dayWidth * CGFloat(dayCount)
            let layouts = CalendarTimedEventLayout.make(
                days: days,
                events: timedEvents,
                hourHeight: hourHeight
            )

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("ALL-DAY")
                            .font(.caption2.weight(.bold))
                        Text(currentTimezoneTitle)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: gutterWidth, height: headerHeight, alignment: .bottomTrailing)
                    .padding(.trailing, 8)
                    .padding(.bottom, 12)

                    ForEach(days, id: \.timeIntervalSinceReferenceDate) { day in
                        CalendarDayHeader(
                            day: day,
                            allVisibleEvents: allDayEvents,
                            allDayEvents: CalendarGridEventOrdering.sorted(
                                allDayEvents.filter { $0.overlaps(day: day) },
                                in: day
                            ),
                            width: dayWidth,
                            openDetails: openDetails,
                            canEdit: canEdit,
                            moveEvent: moveEvent,
                            createAllDayEvent: createAllDayEvent
                        )
                    }
                }
                .frame(width: contentWidth, height: headerHeight, alignment: .leading)
                .background(.regularMaterial)

                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical) {
                        ZStack(alignment: .topLeading) {
                            TimeGridBackground(
                                days: days,
                                dayWidth: dayWidth,
                                gutterWidth: gutterWidth,
                                hourHeight: hourHeight,
                                height: gridHeight,
                                now: now
                            )
                            .contentShape(Rectangle())
                            .gesture(selectionGesture(dayWidth: dayWidth))

                            ForEach(0...23, id: \.self) { hour in
                                Color.clear
                                    .frame(width: contentWidth, height: 1)
                                    .offset(y: CGFloat(hour) * hourHeight)
                                    .id(TimeGridScrollAnchor.hour(hour))
                                    .allowsHitTesting(false)
                            }

                            if let selectionPreview {
                                TimeGridSelectionPreview(selection: selectionPreview)
                                    .offset(x: gutterWidth + CGFloat(selectionPreview.dayIndex) * dayWidth + 4, y: selectionPreview.y(hourHeight: hourHeight))
                                    .frame(width: max(40, dayWidth - 8), height: selectionPreview.height(hourHeight: hourHeight))
                                    .allowsHitTesting(false)
                            }

                            ForEach(layouts) { layout in
                                CalendarEventInteractionBlock(
                                    event: layout.event,
                                    displayLocation: displayLocation(layout.event),
                                    timeText: layout.timeText,
                                    compact: layout.height < 52,
                                    continuesFromPreviousDay: layout.continuesFromPreviousDay,
                                    continuesToNextDay: layout.continuesToNextDay,
                                    canEdit: canEdit(layout.event),
                                    dayWidth: dayWidth,
                                    hourHeight: hourHeight,
                                    openDetails: { openDetails(layout.event) },
                                    moveEvent: { dayDelta, minuteDelta in
                                        moveEvent(layout.event, dayDelta, minuteDelta)
                                    },
                                    resizeEvent: { endMinuteDelta in
                                        resizeEvent(layout.event, endMinuteDelta)
                                    }
                                )
                                .frame(width: layout.width(dayWidth: dayWidth), height: layout.height)
                                .offset(
                                    x: gutterWidth + CGFloat(layout.dayIndex) * dayWidth + layout.xOffset(dayWidth: dayWidth),
                                    y: layout.y
                                )
                            }

                            if let indicator = CurrentTimeIndicator.position(days: days, now: now, hourHeight: hourHeight) {
                                CurrentTimeIndicator(width: dayWidth)
                                    .offset(
                                        x: gutterWidth + CGFloat(indicator.dayIndex) * dayWidth,
                                        y: indicator.y
                                    )
                            }
                        }
                        .frame(width: contentWidth, height: gridHeight, alignment: .topLeading)
                    }
                    .onAppear {
                        guard !didInitialScroll else { return }
                        didInitialScroll = true
                        scrollToDefaultHour(using: scrollProxy, animated: false)
                    }
                    .onChange(of: daysScrollKey) { _, _ in
                        scrollToDefaultHour(using: scrollProxy, animated: true)
                    }
                    .overlay(alignment: .topTrailing) {
                        if isShowingToday {
                            Button {
                                scrollToDefaultHour(using: scrollProxy, animated: true)
                            } label: {
                                Label("Now", systemImage: "clock")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .padding(10)
                            .help("Jump to current time")
                        }
                    }
                }
                .background(.thinMaterial)
            }
            .frame(width: geometry.size.width, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
        }
        .frame(minHeight: 560)
    }

    private var currentTimezoneTitle: String {
        TimeZone.current.abbreviation() ?? "Local"
    }

    private var daysScrollKey: String {
        days.map { String(Int($0.timeIntervalSinceReferenceDate)) }.joined(separator: ":")
    }

    private var isShowingToday: Bool {
        days.contains { Calendar.current.isDate($0, inSameDayAs: now) }
    }

    private func defaultScrollHour() -> Int {
        if isShowingToday {
            let currentHour = Calendar.current.component(.hour, from: now)
            return min(20, max(0, currentHour - 1))
        }

        if let firstEvent = timedEvents
            .filter({ event in days.contains { Calendar.current.isDate($0, inSameDayAs: event.startDate) } })
            .min(by: { $0.startDate < $1.startDate }) {
            let firstEventHour = Calendar.current.component(.hour, from: firstEvent.startDate)
            return min(20, max(0, firstEventHour - 1))
        }

        return 8
    }

    private func scrollToDefaultHour(using proxy: ScrollViewProxy, animated: Bool) {
        let anchor = TimeGridScrollAnchor.hour(defaultScrollHour())
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            } else {
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
    }

    private func selectionGesture(dayWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                selectionPreview = selection(from: value.startLocation, to: value.location, dayWidth: dayWidth)
            }
            .onEnded { value in
                guard let selection = selection(from: value.startLocation, to: value.location, dayWidth: dayWidth) else {
                    selectionPreview = nil
                    return
                }

                selectionPreview = nil
                let start = date(for: selection.dayIndex, minute: selection.startMinute)
                let end = date(for: selection.dayIndex, minute: selection.endMinute)
                createEvent(start, end)
            }
    }

    private func selection(from start: CGPoint, to end: CGPoint, dayWidth: CGFloat) -> TimeGridSelection? {
        let startX = start.x - gutterWidth
        guard startX >= 0 else { return nil }

        let rawDayIndex = Int((startX / max(dayWidth, 1)).rounded(.down))
        let dayIndex = min(max(rawDayIndex, 0), max(days.count - 1, 0))
        let startMinute = snappedMinute(for: start.y)
        let endMinute = snappedMinute(for: end.y)

        let lower = min(startMinute, endMinute)
        let upper = max(startMinute, endMinute)
        let selectionEnd = upper == lower ? min(24 * 60, lower + 30) : max(upper, lower + 15)

        return TimeGridSelection(
            dayIndex: dayIndex,
            startMinute: lower,
            endMinute: selectionEnd
        )
    }

    private func snappedMinute(for y: CGFloat) -> Int {
        let rawMinute = y / max(hourHeight, 1) * 60
        let snapped = Int((rawMinute / 15).rounded()) * 15
        return min(24 * 60 - 5, max(0, snapped))
    }

    private func date(for dayIndex: Int, minute: Int) -> Date {
        let day = days[min(max(dayIndex, 0), max(days.count - 1, 0))]
        return Calendar.current.date(byAdding: .minute, value: minute, to: day) ?? day
    }
}

struct CalendarDayHeader: View {
    let day: Date
    let allVisibleEvents: [CalendarEvent]
    let allDayEvents: [CalendarEvent]
    let width: CGFloat
    let openDetails: (CalendarEvent) -> Void
    let canEdit: (CalendarEvent) -> Bool
    let moveEvent: (CalendarEvent, Int, Int) -> Void
    let createAllDayEvent: (Date) -> Void

    @State private var isShowingAllDayEvents = false
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(Self.weekday.string(from: day).uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(Self.dayNumber.string(from: day))
                    .font(.title3.bold())
                    .foregroundStyle(Calendar.current.isDateInToday(day) ? Color.accentColor : Color.primary)

                Spacer(minLength: 4)

                Button {
                    createAllDayEvent(day)
                } label: {
                    Image(systemName: "plus")
                        .font(.caption2.weight(.bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .background(Color.primary.opacity(0.06), in: Circle())
                .help("Create all-day event")
            }

            if allDayEvents.isEmpty {
                Button {
                    createAllDayEvent(day)
                } label: {
                    Text("Add all-day")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(allDayEvents.prefix(3)) { event in
                        allDayEventButton(for: event)
                    }

                    if allDayEvents.count > 3 {
                        Button {
                            isShowingAllDayEvents = true
                        } label: {
                            Text("+\(allDayEvents.count - 3) more")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 7)
                        }
                        .buttonStyle(.plain)
                        .help("Show all all-day events")
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: width, height: 116, alignment: .topLeading)
        .background(Calendar.current.isDateInToday(day) ? Color.accentColor.opacity(0.06) : Color.clear)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 1)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isDropTarget ? Color.accentColor.opacity(0.72) : Color.clear, lineWidth: 2)
                .padding(2)
        )
        .onDrop(of: [.plainText], isTargeted: $isDropTarget, perform: handleDrop)
        .popover(isPresented: $isShowingAllDayEvents, arrowEdge: .top) {
            DayEventsPopover(
                day: day,
                events: allDayEvents.sorted { $0.startDate < $1.startDate },
                titleSuffix: "all-day",
                openDetails: { event in
                    isShowingAllDayEvents = false
                    openDetails(event)
                },
                createEvent: {
                    isShowingAllDayEvents = false
                    createAllDayEvent(day)
                }
            )
        }
    }

    @ViewBuilder
    private func allDayEventButton(for event: CalendarEvent) -> some View {
        let button = Button {
            openDetails(event)
        } label: {
            CalendarEventChipRow(
                event: event,
                isEditable: canEdit(event),
                daySpan: CalendarEventDaySpan(event: event, day: day),
                horizontalPadding: 7,
                colorOpacity: 0.14
            )
        }
        .buttonStyle(.plain)

        if canEdit(event) {
            button
                .onDrag {
                    NSItemProvider(object: CalendarEventDragPayload.make(eventID: event.id) as NSString)
                }
                .help("Drag to move all-day event. Click for details.")
        } else {
            button
                .help("Read-only source event. Click for details.")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = (object as? NSString) as String?,
                  let eventID = CalendarEventDragPayload.eventID(from: text),
                  let event = allVisibleEvents.first(where: { $0.id == eventID }),
                  event.isAllDay,
                  canEdit(event) else { return }

            let sourceDay = Calendar.current.startOfDay(for: event.startDate)
            let destinationDay = Calendar.current.startOfDay(for: day)
            let dayDelta = Calendar.current.dateComponents([.day], from: sourceDay, to: destinationDay).day ?? 0
            guard dayDelta != 0 else { return }

            DispatchQueue.main.async {
                moveEvent(event, dayDelta, 0)
            }
        }

        return true
    }

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    private static let dayNumber: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()
}

struct TimeGridSelection: Equatable {
    let dayIndex: Int
    let startMinute: Int
    let endMinute: Int

    func y(hourHeight: CGFloat) -> CGFloat {
        CGFloat(startMinute) / 60 * hourHeight
    }

    func height(hourHeight: CGFloat) -> CGFloat {
        max(24, CGFloat(endMinute - startMinute) / 60 * hourHeight)
    }
}

struct TimeGridScrollAnchor: Hashable {
    let hour: Int

    static func hour(_ hour: Int) -> TimeGridScrollAnchor {
        TimeGridScrollAnchor(hour: min(23, max(0, hour)))
    }
}

struct TimeGridSelectionPreview: View {
    let selection: TimeGridSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("New event")
                .font(.caption.weight(.bold))
            Text(durationText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.42), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    private var durationText: String {
        let minutes = max(5, selection.endMinute - selection.startMinute)
        if minutes < 60 { return "\(minutes)m" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

struct TimeGridBackground: View {
    let days: [Date]
    let dayWidth: CGFloat
    let gutterWidth: CGFloat
    let hourHeight: CGFloat
    let height: CGFloat
    let now: Date

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(days.indices, id: \.self) { index in
                Rectangle()
                    .fill(Calendar.current.isDateInToday(days[index]) ? Color.accentColor.opacity(0.035) : Color.clear)
                    .frame(width: dayWidth, height: height)
                    .offset(x: gutterWidth + CGFloat(index) * dayWidth)

                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(width: 1, height: height)
                    .offset(x: gutterWidth + CGFloat(index + 1) * dayWidth)
            }

            ForEach(0...24, id: \.self) { hour in
                HStack(spacing: 0) {
                    Text(hourLabel(hour))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: gutterWidth - 8, alignment: .trailing)
                        .padding(.trailing, 8)

                    Rectangle()
                        .fill(hour == 0 ? Color.primary.opacity(0.12) : Color.primary.opacity(0.08))
                        .frame(height: hour == 0 ? 1.2 : 1)
                }
                .frame(height: 18)
                .offset(y: CGFloat(hour) * hourHeight - 9)
            }
        }
        .frame(height: height, alignment: .topLeading)
    }

    private func hourLabel(_ hour: Int) -> String {
        guard hour < 24 else { return "" }
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return Formatters.time.string(from: date)
    }
}

struct CalendarEventBlock: View {
    let event: CalendarEvent
    let displayLocation: String?
    let timeText: String
    let compact: Bool
    let continuesFromPreviousDay: Bool
    let continuesToNextDay: Bool
    let canEdit: Bool
    let openDetails: () -> Void

    var body: some View {
        Button(action: openDetails) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color(nsColor: event.calendarColor))
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                    HStack(spacing: 4) {
                        if continuesFromPreviousDay {
                            Image(systemName: "arrow.left")
                                .help("Continues from previous day")
                        }

                        Text(event.title)
                            .lineLimit(compact ? 1 : 2)

                        if let badge = event.gridResponseBadge {
                            CalendarGridResponseBadgeView(
                                badge: badge,
                                compact: true,
                                iconOnly: compact
                            )
                        }

                        if !event.availability.isBusy {
                            Image(systemName: event.availability.symbolName)
                                .help("Show as \(event.availability.title)")
                        }

                        if continuesToNextDay {
                            Image(systemName: "arrow.right")
                                .help("Continues to next day")
                        }
                    }
                    .font(compact ? .caption.weight(.bold) : .callout.weight(.bold))

                    if !compact {
                        Text(timeText)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        HStack(spacing: 5) {
                            Image(systemName: event.meetingMethod.symbolName)
                            Text(event.gridVenueText(displayLocation: displayLocation))
                                .lineLimit(1)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, compact ? 4 : 7)
                .padding(.bottom, canEdit ? (compact ? 8 : 11) : (compact ? 4 : 7))

                Spacer(minLength: 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: event.calendarColor).opacity(backgroundOpacity), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    Color(nsColor: event.calendarColor).opacity(strokeOpacity),
                    style: StrokeStyle(lineWidth: 1, dash: event.availability.isBusy ? [] : [4, 3])
                )
        )
        .overlay(alignment: .topTrailing) {
            if !canEdit {
                Image(systemName: "lock.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .padding(5)
                    .help("Read-only source event. Open details to edit in its source.")
            }
        }
        .clipped()
        .help(canEdit ? "Drag to move. Pull the bottom edge to resize." : "\(event.title) is read-only in Working Calendar.")
    }

    private var backgroundOpacity: Double {
        event.availability.isBusy ? 0.17 : 0.07
    }

    private var strokeOpacity: Double {
        event.availability.isBusy ? 0.35 : 0.42
    }
}

struct CalendarEventInteractionBlock: View {
    let event: CalendarEvent
    let displayLocation: String?
    let timeText: String
    let compact: Bool
    let continuesFromPreviousDay: Bool
    let continuesToNextDay: Bool
    let canEdit: Bool
    let dayWidth: CGFloat
    let hourHeight: CGFloat
    let openDetails: () -> Void
    let moveEvent: (Int, Int) -> Void
    let resizeEvent: (Int) -> Void

    @State private var movePreview: CGSize = .zero
    @State private var resizePreviewHeight: CGFloat = 0

    var body: some View {
        CalendarEventBlock(
            event: event,
            displayLocation: displayLocation,
            timeText: timeText,
            compact: compact,
            continuesFromPreviousDay: continuesFromPreviousDay,
            continuesToNextDay: continuesToNextDay,
            canEdit: canEdit,
            openDetails: openDetails
        )
        .offset(movePreview)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if canEdit {
                CalendarResizeHandle()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                    .gesture(resizeGesture)
            }
        }
        .overlay(alignment: .bottom) {
            if resizePreviewHeight != 0 {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.22))
                    .frame(height: max(2, abs(resizePreviewHeight)))
                    .offset(y: resizePreviewHeight > 0 ? resizePreviewHeight / 2 : resizePreviewHeight / 2)
                    .allowsHitTesting(false)
            }
        }
        .opacity(movePreview == .zero && resizePreviewHeight == 0 ? 1 : 0.86)
        .scaleEffect(movePreview == .zero && resizePreviewHeight == 0 ? 1 : 1.01)
        .animation(.easeOut(duration: 0.12), value: movePreview)
        .animation(.easeOut(duration: 0.12), value: resizePreviewHeight)
        .gesture(canEdit ? moveGesture : nil)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                movePreview = snappedPreview(for: value.translation)
            }
            .onEnded { value in
                let snapped = snappedMove(for: value.translation)
                movePreview = .zero
                guard snapped.dayDelta != 0 || snapped.minuteDelta != 0 else { return }
                moveEvent(snapped.dayDelta, snapped.minuteDelta)
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                resizePreviewHeight = snappedResizeHeight(for: value.translation.height)
            }
            .onEnded { value in
                let minuteDelta = snappedMinuteDelta(forVerticalTranslation: value.translation.height)
                resizePreviewHeight = 0
                guard minuteDelta != 0 else { return }
                resizeEvent(minuteDelta)
            }
    }

    private func snappedPreview(for translation: CGSize) -> CGSize {
        let snapped = snappedMove(for: translation)
        return CGSize(
            width: CGFloat(snapped.dayDelta) * dayWidth,
            height: CGFloat(snapped.minuteDelta) / 60 * hourHeight
        )
    }

    private func snappedMove(for translation: CGSize) -> (dayDelta: Int, minuteDelta: Int) {
        let dayDelta = Int((translation.width / max(dayWidth, 1)).rounded())
        return (
            dayDelta,
            snappedMinuteDelta(forVerticalTranslation: translation.height)
        )
    }

    private func snappedResizeHeight(for translation: CGFloat) -> CGFloat {
        CGFloat(snappedMinuteDelta(forVerticalTranslation: translation)) / 60 * hourHeight
    }

    private func snappedMinuteDelta(forVerticalTranslation translation: CGFloat) -> Int {
        let rawMinutes = translation / max(hourHeight, 1) * 60
        return Int((rawMinutes / 15).rounded()) * 15
    }
}

struct CalendarResizeHandle: View {
    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.22))
            .frame(width: 34, height: 4)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .help("Drag to resize")
    }
}

struct CurrentTimeIndicator: View {
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
                .offset(x: -3)
            Rectangle()
                .fill(Color.red)
                .frame(width: max(0, width - 4), height: 1.5)
        }
        .frame(width: width, height: 8, alignment: .leading)
    }

    static func position(days: [Date], now: Date, hourHeight: CGFloat) -> (dayIndex: Int, y: CGFloat)? {
        guard let dayIndex = days.firstIndex(where: { Calendar.current.isDate($0, inSameDayAs: now) }) else {
            return nil
        }

        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minutes = CGFloat((components.hour ?? 0) * 60 + (components.minute ?? 0))
        return (dayIndex, minutes / 60 * hourHeight)
    }
}

struct MonthCalendarGrid: View {
    let monthDate: Date
    let days: [Date]
    let events: [CalendarEvent]
    let openDetails: (CalendarEvent) -> Void
    let canEdit: (CalendarEvent) -> Bool
    let moveEvent: (CalendarEvent, Date) -> Void
    let createEvent: (Date) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(CalendarGridDates.weekdaySymbols, id: \.self) { symbol in
                    Text(symbol.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(days, id: \.timeIntervalSinceReferenceDate) { day in
                    MonthDayCell(
                        day: day,
                        isInFocusedMonth: Calendar.current.isDate(day, equalTo: monthDate, toGranularity: .month),
                        allVisibleEvents: events,
                        events: CalendarGridEventOrdering.sorted(
                            events.filter { $0.overlaps(day: day) },
                            in: day
                        ),
                        openDetails: openDetails,
                        canEdit: canEdit,
                        moveEvent: moveEvent,
                        createEvent: createEvent
                    )
                }
            }
        }
    }
}

struct MonthDayCell: View {
    let day: Date
    let isInFocusedMonth: Bool
    let allVisibleEvents: [CalendarEvent]
    let events: [CalendarEvent]
    let openDetails: (CalendarEvent) -> Void
    let canEdit: (CalendarEvent) -> Bool
    let moveEvent: (CalendarEvent, Date) -> Void
    let createEvent: (Date) -> Void

    @State private var isShowingDayEvents = false
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(Self.dayNumber.string(from: day))
                    .font(.callout.weight(.bold))
                    .foregroundStyle(dayNumberColor)
                    .frame(width: 28, height: 28)
                    .background(todayBackground, in: Circle())

                Spacer()

                Button {
                    createEvent(day)
                } label: {
                    Image(systemName: "plus")
                        .font(.caption2.weight(.bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .background(Color.primary.opacity(0.06), in: Circle())
                .help("Create event")
                .opacity(isInFocusedMonth ? 1 : 0.45)

                if !events.isEmpty {
                    Button {
                        isShowingDayEvents = true
                    } label: {
                        Text("\(events.count)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Show all events")
                }
            }

            VStack(spacing: 4) {
                ForEach(events.prefix(4)) { event in
                    monthEventButton(for: event)
                }

                if events.count > 4 {
                    Button {
                        isShowingDayEvents = true
                    } label: {
                        Text("+ \(events.count - 4) more")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.plain)
                    .help("Show all events")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(minHeight: 116, alignment: .topLeading)
        .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isDropTarget ? 2 : 1)
        )
        .opacity(isInFocusedMonth ? 1 : 0.58)
        .onDrop(of: [.plainText], isTargeted: $isDropTarget, perform: handleDrop)
        .popover(isPresented: $isShowingDayEvents, arrowEdge: .trailing) {
            DayEventsPopover(
                day: day,
                events: CalendarGridEventOrdering.sorted(events, in: day),
                openDetails: { event in
                    isShowingDayEvents = false
                    openDetails(event)
                },
                createEvent: {
                    isShowingDayEvents = false
                    createEvent(day)
                }
            )
        }
    }

    @ViewBuilder
    private func monthEventButton(for event: CalendarEvent) -> some View {
        let button = Button {
            openDetails(event)
        } label: {
            CalendarEventChipRow(
                event: event,
                isEditable: canEdit(event),
                daySpan: CalendarEventDaySpan(event: event, day: day),
                timePrefix: chipTimePrefix(for: event)
            )
        }
        .buttonStyle(.plain)

        if canEdit(event) {
            button
                .onDrag {
                    NSItemProvider(object: CalendarEventDragPayload.make(eventID: event.id) as NSString)
                }
                .help("Drag to move. Click for details.")
        } else {
            button
                .help("Read-only source event. Click for details.")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = (object as? NSString) as String?,
                  let eventID = CalendarEventDragPayload.eventID(from: text),
                  let event = allVisibleEvents.first(where: { $0.id == eventID }),
                  canEdit(event) else { return }

            DispatchQueue.main.async {
                moveEvent(event, day)
            }
        }

        return true
    }

    private var dayNumberColor: Color {
        if Calendar.current.isDateInToday(day) { return .white }
        return isInFocusedMonth ? .primary : .secondary
    }

    private var todayBackground: Color {
        Calendar.current.isDateInToday(day) ? .accentColor : .clear
    }

    private var borderColor: Color {
        if isDropTarget { return .accentColor.opacity(0.72) }
        if Calendar.current.isDateInToday(day) { return Color.accentColor.opacity(0.34) }
        return Color.primary.opacity(0.07)
    }

    private var backgroundStyle: some ShapeStyle {
        if Calendar.current.isDateInToday(day) {
            return AnyShapeStyle(Color.accentColor.opacity(0.06))
        }

        return AnyShapeStyle(.thinMaterial)
    }

    private func chipTimePrefix(for event: CalendarEvent) -> String? {
        guard !event.isAllDay else { return nil }
        let daySpan = CalendarEventDaySpan(event: event, day: day)
        guard !daySpan.continuesFromPreviousDay else { return nil }
        return Formatters.time.string(from: event.startDate)
    }

    private static let dayNumber: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()
}

struct CalendarEventChipRow: View {
    let event: CalendarEvent
    let isEditable: Bool
    var daySpan: CalendarEventDaySpan = .singleDay
    var timePrefix: String? = nil
    var horizontalPadding: CGFloat = 6
    var colorOpacity: Double = 0.12

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color(nsColor: event.calendarColor))
                .frame(width: 6, height: 6)

            if daySpan.continuesFromPreviousDay {
                Image(systemName: "arrow.left")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary.opacity(0.78))
                    .help("Continues from previous day")
            }

            if !event.availability.isBusy {
                Image(systemName: event.availability.symbolName)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.teal)
                    .help("Show as \(event.availability.title)")
            }

            if let timePrefix {
                Text(timePrefix)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(event.title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)

            if daySpan.continuesToNextDay {
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary.opacity(0.78))
                    .help("Continues to next day")
            }

            Spacer(minLength: 0)

            if let badge = event.gridResponseBadge {
                CalendarGridResponseBadgeView(badge: badge, compact: true, iconOnly: true)
            }

            if !isEditable {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 4)
        .background(Color(nsColor: event.calendarColor).opacity(effectiveColorOpacity), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var effectiveColorOpacity: Double {
        event.availability.isBusy ? colorOpacity : min(colorOpacity, 0.07)
    }
}

struct CalendarGridResponseBadgeView: View {
    let badge: CalendarGridResponseBadge
    var compact = false
    var iconOnly = false

    var body: some View {
        Group {
            if iconOnly {
                Image(systemName: badge.symbolName)
                    .font(.system(size: compact ? 9 : 11, weight: .bold))
                    .foregroundStyle(Color(nsColor: badge.color))
                    .help(badge.title)
            } else {
                Label(compact ? badge.compactTitle : badge.title, systemImage: badge.symbolName)
                    .font((compact ? Font.caption2 : Font.caption).weight(.bold))
                    .lineLimit(1)
                    .foregroundStyle(Color(nsColor: badge.color))
                    .padding(.horizontal, compact ? 5 : 7)
                    .padding(.vertical, compact ? 2 : 3)
                    .background(Color(nsColor: badge.color).opacity(0.14), in: Capsule())
                    .help(badge.requiresAttention ? "\(badge.title) - response needed" : badge.title)
            }
        }
        .accessibilityLabel(badge.title)
    }
}

struct CalendarEventDaySpan {
    var continuesFromPreviousDay: Bool
    var continuesToNextDay: Bool

    static let singleDay = CalendarEventDaySpan(
        continuesFromPreviousDay: false,
        continuesToNextDay: false
    )

    init(continuesFromPreviousDay: Bool, continuesToNextDay: Bool) {
        self.continuesFromPreviousDay = continuesFromPreviousDay
        self.continuesToNextDay = continuesToNextDay
    }

    init(event: CalendarEvent, day: Date) {
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 3600)
        continuesFromPreviousDay = event.startDate < dayStart
        continuesToNextDay = event.endDate > dayEnd
    }
}

private enum CalendarGridEventOrdering {
    static func sorted(_ events: [CalendarEvent], in day: Date) -> [CalendarEvent] {
        events.sorted { left, right in
            ordered(left, before: right, in: day)
        }
    }

    private static func ordered(_ left: CalendarEvent, before right: CalendarEvent, in day: Date) -> Bool {
        let leftKey = key(for: left, in: day)
        let rightKey = key(for: right, in: day)

        if leftKey.group != rightKey.group { return leftKey.group < rightKey.group }
        if leftKey.visibleStart != rightKey.visibleStart { return leftKey.visibleStart < rightKey.visibleStart }
        if leftKey.visibleDuration != rightKey.visibleDuration { return leftKey.visibleDuration > rightKey.visibleDuration }

        let titleOrder = left.title.localizedCaseInsensitiveCompare(right.title)
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }

        return left.id < right.id
    }

    private static func key(for event: CalendarEvent, in day: Date) -> SortKey {
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 3600)
        let visibleStart = max(event.startDate, dayStart)
        let visibleEnd = min(event.endDate, dayEnd)
        let spansDayBoundary = event.startDate < dayStart || event.endDate > dayEnd
        let group: Int

        if event.isAllDay {
            group = 0
        } else if spansDayBoundary {
            group = 1
        } else {
            group = 2
        }

        return SortKey(
            group: group,
            visibleStart: visibleStart,
            visibleDuration: max(0, visibleEnd.timeIntervalSince(visibleStart))
        )
    }

    private struct SortKey {
        let group: Int
        let visibleStart: Date
        let visibleDuration: TimeInterval
    }
}

enum CalendarEventDragPayload {
    private static let prefix = "working-calendar-event:"

    static func make(eventID: String) -> String {
        "\(prefix)\(eventID)"
    }

    static func eventID(from text: String) -> String? {
        guard text.hasPrefix(prefix) else { return nil }
        let id = String(text.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }
}

struct DayEventsPopover: View {
    let day: Date
    let events: [CalendarEvent]
    var titleSuffix: String = "events"
    let openDetails: (CalendarEvent) -> Void
    let createEvent: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.titleFormatter.string(from: day))
                        .font(.headline)
                    Text("\(events.count) \(titleSuffix)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: createEvent) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .help("Create event")
            }

            Divider()

            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(events) { event in
                        Button {
                            openDetails(event)
                        } label: {
                            DayPopoverEventRow(event: event)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: 360)
        }
        .padding(14)
        .frame(width: 360)
    }

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()
}

struct DayPopoverEventRow: View {
    let event: CalendarEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(nsColor: event.calendarColor))
                .frame(width: 5, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(event.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)

                    if let badge = event.gridResponseBadge {
                        CalendarGridResponseBadgeView(badge: badge, compact: true)
                    }
                }

                HStack(spacing: 6) {
                    Text(timeText)
                    Text("·")
                    Label(event.meetingMethod.title, systemImage: event.meetingMethod.symbolName)
                    Text("·")
                    Text(event.calendarTitle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: event.calendarColor).opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var timeText: String {
        Formatters.eventRange(event)
    }
}

struct CalendarTimedEventLayout: Identifiable {
    let id: String
    let event: CalendarEvent
    let dayIndex: Int
    let columnIndex: Int
    let columnCount: Int
    let timeText: String
    let continuesFromPreviousDay: Bool
    let continuesToNextDay: Bool
    let startMinute: Int
    let endMinute: Int
    let hourHeight: CGFloat

    var y: CGFloat {
        CGFloat(startMinute) / 60 * hourHeight
    }

    var height: CGFloat {
        max(24, CGFloat(max(15, endMinute - startMinute)) / 60 * hourHeight)
    }

    func xOffset(dayWidth: CGFloat) -> CGFloat {
        let laneWidth = dayWidth / CGFloat(max(columnCount, 1))
        return CGFloat(columnIndex) * laneWidth + 4
    }

    func width(dayWidth: CGFloat) -> CGFloat {
        let laneWidth = dayWidth / CGFloat(max(columnCount, 1))
        return max(42, laneWidth - 8)
    }

    static func make(days: [Date], events: [CalendarEvent], hourHeight: CGFloat) -> [CalendarTimedEventLayout] {
        days.enumerated().flatMap { dayIndex, day in
            makeForDay(day, dayIndex: dayIndex, events: events, hourHeight: hourHeight)
        }
    }

    private static func makeForDay(
        _ day: Date,
        dayIndex: Int,
        events: [CalendarEvent],
        hourHeight: CGFloat
    ) -> [CalendarTimedEventLayout] {
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 3600)
        let segments = events
            .filter { $0.endDate > dayStart && $0.startDate < dayEnd }
            .map { event in
                let segmentStart = max(event.startDate, dayStart)
                let segmentEnd = min(event.endDate, dayEnd)
                return TimedSegment(
                    event: event,
                    timeText: "\(Formatters.time.string(from: segmentStart)) - \(Formatters.time.string(from: segmentEnd))",
                    continuesFromPreviousDay: event.startDate < dayStart,
                    continuesToNextDay: event.endDate > dayEnd,
                    startMinute: minuteOffset(segmentStart, from: dayStart),
                    endMinute: minuteOffset(segmentEnd, from: dayStart)
                )
            }
            .sorted(by: { (left: TimedSegment, right: TimedSegment) in
                if left.startMinute == right.startMinute {
                    return left.endMinute > right.endMinute
                }
                return left.startMinute < right.startMinute
            })

        var layouts: [CalendarTimedEventLayout] = []
        var cluster: [TimedSegment] = []
        var clusterEnd = -1

        func flushCluster() {
            guard !cluster.isEmpty else { return }
            layouts.append(contentsOf: assignColumns(cluster, dayIndex: dayIndex, hourHeight: hourHeight))
            cluster.removeAll()
            clusterEnd = -1
        }

        for segment in segments {
            if !cluster.isEmpty && segment.startMinute >= clusterEnd {
                flushCluster()
            }
            cluster.append(segment)
            clusterEnd = max(clusterEnd, segment.endMinute)
        }

        flushCluster()
        return layouts
    }

    private static func assignColumns(
        _ segments: [TimedSegment],
        dayIndex: Int,
        hourHeight: CGFloat
    ) -> [CalendarTimedEventLayout] {
        var columnEndMinutes: [Int] = []
        var assignments: [(segment: TimedSegment, column: Int)] = []

        for segment in segments {
            if let reusableColumn = columnEndMinutes.firstIndex(where: { $0 <= segment.startMinute }) {
                columnEndMinutes[reusableColumn] = segment.endMinute
                assignments.append((segment, reusableColumn))
            } else {
                columnEndMinutes.append(segment.endMinute)
                assignments.append((segment, columnEndMinutes.count - 1))
            }
        }

        let columnCount = max(columnEndMinutes.count, 1)
        return assignments.map { assignment in
            CalendarTimedEventLayout(
                id: "\(assignment.segment.event.id)-\(dayIndex)",
                event: assignment.segment.event,
                dayIndex: dayIndex,
                columnIndex: assignment.column,
                columnCount: columnCount,
                timeText: assignment.segment.timeText,
                continuesFromPreviousDay: assignment.segment.continuesFromPreviousDay,
                continuesToNextDay: assignment.segment.continuesToNextDay,
                startMinute: assignment.segment.startMinute,
                endMinute: assignment.segment.endMinute,
                hourHeight: hourHeight
            )
        }
    }

    private static func minuteOffset(_ date: Date, from start: Date) -> Int {
        max(0, min(24 * 60, Int(date.timeIntervalSince(start) / 60)))
    }

    private struct TimedSegment {
        let event: CalendarEvent
        let timeText: String
        let continuesFromPreviousDay: Bool
        let continuesToNextDay: Bool
        let startMinute: Int
        let endMinute: Int
    }
}

private enum CalendarGridDates {
    static func visibleInterval(for date: Date, mode: CalendarGridMode) -> DateInterval {
        let calendar = Calendar.current
        switch mode {
        case .day:
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 3600)
            return DateInterval(start: start, end: end)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date) ?? fallbackInterval(for: date, days: 7)
        case .month:
            return calendar.dateInterval(of: .month, for: date) ?? fallbackInterval(for: date, days: 31)
        }
    }

    static func fetchInterval(for date: Date, mode: CalendarGridMode) -> DateInterval {
        let calendar = Calendar.current
        let visible = visibleDays(for: date, mode: mode)
        guard let first = visible.first, let last = visible.last else {
            return visibleInterval(for: date, mode: mode)
        }

        let start = calendar.startOfDay(for: first)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)) ?? last.addingTimeInterval(24 * 3600)
        return DateInterval(start: start, end: end)
    }

    static func visibleDays(for date: Date, mode: CalendarGridMode) -> [Date] {
        let calendar = Calendar.current
        switch mode {
        case .day:
            return [calendar.startOfDay(for: date)]
        case .week:
            let interval = visibleInterval(for: date, mode: .week)
            return days(from: interval.start, to: interval.end)
        case .month:
            let monthInterval = visibleInterval(for: date, mode: .month)
            let firstWeekStart = calendar.dateInterval(of: .weekOfYear, for: monthInterval.start)?.start ?? monthInterval.start
            let lastMonthDay = monthInterval.end.addingTimeInterval(-1)
            let lastWeekEnd = calendar.dateInterval(of: .weekOfYear, for: lastMonthDay)?.end ?? monthInterval.end
            return days(from: firstWeekStart, to: lastWeekEnd)
        }
    }

    static func title(for date: Date, mode: CalendarGridMode) -> String {
        switch mode {
        case .day:
            return dayTitle.string(from: date)
        case .week:
            let interval = visibleInterval(for: date, mode: .week)
            let end = interval.end.addingTimeInterval(-1)
            return "\(shortDateTitle.string(from: interval.start)) - \(shortDateTitle.string(from: end))"
        case .month:
            return monthTitle.string(from: date)
        }
    }

    static var weekdaySymbols: [String] {
        let formatter = DateFormatter()
        let symbols = formatter.shortStandaloneWeekdaySymbols ?? formatter.shortWeekdaySymbols ?? []
        let firstWeekday = Calendar.current.firstWeekday - 1
        guard symbols.count == 7 else { return symbols }
        return Array(symbols[firstWeekday...] + symbols[..<firstWeekday])
    }

    private static func days(from start: Date, to end: Date) -> [Date] {
        var result: [Date] = []
        var cursor = Calendar.current.startOfDay(for: start)
        while cursor < end {
            result.append(cursor)
            cursor = Calendar.current.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(24 * 3600)
        }
        return result
    }

    private static func fallbackInterval(for date: Date, days: Int) -> DateInterval {
        let start = Calendar.current.startOfDay(for: date)
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(TimeInterval(days * 24 * 3600))
        return DateInterval(start: start, end: end)
    }

    private static let dayTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()

    private static let shortDateTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let monthTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()
}

private extension CalendarEvent {
    func overlaps(day: Date) -> Bool {
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 3600)
        return endDate > dayStart && startDate < dayEnd
    }
}
