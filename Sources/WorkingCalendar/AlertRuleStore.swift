import Combine
import Foundation

@MainActor
final class AlertRuleStore: ObservableObject {
    @Published var rules: [AlertRule] = [] {
        didSet { save() }
    }

    private let storageKey = "alertRules"

    init() {
        load()
    }

    func add(_ rule: AlertRule) {
        rules.append(rule.normalizedBooleanPredicates)
    }

    func update(_ rule: AlertRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule.normalizedBooleanPredicates
    }

    func delete(_ rule: AlertRule) {
        rules.removeAll { $0.id == rule.id }
    }

    func resetToDefaults() {
        rules = AlertRule.defaults
    }

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([AlertRule].self, from: data),
            !decoded.isEmpty
        else {
            rules = AlertRule.defaults
            return
        }

        let normalized = decoded.map(\.normalizedBooleanPredicates)
        rules = normalized
        if normalized != decoded {
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

private extension AlertRule {
    var normalizedBooleanPredicates: AlertRule {
        var copy = self
        copy.condition = condition?.normalizedBooleanPredicates
        return copy
    }
}

private extension RuleConditionGroup {
    var normalizedBooleanPredicates: RuleConditionGroup {
        var copy = self
        copy.conditions = conditions.map(\.normalizedBooleanPredicates)
        return copy
    }
}

private extension RuleCondition {
    var normalizedBooleanPredicates: RuleCondition {
        switch self {
        case .predicate(let predicate):
            return .predicate(predicate.normalizedBooleanPredicate)
        case .group(let group):
            return .group(group.normalizedBooleanPredicates)
        }
    }
}

private extension RulePredicate {
    var normalizedBooleanPredicate: RulePredicate {
        guard field.isBoolean else { return self }

        var copy = self
        if copy.comparison != .isEqualTo && copy.comparison != .isNotEqualTo {
            copy.comparison = .isEqualTo
        }

        let normalizedValue = copy.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["false", "no", "0", "off"].contains(normalizedValue) {
            copy.value = "false"
        } else {
            copy.value = "true"
        }
        return copy
    }
}
