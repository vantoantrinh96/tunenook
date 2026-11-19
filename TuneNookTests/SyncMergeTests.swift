import Testing
import Foundation
@testable import TuneNook

@Suite struct SyncMergeTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + offset) }
    func meta(_ offset: TimeInterval, by: String = "A", deleted: Bool = false) -> SyncMeta {
        SyncMeta(modifiedAt: at(offset), modifiedBy: by, deleted: deleted)
    }
    func topic(_ id: UUID, _ name: String, _ m: SyncMeta) -> SyncTopic {
        SyncTopic(id: id, meta: m, name: name, colorHex: "#fff", createdAt: at(-1000), deadline: nil, mergedInto: nil)
    }
    func task(_ id: UUID, _ m: SyncMeta) -> SyncTask {
        SyncTask(id: id, meta: m, title: "t", estimatedSessions: 1, isDone: false, createdAt: at(-1000), completedAt: nil, topicID: nil)
    }
    func session(_ id: UUID, _ m: SyncMeta) -> SyncSession {
        SyncSession(id: id, meta: m, kind: "focus", startedAt: at(-500), endedAt: at(-400), activeSeconds: 100, completed: true, taskID: nil)
    }
    func snap(_ dev: String, topics: [SyncTopic] = [], tasks: [SyncTask] = [], sessions: [SyncSession] = [],
              settings: [String: SyncSetting] = [:], goals: [SyncGoal] = [], icons: [String] = []) -> DeviceSnapshot {
        var s = DeviceSnapshot.empty(deviceID: dev, deviceName: dev)
        s.topics = topics; s.tasks = tasks; s.sessions = sessions
        s.settings = settings; s.goals = goals; s.unlockedIcons = icons
        return s
    }
    var identity: DeviceSnapshot {
        var s = DeviceSnapshot.empty(deviceID: "ME", deviceName: "My Mac"); s.appVersion = "9.9"; return s
    }

    @Test func newerEditWins() {
        let id = UUID()
        let a = snap("A", topics: [topic(id, "old", meta(0))])
        let b = snap("B", topics: [topic(id, "new", meta(10, by: "B"))])
        #expect(SyncMerge.merge([a, b], into: identity, now: now).topics.map(\.name) == ["new"])
        #expect(SyncMerge.merge([b, a], into: identity, now: now).topics.map(\.name) == ["new"])
    }

    @Test func newerDeleteBeatsOlderEdit() {
        let id = UUID()
        let a = snap("A", topics: [topic(id, "x", meta(0))])
        let b = snap("B", topics: [topic(id, "x", meta(10, by: "B", deleted: true))])
        let r = SyncMerge.merge([a, b], into: identity, now: now)
        #expect(r.topics.count == 1 && r.topics[0].meta.deleted)
    }

    @Test func newerEditBeatsOlderDelete() {
        let id = UUID()
        let a = snap("A", topics: [topic(id, "x", meta(0, deleted: true))])
        let b = snap("B", topics: [topic(id, "back", meta(10, by: "B"))])
        let r = SyncMerge.merge([a, b], into: identity, now: now)
        #expect(r.topics.count == 1 && !r.topics[0].meta.deleted && r.topics[0].name == "back")
    }

    @Test func tieBreaksOnDeviceID() {
        let id = UUID()
        let a = snap("A", topics: [topic(id, "fromA", meta(5, by: "A"))])
        let b = snap("B", topics: [topic(id, "fromB", meta(5, by: "B"))])
        #expect(SyncMerge.merge([a, b], into: identity, now: now).topics.map(\.name) == ["fromB"])
        #expect(SyncMerge.merge([b, a], into: identity, now: now).topics.map(\.name) == ["fromB"])
    }

    @Test func recordsFromOneSideAreKept() {
        let a = snap("A", topics: [topic(UUID(), "a", meta(0))], tasks: [task(UUID(), meta(0))], sessions: [session(UUID(), meta(0))])
        let b = snap("B", topics: [topic(UUID(), "b", meta(0, by: "B"))], tasks: [task(UUID(), meta(0, by: "B"))], sessions: [session(UUID(), meta(0, by: "B"))])
        let r = SyncMerge.merge([a, b], into: identity, now: now)
        #expect(r.topics.count == 2 && r.tasks.count == 2 && r.sessions.count == 2)
    }

    @Test func settingsMergePerKey() {
        let a = snap("A", settings: [
            "timer.focusMinutes": SyncSetting(value: .int(30), meta: meta(10)),
            "away.idleMinutes": SyncSetting(value: .int(1), meta: meta(0))])
        let b = snap("B", settings: [
            "timer.focusMinutes": SyncSetting(value: .int(20), meta: meta(0, by: "B")),
            "away.idleMinutes": SyncSetting(value: .int(7), meta: meta(10, by: "B"))])
        let r = SyncMerge.merge([a, b], into: identity, now: now)
        #expect(r.settings["timer.focusMinutes"]?.value == .int(30))
        #expect(r.settings["away.idleMinutes"]?.value == .int(7))
    }

    @Test func goalsMergePerDay() {
        let d10 = at(-86_400 * 10), d12 = at(-86_400 * 12)
        let a = snap("A", goals: [SyncGoal(day: d10, meta: meta(0), kind: "sessions", target: 3),
                                   SyncGoal(day: d12, meta: meta(0), kind: "sessions", target: 4)])
        let b = snap("B", goals: [SyncGoal(day: d12, meta: meta(10, by: "B"), kind: "sessions", target: 9)])
        let r = SyncMerge.merge([a, b], into: identity, now: now)
        #expect(r.goals.count == 2)
        #expect(r.goals.first { $0.day == d12 }?.target == 9)
        #expect(r.goals.first { $0.day == d10 }?.target == 3)
    }

    @Test func iconsAreUnioned() {
        let a = snap("A", icons: ["note", "timer"]); let b = snap("B", icons: ["note", "flame"])
        #expect(SyncMerge.merge([a, b], into: identity, now: now).unlockedIcons == ["flame", "note", "timer"])
    }

    @Test func oldTombstonesArePruned() {
        let day: TimeInterval = 86_400
        let old = UUID(), recent = UUID(), live = UUID()
        let a = snap("A", topics: [
            topic(old, "old", meta(-91 * day, deleted: true)),
            topic(recent, "recent", meta(-89 * day, deleted: true)),
            topic(live, "live", meta(-200 * day))])
        let r = SyncMerge.merge([a], into: identity, now: now)
        #expect(Set(r.topics.map(\.id)) == [recent, live])
    }

    @Test func resultCarriesIdentity() {
        let r = SyncMerge.merge([], into: identity, now: now)
        #expect(r.deviceID == "ME" && r.deviceName == "My Mac" && r.appVersion == "9.9")
        #expect(r.exportedAt == now && r.formatVersion == 1)
    }
}
