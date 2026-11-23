import Foundation
import SwiftData
import Testing
@testable import TuneNook

@MainActor
struct SnapshotCaptureTests {
    let container: ModelContainer
    let context: ModelContext
    let defaults: UserDefaults
    let goalStore: GoalStore
    let rewards: RewardStore
    let identity = DeviceSnapshot.empty(deviceID: "mac-A", deviceName: "Mac A")

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var t1: Date { t0.addingTimeInterval(3_600) }
    var t2: Date { t0.addingTimeInterval(7_200) }

    init() throws {
        container = try ModelContainer(
            for: Topic.self, TodoTask.self, FocusSession.self,
            configurations: .init(isStoredInMemoryOnly: true))
        context = container.mainContext
        defaults = TestDefaults.make()
        goalStore = GoalStore(defaults: defaults)
        rewards = RewardStore(defaults: defaults)
    }

    private func capturer(merged: [UUID: UUID] = [:]) -> SnapshotCapture {
        SnapshotCapture(context: context, defaults: defaults, goalStore: goalStore, rewards: rewards,
                        identity: identity, mergedTopics: merged)
    }

    /// One topic with one task and one session on that task.
    @discardableResult
    private func seed() throws -> (Topic, TodoTask, FocusSession) {
        let topic = Topic(name: "Guitar", createdAt: t0.addingTimeInterval(-500))
        let task = TodoTask(title: "Scales", topic: topic, createdAt: t0.addingTimeInterval(-400))
        let session = FocusSession(kind: .focus, startedAt: t0.addingTimeInterval(-300),
                                   endedAt: t0.addingTimeInterval(-200), activeSeconds: 100,
                                   completed: true, task: task)
        context.insert(topic); context.insert(task); context.insert(session)
        try context.save()
        return (topic, task, session)
    }

    private func day(_ n: Int) -> Date { t0.addingTimeInterval(Double(n) * 86_400) }

    @Test func firstCaptureStampsDistantPast() throws {
        let (topic, task, session) = try seed()
        goalStore.setGoal(DailyGoal(kind: .sessions, target: 6), now: t0)
        defaults.set(50, forKey: "timer.focusMinutes")

        let snap = try capturer().capture(baseline: nil, now: t1)

        #expect(snap.topics.map(\.id) == [topic.syncID])
        #expect(snap.tasks.map(\.id) == [task.syncID])
        #expect(snap.tasks.first?.topicID == topic.syncID)
        #expect(snap.sessions.map(\.id) == [session.syncID])
        #expect(snap.sessions.first?.taskID == task.syncID)
        #expect(snap.goals.count == 1)
        #expect(snap.goals.first?.target == 6)
        #expect(snap.settings["timer.focusMinutes"]?.value == .int(50))
        #expect(snap.settings.count == SyncedSetting.all.count)
        #expect(snap.deviceID == identity.deviceID)
        #expect(snap.exportedAt == t1)
        #expect(snap.unlockedIcons.contains(MenuBarIcon.classic.id))

        let metas = snap.topics.map(\.meta) + snap.tasks.map(\.meta) + snap.sessions.map(\.meta)
            + snap.goals.map(\.meta) + snap.settings.values.map(\.meta)
        for meta in metas {
            #expect(meta.modifiedAt == .distantPast)
            #expect(meta.modifiedBy == identity.deviceID)
            #expect(meta.deleted == false)
        }
    }

    @Test func unchangedRowsKeepBaselineMeta() throws {
        try seed()
        goalStore.setGoal(DailyGoal(kind: .minutes, target: 90), now: t0)
        let first = try capturer().capture(baseline: nil, now: t1)
        var second = try capturer().capture(baseline: first, now: t2)
        #expect(second.exportedAt == t2)
        second.exportedAt = first.exportedAt
        #expect(second == first)
    }

    @Test func editedRowIsStampedNow() throws {
        let (topic, _, _) = try seed()
        let baseline = try capturer().capture(baseline: nil, now: t1)
        topic.name = "Bass"
        try context.save()

        let snap = try capturer().capture(baseline: baseline, now: t2)

        #expect(snap.topics.first?.name == "Bass")
        #expect(snap.topics.first?.meta.modifiedAt == t2)
        #expect(snap.tasks.allSatisfy { $0.meta.modifiedAt == .distantPast })
        #expect(snap.sessions.allSatisfy { $0.meta.modifiedAt == .distantPast })
        #expect(snap.settings.values.allSatisfy { $0.meta.modifiedAt == .distantPast })
    }

    @Test func deletedRowBecomesTombstone() throws {
        let (_, task, _) = try seed()
        let taskID = task.syncID
        let baseline = try capturer().capture(baseline: nil, now: t1)
        context.delete(task)
        try context.save()

        let snap = try capturer().capture(baseline: baseline, now: t2)

        let tomb = try #require(snap.tasks.first { $0.id == taskID })
        #expect(tomb.meta.deleted)
        #expect(tomb.meta.modifiedAt == t2)
        #expect(tomb.meta.modifiedBy == identity.deviceID)
        #expect(tomb.title == "Scales")
        // The session lost its task locally, so that is an edit too.
        #expect(snap.sessions.first?.taskID == nil)
        #expect(snap.sessions.first?.meta.modifiedAt == t2)
    }

