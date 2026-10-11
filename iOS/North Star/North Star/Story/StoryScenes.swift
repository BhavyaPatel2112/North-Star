import SwiftUI

// The seven scenes of "Why the North Star?". Each sets `ready` once its small
// action is done, which shows the Continue button (see StoryView).

// MARK: - 1. The still star

/// A night sky turning around one star. Dragging spins the sky: every star moves
/// in a circle except the North Star, which holds its place (true of Polaris).
struct StillStarScene: View {
    @Binding var ready: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now
    @State private var spun: Double = 0
    @State private var dragStartSpin: Double?
    @State private var turned = false

    var body: some View {
        StoryStage { size in
            let pole = CGPoint(x: size.width * 0.5, y: size.height * 0.45)
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSince(start)
                ZStack {
                    LinearGradient(colors: [Color(red: 0.01, green: 0.02, blue: 0.06), Color(red: 0.06, green: 0.09, blue: 0.18)],
                                   startPoint: .top, endPoint: .bottom)
                    StarTrails(rotation: (reduceMotion ? 0 : elapsed * 0.06) + spun, pole: pole)
                    NorthStarGlint(opacity: 1, size: 74).position(pole)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture()
                .onChanged { value in
                    if dragStartSpin == nil { dragStartSpin = spun }
                    spun = dragStartSpin! + Double(value.translation.width) / 140
                    if abs(spun) > 1.0, !turned {
                        withAnimation { turned = true }
                        ready = true
                    }
                }
                .onEnded { _ in dragStartSpin = nil })
        } words: {
            if turned {
                StoryCaption(first: "While the whole sky turns,", second: "it stays still.")
            } else {
                StoryCaption(first: "For thousands of years,", second: "travellers found their way by one star.",
                             hint: "Drag to turn the sky")
            }
        }
    }
}

/// Stars circling a pole, each with a short trail like a long-exposure photo.
private struct StarTrails: View {
    let rotation: Double
    let pole: CGPoint

    private struct Star { let radius, angle, size, brightness: Double }

    private static let stars: [Star] = {
        var seed: UInt64 = 9
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        return (0..<320).map { _ in
            Star(radius: 0.06 + sqrt(random()) * 1.1, angle: random() * 2 * .pi,
                 size: 0.6 + random() * 1.4, brightness: 0.25 + random() * 0.75)
        }
    }()

    var body: some View {
        Canvas { ctx, size in
            let reach = max(size.width, size.height)
            for star in Self.stars {
                let r = star.radius * reach
                let a = star.angle + rotation
                var trail = Path()
                trail.addArc(center: pole, radius: r, startAngle: .radians(a - 0.32), endAngle: .radians(a), clockwise: false)
                ctx.stroke(trail, with: .color(.white.opacity(star.brightness * 0.28)),
                           style: StrokeStyle(lineWidth: star.size * 0.7, lineCap: .round))
                let point = CGPoint(x: pole.x + cos(a) * r, y: pole.y + sin(a) * r)
                ctx.fill(Path(ellipseIn: CGRect(x: point.x - star.size / 2, y: point.y - star.size / 2,
                                                width: star.size, height: star.size)),
                         with: .color(.white.opacity(star.brightness)))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 2. Your North Star

/// The traveller alone on the snowy shore under the night sky. Tapping the star
/// draws a faint line from them to it.
struct YourStarScene: View {
    @Binding var ready: Bool
    @State private var linked = false
    @State private var line: CGFloat = 0
    @State private var pulse = false

    var body: some View {
        StoryStage { size in
            let traveller = travellerSpot(in: size)
            let star = CGPoint(x: size.width * 0.64, y: size.height * 0.115)
            ZStack {
                Landscape(palette: LandscapePalette(pm25: 10, hourOfDay: 22), showsTraveller: false)
                Path { p in
                    p.move(to: CGPoint(x: traveller.x + 4, y: traveller.y - 14))
                    p.addLine(to: star)
                }
                .trim(from: 0, to: line)
                .stroke(Theme.star.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 6]))
                TinyTraveller(height: 34).position(traveller)
                // An invitation to tap: a soft ring breathing around the star.
                if !linked {
                    Circle()
                        .stroke(.white.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 54, height: 54)
                        .scaleEffect(pulse ? 1.35 : 0.9)
                        .opacity(pulse ? 0 : 0.8)
                        .position(star)
                        .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true } }
                }
                Circle().fill(.clear).frame(width: 96, height: 96).contentShape(Circle())
                    .position(star)
                    .onTapGesture {
                        guard !linked else { return }
                        withAnimation(.easeInOut(duration: 1.4)) { line = 1 }
                        withAnimation(.easeInOut(duration: 0.5)) { linked = true }
                        ready = true
                    }
                    .accessibilityLabel("The North Star")
                    .accessibilityAddTraits(.isButton)
            }
        } words: {
            if linked {
                StoryCaption(first: "Everyone has one.",
                             second: "The runner you are becoming: stronger, healthier, calmer.")
            } else {
                StoryCaption(first: "Everyone has one.", second: "A North Star of their own.", hint: "Tap the star")
            }
        }
    }
}

