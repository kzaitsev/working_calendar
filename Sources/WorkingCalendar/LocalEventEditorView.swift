import SwiftUI

private enum LocalOrdinalRecurrenceMode: String, CaseIterable, Identifiable {
    case date
    case weekday

    var id: String { rawValue }

    var title: String {
        switch self {
        case .date: return "Same date"
        case .weekday: return "Weekday pattern"
        }
    }
}

struct LocalEventEditorView: View {
    @State private var draft: LocalEventDraft
    let calendars: [LocalCalendar]
    let backendInfoForCalendarID: (String) -> CalendarBackendInfo
    let conflictsForDraft: (LocalEventDraft) -> [CalendarEvent]
    let save: (LocalEventDraft) -> Void
    let cancel: () -> Void

    init(
        draft: LocalEventDraft,
        calendars: [LocalCalendar],
        backendInfoForCalendarID: @escaping (String) -> CalendarBackendInfo = { _ in .local },
        conflictsForDraft: @escaping (LocalEventDraft) -> [CalendarEvent] = { _ in [] },
        save: @escaping (LocalEventDraft) -> Void,
        cancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.calendars = calendars
        self.backendInfoForCalendarID = backendInfoForCalendarID
        self.conflictsForDraft = conflictsForDraft
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(editorTitle)
                    .font(.title2.bold())
                Spacer()
                Button("Cancel", action: cancel)
                Button(saveButtonTitle) {
                    save(normalizedDraft)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .help(saveButtonHelp)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LocalEventEditorRow(label: "Title") {
                        TextField("Event title", text: $draft.title)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }

                    LocalEventEditorRow(label: "Calendar") {
                        Picker("", selection: $draft.calendarID) {
                            ForEach(calendars) { calendar in
                                HStack {
                                    Circle()
                                        .fill(Color(nsColor: calendar.color))
                                        .frame(width: 8, height: 8)
                                    Text(calendar.title)
                                }
                                .tag(calendar.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                    }

                    LocalEventEditorBackendStrip(info: selectedBackendInfo)

                    Toggle("All-day", isOn: $draft.isAllDay)
                        .toggleStyle(.checkbox)

                    LocalEventEditorRow(label: "Show As") {
                        Picker("", selection: $draft.availability) {
                            ForEach(CalendarEventAvailability.allCases) { availability in
                                Label(availability.title, systemImage: availability.symbolName)
                                    .tag(availability)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }

                    LocalEventEditorRow(label: "Privacy") {
                        Picker("", selection: $draft.privacy) {
                            ForEach(CalendarEventPrivacy.allCases) { privacy in
                                Label(privacy.title, systemImage: privacy.symbolName)
                                    .tag(privacy)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    LocalEventEditorRow(label: "Importance") {
                        Picker("", selection: $draft.importance) {
                            ForEach(CalendarEventImportance.allCases) { importance in
                                Label(importance.title, systemImage: importance.symbolName)
                                    .tag(importance)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    LocalEventEditorRow(label: "Time Zone") {
                        Picker("", selection: $draft.timeZoneIdentifier) {
                            ForEach(Self.timeZoneIdentifiers, id: \.self) { identifier in
                                Text(identifier).tag(identifier)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                    }

                    LocalEventEditorRow(label: "Starts") {
                        DatePicker(
                            "",
                            selection: $draft.startDate,
                            displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute]
                        )
                        .labelsHidden()
                        .environment(\.timeZone, selectedTimeZone)
                    }

                    LocalEventEditorRow(label: "Ends") {
                        DatePicker(
                            "",
                            selection: $draft.endDate,
                            displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute]
                        )
                        .labelsHidden()
                        .environment(\.timeZone, selectedTimeZone)
                    }

                    let conflicts = conflictingEvents
                    if !conflicts.isEmpty {
                        LocalEventConflictWarning(events: conflicts)
                    }

                    if draft.isDetachedOccurrenceDraft {
                        LocalEventEditorRow(label: "Scope") {
                            Label("This occurrence only", systemImage: "calendar.badge.clock")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        LocalEventEditorRow(label: "Repeat") {
                            HStack(spacing: 12) {
                                Picker("", selection: $draft.recurrenceFrequency) {
                                    ForEach(LocalRecurrenceFrequency.allCases) { frequency in
                                        Text(frequency.title).tag(frequency)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 150)

                                if draft.recurrenceFrequency != .none {
                                    Stepper(
                                        "Every \(draft.recurrenceInterval) \(draft.recurrenceFrequency.intervalTitle(count: draft.recurrenceInterval))",
                                        value: $draft.recurrenceInterval,
                                        in: 1...30
                                    )
                                    .frame(width: 210, alignment: .leading)
                                }
                            }
                        }

                        if draft.recurrenceFrequency != .none {
                            if draft.recurrenceFrequency == .weekly {
                                LocalEventEditorRow(label: "Repeat on") {
                                    LocalWeekdayPickerView(selectedWeekdays: $draft.recurrenceWeekdays)
                                }
                            }

                            if supportsOrdinalRecurrence(draft.recurrenceFrequency) {
                                LocalEventEditorRow(label: "Repeat by") {
                                    HStack(spacing: 10) {
                                        Picker("", selection: ordinalRecurrenceModeBinding) {
                                            ForEach(LocalOrdinalRecurrenceMode.allCases) { mode in
                                                Text(mode.title).tag(mode)
                                            }
                                        }
                                        .pickerStyle(.segmented)
                                        .labelsHidden()
                                        .frame(width: 250)

                                        if ordinalRecurrenceModeBinding.wrappedValue == .weekday {
                                            Picker("", selection: recurrenceOrdinalBinding) {
                                                ForEach(ordinalOptions, id: \.self) { ordinal in
                                                    Text(ordinalTitle(ordinal))
                                                        .tag(ordinal)
                                                        .disabled(isOrdinalUnsupportedForSelectedBackend(ordinal))
                                                }
                                            }
                                            .labelsHidden()
                                            .frame(width: 126)

                                            Picker("", selection: recurrenceOrdinalWeekdayBinding) {
                                                ForEach(orderedWeekdays, id: \.self) { weekday in
                                                    Text(weekdayName(weekday)).tag(weekday)
                                                }
                                            }
                                            .labelsHidden()
                                            .frame(width: 138)
                                        } else {
                                            Text(dateRecurrenceSummary)
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }

                                if ordinalRecurrenceModeBinding.wrappedValue == .weekday {
                                    LocalEventEditorRow(label: "") {
                                        Text(ordinalRecurrenceSummary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                }
                            }

                            LocalEventEditorRow(label: "Repeat end") {
                                HStack(spacing: 12) {
                                    Toggle("Ends", isOn: recurrenceEndsBinding)
                                        .toggleStyle(.checkbox)

                                    if draft.recurrenceEndDate != nil {
                                        DatePicker(
                                            "",
                                            selection: recurrenceEndDateBinding,
                                            displayedComponents: [.date]
                                        )
                                        .labelsHidden()
                                    } else {
                                        Text("Never")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                        }

                        if let warning = recurrenceCompatibilityWarning {
                            LocalEventEditorRow(label: "") {
                                LocalEventEditorValidationWarning(message: warning)
                            }
                        }
                    }

                    Divider()

                    LocalEventEditorRow(label: "Location") {
                        TextField("Room, address, Zoom, Google Meet...", text: $draft.location)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }

                    LocalEventEditorRow(label: "URL") {
                        TextField("https://meet.google.com/...", text: $draft.urlString)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }

                    LocalEventEditorRow(label: "Categories") {
                        TextField("customer, prod, hiring", text: categoriesTextBinding)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }

                    LocalEventEditorRow(label: "Reminders") {
                        TextField("5, 15, 60", text: remindersTextBinding)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }

                    Divider()

                    LocalEventEditorRow(label: "Organizer") {
                        HStack(spacing: 8) {
                            TextField("Name", text: $draft.organizerName)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                            TextField("email@example.com", text: $draft.organizerEmail)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }

                    LocalAttendeesEditorView(attendees: $draft.attendees)

                    LocalEventEditorRow(label: "My response") {
                        Picker("", selection: $draft.myResponseStatus) {
                            ForEach(responseStatusOptions) { status in
                                Text(responseStatusTitle(status)).tag(status)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notes")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)

                        TextEditor(text: $draft.notes)
                            .font(.callout)
                            .frame(minHeight: 120)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
            .frame(maxHeight: 660)
        }
        .padding(24)
        .frame(width: 640)
        .onAppear {
            normalizeRecurrenceWeekdays()
            normalizeOrdinalRecurrenceForCurrentFrequency()
        }
        .onChange(of: draft.startDate) { oldValue, newValue in
            let previousDuration = max(5 * 60, draft.endDate.timeIntervalSince(oldValue))
            if draft.endDate <= newValue {
                draft.endDate = newValue.addingTimeInterval(previousDuration)
            }
            normalizeRecurrenceWeekdays()
            alignOrdinalRecurrenceToStartDate()
        }
        .onChange(of: draft.isAllDay) { _, isAllDay in
            if isAllDay {
                draft.startDate = Calendar.current.startOfDay(for: draft.startDate)
                draft.endDate = Calendar.current.date(byAdding: .day, value: 1, to: draft.startDate) ?? draft.startDate.addingTimeInterval(24 * 3600)
            }
        }
        .onChange(of: draft.recurrenceFrequency) { _, frequency in
            if frequency == .none {
                draft.recurrenceEndDate = nil
                draft.recurrenceInterval = 1
                draft.recurrenceWeekdays = []
                draft.recurrenceWeekStart = nil
                draft.recurrenceSetPositions = []
                clearOrdinalRecurrence()
                draft.recurrenceMonthDay = nil
                draft.recurrenceMonths = []
            } else if frequency == .weekly {
                normalizeRecurrenceWeekdays()
                clearOrdinalRecurrence()
                draft.recurrenceMonthDay = nil
                draft.recurrenceMonths = []
            } else {
                draft.recurrenceInterval = max(1, draft.recurrenceInterval)
                draft.recurrenceWeekdays = []
                draft.recurrenceWeekStart = nil
                draft.recurrenceSetPositions = []
                draft.recurrenceMonths = normalizedRecurrenceMonths(draft.recurrenceMonths, frequency: frequency)
                normalizeOrdinalRecurrenceForCurrentFrequency()
            }
        }
        .onChange(of: draft.attendees) { _, _ in
            normalizeResponseStatusForAttendees()
        }
    }

    private var saveButtonTitle: String {
        conflictingEvents.isEmpty ? "Save" : "Save Anyway"
    }

    private var saveButtonHelp: String {
        if let blockingMessage = blockingValidationMessage {
            return blockingMessage
        }
        return conflictingEvents.isEmpty
            ? "Save event"
            : "Save event even though it overlaps another event"
    }

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && blockingValidationMessage == nil
    }

    private var editorTitle: String {
        if draft.eventID == nil { return "New Event" }
        if draft.isDetachedOccurrenceDraft { return "Edit Occurrence" }
        return "Edit Event"
    }

    private var selectedTimeZone: TimeZone {
        TimeZone(identifier: draft.timeZoneIdentifier) ?? .current
    }

    private var selectedBackendInfo: CalendarBackendInfo {
        backendInfoForCalendarID(draft.calendarID)
    }

    private var hasAttendees: Bool {
        draft.attendees.contains { !$0.isBlank }
    }

    private var responseStatusOptions: [EventResponseStatus] {
        hasAttendees
            ? [.pending, .accepted, .tentative, .declined]
            : [.notInvited, .accepted, .tentative, .declined]
    }

    private var categoriesTextBinding: Binding<String> {
        Binding(
            get: { draft.categories.joined(separator: ", ") },
            set: { draft.categories = eventCategories(from: $0) }
        )
    }

    private var remindersTextBinding: Binding<String> {
        Binding(
            get: { draft.reminderOffsets.map(String.init).joined(separator: ", ") },
            set: { draft.reminderOffsets = reminderOffsets(from: $0) }
        )
    }

    private var blockingValidationMessage: String? {
        recurrenceCompatibilityWarning
    }

    private var recurrenceCompatibilityWarning: String? {
        if selectedBackendInfo.sourceKind == .googleCalendar,
           let reminderOffsets = unsupportedGoogleReminderOffsets {
            return "Google Calendar can save at most 5 reminders. This event has reminders \(reminderOffsets.map(String.init).joined(separator: ", ")) minutes before start."
        }

        guard selectedBackendInfo.sourceKind == .microsoft365 else {
            return nil
        }

        if draft.hasAdditionalOccurrences {
            return "Microsoft 365 cannot save recurrence rules with extra RDATE occurrences. Move this event to a local, Google, or CalDAV calendar before editing it."
        }

        if let reminderOffsets = unsupportedMicrosoft365ReminderOffsets {
            return "Microsoft 365 can save only one reminder. This event has reminders \(reminderOffsets.map(String.init).joined(separator: ", ")) minutes before start."
        }

        if let ordinal = unsupportedMicrosoft365RecurrenceOrdinal {
            return "Microsoft 365 can save weekday repeats only as first, second, third, fourth, or last. Change \(ordinalTitle(ordinal).lowercased()) to a supported ordinal, or move this event to a local, Google, or CalDAV calendar."
        }

        if let monthDay = unsupportedMicrosoft365RecurrenceMonthDay {
            return "Microsoft 365 cannot save \(monthDayRecurrenceTitle(monthDay).lowercased()) repeats. Move this event to a local, Google, or CalDAV calendar before editing it."
        }

        if let months = unsupportedMicrosoft365MonthlyRecurrenceMonths {
            return "Microsoft 365 cannot save monthly repeats limited to \(months.map(String.init).joined(separator: ", ")). Move this event to a local, Google, or CalDAV calendar."
        }

        if let positions = unsupportedMicrosoft365WeeklyRecurrenceSetPositions {
            return "Microsoft 365 cannot save weekly repeats with BYSETPOS \(positions.map(String.init).joined(separator: ", ")). Move this event to a local, Google, or CalDAV calendar."
        }

        return nil
    }

    private var unsupportedGoogleReminderOffsets: [Int]? {
        let offsets = normalizedReminderOffsets(normalizedDraft.reminderOffsets)
        return offsets.count > 5 ? offsets : nil
    }

    private var unsupportedMicrosoft365ReminderOffsets: [Int]? {
        let offsets = normalizedReminderOffsets(normalizedDraft.reminderOffsets)
        return offsets.count > 1 ? offsets : nil
    }

    private var unsupportedMicrosoft365RecurrenceOrdinal: Int? {
        let normalized = normalizedDraft
        guard normalized.recurrenceFrequency == .monthly || normalized.recurrenceFrequency == .yearly,
              normalized.recurrenceOrdinalWeekday != nil,
              let ordinal = normalized.recurrenceOrdinal,
              !Self.microsoft365RelativeRecurrenceOrdinals.contains(ordinal)
        else {
            return nil
        }
        return ordinal
    }

    private var unsupportedMicrosoft365RecurrenceMonthDay: Int? {
        let normalized = normalizedDraft
        guard normalized.recurrenceFrequency == .monthly || normalized.recurrenceFrequency == .yearly,
              normalized.recurrenceOrdinal == nil,
              normalized.recurrenceOrdinalWeekday == nil,
              let monthDay = normalized.recurrenceMonthDay,
              monthDay < 0
        else {
            return nil
        }
        return monthDay
    }

    private var unsupportedMicrosoft365MonthlyRecurrenceMonths: [Int]? {
        let normalized = normalizedDraft
        guard normalized.recurrenceFrequency == .monthly else {
            return nil
        }
        let months = normalizedRecurrenceMonths(
            normalized.recurrenceMonths,
            frequency: normalized.recurrenceFrequency
        )
        return months.isEmpty ? nil : months
    }

    private var unsupportedMicrosoft365WeeklyRecurrenceSetPositions: [Int]? {
        let normalized = normalizedDraft
        guard normalized.recurrenceFrequency == .weekly else {
            return nil
        }
        let positions = normalizedRecurrenceSetPositions(
            normalized.recurrenceSetPositions,
            frequency: normalized.recurrenceFrequency
        )
        return positions.isEmpty ? nil : positions
    }

    private var conflictingEvents: [CalendarEvent] {
        let normalized = normalizedDraft
        guard normalized.availability.isBusy else { return [] }
        return conflictsForDraft(normalized)
            .filter { event in
                guard !isSameDraftEvent(event, draft: normalized) else { return false }
                guard event.availability.isBusy else { return false }
                return event.endDate > normalized.startDate && event.startDate < normalized.endDate
            }
            .sorted { $0.startDate < $1.startDate }
    }

    private var normalizedDraft: LocalEventDraft {
        var copy = draft
        if copy.endDate <= copy.startDate {
            copy.endDate = copy.startDate.addingTimeInterval(copy.isAllDay ? 24 * 3600 : 30 * 60)
        }
        if copy.timeZoneIdentifier.isEmpty || TimeZone(identifier: copy.timeZoneIdentifier) == nil {
            copy.timeZoneIdentifier = TimeZone.current.identifier
        }
        copy.categories = normalizedEventCategories(copy.categories)
        copy.reminderOffsets = normalizedReminderOffsets(copy.reminderOffsets)
        let hasAttendees = copy.attendees.contains { !$0.isBlank }
        if hasAttendees && copy.myResponseStatus == .notInvited {
            copy.myResponseStatus = .pending
        }
        if !hasAttendees && copy.myResponseStatus == .pending {
            copy.myResponseStatus = .notInvited
        }
        if copy.isDetachedOccurrenceDraft {
            copy.recurrenceFrequency = .none
            copy.recurrenceInterval = 1
            copy.recurrenceWeekdays = []
            copy.recurrenceWeekStart = nil
            copy.recurrenceSetPositions = []
            copy.recurrenceOrdinal = nil
            copy.recurrenceOrdinalWeekday = nil
            copy.recurrenceMonthDay = nil
            copy.recurrenceMonths = []
            copy.recurrenceEndDate = nil
            return copy
        }
        copy.recurrenceInterval = max(1, copy.recurrenceInterval)
        if copy.recurrenceFrequency == .none {
            copy.recurrenceWeekdays = []
            copy.recurrenceWeekStart = nil
            copy.recurrenceSetPositions = []
            copy.recurrenceMonthDay = nil
            copy.recurrenceMonths = []
            copy.recurrenceEndDate = nil
        } else if copy.recurrenceFrequency == .weekly {
            copy.recurrenceWeekdays = normalizedWeekdays(copy.recurrenceWeekdays)
            if copy.recurrenceWeekdays.isEmpty {
                copy.recurrenceWeekdays = [Calendar.current.component(.weekday, from: copy.startDate)]
            }
            copy.recurrenceWeekStart = normalizedRecurrenceWeekStart(copy.recurrenceWeekStart, frequency: copy.recurrenceFrequency)
            copy.recurrenceSetPositions = normalizedRecurrenceSetPositions(copy.recurrenceSetPositions, frequency: copy.recurrenceFrequency)
            copy.recurrenceMonthDay = nil
            copy.recurrenceMonths = []
        } else {
            copy.recurrenceWeekdays = []
            copy.recurrenceWeekStart = nil
            copy.recurrenceSetPositions = []
            copy.recurrenceMonths = normalizedRecurrenceMonths(copy.recurrenceMonths, frequency: copy.recurrenceFrequency)
        }
        if supportsOrdinalRecurrence(copy.recurrenceFrequency) {
            if copy.recurrenceOrdinal != nil || copy.recurrenceOrdinalWeekday != nil {
                let normalized = normalizedOrdinalRecurrence(
                    copy.recurrenceOrdinal ?? ordinal(for: copy.startDate, preservingSignOf: nil),
                    weekday: copy.recurrenceOrdinalWeekday ?? Calendar.current.component(.weekday, from: copy.startDate),
                    frequency: copy.recurrenceFrequency
                )
                copy.recurrenceOrdinal = normalized.ordinal
                copy.recurrenceOrdinalWeekday = normalized.weekday
                copy.recurrenceMonthDay = nil
            } else {
                copy.recurrenceMonthDay = normalizedRecurrenceMonthDay(copy.recurrenceMonthDay, frequency: copy.recurrenceFrequency)
            }
        } else {
            copy.recurrenceOrdinal = nil
            copy.recurrenceOrdinalWeekday = nil
            copy.recurrenceMonthDay = nil
        }
        if let recurrenceEndDate = copy.recurrenceEndDate,
           Calendar.current.startOfDay(for: recurrenceEndDate) < Calendar.current.startOfDay(for: copy.startDate) {
            copy.recurrenceEndDate = copy.startDate
        }
        return copy
    }

    private func isSameDraftEvent(_ event: CalendarEvent, draft: LocalEventDraft) -> Bool {
        guard let eventID = draft.eventID else { return false }
        return event.id == eventID || event.calendarItemIdentifier == eventID
    }

    private func normalizeRecurrenceWeekdays() {
        guard draft.recurrenceFrequency == .weekly else {
            draft.recurrenceWeekdays = []
            draft.recurrenceSetPositions = []
            return
        }

        let normalized = normalizedWeekdays(draft.recurrenceWeekdays)
        draft.recurrenceWeekdays = normalized.isEmpty
            ? [Calendar.current.component(.weekday, from: draft.startDate)]
            : normalized
    }

    private func normalizedWeekdays(_ weekdays: [Int]) -> [Int] {
        Array(Set(weekdays.filter { (1...7).contains($0) })).sorted()
    }

    private func supportsOrdinalRecurrence(_ frequency: LocalRecurrenceFrequency) -> Bool {
        frequency == .monthly || frequency == .yearly
    }

    private var ordinalRecurrenceModeBinding: Binding<LocalOrdinalRecurrenceMode> {
        Binding(
            get: {
                draft.recurrenceOrdinal != nil && draft.recurrenceOrdinalWeekday != nil
                    ? .weekday
                    : .date
            },
            set: { mode in
                switch mode {
                case .date:
                    clearOrdinalRecurrence()
                case .weekday:
                    applyOrdinalRecurrenceDefaults()
                }
            }
        )
    }

    private var recurrenceOrdinalBinding: Binding<Int> {
        Binding(
            get: { draft.recurrenceOrdinal ?? ordinal(for: draft.startDate, preservingSignOf: nil) },
            set: { ordinal in
                draft.recurrenceOrdinal = ordinal
                draft.recurrenceOrdinalWeekday = draft.recurrenceOrdinalWeekday
                    ?? Calendar.current.component(.weekday, from: draft.startDate)
            }
        )
    }

    private var recurrenceOrdinalWeekdayBinding: Binding<Int> {
        Binding(
            get: { draft.recurrenceOrdinalWeekday ?? Calendar.current.component(.weekday, from: draft.startDate) },
            set: { weekday in
                draft.recurrenceOrdinal = draft.recurrenceOrdinal
                    ?? ordinal(for: draft.startDate, preservingSignOf: nil)
                draft.recurrenceOrdinalWeekday = weekday
            }
        )
    }

    private var ordinalOptions: [Int] {
        [1, 2, 3, 4, 5, -1, -2, -3, -4, -5]
    }

    private static let microsoft365RelativeRecurrenceOrdinals: Set<Int> = [1, 2, 3, 4, -1]

    private func isOrdinalUnsupportedForSelectedBackend(_ ordinal: Int) -> Bool {
        selectedBackendInfo.sourceKind == .microsoft365
            && !Self.microsoft365RelativeRecurrenceOrdinals.contains(ordinal)
    }

    private var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (($0 + first - 1) % 7) + 1 }
    }

    private var dateRecurrenceSummary: String {
        switch draft.recurrenceFrequency {
        case .monthly:
            return monthDayRecurrenceTitle(draft.recurrenceMonthDay ?? Calendar.current.component(.day, from: draft.startDate))
        case .yearly:
            if let recurrenceMonthDay = draft.recurrenceMonthDay, recurrenceMonthDay < 0 {
                return "\(monthDayRecurrenceTitle(recurrenceMonthDay)) of \(monthName(for: draft.startDate))"
            }
            return monthDayTitle(for: draft.startDate)
        case .none, .daily, .weekly:
            return ""
        }
    }

    private var ordinalRecurrenceSummary: String {
        let ordinal = draft.recurrenceOrdinal ?? ordinal(for: draft.startDate, preservingSignOf: nil)
        let weekday = draft.recurrenceOrdinalWeekday ?? Calendar.current.component(.weekday, from: draft.startDate)
        let base = "\(ordinalTitle(ordinal)) \(weekdayName(weekday))"
        if draft.recurrenceFrequency == .yearly {
            return "\(base) of \(monthName(for: draft.startDate))"
        }
        return base
    }

    private func normalizeOrdinalRecurrenceForCurrentFrequency() {
        guard supportsOrdinalRecurrence(draft.recurrenceFrequency) else {
            clearOrdinalRecurrence()
            return
        }

        guard draft.recurrenceOrdinal != nil || draft.recurrenceOrdinalWeekday != nil else { return }
        let normalized = normalizedOrdinalRecurrence(
            draft.recurrenceOrdinal ?? ordinal(for: draft.startDate, preservingSignOf: nil),
            weekday: draft.recurrenceOrdinalWeekday ?? Calendar.current.component(.weekday, from: draft.startDate),
            frequency: draft.recurrenceFrequency
        )
        draft.recurrenceOrdinal = normalized.ordinal
        draft.recurrenceOrdinalWeekday = normalized.weekday
    }

    private func alignOrdinalRecurrenceToStartDate() {
        guard supportsOrdinalRecurrence(draft.recurrenceFrequency),
              draft.recurrenceOrdinal != nil || draft.recurrenceOrdinalWeekday != nil
        else {
            return
        }

        draft.recurrenceOrdinal = ordinal(for: draft.startDate, preservingSignOf: draft.recurrenceOrdinal)
        draft.recurrenceOrdinalWeekday = Calendar.current.component(.weekday, from: draft.startDate)
    }

    private func applyOrdinalRecurrenceDefaults() {
        guard supportsOrdinalRecurrence(draft.recurrenceFrequency) else { return }
        draft.recurrenceOrdinal = ordinal(for: draft.startDate, preservingSignOf: draft.recurrenceOrdinal)
        draft.recurrenceOrdinalWeekday = Calendar.current.component(.weekday, from: draft.startDate)
        draft.recurrenceMonthDay = nil
    }

    private func clearOrdinalRecurrence() {
        draft.recurrenceOrdinal = nil
        draft.recurrenceOrdinalWeekday = nil
    }

    private func monthDayRecurrenceTitle(_ monthDay: Int) -> String {
        if monthDay == -1 {
            return "Last day"
        }
        if monthDay < 0 {
            return "\(abs(monthDay)) days before month end"
        }
        return "Day \(monthDay)"
    }

    private func ordinal(for date: Date, preservingSignOf sourceOrdinal: Int?) -> Int {
        let calendar = Calendar.current
        let day = calendar.component(.day, from: date)
        if let sourceOrdinal, sourceOrdinal < 0,
           let days = calendar.range(of: .day, in: .month, for: date) {
            return -(((days.upperBound - 1 - day) / 7) + 1)
        }
        return ((day - 1) / 7) + 1
    }

    private func ordinalTitle(_ ordinal: Int) -> String {
        switch ordinal {
        case 1: return "First"
        case 2: return "Second"
        case 3: return "Third"
        case 4: return "Fourth"
        case 5: return "Fifth"
        case -1: return "Last"
        case -2: return "Second last"
        case -3: return "Third last"
        case -4: return "Fourth last"
        case -5: return "Fifth last"
        default: return "\(ordinal)"
        }
    }

    private func weekdayName(_ weekday: Int) -> String {
        guard (1...7).contains(weekday) else { return "Weekday" }
        return Calendar.current.weekdaySymbols[weekday - 1]
    }

    private func monthName(for date: Date) -> String {
        Calendar.current.monthSymbols[Calendar.current.component(.month, from: date) - 1]
    }

    private func monthDayTitle(for date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func normalizeResponseStatusForAttendees() {
        if hasAttendees && draft.myResponseStatus == .notInvited {
            draft.myResponseStatus = .pending
        } else if !hasAttendees && draft.myResponseStatus == .pending {
            draft.myResponseStatus = .notInvited
        }
    }

    private func responseStatusTitle(_ status: EventResponseStatus) -> String {
        switch status {
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

    private var recurrenceEndsBinding: Binding<Bool> {
        Binding(
            get: { draft.recurrenceEndDate != nil },
            set: { ends in
                if ends {
                    draft.recurrenceEndDate = draft.recurrenceEndDate
                        ?? Calendar.current.date(byAdding: .month, value: 3, to: draft.startDate)
                        ?? draft.startDate
                } else {
                    draft.recurrenceEndDate = nil
                }
            }
        )
    }

    private var recurrenceEndDateBinding: Binding<Date> {
        Binding(
            get: { draft.recurrenceEndDate ?? draft.startDate },
            set: { draft.recurrenceEndDate = $0 }
        )
    }

    private static let timeZoneIdentifiers: [String] = {
        let preferred = [
            TimeZone.current.identifier,
            "UTC",
            "Asia/Nicosia",
            "Europe/London",
            "Europe/Paris",
            "America/New_York",
            "America/Chicago",
            "America/Denver",
            "America/Los_Angeles",
            "Asia/Dubai",
            "Asia/Tokyo",
            "Australia/Sydney"
        ]
        let combined = preferred + TimeZone.knownTimeZoneIdentifiers.sorted()
        return combined.reduce(into: [String]()) { result, identifier in
            if !result.contains(identifier) {
                result.append(identifier)
            }
        }
    }()
}

struct LocalEventConflictWarning: View {
    let events: [CalendarEvent]

    private var visibleEvents: [CalendarEvent] {
        Array(events.prefix(3))
    }

    private var extraCount: Int {
        max(0, events.count - visibleEvents.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("\(events.count) conflict\(events.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)

            VStack(spacing: 6) {
                ForEach(visibleEvents) { event in
                    HStack(spacing: 8) {
                        CalendarDot(color: event.calendarColor)
                        Text(event.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(Formatters.eventRange(event))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if extraCount > 0 {
                    Text("+ \(extraCount) more")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.24))
        )
    }
}

struct LocalEventEditorValidationWarning: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.octagon.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.24))
            )
    }
}

struct LocalEventEditorBackendStrip: View {
    let info: CalendarBackendInfo

    var body: some View {
        HStack(spacing: 10) {
            Label(info.sourceKindTitle, systemImage: info.sourceKind.symbolName)
                .font(.caption.weight(.bold))
                .foregroundStyle(accentColor)

            Text(info.storageText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 12)

            if let error = trimmedError {
                Label("Sync issue", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(error)
            } else if info.pendingOutboxCount > 0 {
                Label("\(info.pendingOutboxCount) pending", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            } else {
                Label(info.capabilityText, systemImage: capabilitySymbolName)
                    .foregroundStyle(accentColor)
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(accentColor.opacity(0.18), lineWidth: 1)
        )
    }

    private var trimmedError: String? {
        let error = info.lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return error.isEmpty ? nil : error
    }

    private var accentColor: Color {
        if trimmedError != nil {
            return .red
        }
        if info.pendingOutboxCount > 0 {
            return .orange
        }
        if !info.isProviderBacked {
            return .teal
        }
        return info.allowsEventWrite ? .green : .secondary
    }

    private var capabilitySymbolName: String {
        if !info.isSourceEnabled {
            return "pause.circle"
        }
        if info.allowsEventWrite {
            return "arrow.triangle.2.circlepath"
        }
        if info.allowsResponses {
            return "checkmark.message"
        }
        return "lock"
    }
}

struct LocalEventEditorRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)

            content

            Spacer(minLength: 0)
        }
    }
}

struct LocalWeekdayPickerView: View {
    @Binding var selectedWeekdays: [Int]

    private var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (($0 + first - 1) % 7) + 1 }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(orderedWeekdays, id: \.self) { weekday in
                Button {
                    toggle(weekday)
                } label: {
                    Text(symbol(for: weekday))
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 26)
                        .foregroundStyle(isSelected(weekday) ? Color.white : Color.primary)
                        .background(
                            Capsule()
                                .fill(isSelected(weekday) ? Color.accentColor : Color.primary.opacity(0.07))
                        )
                }
                .buttonStyle(.plain)
                .help(fullName(for: weekday))
            }
        }
    }

    private func toggle(_ weekday: Int) {
        let normalized = selectedWeekdays.normalizedWeekdays
        if normalized.contains(weekday) {
            guard normalized.count > 1 else { return }
            selectedWeekdays = normalized.filter { $0 != weekday }
        } else {
            selectedWeekdays = (normalized + [weekday]).normalizedWeekdays
        }
    }

    private func isSelected(_ weekday: Int) -> Bool {
        selectedWeekdays.normalizedWeekdays.contains(weekday)
    }

    private func symbol(for weekday: Int) -> String {
        Calendar.current.veryShortWeekdaySymbols[weekday - 1]
    }

    private func fullName(for weekday: Int) -> String {
        Calendar.current.weekdaySymbols[weekday - 1]
    }
}

struct LocalAttendeesEditorView: View {
    @Binding var attendees: [LocalEventAttendee]

    private let statuses: [EventResponseStatus] = [.pending, .accepted, .tentative, .declined]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Attendees")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    attendees.append(LocalEventAttendee())
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }

            if attendees.isEmpty {
                Text("No attendees")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach($attendees) { $attendee in
                        HStack(spacing: 8) {
                            TextField("Name", text: $attendee.name)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                            TextField("email@example.com", text: $attendee.email)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                            Picker("", selection: $attendee.status) {
                                ForEach(statuses) { status in
                                    Text(status.title).tag(status)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 126)

                            Button(role: .destructive) {
                                attendees.removeAll { $0.id == attendee.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }
}

private extension Array where Element == Int {
    var normalizedWeekdays: [Int] {
        Array(Set(filter { (1...7).contains($0) })).sorted()
    }
}
