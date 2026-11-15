import Foundation
import Testing
@testable import TuneNook

struct FocusStatsTests {
    var calendar: FocusCalendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return FocusCalendar(calendar: cal, dayStartHour: 0)
    }()

    /// Noon on day `n` after a fixed start date.
    func noon(_ n: Int) -> Date {
        let start = calendar.calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
        return calendar.adding(days: n, to: start)
    }

    func day(_ n: Int) -> Date { calendar.day(for: noon(n)) }

    /// Two 25-minute sessions per listed day: meets a 50-minute goal.
    func totals(days: [Int], minutesEach: Double = 25, perDay: Int = 2) -> [Date: DayTotal] {
        let sessions = days.flatMap { d in
            (0..<perDay).map { _ in SessionSnapshot(endedAt: noon(d), duration: minutesEach * 60) }
        }
        return FocusStats.totals(sessions, calendar: calendar)
    }

    var goals: GoalHistory {
        var history = GoalHistory()
        history.set(DailyGoal(kind: .minutes, target: 50), from: day(-100))
        return history
    }

    @Test func consecutiveDaysBuildStreak() {
        let summary = FocusStats.streak(totals: totals(days: [0, 1, 2]), goals: goals, today: day(2), calendar: calendar)
        #expect(summary.current == 3)
        #expect(summary.longest == 3)
    }

    @Test func unfinishedTodayDoesNotBreakStreak() {
        let summary = FocusStats.streak(totals: totals(days: [0, 1, 2]), goals: goals, today: day(3), calendar: calendar)
        #expect(summary.current == 3)
    }

    @Test func missedDayResetsWithoutFreeze() {
        let summary = FocusStats.streak(totals: totals(days: [0, 1, 3, 4]), goals: goals, today: day(4), calendar: calendar)
        #expect(summary.current == 2)
        #expect(summary.longest == 2)
    }

    @Test func belowGoalCountsAsMissed() {
        var t = totals(days: [0, 1, 3])
        t.merge(totals(days: [2], perDay: 1)) { a, b in DayTotal(seconds: a.seconds + b.seconds, sessions: a.sessions + b.sessions) }
        let summary = FocusStats.streak(totals: t, goals: goals, today: day(3), calendar: calendar)
        #expect(summary.current == 1)
    }

    @Test func sevenDayStreakEarnsFreezeThatCoversMiss() {
        // Days 0–6 met (earns a freeze), day 7 missed, days 8–9 met.
        let summary = FocusStats.streak(
            totals: totals(days: [0, 1, 2, 3, 4, 5, 6, 8, 9]), goals: goals, today: day(9), calendar: calendar
        )
        #expect(summary.frozenDays == [day(7)])
        #expect(summary.current == 9)
        #expect(summary.freezesAvailable == 0)
    }

    @Test func freezesAreCapped() {
        let summary = FocusStats.streak(totals: totals(days: Array(0..<28)), goals: goals, today: day(27), calendar: calendar)
        #expect(summary.freezesAvailable == FocusStats.maxFreezes)
    }

    @Test func goalChangeDoesNotRewritePast() {
        var history = goals
        history.set(DailyGoal(kind: .sessions, target: 5), from: day(2))
        // Days 0–1 met under the old 50-minute goal; day 2 has only 2 sessions.
        let summary = FocusStats.streak(totals: totals(days: [0, 1, 2]), goals: history, today: day(3), calendar: calendar)
        #expect(summary.metDays == [day(0), day(1)])
        #expect(summary.current == 0)
    }

    @Test func dayStartHourShiftsLateNightWork() {
        var late = calendar
        late.dayStartHour = 4
        let twoAM = calendar.calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 2))!
        let previousDay = calendar.calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        #expect(late.day(for: twoAM) == previousDay)
        #expect(calendar.day(for: twoAM) != previousDay)
    }

    @Test func heatmapLevels() {
        let goal = DailyGoal(kind: .minutes, target: 100)
        #expect(FocusStats.level(for: .zero, goal: goal) == 0)
        #expect(FocusStats.level(for: DayTotal(seconds: 10 * 60, sessions: 1), goal: goal) == 1)
        #expect(FocusStats.level(for: DayTotal(seconds: 50 * 60, sessions: 2), goal: goal) == 2)
        #expect(FocusStats.level(for: DayTotal(seconds: 75 * 60, sessions: 3), goal: goal) == 3)
        #expect(FocusStats.level(for: DayTotal(seconds: 100 * 60, sessions: 4), goal: goal) == 4)
    }
}
