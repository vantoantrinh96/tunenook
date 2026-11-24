import Foundation
import Testing
@testable import TuneNook

@MainActor
final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(minutes: Double) { now.addTimeInterval(minutes * 60) }
}

@MainActor
struct TimerEngineTests {
    let clock = FakeClock()
    var settings = TimerSettings(autoStartBreaks: false, autoStartFocus: false)

    func makeEngine() -> (TimerEngine, Recorder) {
        let clock = self.clock
        let settings = self.settings
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let engine = TimerEngine(clock: { clock.now }, settings: { settings }, calendar: utc)
        let recorder = Recorder()
        engine.onSessionEnded = { recorder.records.append($0) }
        return (engine, recorder)
    }

    @Test func focusCompletesIntoShortBreak() {
        let (engine, recorder) = makeEngine()
        engine.start()
        clock.advance(minutes: 25)
        engine.tick()

        #expect(engine.phase == .shortBreak)
        #expect(engine.status == .idle)
        #expect(recorder.records.count == 1)
        #expect(recorder.records[0].kind == .focus)
        #expect(recorder.records[0].completed)
        #expect(engine.completedFocusCount == 1)
    }

    @Test func pauseFreezesRemainingTime() {
        let (engine, _) = makeEngine()
        engine.start()
        clock.advance(minutes: 10)
        engine.pause()
        clock.advance(minutes: 60)
        engine.tick()

        #expect(engine.remaining == 15 * 60)
        engine.resume()
        clock.advance(minutes: 15)
        engine.tick()
        #expect(engine.phase == .shortBreak)
    }

    @Test func activeDurationExcludesPauses() {
        let (engine, recorder) = makeEngine()
        engine.start()
        clock.advance(minutes: 10)
        engine.pause()
        clock.advance(minutes: 30)
        engine.resume()
        clock.advance(minutes: 15)
        engine.tick()

        #expect(abs((recorder.records.first?.activeDuration ?? 0) - 25 * 60) < 0.001)
    }

    @Test func abandonDoesNotCount() {
        let (engine, recorder) = makeEngine()
        engine.start()
        clock.advance(minutes: 5)
        engine.abandon()

        #expect(engine.phase == .focus)
        #expect(engine.status == .idle)
        #expect(engine.completedFocusCount == 0)
        #expect(recorder.records.map(\.completed) == [false])
    }

    @Test func longBreakAfterInterval() {
        var test = self
        test.settings.autoStartBreaks = true
        test.settings.autoStartFocus = true
        let (engine, _) = test.makeEngine()
        engine.start()
        // 4 focus (25) + 3 short breaks (5) = 115 minutes.
        test.clock.advance(minutes: 115)
        engine.tick()

        #expect(engine.phase == .longBreak)
        #expect(engine.completedFocusCount == 4)
        #expect(engine.isRunning)
    }

    @Test func longBreakCycleStartsOverOnANewDay() {
        let (engine, _) = makeEngine()
        // Three focus sessions today: the next one would earn a long break.
        for _ in 0..<3 {
            engine.start()
            clock.advance(minutes: 25)
            engine.tick()
            engine.skipBreak()
        }
        #expect(engine.cyclePosition == 3)

        clock.advance(minutes: 24 * 60)
        engine.tick()
        #expect(engine.cyclePosition == 0)

        engine.start()
        clock.advance(minutes: 25)
        engine.tick()
        #expect(engine.phase == .shortBreak)
        #expect(engine.completedFocusCount == 1)
    }

    @Test func focusFinishingAfterMidnightCountsForTheNewDay() {
        let (engine, _) = makeEngine()
        for _ in 0..<3 {
            engine.start()
            clock.advance(minutes: 25)
            engine.tick()
            engine.skipBreak()
        }
        // Fixed clock starts at 08:00 UTC; it is now 09:15. Start a focus at 23:50.
        clock.advance(minutes: 14 * 60 + 35)
        engine.start()
        clock.advance(minutes: 25)
        engine.tick()

        #expect(engine.phase == .shortBreak)
        #expect(engine.completedFocusCount == 1)
    }

    @Test func sleepingThroughPhasesCatchesUp() {
        var test = self
        test.settings.autoStartBreaks = true
        let (engine, recorder) = test.makeEngine()
        engine.start()
        // Laptop asleep for 40 minutes: focus (25) and short break (5) both finish.
        test.clock.advance(minutes: 40)
        engine.tick()

        #expect(recorder.records.map(\.kind) == [.focus, .shortBreak])
        #expect(engine.phase == .focus)
        #expect(engine.status == .idle)
        #expect(recorder.records[1].endedAt == recorder.records[0].endedAt.addingTimeInterval(5 * 60))
    }

    @Test func skipBreakReturnsToFocus() {
        let (engine, recorder) = makeEngine()
        engine.start()
        clock.advance(minutes: 25)
        engine.tick()
        engine.start()
        engine.skipBreak()

        #expect(engine.phase == .focus)
        #expect(engine.status == .idle)
        #expect(recorder.records.last?.kind == .shortBreak)
        #expect(recorder.records.last?.completed == false)
    }

    @Test func pickingTaskAfterStartingWithoutOneKeepsTimer() {
        let (engine, recorder) = makeEngine()
        let task = TodoTask(title: "Write", estimatedSessions: 1)
        engine.start()
        clock.advance(minutes: 5)
        #expect(!engine.isTaskLocked)
        #expect(engine.requestSwitch(to: task, startNow: false) == nil)

        #expect(engine.currentTask === task)
        #expect(engine.isRunning)
        #expect(recorder.records.isEmpty)
    }

    @Test func switchingTaskMidSessionNeedsConfirmAndResets() {
        let (engine, recorder) = makeEngine()
        let first = TodoTask(title: "Write", estimatedSessions: 1)
        let second = TodoTask(title: "Review", estimatedSessions: 1)
        engine.start(task: first)
        clock.advance(minutes: 5)
        engine.pause()

        let change = engine.requestSwitch(to: second, startNow: false)
        #expect(change != nil)
        #expect(engine.currentTask === first)
        #expect(engine.isPaused)

        engine.confirm(change!)
        #expect(engine.currentTask === second)
        #expect(engine.isRunning)
        #expect(engine.remaining == 25 * 60)
        #expect(recorder.records.map(\.completed) == [false])
        #expect(recorder.records.first?.task === first)
    }

    @Test func switchingDuringBreakIsFree() {
        let (engine, _) = makeEngine()
        engine.start(task: TodoTask(title: "Write", estimatedSessions: 1))
        clock.advance(minutes: 25)
        engine.tick()
        engine.start()
        #expect(engine.requestSwitch(to: TodoTask(title: "Review", estimatedSessions: 1), startNow: false) == nil)
        #expect(engine.phase == .shortBreak)
        #expect(engine.isRunning)
    }
}

@MainActor
final class Recorder {
    var records: [SessionRecord] = []
}
