import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
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

private struct GeneralSettingsTab: View {
    @Environment(LaunchAtLogin.self) private var launchAtLogin
    @Environment(UpdaterController.self) private var updater
    @AppStorage(AwayPolicy.Key.pauseOnLock) private var pauseOnLock = true
    @AppStorage(AwayPolicy.Key.idleMinutes) private var idleMinutes = 0

    var body: some View {
        @Bindable var updater = updater
        Form {
            Section {
                Toggle("Open TuneNook at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if launchAtLogin.needsApproval {
                    LabeledContent("Allow TuneNook in Login Items") {
                        Button("Open System Settings") { launchAtLogin.openLoginItemsSettings() }
                    }
                }
                if let error = launchAtLogin.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                LabeledContent("Start / pause shortcut") {
                    ShortcutRecorder()
                }
            } header: {
                Text("General")
            } footer: {
                Text("The shortcut works from any app. Media keys and AirPods play, pause and change the radio station.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Pause when the Mac locks or sleeps", isOn: $pauseOnLock)
                Picker("Pause when idle for", selection: $idleMinutes) {
                    ForEach(AwayPolicy.idleChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Never" : "\(minutes) minutes").tag(minutes)
                    }
                }
            } header: {
                Text("When you step away")
            } footer: {
                Text("Applies to focus sessions. Idle time isn't counted: the timer goes back to when you stopped typing or moving the mouse. A notification lets you resume when you're back.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                Toggle("Download and install updates automatically", isOn: $updater.automaticallyDownloadsUpdates)
                    .disabled(!updater.automaticallyChecksForUpdates)
                LabeledContent("Version") {
                    HStack {
                        Text(updater.versionDescription)
                        Button("Check Now") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Updates are verified before they're installed. If a timer is running, the update waits until you quit TuneNook.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchAtLogin.refresh() }
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
    @AppStorage(MusicRules.Key.breakAction) private var breakAction = MusicRules.BreakAction.lowerVolume
    @AppStorage(MusicRules.Key.breakStationID) private var breakStationID = ""

    var body: some View {
        Form {
            Section {
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
            } header: {
                Text("Smart rules")
            } footer: {
                Text("Pausing the timer pauses the music and resuming brings it back. Stopping the timer stops the music. Music never starts by itself: press play in the menu bar when you want it.")
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
