import SwiftData
import SwiftUI

struct MainView: View {
    @State private var selectedTopic: Topic?

    var body: some View {
        NavigationSplitView {
            TopicSidebar(selection: $selectedTopic)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if let topic = selectedTopic {
                TaskListView(topic: topic)
                    .id(topic.persistentModelID)
            } else {
                ContentUnavailableView(
                    "Pick a topic",
                    systemImage: "tray",
                    description: Text("Group your to-dos into topics, then start a focus session on any task.")
                )
            }
        }
        .frame(minWidth: 680, minHeight: 420)
        .onAppear(perform: activateApp)
    }
}