/// Where the traveller stands on the landscape's snowy shore.
private func travellerSpot(in size: CGSize) -> CGPoint {
    CGPoint(x: size.width * 0.27, y: size.height * Ridge.shore.y(at: 0.27) - 15)
}

// MARK: - 3. The road, in any weather

/// A vast snowfield at dusk with blowing snow. Press and hold to walk: the
/// traveller walks, marker poles and drifts slide past, and the distance grows.
struct LongRoadScene: View {
    @Binding var ready: Bool
    @State private var holding = false
    @State private var walked: Double = 0   // seconds of walking
    @State private var startedTime = Date.now

    var body: some View {
        StoryStage { size in
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSince(startedTime)
                let scroll = walked * 70
                let weather = Weather.at(walked)
                ZStack {
                    LinearGradient(colors: weather.sky, startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.64))
                        .animation(.easeInOut(duration: 1.2), value: weather)
                    Canvas { ctx, s in drawRoad(ctx: &ctx, size: s, scroll: scroll, time: t, weather: weather) }
                    TinyTraveller(walking: holding, colour: Color(red: 0.10, green: 0.13, blue: 0.20), height: 40)
                        .position(x: size.width * 0.42, y: size.height * 0.64 - 18)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !holding { holding = true } }
                .onEnded { _ in holding = false })
            .task(id: holding) {
                guard holding else { return }
                var last = Date.now
                while !Task.isCancelled && holding {
                    try? await Task.sleep(for: .milliseconds(16))
                    let now = Date.now
                    walked += now.timeIntervalSince(last)
                    last = now
                    if walked > Self.weatherSeconds * 3 && !ready { ready = true }
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: Int(walked * 2))
        } words: {
            let km = String(format: "%.1f km", walked * 0.12)
            if walked > Self.weatherSeconds * 3 {
                StoryCaption(first: "Heat, rain, haze or cold.",
                             second: "North Star finds the best way for today: the route, the time, the stops.", hint: km)
            } else {
                StoryCaption(first: "The road is long,", second: "and the weather never asks first.",
                             hint: walked > 0 ? "\(Weather.at(walked).name) · \(km)" : "Press and hold to run")
            }
        }
    }

    /// Seconds of running in each kind of weather.
    static let weatherSeconds = 1.6

    /// The weather changes as you run: snow, then rain, then heat, then haze.
    enum Weather: Equatable {
        case snow, rain, heat, haze

        static func at(_ walked: Double) -> Weather {
            switch Int(walked / weatherSeconds) {
            case 0: .snow
            case 1: .rain
            case 2: .heat
            default: .haze
            }
        }

        var name: String {
            switch self {
            case .snow: "Cold"
            case .rain: "Rain"
            case .heat: "Heat"
            case .haze: "Haze"
            }
        }

        var sky: [Color] {
            switch self {
            case .snow: [Color(red: 0.08, green: 0.11, blue: 0.22), Color(red: 0.42, green: 0.47, blue: 0.60)]
            case .rain: [Color(red: 0.10, green: 0.13, blue: 0.18), Color(red: 0.30, green: 0.36, blue: 0.44)]
            case .heat: [Color(red: 0.55, green: 0.36, blue: 0.30), Color(red: 0.93, green: 0.70, blue: 0.48)]
            case .haze: [Color(red: 0.42, green: 0.42, blue: 0.44), Color(red: 0.70, green: 0.69, blue: 0.66)]
            }
        }
    }

    /// The far hills, the ground, drifts and marker poles sliding past, and the weather.
    private func drawRoad(ctx: inout GraphicsContext, size: CGSize, scroll: Double, time t: Double, weather: Weather) {
        let ground = size.height * 0.64
        // Far low hills.
        let hills = Ridge(seed: 19, roughness: 0.55, base: 0.645, amplitude: 0.08, peaks: [(0.7, 0.6, 0.2)])
        var hillPath = Path()
        hillPath.move(to: CGPoint(x: 0, y: ground))
        for i in 0..<hills.heights.count {
            let x = Double(i) / Double(hills.heights.count - 1)
            hillPath.addLine(to: CGPoint(x: x * size.width, y: hills.y(at: x) * size.height))
        }
        hillPath.addLine(to: CGPoint(x: size.width, y: ground))
        ctx.fill(hillPath, with: .color(Color(red: 0.30, green: 0.35, blue: 0.48)))
        // Snow.
        ctx.fill(Path(CGRect(x: 0, y: ground, width: size.width, height: size.height - ground)),
                 with: .linearGradient(Gradient(colors: [Color(red: 0.80, green: 0.84, blue: 0.91), Color(red: 0.58, green: 0.65, blue: 0.77)]),
                                       startPoint: CGPoint(x: 0, y: ground), endPoint: CGPoint(x: 0, y: size.height)))
        // Drifts: rows nearer the bottom move faster (closer to you).
        for (row, y) in [0.70, 0.78, 0.88].enumerated() {
            let speed = 0.6 + Double(row) * 0.5
            let spacing = 140.0 + Double(row) * 40
            var x = -((scroll * speed).truncatingRemainder(dividingBy: spacing))
            while x < size.width {
                var drift = Path()
                drift.move(to: CGPoint(x: x, y: y * size.height))
                drift.addQuadCurve(to: CGPoint(x: x + 70, y: y * size.height),
                                   control: CGPoint(x: x + 35, y: y * size.height - 4))
                ctx.stroke(drift, with: .color(.white.opacity(0.45)), lineWidth: 1.2)
                x += spacing
            }
        }
        // Marker poles along the route, every 260 points.
        var pole = -(scroll.truncatingRemainder(dividingBy: 260)) + 60
        while pole < size.width + 20 {
            ctx.fill(Path(CGRect(x: pole, y: ground - 26, width: 2, height: 28)), with: .color(Color(red: 0.15, green: 0.18, blue: 0.26)))
            var flag = Path()
            flag.move(to: CGPoint(x: pole + 2, y: ground - 26))
            flag.addLine(to: CGPoint(x: pole + 12, y: ground - 22))
            flag.addLine(to: CGPoint(x: pole + 2, y: ground - 18))
            ctx.fill(flag, with: .color(Theme.star))
            pole += 260
        }
        // The weather: blowing snow, falling rain, a hot sun, or a veil of haze.
        if weather == .heat {
            let sun = CGRect(x: size.width * 0.72, y: size.height * 0.12, width: 46, height: 46)
            ctx.fill(Path(ellipseIn: sun.insetBy(dx: -30, dy: -30)), with: .color(Color(red: 1, green: 0.85, blue: 0.55).opacity(0.25)))
            ctx.fill(Path(ellipseIn: sun), with: .color(Color(red: 1, green: 0.93, blue: 0.75)))
            return
        }
        if weather == .haze {
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.75, green: 0.73, blue: 0.68).opacity(0.45)))
            return
        }
        var seed: UInt64 = 3
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        for _ in 0..<90 {
            let speed = 40 + random() * 70
            if weather == .rain {
                // Rain falls fast and nearly straight down, as short streaks.
                let x = (random() * size.width - scroll * 0.4).truncatingRemainder(dividingBy: size.width)
                let y = (random() * size.height + t * speed * 6).truncatingRemainder(dividingBy: size.height)
                var streak = Path()
                let start = CGPoint(x: x < 0 ? x + size.width : x, y: y)
                streak.move(to: start)
                streak.addLine(to: CGPoint(x: start.x - 2, y: start.y + 12))
                ctx.stroke(streak, with: .color(.white.opacity(0.35)), lineWidth: 1)
                continue
            }
            let x = (random() * size.width - t * speed - scroll * 0.4).truncatingRemainder(dividingBy: size.width)
            let y = (random() * size.height + t * speed * 0.35).truncatingRemainder(dividingBy: size.height)
            let r = 0.8 + random() * 1.6
            ctx.fill(Path(ellipseIn: CGRect(x: x < 0 ? x + size.width : x, y: y, width: r, height: r)),
                     with: .color(.white.opacity(0.35 + random() * 0.4)))
        }
    }
}

