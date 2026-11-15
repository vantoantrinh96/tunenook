import SwiftData
import SwiftUI

struct StatsView: View {
    @Environment(GoalStore.self) private var goalStore
    @Query(filter: FocusSession.completedFocus) private var sessions: [FocusSession]
    @Query(sort: \Topic.createdAt) private var topics: [Topic]

    var body: some View {
        ScrollView {
            StatsContent(progress: FocusProgress(sessions: sessions, goalStore: goalStore), topics: topics)
        }
        .navigationTitle("Progress")
        .navigationSubtitle(goalSubtitle)
    }

    private var goalSubtitle: String {
        let goal = goalStore.current
        return "Daily goal: \(goal.target) \(goal.unit)"
    }
}

struct StatsContent: View {
    let progress: FocusProgress
    let topics: [Topic]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            tiles(progress)
            card("Focus history") {
                // Show as many weeks as the window has room for.
                ViewThatFits(in: .horizontal) {
                    FocusHeatmap(progress: progress, weeks: 52)
                    FocusHeatmap(progress: progress, weeks: 39)
                    FocusHeatmap(progress: progress, weeks: 26)
                    FocusHeatmap(progress: progress, weeks: 13)
                }
            }
            deadlines(progress)
            card("Menu bar icons") {
                IconCollectionView()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Tiles

    private func tiles(_ progress: FocusProgress) -> some View {
        let goal = progress.todayGoal
        let total = progress.todayTotal
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            StatTile(title: "Today") {
                HStack(spacing: 10) {
                    GoalRing(progress: goal.progress(total), lineWidth: 5)
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(goal.achieved(total))")
                            .font(.title2.weight(.semibold).monospacedDigit())
                        Text("of \(goal.target) \(goal.unit)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            StatTile(title: "Current streak") {
                VStack(alignment: .leading, spacing: 2) {
                    Label("\(progress.streak.current) days", systemImage: "flame.fill")
                        .font(.title2.weight(.semibold).monospacedDigit())
                    Text(progress.todayMet ? "Today counted" : "Meet today's goal to extend")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            StatTile(title: "Best streak") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(progress.streak.longest) days")
                        .font(.title2.weight(.semibold).monospacedDigit())
                    Text("\(progress.streak.metDays.count) goal days total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            StatTile(title: "Streak freezes") {
                VStack(alignment: .leading, spacing: 2) {
                    Label("\(progress.streak.freezesAvailable)", systemImage: "snowflake")
                        .font(.title2.weight(.semibold).monospacedDigit())
                    Text("Earn 1 per \(FocusStats.freezeEvery)-day streak")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            StatTile(title: "Last 7 days") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.lastSevenDays.hoursMinutes)
                        .font(.title2.weight(.semibold).monospacedDigit())
                    Text("focused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Deadlines

    @ViewBuilder
    private func deadlines(_ progress: FocusProgress) -> some View {
        let dated = topics
            .filter { $0.deadline != nil && !$0.openTasks.isEmpty }
            .sorted { $0.deadline! < $1.deadline! }
        if !dated.isEmpty {
            card("Deadlines") {
                VStack(spacing: 10) {
                    ForEach(dated) { topic in
                        DeadlineRow(topic: topic, calendar: progress.calendar, today: progress.today)
                        if topic != dated.last { Divider() }
                    }
                }
            }
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct StatTile<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DeadlineRow: View {
    let topic: Topic
    let calendar: FocusCalendar
    let today: Date

    var body: some View {
        let deadline = topic.deadline ?? today
        let remaining = topic.openTasks.reduce(0) { $0 + max(0, $1.estimatedSessions - $1.actualSessions) }
        let daysLeft = calendar.daysBetween(today, deadline) + 1
        HStack {
            Circle()
                .fill(Color(hex: topic.colorHex))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.name)
                Text("Due \(deadline.formatted(date: .abbreviated, time: .omitted)) · \(remaining) ♪ left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if daysLeft <= 0 {
                Label("Overdue", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            } else {
                let perDay = Int((Double(remaining) / Double(daysLeft)).rounded(.up))
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(perDay) ♪/day")
                        .font(.callout.monospacedDigit())
                    Text(daysLeft == 1 ? "1 day left" : "\(daysLeft) days left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
