import SwiftUI

/// The opening animation: a glowing star on black, with a bright rainbow
/// highlight sweeping once around its edge, seen through a pane of textured
/// glass (GlassPane.metal). Then it fades into the sky.
///
/// Inspired by Brett McMillin's "Spectral signal through the pane of glass"
/// (Figma Community), with a star in place of the ring.
struct LaunchStar: View {
    /// Called when the animation has finished (or was skipped by a tap).
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When the animation's clock started; nil until the glass effect is ready to draw.
    @State private var start: Date?
    @State private var finished = false

    /// The glass: cells 3 points across, each bending the light up to 4 points.
    private static let glass = ShaderLibrary.glassPane(.float(3), .float(8))

    /// Timings in seconds.
    private let fadeIn = 0.45
    private let total = 2.2
    private let fadeOut = 0.5

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { context in
            let t = start.map { context.date.timeIntervalSince($0) } ?? 0
            ZStack {
                Color.black
                if start != nil {
                    StarGlow(sweep: reduceMotion ? 0.62 : progress(t), strength: appear(t))
                        .frame(width: 240, height: 240)
                        .scaleEffect(1 + 0.12 * leave(t))
                }
            }
            .layerEffect(Self.glass, maxSampleOffset: CGSize(width: 8, height: 8), isEnabled: start != nil)
            .opacity(1 - leave(t))
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityLabel("North Star")
        .accessibilityAddTraits(.isImage)
        .task {
            // Prepare the glass effect for the graphics chip first (the first time takes
            // a moment), so the clock only starts once every frame can be drawn.
            _ = try? await Self.glass.compile(as: .layerEffect)
            start = .now
            try? await Task.sleep(for: .seconds(total))
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish()
    }

    // MARK: - Timing curves (each 0 to 1)

    /// The star fading in.
    private func appear(_ t: Double) -> Double { smooth(t / fadeIn) }

    /// How far round the star the highlight has travelled (one turn, easing out).
    private func progress(_ t: Double) -> Double {
        let x = min(1, max(0, t / (total - fadeOut * 0.5)))
        return 0.15 + (1 - pow(1 - x, 2.2)) * 1.0
    }

    /// The whole picture fading out into the sky.
    private func leave(_ t: Double) -> Double { smooth((t - (total - fadeOut)) / fadeOut) }

    private func smooth(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return c * c * (3 - 2 * c)
    }
}

/// The glowing star. A dim glow all round, plus a bright highlight with
/// rainbow edges at `sweep` (0 to 1, the share of one turn round the star).
private struct StarGlow: View {
    let sweep: Double
    let strength: Double

    /// The highlight: transparent most of the way round, then violet, pink,
    /// white-hot, amber and cyan, like light split by a prism.
    private var highlight: AngularGradient {
        AngularGradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: .clear, location: 0.48),
            .init(color: Color(red: 0.45, green: 0.35, blue: 1.0).opacity(0.7), location: 0.62),
            .init(color: Color(red: 1.0, green: 0.55, blue: 0.85), location: 0.72),
            .init(color: .white, location: 0.8),
            .init(color: Color(red: 1.0, green: 0.8, blue: 0.45), location: 0.87),
            .init(color: Color(red: 0.45, green: 0.9, blue: 1.0).opacity(0.6), location: 0.94),
            .init(color: .clear, location: 1.0),
        ], center: .center, angle: .degrees(sweep * 360))
    }

    var body: some View {
        ZStack {
            // Faint outline so the whole star always reads.
            StarShape()
                .stroke(.white.opacity(0.16), style: StrokeStyle(lineWidth: 10, lineJoin: .round))
                .blur(radius: 6)
            // Wide soft glow of the highlight...
            StarShape()
                .stroke(highlight, style: StrokeStyle(lineWidth: 26, lineJoin: .round))
                .blur(radius: 16)
            // ...its coloured edge...
            StarShape()
                .stroke(highlight, style: StrokeStyle(lineWidth: 8, lineJoin: .round))
                .blur(radius: 2)
            // ...and a white-hot centre line where the highlight is brightest.
            StarShape()
                .stroke(highlight, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                .brightness(0.35)
                .blendMode(.plusLighter)
        }
        .compositingGroup()
        .opacity(strength)
    }
}

/// A five-pointed star, point up, filling its frame.
struct StarShape: Shape {
    /// Inner corners as a share of the outer radius (0.45 gives a classic star).
    var innerRatio: Double = 0.45

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.04)  // optically centred
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        var path = Path()
        for i in 0..<10 {
            let radius = i.isMultiple(of: 2) ? outer : inner
            let angle = Double(i) * .pi / 5 - .pi / 2
            let point = CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

#Preview {
    LaunchStar(onFinish: {})
}
