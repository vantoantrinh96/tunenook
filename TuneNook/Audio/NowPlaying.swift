import MediaPlayer
import Observation

/// Shows the radio in Control Center and lets the media keys (and AirPods) play, pause and change station.
@MainActor
final class NowPlayingController {
    private let radio: RadioPlayer
    /// Stay out of Now Playing until the radio is first played, so TuneNook doesn't take
    /// the media keys from other apps at launch.
    private var claimed = false

    init(radio: RadioPlayer) {
        self.radio = radio
    }

    func start() {
        // Handlers are @Sendable so they never assume the main actor, whichever thread calls them.
        let commands = MPRemoteCommandCenter.shared()
        commands.togglePlayPauseCommand.addTarget { @Sendable [weak self] _ in
            self?.perform { $0.toggle() } ?? .commandFailed
        }
        commands.playCommand.addTarget { @Sendable [weak self] _ in
            self?.perform { if !$0.isOn { $0.play() } } ?? .commandFailed
        }
        commands.pauseCommand.addTarget { @Sendable [weak self] _ in
            self?.perform { $0.stop() } ?? .commandFailed
        }
        commands.nextTrackCommand.addTarget { @Sendable [weak self] _ in
            self?.perform { $0.selectStation(offset: 1) } ?? .commandFailed
        }
        commands.previousTrackCommand.addTarget { @Sendable [weak self] _ in
            self?.perform { $0.selectStation(offset: -1) } ?? .commandFailed
        }
        track()
    }

    private nonisolated func perform(_ action: @escaping @MainActor (RadioPlayer) -> Void) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor [weak self] in
            guard let self else { return }
            action(self.radio)
        }
        return .success
    }

    /// Re-runs whenever the radio's state or station changes.
    private func track() {
        withObservationTracking {
            update()
        } onChange: {
            Task { @MainActor [weak self] in self?.track() }
        }
    }

    private func update() {
        let center = MPNowPlayingInfoCenter.default()
        let isOn = radio.isOn
        let station = radio.currentStation
        if isOn { claimed = true }
        guard claimed, let station else { return }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: station.name,
            MPMediaItemPropertyArtist: "\(station.source) · TuneNook",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        center.playbackState = isOn ? .playing : .paused
    }
}
