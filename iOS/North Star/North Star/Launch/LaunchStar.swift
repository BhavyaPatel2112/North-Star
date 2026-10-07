import SwiftUI

/// The opening animation: a star blooms out of the dark, its light travels
/// around it while it twinkles and faint stars appear around it, it flares once,
/// then the picture fades into the sky. Drawn by SkyStar.metal.
///
/// Inspired by Brett McMillin's "Spectral signal through the pane of glass"
/// (Figma Community), as a star in the night sky instead of a ring.
struct LaunchStar: View {
    /// Called when the animation has finished (or was skipped by a tap).
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When the animation's clock started; nil until the shader is ready to draw.
    @State private var start: Date?
    @State private var finished = false

    /// Timings in seconds: bloom, then the light travels, a flare, and the fade into the sky.
    private var total: Double { reduceMotion ? 2.0 : 4.3 }
    private let flareAt = 3.3
    private let fadeOut = 0.7

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(paused: start == nil)) { context in
                let t = time(at: context.date)
                Rectangle()
                    .fill(.black)
                    .colorEffect(ShaderLibrary.skyStar(
                        .float2(geometry.size), .float(t),
                        .float(bloom(t)), .float(orbit(t)), .float(flare(t)), .float(sky(t))),
                                 isEnabled: start != nil)
                    .opacity(1 - leave(t))
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityLabel("North Star")
        .accessibilityAddTraits(.isImage)
        .task {
            // Prepare the shader for the graphics chip first (the first time takes a
            // moment), so the clock only starts once every frame can be drawn.
            _ = try? await ShaderLibrary.skyStar(.float2(CGSize.zero), .float(0), .float(0), .float(0), .float(0), .float(0))
                .compile(as: .colorEffect)
            start = .now
            #if DEBUG
            if UserDefaults.standard.object(forKey: "introAt") != nil { return }  // frozen for screenshots
            #endif
            try? await Task.sleep(for: .seconds(total))
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish()
    }

    /// Seconds since the start. Debug builds can freeze it with "-introAt 2.5" for screenshots.
    private func time(at date: Date) -> Double {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "introAt") != nil { return UserDefaults.standard.double(forKey: "introAt") }
        #endif
        return start.map { date.timeIntervalSince($0) } ?? 0
    }

    // MARK: - Timing curves

    /// The star growing out of a point (0 to 1).
    private func bloom(_ t: Double) -> Double { smooth(t / 0.9) }

    /// Background stars fading in (0 to 1).
    private func sky(_ t: Double) -> Double { smooth((t - 0.3) / 1.2) }

    /// Direction of the travelling light: one and a quarter turns, easing in and out.
    private func orbit(_ t: Double) -> Double {
        if reduceMotion { return -.pi / 3 }
        return -.pi / 2 + smooth(t / (total - 0.4)) * 2.5 * .pi
    }

    /// The final sparkle: a quick bright pulse around flareAt (0 to 1).
    private func flare(_ t: Double) -> Double {
        reduceMotion ? 0 : exp(-pow((t - flareAt) / 0.2, 2))
    }

    /// The whole picture fading out into the sky (0 to 1).
    private func leave(_ t: Double) -> Double { smooth((t - (total - fadeOut)) / fadeOut) }

    private func smooth(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return c * c * (3 - 2 * c)
    }
}

#Preview {
    LaunchStar(onFinish: {})
}
