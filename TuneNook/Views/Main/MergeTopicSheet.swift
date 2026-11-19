import SwiftData
import SwiftUI

/// Picks the topic that `source` is folded into.
struct MergeTopicSheet: View {
    let source: Topic
    var onMerged: (Topic) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Topic.createdAt) private var topics: [Topic]

    @State private var chosen: Topic?
    @State private var failure: String?

    private var others: [Topic] { topics.filter { $0 !== source } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge “\(source.name)” into…")
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
            Text("Moves \(source.tasks.count) tasks and their history into the topic you pick, then deletes “\(source.name)”.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Merge", action: merge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func merge() {
        guard let target = chosen else { return }
        do {
            try TopicMerger.merge(source, into: target, context: context, defaults: .standard)
            onMerged(target)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
