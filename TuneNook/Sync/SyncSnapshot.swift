import Foundation

/// A settings value as it travels in a snapshot: a bare JSON primitive.
enum SyncValue: Codable, Equatable, Sendable {
    case int(Int), bool(Bool), string(String), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported sync value") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

struct SyncMeta: Codable, Equatable, Sendable {
    var modifiedAt: Date
    var modifiedBy: String
    var deleted: Bool
}

extension SyncMeta {
    /// Newer `modifiedAt` wins; a tie goes to the larger `modifiedBy`.
    func wins(over other: SyncMeta) -> Bool {
        if modifiedAt != other.modifiedAt { return modifiedAt > other.modifiedAt }
        return modifiedBy > other.modifiedBy
    }
}

struct SyncTopic: Codable, Equatable, Sendable {
    var id: UUID
    var meta: SyncMeta
    var name: String
    var colorHex: String
    var createdAt: Date
    var deadline: Date?
    var mergedInto: UUID?

    func sameContent(as other: SyncTopic) -> Bool {
        id == other.id && name == other.name && colorHex == other.colorHex
            && createdAt == other.createdAt && deadline == other.deadline
    }
}

struct SyncTask: Codable, Equatable, Sendable {
    var id: UUID
    var meta: SyncMeta
    var title: String
    var estimatedSessions: Int
    var isDone: Bool
    var createdAt: Date
    var completedAt: Date?
    var topicID: UUID?

    func sameContent(as other: SyncTask) -> Bool {
        id == other.id && title == other.title && estimatedSessions == other.estimatedSessions
            && isDone == other.isDone && createdAt == other.createdAt
            && completedAt == other.completedAt && topicID == other.topicID
    }
}

struct SyncSession: Codable, Equatable, Sendable {
    var id: UUID
    var meta: SyncMeta
    var kind: String
    var startedAt: Date
    var endedAt: Date
    var activeSeconds: Double
    var completed: Bool
    var taskID: UUID?

    func sameContent(as other: SyncSession) -> Bool {
        id == other.id && kind == other.kind && startedAt == other.startedAt
            && endedAt == other.endedAt && activeSeconds == other.activeSeconds
            && completed == other.completed && taskID == other.taskID
    }
}

struct SyncSetting: Codable, Equatable, Sendable {
    var value: SyncValue
    var meta: SyncMeta

    func sameContent(as other: SyncSetting) -> Bool { value == other.value }
}

struct SyncGoal: Codable, Equatable, Sendable {
    var day: Date
    var meta: SyncMeta
    var kind: String
    var target: Int

    func sameContent(as other: SyncGoal) -> Bool {
        day == other.day && kind == other.kind && target == other.target
    }
}

struct DeviceSnapshot: Codable, Equatable, Sendable {
    static let currentFormat = 1

    var formatVersion: Int
    var deviceID: String
    var deviceName: String
    var appVersion: String
    var exportedAt: Date
    var topics: [SyncTopic]
    var tasks: [SyncTask]
    var sessions: [SyncSession]
    var settings: [String: SyncSetting]
    var goals: [SyncGoal]
    var unlockedIcons: [String]

    static func empty(deviceID: String, deviceName: String) -> DeviceSnapshot {
        DeviceSnapshot(formatVersion: currentFormat, deviceID: deviceID, deviceName: deviceName,
                       appVersion: "", exportedAt: Date(), topics: [], tasks: [], sessions: [],
                       settings: [:], goals: [], unlockedIcons: [])
    }

    private static func makeFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    func encoded() throws -> Data {
        var copy = self
        copy.topics.sort { $0.id.uuidString < $1.id.uuidString }
        copy.tasks.sort { $0.id.uuidString < $1.id.uuidString }
        copy.sessions.sort { $0.id.uuidString < $1.id.uuidString }
        copy.goals.sort { $0.day < $1.day }
        copy.unlockedIcons.sort()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(DeviceSnapshot.makeFormatter().string(from: date))
        }
        return try encoder.encode(copy)
    }

    static func decode(_ data: Data) throws -> DeviceSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let d = makeFormatter().date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
            }
            return d
        }
        return try decoder.decode(DeviceSnapshot.self, from: data)
    }
}

/// One UserDefaults-backed setting that is synced between Macs.
struct SyncedSetting: Sendable {
    let key: String
    let defaultValue: SyncValue

    static let all: [SyncedSetting] = [
        .init(key: "timer.focusMinutes", defaultValue: .int(25)),
        .init(key: "timer.shortBreakMinutes", defaultValue: .int(5)),
        .init(key: "timer.longBreakMinutes", defaultValue: .int(15)),
        .init(key: "timer.longBreakInterval", defaultValue: .int(4)),
        .init(key: "timer.autoStartBreaks", defaultValue: .bool(true)),
        .init(key: "timer.autoStartFocus", defaultValue: .bool(false)),
        .init(key: "away.pauseOnLock", defaultValue: .bool(true)),
        .init(key: "away.idleMinutes", defaultValue: .int(0)),
        .init(key: "music.breakAction", defaultValue: .string("lowerVolume")),
        .init(key: "music.breakStationID", defaultValue: .null),
        .init(key: "radio.selectedStationID", defaultValue: .null),
        .init(key: "celebrations.level", defaultValue: .string("milestones")),
        .init(key: "goals.dayStartHour", defaultValue: .int(0)),
        .init(key: "rewards.menuBarIcon", defaultValue: .string("note")),
    ]

    func read(from defaults: UserDefaults) -> SyncValue {
        guard let object = defaults.object(forKey: key) else { return defaultValue }
        switch defaultValue {
        case .int: return (object as? NSNumber).map { .int($0.intValue) } ?? defaultValue
        case .bool: return (object as? NSNumber).map { .bool($0.boolValue) } ?? defaultValue
        case .string, .null: return (object as? String).map { .string($0) } ?? defaultValue
        }
    }

    func write(_ value: SyncValue, to defaults: UserDefaults) {
        switch value {
        case .int(let v): defaults.set(v, forKey: key)
        case .bool(let v): defaults.set(v, forKey: key)
        case .string(let v): defaults.set(v, forKey: key)
        case .null: defaults.removeObject(forKey: key)
        }
    }
}

extension Date {
    /// This date floored to whole milliseconds since 1970: the precision a
    /// snapshot keeps. Idempotent, and survives an encode/decode round trip
    /// exactly, so records built from the store compare equal to decoded ones.
    var syncMillis: Date {
        // The small nudge keeps dates already on a millisecond from dropping
        // one when `* 1000` lands a hair below the integer.
        Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000 + 0.001).rounded(.down) / 1000)
    }
}
