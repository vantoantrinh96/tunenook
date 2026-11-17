import Observation
import ServiceManagement

/// Opens TuneNook when the user logs in, through the system login items.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var isEnabled = false
    /// The user has to allow it in System Settings → General → Login Items.
    private(set) var needsApproval = false
    private(set) var errorMessage: String?

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
