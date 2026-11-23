import Foundation
import Testing
@testable import TuneNook

@MainActor
struct RewardsTests {
    func makeStore() -> RewardStore {
        let defaults = TestDefaults.make()
        return RewardStore(defaults: defaults)
    }

    @Test func classicIconIsAlwaysUnlocked() {
        let store = makeStore()
        #expect(store.isUnlocked(.classic))
        #expect(store.selectedIcon == .classic)
    }

    @Test func firstSessionUnlocksStopwatch() {
        let store = makeStore()
        let unlocked = store.update(with: AchievementProgress(totalSessions: 1))
        #expect(unlocked.map(\.id) == ["timer"])
        // Reporting the same progress again unlocks nothing new.
        #expect(store.update(with: AchievementProgress(totalSessions: 1)).isEmpty)
    }

    @Test func unlocksSurviveLowerProgress() {
        let store = makeStore()
        store.update(with: AchievementProgress(totalSessions: 12, longestStreak: 3))
        store.update(with: .init())
        #expect(store.unlockedIDs.isSuperset(of: ["timer", "leaf", "flame"]))
    }

    @Test func lockedIconCannotBeSelected() {
        let store = makeStore()
        store.select(MenuBarIcon.with(id: "crown")!)
        #expect(store.selectedIcon == .classic)
    }

    @Test func plainSessionGetsToast() {
        let events = Celebrations.events(before: .init(), after: .init(), unlocked: [], taskTitle: "Draft")
        #expect(events == [.sessionComplete(taskTitle: "Draft")])
        #expect(!CelebrationLevel.milestones.allows(events[0]))
        #expect(CelebrationLevel.everySession.allows(events[0]))
    }

    @Test func crossingGoalCelebratesOnce() {
        let before = RewardSnapshot(todayMet: false, currentStreak: 1)
        let after = RewardSnapshot(todayMet: true, currentStreak: 2)
        #expect(Celebrations.events(before: before, after: after, unlocked: [], taskTitle: nil) == [.goalReached(streak: 2)])
        // Another session on a day already met is just a session.
        let again = Celebrations.events(before: after, after: after, unlocked: [], taskTitle: nil)
        #expect(again == [.sessionComplete(taskTitle: nil)])
    }

    @Test func streakMilestoneReplacesGoalMessage() {
        let icon = MenuBarIcon.with(id: "star")!
        let events = Celebrations.events(
            before: RewardSnapshot(todayMet: false, currentStreak: 6),
            after: RewardSnapshot(todayMet: true, currentStreak: 7),
            unlocked: [icon],
            taskTitle: nil
        )
        #expect(events == [.streakMilestone(days: 7), .iconUnlocked(icon)])
        #expect(CelebrationLevel.off.allows(events[0]) == false)
    }
}
