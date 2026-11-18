import AppKit
import Charts
import SwiftData
import SwiftUI

// MARK: Weekly focus

/// Bar chart of focus hours per week. Hovering a bar shows that week's numbers.
struct WeeklyFocusChart: View {
    let weeks: [WeekTotal]
    @State private var selected: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Chart(weeks) { week in
                BarMark(
                    x: .value("Week", week.weekStart, unit: .weekOfYear),
                    y: .value("Hours", week.seconds / 3600),
                    width: .ratio(0.7)
                )
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                .foregroundStyle(ProgressPalette.accent.opacity(isDimmed(week) ? 0.35 : 1))
            }
            .chartXSelection(value: $selected)
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: 2)) {
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let hours = value.as(Double.self) { Text("\(hours, format: .number)h") }
                    }
                }
            }
            .frame(height: 140)
            .accessibilityLabel("Focus hours per week")
        }
    }

    private var hovered: WeekTotal? {
        guard let selected else { return nil }
        return weeks.last { $0.weekStart <= selected }
    }

    private func isDimmed(_ week: WeekTotal) -> Bool {
        hovered.map { $0.weekStart != week.weekStart } ?? false
    }

    private var caption: String {
        if let week = hovered {
            let label = week.weekStart.formatted(.dateTime.month(.abbreviated).day())
            return "Week of \(label): \(week.seconds.hoursMinutes) · \(week.sessions) sessions"
        }
        let total = weeks.reduce(0) { $0 + $1.seconds }
        let average = weeks.isEmpty ? 0 : total / Double(weeks.count)
        return "Last \(weeks.count) weeks: \(total.hoursMinutes) · \(average.hoursMinutes) a week on average"
    }
}

// MARK: Estimate accuracy

enum EstimateRange: String, CaseIterable, Identifiable {
    case month = "30 days"
    case quarter = "90 days"
    case all = "All time"

    var id: Self { self }

    func start(today: Date, calendar: FocusCalendar) -> Date? {
        switch self {
        case .month: calendar.adding(days: -29, to: today)
        case .quarter: calendar.adding(days: -89, to: today)
        case .all: nil
        }
    }
}

/// Compares estimated with actual sessions on finished tasks: overall, per topic, and the biggest misses.
struct EstimateCard: View {
    let tasks: [TodoTask]
    let today: Date
    let calendar: FocusCalendar

    @AppStorage("estimateRange") private var range: EstimateRange = .quarter

    var body: some View {
        let report = EstimateReport(tasks: tasks, since: range.start(today: today, calendar: calendar))
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Estimate accuracy").font(.headline)
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(EstimateRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if let ratio = report.overall.ratio {
                overview(report.overall, ratio: ratio)
                if !report.topics.isEmpty { topics(report) }
                if !report.misses.isEmpty { misses(report) }
            } else {
                Text("Finish a few tasks with the timer running to see how your estimates hold up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func overview(_ summary: EstimateSummary, ratio: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(ratio.timesString)
                    .font(.largeTitle.weight(.semibold).monospacedDigit())
                VStack(alignment: .leading, spacing: 2) {
                    Text(EstimateStats.verdict(for: ratio))
                    Text("\(summary.tasks) tasks · \(summary.estimated) ♪ estimated · \(summary.actual) ♪ actual")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            OutcomeBar(summary: summary)
        }
    }

    private func topics(_ report: EstimateReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By topic").font(.subheadline.weight(.medium))
            ForEach(report.topics, id: \.topic.persistentModelID) { row in
                HStack {
                    Circle()
                        .fill(Color(hex: row.topic.colorHex))
                        .frame(width: 10, height: 10)
                    Text(row.topic.name).lineLimit(1)
                    Spacer()
                    Text("\(row.summary.tasks) tasks · \(row.summary.estimated) → \(row.summary.actual) ♪")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text((row.summary.ratio ?? 1).timesString)
                        .font(.callout.monospacedDigit())
                        .frame(minWidth: 40, alignment: .trailing)
                }
            }
        }
    }

    private func misses(_ report: EstimateReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Biggest misses").font(.subheadline.weight(.medium))
            ForEach(report.misses, id: \.persistentModelID) { task in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.title).lineLimit(1)
                        if let topic = task.topic {
                            Text(topic.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    SessionBadge(actual: task.actualSessions, estimated: task.estimatedSessions)
                }
            }
        }
    }
}

/// Under / on / over as one segmented bar, with a legend that carries the counts.
private struct OutcomeBar: View {
    let summary: EstimateSummary

    var body: some View {
        let outcomes = EstimateOutcome.allCases.filter { summary.count($0) > 0 }
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let gaps = CGFloat(max(outcomes.count - 1, 0)) * 2
                HStack(spacing: 2) {
                    ForEach(outcomes, id: \.self) { outcome in
                        Rectangle()
                            .fill(outcome.color)
                            .frame(width: (proxy.size.width - gaps) * share(outcome))
                            .help("\(outcome.title): \(summary.count(outcome)) tasks")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 10)
            HStack(spacing: 14) {
                ForEach(EstimateOutcome.allCases, id: \.self) { outcome in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(outcome.color)
                            .frame(width: 10, height: 10)
                        Text("\(outcome.title) \(summary.count(outcome))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary.under) under, \(summary.onTarget) on estimate, \(summary.over) over")
    }

    private func share(_ outcome: EstimateOutcome) -> CGFloat {
        summary.tasks > 0 ? CGFloat(summary.count(outcome)) / CGFloat(summary.tasks) : 0
    }
}

extension EstimateOutcome {
    /// Diverging: blue for under, neutral gray for on estimate, red for over. Checked for color blindness.
    var color: Color {
        switch self {
        case .under: Self.adaptive(light: "#3987e5", dark: "#4a8fe0")
        case .onTarget: Self.adaptive(light: "#b4b2ab", dark: "#5e5d58")
        case .over: Self.adaptive(light: "#e5533d", dark: "#e0604a")
        }
    }

    private static func adaptive(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }
}

/// The estimate numbers for one range, built from SwiftData tasks.
@MainActor
struct EstimateReport {
    struct TopicRow {
        let topic: Topic
        let summary: EstimateSummary
    }

    let overall: EstimateSummary
    let topics: [TopicRow]
    let misses: [TodoTask]

    init(tasks: [TodoTask], since: Date?, missLimit: Int = 5) {
        let pairs = tasks
            .filter(\.isDone)
            .map { task in
                (task, EstimateSample(
                    estimated: task.estimatedSessions,
                    actual: task.actualSessions,
                    completedAt: task.completedAt ?? task.createdAt,
                    group: task.topic?.persistentModelID
                ))
            }
            .filter { EstimateStats.isEligible($0.1, since: since) }
        let samples = pairs.map(\.1)
        overall = EstimateStats.summary(samples)

        let topicsByID = Dictionary(pairs.compactMap(\.0.topic).map { ($0.persistentModelID, $0) }) { a, _ in a }
        topics = EstimateStats.byGroup(samples)
            .compactMap { id, summary in topicsByID[id].map { TopicRow(topic: $0, summary: summary) } }
            // Most tasks first, then by name.
            .sorted { ($0.summary.tasks, $1.topic.name) > ($1.summary.tasks, $0.topic.name) }

        misses = pairs
            .filter { $0.1.miss > 0 }
            .sorted { EstimateStats.isWorseMiss($0.1, than: $1.1) }
            .prefix(missLimit)
            .map(\.0)
    }
}

extension Double {
    /// "1.4×"
    var timesString: String {
        formatted(.number.precision(.fractionLength(1))) + "×"
    }
}
