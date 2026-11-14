import SwiftData
import SwiftUI

struct TopicSidebar: View {
    @Binding var selection: Topic?

    @Environment(\.modelContext) private var context
    @Environment(TimerEngine.self) private var engine
    @Query(sort: \Topic.createdAt) private var topics: [Topic]

    @State private var editing: TopicDraft?
    @State private var pendingDelete: Topic?

    var body: some View {
        List(selection: $selection) {
            Section("Topics") {
                ForEach(topics) { topic in
                    TopicRow(topic: topic)
                        .tag(topic)
                        .contextMenu {
                            Button("Edit…") { editing = TopicDraft(topic: topic) }
                            Button("Delete…", role: .destructive) { pendingDelete = topic }
                        }
                }
            }
        }
        .overlay {
            if topics.isEmpty {
                ContentUnavailableView {
                    Label("No topics yet", systemImage: "square.stack")
                } actions: {
                    Button("New Topic") { editing = TopicDraft() }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    editing = TopicDraft()
                } label: {
                    Label("New Topic", systemImage: "plus")
                }
                .help("New topic")
            }
        }
        .sheet(item: $editing) { draft in
            TopicEditor(draft: draft) { saved in selection = saved }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")” and all its tasks?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let topic = pendingDelete { delete(topic) }
            }
        } message: {
            Text("Past pomodoro history is kept.")
        }
        .onAppear {
            if selection == nil { selection = topics.first }
        }
    }

    private func delete(_ topic: Topic) {
        if let current = engine.currentTask, current.topic == topic {
            engine.abandon()
            engine.currentTask = nil
        }
        if selection == topic { selection = nil }
        context.delete(topic)
        try? context.save()
        pendingDelete = nil
    }
}

private struct TopicRow: View {
    let topic: Topic

    var body: some View {
        HStack {
            Circle()
                .fill(Color(hex: topic.colorHex))
                .frame(width: 10, height: 10)
            Text(topic.name)
                .lineLimit(1)
            Spacer()
            let open = topic.openTasks.count
            if open > 0 {
                Text("\(open)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
