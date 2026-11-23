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
    var syncID: UUID = UUID()
    var startedAt: Date
    var endedAt: Date
    var kindRaw: String
    var completed: Bool
    /// Time the timer actually ran, excluding pauses. 0 for rows saved before v0.2.
    var activeSeconds: Double = 0
    var task: TodoTask?

    init(kind: SessionKind, startedAt: Date, endedAt: Date, activeSeconds: Double, completed: Bool, task: TodoTask?) {
        self.kindRaw = kind.rawValue
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activeSeconds = activeSeconds
        self.completed = completed
        self.task = task
    }

    static var completedFocus: Predicate<FocusSession> {
        let focus = SessionKind.focus.rawValue
        return #Predicate { $0.completed && $0.kindRaw == focus }
    }

    var focusedDuration: TimeInterval {
        activeSeconds > 0 ? activeSeconds : endedAt.timeIntervalSince(startedAt)
    }

    var kind: SessionKind {
        SessionKind(rawValue: kindRaw) ?? .focus
    }
}
