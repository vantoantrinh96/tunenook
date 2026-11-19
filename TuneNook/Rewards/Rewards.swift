import Foundation
import Observation

/// Lifetime numbers that unlock rewards.
struct AchievementProgress: Equatable, Sendable {
    var totalSessions = 0
    var longestStreak = 0
    var goalDays = 0
}

/// A menu bar icon the user can earn and pick.
struct MenuBarIcon: Identifiable, Hashable, Sendable {
    enum Requirement: Hashable, Sendable {
        case free
        case sessions(Int)
        case streak(Int)
        case goalDays(Int)
    }

    let id: String
    let symbol: String
    let name: String
    let requirement: Requirement

    func isEarned(by progress: AchievementProgress) -> Bool {
        switch requirement {
        case .free: true
        case .sessions(let n): progress.totalSessions >= n
        case .streak(let n): progress.longestStreak >= n
        case .goalDays(let n): progress.goalDays >= n
        }
    }

    /// How far along the requirement is, from 0 to 1.
    func completion(for progress: AchievementProgress) -> Double {
        switch requirement {
        case .free: 1
        case .sessions(let n): min(1, Double(progress.totalSessions) / Double(n))
        case .streak(let n): min(1, Double(progress.longestStreak) / Double(n))
        case .goalDays(let n): min(1, Double(progress.goalDays) / Double(n))
        }
    }

    var requirementText: String {
        switch requirement {
        case .free: "Always yours"
        case .sessions(1): "Finish your first focus session"
        case .sessions(let n): "Finish \(n) focus sessions"
        case .streak(let n): "Reach a \(n)-day streak"
        case .goalDays(let n): "Meet your daily goal on \(n) days"
        }
    }

    func progressText(for progress: AchievementProgress) -> String {
        switch requirement {
        case .free: ""
        case .sessions(let n): "\(min(progress.totalSessions, n)) / \(n) sessions"
        case .streak(let n): "Best \(min(progress.longestStreak, n)) / \(n) days"
        case .goalDays(let n): "\(min(progress.goalDays, n)) / \(n) goal days"
        }
    }

    static let classic = MenuBarIcon(id: "note", symbol: "music.note", name: "Classic", requirement: .free)

    /// Ordered roughly by how long each takes to earn.
    static let all: [MenuBarIcon] = [
        classic,
        MenuBarIcon(id: "timer", symbol: "timer", name: "Stopwatch", requirement: .sessions(1)),
        MenuBarIcon(id: "flame", symbol: "flame.fill", name: "Warm Up", requirement: .streak(3)),
        MenuBarIcon(id: "leaf", symbol: "leaf.fill", name: "Sprout", requirement: .sessions(10)),
        MenuBarIcon(id: "star", symbol: "star.fill", name: "Star Week", requirement: .streak(7)),
        MenuBarIcon(id: "headphones", symbol: "headphones", name: "Deep Listener", requirement: .sessions(25)),
        MenuBarIcon(id: "sparkles", symbol: "sparkles", name: "Fortnight", requirement: .streak(14)),
        MenuBarIcon(id: "mountain", symbol: "mountain.2.fill", name: "Summit", requirement: .goalDays(20)),
        MenuBarIcon(id: "trophy", symbol: "trophy.fill", name: "Centurion", requirement: .sessions(100)),
        MenuBarIcon(id: "crown", symbol: "crown.fill", name: "Monthly Crown", requirement: .streak(30)),
    ]

    static func with(id: String) -> MenuBarIcon? {
        all.first { $0.id == id }
    }
}

/// Remembers which icons are unlocked and which one is in the menu bar.
/// Unlocks are kept even if the history that earned them is later deleted.
@MainActor
@Observable
final class RewardStore {
    private(set) var unlockedIDs: Set<String>
    private(set) var achievements = AchievementProgress()
    var selectedIconID: String {
        didSet { defaults.set(selectedIconID, forKey: Self.selectedKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    private static let unlockedKey = "rewards.unlockedIcons"
    private static let selectedKey = "rewards.menuBarIcon"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = Set(defaults.stringArray(forKey: Self.unlockedKey) ?? [])
        self.unlockedIDs = saved.union([MenuBarIcon.classic.id])
        let selected = defaults.string(forKey: Self.selectedKey) ?? MenuBarIcon.classic.id
        self.selectedIconID = saved.contains(selected) ? selected : MenuBarIcon.classic.id
    }

    var selectedIcon: MenuBarIcon {
        MenuBarIcon.with(id: selectedIconID) ?? .classic
    }

    func isUnlocked(_ icon: MenuBarIcon) -> Bool {
        unlockedIDs.contains(icon.id)
    }

    func select(_ icon: MenuBarIcon) {
        guard isUnlocked(icon) else { return }
        selectedIconID = icon.id
    }

    /// Adds icons unlocked elsewhere (e.g. on another Mac). Unknown IDs are kept
    /// so a newer app version's icons survive a round trip.
    func mergeUnlocked(_ ids: Set<String>) {
        guard !ids.isSubset(of: unlockedIDs) else { return }
        unlockedIDs.formUnion(ids)
        defaults.set(unlockedIDs.sorted(), forKey: Self.unlockedKey)
    }

    /// Records the latest progress and returns icons unlocked by it, in catalogue order.
    @discardableResult
    func update(with progress: AchievementProgress) -> [MenuBarIcon] {
        achievements = progress
        let newlyUnlocked = MenuBarIcon.all.filter { !unlockedIDs.contains($0.id) && $0.isEarned(by: progress) }
        guard !newlyUnlocked.isEmpty else { return [] }
        unlockedIDs.formUnion(newlyUnlocked.map(\.id))
        defaults.set(unlockedIDs.sorted(), forKey: Self.unlockedKey)
        return newlyUnlocked
    }
}
