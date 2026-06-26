import SwiftUI

struct RulesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ruleStore: AlertRuleStore
    @State private var editingRule: AlertRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderBar(
                title: "Rules",
                subtitle: "Build Mail-style filters for the meetings that deserve stronger alerts.",
                actionTitle: "Add Rule",
                actionSystemImage: "plus"
            ) {
                editingRule = AlertRule(
                    name: "New rule",
                    priority: .important,
                    condition: RuleConditionGroup(
                        mode: .all,
                        conditions: [
                            .predicate(field: .anyText, comparison: .contains, value: "")
                        ]
                    ),
                    leadMinutes: 5,
                    repeatEverySeconds: 45,
                    repeatCount: 3,
                    stickyOverlay: true,
                    systemNotification: true,
                    playSound: true,
                    speak: false,
                    bounceDock: true
                )
            }

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(ruleStore.rules) { rule in
                        RuleRow(rule: rule, edit: {
                            editingRule = rule
                        }, delete: {
                            ruleStore.delete(rule)
                        })
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .padding(28)
        .sheet(item: $editingRule) { rule in
            RuleEditorView(rule: rule, calendars: model.localCalendarStore.calendars) { savedRule in
                if ruleStore.rules.contains(where: { $0.id == savedRule.id }) {
                    ruleStore.update(savedRule)
                } else {
                    ruleStore.add(savedRule)
                }
                editingRule = nil
            } cancel: {
                editingRule = nil
            }
        }
    }
}

struct RuleRow: View {
    @EnvironmentObject private var ruleStore: AlertRuleStore
    let rule: AlertRule
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: rule.priority.symbolName)
                .font(.title3)
                .foregroundStyle(Color(nsColor: rule.priority.accentColor))
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 6) {
                Text(rule.name)
                    .font(.headline)
                Text(rule.effectiveCondition.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(actionsSummary)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(nsColor: rule.priority.accentColor))
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { currentRule.enabled },
                set: { enabled in
                    var updated = currentRule
                    updated.enabled = enabled
                    ruleStore.update(updated)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)

            Button(action: edit) {
                Image(systemName: "pencil")
            }
            .help("Edit rule")

            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .help("Delete rule")
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var currentRule: AlertRule {
        ruleStore.rules.first(where: { $0.id == rule.id }) ?? rule
    }

    private var actionsSummary: String {
        var parts = ["\(rule.leadMinutes)m before", "\(rule.repeatCount)x every \(rule.repeatEverySeconds)s"]
        if rule.responseAction != .none {
            parts.append("\(rule.responseAction.title) \(rule.responseScope.ruleTitle)")
        }
        if !rule.locationOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("location: \(rule.locationOverride)")
        }
        if rule.stickyOverlay { parts.append("overlay") }
        if rule.systemNotification { parts.append("notification") }
        if rule.playSound { parts.append("sound") }
        if rule.speak { parts.append("speech") }
        if rule.bounceDock { parts.append("dock") }
        return parts.joined(separator: " · ")
    }
}

struct RuleEditorView: View {
    @State private var draft: AlertRule
    let calendars: [LocalCalendar]
    let save: (AlertRule) -> Void
    let cancel: () -> Void

    init(rule: AlertRule, calendars: [LocalCalendar], save: @escaping (AlertRule) -> Void, cancel: @escaping () -> Void) {
        var normalizedRule = rule
        if normalizedRule.condition == nil {
            normalizedRule.condition = rule.effectiveCondition
        }
        _draft = State(initialValue: normalizedRule)
        self.calendars = calendars
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Rule")
                    .font(.title2.bold())
                Spacer()
                Button("Cancel", action: cancel)
                Button("Save") {
                    save(draft)
                }
                .buttonStyle(.borderedProminent)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    RuleEditorSection(title: "Identity", subtitle: "Name this rule and choose how loud its alerts should be.") {
                        VStack(alignment: .leading, spacing: 10) {
                            EditorFieldRow(label: "Name") {
                                TextField("Rule name", text: $draft.name)
                                    .textFieldStyle(.plain)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }

                            EditorFieldRow(label: "Priority") {
                                Picker("", selection: $draft.priority) {
                                    ForEach(AlertPriority.allCases) { priority in
                                        Label(priority.title, systemImage: priority.symbolName)
                                            .tag(priority)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 220, alignment: .leading)
                            }
                        }
                    }

                    RuleEditorSection(title: "When", subtitle: "The meeting must match this condition tree before any actions below run.") {
                        ConditionGroupEditor(group: conditionBinding, calendars: calendars, depth: 0, onRemove: nil)
                    }

                    RuleFlowConnector(text: "Matched meetings continue to actions")

                    RuleEditorSection(title: "Then", subtitle: "These actions run only for meetings that pass the When block.") {
                        VStack(alignment: .leading, spacing: 12) {
                            EditorFieldRow(label: "Auto response") {
                                Picker("", selection: $draft.responseAction) {
                                    ForEach(RuleResponseAction.allCases) { action in
                                        Label(action.title, systemImage: action.symbolName)
                                            .tag(action)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 240, alignment: .leading)
                            }

                            if draft.responseAction != .none {
                                EditorFieldRow(label: "Response scope") {
                                    Picker("", selection: $draft.responseScope) {
                                        ForEach(CalendarEventResponseScope.allCases) { scope in
                                            Text(scope.title).tag(scope)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 180, alignment: .leading)
                                }
                            }

	                            EditorFieldRow(label: "Display location") {
                                TextField("первая переговорка", text: $draft.locationOverride)
                                    .textFieldStyle(.plain)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }

                            Divider()

                            Stepper("Lead time: \(draft.leadMinutes) minutes", value: $draft.leadMinutes, in: 0...60)
                            Stepper("Repeat count: \(draft.repeatCount)", value: $draft.repeatCount, in: 1...20)
                            Stepper("Repeat every: \(draft.repeatEverySeconds) seconds", value: $draft.repeatEverySeconds, in: 10...300, step: 5)

                            Divider()

                            Toggle("Sticky overlay window", isOn: $draft.stickyOverlay)
                            Toggle("System notification", isOn: $draft.systemNotification)
                            Toggle("Play sound", isOn: $draft.playSound)
                            Toggle("Speak title aloud", isOn: $draft.speak)
                            Toggle("Bounce Dock icon", isOn: $draft.bounceDock)
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(24)
        .frame(width: 860, height: 760)
    }

    private var conditionBinding: Binding<RuleConditionGroup> {
        Binding(
            get: { draft.condition ?? RuleConditionGroup(mode: .all) },
            set: { draft.condition = $0 }
        )
    }
}

struct RuleEditorSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }
}

struct EditorFieldRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .leading)

            content

            Spacer(minLength: 0)
        }
    }
}

