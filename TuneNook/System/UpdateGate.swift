import Foundation

/// Pure timing rules for when update UI may appear. No Sparkle dependency.
struct UpdateGate: Sendable {
    /// "Focus" means the focus phase with the engine active (running or paused).
    static func isFocusing(phase: SessionKind, isActive: Bool) -> Bool {
        phase == .focus && isActive
    }

    private(set) var isHoldingUpdate = false

    /// A scheduled check found an update. Returns true if it may be shown now; otherwise holds it.
    mutating func scheduledUpdateFound(isFocusing: Bool) -> Bool {
        if isFocusing {
            isHoldingUpdate = true
            return false
        }
        return true
    }

    /// Timer state changed. Returns true exactly once when a held update should now be shown.
    mutating func focusChanged(isFocusing: Bool) -> Bool {
        guard isHoldingUpdate, !isFocusing else { return false }
        isHoldingUpdate = false
        return true
    }

    /// The user asked for the update (menu, Settings or notification). Clears any hold.
    mutating func userRequestedUpdate() {
        isHoldingUpdate = false
    }

    /// Whether Sparkle must not relaunch now (install on quit instead).
    static func shouldPostponeRelaunch(isActive: Bool) -> Bool {
        isActive
    }
}
