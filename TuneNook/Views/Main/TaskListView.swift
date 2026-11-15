import SwiftData
import SwiftUI

struct TaskListView: View {
    let topic: Topic

    @Environment(\.modelContext) private var context
    @Environment(TimerEngine.self) private var engine
    @State private var editing: TodoTask?

    var body: some View {
        VStack(spacing: 0) {
            NewTaskBar(topic: topic)
            Divider()
            List {
                Section("To do") {
                    if topic.openTasks.isEmpty {
                        Text("Nothing left. Add a task above.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(topic.openTasks) { task in
                        row(task)
                    }
                }
                if !topic.doneTasks.isEmpty {
                    Section("Done") {
                        ForEach(topic.doneTasks) { task in
                            row(task)
                        }
                    }
                }
            }
        }
        .navigationTitle(topic.name)
        .navigationSubtitle(subtitle)
        .sheet(item: $editing) { task in
            TaskEditor(task: task)
        }
    }

    private func row(_ task: TodoTask) -> some View {
        TaskRow(task: task)
            .contextMenu {
                Button("Edit…") { editing = task }
                Button("Delete", role: .destructive) { delete(task) }
            }
    }

    private var subtitle: String {
        let open = topic.openTasks
        let remaining = open.reduce(0) { $0 + max(0, $1.estimatedSessions - $1.actualSessions) }
        var parts = ["\(open.count) open", "\(remaining) ♪ left"]
        if let deadline = topic.deadline {
            parts.append("due \(deadline.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    private func delete(_ task: TodoTask) {
        if engine.currentTask == task {
            engine.abandon()
            engine.currentTask = nil
        }
        context.delete(task)
        try? context.save()
    }
}

private struct NewTaskBar: View {
    let topic: Topic

    @Environment(\.modelContext) private var context
    @State private var title = ""
    @State private var estimate = 1
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            TextField("Add a task…", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(add)
            Stepper(value: $estimate, in: 1...12) {
                Text("♪ \(estimate)")
                    .monospacedDigit()
            }
            .fixedSize()
            .help("Estimated sessions")
            Button("Add", action: add)
                .disabled(trimmed.isEmpty)
        }
        .padding(12)
    }

    private var trimmed: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        guard !trimmed.isEmpty else { return }
        let task = TodoTask(title: trimmed, estimatedSessions: estimate, topic: topic)
        context.insert(task)
        try? context.save()
        title = ""
        estimate = 1
        focused = true
    }
}

private struct TaskRow: View {
    let task: TodoTask

    @Environment(TimerEngine.self) private var engine
    @Environment(\.dismissWindow) private var dismissWindow

    private var isCurrent: Bool {
        engine.currentTask == task && engine.isActive && engine.phase == .focus
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation { task.setDone(!task.isDone) }
            } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isDone ? Color.green : Color.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            Text(task.title)
                .strikethrough(task.isDone)
                .foregroundStyle(task.isDone ? .secondary : .primary)

            if isCurrent {
                Label(engine.remaining.clockString, systemImage: "timer")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(SessionKind.focus.tint)
            }

            Spacer()

            SessionBadge(actual: task.actualSessions, estimated: task.estimatedSessions)

            if !task.isDone {
                Button {
                    engine.startFocus(on: task)
                    dismissWindow(id: WindowID.main)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .disabled(isCurrent)
                .help("Start a focus session on this task")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct TaskEditor: View {
    @Bindable var task: TodoTask
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var estimate = 1

    var body: some View {
        Form {
            TextField("Title", text: $title)
            Stepper(value: $estimate, in: 1...12) {
                LabeledContent("Estimate", value: "♪ \(estimate)")
            }
            LabeledContent("Done so far", value: "♪ \(task.actualSessions)")
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .onAppear {
            title = task.title
            estimate = task.estimatedSessions
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    task.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    task.estimatedSessions = estimate
                    dismiss()
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
