import Foundation
import Testing
@testable import TuneNook

struct FirstSyncTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { t0.addingTimeInterval(3_600) }

    private func snapshot(_ id: String, settings: [String: SyncValue] = [:], goals: [(Int, String, Int)] = []) -> DeviceSnapshot {
        var snap = DeviceSnapshot.empty(deviceID: id, deviceName: id)
        let meta = SyncMeta(modifiedAt: .distantPast, modifiedBy: id, deleted: false)
        for setting in SyncedSetting.all { snap.settings[setting.key] = SyncSetting(value: setting.defaultValue, meta: meta) }
        for (key, value) in settings { snap.settings[key] = SyncSetting(value: value, meta: meta) }
        snap.goals = goals.map { SyncGoal(day: day($0.0), meta: meta, kind: $0.1, target: $0.2) }
        return snap
    }

    private func day(_ n: Int) -> Date { t0.addingTimeInterval(Double(n) * 86_400) }

    @Test func noDifferencesWhenEqual() {
        let local = snapshot("mac-A", settings: ["timer.focusMinutes": .int(50)], goals: [(0, "minutes", 90)])
        let remote = snapshot("mac-B", settings: ["timer.focusMinutes": .int(50)], goals: [(0, "minutes", 90)])
        #expect(FirstSync.differences(local: local, remote: remote).isEmpty)
    }

    @Test func differencesListSettingsAndSameDayGoals() {
        let local = snapshot("mac-A", settings: ["timer.focusMinutes": .int(50), "timer.autoStartFocus": .bool(true)],
                             goals: [(0, "minutes", 90), (1, "sessions", 4)])
        let remote = snapshot("mac-B", settings: ["timer.focusMinutes": .int(25)],
                              goals: [(0, "sessions", 6), (2, "minutes", 60)])
        let diffs = FirstSync.differences(local: local, remote: remote)

        #expect(diffs.count == 3)
        #expect(diffs.contains(SettingDifference(label: "Focus length", here: "50 min", there: "25 min")))
        #expect(diffs.contains(SettingDifference(label: "Start focus automatically", here: "On", there: "Off")))
        let goal = diffs.first { $0.label.hasPrefix("Daily goal from ") }
        #expect(goal?.here == "90 min")
        #expect(goal?.there == "6 sessions")
    }

    @Test func chooseThisMacStampsLocalValues() {
        let local = snapshot("mac-A", settings: ["timer.focusMinutes": .int(50)], goals: [(0, "minutes", 90)])
        let remote = snapshot("mac-B", settings: ["timer.focusMinutes": .int(25)], goals: [(0, "sessions", 6)])
        let chosen = FirstSync.choose(useThisMac: true, local: local, remote: remote, now: now)

        #expect(chosen.settings["timer.focusMinutes"]?.value == .int(50))
        #expect(chosen.settings["timer.focusMinutes"]?.meta == SyncMeta(modifiedAt: now, modifiedBy: "mac-A", deleted: false))
        #expect(chosen.goals.first?.target == 90)
        #expect(chosen.goals.first?.meta.modifiedAt == now)
        // Settings that did not differ keep their meta.
        #expect(chosen.settings["timer.shortBreakMinutes"]?.meta.modifiedAt == .distantPast)
        // The chosen values win a merge against the remote.
        let merged = SyncMerge.merge([chosen, remote], into: chosen, now: now)
        #expect(merged.settings["timer.focusMinutes"]?.value == .int(50))
    }

    @Test func chooseOtherMacTakesRemoteValues() {
        let local = snapshot("mac-A", settings: ["timer.focusMinutes": .int(50)], goals: [(0, "minutes", 90)])
        let remote = snapshot("mac-B", settings: ["timer.focusMinutes": .int(25)], goals: [(0, "sessions", 6)])
        let chosen = FirstSync.choose(useThisMac: false, local: local, remote: remote, now: now)

        #expect(chosen.deviceID == "mac-A")
        #expect(chosen.settings["timer.focusMinutes"]?.value == .int(25))
        #expect(chosen.settings["timer.focusMinutes"]?.meta.modifiedBy == "mac-A")
        #expect(chosen.goals.first?.kind == "sessions")
        #expect(chosen.goals.first?.target == 6)
        let merged = SyncMerge.merge([chosen, remote], into: chosen, now: now)
        #expect(merged.settings["timer.focusMinutes"]?.value == .int(25))
    }
}
