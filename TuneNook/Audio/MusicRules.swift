import Foundation

/// What the radio should do as the timer moves between phases.
struct MusicRules: Equatable, Sendable {
    enum BreakAction: String, CaseIterable, Sendable {
        case keepPlaying
        case lowerVolume
        case pause
        case switchStation

        var title: String {
            switch self {
            case .keepPlaying: "Keep playing"
            case .lowerVolume: "Lower the volume"
            case .pause: "Pause the music"
            case .switchStation: "Switch station"
            }
        }
    }

    var autoPlayOnFocus = true
    var breakAction: BreakAction = .lowerVolume
    var breakStationID: String?
    var pauseWithTimer = true
    var stopWithTimer = true

    static let breakVolume: Float = 0.3

    enum Key {
        static let autoPlayOnFocus = "radio.autoPlayOnFocus"
        static let breakAction = "music.breakAction"
        static let breakStationID = "music.breakStationID"
        static let pauseWithTimer = "music.pauseWithTimer"
        static let stopWithTimer = "music.stopWithTimer"
    }

    static func load(from defaults: UserDefaults = .standard) -> MusicRules {
        var rules = MusicRules()
        if let value = defaults.object(forKey: Key.autoPlayOnFocus) as? Bool { rules.autoPlayOnFocus = value }
        if let raw = defaults.string(forKey: Key.breakAction), let action = BreakAction(rawValue: raw) {
            rules.breakAction = action
        }
        rules.breakStationID = defaults.string(forKey: Key.breakStationID)
        if let value = defaults.object(forKey: Key.pauseWithTimer) as? Bool { rules.pauseWithTimer = value }
        if let value = defaults.object(forKey: Key.stopWithTimer) as? Bool { rules.stopWithTimer = value }
        return rules
    }
}

/// Where the timer is, as far as music is concerned.
enum MusicMoment: Equatable, Sendable {
    /// Focus started or resumed.
    case focus
    /// A focus session finished, or a break started or resumed.
    case breakTime
    /// A break was skipped; focus is next.
    case focusReady
    /// The timer was paused.
    case paused
    /// The timer was stopped before the session finished.
    case stopped
}

/// What the director should do to the radio.
enum MusicCommand: Equatable, Sendable {
    case leaveAlone
    /// Play a station at a volume. Doesn't restart a station that is already playing.
    case play(stationID: String, volume: Float)
    /// Go quiet but come back at the next focus.
    case suspend
    /// Go quiet for good.
    case stop
}

extension MusicRules {
    /// - Parameters:
    ///   - musicActive: whether music is on, or was silenced by a rule and should come back.
    ///   - focusStationID: the station picked in the radio panel.
    func command(for moment: MusicMoment, musicActive: Bool, focusStationID: String) -> MusicCommand {
        let focusPlay = MusicCommand.play(stationID: focusStationID, volume: 1)
        switch moment {
        case .focus:
            return musicActive || autoPlayOnFocus ? focusPlay : .leaveAlone
        case .focusReady:
            return musicActive ? focusPlay : .leaveAlone
        case .breakTime:
            guard musicActive else { return .leaveAlone }
            switch breakAction {
            case .keepPlaying:
                return focusPlay
            case .lowerVolume:
                return .play(stationID: focusStationID, volume: Self.breakVolume)
            case .pause:
                return .suspend
            case .switchStation:
                return .play(stationID: breakStationID ?? focusStationID, volume: 1)
            }
        case .paused:
            return musicActive && pauseWithTimer ? .suspend : .leaveAlone
        case .stopped:
            return musicActive && stopWithTimer ? .stop : .leaveAlone
        }
    }
}

/// Applies the music rules to the radio as timer events come in.
@MainActor
final class MusicDirector {
    private let radio: RadioPlayer
    private let rules: () -> MusicRules
    /// True when a rule silenced music that should come back at the next focus.
    private(set) var suspended = false

    init(radio: RadioPlayer, rules: @escaping () -> MusicRules = { MusicRules.load() }) {
        self.radio = radio
        self.rules = rules
    }

    func handle(_ moment: MusicMoment) {
        var rules = rules()
        // Until a break station is picked, use the first one that isn't the focus station.
        if !radio.stations.contains(where: { $0.id == rules.breakStationID }) {
            rules.breakStationID = radio.stations.first { $0.id != radio.selectedStationID }?.id
        }
        let command = rules.command(
            for: moment,
            musicActive: radio.isOn || suspended,
            focusStationID: radio.selectedStationID
        )
        switch command {
        case .leaveAlone:
            break
        case .play(let stationID, let volume):
            suspended = false
            radio.play(stationID: stationID, volume: volume)
        case .suspend:
            if radio.isOn {
                radio.stop()
                suspended = true
            }
        case .stop:
            suspended = false
            radio.stop()
        }
    }
}