// MARK: - 4. The climb

/// The whole journey on one screen: the traveller walks from the plains to the
/// summit as the kilometres add up, the trail turning gold behind them.
struct ClimbScene: View {
    @Binding var ready: Bool
    @State private var start = Date.now
    /// Your goal once set; before that, 500 km as an example.
    @AppStorage(JourneyGoal.kmKey) private var goal: Double = 0
    private var shownGoal: Double { goal > 0 ? goal : 500 }

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(start)
            let share = min(1, max(0, (elapsed - 0.6) / 5.5))
            let km = shownGoal * share * share * (3 - 2 * share)
            StoryStage { size in
                JourneyMap(kilometres: km, goal: shownGoal, size: size, compact: true, walking: share < 1)
            } words: {
                StoryCaption(first: "Every run moves you forward.",
                             second: "Your journey keeps count, from the plains to the summit.",
                             hint: "\(Int(km).formatted()) of \(Int(shownGoal).formatted()) km")
            }
            .onChange(of: share >= 1) { _, done in if done { ready = true } }
        }
    }
}

// MARK: - 5. The summit

/// The traveller on the summit under the North Star, drawn by the same shader
/// as the opening star.
struct SummitScene: View {
    @Binding var ready: Bool
    @State private var start = Date.now

    private static let summit = Ridge(seed: 5, roughness: 0.62, base: 1.02, amplitude: 0.26,
                                      peaks: [(0.5, 1.0, 0.28), (0.5, 0.35, 0.06), (0.15, 0.25, 0.1), (0.85, 0.3, 0.1)])

