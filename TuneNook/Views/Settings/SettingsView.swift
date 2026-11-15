import SwiftUI

struct SettingsView: View {
    @AppStorage(TimerSettings.Key.focusMinutes) private var focusMinutes = 25
    @AppStorage(TimerSettings.Key.shortBreakMinutes) private var shortBreakMinutes = 5
    @AppStorage(TimerSettings.Key.longBreakMinutes) private var longBreakMinutes = 15
    @AppStorage(TimerSettings.Key.longBreakInterval) private var longBreakInterval = 4
    @AppStorage(TimerSettings.Key.autoStartBreaks) private var autoStartBreaks = true
    @AppStorage(TimerSettings.Key.autoStartFocus) private var autoStartFocus = false
    @AppStorage(AppPreferences.autoPlayRadioKey) private var autoPlayRadio = true

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

    private func minutesStepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            LabeledContent(title, value: "\(value.wrappedValue) min")
        }
    }
}
