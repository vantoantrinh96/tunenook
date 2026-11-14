import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class RadioPlayer {
    enum State: Equatable {
        case stopped
        case buffering
        case playing
        case failed(String)
    }

    let stations: [RadioStation]
    private(set) var state: State = .stopped
    var selectedStationID: String {
        didSet {
            guard oldValue != selectedStationID else { return }
            UserDefaults.standard.set(selectedStationID, forKey: Self.selectedKey)
            if state != .stopped { play() }
        }
    }

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?

    private static let selectedKey = "radio.selectedStationID"

    init(stations: [RadioStation] = RadioStation.bundled()) {
        self.stations = stations
        let saved = UserDefaults.standard.string(forKey: Self.selectedKey)
        self.selectedStationID = stations.first { $0.id == saved }?.id ?? stations.first?.id ?? ""
        player.automaticallyWaitsToMinimizeStalling = true
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.handle(status) }
        }
    }

    var selectedStation: RadioStation? {
        stations.first { $0.id == selectedStationID }
    }

    var isOn: Bool {
        state == .playing || state == .buffering
    }

    func toggle() {
        isOn ? stop() : play()
    }

    func play() {
        guard let station = selectedStation else { return }
        let item = AVPlayerItem(url: station.url)
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "Stream unavailable"
            Task { @MainActor in self?.state = .failed(message) }
        }
        player.replaceCurrentItem(with: item)
        state = .buffering
        player.play()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservation = nil
        state = .stopped
    }

    private func handle(_ status: AVPlayer.TimeControlStatus) {
        guard state != .stopped else { return }
        if case .failed = state { return }
        switch status {
        case .playing: state = .playing
        case .waitingToPlayAtSpecifiedRate: state = .buffering
        case .paused: break
        @unknown default: break
        }
    }
}
