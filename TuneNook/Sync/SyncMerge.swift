import Foundation

/// Pure record-by-record merge of device snapshots.
enum SyncMerge {
    /// Tombstones older than this are dropped from merged output.
    static let tombstoneWindow: TimeInterval = 90 * 86_400

    static func merge(_ snapshots: [DeviceSnapshot], into identity: DeviceSnapshot, now: Date) -> DeviceSnapshot {
        var result = identity
        result.formatVersion = DeviceSnapshot.currentFormat
        result.exportedAt = now

        result.topics = pick(snapshots.flatMap(\.topics), key: \.id, meta: \.meta, now: now)
        result.tasks = pick(snapshots.flatMap(\.tasks), key: \.id, meta: \.meta, now: now)
        result.sessions = pick(snapshots.flatMap(\.sessions), key: \.id, meta: \.meta, now: now)
        result.goals = pick(snapshots.flatMap(\.goals), key: \.day, meta: \.meta, now: now)

        var settings: [String: SyncSetting] = [:]
        for snapshot in snapshots {
            for (key, setting) in snapshot.settings {
                if let existing = settings[key], !setting.meta.wins(over: existing.meta) { continue }
                settings[key] = setting
            }
        }
        result.settings = settings.filter { !isExpired($0.value.meta, now: now) }

        result.unlockedIcons = Set(snapshots.flatMap(\.unlockedIcons)).sorted()
        return result
    }

    private static func isExpired(_ meta: SyncMeta, now: Date) -> Bool {
        meta.deleted && now.timeIntervalSince(meta.modifiedAt) > tombstoneWindow
    }

    private static func pick<R, K: Hashable>(_ records: [R], key: KeyPath<R, K>, meta: KeyPath<R, SyncMeta>, now: Date) -> [R] {
        var best: [K: R] = [:]
        for record in records {
            let k = record[keyPath: key]
            if let existing = best[k], !record[keyPath: meta].wins(over: existing[keyPath: meta]) { continue }
            best[k] = record
        }
        return best.values.filter { !isExpired($0[keyPath: meta], now: now) }
    }
}

/// What the local store should hold after a merge: live rows only, with
/// topic merges followed and dangling references cleaned up.
struct ResolvedState: Equatable, Sendable {
    var topics: [SyncTopic]
    var tasks: [SyncTask]
    var sessions: [SyncSession]
    var settings: [String: SyncValue]
    var goals: [SyncGoal]
    var unlockedIcons: Set<String>
}

extension SyncMerge {
    private static let maxMergeHops = 16

    private enum TopicOutcome {
        case live(UUID), deleted, unknown
    }

    static func resolve(_ snapshot: DeviceSnapshot) -> ResolvedState {
        let topicsByID = Dictionary(snapshot.topics.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        func outcome(for start: UUID) -> TopicOutcome {
            var current = start
            var seen: Set<UUID> = []
            for _ in 0...maxMergeHops {
                guard seen.insert(current).inserted else { return .deleted }   // cycle
                guard let topic = topicsByID[current] else { return .unknown }
                if !topic.meta.deleted { return .live(topic.id) }
                guard let next = topic.mergedInto else { return .deleted }
                current = next
            }
            return .deleted   // chain too long
        }

        var tasks: [SyncTask] = []
        for var task in snapshot.tasks where !task.meta.deleted {
            guard let topicID = task.topicID else { continue }
            switch outcome(for: topicID) {
            case .live(let target):
                task.topicID = target
                tasks.append(task)
            case .deleted, .unknown:
                continue
            }
        }
        let liveTaskIDs = Set(tasks.map(\.id))

        var sessions: [SyncSession] = []
        for var session in snapshot.sessions where !session.meta.deleted {
            if let taskID = session.taskID, !liveTaskIDs.contains(taskID) { session.taskID = nil }
            sessions.append(session)
        }

        var settings: [String: SyncValue] = [:]
        for (key, setting) in snapshot.settings where !setting.meta.deleted { settings[key] = setting.value }

        return ResolvedState(
            topics: snapshot.topics.filter { !$0.meta.deleted },
            tasks: tasks,
            sessions: sessions,
            settings: settings,
            goals: snapshot.goals.filter { !$0.meta.deleted }.sorted { $0.day < $1.day },
            unlockedIcons: Set(snapshot.unlockedIcons))
    }
}
