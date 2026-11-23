import Foundation
import SwiftData
import Testing
@testable import TuneNook

/// Counts `UserDefaults.didChangeNotification`s; posted synchronously.
private final class ChangeCounter: @unchecked Sendable {
    var count = 0
}

@MainActor
final class ApplierSpy {
    var radioStopped = true
    var stations: [String] = []
    var deletedTitles: [String] = []
}

@MainActor
struct SnapshotApplierTests {
    let container: ModelContainer
    let context: ModelContext
    let defaults: UserDefaults
    let goalStore: GoalStore
    let rewards: RewardStore
    let clock = FakeClock()
    let engine: TimerEngine
    let spy = ApplierSpy()

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var meta: SyncMeta { SyncMeta(modifiedAt: t0, modifiedBy: "mac-B", deleted: false) }

    init() throws {
        container = try ModelContainer(
            for: Topic.self, TodoTask.self, FocusSession.self,
            configurations: .init(isStoredInMemoryOnly: true))
        context = container.mainContext
        defaults = TestDefaults.make()
        goalStore = GoalStore(defaults: defaults)
        rewards = RewardStore(defaults: defaults)
        let clock = self.clock
        let settings = TimerSettings(autoStartBreaks: false, autoStartFocus: false)
        engine = TimerEngine(clock: { clock.now }, settings: { settings })
    }

    private var applier: SnapshotApplier {
        let spy = self.spy
        return SnapshotApplier(
            context: context, defaults: defaults, goalStore: goalStore, rewards: rewards, engine: engine,
            radioIsStopped: { spy.radioStopped },
            setRadioStation: { spy.stations.append($0) },
            notifyTaskDeleted: { spy.deletedTitles.append($0) })
    }

    private func emptyState() -> ResolvedState {
        ResolvedState(topics: [], tasks: [], sessions: [], settings: [:], goals: [], unlockedIcons: [])
    }

    private func record(_ topic: Topic, name: String? = nil) -> SyncTopic {
        SyncTopic(id: topic.syncID, meta: meta, name: name ?? topic.name, colorHex: topic.colorHex,
                  createdAt: topic.createdAt.syncMillis, deadline: topic.deadline?.syncMillis, mergedInto: nil)
    }

    private func record(_ task: TodoTask, topicID: UUID) -> SyncTask {
        SyncTask(id: task.syncID, meta: meta, title: task.title, estimatedSessions: task.estimatedSessions,
                 isDone: task.isDone, createdAt: task.createdAt.syncMillis,
                 completedAt: task.completedAt?.syncMillis, topicID: topicID)
    }

    private func record(_ session: FocusSession, taskID: UUID?) -> SyncSession {
        SyncSession(id: session.syncID, meta: meta, kind: session.kindRaw,
                    startedAt: session.startedAt.syncMillis, endedAt: session.endedAt.syncMillis,
                    activeSeconds: session.activeSeconds, completed: session.completed, taskID: taskID)
    }

    /// The settings as they currently are locally.
    private func currentSettings() -> [String: SyncValue] {
        var result: [String: SyncValue] = [:]
        for setting in SyncedSetting.all { result[setting.key] = setting.read(from: defaults) }
        result["goals.dayStartHour"] = .int(goalStore.dayStartHour)
        result["rewards.menuBarIcon"] = .string(rewards.selectedIconID)
        return result
    }

    private func fetchTopics() throws -> [Topic] { try context.fetch(FetchDescriptor<Topic>()) }
    private func fetchTasks() throws -> [TodoTask] { try context.fetch(FetchDescriptor<TodoTask>()) }
    private func fetchSessions() throws -> [FocusSession] { try context.fetch(FetchDescriptor<FocusSession>()) }

