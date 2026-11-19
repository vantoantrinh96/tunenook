import Foundation
import SwiftData

/// Folds one topic into another and remembers the merge so the sync engine can
/// tombstone the source with `mergedInto`, which makes tasks other Macs later
/// add to the source follow it into the target.
@MainActor
enum TopicMerger {
    enum MergeError: Error { case sameTopic }

    static let defaultsKey = "sync.mergedTopics"

    /// Moves every task of `source` (sessions stay linked to their tasks) to
    /// `target`, deletes `source` and records the merge. Never touches the timer.
    static func merge(_ source: Topic, into target: Topic, context: ModelContext, defaults: UserDefaults) throws {
        guard source !== target, source.syncID != target.syncID else { throw MergeError.sameTopic }
        let sourceID = source.syncID
        for task in Array(source.tasks) { task.topic = target }
        context.delete(source)
        try context.save()
        var merges = pending(in: defaults)
        merges[sourceID] = target.syncID
        // Merges that pointed at the source now lead to the target.
        for (key, value) in merges where value == sourceID { merges[key] = target.syncID }
        store(merges, in: defaults)
    }

    static func pending(in defaults: UserDefaults) -> [UUID: UUID] {
        guard let raw = defaults.dictionary(forKey: defaultsKey) as? [String: String] else { return [:] }
        var result: [UUID: UUID] = [:]
        for (key, value) in raw {
            if let source = UUID(uuidString: key), let target = UUID(uuidString: value) { result[source] = target }
        }
        return result
    }

    static func clear(_ sourceIDs: [UUID], in defaults: UserDefaults) {
        guard !sourceIDs.isEmpty else { return }
        var merges = pending(in: defaults)
        for id in sourceIDs { merges[id] = nil }
        store(merges, in: defaults)
    }

    private static func store(_ merges: [UUID: UUID], in defaults: UserDefaults) {
        if merges.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(Dictionary(uniqueKeysWithValues: merges.map { ($0.key.uuidString, $0.value.uuidString) }),
                         forKey: defaultsKey)
        }
    }
}
