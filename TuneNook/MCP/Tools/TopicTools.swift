import Foundation
import SwiftData

struct TopicDTO: Encodable {
    let id: String
    let name: String
    let color: String
    let openTasks: Int
    let doneTasks: Int

    enum CodingKeys: String, CodingKey { case id, name, color, openTasks, doneTasks }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(color, forKey: .color)
        try c.encode(openTasks, forKey: .openTasks)
        try c.encode(doneTasks, forKey: .doneTasks)
    }
}

struct TopicList: Encodable { let topics: [TopicDTO] }

struct CreateTopicArgs: Decodable {
    var name: String?
    var color: String?
}

struct UpdateTopicArgs: Decodable {
    var id: String?
    var name: String?
    var color: String?
}

struct IDArgs: Decodable { var id: String? }

extension TuneNookTools {
    func topicDTO(_ topic: Topic) -> TopicDTO {
        TopicDTO(id: EntityID.encode(topic.persistentModelID), name: topic.name, color: topic.colorHex,
                 openTasks: topic.openTasks.count, doneTasks: topic.doneTasks.count)
    }

    func requireID(_ id: String?) throws -> String {
        guard let id else { throw ToolError("id is required.") }
        return id
    }

    func validColor(_ color: String) throws -> String {
        guard Topic.palette.contains(color) else {
            throw ToolError("color must be one of: \(Topic.palette.joined(separator: ", ")).")
        }
        return color
    }

    func listTopics() throws -> TopicList {
        let topics = try context.fetch(FetchDescriptor<Topic>(sortBy: [SortDescriptor(\.createdAt)]))
        return TopicList(topics: topics.map(topicDTO))
    }

    func createTopic(_ args: CreateTopicArgs) throws -> TopicDTO {
        guard let name = args.name else { throw ToolError("name is required.") }
        let clean = try cleanName(name, field: "name")
        let color = try args.color.map(validColor) ?? Topic.palette[0]
        let topic = Topic(name: clean, colorHex: color, createdAt: now())
        context.insert(topic)
        try save()
        return topicDTO(topic)
    }

    func updateTopic(_ args: UpdateTopicArgs) throws -> TopicDTO {
        let topic = try topic(id: requireID(args.id))
        let name = try args.name.map { try cleanName($0, field: "name") }
        let color = try args.color.map(validColor)
        if let name { topic.name = name }
        if let color { topic.colorHex = color }
        try save()
        return topicDTO(topic)
    }

    func deleteTopic(_ args: IDArgs) throws -> Deleted {
        let topic = try topic(id: requireID(args.id))
        let tasks = topic.tasks
        if tasks.contains(where: isBusy) { throw Self.busyError }
        tasks.forEach(deselect)
        context.delete(topic)
        try save()
        return Deleted()
    }

    static let busyError = ToolError("A focus session is running on this task. Stop it in TuneNook first.")
}
