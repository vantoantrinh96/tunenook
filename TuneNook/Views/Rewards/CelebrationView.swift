import SwiftUI

/// The card and confetti shown in the celebration overlay.
struct CelebrationView: View {
    let celebration: Celebration
    var reduceMotion = false
    /// Fixed start time keeps rendering deterministic in previews and tests.
    var startDate = Date()

    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .top) {
            if celebration.isMilestone && !reduceMotion {
                ConfettiView(startDate: startDate, origin: UnitPoint(x: 0.5, y: 0.14))
            }
            card
                .padding(.top, 24)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.85)
                .opacity(appeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.65)) {
                appeared = true
            }
        }
    }

    private var card: some View {
        HStack(spacing: 14) {
            Image(systemName: celebration.symbol)
                .font(.system(size: celebration.isMilestone ? 26 : 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: celebration.isMilestone ? 52 : 38, height: celebration.isMilestone ? 52 : 38)
                .background(Celebration.accent.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(celebration.title)
                    .font(celebration.isMilestone ? .title3.weight(.semibold) : .headline)
                Text(celebration.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
    }
}

extension Celebration {
    static let accent = Color(hex: "#E5533D")
}

/// A one-shot burst of confetti and notes, drawn from a fixed seed.
struct ConfettiView: View {
    let startDate: Date
    let origin: UnitPoint
    var lifetime: TimeInterval = 3.2

    private let particles = (0..<70).map(Particle.init)

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSince(startDate)
                guard t >= 0, t < lifetime else { return }
                let start = CGPoint(x: origin.x * size.width, y: origin.y * size.height)
                for particle in particles {
                    particle.draw(in: &context, from: start, at: t, lifetime: lifetime)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    struct Particle {
        static let colors: [Color] = [
            Color(hex: "#E5533D"), Color(hex: "#F5A623"), Color(hex: "#2BB5A0"),
            Color(hex: "#3987E5"), Color(hex: "#8E5BD9"), Color(hex: "#F06BA8"),
        ]

        let velocity: CGVector
        let spin: Double
        let size: CGFloat
        let color: Color
        let isNote: Bool

        init(_ index: Int) {
            // Cheap deterministic pseudo-random values from the index.
            func rand(_ salt: Int) -> Double {
                let x = sin(Double(index * 97 + salt * 31) * 12.9898) * 43758.5453
                return x - x.rounded(.down)
            }
            let angle = -Double.pi / 2 + (rand(1) - 0.5) * 2.4
            let speed = 220 + rand(2) * 260
            velocity = CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed)
            spin = (rand(3) - 0.5) * 14
            size = 5 + rand(4) * 5
            color = Self.colors[index % Self.colors.count]
            isNote = index % 9 == 0
        }

        func draw(in context: inout GraphicsContext, from start: CGPoint, at t: TimeInterval, lifetime: TimeInterval) {
            let gravity = 520.0
            let drag = 0.9
            let x = start.x + velocity.dx * t * drag
            let y = start.y + velocity.dy * t + 0.5 * gravity * t * t
            let fade = min(1, max(0, (lifetime - t) / 0.8))
            var ctx = context
            ctx.opacity = fade
            ctx.translateBy(x: x, y: y)
            ctx.rotate(by: .radians(spin * t))
            if isNote {
                ctx.draw(Text("♪").font(.system(size: size * 2.4, weight: .bold)).foregroundStyle(color), at: .zero)
            } else {
                let rect = CGRect(x: -size / 2, y: -size / 4, width: size, height: size / 2)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
            }
        }
    }
}