struct ConditionGroupEditor: View {
    @Binding var group: RuleConditionGroup
    let calendars: [LocalCalendar]
    let depth: Int
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(group.mode.uiColor)
                .frame(width: 4)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(depth == 0 ? "Root match" : "Nested group")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 88, alignment: .leading)

                        RuleModeBadge(mode: group.mode)

                        Picker("", selection: $group.mode) {
                            ForEach(RuleConditionMode.allCases) { mode in
                                Text(mode.sentence).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 245)

                        Spacer()

                        if let onRemove {
                            Button(role: .destructive, action: onRemove) {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Remove group")
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(group.mode.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button {
                            group.conditions.append(.predicate(RulePredicate(field: .title, comparison: .contains)))
                        } label: {
                            Label("Condition", systemImage: "plus")
                        }
                        .controlSize(.small)

                        Button {
                            group.conditions.append(.group(RuleConditionGroup(
                                mode: .all,
                                conditions: [.predicate(RulePredicate(field: .anyText, comparison: .contains))]
                            )))
                        } label: {
                            Label("Group", systemImage: "rectangle.stack.badge.plus")
                        }
                        .controlSize(.small)

                        Button {
                            group.conditions.append(.group(RuleConditionGroup(
                                mode: .none,
                                conditions: [.predicate(RulePredicate(field: .title, comparison: .contains))]
                            )))
                        } label: {
                            Label("Not", systemImage: "nosign")
                        }
                        .controlSize(.small)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if group.conditions.isEmpty {
                    Text("This group is empty, so it matches every meeting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 8) {
                        ForEach(group.conditions.indices, id: \.self) { index in
                            ConditionNodeEditor(
                                condition: $group.conditions[index],
                                calendars: calendars,
                                depth: depth + 1,
                                connector: group.mode.connectorLabel(for: index)
                            ) {
                                group.conditions.remove(at: index)
                            }
                        }
                    }
                }
            }
        }
        .padding(depth == 0 ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(depth == 0 ? group.mode.uiColor.opacity(0.04) : group.mode.uiColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(group.mode.uiColor.opacity(depth == 0 ? 0.14 : 0.18), lineWidth: 1)
        )
    }
}

struct ConditionNodeEditor: View {
    @Binding var condition: RuleCondition
    let calendars: [LocalCalendar]
    let depth: Int
    let connector: String
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ConnectorBadge(text: connector)
                .padding(.top, 13)

            switch condition {
            case .predicate:
                PredicateEditor(predicate: predicateBinding, calendars: calendars, remove: remove)
            case .group:
                ConditionGroupEditor(group: groupBinding, calendars: calendars, depth: depth, onRemove: remove)
            }
        }
    }

    private var predicateBinding: Binding<RulePredicate> {
        Binding(
            get: {
                if case .predicate(let predicate) = condition {
                    return predicate
                }
                return RulePredicate()
            },
            set: { condition = .predicate($0) }
        )
    }

    private var groupBinding: Binding<RuleConditionGroup> {
        Binding(
            get: {
                if case .group(let group) = condition {
                    return group
                }
                return RuleConditionGroup(mode: .all)
            },
            set: { condition = .group($0) }
        )
    }
}

struct RuleFlowConnector: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 2, height: 12)
                Image(systemName: "arrow.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.primary.opacity(0.35))
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 2, height: 12)
            }
            .frame(width: 32)

            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.leading, 16)
    }
}

struct RuleModeBadge: View {
    let mode: RuleConditionMode

