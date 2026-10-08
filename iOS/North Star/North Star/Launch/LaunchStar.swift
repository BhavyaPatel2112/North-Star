import SwiftUI

/// The opening animation (10 seconds): a star blooms out of the dark, its light
/// travels around it while it twinkles, faint stars appear and the glow slowly
/// builds, it flares once and settles. Then two choices appear: enter the app,
/// or learn why the North Star (the story). Drawn by SkyStar.metal.
///
/// Inspired by Brett McMillin's "Spectral signal through the pane of glass"
/// (Figma Community), as a star in the night sky instead of a ring.
struct LaunchStar: View {
    /// "Enter": go to the app.
    let onEnter: () -> Void
    /// "Why the North Star?": play the story.
    let onStory: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When the animation's clock started; nil until the shader is ready to draw.
    @State private var start: Date?
    /// True once the two buttons are showing (after 10 seconds, or straight away after a tap).
    @State private var showChoices = false

    /// Timings in seconds:
    /// 0 to 2      the star blooms from a point (background stars fade in from 0.8 to 3)
    /// 2 to 8      its light travels around it two and a half times; the glow slowly builds
    /// 8.2         the flare, then the star settles into a calm glow
    /// 10          the two buttons fade in (the light keeps drifting while you choose)
    private var total: Double { reduceMotion ? 2.0 : 10.0 }
    private let flareAt = 8.2

    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geometry in
                TimelineView(.animation(paused: start == nil)) { context in
                    let t = time(at: context.date)
                    Rectangle()
                        .fill(.black)
                        .colorEffect(ShaderLibrary.skyStar(
                            .float2(geometry.size), .float(t),
                            .float(bloom(t)), .float(orbit(t)), .float(flare(t)), .float(sky(t))),
                                     isEnabled: start != nil)
                }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            // A tap during the animation skips straight to the choices.
            .onTapGesture { withAnimation(.easeOut(duration: 0.5)) { showChoices = true } }
            .accessibilityLabel("North Star")
            .accessibilityAddTraits(.isImage)

            choices
                .opacity(showChoices ? 1 : 0)
                .offset(y: showChoices ? 0 : 12)
                .allowsHitTesting(showChoices)
        }
        .task {
            // Prepare the shader for the graphics chip first (the first time takes a
            // moment), so the clock only starts once every frame can be drawn.
            _ = try? await ShaderLibrary.skyStar(.float2(CGSize.zero), .float(0), .float(0), .float(0), .float(0), .float(0))
                .compile(as: .colorEffect)
            start = .now
            #if DEBUG
            if let frozen = UserDefaults.standard.object(forKey: "introAt") as? String, Double(frozen) ?? 0 >= total {
                showChoices = true  // frozen after the end, for screenshots
                return
            }
            if UserDefaults.standard.object(forKey: "introAt") != nil { return }
            #endif
            try? await Task.sleep(for: .seconds(total))
            withAnimation(.easeOut(duration: 0.8)) { showChoices = true }
        }
    }

    /// The wordmark and the two buttons.
    private var choices: some View {
        VStack(spacing: 14) {
            Text("North Star")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Keep going.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.bottom, 18)
            Button(action: onEnter) {
                Text("Enter")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(.black)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
            Button(action: onStory) {
                Text("Why the North Star?")
                    .font(.headline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(.white)
                    .northGlass(in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 36)
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
    private func bloom(_ t: Double) -> Double { smooth(t / (reduceMotion ? 0.9 : 2.0)) }

    /// Background stars fading in (0 to 1).
    private func sky(_ t: Double) -> Double { reduceMotion ? smooth((t - 0.3) / 1.2) : smooth((t - 0.8) / 2.2) }

    /// Direction of the travelling light: two and a half turns, easing in and out,
    /// then a slow drift so the star stays alive while you choose.
    private func orbit(_ t: Double) -> Double {
        if reduceMotion { return -.pi / 3 }
        let settled = total - 0.6
        return -.pi / 2 + smooth(t / settled) * 5 * .pi + max(0, t - settled) * 0.25
    }

    /// Extra glow and longer rays: a slow build from 2 s up to the flare, then the
    /// flare itself, a quick bright pulse at flareAt (0 to 1).
    private func flare(_ t: Double) -> Double {
        if reduceMotion { return 0 }
        let build = 0.22 * smooth((t - 2) / (flareAt - 2.2)) * (1 - smooth((t - flareAt) / 0.4))
        let peak = exp(-pow((t - flareAt) / 0.25, 2))
        return max(build, peak)
    }

    private func smooth(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return c * c * (3 - 2 * c)
    }
}

#Preview {
    LaunchStar(onEnter: {}, onStory: {})
}
