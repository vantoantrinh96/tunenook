import Foundation

/// One setting or goal that has a different value here and on the other Macs.
struct SettingDifference: Equatable, Sendable {
    var label: String
    var here: String
    var there: String
}

/// The choice made the first time a Mac joins a folder other Macs already use:
/// whose settings and goals to keep when they differ. Topics, tasks and
/// sessions always combine, so they are never part of it.
enum FirstSync {
    static func differences(local: DeviceSnapshot, remote: DeviceSnapshot) -> [SettingDifference] {
        var result: [SettingDifference] = []
        for (key, here, there) in differingSettings(local: local, remote: remote) {
            result.append(SettingDifference(label: label(for: key), here: describe(here, key: key),
                                            there: describe(there, key: key)))
        }
        for (here, there) in differingGoals(local: local, remote: remote) {
            result.append(SettingDifference(
                label: "Daily goal from \(here.day.formatted(date: .abbreviated, time: .omitted))",
                here: describe(here), there: describe(there)))
        }
        return result
    }

    static func choose(useThisMac: Bool, local: DeviceSnapshot, remote: DeviceSnapshot, now: Date) -> DeviceSnapshot {
        let meta = SyncMeta(modifiedAt: now.syncMillis, modifiedBy: local.deviceID, deleted: false)
        var result = local
        for (key, here, there) in differingSettings(local: local, remote: remote) {
            result.settings[key] = SyncSetting(value: useThisMac ? here : there, meta: meta)
        }
        for (here, there) in differingGoals(local: local, remote: remote) {
            var goal = useThisMac ? here : there
            goal.meta = meta
            if let index = result.goals.firstIndex(where: { $0.day == here.day }) { result.goals[index] = goal }
        }
        return result
    }

    // MARK: - Comparing

    /// Synced settings first, in their usual order, then keys this version doesn't know.
    private static func differingSettings(local: DeviceSnapshot, remote: DeviceSnapshot) -> [(String, SyncValue, SyncValue)] {
        let known = SyncedSetting.all.map(\.key)
        let keys = known + local.settings.keys.filter { !known.contains($0) }.sorted()
        return keys.compactMap { key in
            guard let here = local.settings[key], let there = remote.settings[key],
                  !here.meta.deleted, !there.meta.deleted, here.value != there.value else { return nil }
            return (key, here.value, there.value)
        }
    }

    private static func differingGoals(local: DeviceSnapshot, remote: DeviceSnapshot) -> [(SyncGoal, SyncGoal)] {
        let remoteByDay = Dictionary(remote.goals.filter { !$0.meta.deleted }.map { ($0.day, $0) },
                                     uniquingKeysWith: { a, _ in a })
        return local.goals.filter { !$0.meta.deleted }.sorted { $0.day < $1.day }.compactMap { here in
            guard let there = remoteByDay[here.day], !here.sameContent(as: there) else { return nil }
            return (here, there)
        }
    }

    // MARK: - Describing

    private static let labels: [String: String] = [
        "timer.focusMinutes": "Focus length",
        "timer.shortBreakMinutes": "Short break",
        "timer.longBreakMinutes": "Long break",
        "timer.longBreakInterval": "Long break every",
        "timer.autoStartBreaks": "Start breaks automatically",
        "timer.autoStartFocus": "Start focus automatically",
        "away.pauseOnLock": "Pause when the Mac locks",
        "away.idleMinutes": "Pause when idle",
        "music.breakAction": "Music on breaks",
        "music.breakStationID": "Break station",
        "radio.selectedStationID": "Radio station",
        "celebrations.level": "Celebrations",
        "goals.dayStartHour": "New day starts at",
        "rewards.menuBarIcon": "Menu bar icon",
    ]

    private static func label(for key: String) -> String { labels[key] ?? key }

    private static func describe(_ value: SyncValue, key: String) -> String {
        switch (key, value) {
        case ("timer.focusMinutes", .int(let n)), ("timer.shortBreakMinutes", .int(let n)),
             ("timer.longBreakMinutes", .int(let n)):
            return "\(n) min"
        case ("timer.longBreakInterval", .int(let n)):
            return n == 1 ? "1 session" : "\(n) sessions"
        case ("away.idleMinutes", .int(let n)):
            return n == 0 ? "Off" : "After \(n) min"
        case ("music.breakAction", .string(let raw)):
            return MusicRules.BreakAction(rawValue: raw)?.title ?? raw
        case ("music.breakStationID", .string(let id)), ("radio.selectedStationID", .string(let id)):
            return RadioStation.bundled().first { $0.id == id }?.name ?? id
        case ("celebrations.level", .string(let raw)):
            return CelebrationLevel(rawValue: raw)?.title ?? raw
        case ("goals.dayStartHour", .int(let hour)):
            return hour == 0 ? "Midnight" : String(format: "%d:00", hour)
        case ("rewards.menuBarIcon", .string(let id)):
            return MenuBarIcon.with(id: id)?.name ?? id
        default:
            switch value {
            case .int(let n): return "\(n)"
            case .bool(let b): return b ? "On" : "Off"
            case .string(let s): return s
            case .null: return "None"
            }
        }
    }

    private static func describe(_ goal: SyncGoal) -> String {
        guard let kind = DailyGoal.Kind(rawValue: goal.kind) else { return "\(goal.target)" }
        return "\(goal.target) \(DailyGoal(kind: kind, target: goal.target).unit)"
    }
}
