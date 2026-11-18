import Foundation
import Testing
@testable import TuneNook

struct EstimateStatsTests {
    var calendar: FocusCalendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        cal.firstWeekday = 2 // Monday
        return FocusCalendar(calendar: cal, dayStartHour: 4)
    }()

    /// `hour` o'clock on day `n` after Monday, 2 November 2026.
    func date(_ n: Int, hour: Int = 12) -> Date {
        let start = calendar.calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: hour))!
        return calendar.calendar.date(byAdding: .day, value: n, to: start)!
    }

    func sample(_ estimated: Int, _ actual: Int, day: Int = 0, topic: String? = "A") -> EstimateSample<String> {
        EstimateSample(estimated: estimated, actual: actual, completedAt: date(day), group: topic)
    }

    @Test func outcomeComparesActualWithEstimate() {
        #expect(sample(3, 2).outcome == .under)
        #expect(sample(3, 3).outcome == .onTarget)
        #expect(sample(3, 5).outcome == .over)
    }

    @Test func eligibleSkipsUntimedTasksAndOlderOnes() {
        let samples = [sample(2, 0), sample(2, 2, day: -10), sample(2, 3, day: 0), sample(0, 1)]
        #expect(EstimateStats.eligible(samples, since: nil).count == 2)
        #expect(EstimateStats.eligible(samples, since: date(-5)).count == 1)
    }

    @Test func summaryAddsUpTasksAndOutcomes() {
        let summary = EstimateStats.summary([sample(2, 1), sample(2, 2), sample(4, 7)])
        #expect(summary.tasks == 3)
        #expect(summary.estimated == 8)
        #expect(summary.actual == 10)
        #expect(summary.under == 1)
        #expect(summary.onTarget == 1)
        #expect(summary.over == 1)
        #expect(summary.ratio == 1.25)
    }

    @Test func emptySummaryHasNoRatio() {
        #expect(EstimateSummary.empty.ratio == nil)
    }

    @Test func byGroupSplitsPerTopicAndSkipsTasksWithoutOne() {
        let groups = EstimateStats.byGroup([sample(2, 4, topic: "A"), sample(1, 1, topic: "B"), sample(3, 3, topic: "A"), sample(5, 1, topic: nil)])
        #expect(groups.count == 2)
        #expect(groups["A"]?.tasks == 2)
        #expect(groups["A"]?.actual == 7)
        #expect(groups["B"]?.ratio == 1)
    }

    @Test func biggestMissesAreWorstFirstAndSkipExactOnes() {
        let misses = EstimateStats.biggestMisses(
            [sample(2, 2), sample(1, 4, day: 0), sample(6, 2, day: 1), sample(2, 3), sample(3, 6, day: 2)],
            limit: 3
        )
        #expect(misses.map(\.miss) == [4, 3, 3])
        // Equal misses: the more recent task comes first.
        #expect(misses[1].completedAt == date(2))
    }

    @Test func weeklyBucketsByWeekWithEmptyWeeks() {
        let sessions = [
            SessionSnapshot(endedAt: date(0), duration: 1500), // Mon, week 0
            SessionSnapshot(endedAt: date(6), duration: 1500), // Sun, week 0
            SessionSnapshot(endedAt: date(14), duration: 600), // Mon, week 2
            SessionSnapshot(endedAt: date(-30), duration: 900), // too old
        ]
        let weeks = EstimateStats.weekly(sessions, weeks: 3, today: date(15), calendar: calendar)
        #expect(weeks.count == 3)
        #expect(weeks.map(\.sessions) == [2, 0, 1])
        #expect(weeks[0].seconds == 3000)
        #expect(weeks[0].weekStart == calendar.calendar.startOfDay(for: date(0)))
    }

    @Test func weeklyUsesFocusDayForLateNightWork() {
        // 2 AM on Monday of week 1 still belongs to Sunday (day starts at 4 AM), so week 0.
        let sessions = [SessionSnapshot(endedAt: date(7, hour: 2), duration: 1500)]
        let weeks = EstimateStats.weekly(sessions, weeks: 2, today: date(8), calendar: calendar)
        #expect(weeks.map(\.sessions) == [1, 0])
    }

    @Test func verdictDescribesTheRatio() {
        #expect(EstimateStats.verdict(for: 1.4) == "Tasks take 40% more sessions than you estimate")
        #expect(EstimateStats.verdict(for: 0.75) == "Tasks take 25% fewer sessions than you estimate")
        #expect(EstimateStats.verdict(for: 1.03) == "Your estimates are close to spot on")
    }
}
