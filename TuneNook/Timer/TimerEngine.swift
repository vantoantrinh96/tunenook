import Foundation
import Observation

/// A finished or abandoned phase, handed to the persistence layer.
struct SessionRecord {
    let kind: SessionKind
    let startedAt: Date
    let endedAt: Date
    let completed: Bool
    let task: TodoTask?
}

/// Focus timer state machine. Remaining time is always derived from an end date,
/// so the timer stays correct across sleep, throttling or a closed menu.
@MainActor
@Observable
final class TimerEngine {
    enum Status: Equatable {
        case idle
        case running(endsAt: Date)
        case paused(remaining: TimeInterval)
    }

    private(set) var phase: SessionKind = .focus
    private(set) var status: Status = .idle
    /// Focus sessions completed since the app launched; drives the long-break cycle.
    private(set) var completedFocusCount = 0
    private(set) var now: Date
    var currentTask: TodoTask?

    /// Called whenever a phase ends, completed or not.
    @ObservationIgnored var onSessionEnded: ((SessionRecord) -> Void)?
    /// Called when a phase starts or resumes running, with its end date.
    @ObservationIgnored var onRunningScheduled: ((SessionKind, Date) -> Void)?
    /// Called when a running phase stops before its end date.
    @ObservationIgnored var onRunningCancelled: (() -> Void)?

    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let settingsProvider: () -> TimerSettings
    @ObservationIgnored private var phaseStartedAt: Date?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    init(
        clock: @escaping () -> Date = Date.init,
        settings: @escaping () -> TimerSettings = { TimerSettings.load() }
    ) {
        self.clock = clock
        self.settingsProvider = settings
        self.now = clock()
    }

    // MARK: Derived state

    var settings: TimerSettings { settingsProvider() }

    var remaining: TimeInterval {
        switch status {
        case .idle: settings.duration(of: phase)
        case .running(let endsAt): max(0, endsAt.timeIntervalSince(now))
        case .paused(let remaining): remaining
        }
    }

    var progress: Double {
        let total = settings.duration(of: phase)
        return total > 0 ? 1 - remaining / total : 0
    }

    var isRunning: Bool {
        if case .running = status { true } else { false }
    }

    var isPaused: Bool {
        if case .paused = status { true } else { false }
    }

    var isActive: Bool { status != .idle }

    /// Position inside the current long-break cycle, e.g. 2 of 4.
    var cyclePosition: Int {
        completedFocusCount % settings.longBreakInterval
    }

    // MARK: Controls

    /// Starts the current phase. Passing a task switches the active task.
    func start(task: TodoTask? = nil) {
        if let task { currentTask = task }
        guard status == .idle else { return }
        now = clock()
        phaseStartedAt = now
        run(for: settings.duration(of: phase))
    }

    /// Starts a focus session on `task`, abandoning any phase in progress.
    func startFocus(on task: TodoTask) {
        if isActive { abandon() }
        phase = .focus
        start(task: task)
    }

    func pause() {
        guard case .running(let endsAt) = status else { return }
        now = clock()
        status = .paused(remaining: max(0, endsAt.timeIntervalSince(now)))
        onRunningCancelled?()
    }

    func resume() {
        guard case .paused(let remaining) = status else { return }
        now = clock()
        run(for: remaining)
    }

    func toggle() {
        switch status {
        case .idle: start()
        case .running: pause()
        case .paused: resume()
        }
    }

    /// Stops the current phase without counting it. A stopped break returns to focus.
    func abandon() {
        guard isActive else { return }
        now = clock()
        if isRunning { onRunningCancelled?() }
        emit(completed: false, endedAt: now)
        status = .idle
        if phase.isBreak { phase = .focus }
    }

    /// Ends a break early and moves on to focus.
    func skipBreak() {
        guard phase.isBreak else { return }
        abandon()
        phase = .focus
        status = .idle
        if settings.autoStarts(.focus) { start() }
    }

    // MARK: Ticking

    func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    func tick() {
        now = clock()
        if case .running(let endsAt) = status, now >= endsAt {
            complete(at: endsAt)
        }
    }

    // MARK: Private

    private func run(for duration: TimeInterval) {
        let endsAt = now.addingTimeInterval(duration)
        status = .running(endsAt: endsAt)
        onRunningScheduled?(phase, endsAt)
    }

    private func complete(at endDate: Date) {
        emit(completed: true, endedAt: endDate)
        let settings = self.settings
        let next: SessionKind
        if phase == .focus {
            completedFocusCount += 1
            next = completedFocusCount % settings.longBreakInterval == 0 ? .longBreak : .shortBreak
        } else {
            next = .focus
        }
        phase = next
        status = .idle
        if settings.autoStarts(next) {
            phaseStartedAt = endDate
            now = max(now, endDate)
            // The next phase starts when the previous one ended, so time spent asleep still counts.
            let endsAt = endDate.addingTimeInterval(settings.duration(of: next))
            status = .running(endsAt: endsAt)
            onRunningScheduled?(next, endsAt)
            tick()
        }
    }

    private func emit(completed: Bool, endedAt: Date) {
        let record = SessionRecord(
            kind: phase,
            startedAt: phaseStartedAt ?? endedAt,
            endedAt: endedAt,
            completed: completed,
            task: phase == .focus ? currentTask : nil
        )
        phaseStartedAt = nil
        onSessionEnded?(record)
    }
}
