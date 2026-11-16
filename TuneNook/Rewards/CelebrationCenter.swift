import AppKit
import SwiftUI

/// Shows celebrations one at a time in a click-through overlay near the top of the screen.
@MainActor
final class CelebrationCenter {
    private var queue: [Celebration] = []
    private var panel: NSPanel?
    private var isShowing = false

    private static let size = CGSize(width: 560, height: 420)

    /// Queues the celebrations the user's preference allows.
    func celebrate(_ celebrations: [Celebration], level: CelebrationLevel = .current) {
        queue += celebrations.filter(level.allows)
        showNextIfIdle()
    }

    private func showNextIfIdle() {
        guard !isShowing, !queue.isEmpty else { return }
        let celebration = queue.removeFirst()
        isShowing = true

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: CelebrationView(celebration: celebration, reduceMotion: reduceMotion))
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let duration: Duration = celebration.isMilestone ? .seconds(3.6) : .seconds(2.4)
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            await self?.dismiss(panel)
        }
    }

    private func dismiss(_ panel: NSPanel) async {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: nil)
        try? await Task.sleep(for: .milliseconds(300))
        panel.orderOut(nil)
        panel.contentView = nil
        isShowing = false
        showNextIfIdle()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let origin = CGPoint(
            x: visible.midX - Self.size.width / 2,
            y: visible.maxY - Self.size.height
        )
        panel.setFrame(CGRect(origin: origin, size: Self.size), display: false)
    }
}
