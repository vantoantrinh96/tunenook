import Foundation
import SwiftData
import Testing
@testable import TuneNook

@MainActor
struct SidebarSelectionTests {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try ModelContainer(
            for: Topic.self, TodoTask.self, FocusSession.self,
            configurations: .init(isStoredInMemoryOnly: true))
        context = container.mainContext
    }

    func live() throws -> [Topic] {
        try context.fetch(FetchDescriptor<Topic>())
    }

    @Test func topicDeletedElsewhereFallsBackToProgress() throws {
        let kept = Topic(name: "Kept")
        let gone = Topic(name: "Gone")
        context.insert(kept)
        context.insert(gone)
        try context.save()
        let selection = SidebarItem.topic(gone)

        context.delete(gone)
        try context.save()

        #expect(selection.keeping(try live()) == .progress)
        #expect(SidebarItem.topic(kept).keeping(try live()) == .topic(kept))
    }

    @Test func progressIsKeptEvenWithNoTopics() throws {
        #expect(SidebarItem.progress.keeping(try live()) == .progress)
    }
}
