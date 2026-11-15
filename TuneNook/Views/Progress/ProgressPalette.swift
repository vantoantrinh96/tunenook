import AppKit
import SwiftUI

/// Sequential blue ramp for progress visuals, stepped separately for light and dark.
/// Validated as an ordinal ramp (monotone lightness, light end ≥ 2:1 against the surface).
enum ProgressPalette {
    /// Heatmap levels 1...4. Level 0 (no focus) uses `empty`.
    static let levels: [Color] = [
        adaptive(light: "#86b6ef", dark: "#184f95"),
        adaptive(light: "#3987e5", dark: "#2a78d6"),
        adaptive(light: "#1c5cab", dark: "#6da7ec"),
        adaptive(light: "#0d366b", dark: "#b7d3f6"),
    ]

    static let empty = Color.secondary.opacity(0.15)
    static let accent = adaptive(light: "#2a78d6", dark: "#6da7ec")

    static func color(forLevel level: Int) -> Color {
        level <= 0 ? empty : levels[min(level, levels.count) - 1]
    }

    private static func adaptive(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }
}

/// Small ring showing today's progress toward the daily goal.
struct GoalRing: View {
    let progress: Double
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle()
                .stroke(ProgressPalette.empty, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(ProgressPalette.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if progress >= 1 {
                Image(systemName: "checkmark")
                    .font(.system(size: lineWidth * 2.4, weight: .bold))
                    .foregroundStyle(ProgressPalette.accent)
            }
        }
        .animation(.easeOut, value: progress)
    }
}

extension TimeInterval {
    /// "2h 05m" or "45m".
    var hoursMinutes: String {
        let minutes = Int(self / 60)
        return minutes >= 60 ? String(format: "%dh %02dm", minutes / 60, minutes % 60) : "\(minutes)m"
    }
}
