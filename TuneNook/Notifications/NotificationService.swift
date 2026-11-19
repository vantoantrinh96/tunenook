import Foundation
import UserNotifications

/// Schedules the "phase finished" alert ahead of time, so it fires even if the app is throttled.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let requestID = "tunenook.phase-end"
    private nonisolated static let awayCategory = "tunenook.away"
    private nonisolated static let resumeAction = "resume"
    private nonisolated static let updateID = "tunenook.update"

    /// Called when the user taps "Resume Focus" on the away notification.
    var onResumeRequested: (() -> Void)?

    /// Called when the user clicks the "update available" notification.
    var onShowUpdateRequested: (() -> Void)?

    override init() {
        super.init()
        center.delegate = self
        let resume = UNNotificationAction(identifier: Self.resumeAction, title: "Resume Focus", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.awayCategory, actions: [resume], intentIdentifiers: []),
        ])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if response.actionIdentifier == Self.resumeAction {
            await MainActor.run { self.onResumeRequested?() }
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                  response.notification.request.identifier == Self.updateID {
            await MainActor.run { self.onShowUpdateRequested?() }
        }
    }

    /// A menu bar app often counts as frontmost, so ask for banners explicitly.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func requestAuthorization() {
        // The reply comes on a background queue. Without @Sendable, older SDKs make this closure
        // main-actor isolated and Swift 6 traps when it runs off the main thread.
        center.requestAuthorization(options: [.alert, .sound]) { @Sendable _, _ in }
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

    /// Another Mac deleted the task the running session is for.
    func notifyTaskDeletedElsewhere(taskTitle: String) {
        let content = UNMutableNotificationContent()
        content.title = "Task deleted on another Mac"
        content.body = "“\(taskTitle)” was deleted on another Mac. Your session keeps running without a task."
        center.add(UNNotificationRequest(identifier: "tunenook.task-deleted", content: content, trigger: nil))
    }

    /// Tells the user focus was paused while they were away, with a button to resume.
    func notifyPausedWhileAway(remaining: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Focus paused while you were away"
        content.body = "\(remaining.clockString) left. Resume when you're ready."
        content.categoryIdentifier = Self.awayCategory
        center.add(UNNotificationRequest(identifier: "tunenook.away", content: content, trigger: nil))
    }

    /// A scheduled check found an update while the user was focusing.
    func notifyUpdateAvailable(version: String) {
        let content = UNMutableNotificationContent()
        content.title = String(format: "TuneNook %@ is available", version)
        center.add(UNNotificationRequest(identifier: Self.updateID, content: content, trigger: nil))
    }

    /// The update is being shown, so the "available" notification is stale.
    func clearUpdateAvailable() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.updateID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.updateID])
    }

    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
    }
}
