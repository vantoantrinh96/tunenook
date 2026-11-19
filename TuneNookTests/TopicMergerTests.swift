import Foundation
import SwiftData
import Testing
@testable import TuneNook

@MainActor
struct TopicMergerTests {
    let container: ModelContainer
    let context: ModelContext
    let defaults = UserDefaults(suiteName: UUID().uuidString)!

    init() throws {
        container = try ModelContainer(
            for: Topic.self, TodoTask.self, FocusSession.self,
            configurations: .init(isStoredInMemoryOnly: true))
        context = container.mainContext
    }

    private func makeTopics() -> (Topic, Topic) {
        let source = Topic(name: "Work")
        let target = Topic(name: "Office")
        context.insert(source)
        context.insert(target)
        return (source, target)
    }

    @Test func movesTasksAndSessions() throws {
        let (source, target) = makeTopics()
        let a = TodoTask(title: "A", topic: source)
        let b = TodoTask(title: "B", topic: source)
        let existing = TodoTask(title: "C", topic: target)
        [a, b, existing].forEach(context.insert)
        for i in 0..<3 {
            let start = Date(timeIntervalSince1970: Double(i) * 3_600)
            context.insert(FocusSession(kind: .focus, startedAt: start, endedAt: start.addingTimeInterval(1_500),
                                        activeSeconds: 1_500, completed: true, task: a))
        }
        try context.save()

        try TopicMerger.merge(source, into: target, context: context, defaults: defaults)

        let topics = try context.fetch(FetchDescriptor<Topic>())
        #expect(topics.count == 1)
        #expect(topics.first === target)
        #expect(target.tasks.count == 3)
        #expect(a.sessions.count == 3)
        #expect(a.topic === target)
        #expect(try context.fetchCount(FetchDescriptor<FocusSession>()) == 3)
        #expect(try context.fetchCount(FetchDescriptor<TodoTask>()) == 3)
    }

    @Test func recordsMergeForSync() throws {
        let (source, target) = makeTopics()
        let sourceID = source.syncID
        try TopicMerger.merge(source, into: target, context: context, defaults: defaults)
        #expect(TopicMerger.pending(in: defaults) == [sourceID: target.syncID])
        TopicMerger.clear([sourceID], in: defaults)
        #expect(TopicMerger.pending(in: defaults).isEmpty)
    }

    @Test func runningTaskKeepsRunning() throws {
        let (source, target) = makeTopics()
        let task = TodoTask(title: "A", topic: source)
        context.insert(task)
        try context.save()
        let settings = TimerSettings(autoStartBreaks: false, autoStartFocus: false)
        let engine = TimerEngine(clock: { Date(timeIntervalSince1970: 1_800_000_000) }, settings: { settings })
        engine.startFocus(on: task)
        #expect(engine.isActive)

        try TopicMerger.merge(source, into: target, context: context, defaults: defaults)

        #expect(engine.isActive)
        #expect(engine.currentTask === task)
        #expect(task.topic === target)
    }

    @Test func mergeIntoSelfThrows() throws {
        let (source, _) = makeTopics()
        #expect(throws: TopicMerger.MergeError.self) {
            try TopicMerger.merge(source, into: source, context: context, defaults: defaults)
        }
        #expect(TopicMerger.pending(in: defaults).isEmpty)
    }

    @Test func summaryCountsTasks() {
        #expect(MergeTopicSheet.summary(taskCount: 1, sourceName: "Work")
                == "Moves 1 task and their history into the topic you pick, then deletes “Work”.")
        #expect(MergeTopicSheet.summary(taskCount: 3, sourceName: "Work")
                == "Moves 3 tasks and their history into the topic you pick, then deletes “Work”.")
    }
}
