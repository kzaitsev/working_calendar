import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var providerStore: CalendarProviderStore
    @EnvironmentObject private var ruleStore: AlertRuleStore
    let openProviderSourceSetup: (ProviderSourceSetupIntent) -> Void

    init(openProviderSourceSetup: @escaping (ProviderSourceSetupIntent) -> Void = { _ in }) {
        self.openProviderSourceSetup = openProviderSourceSetup
    }

    var body: some View {
        let providerSourceIntent = ProviderSourceSetupIntent.settingsIntent(sourceCount: providerStore.accounts.count)
        let reports = model.providerDiagnosticReports()
        let coverageSummary = ProviderCoverageSummary(reports: reports)
        let preflightSummary = ProviderPreflightReadinessSummary(reports: reports)

        VStack(alignment: .leading, spacing: 22) {
            HeaderBar(
                title: "Settings",
                subtitle: "Tune scan windows for app-owned calendars and provider sync.",
                actionTitle: "Test Alert",
                actionSystemImage: "bell.and.waves.left.and.right"
            ) {
                model.showTestAlert()
            }

            VStack(alignment: .leading, spacing: 18) {
                SectionTitle(title: "Sources", subtitle: "Working Calendar uses its own local store plus protocol providers.")

                VStack(alignment: .leading, spacing: 12) {
                    SettingsStatusRow(
                        symbolName: "tray.full",
                        color: .teal,
                        title: "\(model.localCalendarStore.calendars.count) local calendars",
                        subtitle: "\(model.localCalendarStore.events.count) stored events"
                    )

                    SettingsStatusRow(
                        symbolName: "link",
                        color: .blue,
                        title: "\(providerStore.accounts.count) provider sources",
                        subtitle: model.providerSettingsSummaryText(),
                        actionTitle: providerSourceIntent.actionTitle,
                        actionSystemImage: providerSourceIntent.actionSystemImage,
                        action: { openProviderSourceSetup(providerSourceIntent) }
                    )

                    SettingsStatusRow(
                        symbolName: "checklist.checked",
                        color: coverageSummaryColor(coverageSummary),
                        title: coverageSummary.titleText,
                        subtitle: coverageSummary.detailText
                    )
                }
                .padding(16)
                .frame(maxWidth: 760, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06))
                )

                if !reports.isEmpty {
                    SectionTitle(title: "Provider Health", subtitle: "Direct sync state and onboarding readiness for protocol sources.")

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(reports.enumerated()), id: \.element.id) { index, report in
                            if index > 0 {
                                Divider()
                            }
                            SettingsProviderHealthRow(report: report) {
                                openProviderSourceSetup(.addSource(report.source))
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: 920, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06))
                    )
                }

                SectionTitle(title: "Provider Preflight", subtitle: "Verify saved sources before live provider sync or write probes.")

                SettingsPreflightCommandCard(
                    coverageSummary: coverageSummary,
                    preflightSummary: preflightSummary
                )

                SectionTitle(title: "Scanning", subtitle: "Alerts scan every 20 seconds; provider sources sync in the background.")

                VStack(alignment: .leading, spacing: 18) {
                    SettingsSliderRow(
                        title: "Agenda look ahead",
                        subtitle: "How far ahead the agenda, menu bar, calendar, and alerts should scan.",
                        valueText: "\(Int(model.lookAheadHours)) hours",
                        value: $model.lookAheadHours,
                        bounds: 4...48
                    )
                    Divider()
                    SettingsSliderRow(
                        title: "Invite response look ahead",
                        subtitle: "How far ahead to collect meetings that still need Accept, Maybe, or Decline.",
                        valueText: "\(Int(model.responseLookAheadHours)) hours",
                        value: $model.responseLookAheadHours,
                        bounds: 4...168
                    )
                    Divider()
                    SettingsSliderRow(
                        title: "Provider sync interval",
                        subtitle: "How often connected calendar sources should refresh from their providers.",
                        valueText: "\(Int(model.providerSyncIntervalMinutes)) min",
                        value: $model.providerSyncIntervalMinutes,
                        bounds: 1...60
                    )
                }
                .padding(16)
                .frame(maxWidth: 760, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06))
                )

                SectionTitle(title: "Rules", subtitle: "Restore the default alerting and auto-response rules.")

                HStack {
                    Button {
                        ruleStore.resetToDefaults()
                    } label: {
                        Label("Reset Rules", systemImage: "arrow.counterclockwise")
                    }

                    Spacer()
                }
                .padding(16)
                .frame(maxWidth: 760, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06))
                )

                Spacer()
            }
        }
        .padding(28)
    }

    private func coverageSummaryColor(_ summary: ProviderCoverageSummary) -> Color {
        if !summary.isStrictCoverageComplete {
            return .secondary
        }

        return summary.needsAttention ? .orange : .blue
    }

}

enum ProviderSourceSetupIntent: Equatable {
    case addSource(ProviderDiagnosticSource?)
    case manageSources

