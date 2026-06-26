import Foundation

@MainActor
final class AlertEngine {
    private struct AlertKey: Hashable {
        let eventID: String
        let ruleID: UUID
    }

    private struct FiredState {
        var count: Int
        var lastFiredAt: Date
    }

    private var firedStates: [AlertKey: FiredState] = [:]
    private var snoozedUntil: [String: Date] = [:]

    func evaluate(events: [CalendarEvent], rules: [AlertRule], now: Date) -> [MeetingAlert] {
        var alerts: [MeetingAlert] = []

        for event in events {
            guard event.endDate > now else { continue }

            if let snoozeDate = snoozedUntil[event.id], snoozeDate > now {
                continue
            }

            for rule in rules where rule.matches(event, now: now) {
                let secondsUntilStart = event.startDate.timeIntervalSince(now)
                let alertWindow = TimeInterval(rule.leadMinutes * 60)

                guard secondsUntilStart <= alertWindow else { continue }
                guard secondsUntilStart >= -180 else { continue }

                let key = AlertKey(eventID: event.id, ruleID: rule.id)
                let state = firedStates[key]
                let firedCount = state?.count ?? 0

                guard firedCount < max(rule.repeatCount, 1) else { continue }

                if let lastFiredAt = state?.lastFiredAt,
                   now.timeIntervalSince(lastFiredAt) < TimeInterval(max(rule.repeatEverySeconds, 10)) {
                    continue
                }

                let alert = MeetingAlert(event: event, rule: rule, firedAt: now, fireIndex: firedCount + 1)
                alerts.append(alert)
                firedStates[key] = FiredState(count: firedCount + 1, lastFiredAt: now)
            }
        }

        pruneState(now: now, liveEvents: events)
        return alerts.sorted { lhs, rhs in
            priorityRank(lhs.rule.priority) > priorityRank(rhs.rule.priority)
        }
    }

    func snooze(eventID: String, until date: Date) {
        snoozedUntil[eventID] = date
    }

    func clearSnooze(eventID: String) {
        snoozedUntil[eventID] = nil
    }

    private func pruneState(now: Date, liveEvents: [CalendarEvent]) {
        let liveIDs = Set(liveEvents.filter { $0.endDate > now.addingTimeInterval(-3600) }.map(\.id))
        firedStates = firedStates.filter { key, _ in
            liveIDs.contains(key.eventID)
        }
        snoozedUntil = snoozedUntil.filter { _, date in date > now }
    }

    private func priorityRank(_ priority: AlertPriority) -> Int {
        switch priority {
        case .normal: return 0
        case .important: return 1
        case .critical: return 2
        }
    }
}
