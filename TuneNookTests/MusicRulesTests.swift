import Testing
@testable import TuneNook

struct MusicRulesTests {
    let focus = "groovesalad"

    func command(_ moment: MusicMoment, active: Bool, _ configure: (inout MusicRules) -> Void = { _ in }) -> MusicCommand {
        var rules = MusicRules()
        configure(&rules)
        return rules.command(for: moment, musicActive: active, focusStationID: focus)
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
        #expect(command(.paused, active: true) == .stop)
        #expect(command(.stopped, active: true) == .stop)
    }

    @Test func skippedBreakRestoresFocusMusic() {
        #expect(command(.focusReady, active: true) == .play(stationID: focus, volume: 1))
    }
}
