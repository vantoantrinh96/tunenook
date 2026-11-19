import Foundation

struct GoalDTO: Codable, Equatable {
    let kind: String
    let target: Int
}

struct StationDTO: Encodable {
    let id: String
    let name: String
}

struct AllowedDTO: Encodable {
    let dailyGoalKind: [String]
    let breakMusic: [String]
    let celebrations: [String]
    let idlePauseMinutes: [Int]
    let stations: [StationDTO]
}

struct SettingsDTO: Encodable {
    let focusMinutes: Int
    let shortBreakMinutes: Int
    let longBreakMinutes: Int
    let longBreakInterval: Int
    let autoStartBreaks: Bool
    let autoStartFocus: Bool
    let dailyGoal: GoalDTO
    let dayStartHour: Int
    let breakMusic: String
    let breakStationId: String?
    let celebrations: String
    let pauseOnLock: Bool
    let idlePauseMinutes: Int
    let allowed: AllowedDTO

    enum CodingKeys: String, CodingKey {
        case focusMinutes, shortBreakMinutes, longBreakMinutes, longBreakInterval
        case autoStartBreaks, autoStartFocus, dailyGoal, dayStartHour, breakMusic
        case breakStationId, celebrations, pauseOnLock, idlePauseMinutes, allowed
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(focusMinutes, forKey: .focusMinutes)
        try c.encode(shortBreakMinutes, forKey: .shortBreakMinutes)
        try c.encode(longBreakMinutes, forKey: .longBreakMinutes)
        try c.encode(longBreakInterval, forKey: .longBreakInterval)
        try c.encode(autoStartBreaks, forKey: .autoStartBreaks)
        try c.encode(autoStartFocus, forKey: .autoStartFocus)
        try c.encode(dailyGoal, forKey: .dailyGoal)
        try c.encode(dayStartHour, forKey: .dayStartHour)
        try c.encode(breakMusic, forKey: .breakMusic)
        try c.encode(breakStationId, forKey: .breakStationId)
        try c.encode(celebrations, forKey: .celebrations)
        try c.encode(pauseOnLock, forKey: .pauseOnLock)
        try c.encode(idlePauseMinutes, forKey: .idlePauseMinutes)
        try c.encode(allowed, forKey: .allowed)
    }
}

struct UpdateSettingsArgs: Decodable {
    enum StationChange { case keep, clear, set(String) }

    var focusMinutes: Int?
    var shortBreakMinutes: Int?
    var longBreakMinutes: Int?
    var longBreakInterval: Int?
    var autoStartBreaks: Bool?
    var autoStartFocus: Bool?
    var dailyGoal: GoalDTO?
    var breakMusic: String?
    var breakStation: StationChange = .keep
    var celebrations: String?
    var pauseOnLock: Bool?
    var idlePauseMinutes: Int?
    var hasDayStartHour = false

    enum CodingKeys: String, CodingKey {
        case focusMinutes, shortBreakMinutes, longBreakMinutes, longBreakInterval
        case autoStartBreaks, autoStartFocus, dailyGoal, dayStartHour, breakMusic
        case breakStationId, celebrations, pauseOnLock, idlePauseMinutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasDayStartHour = c.contains(.dayStartHour)
        focusMinutes = try c.decodeIfPresent(Int.self, forKey: .focusMinutes)
        shortBreakMinutes = try c.decodeIfPresent(Int.self, forKey: .shortBreakMinutes)
        longBreakMinutes = try c.decodeIfPresent(Int.self, forKey: .longBreakMinutes)
        longBreakInterval = try c.decodeIfPresent(Int.self, forKey: .longBreakInterval)
        autoStartBreaks = try c.decodeIfPresent(Bool.self, forKey: .autoStartBreaks)
        autoStartFocus = try c.decodeIfPresent(Bool.self, forKey: .autoStartFocus)
        dailyGoal = try c.decodeIfPresent(GoalDTO.self, forKey: .dailyGoal)
        breakMusic = try c.decodeIfPresent(String.self, forKey: .breakMusic)
        if c.contains(.breakStationId) {
            breakStation = try c.decodeNil(forKey: .breakStationId) ? .clear : .set(c.decode(String.self, forKey: .breakStationId))
        }
        celebrations = try c.decodeIfPresent(String.self, forKey: .celebrations)
        pauseOnLock = try c.decodeIfPresent(Bool.self, forKey: .pauseOnLock)
        idlePauseMinutes = try c.decodeIfPresent(Int.self, forKey: .idlePauseMinutes)
    }
}

