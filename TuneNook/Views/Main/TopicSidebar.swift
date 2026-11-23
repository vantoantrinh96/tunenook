import SwiftData
import SwiftUI

struct TopicSidebar: View {
    @Binding var selection: SidebarItem?

    @Environment(\.modelContext) private var context
    @Environment(TimerEngine.self) private var engine
    @Query(sort: \Topic.createdAt) private var topics: [Topic]

    @State private var editing: TopicDraft?
    @State private var pendingDelete: Topic?
    @State private var merging: Topic?
    @State private var mergeError: String?

    var body: some View {
        List(selection: $selection) {
            Label("Progress", systemImage: "chart.bar.xaxis")
                .tag(SidebarItem.progress)
            Section("Topics") {
                if topics.isEmpty {
                    Button("New Topic…") { editing = TopicDraft() }
                        .buttonStyle(.link)
                }
                ForEach(topics) { topic in
                    TopicRow(topic: topic)
                        .tag(SidebarItem.topic(topic))
                        .contextMenu {
                            Button("Edit…") { editing = TopicDraft(topic: topic) }
                            if topics.count > 1 {
                                Button("Merge into…") { merging = topic }
                            }
                            Button("Delete…", role: .destructive) { pendingDelete = topic }
                        }
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
            TopicEditor(draft: draft) { saved in selection = .topic(saved) }
        }
        .sheet(item: $merging) { source in
            MergeTopicSheet(source: source) { target in merge(source, into: target) }
        }
        .alert("Couldn't merge the topics", isPresented: Binding(
            get: { mergeError != nil }, set: { if !$0 { mergeError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(mergeError ?? "")
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
            Text("Past session history is kept.")
        }
    }

    /// Closes the sheet and moves the selection off the source first, so nothing
    /// on screen reads the source once the merge has deleted it.
    private func merge(_ source: Topic, into target: Topic) {
        merging = nil
        let wasSelected = selection == .topic(source)
        if wasSelected { selection = .topic(target) }
        do {
            try TopicMerger.merge(source, into: target, context: context, defaults: .standard)
        } catch {
            if wasSelected { selection = .topic(source) }
            mergeError = error.localizedDescription
        }
    }

    private func delete(_ topic: Topic) {
        if let current = engine.currentTask, current.topic == topic {
            engine.abandon()
            engine.currentTask = nil
        }
        if selection == .topic(topic) { selection = .progress }
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
