import SwiftUI

/// The journey to your North Star: one tall picture of the whole expedition,
/// read from the bottom up. You start alone on the arctic plains, cross the
/// frozen lake, pass the North Pole, climb the mountain on switchbacks, and
/// reach the summit with the North Star above it. A dotted trail runs through
/// it; the part you have covered turns gold, and your traveller stands where
/// you are. Every kilometre you run moves you forward.
struct JourneyView: View {
    /// Kilometres run since the goal was set, read from Apple Health (RunTracker).
    @AppStorage(RunTracker.kmKey) private var kilometres: Double = 0
    @AppStorage(RunTracker.runsKey) private var runs: Int = 0
    @AppStorage(RunTracker.connectedKey) private var healthConnected = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(JourneyGoal.kmKey) private var goal: Double = 500
    @AppStorage(JourneyGoal.startKey) private var start: Double = 0
    @AppStorage(JourneyGoal.whyKey) private var why: String = ""
    @State private var editingGoal = false
    /// Where the traveller stood last time you saw the Journey, so new runs can be walked.
    @AppStorage("journeySeenKm") private var seenKm: Double = 0
    /// The kilometres the picture shows right now (walks up to `kilometres` after new runs).
    @State private var shownKm: Double = 0
    @State private var walkingUp = false
    /// "+6.2 km since last time", shown briefly after a walk-up.
    @State private var gainNote: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Total height of the journey picture, in points.
    private let height: CGFloat = 2300
    @State private var showingStory = false

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                GeometryReader { geometry in
                    JourneyMap(kilometres: shownKm, goal: safeGoal, size: CGSize(width: geometry.size.width, height: height),
                               scheduleKm: JourneyGoal.onSchedule(goal: safeGoal, start: start), why: why, walking: walkingUp)
                }
                .frame(height: height)
                .overlay(alignment: .top) {
                    // An invisible marker at the traveller's height, to scroll to on opening.
                    VStack(spacing: 0) {
                        Color.clear.frame(height: JourneyStage.y(atShare: shownKm / safeGoal) * height)
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
            .overlay(alignment: .bottom) { gainBanner }
            .sensoryFeedback(.success, trigger: stagesPassed(shownKm))
            #if os(iOS)
            .fullScreenCover(isPresented: $showingStory) { StoryView { showingStory = false } }
            .fullScreenCover(isPresented: $editingGoal) { GoalSetupView(isEditing: true) { editingGoal = false } }
            #else
            .sheet(isPresented: $showingStory) { StoryView { showingStory = false }.frame(minWidth: 420, minHeight: 760) }
            .sheet(isPresented: $editingGoal) { GoalSetupView(isEditing: true) { editingGoal = false }.frame(minWidth: 420, minHeight: 760) }
            #endif
            .onAppear {
                // Start where you were last time; new runs are then walked (see walkUp).
                shownKm = min(seenKm, kilometres)
                // After the first layout, so the scroll view knows its content.
                DispatchQueue.main.async {
                    reader.scrollTo("traveller", anchor: UnitPoint(x: 0.5, y: 0.62))
                    walkUp(reader)
                }
            }
            .onChange(of: kilometres) { walkUp(reader) }
            // Read new runs whenever the Journey opens or the app comes back to the front.
            .task { await RunTracker.refresh() }
            .onChange(of: scenePhase) { if scenePhase == .active { Task { await RunTracker.refresh() } } }
            .onChange(of: start) { Task { await RunTracker.refresh() } }
        }
    }

    /// Title and progress, on glass at the top.
    /// The goal, never zero (before it is set, a 500 km placeholder).
    private var safeGoal: Double { goal > 0 ? goal : 500 }

