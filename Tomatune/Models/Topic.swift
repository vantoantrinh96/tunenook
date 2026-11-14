import Foundation
import SwiftData

@Model
final class Topic {
    var name: String
    var colorHex: String
    var createdAt: Date
    var deadline: Date?

    @Relationship(deleteRule: .cascade, inverse: \TodoTask.topic)
    var tasks: [TodoTask] = []

    init(name: String, colorHex: String = Topic.palette[0], deadline: Date? = nil, createdAt: Date = .now) {
        self.name = name
        self.colorHex = colorHex
        self.deadline = deadline
        self.createdAt = createdAt
    }

    var openTasks: [TodoTask] {
        tasks.filter { !$0.isDone }.sorted { $0.createdAt < $1.createdAt }
    }

    var doneTasks: [TodoTask] {
        tasks.filter(\.isDone).sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
    }

    static let palette = ["#E5533D", "#F29E38", "#E9C46A", "#43AA8B", "#4D8FD6", "#8E6FD8", "#D96BA0", "#8A8F98"]
}
