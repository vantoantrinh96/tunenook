import SwiftData
import SwiftUI

struct MenuBarView: View {
    @Environment(TimerEngine.self) private var engine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TimerPanel()
            Divider()
            RadioPanel()
            Divider()
            TodaySummary()
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 300)
    }

    private var footer: some View {
        HStack {
            Button("Open TuneNook") {
                openWindow(id: WindowID.main)
                activateApp()
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .simultaneousGesture(TapGesture().onEnded { activateApp() })
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit TuneNook")
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Timer

private struct TimerPanel: View {
    @Environment(TimerEngine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(engine.phase.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(engine.phase.tint.opacity(0.18), in: Capsule())
                    .foregroundStyle(engine.phase.tint)
                Spacer()
                CycleDots(filled: engine.cyclePosition, total: engine.settings.longBreakInterval)
            }

            Text(engine.remaining.clockString)
                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(maxWidth: .infinity)

            ProgressView(value: engine.progress)
                .tint(engine.phase.tint)

            TaskLine()

            HStack {
                Button(action: engine.toggle) {
                    Label(primaryTitle, systemImage: engine.isRunning ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.phase.tint)
                .keyboardShortcut(.space, modifiers: [])

                if engine.phase.isBreak {
                    Button("Skip", action: engine.skipBreak)
                } else if engine.isActive {
                    Button("Stop", role: .destructive, action: engine.abandon)
                        .help("Stop without counting this session")
                }
            }
            .controlSize(.large)
        }
    }

    private var primaryTitle: String {
        switch engine.status {
        case .idle: engine.phase.isBreak ? "Start Break" : "Start Focus"
        case .running: "Pause"
        case .paused: "Resume"
        }
    }
}

private struct CycleDots: View {
    let filled: Int
    let total: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index < filled ? Color(hex: "#E5533D") : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
        .help("\(filled) of \(total) until the long break")
    }
}

private struct TaskLine: View {
    @Environment(TimerEngine.self) private var engine
    @Query(sort: \Topic.createdAt) private var topics: [Topic]

    var body: some View {
        HStack(spacing: 8) {
            if let task = engine.currentTask {
                Button {
                    task.setDone(!task.isDone)
                } label: {
                    Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.borderless)
                .help(task.isDone ? "Mark as not done" : "Mark task done")

                Text(task.title)
                    .lineLimit(1)
                    .strikethrough(task.isDone)
                Spacer(minLength: 4)
                SessionBadge(actual: task.actualSessions, estimated: task.estimatedSessions)
            } else {
                Text("No task selected")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            taskMenu
        }
        .font(.callout)
    }

    private var taskMenu: some View {
        Menu {
            ForEach(topics) { topic in
                let open = topic.openTasks
                if !open.isEmpty {
                    Section(topic.name) {
                        ForEach(open) { task in
                            Button(task.title) { engine.currentTask = task }
                        }
                    }
                }
            }
            if engine.currentTask != nil {
                Divider()
                Button("Clear Task") { engine.currentTask = nil }
            }
        } label: {
            Image(systemName: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose a task")
    }
}

// MARK: - Radio

private struct RadioPanel: View {
    @Environment(RadioPlayer.self) private var radio

    var body: some View {
        @Bindable var radio = radio
        HStack(spacing: 10) {
            Button(action: radio.toggle) {
                Image(systemName: radio.isOn ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title)
            }
            .buttonStyle(.borderless)
            .disabled(radio.stations.isEmpty)
            .help(radio.isOn ? "Stop radio" : "Play radio")

            VStack(alignment: .leading, spacing: 2) {
                Picker("Station", selection: $radio.selectedStationID) {
                    ForEach(radio.stations) { station in
                        Label(station.name, systemImage: station.symbol).tag(station.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var statusText: String {
        switch radio.state {
        case .stopped: radio.selectedStation?.subtitle ?? "No stations"
        case .buffering: "Connecting…"
        case .playing: "Live · \(radio.selectedStation?.source ?? "")"
        case .failed(let message): message
        }
    }
}

// MARK: - Today

private struct TodaySummary: View {
    @Query private var sessions: [FocusSession]

    init() {
        let start = Calendar.current.startOfDay(for: .now)
        let focus = SessionKind.focus.rawValue
        _sessions = Query(filter: #Predicate<FocusSession> {
            $0.completed && $0.kindRaw == focus && $0.endedAt >= start
        })
    }

    var body: some View {
        let minutes = Int(sessions.reduce(0) { $0 + $1.endedAt.timeIntervalSince($1.startedAt) } / 60)
        HStack {
            Text("Today")
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(sessions.count) ♪ · \(minutes) min")
                .monospacedDigit()
        }
        .font(.callout)
    }
}
