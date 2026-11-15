import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            TimerSettingsTab()
                .tabItem { Label("Timer", systemImage: "timer") }
            GoalSettingsTab()
                .tabItem { Label("Goal", systemImage: "flame") }
            MusicSettingsTab()
                .tabItem { Label("Music", systemImage: "music.note") }
            RewardSettingsTab()
                .tabItem { Label("Rewards", systemImage: "gift") }
        }
        .frame(width: 460)
    }
}

private struct TimerSettingsTab: View {
    @AppStorage(TimerSettings.Key.focusMinutes) private var focusMinutes = 25
    @AppStorage(TimerSettings.Key.shortBreakMinutes) private var shortBreakMinutes = 5
    @AppStorage(TimerSettings.Key.longBreakMinutes) private var longBreakMinutes = 15
    @AppStorage(TimerSettings.Key.longBreakInterval) private var longBreakInterval = 4
    @AppStorage(TimerSettings.Key.autoStartBreaks) private var autoStartBreaks = true
    @AppStorage(TimerSettings.Key.autoStartFocus) private var autoStartFocus = false

    var body: some View {
        Form {
            Section("Durations") {
                minutesStepper("Focus", value: $focusMinutes, range: 5...90)
                minutesStepper("Short break", value: $shortBreakMinutes, range: 1...30)
                minutesStepper("Long break", value: $longBreakMinutes, range: 5...60)
                Stepper(value: $longBreakInterval, in: 2...8) {
                    LabeledContent("Long break every", value: "\(longBreakInterval) sessions")
                }
            }
            Section {
                Toggle("Start breaks automatically", isOn: $autoStartBreaks)
                Toggle("Start focus automatically after a break", isOn: $autoStartFocus)
            } header: {
                Text("Flow")
            } footer: {
                Text("Changes apply from the next timer phase.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func minutesStepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            LabeledContent(title, value: "\(value.wrappedValue) min")
        }
    }
}

private struct GoalSettingsTab: View {
    @Environment(GoalStore.self) private var goalStore

    var body: some View {
        Form {
            goalSection
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var goalSection: some View {
        @Bindable var goalStore = goalStore
        let goal = goalStore.current
        let kind = Binding<DailyGoal.Kind>(
            get: { goalStore.current.kind },
            set: { goalStore.setGoal(DailyGoal(kind: $0, target: DailyGoal.defaultTarget(for: $0))) }
        )
        let target = Binding<Int>(
            get: { goalStore.current.target },
            set: { goalStore.setGoal(DailyGoal(kind: goalStore.current.kind, target: $0)) }
        )
        return Section {
            Picker("Daily goal", selection: kind) {
                Text("Focus minutes").tag(DailyGoal.Kind.minutes)
                Text("Sessions").tag(DailyGoal.Kind.sessions)
            }
            if goal.kind == .minutes {
                Stepper(value: target, in: 15...600, step: 15) {
                    LabeledContent("Target", value: "\(goal.target) min")
                }
            } else {
                Stepper(value: target, in: 1...16) {
                    LabeledContent("Target", value: "\(goal.target) sessions")
                }
            }
            Picker("New day starts at", selection: $goalStore.dayStartHour) {
                ForEach(0...6, id: \.self) { hour in
                    Text(hour == 0 ? "Midnight" : "\(hour):00 AM").tag(hour)
                }
            }
        } header: {
            Text("Daily goal")
        } footer: {
            Text("Hit the goal to grow your streak. Every \(FocusStats.freezeEvery)-day streak earns a freeze (max \(FocusStats.maxFreezes)) that covers a missed day. Goal changes apply from today on.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MusicSettingsTab: View {
    @Environment(RadioPlayer.self) private var radio
    @AppStorage(MusicRules.Key.autoPlayOnFocus) private var autoPlayOnFocus = true
    @AppStorage(MusicRules.Key.breakAction) private var breakAction = MusicRules.BreakAction.lowerVolume
    @AppStorage(MusicRules.Key.breakStationID) private var breakStationID = ""
    @AppStorage(MusicRules.Key.pauseWithTimer) private var pauseWithTimer = true
    @AppStorage(MusicRules.Key.stopWithTimer) private var stopWithTimer = true

    var body: some View {
        Form {
            Section {
                Toggle("Play radio when focus starts", isOn: $autoPlayOnFocus)
                Picker("When a break starts", selection: $breakAction) {
                    ForEach(MusicRules.BreakAction.allCases, id: \.self) { action in
                        Text(action.title).tag(action)
                    }
                }
                if breakAction == .switchStation {
                    Picker("Break station", selection: breakStation) {
                        ForEach(radio.stations) { station in
                            Label(station.name, systemImage: station.symbol).tag(station.id)
                        }
                    }
                }
                Toggle("Pause music when the timer is paused", isOn: $pauseWithTimer)
                Toggle("Stop music when the timer is stopped", isOn: $stopWithTimer)
            } header: {
                Text("Smart rules")
            } footer: {
                Text("Focus always plays the station picked in the menu bar, at full volume. Music paused by a rule comes back when focus resumes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Radio streams by SomaFM, listener-supported internet radio.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link("somafm.com", destination: URL(string: "https://somafm.com")!)
                    .font(.footnote)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Defaults to a calm station other than the focus one.
    private var breakStation: Binding<String> {
        Binding(
            get: {
                if radio.stations.contains(where: { $0.id == breakStationID }) { return breakStationID }
                return radio.stations.first { $0.id != radio.selectedStationID }?.id ?? radio.selectedStationID
            },
            set: { breakStationID = $0 }
        )
    }
}

private struct RewardSettingsTab: View {
    @AppStorage(CelebrationLevel.key) private var level = CelebrationLevel.milestones
    @State private var preview = CelebrationCenter()

    var body: some View {
        Form {
            Section {
                Picker("Celebrations", selection: $level) {
                    ForEach(CelebrationLevel.allCases, id: \.self) { level in
                        Text(level.title).tag(level)
                    }
                }
                LabeledContent("Preview") {
                    Button("Show") {
                        preview.celebrate([.streakMilestone(days: 7)], level: .everySession)
                    }
                }
            } footer: {
                Text("Milestones are reaching your daily goal, streak milestones and new icons.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Menu bar icon") {
                IconCollectionView()
                    .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