    @Test func insertsUpdatesAndDeletes() throws {
        let a = Topic(name: "A", createdAt: t0), b = Topic(name: "B", createdAt: t0)
        context.insert(a); context.insert(b)
        try context.save()
        let cID = UUID()
        var state = emptyState()
        state.topics = [
            record(a, name: "A renamed"),
            SyncTopic(id: cID, meta: meta, name: "C", colorHex: "#43AA8B", createdAt: t0,
                      deadline: t0.addingTimeInterval(86_400), mergedInto: nil),
        ]

        try applier.apply(state)

        let topics = try fetchTopics()
        #expect(Set(topics.map(\.syncID)) == [a.syncID, cID])
        #expect(topics.first { $0.syncID == a.syncID }?.name == "A renamed")
        let c = try #require(topics.first { $0.syncID == cID })
        #expect(c.name == "C")
        #expect(c.colorHex == "#43AA8B")
        #expect(c.deadline == t0.addingTimeInterval(86_400))
        #expect(!context.hasChanges)
    }

    @Test func insertsTasksAndSessionsWithRelationships() throws {
        let topicID = UUID(), taskID = UUID(), sessionID = UUID()
        var state = emptyState()
        state.topics = [SyncTopic(id: topicID, meta: meta, name: "T", colorHex: "#fff", createdAt: t0,
                                  deadline: nil, mergedInto: nil)]
        state.tasks = [SyncTask(id: taskID, meta: meta, title: "Do", estimatedSessions: 3, isDone: true,
                                createdAt: t0, completedAt: t0.addingTimeInterval(60), topicID: topicID)]
        state.sessions = [SyncSession(id: sessionID, meta: meta, kind: "shortBreak", startedAt: t0,
                                      endedAt: t0.addingTimeInterval(300), activeSeconds: 290,
                                      completed: true, taskID: taskID)]

        try applier.apply(state)

        let task = try #require(try fetchTasks().first)
        #expect(task.syncID == taskID)
        #expect(task.topic?.syncID == topicID)
        #expect(task.estimatedSessions == 3 && task.isDone)
        #expect(task.completedAt == t0.addingTimeInterval(60))
        let session = try #require(try fetchSessions().first)
        #expect(session.syncID == sessionID)
        #expect(session.kindRaw == "shortBreak")
        #expect(session.activeSeconds == 290)
        #expect(session.task?.syncID == taskID)
    }

    @Test func movesTaskBeforeDeletingTopic() throws {
        let x = Topic(name: "X", createdAt: t0), y = Topic(name: "Y", createdAt: t0)
        let task = TodoTask(title: "Move me", topic: x, createdAt: t0)
        context.insert(x); context.insert(y); context.insert(task)
        try context.save()
        var state = emptyState()
        state.topics = [record(y)]
        state.tasks = [record(task, topicID: y.syncID)]

        try applier.apply(state)

        #expect(try fetchTopics().map(\.syncID) == [y.syncID])
        let survivor = try #require(try fetchTasks().first)
        #expect(survivor.syncID == task.syncID)
        #expect(survivor.topic?.syncID == y.syncID)
    }

    @Test func runningTaskDeletedKeepsTimer() throws {
        let topic = Topic(name: "Guitar", createdAt: t0)
        let task = TodoTask(title: "Scales", topic: topic, createdAt: t0)
        let session = FocusSession(kind: .focus, startedAt: t0, endedAt: t0.addingTimeInterval(1_500),
                                   activeSeconds: 1_500, completed: true, task: task)
        context.insert(topic); context.insert(task); context.insert(session)
        try context.save()
        engine.start(task: task)
        var state = emptyState()
        state.topics = [record(topic)]
        state.sessions = [record(session, taskID: nil)]

        try applier.apply(state)

        #expect(engine.isActive)
        #expect(engine.currentTask == nil)
        #expect(spy.deletedTitles == ["Scales"])
        #expect(try fetchTasks().isEmpty)
        let kept = try #require(try fetchSessions().first)
        #expect(kept.syncID == session.syncID)
        #expect(kept.task == nil)
    }

    @Test func idleTaskDeletedClearsSelectionQuietly() throws {
        let topic = Topic(name: "Guitar", createdAt: t0)
        let task = TodoTask(title: "Scales", topic: topic, createdAt: t0)
        context.insert(topic); context.insert(task)
        try context.save()
        engine.currentTask = task
        var state = emptyState()
        state.topics = [record(topic)]

        try applier.apply(state)

        #expect(engine.currentTask == nil)
        #expect(spy.deletedTitles.isEmpty)
    }

