import SwiftUI

/// The journey to your North Star: one tall picture of the whole expedition,
/// read from the bottom up. You start alone on the arctic plains, cross the
/// frozen lake, pass the North Pole, climb the mountain on switchbacks, and
/// reach the summit with the North Star above it. A dotted trail runs through
/// it; the part you have covered turns gold, and your traveller stands where
/// you are. Every kilometre you run moves you forward.
struct JourneyView: View {
    /// Kilometres travelled so far. Run tracking (Apple Health) will fill this in;
    /// until then it stays at the start.
    @AppStorage("journeyKm") private var kilometres: Double = 0

    /// Total height of the journey picture, in points.
    private let height: CGFloat = 2300
    @State private var showingStory = false

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                GeometryReader { geometry in
                    JourneyMap(kilometres: kilometres, size: CGSize(width: geometry.size.width, height: height))
                }
                .frame(height: height)
                .overlay(alignment: .top) {
                    // An invisible marker at the traveller's height, to scroll to on opening.
                    VStack(spacing: 0) {
                        Color.clear.frame(height: JourneyStage.y(atKm: kilometres) * height)
                        Color.clear.frame(height: 1).id("traveller")
                        Spacer(minLength: 0)
                    }
                    .allowsHitTesting(false)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .background(JourneyColours.plains)
            .overlay(alignment: .top) { header }
            #if os(iOS)
            .fullScreenCover(isPresented: $showingStory) { StoryView { showingStory = false } }
            #else
            .sheet(isPresented: $showingStory) { StoryView { showingStory = false }.frame(minWidth: 420, minHeight: 760) }
            #endif
            .onAppear {
                // After the first layout, so the scroll view knows its content.
                DispatchQueue.main.async { reader.scrollTo("traveller", anchor: UnitPoint(x: 0.5, y: 0.62)) }
            }
        }
    }

    /// Title and progress, on glass at the top.
    private var header: some View {
        let next = JourneyStage.all.first { $0.kilometres > kilometres }
        return VStack(spacing: 4) {
            Text("Your journey")
                .font(.system(size: 26, weight: .regular))
            Text(progressLine(next: next))
                .font(.footnote.weight(.medium))
                .opacity(0.8)
                .multilineTextAlignment(.center)
            Button("Why the North Star?") { showingStory = true }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.star)
                .buttonStyle(.plain)
                .padding(.top, 2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .northGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func progressLine(next: JourneyStage?) -> String {
        let done = String(format: kilometres < 10 ? "%.1f" : "%.0f", kilometres)
        guard let next else { return "\(done) km. You reached your North Star." }
        let left = max(0, next.kilometres - kilometres)
        return "\(done) of \(Int(JourneyStage.total)) km · \(Int(left.rounded(.up))) km to \(next.name)"
    }
}

// MARK: - Stages

/// A stop on the journey, with where it sits on the trail.
struct JourneyStage: Identifiable {
    let name: String
    let kilometres: Double
    let line: String
    /// Index of its point on the trail (JourneyTrail.points).
    let point: Int
    var id: String { name }

    static let all: [JourneyStage] = [
        JourneyStage(name: "the arctic plains", kilometres: 0, line: "Every journey starts with one step.", point: 0),
        JourneyStage(name: "the frozen lake", kilometres: 25, line: "Keep moving. The ice holds.", point: 2),
        JourneyStage(name: "the North Pole", kilometres: 75, line: "Nothing out here but you and the wind.", point: 5),
        JourneyStage(name: "the mountain", kilometres: 150, line: "The climb begins. Carry what you have.", point: 6),
        JourneyStage(name: "your North Star", kilometres: 300, line: "Where you were always heading.", point: JourneyTrail.points.count - 1),
    ]

    static var total: Double { all.last!.kilometres }

    /// Where on the trail (0 to 1 along its points) a distance falls, between stages.
    static func trailPosition(atKm km: Double) -> (index: Int, t: Double) {
        let stages = all
        guard km > 0 else { return (0, 0) }
        guard km < total else { return (JourneyTrail.points.count - 1, 0) }
        let i = stages.lastIndex { $0.kilometres <= km }!
        let a = stages[i], b = stages[i + 1]
        let share = (km - a.kilometres) / (b.kilometres - a.kilometres)
        let exact = Double(a.point) + share * Double(b.point - a.point)
        return (Int(exact), exact - Double(Int(exact)))
    }

    /// Height of the traveller on the picture (0 at top, 1 at bottom).
    static func y(atKm km: Double) -> Double {
        let p = trailPosition(atKm: km)
        let points = JourneyTrail.points
        guard p.index < points.count - 1 else { return points[p.index].y }
        return points[p.index].y + (points[p.index + 1].y - points[p.index].y) * p.t
    }

    func label(isReached: Bool) -> String { kilometres == 0 ? "Start" : "\(Int(kilometres)) km" }
}

/// The trail through the journey, as fractions of the picture (x across, y down).
enum JourneyTrail {
    static let points: [CGPoint] = [
        CGPoint(x: 0.42, y: 0.93),   // start, on the plains
        CGPoint(x: 0.66, y: 0.85),
        CGPoint(x: 0.34, y: 0.755),  // the frozen lake's shore
        CGPoint(x: 0.62, y: 0.69),
        CGPoint(x: 0.38, y: 0.62),
        CGPoint(x: 0.58, y: 0.535),  // the North Pole
        CGPoint(x: 0.40, y: 0.45),   // the foot of the mountain
        CGPoint(x: 0.62, y: 0.39),
        CGPoint(x: 0.41, y: 0.325),
        CGPoint(x: 0.57, y: 0.265),
        CGPoint(x: 0.50, y: 0.205),  // the summit
    ]

    /// A smooth line through the points, from `start` to `end` (indices, with a share of the last segment).
    static func path(in size: CGSize, upTo end: (index: Int, t: Double)? = nil) -> Path {
        let p = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        var path = Path()
        path.move(to: p[0])
        let last = end?.index ?? p.count - 1
        for i in 0..<min(last + 1, p.count - 1) {
            // Curves through the midpoints keep the trail smooth.
            let a = p[i], b = p[i + 1]
            let control1 = CGPoint(x: a.x, y: a.y + (b.y - a.y) * 0.5)
            let control2 = CGPoint(x: b.x, y: a.y + (b.y - a.y) * 0.5)
            if let end, i == end.index {
                // Partial last segment: approximate with a straight piece.
                path.addLine(to: CGPoint(x: a.x + (b.x - a.x) * end.t, y: a.y + (b.y - a.y) * end.t))
            } else {
                path.addCurve(to: b, control1: control1, control2: control2)
            }
        }
        return path
    }
}

// MARK: - The picture

enum JourneyColours {
    static let nightTop = Color(red: 0.02, green: 0.03, blue: 0.08)
    static let nightLow = Color(red: 0.10, green: 0.14, blue: 0.24)
    static let twilight = Color(red: 0.42, green: 0.48, blue: 0.60)
    static let plains = Color(red: 0.82, green: 0.86, blue: 0.91)
    static let rock = Color(red: 0.15, green: 0.19, blue: 0.27)
    static let mountainSnow = Color(red: 0.78, green: 0.83, blue: 0.91)
    static let ice = Color(red: 0.58, green: 0.70, blue: 0.80)
    static let trail = Color.white.opacity(0.7)
}

/// The whole journey drawn at a given size (also used, smaller, in the story).
struct JourneyMap: View {
    let kilometres: Double
    let size: CGSize
    /// Short labels only (names and distances), for small sizes.
    var compact = false
    /// The traveller walks (in the story) or stands (on the Journey tab).
    var walking = false

    var body: some View {
        let progress = JourneyStage.trailPosition(atKm: kilometres)
        ZStack(alignment: .topLeading) {
            // Sky: deep night at the top (the star), paling to arctic twilight below.
            LinearGradient(stops: [
                .init(color: JourneyColours.nightTop, location: 0),
                .init(color: JourneyColours.nightLow, location: 0.3),
                .init(color: JourneyColours.twilight, location: 0.55),
                .init(color: JourneyColours.plains, location: 0.8),
            ], startPoint: .top, endPoint: .bottom)

            StarField(size: size)

            NorthStarGlint(opacity: 1, size: 90)
                .position(x: size.width * 0.5, y: size.height * 0.095)

            // The mountain, with snow on its upper half.
            MountainShape().fill(JourneyColours.rock)
            MountainShape(snowOnly: true).fill(JourneyColours.mountainSnow)

            // The ice field around the Pole and the frozen lake, then the plains.
            IceFieldShape().fill(LinearGradient(colors: [JourneyColours.twilight.opacity(0.9), JourneyColours.plains],
                                                startPoint: .top, endPoint: .bottom))
            SnowDrifts().stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            LakeIceShape().fill(LinearGradient(colors: [JourneyColours.ice.opacity(0.75), JourneyColours.ice, JourneyColours.ice.opacity(0.8)],
                                               startPoint: .top, endPoint: .bottom))
            IceCracks().stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            LakeIceShape().stroke(.white.opacity(0.6), lineWidth: 1.5)

            // The Pole itself: a lone marker in the ice.
            PoleMarker()
                .position(x: size.width * 0.66, y: size.height * 0.53)

            // The trail: dotted all the way, gold where you have been.
            JourneyTrail.path(in: size)
                .stroke(JourneyColours.trail, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 9]))
            if kilometres > 0 {
                JourneyTrail.path(in: size, upTo: progress)
                    .stroke(Theme.star, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            }

            ForEach(JourneyStage.all) { stage in
                let point = JourneyTrail.points[stage.point]
                StageMarker(stage: stage, reached: kilometres >= stage.kilometres,
                            onLeft: point.x > 0.5, compact: compact)
                    .position(x: point.x * size.width, y: point.y * size.height)
            }

            Traveller(walking: walking)
                .position(travellerPoint(progress))
        }
        .frame(width: size.width, height: size.height)
    }

    private func travellerPoint(_ p: (index: Int, t: Double)) -> CGPoint {
        let points = JourneyTrail.points
        let a = points[p.index], b = points[min(p.index + 1, points.count - 1)]
        return CGPoint(x: (a.x + (b.x - a.x) * p.t) * size.width,
                       y: (a.y + (b.y - a.y) * p.t) * size.height - 16)
    }
}

