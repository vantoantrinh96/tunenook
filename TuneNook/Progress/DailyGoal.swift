import Foundation
import Observation

struct DayTotal: Equatable, Sendable {
    var seconds: TimeInterval = 0
    var sessions: Int = 0

    var minutes: Int { Int(seconds / 60) }

    static let zero = DayTotal()
}

struct DailyGoal: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case minutes
        case sessions
    }

    var kind: Kind
    var target: Int

    static let `default` = DailyGoal(kind: .minutes, target: 120)

    static func defaultTarget(for kind: Kind) -> Int {
        kind == .minutes ? 120 : 4
    }

    func achieved(_ total: DayTotal) -> Int {
        kind == .minutes ? total.minutes : total.sessions
    }

    func progress(_ total: DayTotal) -> Double {
        target > 0 ? Double(achieved(total)) / Double(target) : 0
    }

    func isMet(_ total: DayTotal) -> Bool {
        achieved(total) >= target
    }

    var unit: String { kind == .minutes ? "min" : "sessions" }
}

/// Every goal the user has set, each effective from a focus day onward.
/// Changing the goal today never rewrites whether past days were met.
struct GoalHistory: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var effectiveFrom: Date
        var goal: DailyGoal
    }

    private(set) var entries: [Entry] = []

    init(entries: [Entry] = []) {
        self.entries = entries.sorted { $0.effectiveFrom < $1.effectiveFrom }
    }

    var current: DailyGoal { entries.last?.goal ?? .default }

    func goal(on day: Date) -> DailyGoal {
        // Days before the first explicit goal were judged against the default.
        entries.last { $0.effectiveFrom <= day }?.goal ?? .default
    }

    mutating func set(_ goal: DailyGoal, from day: Date) {
        entries.removeAll { $0.effectiveFrom >= day }
        if entries.last?.goal != goal {
            entries.append(Entry(effectiveFrom: day, goal: goal))
        }
    }
}

/// Persists the goal history and the day boundary in UserDefaults.
@MainActor
@Observable
final class GoalStore {
    private(set) var history: GoalHistory
    var dayStartHour: Int {
        didSet { defaults.set(dayStartHour, forKey: Self.dayStartKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    private static let historyKey = "goals.history"
    private static let dayStartKey = "goals.dayStartHour"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.dayStartHour = defaults.integer(forKey: Self.dayStartKey)
        if let data = defaults.data(forKey: Self.historyKey),
           let history = try? JSONDecoder().decode(GoalHistory.self, from: data) {
            self.history = history
        } else {
            self.history = GoalHistory()
        }
    }

    var calendar: FocusCalendar { FocusCalendar(dayStartHour: dayStartHour) }
    var current: DailyGoal { history.current }

    func setGoal(_ goal: DailyGoal, now: Date = .now) {
        history.set(goal, from: calendar.day(for: now))
        persistHistory()
    }

    /// Replaces the whole history, e.g. with the one merged from other Macs.
    func replaceHistory(_ history: GoalHistory) {
        self.history = history
        persistHistory()
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: Self.historyKey)
        }
    }
}
