import Testing
import Foundation
@testable import TuneNook

@Suite struct SyncResolveTests {
    func at(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + offset) }
    func meta(_ offset: TimeInterval = 0, deleted: Bool = false) -> SyncMeta {
        SyncMeta(modifiedAt: at(offset), modifiedBy: "A", deleted: deleted)
    }
    func topic(_ id: UUID, deleted: Bool = false, mergedInto: UUID? = nil, at t: TimeInterval = 0) -> SyncTopic {
        SyncTopic(id: id, meta: meta(t, deleted: deleted), name: "n", colorHex: "#fff", createdAt: at(-1000),
                  deadline: nil, mergedInto: mergedInto)
    }
    func task(_ id: UUID, topic: UUID?, deleted: Bool = false, at t: TimeInterval = 0) -> SyncTask {
        SyncTask(id: id, meta: meta(t, deleted: deleted), title: "t", estimatedSessions: 1, isDone: false,
                 createdAt: at(-1000), completedAt: nil, topicID: topic)
    }
    func session(_ id: UUID, task: UUID?, deleted: Bool = false) -> SyncSession {
        SyncSession(id: id, meta: meta(0, deleted: deleted), kind: "focus", startedAt: at(-500), endedAt: at(-400),
                    activeSeconds: 100, completed: true, taskID: task)
    }
    func snap(topics: [SyncTopic] = [], tasks: [SyncTask] = [], sessions: [SyncSession] = [],
              goals: [SyncGoal] = [], settings: [String: SyncSetting] = [:], icons: [String] = []) -> DeviceSnapshot {
        var s = DeviceSnapshot.empty(deviceID: "A", deviceName: "A")
        s.topics = topics; s.tasks = tasks; s.sessions = sessions
        s.goals = goals; s.settings = settings; s.unlockedIcons = icons
        return s
    }

    @Test func taskInMergedTopicFollowsTarget() {
        let x = UUID(), y = UUID(), t = UUID()
        let r = SyncMerge.resolve(snap(topics: [topic(x, deleted: true, mergedInto: y), topic(y)],
                                       tasks: [task(t, topic: x)]))
        #expect(r.tasks.map(\.topicID) == [y])
        #expect(r.topics.map(\.id) == [y])
    }

    @Test func taskAddedOfflineToMergedTopicFollowsTarget() {
        let x = UUID(), y = UUID(), t = UUID()
        let r = SyncMerge.resolve(snap(topics: [topic(x, deleted: true, mergedInto: y, at: 10), topic(y)],
                                       tasks: [task(t, topic: x, at: 50)]))
        #expect(r.tasks.map(\.topicID) == [y])
    }

    @Test func mergeChainIsFollowed() {
        let x = UUID(), y = UUID(), z = UUID(), t = UUID()
        let r = SyncMerge.resolve(snap(topics: [topic(x, deleted: true, mergedInto: y),
                                                topic(y, deleted: true, mergedInto: z), topic(z)],
                                       tasks: [task(t, topic: x)]))
        #expect(r.tasks.map(\.topicID) == [z])
    }

    @Test func mergeCycleCountsAsDeleted() {
        let x = UUID(), y = UUID(), t = UUID()
        let r = SyncMerge.resolve(snap(topics: [topic(x, deleted: true, mergedInto: y),
                                                topic(y, deleted: true, mergedInto: x)],
                                       tasks: [task(t, topic: x)]))
        #expect(r.tasks.isEmpty)
    }

    @Test func taskInDeletedTopicIsDropped() {
        let x = UUID(), t = UUID()
        let r = SyncMerge.resolve(snap(topics: [topic(x, deleted: true)], tasks: [task(t, topic: x, at: 99)]))
        #expect(r.tasks.isEmpty)
    }

    @Test func taskWithUnknownTopicIsHeldBack() {
        let t = UUID(), s = UUID()
        let r = SyncMerge.resolve(snap(tasks: [task(t, topic: UUID())], sessions: [session(s, task: t)]))
        #expect(r.tasks.isEmpty)
        #expect(r.sessions.map(\.id) == [s])
        #expect(r.sessions.first?.taskID == nil)
    }

    @Test func taskWithoutTopicIsDropped() {
        let r = SyncMerge.resolve(snap(tasks: [task(UUID(), topic: nil)]))
        #expect(r.tasks.isEmpty)
    }

    @Test func sessionOfDroppedTaskLosesTask() {
        let x = UUID(), t = UUID(), s = UUID()
        let r = SyncMerge.resolve(snap(topics: [topic(x, deleted: true)], tasks: [task(t, topic: x)],
                                       sessions: [session(s, task: t)]))
        #expect(r.sessions.count == 1)
        #expect(r.sessions[0].taskID == nil)
    }

    @Test func sessionKeepsLiveTask() {
        let x = UUID(), t = UUID(), s = UUID()
        let r = SyncMerge.resolve(snap(topics: [topic(x)], tasks: [task(t, topic: x)], sessions: [session(s, task: t)]))
        #expect(r.sessions[0].taskID == t)
    }

    @Test func tombstonesAreNotResolved() {
        let x = UUID(), live = UUID(), t = UUID(), s = UUID()
        let goal = SyncGoal(day: at(0), meta: meta(0, deleted: true), kind: "focus", target: 3)
        let liveGoal = SyncGoal(day: at(-86_400), meta: meta(), kind: "focus", target: 2)
        let r = SyncMerge.resolve(snap(topics: [topic(x, deleted: true), topic(live)],
                                       tasks: [task(t, topic: live, deleted: true)],
                                       sessions: [session(s, task: nil, deleted: true)],
                                       goals: [goal, liveGoal],
                                       settings: ["a": SyncSetting(value: .int(1), meta: meta()),
                                                  "b": SyncSetting(value: .int(2), meta: meta(0, deleted: true))],
                                       icons: ["note", "bolt"]))
        #expect(r.topics.map(\.id) == [live])
        #expect(r.tasks.isEmpty)
        #expect(r.sessions.isEmpty)
        #expect(r.goals == [liveGoal])
        #expect(r.settings == ["a": .int(1)])
        #expect(r.unlockedIcons == ["note", "bolt"])
    }
}
