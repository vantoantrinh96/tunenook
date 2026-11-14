import SwiftUI

extension TimeInterval {
    /// "mm:ss", rounding up so the display never shows 00:00 while time remains.
    var clockString: String {
        let total = Int(self.rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

extension SessionKind {
    var tint: Color {
        switch self {
        case .focus: Color(hex: "#E5533D")
        case .shortBreak: Color(hex: "#43AA8B")
        case .longBreak: Color(hex: "#4D8FD6")
        }
    }

    var emoji: String { self == .focus ? "🍅" : "☕️" }
}

/// "🍅 2/4" — actual vs estimated pomodoros, red when over the estimate.
struct PomodoroBadge: View {
    let actual: Int
    let estimated: Int

    var body: some View {
        Text("🍅 \(actual)/\(estimated)")
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(actual > estimated ? Color.red : Color.secondary)
            .help("\(actual) done of \(estimated) estimated")
    }
}