    var body: some View {
        StoryStage { size in
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSince(start)
                ZStack {
                    Rectangle().fill(.black)
                        .colorEffect(ShaderLibrary.skyStar(
                            .float2(size), .float(t), .float(1), .float(t * 0.35 - .pi / 2),
                            .float(0.15 + 0.6 * exp(-pow((t - 1.0) / 0.5, 2))), .float(1)))
                    SummitShape(ridge: Self.summit).fill(Color(red: 0.08, green: 0.10, blue: 0.17))
                    SummitShape(ridge: Self.summit, snowBelow: 0.86).fill(Color(red: 0.70, green: 0.76, blue: 0.86))
                    TinyTraveller(height: 34)
                        .position(x: size.width * 0.5, y: Self.summit.y(at: 0.5) * size.height - 15)
                }
            }
        } words: {
            StoryCaption(first: "You may never touch it.", second: "But it keeps you heading the right way.")
        }
        .task {
            try? await Task.sleep(for: .seconds(1.8))
            ready = true
        }
    }
}

/// A ridge filled to the bottom; with snowBelow, only the part above that height (snow).
private struct SummitShape: Shape {
    let ridge: Ridge
    var snowBelow: Double?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for i in 0..<ridge.heights.count {
            let x = Double(i) / Double(ridge.heights.count - 1)
            path.addLine(to: CGPoint(x: rect.minX + x * rect.width, y: rect.minY + ridge.y(at: x) * rect.height))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        guard let snowBelow else { return path }
        return path.intersection(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * snowBelow)))
    }
}
