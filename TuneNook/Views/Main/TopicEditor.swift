import SwiftData
import SwiftUI

/// Editable copy of a topic, so Cancel leaves the stored topic untouched.
struct TopicDraft: Identifiable {
    let id = UUID()
    var topic: Topic?
    var name: String
    var colorHex: String

    init(topic: Topic? = nil) {
        self.topic = topic
        self.name = topic?.name ?? ""
        self.colorHex = topic?.colorHex ?? Topic.palette.randomElement() ?? Topic.palette[0]
    }
}

struct TopicEditor: View {
    @State var draft: TopicDraft
    var onSave: (Topic) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Name", text: $draft.name, prompt: Text("e.g. Reading, Side project"))

            LabeledContent("Color") {
                HStack(spacing: 8) {
                    ForEach(Topic.palette, id: \.self) { hex in
                        Button {
                            draft.colorHex = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 18, height: 18)
                                .overlay {
                                    if draft.colorHex == hex {
                                        Circle().strokeBorder(.primary, lineWidth: 2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(draft.topic == nil ? "Create" : "Save", action: save)
                    .disabled(trimmedName.isEmpty)
            }
        }
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        let topic = draft.topic ?? Topic(name: trimmedName)
        topic.name = trimmedName
        topic.colorHex = draft.colorHex
        if draft.topic == nil { context.insert(topic) }
        try? context.save()
        onSave(topic)
        dismiss()
    }
}
