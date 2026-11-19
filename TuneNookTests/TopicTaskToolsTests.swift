import Foundation
import SwiftData
import Testing
@testable import TuneNook

@MainActor
struct TopicTaskToolsTests {
    final class Box {
        var busy: Set<PersistentIdentifier> = []
        var deselected: [PersistentIdentifier] = []
        var deselectedWasPresent: [Bool] = []
    }

    let container: ModelContainer
    let context: ModelContext
    let tools: TuneNookTools
    let box = Box()
    let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return cal
    }()
    let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        container = try ModelContainer(
            for: Topic.self, TodoTask.self, FocusSession.self,
            configurations: .init(isStoredInMemoryOnly: true))
        context = container.mainContext
        tools = Self.makeTools(context: context, box: box, calendar: calendar, now: fixedNow)
    }

    static func makeTools(context: ModelContext, box: Box, calendar: Calendar, now: Date) -> TuneNookTools {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return TuneNookTools(
            context: context, defaults: defaults, goalStore: GoalStore(defaults: defaults), stations: [],
            isBusy: { box.busy.contains($0.persistentModelID) },
            deselect: { task in
                box.deselected.append(task.persistentModelID)
                box.deselectedWasPresent.append(!task.isDeleted)
            },
            now: { now }, calendar: calendar)
    }

    @discardableResult
    func call(_ name: String, _ json: String = "{}") throws -> [String: Any] {
        let data = try tools.call(name, arguments: Data(json.utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func createTopic(_ name: String = "T") throws -> String {
        try #require(try call("create_topic", #"{"name":"\#(name)"}"#)["id"] as? String)
    }

    func createTask(_ topic: String, _ json: String = #"{"title":"A"}"#) throws -> String {
        let merged = json.dropLast() + #","topic_id":"\#(topic)"}"#
        return try #require(try call("create_task", String(merged))["id"] as? String)
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

    @Test func createThenListTopic() throws {
        let created = try call("create_topic", ##"{"name":"  Thesis ","color":"#43AA8B","deadline":"2026-12-01"}"##)
        #expect(created["name"] as? String == "Thesis")
        #expect(created["color"] as? String == "#43AA8B")
        let expected = calendar.date(from: DateComponents(year: 2026, month: 12, day: 1))!
        let topic = try #require(try context.fetch(FetchDescriptor<Topic>()).first)
        #expect(topic.deadline == expected)
        let listed = try #require(try call("list_topics")["topics"] as? [[String: Any]])
        #expect(listed.count == 1)
        #expect(listed[0]["open_tasks"] as? Int == 0)
        #expect(listed[0]["id"] as? String == created["id"] as? String)
        #expect(listed[0]["deadline"] is String)
    }

    @Test func topicValidation() throws {
        expectToolError { try call("create_topic", #"{"name":"   "}"#) }
        expectToolError { try call("create_topic", ##"{"name":"x","color":"#000000"}"##) }
        expectToolError { try call("create_topic", #"{"name":"x","deadline":"soon"}"#) }
        expectToolError { try call("create_topic", #"{"name":5}"#) }
        expectToolError { try call("create_task", #"{"title":"x","topic_id":"y","estimated_sessions":"3"}"#) }
        do {
            try call("create_topic", #"{"name":5}"#)
            Issue.record("expected ToolError")
        } catch let error as ToolError {
            #expect(error.message.contains("name"))
        }
        do {
            try call("create_task", #"{"title":"x","topic_id":"y","estimated_sessions":"3"}"#)
            Issue.record("expected ToolError")
        } catch let error as ToolError {
            #expect(error.message.contains("estimated_sessions"))
        }
        #expect(try context.fetch(FetchDescriptor<Topic>()).isEmpty)
    }

    @Test func updateTopicDeadlineNullClearsAbsentKeeps() throws {
        let id = try #require(try call("create_topic", #"{"name":"A","deadline":"2026-12-01"}"#)["id"] as? String)
        let renamed = try call("update_topic", #"{"id":"\#(id)","name":"B"}"#)
        #expect(renamed["name"] as? String == "B")
        #expect(renamed["deadline"] is String)
        let cleared = try call("update_topic", #"{"id":"\#(id)","deadline":null}"#)
        #expect(cleared["deadline"] is NSNull)
        let topic = try #require(try context.fetch(FetchDescriptor<Topic>()).first)
        #expect(topic.deadline == nil)
    }

    @Test func createTaskNeedsTopic() throws {
        expectToolError { try call("create_task", #"{"title":"x"}"#) }
        expectToolError("No topic with that id.") { try call("create_task", #"{"title":"x","topic_id":"bogus"}"#) }
    }

    @Test func taskEstimateRange() throws {
        let topic = try createTopic()
        expectToolError { try call("create_task", #"{"title":"x","topic_id":"\#(topic)","estimated_sessions":0}"#) }
        expectToolError { try call("create_task", #"{"title":"x","topic_id":"\#(topic)","estimated_sessions":13}"#) }
        expectToolError { try call("create_task", #"{"title":"  ","topic_id":"\#(topic)"}"#) }
        let twelve = try call("create_task", #"{"title":"x","topic_id":"\#(topic)","estimated_sessions":12}"#)
        #expect(twelve["estimated_sessions"] as? Int == 12)
        let dflt = try call("create_task", #"{"title":"y","topic_id":"\#(topic)"}"#)
        #expect(dflt["estimated_sessions"] as? Int == 1)
        #expect(dflt["topic_name"] as? String == "T")
        #expect(dflt["actual_sessions"] as? Int == 0)
    }

    @Test func updateTaskDoneSetsCompletedAt() throws {
        let topic = try createTopic()
        let id = try createTask(topic)
        let done = try call("update_task", #"{"id":"\#(id)","done":true}"#)
        #expect(done["done"] as? Bool == true)
        #expect(done["completed_at"] is String)
        let task = try #require(try context.fetch(FetchDescriptor<TodoTask>()).first)
        #expect(task.completedAt == fixedNow)
        let undone = try call("update_task", #"{"id":"\#(id)","done":false}"#)
        #expect(undone["completed_at"] is NSNull)
        expectToolError { try call("update_task", #"{"id":"\#(id)","topic_id":null}"#) }
        let other = try createTopic("Other")
        let moved = try call("update_task", #"{"id":"\#(id)","topic_id":"\#(other)","title":" Z "}"#)
        #expect(moved["topic_name"] as? String == "Other")
        #expect(moved["title"] as? String == "Z")
    }

    @Test func listTasksStatusFilter() throws {
        let topic = try createTopic()
        _ = try createTask(topic, #"{"title":"open"}"#)
        let done = try createTask(topic, #"{"title":"done"}"#)
        try call("update_task", #"{"id":"\#(done)","done":true}"#)
        func titles(_ json: String) throws -> [String] {
            let tasks = try #require(try call("list_tasks", json)["tasks"] as? [[String: Any]])
            return tasks.compactMap { $0["title"] as? String }
        }
        #expect(try titles("{}") == ["open"])
        #expect(try titles(#"{"status":"open"}"#) == ["open"])
        #expect(try titles(#"{"status":"done"}"#) == ["done"])
        #expect(try titles(#"{"status":"all"}"#).sorted() == ["done", "open"])
        expectToolError { try call("list_tasks", #"{"status":"weird"}"#) }
    }

    @Test func listTasksFiltersByTopic() throws {
        let a = try createTopic("A")
        let b = try createTopic("B")
        _ = try createTask(a, #"{"title":"a-open"}"#)
        let aDone = try createTask(a, #"{"title":"a-done"}"#)
        _ = try createTask(b, #"{"title":"b-open"}"#)
        try call("update_task", #"{"id":"\#(aDone)","done":true}"#)
        func titles(_ json: String) throws -> [String] {
            try #require(try call("list_tasks", json)["tasks"] as? [[String: Any]]).compactMap { $0["title"] as? String }
        }
        #expect(try titles(#"{"topic_id":"\#(a)"}"#) == ["a-open"])
        #expect(try titles(#"{"topic_id":"\#(a)","status":"all"}"#) == ["a-open", "a-done"])
        #expect(try titles(#"{"topic_id":"\#(b)","status":"done"}"#) == [])
        expectToolError("No topic with that id.") { try call("list_tasks", #"{"topic_id":"nope"}"#) }
    }

    @Test func listTasksOrderMatchesTopicOrdering() throws {
        let topic = try createTopic()
        for title in ["o1", "o2", "d1", "d2"] { _ = try createTask(topic, #"{"title":"\#(title)"}"#) }
        let tasks = try context.fetch(FetchDescriptor<TodoTask>())
        func task(_ title: String) -> TodoTask { tasks.first { $0.title == title }! }
        let base = fixedNow
        task("o2").createdAt = base.addingTimeInterval(10)
        task("o1").createdAt = base.addingTimeInterval(20)  // o2 is older, so it sorts first
        task("d1").createdAt = base
        task("d2").createdAt = base
        task("d1").setDone(true, at: base.addingTimeInterval(100))
        task("d2").setDone(true, at: base.addingTimeInterval(200))
        try context.save()
        func titles(_ status: String) throws -> [String] {
            try #require(try call("list_tasks", #"{"status":"\#(status)"}"#)["tasks"] as? [[String: Any]]).compactMap { $0["title"] as? String }
        }
        #expect(try titles("open") == ["o2", "o1"])
        #expect(try titles("done") == ["d2", "d1"])
        let model = try #require(try context.fetch(FetchDescriptor<Topic>()).first)
        #expect(try titles("open") == model.openTasks.map(\.title))
        #expect(try titles("done") == model.doneTasks.map(\.title))
    }

    @Test func unknownArgumentKeysAreIgnored() throws {
        let created = try call("create_topic", #"{"name":"X","bogus":[1,2],"another":{"a":1}}"#)
        #expect(created["name"] as? String == "X")
    }

    @Test func outputDatesCarryTimeZone() throws {
        let created = try call("create_topic", ##"{"name":"X","deadline":"2026-12-01"}"##)
        let deadline = try #require(created["deadline"] as? String)
        #expect(deadline == "2026-12-01T00:00:00+07:00")
        let topic = try #require(created["id"] as? String)
        let task = try createTask(topic)
        let done = try call("update_task", #"{"id":"\#(task)","done":true}"#)
        let completed = try #require(done["completed_at"] as? String)
        #expect(completed.hasSuffix("+07:00") || completed.hasSuffix("Z"))
        #expect((done["created_at"] as? String)?.hasSuffix("+07:00") == true)
    }

    @Test func deleteTaskKeepsSessions() throws {
        let topic = try createTopic()
        let id = try createTask(topic)
        let task = try #require(try context.fetch(FetchDescriptor<TodoTask>()).first)
        let session = FocusSession(kind: .focus, startedAt: .now, endedAt: .now, activeSeconds: 60, completed: true, task: task)
        context.insert(session)
        try context.save()
        let result = try call("delete_task", #"{"id":"\#(id)"}"#)
        #expect(result["deleted"] as? Bool == true)
        let sessions = try context.fetch(FetchDescriptor<FocusSession>())
        #expect(sessions.count == 1)
        #expect(sessions[0].task == nil)
        #expect(try context.fetch(FetchDescriptor<TodoTask>()).isEmpty)
    }

    @Test func deleteTopicCascadesTasks() throws {
        let topic = try createTopic()
        _ = try createTask(topic)
        _ = try createTask(topic, #"{"title":"B"}"#)
        try call("delete_topic", #"{"id":"\#(topic)"}"#)
        #expect(try context.fetch(FetchDescriptor<Topic>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<TodoTask>()).isEmpty)
        #expect(box.deselected.count == 2)
    }

    @Test func busyTaskCannotBeDeleted() throws {
        let topic = try createTopic()
        let id = try createTask(topic)
        let task = try #require(try context.fetch(FetchDescriptor<TodoTask>()).first)
        box.busy.insert(task.persistentModelID)
        let message = "A focus session is running on this task. Stop it in TuneNook first."
        expectToolError(message) { try call("delete_task", #"{"id":"\#(id)"}"#) }
        expectToolError(message) { try call("delete_topic", #"{"id":"\#(topic)"}"#) }
        #expect(try context.fetch(FetchDescriptor<TodoTask>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<Topic>()).count == 1)
        #expect(box.deselected.isEmpty)
        let updated = try call("update_task", #"{"id":"\#(id)","title":"New"}"#)
        #expect(updated["title"] as? String == "New")
    }

    @Test func selectedIdleTaskIsDeselectedThenDeleted() throws {
        let topic = try createTopic()
        let id = try createTask(topic)
        let task = try #require(try context.fetch(FetchDescriptor<TodoTask>()).first)
        let pid = task.persistentModelID
        try call("delete_task", #"{"id":"\#(id)"}"#)
        #expect(box.deselected == [pid])
        #expect(box.deselectedWasPresent == [true])
    }

    @Test func staleAndWrongKindIds() throws {
        let topic = try createTopic()
        let id = try createTask(topic)
        try call("delete_task", #"{"id":"\#(id)"}"#)
        expectToolError("No task with that id.") { try call("delete_task", #"{"id":"\#(id)"}"#) }
        expectToolError("No task with that id.") { try call("update_task", #"{"id":"\#(id)","title":"x"}"#) }
        expectToolError("No task with that id.") { try call("delete_task", #"{"id":"\#(topic)"}"#) }
        expectToolError("No task with that id.") { try call("delete_task", #"{"id":"not-an-id"}"#) }
        expectToolError("No topic with that id.") { try call("delete_topic", #"{"id":"not-an-id"}"#) }
        #expect(try context.fetch(FetchDescriptor<Topic>()).count == 1)
    }

    /// Row numbers are dense in both tables, so topic p1 and task p1 both exist here:
    /// an id of the wrong kind must never resolve to the other table's row with the same number.
    @Test func wrongKindIdsNeverHitCollidingRows() throws {
        let topicA = try createTopic("A")
        let topicB = try createTopic("B")
        let task1 = try createTask(topicA, #"{"title":"One"}"#)
        let task2 = try createTask(topicB, #"{"title":"Two"}"#)

        expectToolError("No task with that id.") { try call("delete_task", #"{"id":"\#(topicA)"}"#) }
        expectToolError("No task with that id.") { try call("update_task", #"{"id":"\#(topicA)","title":"x"}"#) }
        expectToolError("No topic with that id.") { try call("delete_topic", #"{"id":"\#(task2)"}"#) }
        expectToolError("No topic with that id.") { try call("update_topic", #"{"id":"\#(task1)","name":"x"}"#) }
        expectToolError("No topic with that id.") {
            try call("create_task", #"{"title":"New","topic_id":"\#(task2)"}"#)
        }
        expectToolError("No topic with that id.") { try call("list_tasks", #"{"topic_id":"\#(task1)"}"#) }
        expectToolError("No topic with that id.") { try call("list_sessions", #"{"topic_id":"\#(task1)"}"#) }
        expectToolError("No task with that id.") { try call("list_sessions", #"{"task_id":"\#(topicB)"}"#) }

        let topics = try context.fetch(FetchDescriptor<Topic>()).map(\.name).sorted()
        let tasks = try context.fetch(FetchDescriptor<TodoTask>()).map(\.title).sorted()
        #expect(topics == ["A", "B"])
        #expect(tasks == ["One", "Two"])
        #expect(box.deselected.isEmpty)
    }

    /// A failed save must not leave the tool's changes pending in the shared context,
    /// where the next UI save would write them after the agent was told the call failed.
    @Test func failedSaveIsReportedForEveryWrite() throws {
        let topic = try createTopic("Keep")
        let task = try createTask(topic, #"{"title":"Stay"}"#)
        struct Refused: Error {}
        tools.saveContext = { _ in throw Refused() }
        let refused = "Could not save: \(Refused().localizedDescription)"

        expectToolError(refused) { try call("create_topic", #"{"name":"New"}"#) }
        expectToolError(refused) { try call("update_topic", #"{"id":"\#(topic)","name":"Renamed"}"#) }
        expectToolError(refused) { try call("create_task", #"{"title":"New","topic_id":"\#(topic)"}"#) }
        expectToolError(refused) { try call("update_task", #"{"id":"\#(task)","title":"Renamed"}"#) }
        expectToolError(refused) { try call("delete_task", #"{"id":"\#(task)"}"#) }
    }

    @Test func idsSurviveReopeningTheStore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tunenook-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        var id: String
        do {
            let first = try ModelContainer(
                for: Topic.self, TodoTask.self, FocusSession.self, configurations: .init(url: url))
            let t = Self.makeTools(context: first.mainContext, box: Box(), calendar: calendar, now: fixedNow)
            let data = try t.call("create_topic", arguments: Data(#"{"name":"Keep"}"#.utf8))
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            id = try #require(object["id"] as? String)
        }
        let second = try ModelContainer(
            for: Topic.self, TodoTask.self, FocusSession.self, configurations: .init(url: url))
        let t = Self.makeTools(context: second.mainContext, box: Box(), calendar: calendar, now: fixedNow)
        let data = try t.call("update_topic", arguments: Data(#"{"id":"\#(id)","name":"Renamed"}"#.utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["name"] as? String == "Renamed")
    }

    @Test func unknownToolThrows() throws {
        expectToolError { try call("nope") }
        #expect(TuneNookTools.toolNames.count == 12)
    }
}
