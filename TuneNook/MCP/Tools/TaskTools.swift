import Foundation
import SwiftData

struct TaskDTO: Encodable {
    let id: String
    let title: String
    let topicId: String?
    let topicName: String?
    let estimatedSessions: Int
    let actualSessions: Int
    let done: Bool
    let createdAt: Date
    let completedAt: Date?
    let deadline: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, topicId, topicName, estimatedSessions, actualSessions, done, createdAt, completedAt, deadline
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(topicId, forKey: .topicId)
        try c.encode(topicName, forKey: .topicName)
        try c.encode(estimatedSessions, forKey: .estimatedSessions)
        try c.encode(actualSessions, forKey: .actualSessions)
        try c.encode(done, forKey: .done)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(completedAt, forKey: .completedAt)
        try c.encode(deadline, forKey: .deadline)
    }
}

struct TaskList: Encodable { let tasks: [TaskDTO] }

struct ListTasksArgs: Decodable {
    var status: String?
    var topicId: String?
}

struct CreateTaskArgs: Decodable {
    var title: String?
    var topicId: String?
    var estimatedSessions: Int?
    var deadline: String?
}

struct UpdateTaskArgs: Decodable {
    enum DeadlineChange { case keep, clear, set(String) }

    var id: String?
    var title: String?
    var topicId: String?
    var estimatedSessions: Int?
    var done: Bool?
    var deadline: DeadlineChange = .keep
    var topicIdIsNull = false

    enum CodingKeys: String, CodingKey { case id, title, topicId, estimatedSessions, done, deadline }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        estimatedSessions = try c.decodeIfPresent(Int.self, forKey: .estimatedSessions)
        done = try c.decodeIfPresent(Bool.self, forKey: .done)
        if c.contains(.topicId) {
            if try c.decodeNil(forKey: .topicId) { topicIdIsNull = true } else { topicId = try c.decode(String.self, forKey: .topicId) }
        }
        if c.contains(.deadline) {
            deadline = try c.decodeNil(forKey: .deadline) ? .clear : .set(c.decode(String.self, forKey: .deadline))
        }
    }
}

extension TuneNookTools {
    func taskDTO(_ task: TodoTask) -> TaskDTO {
        TaskDTO(id: EntityID.encode(task.persistentModelID), title: task.title,
                topicId: task.topic.map { EntityID.encode($0.persistentModelID) }, topicName: task.topic?.name,
                estimatedSessions: task.estimatedSessions, actualSessions: task.actualSessions,
                done: task.isDone, createdAt: task.createdAt, completedAt: task.completedAt,
                deadline: task.deadline)
    }

    func validEstimate(_ value: Int) throws -> Int {
        guard (1...12).contains(value) else { throw ToolError("estimated_sessions must be between 1 and 12.") }
        return value
    }

    func listTasks(_ args: ListTasksArgs) throws -> TaskList {
        let status = args.status ?? "open"
        guard ["open", "done", "all"].contains(status) else {
            throw ToolError("status must be open, done or all.")
        }
        let all = try args.topicId.map { try topic(id: $0).tasks } ?? context.fetch(FetchDescriptor<TodoTask>())
        // Same ordering as Topic.openTasks / doneTasks.
        let open = all.filter { !$0.isDone }.sorted { $0.createdAt < $1.createdAt }
        let done = all.filter(\.isDone).sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
        let picked = status == "open" ? open : status == "done" ? done : open + done
        return TaskList(tasks: picked.map(taskDTO))
    }

    func createTask(_ args: CreateTaskArgs) throws -> TaskDTO {
        guard let title = args.title else { throw ToolError("title is required.") }
        let clean = try cleanName(title, field: "title")
        guard let topicID = args.topicId else { throw ToolError("topic_id is required.") }
        let estimate = try args.estimatedSessions.map(validEstimate) ?? 1
        let deadline = try args.deadline.map { try parseDate($0, field: "deadline") }
        let topic = try topic(id: topicID)
        let task = TodoTask(title: clean, estimatedSessions: estimate, topic: topic, deadline: deadline, createdAt: now())
        context.insert(task)
        try save()
        return taskDTO(task)
    }

    func updateTask(_ args: UpdateTaskArgs) throws -> TaskDTO {
        let task = try task(id: requireID(args.id))
        if args.topicIdIsNull { throw ToolError("topic_id cannot be null; a task must belong to a topic.") }
        let title = try args.title.map { try cleanName($0, field: "title") }
        let estimate = try args.estimatedSessions.map(validEstimate)
        let topic = try args.topicId.map { try self.topic(id: $0) }
        var deadline: Date??
        switch args.deadline {
        case .keep: deadline = nil
        case .clear: deadline = .some(nil)
        case .set(let string): deadline = .some(try parseDate(string, field: "deadline"))
        }
        if let title { task.title = title }
        if let estimate { task.estimatedSessions = estimate }
        if let topic { task.topic = topic }
        if let deadline { task.deadline = deadline }
        if let done = args.done { task.setDone(done, at: now()) }
        try save()
        return taskDTO(task)
    }

    func deleteTask(_ args: IDArgs) throws -> Deleted {
        let task = try task(id: requireID(args.id))
        if isBusy(task) { throw Self.busyError }
        deselect(task)
        context.delete(task)
        try save()
        return Deleted()
    }
}
