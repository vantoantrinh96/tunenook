import Foundation
import SwiftData

/// Reacts to the timer: saves sessions, updates rewards, celebrates and steers the music.
@MainActor
final class SessionCoordinator {
    private let context: ModelContext
    private let engine: TimerEngine
    private let goalStore: GoalStore
    private let rewards: RewardStore
    private let notifications: NotificationService
    private let celebrations: CelebrationCenter
    private let music: MusicDirector

    init(
        context: ModelContext,
        engine: TimerEngine,
        goalStore: GoalStore,
        rewards: RewardStore,
        notifications: NotificationService,
        celebrations: CelebrationCenter,
        music: MusicDirector
    ) {
        self.context = context
        self.engine = engine
        self.goalStore = goalStore
        self.rewards = rewards
        self.notifications = notifications
        self.celebrations = celebrations
        self.music = music
    }

    func attach() {
        engine.onSessionEnded = { [weak self] in self?.sessionEnded($0) }
        engine.onRunningScheduled = { [weak self] in self?.runningScheduled($0, endsAt: $1) }
        engine.onRunningCancelled = { [weak self] in self?.runningCancelled() }
        // Catch up on rewards earned before this version, without celebrating them.
        rewards.update(with: currentProgress().achievements)
    }

    // MARK: Timer events

    private func sessionEnded(_ record: SessionRecord) {
        let before = currentProgress().snapshot
        context.insert(FocusSession(
            kind: record.kind,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            activeSeconds: record.activeDuration,
            completed: record.completed,
            task: record.task
        ))
        try? context.save()

        switch (record.kind, record.completed) {
        case (.focus, true):
            let progress = currentProgress()
            let after = progress.snapshot
            let unlocked = rewards.update(with: progress.achievements)
            if !before.todayMet && after.todayMet {
                notifications.notifyGoalReached(streak: after.currentStreak)
            }
            celebrations.celebrate(Celebrations.events(
                before: before, after: after, unlocked: unlocked, taskTitle: record.task?.title
            ))
            music.handle(.breakTime)
        case (.focus, false):
            // Starting focus on another task stops the current one first; wait to see if the timer restarts.
            Task { @MainActor [weak self] in
                guard let self, !self.engine.isActive else { return }
                self.music.handle(.stopped)
            }
        case (_, false):
            music.handle(.focusReady)
        default:
            break
        }
    }

    private func runningScheduled(_ kind: SessionKind, endsAt: Date) {
        notifications.schedulePhaseEnd(kind, at: endsAt, taskTitle: engine.currentTask?.title)
        music.handle(kind == .focus ? .focus : .breakTime)
    }

    private func runningCancelled() {
        notifications.cancel()
        if engine.isPaused { music.handle(.paused) }
    }

    // MARK: Progress

    private struct Progress {
        var snapshot: RewardSnapshot
        var achievements: AchievementProgress
    }

    private func currentProgress() -> Progress {
        let sessions = (try? context.fetch(FetchDescriptor(predicate: FocusSession.completedFocus))) ?? []
        let progress = FocusProgress(sessions: sessions, goalStore: goalStore)
        return Progress(
            snapshot: RewardSnapshot(todayMet: progress.todayMet, currentStreak: progress.streak.current),
            achievements: AchievementProgress(
                totalSessions: sessions.count,
                longestStreak: progress.streak.longest,
                goalDays: progress.streak.metDays.count
            )
        )
    }
}
