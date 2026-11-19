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
