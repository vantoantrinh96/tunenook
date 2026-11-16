import Foundation

/// What the radio should do as the timer moves between phases.
struct MusicRules: Equatable, Sendable {
    enum BreakAction: String, CaseIterable, Sendable {
        case keepPlaying
        case lowerVolume
        case stop
        case switchStation

        var title: String {
            switch self {
            case .keepPlaying: "Keep playing"
            case .lowerVolume: "Lower the volume"
            case .stop: "Stop the music"
            case .switchStation: "Switch station"
            }
        }
    }

    var breakAction: BreakAction = .lowerVolume
    var breakStationID: String?

    static let breakVolume: Float = 0.3

    enum Key {
        static let breakAction = "music.breakAction"
        static let breakStationID = "music.breakStationID"
    }

    static func load(from defaults: UserDefaults = .standard) -> MusicRules {
        var rules = MusicRules()
        if let raw = defaults.string(forKey: Key.breakAction), let action = BreakAction(rawValue: raw) {
            rules.breakAction = action
        }
        rules.breakStationID = defaults.string(forKey: Key.breakStationID)
        return rules
    }
}

/// Where the timer is, as far as music is concerned.
enum MusicMoment: Equatable, Sendable {
    /// Focus started or resumed: restores the focus station and volume if music is on.
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
    /// Turn the radio off. It only comes back when the user plays it.
    case stop
}

extension MusicRules {
    /// - Parameters:
    ///   - musicActive: whether the radio is on. Rules never turn it on; only the user does.
    ///   - focusStationID: the station picked in the radio panel.
    func command(for moment: MusicMoment, musicActive: Bool, focusStationID: String) -> MusicCommand {
        let focusPlay = MusicCommand.play(stationID: focusStationID, volume: 1)
        switch moment {
        case .focus:
            return musicActive ? focusPlay : .leaveAlone
        case .focusReady:
            return musicActive ? focusPlay : .leaveAlone
        case .breakTime:
            guard musicActive else { return .leaveAlone }
            switch breakAction {
            case .keepPlaying:
                return focusPlay
            case .lowerVolume:
                return .play(stationID: focusStationID, volume: Self.breakVolume)
            case .stop:
                return .stop
            case .switchStation:
                return .play(stationID: breakStationID ?? focusStationID, volume: 1)
            }
        case .paused, .stopped:
            return musicActive ? .stop : .leaveAlone
        }
    }
}

/// Applies the music rules to the radio as timer events come in.
@MainActor
final class MusicDirector {
    private let radio: RadioPlayer
    private let rules: () -> MusicRules

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
            musicActive: radio.isOn,
            focusStationID: radio.selectedStationID
        )
        switch command {
        case .leaveAlone:
            break
        case .play(let stationID, let volume):
            radio.play(stationID: stationID, volume: volume)
        case .stop:
            radio.stop()
        }
    }
}
