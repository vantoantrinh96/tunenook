import Foundation
import SwiftData
import Testing
@testable import TuneNook

@MainActor
struct SyncIDBackfillTests {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try ModelContainer(
            for: Topic.self, TodoTask.self, FocusSession.self,
            configurations: .init(isStoredInMemoryOnly: true))
        context = container.mainContext
    }

    private func session(at offset: TimeInterval) -> FocusSession {
        let start = Date(timeIntervalSince1970: 1_800_000_000 + offset)
        return FocusSession(kind: .focus, startedAt: start, endedAt: start.addingTimeInterval(60),
                            activeSeconds: 60, completed: true, task: nil)
    }

    @Test func newRowsGetDistinctIDs() {
        let topics = [Topic(name: "A"), Topic(name: "B")]
        let tasks = [TodoTask(title: "A"), TodoTask(title: "B")]
        let sessions = [session(at: 0), session(at: 100)]
        topics.forEach(context.insert)
        tasks.forEach(context.insert)
        sessions.forEach(context.insert)
        let ids = topics.map(\.syncID) + tasks.map(\.syncID) + sessions.map(\.syncID)
        #expect(Set(ids).count == 6)
    }

    @Test func backfillGivesDuplicatesFreshIDs() throws {
        let shared = UUID()
        let sharedSessions = UUID()
        for i in 0..<3 {
            let t = Topic(name: "T\(i)", createdAt: Date(timeIntervalSince1970: Double(i)))
            t.syncID = shared
            context.insert(t)
        }
        for i in 0..<2 {
            let s = session(at: Double(i) * 100)
            s.syncID = sharedSessions
            context.insert(s)
        }
        try context.save()

        let changed = try SyncIDBackfill.run(in: context)
        #expect(changed == 3)
        let topics = try context.fetch(FetchDescriptor<Topic>())
        let sessions = try context.fetch(FetchDescriptor<FocusSession>())
        #expect(topics.count == 3)
        #expect(sessions.count == 2)
        #expect(Set(topics.map(\.syncID)).count == 3)
        #expect(Set(sessions.map(\.syncID)).count == 2)
    }

    @Test func backfillIsNoOpWhenUnique() throws {
        context.insert(Topic(name: "A"))
        context.insert(TodoTask(title: "B"))
        context.insert(session(at: 0))
        try context.save()
        #expect(try SyncIDBackfill.run(in: context) == 0)
    }
}
