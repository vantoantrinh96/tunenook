import Foundation
import Testing
@testable import TuneNook

@Suite struct DeadlinePresetTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func todayIsStartOfToday() {
        #expect(DeadlinePreset.today.date(from: date(2026, 11, 25, 15, 30), calendar: calendar) == date(2026, 11, 25))
    }

    @Test func tomorrowIsStartOfNextDay() {
        #expect(DeadlinePreset.tomorrow.date(from: date(2026, 11, 25, 15, 30), calendar: calendar) == date(2026, 11, 26))
    }

    @Test func nextWeekFromWednesdayIsNextMonday() {
        #expect(DeadlinePreset.nextWeek.date(from: date(2026, 11, 25, 15, 30), calendar: calendar) == date(2026, 11, 30))
    }

    @Test func nextWeekFromMondayIsSevenDaysLater() {
        #expect(DeadlinePreset.nextWeek.date(from: date(2026, 11, 30, 9), calendar: calendar) == date(2026, 12, 7))
    }

    @Test func nextWeekFromSundayIsTomorrow() {
        #expect(DeadlinePreset.nextWeek.date(from: date(2026, 11, 29, 22), calendar: calendar) == date(2026, 11, 30))
    }

    @Test func shortLabelTodayTomorrowAndDate() {
        let now = date(2026, 11, 25, 15, 30)
        #expect(DeadlinePreset.shortLabel(for: date(2026, 11, 25), now: now, calendar: calendar) == "Today")
        #expect(DeadlinePreset.shortLabel(for: date(2026, 11, 26), now: now, calendar: calendar) == "Tomorrow")
        #expect(DeadlinePreset.shortLabel(for: date(2026, 11, 28), now: now, calendar: calendar) == "Nov 28")
        #expect(DeadlinePreset.shortLabel(for: date(2026, 11, 24), now: now, calendar: calendar) == "Nov 24")
    }

    @Test func pickedDayThatHasPassedIsDropped() {
        let now = date(2026, 11, 26, 8)
        #expect(DeadlinePreset.unexpired(date(2026, 11, 25), now: now, calendar: calendar) == nil)
        #expect(DeadlinePreset.unexpired(date(2026, 11, 26), now: now, calendar: calendar) == date(2026, 11, 26))
        #expect(DeadlinePreset.unexpired(date(2026, 11, 27), now: now, calendar: calendar) == date(2026, 11, 27))
        #expect(DeadlinePreset.unexpired(nil, now: now, calendar: calendar) == nil)
    }

    @Test func titles() {
        #expect(DeadlinePreset.allCases.map(\.title) == ["Today", "Tomorrow", "Next week"])
    }
}
