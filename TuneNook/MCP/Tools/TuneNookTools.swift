import Foundation
import SwiftData

/// Something the agent got wrong. The message is shown to the agent verbatim.
struct ToolError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    init(message: String) { self.message = message }
}

/// The SDK-free tool layer: JSON in, JSON out. Everything runs on the main actor.
@MainActor
final class TuneNookTools {
    let context: ModelContext
    let defaults: UserDefaults
    let goalStore: GoalStore
    let stations: [RadioStation]
    let isBusy: (TodoTask) -> Bool
    let deselect: (TodoTask) -> Void
    let now: () -> Date
    let calendar: Calendar
    /// How a write is saved; tests swap it to make saving fail.
    var saveContext: (ModelContext) throws -> Void = { try $0.save() }

    init(context: ModelContext,
         defaults: UserDefaults,
         goalStore: GoalStore,
         stations: [RadioStation],
         isBusy: @escaping (TodoTask) -> Bool,
         deselect: @escaping (TodoTask) -> Void,
         now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current) {
        self.context = context
        self.defaults = defaults
        self.goalStore = goalStore
        self.stations = stations
        self.isBusy = isBusy
        self.deselect = deselect
        self.now = now
        self.calendar = calendar
    }

    static let toolNames = [
        "list_topics", "create_topic", "update_topic", "delete_topic",
        "list_tasks", "create_task", "update_task", "delete_task",
        "get_settings", "update_settings",
        "list_sessions", "get_progress",
    ]

    /// Runs one tool. `arguments` is a JSON object (empty data means `{}`). Returns a JSON object.
    /// Throws `ToolError` for anything the agent got wrong; nothing else escapes.
    func call(_ name: String, arguments: Data) throws -> Data {
        let args = arguments.isEmpty ? Data("{}".utf8) : arguments
        do {
            let isObject = (try? JSONSerialization.jsonObject(with: args)) is [String: Any]
            guard isObject else { throw ToolError("Arguments must be a JSON object.") }
            switch name {
            case "list_topics": return try encode(listTopics())
            case "create_topic": return try encode(createTopic(decode(args)))
            case "update_topic": return try encode(updateTopic(decode(args)))
            case "delete_topic": return try encode(deleteTopic(decode(args)))
            case "list_tasks": return try encode(listTasks(decode(args)))
            case "create_task": return try encode(createTask(decode(args)))
            case "update_task": return try encode(updateTask(decode(args)))
            case "delete_task": return try encode(deleteTask(decode(args)))
            case "get_settings": return try encode(getSettings())
            case "update_settings": return try encode(updateSettings(decode(args)))
            case "list_sessions": return try encode(listSessions(decode(args)))
            case "get_progress": return try encode(getProgress(decode(args)))
            default: throw ToolError("Unknown tool \(name).")
            }
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError("The tool failed: \(error.localizedDescription)")
        }
    }

    // MARK: JSON

    func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch let error as DecodingError {
            throw ToolError("Invalid argument: \(Self.describe(error)).")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func field(_ path: [CodingKey]) -> String {
            let key = path.last?.stringValue ?? "arguments"
            return key.unicodeScalars.reduce("") { $0 + (CharacterSet.uppercaseLetters.contains($1) ? "_" + String($1).lowercased() : String($1)) }
        }
        switch error {
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            return "\(field(ctx.codingPath)) has the wrong type"
        case .keyNotFound(let key, _):
            return "\(field([key])) is required"
        @unknown default:
            return "malformed arguments"
        }
    }

    func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let timeZone = calendar.timeZone
        // Built once per encode; only used synchronously inside this call.
        nonisolated(unsafe) let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return try encoder.encode(value)
    }

    /// Full ISO 8601, or `YYYY-MM-DD` meaning the start of that day in `calendar`
    /// (or its last second, with `endOfDay`).
    func parseDate(_ string: String, field: String, endOfDay: Bool = false) throws -> Date {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
           let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) {
            let comps = DateComponents(year: y, month: m, day: d)
            if let date = calendar.date(from: comps),
               calendar.dateComponents([.year, .month, .day], from: date) == comps {
                if endOfDay, let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: date) {
                    return end
                }
                return date
            }
        } else {
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = plain.date(from: string) ?? fractional.date(from: string) { return date }
        }
        throw ToolError("\(field) must be an ISO 8601 date or YYYY-MM-DD.")
    }

    // MARK: Store

    /// Saves the tool's writes. A failed save is reported, not rolled back: `ModelContext.rollback()`
    /// traps inside SwiftData on macOS 15 ("A ModelSnapshot must be initialized with a known-keys dictionary").
    func save() throws {
        do {
            try saveContext(context)
        } catch {
            throw ToolError("Could not save: \(error.localizedDescription)")
        }
    }

    func topic(id string: String) throws -> Topic {
        guard let topic = try row(Topic.self, id: string) else { throw ToolError("No topic with that id.") }
        return topic
    }

    func task(id string: String) throws -> TodoTask {
        guard let task = try row(TodoTask.self, id: string) else { throw ToolError("No task with that id.") }
        return task
    }

    /// The predicate matches the row's primary key only, and row numbers are dense in every table,
    /// so an id of another entity (or another store) must be rejected before and after the fetch.
    private func row<T: PersistentModel>(_ type: T.Type, id string: String) throws -> T? {
        // A @Model's entity name is its class name (`Schema.entityName(for:)` needs macOS 15).
        guard let id = EntityID.decode(string), id.entityName == String(describing: T.self) else { return nil }
        // Compare encodings, not `==`: on macOS 15 a decoded identifier never equals the live one,
        // even with identical entity, store and primary key. Check every result, not just the first:
        // on macOS 15 the fetch can also return unsaved inserts that are pending in the context.
        let canonical = EntityID.encode(id)
        return try context.fetch(FetchDescriptor<T>(predicate: #Predicate { $0.persistentModelID == id }))
            .first { EntityID.encode($0.persistentModelID) == canonical }
    }

    func cleanName(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolError("\(field) must not be empty.") }
        return trimmed
    }
}

struct Deleted: Encodable { let deleted = true }
