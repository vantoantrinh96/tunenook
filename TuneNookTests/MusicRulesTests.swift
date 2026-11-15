import Testing
@testable import TuneNook

struct MusicRulesTests {
    let focus = "groovesalad"

    func command(_ moment: MusicMoment, active: Bool, _ configure: (inout MusicRules) -> Void = { _ in }) -> MusicCommand {
        var rules = MusicRules()
        configure(&rules)
        return rules.command(for: moment, musicActive: active, focusStationID: focus)
    }

    @Test func focusAutoPlays() {
        #expect(command(.focus, active: false) == .play(stationID: focus, volume: 1))
        #expect(command(.focus, active: false) { $0.autoPlayOnFocus = false } == .leaveAlone)
        // Music that was on, or paused by a rule, always returns for focus.
        #expect(command(.focus, active: true) { $0.autoPlayOnFocus = false } == .play(stationID: focus, volume: 1))
    }

    @Test func breakActions() {
        #expect(command(.breakTime, active: true) == .play(stationID: focus, volume: MusicRules.breakVolume))
        #expect(command(.breakTime, active: true) { $0.breakAction = .keepPlaying } == .play(stationID: focus, volume: 1))
        #expect(command(.breakTime, active: true) { $0.breakAction = .pause } == .suspend)
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

    @Test func pauseAndStopFollowTimer() {
        #expect(command(.paused, active: true) == .suspend)
        #expect(command(.paused, active: true) { $0.pauseWithTimer = false } == .leaveAlone)
        #expect(command(.stopped, active: true) == .stop)
        #expect(command(.stopped, active: true) { $0.stopWithTimer = false } == .leaveAlone)
    }

    @Test func skippedBreakRestoresFocusMusic() {
        #expect(command(.focusReady, active: true) == .play(stationID: focus, volume: 1))
    }
}
