import SwiftUI

/// A task change that needs the user's OK because it resets a focus session in progress.
struct TaskSwitch: Identifiable {
    let id = UUID()
    let from: TodoTask
    let to: TodoTask
    let remaining: TimeInterval
    /// Start a new focus session right away instead of leaving the timer reset.
    let startNow: Bool
}

extension TimerEngine {
    /// Switches straight away when nothing is at stake; otherwise returns the switch to confirm.
    func requestSwitch(to task: TodoTask, startNow: Bool) -> TaskSwitch? {
        if isTaskLocked, let current = currentTask, current != task {
            return TaskSwitch(from: current, to: task, remaining: remaining, startNow: startNow)
        }
        perform(task: task, startNow: startNow)
        return nil
    }

    func confirm(_ change: TaskSwitch) {
        perform(task: change.to, startNow: change.startNow)
    }

    private func perform(task: TodoTask, startNow: Bool) {
        if startNow {
            startFocus(on: task)
        } else {
            selectTask(task)
        }
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
            Button(change.startNow ? "Reset & Start" : "Reset Timer", role: .destructive) {
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
    let next = change.startNow
        ? "A new focus session will start on “\(change.to.title)”."
        : "The timer goes back to the start, ready for “\(change.to.title)”."
    return """
    A focus session on “\(change.from.title)” is in progress (\(change.remaining.clockString) left). \
    Switching tasks resets the timer, and this session won't count toward the task or your daily goal. \(next)
    """
}
