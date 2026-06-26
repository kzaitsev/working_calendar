import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel

    private var nextEvent: CalendarEvent? {
        let upcoming = model.agendaEvents().filter { $0.endDate > Date() }
        return upcoming.first { !$0.isAllDay } ?? upcoming.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let nextEvent {
                Text(nextEvent.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(nextEventSubtitle(nextEvent))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if nextEvent.joinURL != nil {
                    Button {
                        model.openEventLink(nextEvent)
                    } label: {
                        Label("Join", systemImage: "video.fill")
                    }
                }
            } else {
                Text("No upcoming meetings")
                    .font(.headline)
                Text("Enjoy the quiet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button {
                Task {
                    await model.syncProviderSources(force: true)
                    model.tick()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            } label: {
                Label("Open Working Calendar", systemImage: "macwindow")
            }

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(10)
        .frame(width: 280)
    }

    private func nextEventSubtitle(_ event: CalendarEvent) -> String {
        if event.isAllDay {
            return "All day · \(event.calendarTitle)"
        }

        return "\(event.minutesUntilStart()) min · \(event.meetingMethod.title) · \(Formatters.eventRange(event))"
    }
}