    @Test func mergedTopicTombstoneCarriesTarget() throws {
        let x = Topic(name: "X"), y = Topic(name: "Y")
        context.insert(x); context.insert(y)
        try context.save()
        let xID = x.syncID, yID = y.syncID
        let baseline = try capturer().capture(baseline: nil, now: t1)
        context.delete(x)
        try context.save()

        let snap = try capturer(merged: [xID: yID]).capture(baseline: baseline, now: t2)

        let tomb = try #require(snap.topics.first { $0.id == xID })
        #expect(tomb.meta.deleted)
        #expect(tomb.meta.modifiedAt == t2)
        #expect(tomb.mergedInto == yID)
        let live = try #require(snap.topics.first { $0.id == yID })
        #expect(!live.meta.deleted)
        #expect(live.meta.modifiedAt == .distantPast)
    }

    @Test func changedSettingIsStamped() throws {
        let baseline = try capturer().capture(baseline: nil, now: t1)
        defaults.set(50, forKey: "timer.focusMinutes")

        let snap = try capturer().capture(baseline: baseline, now: t2)

        for (key, setting) in snap.settings {
            if key == "timer.focusMinutes" {
                #expect(setting.value == .int(50))
                #expect(setting.meta.modifiedAt == t2)
            } else {
                #expect(setting.meta.modifiedAt == .distantPast, "\(key)")
            }
        }
    }

    @Test func storeBackedSettingsComeFromTheirStores() throws {
        goalStore.dayStartHour = 4
        let snap = try capturer().capture(baseline: nil, now: t1)
        #expect(snap.settings["goals.dayStartHour"]?.value == .int(4))
        #expect(snap.settings["rewards.menuBarIcon"]?.value == .string(rewards.selectedIconID))
    }

    @Test func settingNewToAnExistingBaselineIsStampedNow() throws {
        var baseline = try capturer().capture(baseline: nil, now: t1)
        baseline.settings["away.idleMinutes"] = nil

        let snap = try capturer().capture(baseline: baseline, now: t2)

        #expect(snap.settings["away.idleMinutes"]?.meta.modifiedAt == t2)
        #expect(snap.settings["timer.focusMinutes"]?.meta.modifiedAt == .distantPast)
    }

    @Test func removedGoalEntryBecomesTombstone() throws {
        goalStore.setGoal(DailyGoal(kind: .minutes, target: 60), now: day(10))
        goalStore.setGoal(DailyGoal(kind: .minutes, target: 90), now: day(12))
        let baseline = try capturer().capture(baseline: nil, now: t1)
        #expect(baseline.goals.count == 2)
        let day12 = try #require(baseline.goals.max { $0.day < $1.day }).day

        goalStore.setGoal(DailyGoal(kind: .sessions, target: 3), now: day(10))
        let snap = try capturer().capture(baseline: baseline, now: t2)

        let tomb = try #require(snap.goals.first { $0.day == day12 })
        #expect(tomb.meta.deleted)
        #expect(tomb.meta.modifiedAt == t2)
        let live = try #require(snap.goals.first { !$0.meta.deleted })
        #expect(live.kind == "sessions")
        #expect(live.meta.modifiedAt == t2)
    }

    @Test func heldBackTaskIsCarried() throws {
        try seed()
        var baseline = try capturer().capture(baseline: nil, now: t1)
        let held = SyncTask(id: UUID(), meta: SyncMeta(modifiedAt: t0, modifiedBy: "mac-B", deleted: false),
                            title: "From B", estimatedSessions: 2, isDone: false, createdAt: t0,
                            completedAt: nil, topicID: UUID())
        baseline.tasks.append(held)

        let snap = try capturer().capture(baseline: baseline, now: t2)

        #expect(snap.tasks.filter { $0.id == held.id } == [held])
    }

    @Test func tombstonesInBaselineAreCarried() throws {
        var baseline = try capturer().capture(baseline: nil, now: t1)
        let dead = SyncTopic(id: UUID(), meta: SyncMeta(modifiedAt: t0, modifiedBy: "mac-B", deleted: true),
                             name: "Old", colorHex: "#fff", createdAt: t0, mergedInto: nil)
        baseline.topics.append(dead)

        let snap = try capturer().capture(baseline: baseline, now: t2)

        #expect(snap.topics == [dead])
    }

    @Test func subMillisecondDatesDoNotRestamp() throws {
        let topic = Topic(name: "Precise", createdAt: Date(timeIntervalSince1970: 1_800_000_000.123_456_789))
        context.insert(topic)
        try context.save()
        let first = try capturer().capture(baseline: nil, now: t1)
        let baseline = try DeviceSnapshot.decode(first.encoded())

        let snap = try capturer().capture(baseline: baseline, now: t2)

        #expect(snap.topics.first?.meta.modifiedAt == .distantPast)
        #expect(snap.topics.first?.createdAt == baseline.topics.first?.createdAt)
    }