/// A stop on the trail: a dot, and its name, distance and line beside it.
private struct StageMarker: View {
    let stage: JourneyStage
    let reached: Bool
    /// Put the text on the left of the dot (when the dot is on the right half).
    let onLeft: Bool
    var compact = false

    var body: some View {
        let dot = Circle()
            .fill(reached ? Theme.star : .white)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 1))
        let name = stage.name.prefix(1).uppercased() + stage.name.dropFirst()
        let text = VStack(alignment: onLeft ? .trailing : .leading, spacing: 2) {
            if compact {
                // One short line, for small sizes.
                Text(name).font(.caption.weight(.semibold))
            } else {
                Text(stage.label(isReached: reached))
                    .font(.caption.weight(.semibold))
                    .opacity(0.8)
                Text(name)
                    .font(.headline.weight(.regular))
                Text(stage.line)
                    .font(.caption)
                    .opacity(0.8)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
        .frame(width: 170, alignment: onLeft ? .trailing : .leading)

        HStack(spacing: 10) {
            if onLeft { text; dot } else { dot; text }
        }
        // Keep the dot itself on the trail point.
        .offset(x: onLeft ? -85 - 5 : 85 + 5)
        .accessibilityElement(children: .combine)
    }
}

/// You: the tiny traveller on the trail, with a soft glow so you can find yourself.
private struct Traveller: View {
    var walking = false

