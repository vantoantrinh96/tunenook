import SwiftUI

struct MenuBarLabel: View {
    let engine: TimerEngine
    let rewards: RewardStore

    var body: some View {
        if engine.isActive {
            HStack(spacing: 4) {
                Image(systemName: engine.phase.isBreak ? "cup.and.saucer.fill" : rewards.selectedIcon.symbol)
                Text("\(engine.remaining.clockString)\(engine.isPaused ? " ⏸" : "")")
                    .monospacedDigit()
            }
        } else {
            Image(systemName: rewards.selectedIcon.symbol)
        }
    }
}
