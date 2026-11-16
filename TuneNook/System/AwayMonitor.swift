import AppKit
import CoreGraphics
import Foundation

/// When the user steps away, how to treat a running focus session.
struct AwayPolicy: Equatable, Sendable {
    var pauseOnLock = true
    /// 0 turns idle detection off.
    var idleMinutes = 0

    enum Key {
        static let pauseOnLock = "away.pauseOnLock"
        static let idleMinutes = "away.idleMinutes"
    }

    static let idleChoices = [0, 2, 5, 10, 15]

    static func load(from defaults: UserDefaults = .standard) -> AwayPolicy {
        var policy = AwayPolicy()
        if let value = defaults.object(forKey: Key.pauseOnLock) as? Bool { policy.pauseOnLock = value }
        policy.idleMinutes = defaults.integer(forKey: Key.idleMinutes)
        return policy
    }

    /// When the session should be paused as of, given how long there's been no input. Nil keeps it running.
    func idlePauseDate(idleSeconds: TimeInterval, now: Date) -> Date? {
        guard idleMinutes > 0, idleSeconds >= Double(idleMinutes) * 60 else { return nil }
        return now.addingTimeInterval(-idleSeconds)
    }
}

/// Pauses focus when the Mac locks, sleeps or sits idle, and says so when the user is back.
@MainActor
final class AwayMonitor {
    private let engine: TimerEngine
    private let notifications: NotificationService
    private let policy: () -> AwayPolicy
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var idleTask: Task<Void, Never>?
    /// True while a pause we made is waiting for the user to come back.
    private var pausedByAway = false

    init(
        engine: TimerEngine,
        notifications: NotificationService,
        policy: @escaping () -> AwayPolicy = { AwayPolicy.load() }
    ) {
        self.engine = engine
        self.notifications = notifications
        self.policy = policy
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name) { $0.lockedOrAsleep() }
        }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.lockedOrAsleep() }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name) { $0.returned() }
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.returned() }

        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.checkIdle()
            }
        }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ handler: @escaping @Sendable @MainActor (AwayMonitor) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    private var isFocusing: Bool {
        engine.phase == .focus && engine.isRunning
    }

    private func lockedOrAsleep() {
        guard policy().pauseOnLock, isFocusing else { return }
        engine.pause()
        pausedByAway = true
    }

    private func checkIdle() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if isFocusing, let date = policy().idlePauseDate(idleSeconds: idle, now: .now) {
            engine.pause(asOf: date)
            pausedByAway = true
        } else if pausedByAway, idle < 15 {
            returned()
        }
    }

    private func returned() {
        guard pausedByAway else { return }
        pausedByAway = false
        if engine.isPaused && engine.phase == .focus {
            notifications.notifyPausedWhileAway(remaining: engine.remaining)
        }
    }
}
