import Foundation

/// A moment worth marking on screen.
enum Celebration: Equatable, Sendable {
    case sessionComplete(taskTitle: String?)
    case goalReached(streak: Int)
    case streakMilestone(days: Int)
    case iconUnlocked(MenuBarIcon)

    /// Milestones get confetti; a finished session gets a quiet toast.
    var isMilestone: Bool {
        if case .sessionComplete = self { false } else { true }
    }

    var symbol: String {
        switch self {
        case .sessionComplete: "music.note"
        case .goalReached: "checkmark.seal.fill"
        case .streakMilestone: "flame.fill"
        case .iconUnlocked(let icon): icon.symbol
        }
    }

    var title: String {
        switch self {
        case .sessionComplete: "Session complete"
        case .goalReached: "Daily goal reached"
        case .streakMilestone(let days): "\(days)-day streak!"
        case .iconUnlocked(let icon): "New icon: \(icon.name)"
        }
    }

    var subtitle: String {
        switch self {
        case .sessionComplete(let title):
            title.map { "+1 ♪ on “\($0)”" } ?? "+1 ♪ Time for a break."
        case .goalReached(let streak):
            streak > 1 ? "\(streak) days in a row. Keep it going!" : "Great start. Come back tomorrow."
        case .streakMilestone(let days):
            "You've met your goal \(days) days running."
        case .iconUnlocked:
            "Pick it in Settings → Rewards."
        }
    }
}

/// How much celebrating the user wants.
enum CelebrationLevel: String, CaseIterable, Sendable {
    case off
    case milestones
    case everySession

    static let key = "celebrations.level"

    static var current: CelebrationLevel {
        UserDefaults.standard.string(forKey: key).flatMap(CelebrationLevel.init) ?? .milestones
    }

    func allows(_ celebration: Celebration) -> Bool {
        switch self {
        case .off: false
        case .milestones: celebration.isMilestone
        case .everySession: true
        }
    }

    var title: String {
        switch self {
        case .off: "Off"
        case .milestones: "Milestones only"
        case .everySession: "Every session"
        }
    }
}

/// Progress right before and right after a session was saved.
struct RewardSnapshot: Equatable, Sendable {
    var todayMet = false
    var currentStreak = 0
}

enum Celebrations {
    static let streakMilestones: Set<Int> = [3, 7, 14, 21, 30, 50, 75, 100, 150, 200, 365]

    /// What to celebrate after a completed focus session, most important first.
    static func events(
        before: RewardSnapshot,
        after: RewardSnapshot,
        unlocked: [MenuBarIcon],
        taskTitle: String?
    ) -> [Celebration] {
        var events: [Celebration] = []
        if !before.todayMet && after.todayMet {
            if streakMilestones.contains(after.currentStreak) {
                events.append(.streakMilestone(days: after.currentStreak))
            } else {
                events.append(.goalReached(streak: after.currentStreak))
            }
        }
        events += unlocked.map(Celebration.iconUnlocked)
        if events.isEmpty {
            events.append(.sessionComplete(taskTitle: taskTitle))
        }
        return events
    }
}