    static func settingsIntent(sourceCount: Int) -> ProviderSourceSetupIntent {
        sourceCount > 0 ? .manageSources : .addSource(nil)
    }

    var shouldPresentAddSource: Bool {
        if case .addSource = self {
            return true
        }
        return false
    }

    var preferredSource: ProviderDiagnosticSource? {
        if case .addSource(let source) = self {
            return source
        }
        return nil
    }

    var actionTitle: String {
        switch self {
        case .addSource:
            return "Add Source"
        case .manageSources:
            return "Manage Sources"
        }
    }

    var actionSystemImage: String {
        switch self {
        case .addSource:
            return "plus"
        case .manageSources:
            return "slider.horizontal.3"
        }
    }
}

struct SettingsStatusRow: View {
    let symbolName: String
    let color: Color
    let title: String
    let subtitle: String
    var actionTitle: String? = nil
    var actionSystemImage: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .foregroundStyle(color)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let actionTitle,
               let actionSystemImage,
               let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: actionSystemImage)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

struct SettingsProviderHealthRow: View {
    let report: ProviderDiagnosticReport
    var addSource: (() -> Void)? = nil

    var shouldShowAddSourceAction: Bool {
        report.isOnboardingReport && addSource != nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: report.source.symbolName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 28, height: 28)
                .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(report.accountTitle ?? report.source.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)

