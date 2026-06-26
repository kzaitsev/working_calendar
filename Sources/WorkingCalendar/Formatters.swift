import Foundation

enum Formatters {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    static let dayAndTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .medium
        return formatter
    }()

    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .none
        formatter.dateStyle = .medium
        return formatter
    }()

    static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    static func eventRange(_ event: CalendarEvent) -> String {
        if event.isAllDay {
            let startDay = Calendar.current.startOfDay(for: event.startDate)
            let inclusiveEndDate = event.endDate > event.startDate
                ? event.endDate.addingTimeInterval(-1)
                : event.startDate
            let endDay = Calendar.current.startOfDay(for: inclusiveEndDate)

            if Calendar.current.isDate(startDay, inSameDayAs: endDay) {
                return "All day · \(date.string(from: startDay))"
            }

            return "All day · \(date.string(from: startDay)) - \(date.string(from: endDay))"
        }

        if Calendar.current.isDate(event.startDate, inSameDayAs: event.endDate) {
            return "\(time.string(from: event.startDate)) - \(time.string(from: event.endDate))"
        }

        return "\(dayAndTime.string(from: event.startDate)) - \(dayAndTime.string(from: event.endDate))"
    }

    static func eventStartLabel(_ event: CalendarEvent) -> String {
        event.isAllDay ? "ALL DAY" : time.string(from: event.startDate)
    }
}
