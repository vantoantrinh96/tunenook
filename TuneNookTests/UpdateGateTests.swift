import Foundation
import Testing
@testable import TuneNook

@MainActor
struct UpdateGateTests {
    let clock = FakeClock()

    func makeEngine(autoStartBreaks: Bool = false) -> TimerEngine {
        let clock = self.clock
        let settings = TimerSettings(autoStartBreaks: autoStartBreaks, autoStartFocus: false)
        return TimerEngine(clock: { clock.now }, settings: { settings })
    }

    @Test func isFocusingOnlyInActiveFocus() {
        #expect(UpdateGate.isFocusing(phase: .focus, isActive: true))
        #expect(!UpdateGate.isFocusing(phase: .focus, isActive: false))
        #expect(!UpdateGate.isFocusing(phase: .shortBreak, isActive: true))
        #expect(!UpdateGate.isFocusing(phase: .longBreak, isActive: true))
    }

    @Test func scheduledUpdateOutsideFocusShowsNow() {
        var gate = UpdateGate()
        let show = gate.scheduledUpdateFound(isFocusing: false)
        #expect(show)
        #expect(!gate.isHoldingUpdate)
    }

    @Test func scheduledUpdateDuringFocusIsHeldUntilFocusEnds() {
        var gate = UpdateGate()
        let shownOnFind = gate.scheduledUpdateFound(isFocusing: true)
        #expect(!shownOnFind)
        #expect(gate.isHoldingUpdate)
        let stillFocusing = gate.focusChanged(isFocusing: true)
        #expect(!stillFocusing)
        let focusEnded = gate.focusChanged(isFocusing: false)
        #expect(focusEnded)
        #expect(!gate.isHoldingUpdate)
        let second = gate.focusChanged(isFocusing: false)
        #expect(!second)
    }

    @Test func focusEndingByAbandonShowsHeldUpdate() {
        let engine = makeEngine()
        var gate = UpdateGate()
        engine.start()
        let shownOnFind = gate.scheduledUpdateFound(isFocusing: UpdateGate.isFocusing(phase: engine.phase, isActive: engine.isActive))
        #expect(!shownOnFind)
        engine.abandon()
        let shownAfterAbandon = gate.focusChanged(isFocusing: UpdateGate.isFocusing(phase: engine.phase, isActive: engine.isActive))
        #expect(shownAfterAbandon)
    }

    @Test func manualCheckClearsHold() {
        var gate = UpdateGate()
        _ = gate.scheduledUpdateFound(isFocusing: true)
        gate.userRequestedUpdate()
        #expect(!gate.isHoldingUpdate)
        let shown = gate.focusChanged(isFocusing: false)
        #expect(!shown)
    }

    @Test func relaunchPostponedForBreakAndPausedFocus() {
        #expect(UpdateGate.shouldPostponeRelaunch(isActive: true))
        #expect(!UpdateGate.shouldPostponeRelaunch(isActive: false))

        let paused = makeEngine()
        paused.start()
        paused.pause()
        #expect(UpdateGate.shouldPostponeRelaunch(isActive: paused.isActive))

        let auto = makeEngine(autoStartBreaks: true)
        auto.start()
        clock.advance(minutes: 25)
        auto.tick()
        #expect(auto.phase == .shortBreak)
        #expect(UpdateGate.shouldPostponeRelaunch(isActive: auto.isActive))
    }
}
