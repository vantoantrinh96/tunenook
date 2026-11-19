import Foundation
import SwiftData
import Testing
@testable import TuneNook

@MainActor
struct SettingsToolsTests {
    final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    let container: ModelContainer
    let defaults: UserDefaults
    let goalStore: GoalStore
    let tools: TuneNookTools
    let clock = Clock()
    let stations = [
        RadioStation(id: "a", name: "Alpha", subtitle: "", symbol: "music.note", url: URL(string: "https://example.com/a")!, source: "test"),
        RadioStation(id: "b", name: "Beta", subtitle: "", symbol: "music.note", url: URL(string: "https://example.com/b")!, source: "test"),
    ]

    init() throws {
        container = try ModelContainer(
            for: Topic.self, TodoTask.self, FocusSession.self,
            configurations: .init(isStoredInMemoryOnly: true))
        defaults = UserDefaults(suiteName: UUID().uuidString)!
        goalStore = GoalStore(defaults: defaults)
        let clock = self.clock
        tools = TuneNookTools(
            context: container.mainContext, defaults: defaults, goalStore: goalStore, stations: stations,
            isBusy: { _ in false }, deselect: { _ in },
            now: { clock.now })
    }

    @discardableResult
    func call(_ name: String, _ json: String = "{}") throws -> [String: Any] {
        let data = try tools.call(name, arguments: Data(json.utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func expectToolError(_ message: String? = nil, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected ToolError")
        } catch let error as ToolError {
            if let message { #expect(error.message == message) }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func defaultsAreReported() throws {
        let s = try call("get_settings")
        #expect(s["focus_minutes"] as? Int == 25)
        #expect(s["short_break_minutes"] as? Int == 5)
        #expect(s["long_break_minutes"] as? Int == 15)
        #expect(s["long_break_interval"] as? Int == 4)
        #expect(s["auto_start_breaks"] as? Bool == true)
        #expect(s["auto_start_focus"] as? Bool == false)
        let goal = try #require(s["daily_goal"] as? [String: Any])
        #expect(goal["kind"] as? String == "minutes")
        #expect(goal["target"] as? Int == 120)
        #expect(s["day_start_hour"] as? Int == 0)
        #expect(s["break_music"] as? String == "lowerVolume")
        #expect(s.keys.contains("break_station_id"))
        #expect(s["break_station_id"] is NSNull)
        #expect(s["celebrations"] as? String == "milestones")
        #expect(s["pause_on_lock"] as? Bool == true)
        #expect(s["idle_pause_minutes"] as? Int == 0)
        let allowed = try #require(s["allowed"] as? [String: Any])
        #expect(allowed["daily_goal_kind"] as? [String] == ["minutes", "sessions"])
        #expect(allowed["break_music"] as? [String] == ["keepPlaying", "lowerVolume", "stop", "switchStation"])
        #expect(allowed["celebrations"] as? [String] == ["off", "milestones", "everySession"])
        #expect(allowed["idle_pause_minutes"] as? [Int] == [0, 2, 5, 10, 15])
        let listed = try #require(allowed["stations"] as? [[String: String]])
        #expect(listed == [["id": "a", "name": "Alpha"], ["id": "b", "name": "Beta"]])
    }

    @Test func updateWritesTheSameKeysTheUIReads() throws {
        let result = try call("update_settings", #"{"focus_minutes":50,"celebrations":"off","break_music":"stop","break_station_id":"b","pause_on_lock":false,"idle_pause_minutes":5,"auto_start_focus":true}"#)
        #expect(result["focus_minutes"] as? Int == 50)
        #expect(TimerSettings.load(from: defaults).focusMinutes == 50)
        #expect(TimerSettings.load(from: defaults).autoStartFocus)
        #expect(defaults.string(forKey: CelebrationLevel.key) == "off")
        let rules = MusicRules.load(from: defaults)
        #expect(rules.breakAction == .stop)
        #expect(rules.breakStationID == "b")
        let away = AwayPolicy.load(from: defaults)
        #expect(!away.pauseOnLock)
        #expect(away.idleMinutes == 5)
    }

    @Test func rangeLimits() {
        for json in [
            #"{"focus_minutes":4}"#, #"{"focus_minutes":91}"#, #"{"long_break_interval":1}"#,
            #"{"idle_pause_minutes":3}"#, #"{"break_music":"loud"}"#, #"{"break_station_id":"nope"}"#,
            #"{"focus_minutes":"x"}"#, #"{"celebrations":"loud"}"#,
        ] {
            expectToolError { try call("update_settings", json) }
        }
    }

    @Test func oneBadFieldChangesNothing() {
        expectToolError { try call("update_settings", #"{"focus_minutes":50,"short_break_minutes":99}"#) }
        #expect(TimerSettings.load(from: defaults).focusMinutes == 25)
    }

    @Test func emptyArgumentsThrow() {
        expectToolError("Nothing to change.") { try call("update_settings") }
    }

    @Test func goalGoesThroughGoalStore() throws {
        try call("update_settings", #"{"daily_goal":{"kind":"sessions","target":6}}"#)
        #expect(goalStore.current == DailyGoal(kind: .sessions, target: 6))
        expectToolError { try call("update_settings", #"{"daily_goal":{"kind":"sessions","target":17}}"#) }
        expectToolError { try call("update_settings", #"{"daily_goal":{"kind":"minutes","target":100}}"#) }
        expectToolError { try call("update_settings", #"{"daily_goal":{"kind":"minutes","target":615}}"#) }
        expectToolError { try call("update_settings", #"{"daily_goal":{"kind":"hours","target":2}}"#) }
        #expect(goalStore.current == DailyGoal(kind: .sessions, target: 6))
    }

    @Test func goalChangeDoesNotRewritePastDays() throws {
        let day: TimeInterval = 86_400
        let start = clock.now
        try call("update_settings", #"{"daily_goal":{"kind":"minutes","target":60}}"#)
        clock.now = start.addingTimeInterval(5 * day)
        try call("update_settings", #"{"daily_goal":{"kind":"sessions","target":8}}"#)
        let past = goalStore.calendar.day(for: start.addingTimeInterval(2 * day))
        #expect(goalStore.history.goal(on: past) == DailyGoal(kind: .minutes, target: 60))
        #expect(goalStore.current == DailyGoal(kind: .sessions, target: 8))
    }

    @Test func dayStartHourIsReadOnly() {
        expectToolError("day_start_hour can only be changed in TuneNook's Settings.") {
            try call("update_settings", #"{"day_start_hour":4,"focus_minutes":50}"#)
        }
        #expect(goalStore.dayStartHour == 0)
        #expect(TimerSettings.load(from: defaults).focusMinutes == 25)
    }

    @Test func clearBreakStationWithNull() throws {
        try call("update_settings", #"{"break_station_id":"a"}"#)
        #expect(MusicRules.load(from: defaults).breakStationID == "a")
        let result = try call("update_settings", #"{"break_station_id":null}"#)
        #expect(result["break_station_id"] is NSNull)
        #expect(MusicRules.load(from: defaults).breakStationID == nil)
    }
}
