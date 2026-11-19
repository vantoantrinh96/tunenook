import Foundation
import SwiftData

/// Builds this Mac's `DeviceSnapshot` from local state, deciding which records
/// changed by diffing against the baseline (the merged snapshot saved after
/// the previous sync pass).
@MainActor
struct SnapshotCapture {
    let context: ModelContext
    let defaults: UserDefaults
    let goalStore: GoalStore
    let rewards: RewardStore
    /// deviceID / deviceName / appVersion; its records are ignored.
    let identity: DeviceSnapshot
    /// Topic merges done locally: source syncID → target syncID.
    let mergedTopics: [UUID: UUID]

    func capture(baseline: DeviceSnapshot?, now rawNow: Date) throws -> DeviceSnapshot {
        let now = rawNow.syncMillis
        let seen = baseline.map(SyncMerge.resolve)
        let stamp = SyncMeta(modifiedAt: baseline == nil ? .distantPast : now,
                             modifiedBy: identity.deviceID, deleted: false)
        let tombstone = SyncMeta(modifiedAt: now, modifiedBy: identity.deviceID, deleted: true)

        var snapshot = identity
        snapshot.formatVersion = DeviceSnapshot.currentFormat
        snapshot.exportedAt = now

        snapshot.topics = diff(
            local: try context.fetch(FetchDescriptor<Topic>()).map(record),
            raw: baseline?.topics ?? [], seen: seen?.topics ?? [],
            key: \.id, stamp: stamp,
            tombstone: { topic in
                var t = topic
                t.meta = tombstone
                t.mergedInto = mergedTopics[topic.id]
                return t
            })

        snapshot.tasks = diff(
            local: try context.fetch(FetchDescriptor<TodoTask>()).map(record),
            raw: baseline?.tasks ?? [], seen: seen?.tasks ?? [],
            key: \.id, stamp: stamp,
            tombstone: { var t = $0; t.meta = tombstone; return t })

        snapshot.sessions = diff(
            local: try context.fetch(FetchDescriptor<FocusSession>()).map(record),
            raw: baseline?.sessions ?? [], seen: seen?.sessions ?? [],
            key: \.id, stamp: stamp,
            tombstone: { var s = $0; s.meta = tombstone; return s })

        snapshot.goals = diff(
            local: goalStore.history.entries.map(record),
            raw: baseline?.goals ?? [], seen: seen?.goals ?? [],
            key: \.day, stamp: stamp,
            tombstone: { var g = $0; g.meta = tombstone; return g })

        snapshot.settings = captureSettings(baseline: baseline, seen: seen, stamp: stamp)

        snapshot.unlockedIcons = rewards.unlockedIDs.union(baseline?.unlockedIcons ?? []).sorted()
        return snapshot
    }

    // MARK: - Diffing

    /// Every local record keeps the baseline's raw record when its content is
    /// unchanged against the resolved or raw baseline, and is stamped otherwise.
    /// Records live in the resolved baseline but gone locally become
    /// tombstones; every other baseline record is carried unchanged.
    private func diff<R: SyncRecord, K: Hashable>(
        local: [R], raw: [R], seen: [R], key: KeyPath<R, K>, stamp: SyncMeta,
        tombstone: (R) -> R
    ) -> [R] {
        let rawByKey = Dictionary(raw.map { ($0[keyPath: key], $0) }, uniquingKeysWith: { a, _ in a })
        let seenByKey = Dictionary(seen.map { ($0[keyPath: key], $0) }, uniquingKeysWith: { a, _ in a })

        var result: [R] = []
        var localKeys: Set<K> = []
        for var record in local {
            let k = record[keyPath: key]
            guard localKeys.insert(k).inserted else { continue }
            // A row is unchanged if it matches either the resolved baseline
            // or its raw live form: the resolver hides some rows (a task
            // without a topic) and rewrites others (that task's sessions
            // lose their taskID) that the local store still holds as raw.
            let previous = [seenByKey[k], rawByKey[k].flatMap { $0.meta.deleted ? nil : $0 }].compactMap { $0 }
            if previous.contains(where: record.sameContent), let original = rawByKey[k] {
                result.append(original)
            } else {
                record.meta = stamp
                result.append(record)
            }
        }
        for record in raw where !localKeys.contains(record[keyPath: key]) {
            let k = record[keyPath: key]
            result.append(seenByKey[k] != nil ? tombstone(record) : record)
        }
        return result
    }

    private func captureSettings(baseline: DeviceSnapshot?, seen: ResolvedState?, stamp: SyncMeta) -> [String: SyncSetting] {
        var result = baseline?.settings ?? [:]   // carries keys this version doesn't know
        for setting in SyncedSetting.all {
            let value: SyncValue
            switch setting.key {
            case "goals.dayStartHour": value = .int(goalStore.dayStartHour)
            case "rewards.menuBarIcon": value = .string(rewards.selectedIconID)
            default: value = setting.read(from: defaults)
            }
            if seen?.settings[setting.key] == value, let original = baseline?.settings[setting.key] {
                result[setting.key] = original
            } else {
                result[setting.key] = SyncSetting(value: value, meta: stamp)
            }
        }
        return result
    }

    // MARK: - Records

    private func record(_ topic: Topic) -> SyncTopic {
        SyncTopic(id: topic.syncID, meta: placeholder, name: topic.name, colorHex: topic.colorHex,
                  createdAt: topic.createdAt.syncMillis, deadline: topic.deadline?.syncMillis, mergedInto: nil)
    }

    private func record(_ task: TodoTask) -> SyncTask {
        SyncTask(id: task.syncID, meta: placeholder, title: task.title, estimatedSessions: task.estimatedSessions,
                 isDone: task.isDone, createdAt: task.createdAt.syncMillis,
                 completedAt: task.completedAt?.syncMillis, topicID: task.topic?.syncID)
    }

    private func record(_ session: FocusSession) -> SyncSession {
        SyncSession(id: session.syncID, meta: placeholder, kind: session.kindRaw,
                    startedAt: session.startedAt.syncMillis, endedAt: session.endedAt.syncMillis,
                    activeSeconds: session.activeSeconds, completed: session.completed,
                    taskID: session.task?.syncID)
    }

    private func record(_ entry: GoalHistory.Entry) -> SyncGoal {
        SyncGoal(day: entry.effectiveFrom.syncMillis, meta: placeholder,
                 kind: entry.goal.kind.rawValue, target: entry.goal.target)
    }

    private var placeholder: SyncMeta {
        SyncMeta(modifiedAt: .distantPast, modifiedBy: identity.deviceID, deleted: false)
    }
}

/// The record types `SnapshotCapture` diffs generically.
protocol SyncRecord {
    var meta: SyncMeta { get set }
    func sameContent(as other: Self) -> Bool
}

extension SyncTopic: SyncRecord {}
extension SyncTask: SyncRecord {}
extension SyncSession: SyncRecord {}
extension SyncGoal: SyncRecord {}
