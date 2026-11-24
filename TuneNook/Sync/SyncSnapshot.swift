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
    var mergedInto: UUID?

    func sameContent(as other: SyncTopic) -> Bool {
        id == other.id && name == other.name && colorHex == other.colorHex
            && createdAt == other.createdAt
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
    var deadline: Date?
    var topicID: UUID?

    func sameContent(as other: SyncTask) -> Bool {
        id == other.id && title == other.title && estimatedSessions == other.estimatedSessions
            && isDone == other.isDone && createdAt == other.createdAt
            && completedAt == other.completedAt && deadline == other.deadline && topicID == other.topicID
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

    /// One formatter for every date: building one per date made large snapshots
    /// take seconds. `ISO8601DateFormatter` is thread-safe, and this one is never
    /// changed after it is made.
    nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Parses a wire date. The usual `yyyy-MM-ddTHH:mm:ss.SSSZ` shape is read by
    /// hand (the formatter takes ~100 µs a date); anything else goes to the formatter.
    static func parseDate(_ string: String) -> Date? {
        fastParse(string) ?? formatter.date(from: string)
    }

    /// The same instant the formatter yields for a millisecond date, or nil when
    /// the string is not exactly that shape. Years before 1600 go to the
    /// formatter, which may switch to the Julian calendar there.
    static func fastParse(_ string: String) -> Date? {
        var string = string
        return string.withUTF8 { b -> Date? in
            guard b.count == 24, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A, b[16] == 0x3A,
                  b[19] == 0x2E, b[23] == 0x5A else { return nil }
            func number(_ start: Int, _ length: Int) -> Int? {
                var value = 0
                for i in start..<(start + length) {
                    let digit = Int(b[i]) - 0x30
                    guard (0...9).contains(digit) else { return nil }
                    value = value * 10 + digit
                }
                return value
            }
            guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
                  let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
                  let millis = number(20, 3),
                  year >= 1600, (1...12).contains(month), hour < 24, minute < 60, second < 60
            else { return nil }
            let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            guard (1...monthDays[month - 1]).contains(day) else { return nil }
            // Days since 1970-01-01 in the proleptic Gregorian calendar.
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yearOfEra = y - era * 400
            let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            let days = era * 146_097 + dayOfEra - 719_468
            let seconds = ((days * 24 + hour) * 60 + minute) * 60 + second
            return Date(timeIntervalSince1970: Double(seconds * 1000 + millis) / 1000)
        }
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
            try c.encode(DeviceSnapshot.formatter.string(from: date))
        }
        return try encoder.encode(copy)
    }

    static func decode(_ data: Data) throws -> DeviceSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let d = parseDate(s) else {
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
