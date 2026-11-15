import Foundation

/// The parts of a focus session that statistics need, free of SwiftData.
struct SessionSnapshot: Sendable {
    let endedAt: Date
    let duration: TimeInterval
}

struct StreakSummary: Equatable, Sendable {
    var current = 0
    var longest = 0
    var freezesAvailable = 0
    var metDays: Set<Date> = []
    var frozenDays: Set<Date> = []

    static let empty = StreakSummary()
}

enum FocusStats {
    /// A streak earns one freeze every `freezeEvery` met days, holding at most `maxFreezes`.
    static let freezeEvery = 7
    static let maxFreezes = 2

    static func totals(_ sessions: [SessionSnapshot], calendar: FocusCalendar) -> [Date: DayTotal] {
        var totals: [Date: DayTotal] = [:]
        for session in sessions {
            let day = calendar.day(for: session.endedAt)
            totals[day, default: .zero].seconds += session.duration
            totals[day, default: .zero].sessions += 1
        }
        return totals
    }

    /// Walks every day from the first focus day to today.
    /// A missed day uses a freeze if one is available; otherwise the streak resets.
    /// Today never breaks the streak, since there is still time to meet the goal.
    static func streak(
        totals: [Date: DayTotal],
        goals: GoalHistory,
        today: Date,
        calendar: FocusCalendar
    ) -> StreakSummary {
        guard let firstDay = totals.keys.min(), firstDay <= today else { return .empty }

        var summary = StreakSummary()
        var running = 0
        for day in calendar.days(from: firstDay, through: today) {
            let total = totals[day] ?? .zero
            if goals.goal(on: day).isMet(total) {
                running += 1
                summary.metDays.insert(day)
                summary.longest = max(summary.longest, running)
                if running % freezeEvery == 0 {
                    summary.freezesAvailable = min(maxFreezes, summary.freezesAvailable + 1)
                }
            } else if day == today {
                continue
            } else if running > 0 && summary.freezesAvailable > 0 {
                summary.freezesAvailable -= 1
                summary.frozenDays.insert(day)
            } else {
                running = 0
            }
        }
        summary.current = running
        return summary
    }

    /// Heatmap intensity: 0 = nothing, 1–3 = partway to the goal, 4 = goal met.
    static func level(for total: DayTotal, goal: DailyGoal) -> Int {
        guard total.sessions > 0 else { return 0 }
        let progress = goal.progress(total)
        switch progress {
        case 1...: return 4
        case 0.66...: return 3
        case 0.33...: return 2
        default: return 1
        }
    }
}

/// Everything the progress UI needs, computed once from the stored sessions.
@MainActor
struct FocusProgress {
    let calendar: FocusCalendar
    let today: Date
    let totals: [Date: DayTotal]
    let goals: GoalHistory
    let streak: StreakSummary

    init(sessions: [FocusSession], goalStore: GoalStore, now: Date = .now) {
        let calendar = goalStore.calendar
        let snapshots = sessions
            .filter { $0.kind == .focus && $0.completed }
            .map { SessionSnapshot(endedAt: $0.endedAt, duration: $0.focusedDuration) }
        self.calendar = calendar
        self.today = calendar.day(for: now)
        self.goals = goalStore.history
        self.totals = FocusStats.totals(snapshots, calendar: calendar)
        self.streak = FocusStats.streak(totals: totals, goals: goals, today: today, calendar: calendar)
    }

    var todayGoal: DailyGoal { goals.goal(on: today) }
    var todayTotal: DayTotal { totals[today] ?? .zero }
    var todayMet: Bool { todayGoal.isMet(todayTotal) }

    func total(on day: Date) -> DayTotal { totals[day] ?? .zero }

    func level(on day: Date) -> Int {
        FocusStats.level(for: total(on: day), goal: goals.goal(on: day))
    }

    /// Total focus time over the last 7 days including today.
    var lastSevenDays: TimeInterval {
        (0..<7).reduce(0) { $0 + total(on: calendar.adding(days: -$1, to: today)).seconds }
    }
}