                    Text(report.source.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.12), in: Capsule())

                    Text(report.status.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.12), in: Capsule())

                    if let oauth = report.oauth {
                        Text(oauth.status.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(oauthColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(oauthColor.opacity(0.12), in: Capsule())
                            .help(oauthHelpText(oauth))
                    }
                }

                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(report.summaryLine)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(importedText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Text(syncText)
                    .font(.caption2)
                    .foregroundStyle(syncColor)
                    .lineLimit(1)
                    .help(syncHelpText)
            }
            .frame(width: 180, alignment: .trailing)

            if shouldShowAddSourceAction, let addSource {
                Button(action: addSource) {
                    Label("Add Source", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .help("Add \(report.source.onboardingTitle) source")
            }
        }
        .padding(.vertical, 10)
    }

    private var statusColor: Color {
        switch report.status {
        case .passed:
            return .green
        case .pending:
            return .orange
        case .skipped:
            return .secondary
        case .failed:
            return .red
        }
    }

    private var syncColor: Color {
        report.nextSyncAt == nil || report.status == .failed ? statusColor : .secondary
    }

    private var oauthColor: Color {
        guard let oauth = report.oauth else { return .secondary }
        switch oauth.status {
        case .ready:
            return .green
        case .refreshDue:
            return .orange
        case .missingCredential, .missingRefreshToken, .missingScopes:
            return .red
        }
    }

    private var detailText: String {
        var parts = [report.message.isEmpty ? report.summaryLine : report.message]
        if let oauth = report.oauth {
            parts.append(oauth.status.title)
        }
        if report.writableCalendarCount > 0 {
            parts.append("\(report.writableCalendarCount) writable")
        }
        let responseOnlyCount = max(0, report.responseCapableCalendarCount - report.writableCalendarCount)
        if responseOnlyCount > 0 {
            parts.append("\(responseOnlyCount) response-only")
        }
        if report.readOnlyCalendarCount > 0 {
            parts.append("\(report.readOnlyCalendarCount) read-only")
        }
        if report.identityEmailCount > 0 {
            parts.append("\(report.identityEmailCount) identities")
        }
        if report.syncStateCount > 0 {
            parts.append("\(report.syncStateCount) sync states")
        }
        if report.httpValidatorCount > 0 {
            parts.append("\(report.httpValidatorCount) validators")
        }
        if let refreshIntervalSeconds = report.refreshIntervalSeconds, refreshIntervalSeconds > 0 {
            parts.append("refresh \(formattedRefreshInterval(refreshIntervalSeconds))")
        }
        if report.writeProbeCount > 0 {
            parts.append("\(report.writeProbeCount) write probe\(report.writeProbeCount == 1 ? "" : "s")")
        }
        if report.responseProbeCount > 0 {
            parts.append("\(report.responseProbeCount) response probe\(report.responseProbeCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    private var importedText: String {
        "\(report.calendarCount)c · \(report.eventCount)e"
    }

    private var syncText: String {
        if !report.isEnabled {
            return "Disabled"
        }
        if report.needsAttention {
            if let lastSyncFailedAt = report.lastSyncFailedAt {
                return "Failed \(lastSyncFailedAt.formatted(date: .omitted, time: .shortened))"
            }
            return "Needs attention"
        }
        if report.lastSyncAt == nil {
            return "Initial sync"
        }
        if report.pendingOutboxCount > 0 {
            return "\(report.pendingOutboxCount) pending"
        }
        if let nextSyncAt = report.nextSyncAt {
            return "Next \(nextSyncAt.formatted(date: .omitted, time: .shortened))"
        }
        return "Synced"
    }

    private var syncHelpText: String {
        var parts: [String] = []
        if let lastSyncAt = report.lastSyncAt {
            let durationText = report.lastSyncDurationSeconds.map { " in \(formattedDuration($0))" } ?? ""
            parts.append("Last sync \(lastSyncAt.formatted(date: .abbreviated, time: .standard))\(durationText)")
        }
        if let lastSyncFailedAt = report.lastSyncFailedAt {
            let durationText = report.lastSyncDurationSeconds.map { " after \(formattedDuration($0))" } ?? ""
            parts.append("Last failed sync \(lastSyncFailedAt.formatted(date: .abbreviated, time: .standard))\(durationText)")
        }
        if let nextSyncAt = report.nextSyncAt {
            parts.append("Next sync \(nextSyncAt.formatted(date: .abbreviated, time: .standard))")
        }
        if report.pendingOutboxCount > 0 {
            parts.append("\(report.pendingOutboxCount) pending remote update\(report.pendingOutboxCount == 1 ? "" : "s")")
        }
        if report.attentionOutboxCount > 0 {
            parts.append("\(report.attentionOutboxCount) remote update\(report.attentionOutboxCount == 1 ? "" : "s") need attention")
        }
        if report.syncStateCount > 0 {
            parts.append("\(report.syncStateCount) incremental sync state\(report.syncStateCount == 1 ? "" : "s")")
        }
        if report.httpValidatorCount > 0 {
            parts.append("\(report.httpValidatorCount) HTTP validator\(report.httpValidatorCount == 1 ? "" : "s")")
        }
        if let refreshIntervalSeconds = report.refreshIntervalSeconds, refreshIntervalSeconds > 0 {
            parts.append("Feed refresh interval \(formattedRefreshInterval(refreshIntervalSeconds))")
        }
        if report.writeProbeCount > 0 {
            parts.append("\(report.writeProbeCount) live write probe\(report.writeProbeCount == 1 ? "" : "s")")
        }
        if report.responseProbeCount > 0 {
            parts.append("\(report.responseProbeCount) live response probe\(report.responseProbeCount == 1 ? "" : "s")")
        }
        if let oauth = report.oauth {
            parts.append(oauthHelpText(oauth))
        }
        return parts.isEmpty ? report.summaryLine : parts.joined(separator: " · ")
    }

    private func oauthHelpText(_ oauth: ProviderOAuthDiagnostic) -> String {
        var parts = [oauth.status.title]
        if let expiresAt = oauth.expiresAt {
            parts.append("expires \(expiresAt.formatted(date: .abbreviated, time: .standard))")
        }
        parts.append(oauth.hasRefreshToken ? "refresh token available" : "no refresh token")
        parts.append("\(oauth.grantedScopeCount) granted scope\(oauth.grantedScopeCount == 1 ? "" : "s")")
        if oauth.missingScopeCount > 0 {
            parts.append("\(oauth.missingScopeCount) missing scope\(oauth.missingScopeCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let safeSeconds = max(0, seconds)
        if safeSeconds < 1 {
            return "<1s"
        }
        if safeSeconds < 60 {
            return "\(Int(safeSeconds.rounded()))s"
        }
        let minutes = Int((safeSeconds / 60).rounded())
        return "\(minutes)m"
    }

    private func formattedRefreshInterval(_ seconds: Int) -> String {
        let safeSeconds = max(0, seconds)
        if safeSeconds < 60 {
            return "\(safeSeconds)s"
        }
        let minutes = safeSeconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = max(1, minutes / 60)
        return "\(hours)h"
    }
}

struct SettingsPreflightCommandCard: View {
    let coverageSummary: ProviderCoverageSummary
    let preflightSummary: ProviderPreflightReadinessSummary
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checklist.checked")
                .font(.callout.weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 28, height: 28)
                .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(preflightSummary.titleText)
                    .font(.callout.weight(.semibold))

                Text(preflightSummary.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !preflightSummary.isReady {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(preflightSummary.failurePreview(), id: \.self) { failure in
                            Label(failure, systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        let hiddenCount = preflightSummary.hiddenFailureCount()
                        if hiddenCount > 0 {
                            Text("+ \(hiddenCount) more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text(coverageSummary.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(ProviderPreflightCommand.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(ProviderPreflightCommand.shellCommand)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .textSelection(.enabled)

                    Button {
                        copyPreflightCommand()
                    } label: {
                        Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .help("Copy preflight command")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 920, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }

    private var statusColor: Color {
        preflightSummary.isReady ? .blue : .orange
    }

    private func copyPreflightCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ProviderPreflightCommand.shellCommand, forType: .string)
        didCopy = true

        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run {
                didCopy = false
            }
        }
    }
}

struct SettingsSliderRow: View {
    let title: String
    let subtitle: String
    let valueText: String
    @Binding var value: Double
    let bounds: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(valueText)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
            }

            Slider(value: $value, in: bounds, step: 1)
        }
    }
}
