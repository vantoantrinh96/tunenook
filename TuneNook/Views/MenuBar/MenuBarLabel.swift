import SwiftUI

struct MenuBarLabel: View {
    let engine: TimerEngine

    var body: some View {
        if engine.isActive {
            Text("\(engine.phase.emoji) \(engine.remaining.clockString)\(engine.isPaused ? " ⏸" : "")")
                .monospacedDigit()
        } else {
            Image(systemName: "timer")
        }
    }
}
