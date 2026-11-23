import Foundation
import SwiftData
import Testing
@testable import TuneNook

@MainActor
struct HistoryToolsTests {
    let container: ModelContainer
    let context: ModelContext
    let defaults: UserDefaults
    let goalStore: GoalStore
    let tools: TuneNookTools
    let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return cal
    }()
    let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    /// `calendar` is the tool layer's calendar (date-only input, output formatting). Progress days come from
    /// `GoalStore.calendar`, which is always `Calendar.current`, so progress tests build dates with `Calendar.current`.
    init(now: Date? = nil, calendar: Calendar? = nil) throws {
        container = try ModelContainer(
            for: Topic.self, TodoTask.self, FocusSession.self,
            configurations: .init(isStoredInMemoryOnly: true))
        context = container.mainContext
        defaults = TestDefaults.make()
        goalStore = GoalStore(defaults: defaults)
        let fixed = now ?? fixedNow
        tools = TuneNookTools(
            context: context, defaults: defaults, goalStore: goalStore, stations: [],
            isBusy: { _ in false }, deselect: { _ in },
            now: { fixed }, calendar: calendar ?? self.calendar)
    }

    @discardableResult
    func call(_ name: String, _ json: String = "{}") throws -> [String: Any] {
        let data = try tools.call(name, arguments: Data(json.utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func expectToolError(_ fragment: String? = nil, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected ToolError")
        } catch let error as ToolError {
            if let fragment { #expect(error.message.contains(fragment)) }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @discardableResult
    func addSession(kind: SessionKind = .focus, start: Date, minutes: Double = 25, completed: Bool = true,
                    task: TodoTask? = nil) throws -> FocusSession {
        let session = FocusSession(kind: kind, startedAt: start, endedAt: start.addingTimeInterval(minutes * 60),
                                   activeSeconds: minutes * 60, completed: completed, task: task)
        context.insert(session)
        try context.save()
        return session
    }

    func daysAgo(_ n: Double, from now: Date? = nil) -> Date {
        (now ?? fixedNow).addingTimeInterval(-n * 86_400)
    }

    func sessions(_ result: [String: Any]) throws -> [[String: Any]] {
        try #require(result["sessions"] as? [[String: Any]])
    }

    @Test func defaultRangeIsLastSevenDays() throws {
        try addSession(start: daysAgo(2))
        try addSession(start: daysAgo(10))
        let result = try sessions(call("list_sessions"))
        #expect(result.count == 1)
        #expect(result[0]["kind"] as? String == "focus")
        #expect(result[0]["active_minutes"] as? Double == 25)
        #expect(result[0]["completed"] as? Bool == true)
    }

    @Test func newestFirstWithLimitAndHasMore() throws {
        for i in 0..<5 { try addSession(start: daysAgo(Double(i) + 0.5)) }
        let result = try call("list_sessions", #"{"limit":2}"#)
        let rows = try sessions(result)
        #expect(rows.count == 2)
        #expect(result["has_more"] as? Bool == true)
        let first = try #require(rows[0]["started_at"] as? String)
        let second = try #require(rows[1]["started_at"] as? String)
        #expect(first > second)
        #expect(try call("list_sessions")["has_more"] as? Bool == false)
        expectToolError("limit") { try call("list_sessions", #"{"limit":0}"#) }
        expectToolError("limit") { try call("list_sessions", #"{"limit":501}"#) }
    }

    @Test func filtersByTopicTaskKindAndCompleted() throws {
        let topicA = Topic(name: "A", colorHex: "#FF0000")
        let topicB = Topic(name: "B", colorHex: "#00FF00")
        context.insert(topicA); context.insert(topicB)
        let taskA = TodoTask(title: "Task A", estimatedSessions: 1)
        let taskB = TodoTask(title: "Task B", estimatedSessions: 1)
        context.insert(taskA); context.insert(taskB)
        taskA.topic = topicA
        taskB.topic = topicB
        try context.save()
        try addSession(start: daysAgo(1), task: taskA)
        try addSession(start: daysAgo(2), completed: false, task: taskA)
        try addSession(kind: .shortBreak, start: daysAgo(3), task: taskB)
        try addSession(start: daysAgo(4), task: taskB)

        let topicId = EntityID.encode(topicA.persistentModelID)
        let taskId = EntityID.encode(taskB.persistentModelID)
        #expect(try sessions(call("list_sessions", #"{"topic_id":"\#(topicId)"}"#)).count == 2)
        #expect(try sessions(call("list_sessions", #"{"task_id":"\#(taskId)"}"#)).count == 2)
        #expect(try sessions(call("list_sessions", #"{"kind":"shortBreak"}"#)).count == 1)
        #expect(try sessions(call("list_sessions", #"{"completed_only":true}"#)).count == 3)
        let both = try sessions(call("list_sessions", #"{"topic_id":"\#(topicId)","completed_only":true}"#))
        #expect(both.count == 1)
        #expect(both[0]["task_title"] as? String == "Task A")
        #expect(both[0]["topic_name"] as? String == "A")
        #expect(both[0]["topic_id"] as? String == topicId)
        expectToolError("kind") { try call("list_sessions", #"{"kind":"nap"}"#) }
        expectToolError("topic") { try call("list_sessions", #"{"topic_id":"bogus"}"#) }
    }

    @Test func sessionOfDeletedTaskHasNullTask() throws {
        let task = TodoTask(title: "Gone", estimatedSessions: 1)
        context.insert(task)
        try addSession(start: daysAgo(1), task: task)
        context.delete(task)
        try context.save()
        let row = try #require(try sessions(call("list_sessions")).first)
        #expect(row["task_id"] is NSNull)
        #expect(row["task_title"] is NSNull)
        #expect(row["topic_id"] is NSNull)
        #expect(row["topic_name"] is NSNull)
    }

    @Test func dateOnlyRange() throws {
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10))!
        try addSession(start: day.addingTimeInterval(23.5 * 3600))
        try addSession(start: day.addingTimeInterval(24.5 * 3600))
        let result = try sessions(call("list_sessions", #"{"from":"2026-11-10","to":"2026-11-10"}"#))
        #expect(result.count == 1)
        expectToolError("from") { try call("list_sessions", #"{"from":"yesterday"}"#) }
    }

    // MARK: Progress

    /// Noon today in the machine's calendar, the one `GoalStore.calendar` uses.
    static func localNoon() -> Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!
    }

    @Test func progressMatchesFocusProgress() throws {
        let now = Self.localNoon()
        let suite = try HistoryToolsTests(now: now, calendar: .current)
        suite.goalStore.setGoal(DailyGoal(kind: .minutes, target: 50), now: now)
        try suite.addSession(start: now.addingTimeInterval(-3 * 3600))
        try suite.addSession(start: now.addingTimeInterval(-2 * 3600))
        let result = try suite.call("get_progress")
        let today = try #require(result["today"] as? [String: Any])
        #expect(today["minutes"] as? Int == 50)
        #expect(today["sessions"] as? Int == 2)
        #expect(today["goal_met"] as? Bool == true)
        let goal = try #require(today["goal"] as? [String: Any])
        #expect(goal["kind"] as? String == "minutes")
        #expect(goal["target"] as? Int == 50)
        let streak = try #require(result["streak"] as? [String: Any])
        #expect(streak["current"] as? Int == 1)
        let days = try #require(result["days"] as? [[String: Any]])
        #expect(days.count == 7)
        #expect(days.last?["date"] as? String == today["date"] as? String)
        #expect(days.last?["minutes"] as? Int == 50)
        #expect(days.first?["minutes"] as? Int == 0)
        let longer = try #require(try suite.call("get_progress", #"{"days":30}"#)["days"] as? [[String: Any]])
        #expect(longer.count == 30)
        suite.expectToolError("days") { try suite.call("get_progress", #"{"days":0}"#) }
        suite.expectToolError("days") { try suite.call("get_progress", #"{"days":367}"#) }
    }

    @Test func progressRespectsDayStartHour() throws {
        let now = Self.localNoon()
        let suite = try HistoryToolsTests(now: now, calendar: .current)
        suite.goalStore.dayStartHour = 4
        let twoAM = Calendar.current.date(bySettingHour: 1, minute: 35, second: 0, of: now)!
        try suite.addSession(start: twoAM)  // ends 02:00
        let result = try suite.call("get_progress")
        let today = try #require(result["today"] as? [String: Any])
        #expect(today["minutes"] as? Int == 0)
        let days = try #require(result["days"] as? [[String: Any]])
        #expect(days[5]["minutes"] as? Int == 25)
    }

    @Test func historyToolsDoNotWrite() throws {
        try addSession(start: daysAgo(1))
        try call("list_sessions")
        try call("get_progress")
        #expect(context.hasChanges == false)
    }
}