    var body: some View {
        ZStack {
            Circle().fill(Theme.star.opacity(0.35)).frame(width: 40, height: 40).blur(radius: 7)
            TinyTraveller(walking: walking, height: 30)
                .shadow(color: .black.opacity(0.4), radius: 3)
        }
        .accessibilityLabel("You are here")
    }
}

/// A small flag on a pole, standing alone at the top of the world.
private struct PoleMarker: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.white.opacity(0.9)).frame(width: 2, height: 34)
            Path { p in
                p.move(to: CGPoint(x: 2, y: 0))
                p.addLine(to: CGPoint(x: 18, y: 5))
                p.addLine(to: CGPoint(x: 2, y: 10))
            }
            .fill(Theme.star.opacity(0.9))
        }
        .frame(width: 20, height: 34)
        .accessibilityHidden(true)
    }
}

/// Faint fixed stars in the upper sky.
private struct StarField: View {
    let size: CGSize

    var body: some View {
        Canvas { context, canvasSize in
            var seed: UInt64 = 5
            func random() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 33) / Double(1 << 31)
            }
            for _ in 0..<90 {
                let x = random() * canvasSize.width
                let y = random() * canvasSize.height * 0.32
                let r = 0.5 + random() * 1.1
                let alpha = (0.25 + random() * 0.6) * (1 - y / (canvasSize.height * 0.36))
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                             with: .color(.white.opacity(alpha)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The great mountain: a jagged ridge rising to the summit, wide at its base.
private struct MountainShape: Shape {
    var snowOnly = false
    // A broad massif (wide base) with a sharper summit and lesser peaks on its shoulders.
    private static let ridge = Ridge(seed: 41, roughness: 0.66, base: 0.47, amplitude: 0.27,
                                     peaks: [(0.5, 1.3, 0.34), (0.5, 0.3, 0.1), (0.24, 0.3, 0.07), (0.78, 0.35, 0.08)])

    func path(in rect: CGRect) -> Path {
        var mountain = Path()
        mountain.move(to: CGPoint(x: rect.minX, y: rect.minY + 0.5 * rect.height))
        let ridge = Self.ridge
        for i in 0..<ridge.heights.count {
            let x = Double(i) / Double(ridge.heights.count - 1)
            mountain.addLine(to: CGPoint(x: rect.minX + x * rect.width, y: rect.minY + ridge.y(at: x) * rect.height))
        }
        mountain.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 0.5 * rect.height))
        mountain.closeSubpath()
        guard snowOnly else { return mountain }
        // Snow above a ragged line a third of the way down the mountain.
        let line = Ridge(seed: 83, roughness: 0.8, base: 0.33, amplitude: 0.05, peaks: [])
        var above = Path()
        above.move(to: CGPoint(x: rect.minX, y: rect.minY))
        above.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        for i in stride(from: line.heights.count - 1, through: 0, by: -1) {
            let x = Double(i) / Double(line.heights.count - 1)
            above.addLine(to: CGPoint(x: rect.minX + x * rect.width, y: rect.minY + line.y(at: x) * rect.height))
        }
        above.closeSubpath()
        return mountain.intersection(above)
    }
}

/// The ice field from the foot of the mountain down to the plains.
private struct IceFieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        let edge = Ridge(seed: 17, roughness: 0.5, base: 0.475, amplitude: 0.02, peaks: [])
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for i in 0..<edge.heights.count {
            let x = Double(i) / Double(edge.heights.count - 1)
            path.addLine(to: CGPoint(x: rect.minX + x * rect.width, y: rect.minY + edge.y(at: x) * rect.height))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The frozen lake: a wide band of ice from edge to edge, with ragged shores.
private struct LakeIceShape: Shape {
    func path(in rect: CGRect) -> Path {
        let far = Ridge(seed: 23, roughness: 0.55, base: 0.665, amplitude: 0.02, peaks: [(0.3, 0.6, 0.2)])
        let near = Ridge(seed: 61, roughness: 0.55, base: 0.745, amplitude: 0.022, peaks: [(0.75, 0.5, 0.2)])
        var path = Path()
        for i in 0..<far.heights.count {
            let x = Double(i) / Double(far.heights.count - 1)
            let point = CGPoint(x: rect.minX + x * rect.width, y: rect.minY + far.y(at: x) * rect.height)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        for i in stride(from: near.heights.count - 1, through: 0, by: -1) {
            let x = Double(i) / Double(near.heights.count - 1)
            path.addLine(to: CGPoint(x: rect.minX + x * rect.width, y: rect.minY + (near.y(at: x) + 0.025) * rect.height))
        }
        path.closeSubpath()
        return path
    }
}

/// Cracks in the lake ice: a few jagged lines running across it.
private struct IceCracks: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cracks: [[(Double, Double)]] = [
            [(0.05, 0.69), (0.16, 0.695), (0.22, 0.688), (0.34, 0.70), (0.41, 0.697)],
            [(0.55, 0.715), (0.63, 0.708), (0.71, 0.718), (0.83, 0.712), (0.97, 0.72)],
            [(0.22, 0.73), (0.30, 0.722), (0.36, 0.735), (0.47, 0.728)],
            [(0.62, 0.69), (0.66, 0.70), (0.70, 0.694)],
        ]
        for crack in cracks {
            for (i, point) in crack.enumerated() {
                let p = CGPoint(x: rect.minX + point.0 * rect.width, y: rect.minY + point.1 * rect.height)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
        return path
    }
}

/// Wind-blown drifts on the snow: long, gentle curves across the ice field and plains.
private struct SnowDrifts: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let rows: [(y: Double, from: Double, to: Double)] = [
            (0.52, 0.0, 0.45), (0.56, 0.35, 1.0), (0.60, 0.05, 0.6), (0.635, 0.5, 0.95),
            (0.80, 0.0, 0.55), (0.84, 0.4, 1.0), (0.885, 0.1, 0.5), (0.92, 0.6, 1.0), (0.96, 0.0, 0.7),
        ]
        for row in rows {
            let steps = 24
            for i in 0...steps {
                let x = row.from + (row.to - row.from) * Double(i) / Double(steps)
                let y = row.y + 0.004 * sin(x * 14 + row.y * 50)
                let p = CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
        return path
    }
}

#Preview {
    JourneyView()
}
