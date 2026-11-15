import Foundation

/// Maps moments to "focus days". With `dayStartHour = 4`, work done at 2 AM
/// still counts toward the previous day, which suits night owls.
struct FocusCalendar: Sendable {
    var calendar: Calendar = .current
    var dayStartHour: Int = 0

    func day(for date: Date) -> Date {
        calendar.startOfDay(for: date.addingTimeInterval(-Double(dayStartHour) * 3600))
    }

    func adding(days: Int, to day: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: day) ?? day
    }

    /// Inclusive range of days. Empty when `start` is after `end`.
    func days(from start: Date, through end: Date) -> [Date] {
        var result: [Date] = []
        var day = self.day(for: start)
        let last = self.day(for: end)
        while day <= last {
            result.append(day)
            day = adding(days: 1, to: day)
        }
        return result
    }

    func daysBetween(_ start: Date, _ end: Date) -> Int {
        calendar.dateComponents([.day], from: day(for: start), to: day(for: end)).day ?? 0
    }
}