    @Test func settingsWrittenOnlyWhenDifferent() throws {
        defaults.set(50, forKey: "timer.focusMinutes")
        goalStore.setGoal(DailyGoal(kind: .sessions, target: 4), now: t0)
        var state = emptyState()
        state.settings = currentSettings()
        state.goals = goalStore.history.entries.map {
            SyncGoal(day: $0.effectiveFrom, meta: meta, kind: $0.goal.kind.rawValue, target: $0.goal.target)
        }
        state.unlockedIcons = rewards.unlockedIDs
        let counter = ChangeCounter()
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { _ in counter.count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        try applier.apply(state)
        #expect(counter.count == 0)

        // Sanity: the counter does see a real change.
        state.settings["timer.focusMinutes"] = .int(30)
        state.settings["music.breakAction"] = .string("pause")
        state.settings["goals.dayStartHour"] = .int(4)
        try applier.apply(state)
        #expect(counter.count > 0)
        #expect(defaults.integer(forKey: "timer.focusMinutes") == 30)
        #expect(defaults.string(forKey: "music.breakAction") == "pause")
        #expect(goalStore.dayStartHour == 4)
    }

    @Test func nullSettingRemovesValue() throws {
        defaults.set("jazz", forKey: "music.breakStationID")
        var state = emptyState()
        state.settings = ["music.breakStationID": .null]

        try applier.apply(state)

        #expect(defaults.object(forKey: "music.breakStationID") == nil)
    }

    @Test func goalHistoryReplaced() throws {
        goalStore.setGoal(DailyGoal(kind: .minutes, target: 60), now: t0)
        let d1 = t0.addingTimeInterval(86_400), d2 = t0.addingTimeInterval(3 * 86_400)
        var state = emptyState()
        state.goals = [
            SyncGoal(day: d1, meta: meta, kind: "sessions", target: 5),
            SyncGoal(day: d2, meta: meta, kind: "minutes", target: 150),
        ]

        try applier.apply(state)

        let expected = GoalHistory(entries: [
            .init(effectiveFrom: d1, goal: DailyGoal(kind: .sessions, target: 5)),
            .init(effectiveFrom: d2, goal: DailyGoal(kind: .minutes, target: 150)),
        ])
        #expect(goalStore.history == expected)
        #expect(GoalStore(defaults: defaults).history == expected)   // persisted
    }

    @Test func iconsUnionedAndSelected() throws {
        var state = emptyState()
        state.unlockedIcons = ["note", "timer"]
        state.settings = ["rewards.menuBarIcon": .string("timer")]

        try applier.apply(state)

        #expect(rewards.unlockedIDs == ["note", "timer"])
        #expect(rewards.selectedIconID == "timer")
        #expect(RewardStore(defaults: defaults).unlockedIDs == ["note", "timer"])   // persisted

        state.settings = ["rewards.menuBarIcon": .string("crown")]   // not unlocked anywhere
        try applier.apply(state)
        #expect(rewards.selectedIconID == "timer")
        #expect(!rewards.unlockedIDs.contains("crown"))
    }

    @Test func radioStationNotChangedWhilePlaying() throws {
        var state = emptyState()
        state.settings = ["radio.selectedStationID": .string("lofi")]

        spy.radioStopped = false
        try applier.apply(state)
        #expect(spy.stations.isEmpty)
        #expect(defaults.object(forKey: "radio.selectedStationID") == nil)

        spy.radioStopped = true
        try applier.apply(state)
        #expect(spy.stations == ["lofi"])
    }

    @Test func radioStationAlreadySelectedIsNotReapplied() throws {
        defaults.set("lofi", forKey: "radio.selectedStationID")
        var state = emptyState()
        state.settings = ["radio.selectedStationID": .string("lofi")]

        try applier.apply(state)

        #expect(spy.stations.isEmpty)
    }
}
