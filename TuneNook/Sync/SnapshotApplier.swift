import Foundation
import SwiftData

/// Writes the state merged from every Mac into this Mac's store and settings.
///
/// Properties are only assigned when they differ, so applying an unchanged
/// state is a no-op, and a later `SnapshotCapture` against the same merged
/// snapshot sees no local edits. A running focus session is never stopped:
/// if its task is deleted elsewhere it keeps running without one.
@MainActor
struct SnapshotApplier {
    let context: ModelContext
    let defaults: UserDefaults
    let goalStore: GoalStore
    let rewards: RewardStore
    let engine: TimerEngine
    let radioIsStopped: () -> Bool
    let setRadioStation: (String) -> Void
    let notifyTaskDeleted: (_ taskTitle: String) -> Void

    func apply(_ state: ResolvedState) throws {
        try applyRecords(state)
        applySettings(state)
        applyGoals(state.goals)
    }

    // MARK: - Records

    private func applyRecords(_ state: ResolvedState) throws {
        var topics = index(try context.fetch(FetchDescriptor<Topic>()), by: \.syncID)
        var tasks = index(try context.fetch(FetchDescriptor<TodoTask>()), by: \.syncID)
        let sessions = index(try context.fetch(FetchDescriptor<FocusSession>()), by: \.syncID)

        for record in state.topics {
            let topic = topics[record.id] ?? insert(Topic(name: record.name, createdAt: record.createdAt)) {
                $0.syncID = record.id
            }
            topics[record.id] = topic
            update(topic, \.name, record.name)
            update(topic, \.colorHex, record.colorHex)
            updateDate(topic, \.createdAt, record.createdAt)
        }

        for record in state.tasks {
            let task = tasks[record.id] ?? insert(TodoTask(title: record.title, createdAt: record.createdAt)) {
                $0.syncID = record.id
            }
            tasks[record.id] = task
            update(task, \.title, record.title)
            update(task, \.estimatedSessions, record.estimatedSessions)
            update(task, \.isDone, record.isDone)
            updateDate(task, \.createdAt, record.createdAt)
            updateDate(task, \.completedAt, record.completedAt)
            updateDate(task, \.deadline, record.deadline)
            let topic = record.topicID.flatMap { topics[$0] }
            if task.topic?.syncID != topic?.syncID { task.topic = topic }
        }

        for record in state.sessions {
            let session = sessions[record.id] ?? insert(FocusSession(
                kind: SessionKind(rawValue: record.kind) ?? .focus, startedAt: record.startedAt,
                endedAt: record.endedAt, activeSeconds: record.activeSeconds,
                completed: record.completed, task: nil)) {
                $0.syncID = record.id
            }
            update(session, \.kindRaw, record.kind)
            updateDate(session, \.startedAt, record.startedAt)
            updateDate(session, \.endedAt, record.endedAt)
            update(session, \.activeSeconds, record.activeSeconds)
            update(session, \.completed, record.completed)
            let task = record.taskID.flatMap { tasks[$0] }
            if session.task?.syncID != task?.syncID { session.task = task }
        }

        // Children first, so a moved task never goes down with its old topic.
        let liveSessions = Set(state.sessions.map(\.id))
        for (id, session) in sessions where !liveSessions.contains(id) { context.delete(session) }

        let liveTasks = Set(state.tasks.map(\.id))
        for (id, task) in tasks where !liveTasks.contains(id) {
            if engine.currentTask === task {
                engine.currentTask = nil
                if engine.isActive { notifyTaskDeleted(task.title) }
            }
            context.delete(task)
        }

        let liveTopics = Set(state.topics.map(\.id))
        for (id, topic) in topics where !liveTopics.contains(id) { context.delete(topic) }

        if context.hasChanges { try context.save() }
    }

    /// The first row per sync ID; duplicates are left alone.
    private func index<M>(_ models: [M], by key: KeyPath<M, UUID>) -> [UUID: M] {
        Dictionary(models.map { ($0[keyPath: key], $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func insert<M: PersistentModel>(_ model: M, configure: (M) -> Void) -> M {
        configure(model)
        context.insert(model)
        return model
    }

    private func update<M, V: Equatable>(_ model: M, _ key: ReferenceWritableKeyPath<M, V>, _ value: V) {
        if model[keyPath: key] != value { model[keyPath: key] = value }
    }

    /// Snapshots keep whole milliseconds; a local date that rounds to the
    /// record's is left as it is.
    private func updateDate<M>(_ model: M, _ key: ReferenceWritableKeyPath<M, Date>, _ value: Date) {
        if model[keyPath: key].syncMillis != value { model[keyPath: key] = value }
    }

    private func updateDate<M>(_ model: M, _ key: ReferenceWritableKeyPath<M, Date?>, _ value: Date?) {
        if model[keyPath: key]?.syncMillis != value { model[keyPath: key] = value }
    }

    // MARK: - Settings

    private func applySettings(_ state: ResolvedState) {
        rewards.mergeUnlocked(state.unlockedIcons)

        for setting in SyncedSetting.all {
            guard let value = state.settings[setting.key], setting.accepts(value) else { continue }
            switch setting.key {
            case "goals.dayStartHour":
                if case .int(let hour) = value, goalStore.dayStartHour != hour { goalStore.dayStartHour = hour }
            case "rewards.menuBarIcon":
                if case .string(let id) = value, rewards.selectedIconID != id,
                   let icon = MenuBarIcon.with(id: id), rewards.isUnlocked(icon) {
                    rewards.select(icon)
                }
            case "radio.selectedStationID":
                // Switching stations would cut off what is playing; a later pass retries.
                if case .string(let id) = value, setting.read(from: defaults) != value, radioIsStopped() {
                    setRadioStation(id)
                }
            default:
                if setting.read(from: defaults) != value { setting.write(value, to: defaults) }
            }
        }
    }

    // MARK: - Goals

    private func applyGoals(_ goals: [SyncGoal]) {
        let entries = goals.compactMap { goal -> GoalHistory.Entry? in
            guard let kind = DailyGoal.Kind(rawValue: goal.kind) else { return nil }
            return GoalHistory.Entry(effectiveFrom: goal.day, goal: DailyGoal(kind: kind, target: goal.target))
        }
        let merged = GoalHistory(entries: entries)
        let local = GoalHistory(entries: goalStore.history.entries.map {
            GoalHistory.Entry(effectiveFrom: $0.effectiveFrom.syncMillis, goal: $0.goal)
        })
        if merged != local { goalStore.replaceHistory(merged) }
    }
}

private extension SyncedSetting {
    /// Whether `value` has the type this setting stores; `.null` resets it.
    func accepts(_ value: SyncValue) -> Bool {
        switch (defaultValue, value) {
        case (_, .null), (.int, .int), (.bool, .bool), (.string, .string), (.null, .string): true
        default: false
        }
    }
}
