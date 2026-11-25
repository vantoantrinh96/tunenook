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
        .onChange(of: topic.tasks.map(\.persistentModelID)) { _, live in
            // The task was deleted (or moved away) elsewhere, by an agent say: close its editor.
            if let task = editing, !live.contains(task.persistentModelID) { editing = nil }
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
        return "\(open.count) open · \(remaining) ♪ left"
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
    @State private var deadline: Date?
    @State private var pickingDeadline = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            TextField("Add a task…", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(add)
            DeadlineButton(deadline: $deadline, isPresented: $pickingDeadline)
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
        let task = TodoTask(title: trimmed, estimatedSessions: estimate, topic: topic, deadline: deadline)
        context.insert(task)
        try? context.save()
        title = ""
        estimate = 1
        deadline = nil
        focused = true
    }
}

/// Calendar button on the new-task bar: an icon when empty, a "📅 Tomorrow ✕" chip once set.
private struct DeadlineButton: View {
    @Binding var deadline: Date?
    @Binding var isPresented: Bool

    var body: some View {
        HStack(spacing: 2) {
            Button {
                isPresented = true
            } label: {
                if let deadline {
                    Label(DeadlinePreset.shortLabel(for: deadline), systemImage: "calendar")
                } else {
                    Image(systemName: "calendar")
                }
            }
            .help("Deadline")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) { picker }

            if deadline != nil {
                Button {
                    deadline = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove deadline")
            }
        }
        .fixedSize()
    }

    private var picker: some View {
        let today = Calendar.current.startOfDay(for: .now)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                ForEach(DeadlinePreset.allCases, id: \.self) { preset in
                    Button(preset.title) {
                        deadline = preset.date(from: .now)
                        isPresented = false
                    }
                }
            }
            DatePicker(
                "Due",
                selection: Binding(
                    get: { deadline ?? today },
                    set: { deadline = Calendar.current.startOfDay(for: $0) }
                ),
                in: today...,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            if deadline != nil {
                Button("No deadline") {
                    deadline = nil
                    isPresented = false
                }
            }
        }
        .padding(12)
    }
}

private struct TaskRow: View {
    let task: TodoTask

    @Environment(TimerEngine.self) private var engine
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var pendingSwitch: TaskSwitch?

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

            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                if let deadline = task.deadline, !task.isDone {
                    DueLabel(deadline: deadline)
                }
            }

            if isCurrent {
                Label(engine.remaining.clockString, systemImage: "timer")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(SessionKind.focus.tint)
            }

            Spacer()

            SessionBadge(actual: task.actualSessions, estimated: task.estimatedSessions)

            if !task.isDone {
                Button {
                    pendingSwitch = engine.requestSwitch(to: task, startNow: true)
                    if pendingSwitch == nil { dismissWindow(id: WindowID.main) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .disabled(isCurrent)
                .help(engine.isTaskLocked ? "Switch to this task (resets the timer)" : "Start a focus session on this task")
            }
        }
        .padding(.vertical, 2)
        .taskSwitchConfirmation($pendingSwitch, engine: engine) {
            dismissWindow(id: WindowID.main)
        }
    }
}

private struct TaskEditor: View {
    @Bindable var task: TodoTask
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var estimate = 1
    @State private var hasDeadline = false
    @State private var deadline = Date.now

    var body: some View {
        Form {
            TextField("Title", text: $title)
            Stepper(value: $estimate, in: 1...12) {
                LabeledContent("Estimate", value: "♪ \(estimate)")
            }
            LabeledContent("Done so far", value: "♪ \(task.actualSessions)")
            Toggle("Deadline", isOn: $hasDeadline)
            if hasDeadline {
                DatePicker("Due", selection: $deadline, displayedComponents: .date)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .onAppear {
            title = task.title
            estimate = task.estimatedSessions
            hasDeadline = task.deadline != nil
            deadline = task.deadline ?? Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    task.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    task.estimatedSessions = estimate
                    task.deadline = hasDeadline ? deadline : nil
                    dismiss()
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

/// "Due today", "Due tomorrow", "Due Nov 28"; red once the day has passed.
private struct DueLabel: View {
    let deadline: Date

    var body: some View {
        let calendar = Calendar.current
        let overdue = calendar.startOfDay(for: deadline) < calendar.startOfDay(for: .now)
        Label(text(calendar), systemImage: overdue ? "exclamationmark.triangle.fill" : "calendar")
            .font(.caption)
            .foregroundStyle(overdue ? Color.red : Color.secondary)
    }

    private func text(_ calendar: Calendar) -> String {
        if calendar.isDateInToday(deadline) { return "Due today" }
        if calendar.isDateInTomorrow(deadline) { return "Due tomorrow" }
        if calendar.isDateInYesterday(deadline) { return "Overdue · yesterday" }
        let date = deadline.formatted(.dateTime.month(.abbreviated).day())
        return deadline < .now ? "Overdue · \(date)" : "Due \(date)"
    }
}
