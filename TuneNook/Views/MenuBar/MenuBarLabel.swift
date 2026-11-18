import AppKit
import SwiftUI

struct MenuBarLabel: View {
    let engine: TimerEngine
    let rewards: RewardStore
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if engine.isActive {
            // MenuBarExtra ignores font modifiers on its label, so `.monospacedDigit()`
            // has no effect there and the status item jitters as the digits change.
            // Rendering the label to a template image keeps the tabular digits.
            if let image = renderedActiveLabel() {
                Image(nsImage: image)
            } else {
                Text(activeText)
            }
        } else {
            Image(systemName: rewards.selectedIcon.symbol)
        }
    }

    private var activeText: String {
        "\(engine.remaining.clockString)\(engine.isPaused ? " ⏸" : "")"
    }

    private func renderedActiveLabel() -> NSImage? {
        let content = HStack(spacing: 4) {
            Image(systemName: engine.phase.isBreak ? "cup.and.saucer.fill" : rewards.selectedIcon.symbol)
            Text(activeText)
                .monospacedDigit()
        }
        .font(.system(size: NSFont.systemFontSize))
        .foregroundStyle(.black)

        let renderer = ImageRenderer(content: content)
        renderer.scale = max(displayScale, 2)
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }
}
