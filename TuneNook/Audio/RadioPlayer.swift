import AppKit
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
    /// The station on air, which a music rule may set apart from the picked one.
    private(set) var playingStationID: String?
    /// 0–1, eased toward its target so rule changes don't jolt.
    private(set) var volume: Float = 1
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
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObservers: [NSObjectProtocol] = []

    private static let selectedKey = "radio.selectedStationID"

    init(stations: [RadioStation] = RadioStation.bundled()) {
        self.stations = stations
        let saved = UserDefaults.standard.string(forKey: Self.selectedKey)
        self.selectedStationID = stations.first { $0.id == saved }?.id ?? stations.first?.id ?? ""
        player.automaticallyWaitsToMinimizeStalling = true
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.syncWithPlayer() }
        }
        // The player can stop while the Mac sleeps or the screen is locked; check again on the way back.
        let center = NSWorkspace.shared.notificationCenter
        wakeObservers = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { @Sendable [weak self] _ in
                Task { @MainActor in self?.syncWithPlayer() }
            }
        }
    }

    var selectedStation: RadioStation? {
        stations.first { $0.id == selectedStationID }
    }

    /// The station on air, or the picked one when nothing plays.
    var currentStation: RadioStation? {
        stations.first { $0.id == (playingStationID ?? selectedStationID) }
    }

    var isOn: Bool {
        state == .playing || state == .buffering
    }

    func toggle() {
        isOn ? stop() : play()
    }

    func play() {
        play(stationID: selectedStationID, volume: 1)
    }

    /// Plays a station, fading to `volume`. A station already on air keeps playing.
    func play(stationID: String, volume: Float) {
        guard let station = stations.first(where: { $0.id == stationID }) else { return }
        if isOn, playingStationID == station.id {
            fade(to: volume)
            return
        }
        fadeTask?.cancel()
        self.volume = volume
        player.volume = volume
        playingStationID = station.id
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

    /// Picks the next or previous station, wrapping around. Keeps playing if the radio is on.
    func selectStation(offset: Int) {
        guard !stations.isEmpty else { return }
        let index = stations.firstIndex { $0.id == selectedStationID } ?? 0
        let next = (index + offset % stations.count + stations.count) % stations.count
        selectedStationID = stations[next].id
    }

    func stop() {
        fadeTask?.cancel()
        playingStationID = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservation = nil
        state = .stopped
    }

    private func fade(to target: Float) {
        fadeTask?.cancel()
        let start = volume
        guard start != target else { return }
        fadeTask = Task { [weak self] in
            let steps = 20
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled, let self else { return }
                let value = start + (target - start) * Float(step) / Float(steps)
                self.volume = value
                self.player.volume = value
            }
        }
    }

    /// Mirrors the player into `state`. Reads the player's current status rather than the one
    /// a KVO change carried, so a stale change queued before a stop or play can't undo it.
    func syncWithPlayer() {
        guard state != .stopped else { return }
        if case .failed = state { return }
        if player.currentItem?.status == .failed {
            state = .failed(player.currentItem?.error?.localizedDescription ?? "Stream unavailable")
            return
        }
        switch player.timeControlStatus {
        case .playing: state = .playing
        case .waitingToPlayAtSpecifiedRate: state = .buffering
        // Nothing in the app pauses without stopping, so the system did it (sleep, lock, lost stream).
        case .paused: stop()
        @unknown default: break
        }
    }
}
