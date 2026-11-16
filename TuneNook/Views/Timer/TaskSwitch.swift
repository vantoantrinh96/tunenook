import SwiftUI

/// A task change that needs the user's OK because it resets a focus session in progress.
struct TaskSwitch: Identifiable {
    let id = UUID()
    let from: TodoTask
    let to: TodoTask
    let remaining: TimeInterval
}

extension TimerEngine {
    /// Switches straight away when nothing is at stake; otherwise returns the switch to confirm.
    /// - Parameter startNow: whether a free switch also starts focus. A confirmed switch always does,
    ///   so the user keeps focusing on the new task.
    func requestSwitch(to task: TodoTask, startNow: Bool) -> TaskSwitch? {
        if isTaskLocked, let current = currentTask, current != task {
            return TaskSwitch(from: current, to: task, remaining: remaining)
        }
        if startNow {
            startFocus(on: task)
        } else {
            selectTask(task)
        }
        return nil
    }

    /// Stops the current session without counting it and starts a fresh one on the new task.
    func confirm(_ change: TaskSwitch) {
        startFocus(on: change.to)
    }
}

extension View {
    /// Warns that switching tasks resets the timer, and switches if the user agrees.
    func taskSwitchConfirmation(
        _ pending: Binding<TaskSwitch?>,
        engine: TimerEngine,
        onConfirm: @escaping () -> Void = {}
    ) -> some View {
        alert(
            "Switch task and reset the timer?",
            isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
            presenting: pending.wrappedValue
        ) { change in
            Button("Reset & Start", role: .destructive) {
                engine.confirm(change)
                onConfirm()
            }
            Button("Keep Current Task", role: .cancel) {}
        } message: { change in
            Text(message(for: change))
        }
    }
}

private func message(for change: TaskSwitch) -> String {
    let next = "The timer restarts with a new focus session on “\(change.to.title)”."
    return """
    A focus session on “\(change.from.title)” is in progress (\(change.remaining.clockString) left). \
    Switching tasks resets the timer, and this session won't count toward the task or your daily goal. \(next)
    """
}