    @Test func topiclessTaskSessionIsNotRestamped() throws {
        let task = TodoTask(title: "Loose", createdAt: t0)
        let session = FocusSession(kind: .focus, startedAt: t0, endedAt: t0.addingTimeInterval(60),
                                   activeSeconds: 60, completed: true, task: task)
        context.insert(task); context.insert(session)
        try context.save()

        let first = try capturer().capture(baseline: nil, now: t1)
        var second = try capturer().capture(baseline: first, now: t2)

        second.exportedAt = first.exportedAt
        #expect(second == first)
    }

    @Test func captureAfterApplyIsUnchanged() throws {
        let b = SyncMeta(modifiedAt: t0, modifiedBy: "mac-B", deleted: false)
        let dead = SyncMeta(modifiedAt: t0, modifiedBy: "mac-B", deleted: true)
        let xID = UUID(), yID = UUID(), zID = UUID()
        let movedID = UUID(), droppedID = UUID()
        var merged = DeviceSnapshot.empty(deviceID: "mac-A", deviceName: "Mac A")
        merged.exportedAt = t1
        merged.topics = [
            SyncTopic(id: xID, meta: dead, name: "X", colorHex: "#111", createdAt: t0, mergedInto: yID),
            SyncTopic(id: yID, meta: b, name: "Y", colorHex: "#222", createdAt: t0, mergedInto: nil),
            SyncTopic(id: zID, meta: dead, name: "Z", colorHex: "#333", createdAt: t0, mergedInto: nil),
        ]
        merged.tasks = [
            // In a merged-away topic: resolves into Y.
            SyncTask(id: movedID, meta: b, title: "Moved", estimatedSessions: 2, isDone: false,
                     createdAt: t0, completedAt: nil, deadline: t2, topicID: xID),
            // In a deleted topic: dropped by resolve.
            SyncTask(id: droppedID, meta: b, title: "Dropped", estimatedSessions: 1, isDone: true,
                     createdAt: t0, completedAt: t1, topicID: zID),
        ]
        merged.sessions = [
            SyncSession(id: UUID(), meta: b, kind: "focus", startedAt: t0, endedAt: t0.addingTimeInterval(1_500),
                        activeSeconds: 1_500, completed: true, taskID: movedID),
            // Its task is dropped, so it resolves without one.
            SyncSession(id: UUID(), meta: b, kind: "focus", startedAt: t1, endedAt: t1.addingTimeInterval(1_500),
                        activeSeconds: 1_400.5, completed: false, taskID: droppedID),
        ]
        for setting in SyncedSetting.all {
            merged.settings[setting.key] = SyncSetting(value: setting.defaultValue, meta: b)
        }
        merged.settings["timer.focusMinutes"] = SyncSetting(value: .int(50), meta: b)
        merged.settings["goals.dayStartHour"] = SyncSetting(value: .int(4), meta: b)
        merged.settings["rewards.menuBarIcon"] = SyncSetting(value: .string("timer"), meta: b)
        merged.settings["music.breakStationID"] = SyncSetting(value: .string("jazz"), meta: b)
        merged.goals = [SyncGoal(day: t0, meta: b, kind: "sessions", target: 6)]
        merged.unlockedIcons = ["note", "timer"]
        let baseline = try DeviceSnapshot.decode(merged.encoded())

        let clock = FakeClock()
        let engine = TimerEngine(clock: { clock.now }, settings: { TimerSettings() })
        try SnapshotApplier(context: context, defaults: defaults, goalStore: goalStore, rewards: rewards,
                            engine: engine, radioIsStopped: { true },
                            setRadioStation: { _ in Issue.record("radio station is unchanged") },
                            notifyTaskDeleted: { _ in Issue.record("no running task") })
            .apply(SyncMerge.resolve(baseline))

        let snap = try capturer().capture(baseline: baseline, now: t2)

        func sorted<R>(_ records: [R], _ id: (R) -> UUID) -> [R] { records.sorted { id($0).uuidString < id($1).uuidString } }
        #expect(sorted(snap.topics, \.id) == sorted(baseline.topics, \.id))
        #expect(sorted(snap.tasks, \.id) == sorted(baseline.tasks, \.id))
        #expect(sorted(snap.sessions, \.id) == sorted(baseline.sessions, \.id))
        #expect(snap.settings == baseline.settings)
        #expect(snap.goals == baseline.goals)
        #expect(snap.unlockedIcons.sorted() == baseline.unlockedIcons.sorted())
    }

    @Test func syncMillisIsIdempotent() throws {
        for _ in 0..<1_000 {
            let date = Date(timeIntervalSinceReferenceDate: .random(in: 0...1e9)).syncMillis
            #expect(date.syncMillis == date)
        }
    }
}
