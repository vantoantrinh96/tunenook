import SwiftUI

/// GitHub-style grid: one column per week, one cell per focus day.
struct FocusHeatmap: View {
    let progress: FocusProgress
    var weeks = 26

    private let cell: CGFloat = 13
    private let gap: CGFloat = 3

    var body: some View {
        let columns = weekColumns
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: gap) {
                weekdayLabels
                ForEach(Array(columns.enumerated()), id: \.offset) { index, week in
                    VStack(spacing: gap) {
                        Text(monthLabel(for: week, at: index, in: columns))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(width: cell, height: 12, alignment: .leading)
                        ForEach(week, id: \.self) { day in
                            dayCell(day)
                        }
                    }
                }
            }
            legend
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Focus heatmap, last \(weeks) weeks")
    }

    @ViewBuilder
    private func dayCell(_ day: Date) -> some View {
        if day > progress.today {
            Color.clear.frame(width: cell, height: cell)
        } else {
            let total = progress.total(on: day)
            let frozen = progress.streak.frozenDays.contains(day)
            RoundedRectangle(cornerRadius: 3)
                .fill(ProgressPalette.color(forLevel: progress.level(on: day)))
                .frame(width: cell, height: cell)
                .overlay {
                    if frozen {
                        Image(systemName: "snowflake")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(ProgressPalette.accent)
                    }
                    if day == progress.today {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(.primary.opacity(0.6), lineWidth: 1)
                    }
                }
                .help(tooltip(day: day, total: total, frozen: frozen))
                .accessibilityLabel(tooltip(day: day, total: total, frozen: frozen))
        }
    }

    private func tooltip(day: Date, total: DayTotal, frozen: Bool) -> String {
        let date = day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let goal = progress.goals.goal(on: day)
        var parts = [date, "\(total.minutes) min", "\(total.sessions) sessions"]
        if goal.isMet(total) {
            parts.append("goal met")
        } else if frozen {
            parts.append("streak freeze used")
        }
        return parts.joined(separator: " · ")
    }

    private var weekdayLabels: some View {
        let symbols = progress.calendar.calendar.shortWeekdaySymbols
        let first = progress.calendar.calendar.firstWeekday - 1
        return VStack(alignment: .trailing, spacing: gap) {
            Color.clear.frame(width: 24, height: 12)
            ForEach(0..<7, id: \.self) { row in
                // Label every other row, like GitHub, to keep it light.
                Text(row % 2 == 1 ? symbols[(first + row) % 7] : "")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: cell, alignment: .trailing)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: gap) {
            Spacer()
            Text("Less").font(.caption2).foregroundStyle(.secondary)
            ForEach(0...4, id: \.self) { level in
                RoundedRectangle(cornerRadius: 3)
                    .fill(ProgressPalette.color(forLevel: level))
                    .frame(width: cell, height: cell)
            }
            Text("Goal met").font(.caption2).foregroundStyle(.secondary)
            Image(systemName: "snowflake")
                .font(.caption2)
                .foregroundStyle(ProgressPalette.accent)
                .padding(.leading, 8)
            Text("Freeze used").font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Columns of 7 days, ending with the week that contains today.
    private var weekColumns: [[Date]] {
        let calendar = progress.calendar.calendar
        let today = progress.today
        let weekday = calendar.component(.weekday, from: today)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        let lastWeekStart = progress.calendar.adding(days: -offset, to: today)
        return (0..<weeks).reversed().map { back in
            let start = progress.calendar.adding(days: -7 * back, to: lastWeekStart)
            return (0..<7).map { progress.calendar.adding(days: $0, to: start) }
        }
    }

    private func monthLabel(for week: [Date], at index: Int, in columns: [[Date]]) -> String {
        guard let first = week.first else { return "" }
        let calendar = progress.calendar.calendar
        let month = calendar.component(.month, from: first)
        if index > 0, let previous = columns[index - 1].first,
           calendar.component(.month, from: previous) == month {
            return ""
        }
        // Skip a label squeezed into the very first column if the next starts a new month.
        if index == 0, columns.count > 1, let next = columns[1].first,
           calendar.component(.month, from: next) != month {
            return ""
        }
        return first.formatted(.dateTime.month(.abbreviated))
    }
}