    var body: some View {
        Text(mode.badgeTitle)
            .font(.caption.weight(.bold))
            .foregroundStyle(mode.uiColor)
            .frame(width: 50)
            .padding(.vertical, 5)
            .background(mode.uiColor.opacity(0.12), in: Capsule())
    }
}

struct ConnectorBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: 38)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

struct PredicateEditor: View {
    @Binding var predicate: RulePredicate
    let calendars: [LocalCalendar]
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Field", selection: $predicate.field) {
                ForEach(RuleConditionField.allCases) { field in
                    Text(field.title).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: 165)
            .onChange(of: predicate.field) { _, newField in
                normalizeComparison(for: newField)
            }

            Picker("Comparison", selection: $predicate.comparison) {
                ForEach(availableComparisons) { comparison in
                    Text(comparison.title).tag(comparison)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            valueInput
                .frame(width: 270)

            Spacer(minLength: 0)

            Button(role: .destructive, action: remove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .help("Remove condition")
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var valueInput: some View {
        if predicate.comparison == .exists || predicate.comparison == .doesNotExist {
            Text(" ")
                .frame(maxWidth: .infinity)
        } else if predicate.field == .responseStatus || predicate.field == .myResponse {
            Picker("Value", selection: $predicate.value) {
                ForEach(EventResponseStatus.allCases) { status in
                    Text(status.title).tag(status.rawValue)
                }
            }
            .labelsHidden()
        } else if predicate.field.isBoolean {
            Picker("Value", selection: booleanValueBinding) {
                Text("true").tag("true")
                Text("false").tag("false")
            }
            .labelsHidden()
        } else if predicate.field == .calendar && (predicate.comparison == .isEqualTo || predicate.comparison == .isNotEqualTo) && !calendars.isEmpty {
            Picker("Calendar", selection: $predicate.value) {
                ForEach(calendars) { calendar in
                    Text(calendar.title).tag(calendar.title)
                }
            }
            .labelsHidden()
        } else {
            TextField(predicate.field.suggestedPlaceholder, text: $predicate.value)
                .textFieldStyle(.plain)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var availableComparisons: [RuleConditionComparison] {
        if predicate.field.isNumeric {
            return [.isLessThanOrEqualTo, .isGreaterThanOrEqualTo, .isEqualTo, .isNotEqualTo]
        }

        if predicate.field.isBoolean {
            return [.isEqualTo, .isNotEqualTo]
        }

        return [.contains, .doesNotContain, .isEqualTo, .isNotEqualTo, .exists, .doesNotExist]
    }

    private var booleanValueBinding: Binding<String> {
        Binding(
            get: {
                let value = predicate.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return ["false", "no", "0", "off"].contains(value) ? "false" : "true"
            },
            set: { predicate.value = $0 }
        )
    }

    private func normalizeComparison(for field: RuleConditionField) {
        let comparisons = availableComparisons
        if !comparisons.contains(predicate.comparison) {
            predicate.comparison = comparisons.first ?? .contains
        }

        if field == .responseStatus && predicate.value.isEmpty {
            predicate.value = EventResponseStatus.pending.rawValue
        } else if field == .myResponse && predicate.value.isEmpty {
            predicate.value = EventResponseStatus.accepted.rawValue
        } else if field.isBoolean {
            let normalizedValue = predicate.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["false", "no", "0", "off"].contains(normalizedValue) {
                predicate.value = "false"
            } else {
                predicate.value = "true"
            }
        }
    }
}

private extension RuleConditionGroup {
    var summary: String {
        guard !conditions.isEmpty else { return "Every meeting" }

        let joined: String
        switch mode {
        case .all:
            joined = conditions.map(\.summary).joined(separator: " and ")
            return joined
        case .any:
            joined = conditions.map(\.summary).joined(separator: " or ")
            return joined
        case .none:
            joined = conditions.map(\.summary).joined(separator: " or ")
            return "not (\(joined))"
        }
    }
}

private extension RuleConditionMode {
    var badgeTitle: String {
        switch self {
        case .all: return "ALL"
        case .any: return "ANY"
        case .none: return "NONE"
        }
    }

    var explanation: String {
        switch self {
        case .all: return "Every child condition must be true."
        case .any: return "At least one child condition must be true."
        case .none: return "The nested block must not match."
        }
    }

    var uiColor: Color {
        switch self {
        case .all: return .blue
        case .any: return .teal
        case .none: return .red
        }
    }

    func connectorLabel(for index: Int) -> String {
        if index == 0 {
            return self == .none ? "NOT" : "IF"
        }

        switch self {
        case .all: return "AND"
        case .any: return "OR"
        case .none: return "NOT"
        }
    }
}

private extension RuleCondition {
    var summary: String {
        switch self {
        case .predicate(let predicate):
            return predicate.summary
        case .group(let group):
            return "(\(group.summary))"
        }
    }
}

private extension RulePredicate {
    var summary: String {
        if comparison == .exists || comparison == .doesNotExist {
            return "\(field.title) \(comparison.title)"
        }

        return "\(field.title) \(comparison.title) \(value.isEmpty ? "..." : value)"
    }
}
