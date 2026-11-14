import Foundation
import SwiftData

enum SessionKind: String, Codable, CaseIterable, Sendable {
    case focus
    case shortBreak
    case longBreak

    var isBreak: Bool { self != .focus }

    var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short Break"
        case .longBreak: "Long Break"
        }
    }
}

/// One finished (or abandoned) timer phase. Streaks and heatmaps are derived from these rows.
@Model
final class FocusSession {
    var startedAt: Date
    var endedAt: Date
    var kindRaw: String
    var completed: Bool
    var task: TodoTask?

    init(kind: SessionKind, startedAt: Date, endedAt: Date, completed: Bool, task: TodoTask?) {
        self.kindRaw = kind.rawValue
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.completed = completed
        self.task = task
    }

    var kind: SessionKind {
        SessionKind(rawValue: kindRaw) ?? .focus
    }
}