extension TuneNookTools {
    func getSettings() -> SettingsDTO {
        let timer = TimerSettings.load(from: defaults)
        let music = MusicRules.load(from: defaults)
        let away = AwayPolicy.load(from: defaults)
        let level = defaults.string(forKey: CelebrationLevel.key).flatMap(CelebrationLevel.init) ?? .milestones
        let goal = goalStore.current
        return SettingsDTO(
            focusMinutes: timer.focusMinutes, shortBreakMinutes: timer.shortBreakMinutes,
            longBreakMinutes: timer.longBreakMinutes, longBreakInterval: timer.longBreakInterval,
            autoStartBreaks: timer.autoStartBreaks, autoStartFocus: timer.autoStartFocus,
            dailyGoal: GoalDTO(kind: goal.kind.rawValue, target: goal.target),
            dayStartHour: goalStore.dayStartHour,
            breakMusic: music.breakAction.rawValue, breakStationId: music.breakStationID,
            celebrations: level.rawValue,
            pauseOnLock: away.pauseOnLock, idlePauseMinutes: away.idleMinutes,
            allowed: AllowedDTO(
                dailyGoalKind: DailyGoal.Kind.allCases.map(\.rawValue),
                breakMusic: MusicRules.BreakAction.allCases.map(\.rawValue),
                celebrations: CelebrationLevel.allCases.map(\.rawValue),
                idlePauseMinutes: AwayPolicy.idleChoices,
                stations: stations.map { StationDTO(id: $0.id, name: $0.name) }))
    }

    private func inRange(_ value: Int?, _ range: ClosedRange<Int>, _ field: String) throws -> Int? {
        guard let value else { return nil }
        guard range.contains(value) else {
            throw ToolError("\(field) must be between \(range.lowerBound) and \(range.upperBound).")
        }
        return value
    }

    func updateSettings(_ args: UpdateSettingsArgs) throws -> SettingsDTO {
        if args.hasDayStartHour {
            throw ToolError("day_start_hour can only be changed in TuneNook's Settings.")
        }
        // Validate everything first; nothing is written unless every field is good.
        let focus = try inRange(args.focusMinutes, 5...90, "focus_minutes")
        let short = try inRange(args.shortBreakMinutes, 1...30, "short_break_minutes")
        let long = try inRange(args.longBreakMinutes, 5...60, "long_break_minutes")
        let interval = try inRange(args.longBreakInterval, 2...8, "long_break_interval")

        var goal: DailyGoal?
        if let dto = args.dailyGoal {
            guard let kind = DailyGoal.Kind(rawValue: dto.kind) else {
                throw ToolError("daily_goal.kind must be one of: \(DailyGoal.Kind.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            switch kind {
            case .minutes:
                guard (15...600).contains(dto.target), dto.target % 15 == 0 else {
                    throw ToolError("daily_goal.target for minutes must be a multiple of 15 between 15 and 600.")
                }
            case .sessions:
                guard (1...16).contains(dto.target) else {
                    throw ToolError("daily_goal.target for sessions must be between 1 and 16.")
                }
            }
            goal = DailyGoal(kind: kind, target: dto.target)
        }

        var action: MusicRules.BreakAction?
        if let raw = args.breakMusic {
            guard let value = MusicRules.BreakAction(rawValue: raw) else {
                throw ToolError("break_music must be one of: \(MusicRules.BreakAction.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            action = value
        }
        if case .set(let id) = args.breakStation, !stations.contains(where: { $0.id == id }) {
            throw ToolError("break_station_id must be one of the ids in allowed.stations, or null.")
        }
        var level: CelebrationLevel?
        if let raw = args.celebrations {
            guard let value = CelebrationLevel(rawValue: raw) else {
                throw ToolError("celebrations must be one of: \(CelebrationLevel.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            level = value
        }
        var idle: Int?
        if let value = args.idlePauseMinutes {
            guard AwayPolicy.idleChoices.contains(value) else {
                throw ToolError("idle_pause_minutes must be one of: \(AwayPolicy.idleChoices.map(String.init).joined(separator: ", ")).")
            }
            idle = value
        }

        let touched = focus != nil || short != nil || long != nil || interval != nil
            || args.autoStartBreaks != nil || args.autoStartFocus != nil || goal != nil
            || action != nil || level != nil || args.pauseOnLock != nil || idle != nil
        var stationTouched = false
        if case .keep = args.breakStation {} else { stationTouched = true }
        guard touched || stationTouched else { throw ToolError("Nothing to change.") }

        if let focus { defaults.set(focus, forKey: TimerSettings.Key.focusMinutes) }
        if let short { defaults.set(short, forKey: TimerSettings.Key.shortBreakMinutes) }
        if let long { defaults.set(long, forKey: TimerSettings.Key.longBreakMinutes) }
        if let interval { defaults.set(interval, forKey: TimerSettings.Key.longBreakInterval) }
        if let value = args.autoStartBreaks { defaults.set(value, forKey: TimerSettings.Key.autoStartBreaks) }
        if let value = args.autoStartFocus { defaults.set(value, forKey: TimerSettings.Key.autoStartFocus) }
        if let goal { goalStore.setGoal(goal, now: now()) }
        if let action { defaults.set(action.rawValue, forKey: MusicRules.Key.breakAction) }
        switch args.breakStation {
        case .keep: break
        case .clear: defaults.removeObject(forKey: MusicRules.Key.breakStationID)
        case .set(let id): defaults.set(id, forKey: MusicRules.Key.breakStationID)
        }
        if let level { defaults.set(level.rawValue, forKey: CelebrationLevel.key) }
        if let value = args.pauseOnLock { defaults.set(value, forKey: AwayPolicy.Key.pauseOnLock) }
        if let idle { defaults.set(idle, forKey: AwayPolicy.Key.idleMinutes) }
        return getSettings()
    }
}
