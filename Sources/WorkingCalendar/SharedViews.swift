import SwiftUI

struct HeaderBar: View {
    let title: String
    let subtitle: String
    let actionTitle: String
    let actionSystemImage: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: action) {
                Label(actionTitle, systemImage: actionSystemImage)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct SectionTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.bold())
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct CalendarDot: View {
    let color: NSColor

    var body: some View {
        Circle()
            .fill(Color(nsColor: color))
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.45), lineWidth: 1)
            )
    }
}

struct AvailabilityBadge: View {
    let availability: CalendarEventAvailability

    var body: some View {
        Label(availability.title, systemImage: availability.symbolName)
            .font(.caption2.weight(.bold))
            .foregroundStyle(availability.isBusy ? Color.secondary : Color.teal)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background((availability.isBusy ? Color.secondary : Color.teal).opacity(0.14), in: Capsule())
            .help("Show as \(availability.title)")
    }
}

struct PermissionBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
            Spacer()
        }
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct AlertOverlayView: View {
    let alert: MeetingAlert
    let dismiss: () -> Void
    let snooze: () -> Void
    let join: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: alert.rule.priority.symbolName)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color(nsColor: alert.rule.priority.accentColor))
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 6) {
                    Text(alert.startsText)
                        .font(.headline)
                        .foregroundStyle(Color(nsColor: alert.rule.priority.accentColor))
                    Text(alert.event.title)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    HStack(spacing: 6) {
                        Text(Formatters.eventRange(alert.event))
                        Text("·")
                        Label(alert.event.meetingMethod.title, systemImage: alert.event.meetingMethod.symbolName)
                        Text("·")
                        Text(alert.event.calendarTitle)
                        if let displayLocation = alert.displayLocation, !displayLocation.isEmpty {
                            Text("·")
                            Label(displayLocation, systemImage: "mappin.and.ellipse")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(OverlayIconButtonStyle())
                .help("Dismiss")
            }

            HStack(spacing: 10) {
                if alert.event.joinURL != nil {
                    Button(action: join) {
                        Label("Join Meeting", systemImage: "video.fill")
                    }
                    .buttonStyle(OverlayActionButtonStyle(kind: .primary, color: Color(nsColor: alert.rule.priority.accentColor)))
                    .controlSize(.large)
                }

                Button(action: snooze) {
                    Label("Snooze 3m", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(OverlayActionButtonStyle(kind: .secondary, color: Color(nsColor: alert.rule.priority.accentColor)))
                .controlSize(.large)

                Spacer()

                Text(alert.rule.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: alert.rule.priority.accentColor).opacity(0.55), lineWidth: 1)
        )
    }
}

struct OverlayActionButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    let kind: Kind
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(kind == .primary ? Color.white : Color.primary.opacity(0.9))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(background(configuration: configuration), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(kind == .primary ? Color.clear : Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: shadowColor.opacity(configuration.isPressed ? 0.08 : 0.18), radius: 8, x: 0, y: 3)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func background(configuration: Configuration) -> some ShapeStyle {
        if kind == .primary {
            return AnyShapeStyle(color.opacity(configuration.isPressed ? 0.78 : 1))
        }

        return AnyShapeStyle(Color.white.opacity(configuration.isPressed ? 0.72 : 0.9))
    }

    private var shadowColor: Color {
        kind == .primary ? color : .black
    }
}

struct OverlayIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Color.primary.opacity(0.72))
            .frame(width: 32, height: 32)
            .background(Color.white.opacity(configuration.isPressed ? 0.48 : 0.22), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
