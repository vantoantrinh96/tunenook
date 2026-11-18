import Foundation

/// A finished task's estimate and what it really took, free of SwiftData.
/// `Group` identifies the task's topic, so tests can use plain strings.
struct EstimateSample<Group: Hashable & Sendable>: Sendable {
    let estimated: Int
    let actual: Int
    let completedAt: Date
    let group: Group?

    var outcome: EstimateOutcome {
        if actual < estimated { return .under }
        if actual > estimated { return .over }
        return .onTarget
    }

    /// How far off the estimate was, in sessions.
    var miss: Int { abs(actual - estimated) }
}

enum EstimateOutcome: CaseIterable, Sendable {
    case under, onTarget, over

    var title: String {
        switch self {
        case .under: "Under"
        case .onTarget: "On estimate"
        case .over: "Over"
        }
    }
}

struct EstimateSummary: Equatable, Sendable {
    var tasks = 0
    var estimated = 0
    var actual = 0
    var under = 0
    var onTarget = 0
    var over = 0

    static let empty = EstimateSummary()

    /// Actual sessions per estimated session. 1.25 means tasks take 25% longer than planned.
    var ratio: Double? {
        estimated > 0 ? Double(actual) / Double(estimated) : nil
    }

    func count(_ outcome: EstimateOutcome) -> Int {
        switch outcome {
        case .under: under
        case .onTarget: onTarget
        case .over: over
        }
    }

    mutating func add(estimated: Int, actual: Int, outcome: EstimateOutcome) {
        tasks += 1
        self.estimated += estimated
        self.actual += actual
        switch outcome {
        case .under: under += 1
        case .onTarget: onTarget += 1
        case .over: over += 1
        }
    }
}

/// How much focus fell in one week.
struct WeekTotal: Equatable, Sendable, Identifiable {
    let weekStart: Date
    var seconds: TimeInterval
    var sessions: Int

    var id: Date { weekStart }
}

enum EstimateStats {
    /// Within this much of 1×, estimates count as accurate overall.
    static let accurateBand = 0.05

    /// Tasks that say something about estimating: finished, with at least one focus session,
    /// and completed on or after `since` (all time when nil).
    static func isEligible<G>(_ sample: EstimateSample<G>, since: Date?) -> Bool {
        sample.actual > 0 && sample.estimated > 0 && (since.map { sample.completedAt >= $0 } ?? true)
    }

    static func eligible<G>(_ samples: [EstimateSample<G>], since: Date?) -> [EstimateSample<G>] {
        samples.filter { isEligible($0, since: since) }
    }

    static func summary<G>(_ samples: [EstimateSample<G>]) -> EstimateSummary {
        samples.reduce(into: .empty) { $0.add(estimated: $1.estimated, actual: $1.actual, outcome: $1.outcome) }
    }

    /// One summary per topic. Tasks without a topic are left out.
    static func byGroup<G>(_ samples: [EstimateSample<G>]) -> [G: EstimateSummary] {
        var result: [G: EstimateSummary] = [:]
        for sample in samples {
            guard let group = sample.group else { continue }
            result[group, default: .empty].add(estimated: sample.estimated, actual: sample.actual, outcome: sample.outcome)
        }
        return result
    }

    /// Tasks whose estimate was furthest off, worst first. Ties go to the most recent.
    static func biggestMisses<G>(_ samples: [EstimateSample<G>], limit: Int) -> [EstimateSample<G>] {
        Array(samples.filter { $0.miss > 0 }.sorted { isWorseMiss($0, than: $1) }.prefix(limit))
    }

    static func isWorseMiss<G>(_ a: EstimateSample<G>, than b: EstimateSample<G>) -> Bool {
        (a.miss, a.completedAt) > (b.miss, b.completedAt)
    }

    /// Focus per week for the last `weeks` weeks, oldest first, including the current week.
    /// Weeks follow the focus day (so late-night work counts toward the right day) and the
    /// calendar's first weekday. Weeks without focus are present with zero.
    static func weekly(_ sessions: [SessionSnapshot], weeks: Int, today: Date, calendar: FocusCalendar) -> [WeekTotal] {
        guard weeks > 0 else { return [] }
        let cal = calendar.calendar
        func weekStart(of day: Date) -> Date {
            cal.dateInterval(of: .weekOfYear, for: day)?.start ?? day
        }
        let current = weekStart(of: calendar.day(for: today))
        let starts = (0..<weeks).reversed().map {
            cal.date(byAdding: .weekOfYear, value: -$0, to: current) ?? current
        }
        var totals = Dictionary(uniqueKeysWithValues: starts.map { ($0, WeekTotal(weekStart: $0, seconds: 0, sessions: 0)) })
        for session in sessions {
            let start = weekStart(of: calendar.day(for: session.endedAt))
            guard totals[start] != nil else { continue }
            totals[start]!.seconds += session.duration
            totals[start]!.sessions += 1
        }
        return starts.compactMap { totals[$0] }
    }

    /// Plain-language read of a ratio, e.g. "Tasks take 40% more sessions than you estimate".
    static func verdict(for ratio: Double) -> String {
        let percent = Int((abs(ratio - 1) * 100).rounded())
        if abs(ratio - 1) <= accurateBand { return "Your estimates are close to spot on" }
        return ratio > 1
            ? "Tasks take \(percent)% more sessions than you estimate"
            : "Tasks take \(percent)% fewer sessions than you estimate"
    }
}
