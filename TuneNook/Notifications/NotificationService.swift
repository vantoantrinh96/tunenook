import Foundation
import UserNotifications

/// Schedules the "phase finished" alert ahead of time, so it fires even if the app is throttled.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let requestID = "tunenook.phase-end"

    override init() {
        super.init()
        center.delegate = self
    }

    /// A menu bar app often counts as frontmost, so ask for banners explicitly.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func schedulePhaseEnd(_ kind: SessionKind, at date: Date, taskTitle: String?) {
        cancel()
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return }

        let content = UNMutableNotificationContent()
        switch kind {
        case .focus:
            content.title = "Focus session complete ♪"
            content.body = taskTitle.map { "Nice work on “\($0)”. Time for a break." } ?? "Time for a break."
        case .shortBreak, .longBreak:
            content.title = "Break is over"
            content.body = "Ready for the next focus session?"
        }
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        center.add(UNNotificationRequest(identifier: requestID, content: content, trigger: trigger))
    }

    func notifyGoalReached(streak: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Daily goal reached 🔥"
        content.body = streak > 1 ? "That's a \(streak)-day streak. Keep it going tomorrow!" : "Great start. Come back tomorrow to build a streak."
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "tunenook.goal-reached", content: content, trigger: nil))
    }

    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
    }
}
