import Foundation
import SwiftData

/// Rows saved before v0.9 get their `syncID` from the property default, which SwiftData may
/// apply identically to every migrated row. Give every duplicate a fresh ID, keeping the oldest.
enum SyncIDBackfill {
    /// Returns how many rows received a new ID.
    @MainActor
    static func run(in context: ModelContext) throws -> Int {
        var changed = 0
        changed += dedupe(try context.fetch(FetchDescriptor<Topic>(sortBy: [SortDescriptor(\.createdAt)])),
                          id: \.syncID) { $0.syncID = UUID() }
        changed += dedupe(try context.fetch(FetchDescriptor<TodoTask>(sortBy: [SortDescriptor(\.createdAt)])),
                          id: \.syncID) { $0.syncID = UUID() }
        changed += dedupe(try context.fetch(FetchDescriptor<FocusSession>(sortBy: [SortDescriptor(\.startedAt)])),
                          id: \.syncID) { $0.syncID = UUID() }
        if changed > 0 { try context.save() }
        return changed
    }

    private static func dedupe<T>(_ rows: [T], id: KeyPath<T, UUID>, reassign: (T) -> Void) -> Int {
        var seen = Set<UUID>()
        var changed = 0
        for row in rows where !seen.insert(row[keyPath: id]).inserted {
            reassign(row)
            changed += 1
        }
        return changed
    }
}
