import Foundation
import SwiftData

struct SessionDTO: Encodable {
    let kind: String
    let startedAt: Date
    let endedAt: Date
    let activeMinutes: Double
    let completed: Bool
    let taskId: String?
    let taskTitle: String?
    let topicId: String?
    let topicName: String?

    enum CodingKeys: String, CodingKey {
        case kind, startedAt, endedAt, activeMinutes, completed, taskId, taskTitle, topicId, topicName
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endedAt, forKey: .endedAt)
        try c.encode(activeMinutes, forKey: .activeMinutes)
        try c.encode(completed, forKey: .completed)
        try c.encode(taskId, forKey: .taskId)
        try c.encode(taskTitle, forKey: .taskTitle)
        try c.encode(topicId, forKey: .topicId)
        try c.encode(topicName, forKey: .topicName)
    }
}

struct SessionList: Encodable {
    let sessions: [SessionDTO]
    let hasMore: Bool
}

struct ListSessionsArgs: Decodable {
    var from: String?
    var to: String?
    var topicId: String?
    var taskId: String?
    var kind: String?
    var completedOnly: Bool?
    var limit: Int?
}

struct GetProgressArgs: Decodable {
    var days: Int?
}

struct TodayDTO: Encodable {
    let date: String
    let minutes: Int
    let sessions: Int
    let goal: GoalDTO
    let goalMet: Bool
}

struct StreakDTO: Encodable {
    let current: Int
    let longest: Int
    let freezesAvailable: Int
}

struct ProgressDayDTO: Encodable {
    let date: String
    let minutes: Int
    let sessions: Int
    let goalMet: Bool
}

struct ProgressDTO: Encodable {
    let today: TodayDTO
    let streak: StreakDTO
    let days: [ProgressDayDTO]
}

extension TuneNookTools {
    func listSessions(_ args: ListSessionsArgs) throws -> SessionList {
        let limit = args.limit ?? 100
        guard (1...500).contains(limit) else { throw ToolError("limit must be between 1 and 500.") }
        let kind: SessionKind? = try args.kind.map {
            guard let kind = SessionKind(rawValue: $0) else {
                throw ToolError("kind must be focus, shortBreak or longBreak.")
            }
            return kind
        }
        let to = try args.to.map { try parseDate($0, field: "to", endOfDay: true) } ?? now()
        let from = try args.from.map { try parseDate($0, field: "from") }
            ?? to.addingTimeInterval(-7 * 86_400)
        let topicFilter = try args.topicId.map { try topic(id: $0).persistentModelID }
        let taskFilter = try args.taskId.map { try task(id: $0).persistentModelID }

        let descriptor = FetchDescriptor<FocusSession>(
            predicate: #Predicate { $0.startedAt >= from && $0.startedAt <= to },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        let matching = try context.fetch(descriptor).filter { session in
            if let kind, session.kind != kind { return false }
            if args.completedOnly == true, !session.completed { return false }
            if let taskFilter, session.task?.persistentModelID != taskFilter { return false }
            if let topicFilter, session.task?.topic?.persistentModelID != topicFilter { return false }
            return true
        }
        return SessionList(sessions: matching.prefix(limit).map(sessionDTO), hasMore: matching.count > limit)
    }

    private func sessionDTO(_ session: FocusSession) -> SessionDTO {
        let task = session.task
        return SessionDTO(
            kind: session.kind.rawValue, startedAt: session.startedAt, endedAt: session.endedAt,
            activeMinutes: (session.focusedDuration / 60 * 10).rounded() / 10, completed: session.completed,
            taskId: task.map { EntityID.encode($0.persistentModelID) }, taskTitle: task?.title,
            topicId: task?.topic.map { EntityID.encode($0.persistentModelID) }, topicName: task?.topic?.name)
    }

    func getProgress(_ args: GetProgressArgs) throws -> ProgressDTO {
        let count = args.days ?? 7
        guard (1...366).contains(count) else { throw ToolError("days must be between 1 and 366.") }
        let sessions = try context.fetch(FetchDescriptor<FocusSession>(predicate: FocusSession.completedFocus))
        let progress = FocusProgress(sessions: sessions, goalStore: goalStore, now: now())
        let calendar = progress.calendar

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar.calendar
        formatter.timeZone = calendar.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        let today = progress.today
        let goal = progress.todayGoal
        let days = (0..<count).reversed().map { offset -> ProgressDayDTO in
            let day = calendar.adding(days: -offset, to: today)
            let total = progress.total(on: day)
            return ProgressDayDTO(date: formatter.string(from: day), minutes: total.minutes, sessions: total.sessions,
                                  goalMet: progress.goals.goal(on: day).isMet(total))
        }
        return ProgressDTO(
            today: TodayDTO(date: formatter.string(from: today), minutes: progress.todayTotal.minutes,
                            sessions: progress.todayTotal.sessions,
                            goal: GoalDTO(kind: goal.kind.rawValue, target: goal.target), goalMet: progress.todayMet),
            streak: StreakDTO(current: progress.streak.current, longest: progress.streak.longest,
                              freezesAvailable: progress.streak.freezesAvailable),
            days: days)
    }
}
