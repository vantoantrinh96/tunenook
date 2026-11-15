import SwiftUI

struct SettingsView: View {
    @AppStorage(TimerSettings.Key.focusMinutes) private var focusMinutes = 25
    @AppStorage(TimerSettings.Key.shortBreakMinutes) private var shortBreakMinutes = 5
    @AppStorage(TimerSettings.Key.longBreakMinutes) private var longBreakMinutes = 15
    @AppStorage(TimerSettings.Key.longBreakInterval) private var longBreakInterval = 4
    @AppStorage(TimerSettings.Key.autoStartBreaks) private var autoStartBreaks = true
    @AppStorage(TimerSettings.Key.autoStartFocus) private var autoStartFocus = false
    @AppStorage(AppPreferences.autoPlayRadioKey) private var autoPlayRadio = true
    @Environment(GoalStore.self) private var goalStore

    var body: some View {
        Form {
            goalSection
            Section("Durations") {
                minutesStepper("Focus", value: $focusMinutes, range: 5...90)
                minutesStepper("Short break", value: $shortBreakMinutes, range: 1...30)
                minutesStepper("Long break", value: $longBreakMinutes, range: 5...60)
                Stepper(value: $longBreakInterval, in: 2...8) {
                    LabeledContent("Long break every", value: "\(longBreakInterval) sessions")
                }
            }
            Section("Flow") {
                Toggle("Start breaks automatically", isOn: $autoStartBreaks)
                Toggle("Start focus automatically after a break", isOn: $autoStartFocus)
                Toggle("Play radio when focus starts", isOn: $autoPlayRadio)
            }
            Section {
                Text("Radio streams by SomaFM, listener-supported internet radio.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link("somafm.com", destination: URL(string: "https://somafm.com")!)
                    .font(.footnote)
            }
            Text("Changes apply from the next timer phase.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
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

    private func minutesStepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            LabeledContent(title, value: "\(value.wrappedValue) min")
        }
    }
}
