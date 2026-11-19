import SwiftData
import SwiftUI

/// Picks the topic that a topic is folded into. The merge itself is left to
/// `onChoose`, and nothing here reads the source after the sheet opens: once it
/// is merged it is deleted, and a redraw must not touch it.
struct MergeTopicSheet: View {
    var onChoose: (Topic) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Topic.createdAt) private var topics: [Topic]

    private let sourceID: PersistentIdentifier
    @State private var sourceName: String
    @State private var taskCount: Int
    @State private var chosen: Topic?

    init(source: Topic, onChoose: @escaping (Topic) -> Void) {
        self.onChoose = onChoose
        sourceID = source.persistentModelID
        _sourceName = State(initialValue: source.name)
        _taskCount = State(initialValue: source.tasks.count)
    }

    private var others: [Topic] { topics.filter { $0.persistentModelID != sourceID } }

    static func summary(taskCount: Int, sourceName: String) -> String {
        let tasks = taskCount == 1 ? "1 task" : "\(taskCount) tasks"
        return "Moves \(tasks) and their history into the topic you pick, then deletes “\(sourceName)”."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge “\(sourceName)” into…")
                .font(.headline)
            List(others, selection: $chosen) { topic in
                HStack {
                    Circle()
                        .fill(Color(hex: topic.colorHex))
                        .frame(width: 10, height: 10)
                    Text(topic.name)
                        .lineLimit(1)
                }
                .tag(topic)
            }
            .frame(height: 200)
            Text(Self.summary(taskCount: taskCount, sourceName: sourceName))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Merge") {
                    guard let target = chosen else { return }
                    dismiss()
                    onChoose(target)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
