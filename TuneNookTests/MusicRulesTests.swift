import Testing
@testable import TuneNook

struct MusicRulesTests {
    let focus = "groovesalad"

    func command(
        _ moment: MusicMoment,
        active: Bool,
        suspended: Bool = false,
        _ configure: (inout MusicRules) -> Void = { _ in }
    ) -> MusicCommand {
        var rules = MusicRules()
        configure(&rules)
        return rules.command(for: moment, playing: active, suspended: suspended, focusStationID: focus)
    }

    @Test func focusNeverStartsMusic() {
        #expect(command(.focus, active: false) == .leaveAlone)
        // Music that is on returns to the focus station at full volume.
        #expect(command(.focus, active: true) == .play(stationID: focus, volume: 1))
    }

    @Test func breakActions() {
        #expect(command(.breakTime, active: true) == .play(stationID: focus, volume: MusicRules.breakVolume))
        #expect(command(.breakTime, active: true) { $0.breakAction = .keepPlaying } == .play(stationID: focus, volume: 1))
        #expect(command(.breakTime, active: true) { $0.breakAction = .stop } == .stop)
        #expect(command(.breakTime, active: true) {
            $0.breakAction = .switchStation
            $0.breakStationID = "dronezone"
        } == .play(stationID: "dronezone", volume: 1))
    }

    @Test func silentRadioStaysSilent() {
        for moment in [MusicMoment.breakTime, .focusReady, .paused, .stopped] {
            #expect(command(moment, active: false) == .leaveAlone)
        }
    }

    @Test func pauseAndStopStopMusic() {
        #expect(command(.paused, active: true) == .suspend)
        #expect(command(.stopped, active: true) == .stop)
        #expect(command(.stopped, active: false, suspended: true) == .stop)
    }

    @Test func resumeContinuesPausedMusic() {
        #expect(command(.focus, active: false, suspended: true) == .play(stationID: focus, volume: 1))
        // Resuming a paused break brings music back under the break rule.
        #expect(command(.breakTime, active: false, suspended: true) == .play(stationID: focus, volume: MusicRules.breakVolume))
        // Skipping a paused break leaves the timer idle, so the music stays off.
        #expect(command(.focusReady, active: false, suspended: true) == .stop)
    }

    @Test func skippedBreakRestoresFocusMusic() {
        #expect(command(.focusReady, active: true) == .play(stationID: focus, volume: 1))
    }
}
