import SwiftData
import SwiftUI

enum SidebarItem: Hashable {
    case progress
    case topic(Topic)

    /// What to show given the topics that still exist: a topic deleted elsewhere (by an agent,
    /// say) falls back to Progress instead of leaving its deleted model on screen.
    func keeping(_ topics: [Topic]) -> SidebarItem {
        guard case .topic(let topic) = self,
              !topics.contains(where: { $0.persistentModelID == topic.persistentModelID })
        else { return self }
        return .progress
    }
}

struct MainView: View {
    @State private var selection: SidebarItem? = .progress
    @Query private var topics: [Topic]

    var body: some View {
        NavigationSplitView {
            TopicSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            switch selection?.keeping(topics) {
            case .progress:
                StatsView()
            case .topic(let topic):
                TaskListView(topic: topic)
                    .id(topic.persistentModelID)
            case nil:
                ContentUnavailableView(
                    "Pick a topic",
                    systemImage: "tray",
                    description: Text("Group your to-dos into topics, then start a focus session on any task.")
                )
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onChange(of: topics) {
            selection = selection?.keeping(topics)
        }
        .onAppear(perform: activateApp)
    }
}
