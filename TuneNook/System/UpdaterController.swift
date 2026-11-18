import Foundation
import Observation
import Sparkle

/// Owns Sparkle's updater and applies TuneNook's timing rules (`UpdateGate`):
/// no update window during focus, and no relaunch over an active session.
@MainActor
@Observable
final class UpdaterController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let engine: TimerEngine
    @ObservationIgnored private let notifications: NotificationService
    @ObservationIgnored private var gate = UpdateGate()
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    /// Sparkle's install-and-relaunch block, kept while a session is active. Never invoked here:
    /// the update installs when the app quits.
    @ObservationIgnored private var postponedInstall: (() -> Void)?

    init(engine: TimerEngine, notifications: NotificationService) {
        self.engine = engine
        self.notifications = notifications
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
        notifications.onShowUpdateRequested = { [weak self] in self?.checkForUpdates() }
        observeFocus()
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get {
            access(keyPath: \.automaticallyDownloadsUpdates)
            return controller.updater.automaticallyDownloadsUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyDownloadsUpdates) {
                controller.updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    /// For example "0.7.0 (7)".
    var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// A user-initiated check. Also brings forward an update held during focus.
    func checkForUpdates() {
        gate.userRequestedUpdate()
        controller.updater.checkForUpdates()
    }

    // MARK: - Focus tracking

    private var isFocusing: Bool {
        UpdateGate.isFocusing(phase: engine.phase, isActive: engine.isActive)
    }

    /// Re-registers after every change, since `withObservationTracking` fires only once.
    private func observeFocus() {
        withObservationTracking {
            _ = engine.phase
            _ = engine.isActive
        } onChange: { [weak self] in
            // Runs before the new value is stored, so read it on the next main-actor turn.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if gate.focusChanged(isFocusing: isFocusing) {
                    checkForUpdates()
                }
                observeFocus()
            }
        }
    }

    // MARK: - SPUUpdaterDelegate

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard UpdateGate.shouldPostponeRelaunch(isActive: engine.isActive) else { return false }
        postponedInstall = installHandler
        notifications.notifyUpdateOnQuit(version: item.displayVersionString)
        return true
    }

    // MARK: - SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        MainActor.assumeIsolated {
            gate.scheduledUpdateFound(isFocusing: isFocusing)
        }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            notifications.notifyUpdateAvailable(version: version)
        }
    }
}
