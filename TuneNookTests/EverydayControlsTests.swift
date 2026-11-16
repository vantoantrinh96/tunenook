import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import TuneNook

@MainActor
struct EverydayControlsTests {
    // MARK: Backdated pause

    @Test func pauseAsOfIdleStartDoesNotCountIdleTime() {
        let clock = FakeClock()
        let engine = TimerEngine(clock: { clock.now }, settings: { TimerSettings(autoStartBreaks: false) })
        let recorder = Recorder()
        engine.onSessionEnded = { recorder.records.append($0) }
        engine.start()
        clock.advance(minutes: 10)
        // Idle for the last 5 of those minutes.
        engine.pause(asOf: clock.now.addingTimeInterval(-5 * 60))
        #expect(engine.remaining == 20 * 60)

        engine.resume()
        clock.advance(minutes: 20)
        engine.tick()
        #expect(abs((recorder.records.first?.activeDuration ?? 0) - 25 * 60) < 0.001)
    }

    @Test func pauseNeverGoesBackBeforeTheRunStarted() {
        let clock = FakeClock()
        let engine = TimerEngine(clock: { clock.now }, settings: { TimerSettings() })
        engine.start()
        clock.advance(minutes: 2)
        engine.pause(asOf: clock.now.addingTimeInterval(-60 * 60))
        #expect(engine.remaining == 25 * 60)
    }

    // MARK: Away policy

    @Test func idlePolicy() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var policy = AwayPolicy(idleMinutes: 0)
        #expect(policy.idlePauseDate(idleSeconds: 3600, now: now) == nil)
        policy.idleMinutes = 5
        #expect(policy.idlePauseDate(idleSeconds: 4 * 60, now: now) == nil)
        #expect(policy.idlePauseDate(idleSeconds: 6 * 60, now: now) == now.addingTimeInterval(-6 * 60))
    }

    // MARK: Shortcut

    @Test func shortcutNeedsCommandOptionOrControl() {
        #expect(GlobalShortcut(keyCode: UInt16(kVK_ANSI_P), flags: [], characters: "p") == nil)
        #expect(GlobalShortcut(keyCode: UInt16(kVK_ANSI_P), flags: [.shift], characters: "p") == nil)
        let shortcut = GlobalShortcut(keyCode: UInt16(kVK_Space), flags: [.command, .shift], characters: " ")
        #expect(shortcut?.display == "⇧⌘Space")
        #expect(shortcut?.modifiers == UInt32(cmdKey | shiftKey))
    }

    @Test func shortcutPersistsAndCanBeTurnedOff() {
        let defaults = UserDefaults(suiteName: "hotkeys-\(UUID())")!
        let first = HotKeyCenter(defaults: defaults) {}
        #expect(first.shortcut == .default)
        first.set(nil)
        #expect(HotKeyCenter(defaults: defaults) {}.shortcut == nil)
        let custom = GlobalShortcut(keyCode: UInt16(kVK_F5), flags: [.control], characters: nil)!
        first.set(custom)
        #expect(HotKeyCenter(defaults: defaults) {}.shortcut?.display == "⌃F5")
    }
}
