import Foundation

struct TimerSettings: Equatable, Sendable {
    var focusMinutes: Int = 25
    var shortBreakMinutes: Int = 5
    var longBreakMinutes: Int = 15
    var longBreakInterval: Int = 4
    var autoStartBreaks: Bool = true
    var autoStartFocus: Bool = false

    func duration(of kind: SessionKind) -> TimeInterval {
        let minutes = switch kind {
        case .focus: focusMinutes
        case .shortBreak: shortBreakMinutes
        case .longBreak: longBreakMinutes
        }
        return TimeInterval(max(minutes, 1) * 60)
    }

    func autoStarts(_ kind: SessionKind) -> Bool {
        kind.isBreak ? autoStartBreaks : autoStartFocus
    }

    enum Key {
        static let focusMinutes = "timer.focusMinutes"
        static let shortBreakMinutes = "timer.shortBreakMinutes"
        static let longBreakMinutes = "timer.longBreakMinutes"
        static let longBreakInterval = "timer.longBreakInterval"
        static let autoStartBreaks = "timer.autoStartBreaks"
        static let autoStartFocus = "timer.autoStartFocus"
    }

    static func load(from defaults: UserDefaults = .standard) -> TimerSettings {
        var settings = TimerSettings()
        func int(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        settings.focusMinutes = int(Key.focusMinutes, settings.focusMinutes)
        settings.shortBreakMinutes = int(Key.shortBreakMinutes, settings.shortBreakMinutes)
        settings.longBreakMinutes = int(Key.longBreakMinutes, settings.longBreakMinutes)
        settings.longBreakInterval = max(1, int(Key.longBreakInterval, settings.longBreakInterval))
        settings.autoStartBreaks = bool(Key.autoStartBreaks, settings.autoStartBreaks)
        settings.autoStartFocus = bool(Key.autoStartFocus, settings.autoStartFocus)
        return settings
    }
}