    /// The header: your journey and progress in two lines with a slim bar, and a ⋯ menu
    /// for everything else. "Connect Apple Health" sits below as one clear button until
    /// it is connected.
    private var header: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your journey")
                            .font(.system(size: 24, weight: .regular))
                        if !why.isEmpty {
                            Text("Towards: \(why)")
                                .font(.footnote)
                                .foregroundStyle(Theme.star)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    moreMenu
                }
                Text(progressLine)
                    .font(.subheadline.weight(.medium))
                ProgressView(value: min(1, kilometres / safeGoal))
                    .tint(Theme.star)
                Text(paceLine)
                    .font(.caption)
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .northGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            if RunTracker.isAvailable && !healthConnected {
                Button {
                    Task { await RunTracker.connect() }
                } label: {
                    Label("Connect Apple Health", systemImage: "heart.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .northGlass(in: Capsule())
                .accessibilityHint("Counts your running workouts towards your North Star")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    /// Change the goal, replay the story, and Apple Health, tucked into one round button.
    private var moreMenu: some View {
        Menu {
            Button("Change my North Star", systemImage: "star") { editingGoal = true }
            Button("Why the North Star?", systemImage: "book") { showingStory = true }
            if RunTracker.isAvailable {
                Section("Apple Health") {
                    if healthConnected {
                        Text(runs == 1 ? "1 run counted" : "\(runs) runs counted")
                        Button("Check for new runs", systemImage: "arrow.clockwise") {
                            Task { await RunTracker.refresh() }
                        }
                    } else {
                        Button("Connect Apple Health", systemImage: "heart") {
                            Task { await RunTracker.connect() }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .northGlass(in: Circle())
        }
        .accessibilityLabel("More")
    }

    /// "+6.2 km since last time", floating above the tab bar for a few seconds.
    @ViewBuilder
    private var gainBanner: some View {
        if let gainNote {
            Text(gainNote)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .northGlass(in: Capsule())
                .padding(.bottom, 110)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Walks the traveller from where you were last time up to your new total, with the
    /// gold trail filling in behind and the view following. With Reduce Motion it
    /// simply moves there.
    private func walkUp(_ reader: ScrollViewProxy) {
        let gained = kilometres - shownKm
        guard gained > 0.05 else {
            shownKm = kilometres
            seenKm = kilometres
            return
        }
        let note = String(format: gained < 10 ? "+%.1f km since last time" : "+%.0f km since last time", gained)
        if reduceMotion {
            shownKm = kilometres
            reader.scrollTo("traveller", anchor: UnitPoint(x: 0.5, y: 0.62))
        } else {
            // A short pause so you see where you were, then a walk of 2 to 4 seconds.
            let seconds = min(4, max(2, gained / safeGoal * 40))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                walkingUp = true
                withAnimation(.easeInOut(duration: seconds)) {
                    shownKm = kilometres
                    reader.scrollTo("traveller", anchor: UnitPoint(x: 0.5, y: 0.62))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { walkingUp = false }
            }
        }
        seenKm = kilometres
        withAnimation(.snappy) { gainNote = note }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { withAnimation(.easeOut) { gainNote = nil } }
    }

    /// How many stages you have passed (a haptic tap when the walk passes one).
    private func stagesPassed(_ km: Double) -> Int {
        JourneyStage.all.filter { $0.share > 0 && km >= $0.share * safeGoal }.count
    }

    /// "62 of 500 km · 63 km to the North Pole"
    private var progressLine: String {
        let done = String(format: kilometres < 10 ? "%.1f" : "%.0f", kilometres)
        guard let next = JourneyStage.all.first(where: { $0.share * safeGoal > kilometres }) else {
            return "\(done) km. You reached your North Star."
        }
        let left = max(0, next.share * safeGoal - kilometres)
        return "\(done) of \(Int(safeGoal).formatted()) km · \(Int(left.rounded(.up)).formatted()) km to \(next.name)"
    }

    /// "On track · 300 days left", or what it takes to catch up.
    private var paceLine: String {
        let elapsed = JourneyGoal.daysSince(start: start)
        let daysLeft = max(0, Int((JourneyGoal.days - elapsed).rounded(.up)))
        if kilometres >= safeGoal { return "Reached with \(daysLeft) days to spare." }
        guard daysLeft > 0 else { return "The year is over. Set a new North Star when you are ready." }
        let behind = JourneyGoal.onSchedule(goal: safeGoal, start: start) - kilometres
        if behind <= safeGoal * 0.01 { return "On track · \(daysLeft) days left" }
        let weekly = (safeGoal - kilometres) / (Double(daysLeft) / 7)
        return "About \(Int(weekly.rounded(.up))) km a week to stay on course · \(daysLeft) days left"
    }
}

// MARK: - Stages

/// A stop on the journey, with where it sits on the trail.
struct JourneyStage: Identifiable {
    let name: String
    /// Where the stage sits, as a share of your goal (0 at the start, 1 at the summit).
    let share: Double
    let line: String
    /// Index of its point on the trail (JourneyTrail.points).
    let point: Int
    var id: String { name }

    static let all: [JourneyStage] = [
        JourneyStage(name: "the arctic plains", share: 0, line: "Every journey starts with one step.", point: 0),
        JourneyStage(name: "the frozen lake", share: 0.08, line: "Keep moving. The ice holds.", point: 2),
        JourneyStage(name: "the North Pole", share: 0.25, line: "Nothing out here but you and the wind.", point: 5),
        JourneyStage(name: "the mountain", share: 0.5, line: "The climb begins. Carry what you have.", point: 6),
        JourneyStage(name: "your North Star", share: 1, line: "Where you were always heading.", point: JourneyTrail.points.count - 1),
    ]

    /// Where on the trail (along its points) a share of the goal falls, between stages.
    static func trailPosition(atShare share: Double) -> (index: Int, t: Double) {
        let stages = all
        guard share > 0 else { return (0, 0) }
        guard share < 1 else { return (JourneyTrail.points.count - 1, 0) }
        let i = stages.lastIndex { $0.share <= share }!
        let a = stages[i], b = stages[i + 1]
        let within = (share - a.share) / (b.share - a.share)
        let exact = Double(a.point) + within * Double(b.point - a.point)
        return (Int(exact), exact - Double(Int(exact)))
    }

    /// Height of the traveller on the picture (0 at top, 1 at bottom).
    static func y(atShare share: Double) -> Double {
        let p = trailPosition(atShare: share)
        return JourneyTrail.point(index: p.index, t: p.t, in: CGSize(width: 1, height: 1)).y
    }

    func label(goal: Double) -> String { share == 0 ? "Start" : "\(Int((share * goal).rounded()).formatted()) km" }
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

    /// The curve from point `i` to point `i + 1` (start, two control points, end), at `size`.
    /// Controls halfway down each step keep the trail smooth.
    private static func segment(_ i: Int, in size: CGSize) -> [CGPoint] {
        let a = CGPoint(x: points[i].x * size.width, y: points[i].y * size.height)
        let b = CGPoint(x: points[i + 1].x * size.width, y: points[i + 1].y * size.height)
        let middle = a.y + (b.y - a.y) * 0.5
        return [a, CGPoint(x: a.x, y: middle), CGPoint(x: b.x, y: middle), b]
    }

    /// Splits a curve at `t` (de Casteljau's method): the first part's four points.
    private static func firstPart(of c: [CGPoint], at t: Double) -> [CGPoint] {
        func mix(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t) }
        let q0 = mix(c[0], c[1]), q1 = mix(c[1], c[2]), q2 = mix(c[2], c[3])
        let r0 = mix(q0, q1), r1 = mix(q1, q2)
        return [c[0], q0, r0, mix(r0, r1)]
    }

    /// The exact point on the trail `t` of the way along the step after point `index`, so the
    /// traveller stands on the dotted line rather than cutting across its bends.
    static func point(index: Int, t: Double, in size: CGSize) -> CGPoint {
        guard index < points.count - 1 else {
            return CGPoint(x: points[index].x * size.width, y: points[index].y * size.height)
        }
        return firstPart(of: segment(index, in: size), at: t)[3]
    }

    /// The smooth trail through the points, all of it or up to `end` (a point index and a
    /// share of the next step). The partial step follows the same curve exactly.
    static func path(in size: CGSize, upTo end: (index: Int, t: Double)? = nil) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: points[0].x * size.width, y: points[0].y * size.height))
        let last = end?.index ?? points.count - 1
        for i in 0..<min(last + 1, points.count - 1) {
            var c = segment(i, in: size)
            if let end, i == end.index { c = firstPart(of: c, at: end.t) }
            path.addCurve(to: c[3], control1: c[1], control2: c[2])
        }
        return path
    }
}

// MARK: - The picture

enum JourneyColours {
    static let nightTop = Color(red: 0.02, green: 0.03, blue: 0.08)
    static let nightLow = Color(red: 0.10, green: 0.14, blue: 0.24)
    // The lower picture is dusk, not white-out, so the white labels stay readable.
    static let twilight = Color(red: 0.25, green: 0.31, blue: 0.45)
    static let plains = Color(red: 0.36, green: 0.43, blue: 0.56)
    static let rock = Color(red: 0.15, green: 0.19, blue: 0.27)
    static let mountainSnow = Color(red: 0.78, green: 0.83, blue: 0.91)
    static let ice = Color(red: 0.45, green: 0.56, blue: 0.68)
    static let trail = Color.white.opacity(0.7)
}

/// The whole journey drawn at a given size (also used, smaller, in the story).
struct JourneyMap: View, Animatable {
    /// Where the North Star sits (share of the height): just above the summit, not far off.
    static let starY = 0.15

    var kilometres: Double
    /// Lets SwiftUI animate the traveller and the gold trail between two distances.
    var animatableData: Double {
        get { kilometres }
        set { kilometres = newValue }
    }
    /// Your goal for the year; the stages sit at shares of it.
    let goal: Double
    let size: CGSize
    /// Where you would be today on an even pace (a faint marker), if known.
    var scheduleKm: Double?
    /// What you are running towards, shown at the summit.
    var why: String = ""
    /// Short labels only (names and distances), for small sizes.
    var compact = false
    /// The line under the name (your own words at the summit, if you gave them).
    var line: String = ""
    /// The traveller walks (in the story) or stands (on the Journey tab).
    var walking = false

    var body: some View {
        let progress = JourneyStage.trailPosition(atShare: kilometres / max(goal, 1))
        ZStack(alignment: .topLeading) {
            // Sky: deep night at the top (the star), paling to arctic twilight below.
            LinearGradient(stops: [
                .init(color: JourneyColours.nightTop, location: 0),
                .init(color: JourneyColours.nightLow, location: 0.3),
                .init(color: JourneyColours.twilight, location: 0.55),
                .init(color: JourneyColours.plains, location: 0.8),
            ], startPoint: .top, endPoint: .bottom)

            StarField(size: size)

            // A faint beam from the star to the summit ties the goal to the climb.
            LinearGradient(colors: [Theme.star.opacity(0.35), Theme.star.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(width: 3, height: size.height * (JourneyTrail.points.last!.y - Self.starY))
                .blur(radius: 1.5)
                .position(x: size.width * 0.5, y: size.height * (Self.starY + JourneyTrail.points.last!.y) / 2)
            NorthStarGlint(opacity: 1, size: 90)
                .position(x: size.width * 0.5, y: size.height * Self.starY)

            // The mountain, with snow on its upper half.
            MountainShape().fill(JourneyColours.rock)
            MountainShape(snowOnly: true).fill(JourneyColours.mountainSnow)

            // The ice field around the Pole and the frozen lake, then the plains.
            IceFieldShape().fill(LinearGradient(colors: [JourneyColours.twilight.opacity(0.9), JourneyColours.plains],
                                                startPoint: .top, endPoint: .bottom))
            SnowDrifts().stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            LakeIceShape().fill(LinearGradient(colors: [JourneyColours.ice.opacity(0.75), JourneyColours.ice, JourneyColours.ice.opacity(0.8)],
                                               startPoint: .top, endPoint: .bottom))
            IceCracks().stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            LakeIceShape().stroke(.white.opacity(0.45), lineWidth: 1.5)

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
                StageMarker(stage: stage, goal: goal, reached: kilometres >= stage.share * goal,
                            onLeft: point.x > 0.5, compact: compact,
                            line: stage.share == 1 && !why.isEmpty ? why : stage.line)
                    .position(x: point.x * size.width, y: point.y * size.height)
            }

            // Where you would be on an even pace: a faint ring on the trail.
            if let scheduleKm, scheduleKm > kilometres + goal * 0.01 {
                let p = travellerPoint(JourneyStage.trailPosition(atShare: scheduleKm / max(goal, 1)))
                Circle().stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    .frame(width: 22, height: 22)
                    .position(x: p.x, y: p.y + 16)
                    .accessibilityLabel("Where you would be on schedule")
            }

            Traveller(walking: walking)
                .position(travellerPoint(progress))
        }
        .frame(width: size.width, height: size.height)
    }

    private func travellerPoint(_ p: (index: Int, t: Double)) -> CGPoint {
        let point = JourneyTrail.point(index: p.index, t: p.t, in: size)
        return CGPoint(x: point.x, y: point.y - 16)  // feet on the trail
    }
}

/// A stop on the trail: a dot, and its name, distance and line beside it.
private struct StageMarker: View {
    let stage: JourneyStage
    let goal: Double
    let reached: Bool
    /// Put the text on the left of the dot (when the dot is on the right half).
    let onLeft: Bool
    var compact = false
    /// The line under the name (your own words at the summit, if you gave them).
    var line: String = ""

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
                Text(stage.label(goal: goal))
                    .font(.caption.weight(.semibold))
                    .opacity(0.8)
                Text(name)
                    .font(.headline.weight(.regular))
                Text(line)
                    .font(.caption)
                    .opacity(0.8)
            }
        }
        .foregroundStyle(.white)
        // A double shadow (tight and soft) keeps labels readable on light and dark ground.
        .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.35), radius: 8)
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
