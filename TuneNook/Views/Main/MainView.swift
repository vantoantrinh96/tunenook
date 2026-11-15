import SwiftData
import SwiftUI

enum SidebarItem: Hashable {
    case progress
    case topic(Topic)
}

struct MainView: View {
    @State private var selection: SidebarItem? = .progress

    var body: some View {
        NavigationSplitView {
            TopicSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            switch selection {
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
        .onAppear(perform: activateApp)
    }
}
