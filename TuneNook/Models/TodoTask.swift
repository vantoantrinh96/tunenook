import Foundation
import SwiftData

@Model
final class TodoTask {
    var title: String
    var estimatedSessions: Int
    var isDone: Bool
    var createdAt: Date
    var completedAt: Date?
    var topic: Topic?

    @Relationship(deleteRule: .nullify, inverse: \FocusSession.task)
    var sessions: [FocusSession] = []

    init(title: String, estimatedSessions: Int = 1, topic: Topic? = nil, createdAt: Date = .now) {
        self.title = title
        self.estimatedSessions = estimatedSessions
        self.isDone = false
        self.topic = topic
        self.createdAt = createdAt
    }

    /// Completed focus sessions spent on this task.
    var actualSessions: Int {
        sessions.filter { $0.kind == .focus && $0.completed }.count
    }

    func setDone(_ done: Bool, at date: Date = .now) {
        isDone = done
        completedAt = done ? date : nil
    }
}
