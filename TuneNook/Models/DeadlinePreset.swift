import Foundation

/// Quick picks for a task's deadline. Every date is the start of the target day.
enum DeadlinePreset: CaseIterable {
    case today, tomorrow, nextWeek

    var title: String {
        switch self {
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .nextWeek: "Next week"
        }
    }

    /// The deadline this pick means at `now`. Next week is the first Monday after today.
    func date(from now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today:
            return today
        case .tomorrow:
            return calendar.date(byAdding: .day, value: 1, to: today) ?? today
        case .nextWeek:
            return calendar.nextDate(after: today, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? today
        }
    }

    /// "Today", "Tomorrow", otherwise "Nov 28".
    static func shortLabel(for day: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(day, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: calendar.locale ?? .current,
                                     calendar: calendar, timeZone: calendar.timeZone)
        style = style.month(.abbreviated).day()
        return day.formatted(style)
    }
}
