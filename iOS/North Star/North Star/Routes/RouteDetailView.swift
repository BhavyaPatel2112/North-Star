import Charts
import MapKit
import SwiftUI

/// One route in detail: drag the pointer along it to see each street and how
/// clean it is, the cleanest time to start, street-by-street steps, and
/// pharmacies, water and clinics near the route, and where to go after the run.
struct RouteDetailView: View {
    let shape: RouteShape

    @State private var pointerKm: Double = 0
    @State private var stops: [NearbyPlaces.Stop] = []
    @State private var lookedForStops = false
    @State private var afterRun: [NearbyPlaces.Destination] = []
    @State private var lookedAfterRun = false
    /// The street-by-street steps start folded away, to keep the page short.
    @State private var showingSteps = false
    @State private var showingStops = false
    @State private var showingAfterRun = false
    // Pace plan: a target time (as typed) and how to spread it over the route.
    @State private var showingPacePlan = false
    @State private var targetText = ""
    @State private var strategy: PacePlan.Strategy = .evenEffort
    @FocusState private var editingTarget: Bool
    @AppStorage(RunTracker.usualPaceKey) private var usualPace: Double = 0
    @Environment(\.openURL) private var openURL

    private var option: RouteOption { shape.option }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroller in
            ScrollView {
                VStack(spacing: 14) {
                    RouteMap(shapes: [shape], selectedID: option.id, pointer: shape.point(atKm: pointerKm), stops: stops,
                             afterRun: afterRun)
                        .frame(height: geometry.size.height * 0.42 + geometry.safeAreaInsets.top)
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 32, bottomTrailingRadius: 32, style: .continuous))

                    JourneyCard { pointerControl }.padding(.horizontal, 16)

                    if RouteText.finish(option) != nil || RouteText.busyWarning(option) != nil {
                        JourneyCard {
                            if let finish = RouteText.finish(option), let place = option.finishPlace {
                                Label(finish, systemImage: place.symbol)
                            }
                            if let crossing = RouteText.stationCrossing(option) {
                                Label(crossing, systemImage: "figure.walk").foregroundStyle(.secondary)
                            }
                            if let warning = RouteText.busyWarning(option) {
                                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                            if option.finishPlace?.rating != nil { CardNote(text: "Rating from Google.") }
                        }
                        .padding(.horizontal, 16)
                    }

                    JourneyCard {
                        Dropdown(title: "Pace plan", summary: pacePlanSummary, isOpen: $showingPacePlan) { pacePlanContent }
                    }
                    .padding(.horizontal, 16)
                    .id("pacePlan")

                    JourneyCard(title: "When to go") { hourChart }.padding(.horizontal, 16)

                    JourneyCard {
                        Dropdown(title: "Along the way", summary: stopsSummary, isOpen: $showingStops) {
                            ForEach(stops) { stop in
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: stop.kind.symbol)
                                        .frame(width: 30, height: 30)
                                        .background(Theme.ink.opacity(0.07), in: Circle())
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(stop.name).font(.subheadline.weight(.medium))
                                        Text("\(stop.kind.rawValue) · \(Int(stop.offRouteM.rounded(to: 10))) m off route at km \(String(format: "%.1f", stop.atKm))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            CardNote(text: "From Apple Maps. Opening hours are not always known, so check before you rely on a stop.")
                        }
                    }
                    .padding(.horizontal, 16)

                    JourneyCard {
                        Dropdown(title: "After your run", summary: afterRunSummary, isOpen: $showingAfterRun) { afterRunList }
                    }
                    .padding(.horizontal, 16)
                    .id("afterRun")

                    JourneyCard { stepsDropdown }.padding(.horizontal, 16)

                    if let link = option.googleMapsLink {
                        Button { openURL(link) } label: {
                            Label("Open in Google Maps", systemImage: "arrow.up.right")
                        }
                        .buttonStyle(PillButtonStyle())
                        .padding(.horizontal, 16)
                    }

                    CardNote(text: "Good to know: footpaths are not always recorded, so busy roads may have none. There is no data on lighting or safety at night. GPS watches can differ from this distance by 2 to 3%.")
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 24)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            #if DEBUG
            // "-detailScrollTo afterRun" scrolls there once the places are found (for screenshots).
            .onAppear {
                // "-pacePlanOpen YES" opens the pace plan (for screenshots).
                if UserDefaults.standard.bool(forKey: "pacePlanOpen") { showingPacePlan = true }
            }
            .onChange(of: lookedAfterRun) {
                if let target = UserDefaults.standard.string(forKey: "detailScrollTo") { scroller.scrollTo(target, anchor: .top) }
            }
            #endif
            }
        }
        .background(Theme.mist)
        .navigationTitle("\(PlannerModel.format(km: option.distanceKm)) \(option.isLoop ? "loop" : "one way")")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .task {
            // Look up places near the finish at the same time as the stops along the way.
            if let finish = shape.finish {
                Task {
                    afterRun = await NearbyPlaces.afterRun(from: finish)
                    lookedAfterRun = true
                    #if DEBUG
                    for place in afterRun { print("After run:", place.kind, "|", place.name, "|", Int(place.walkM), "m,", Int(place.walkSeconds / 60), "min") }
                    #endif
                }
            } else {
                lookedAfterRun = true
            }
            stops = await NearbyPlaces.stops(along: shape)
            lookedForStops = true
            #if DEBUG
            for stop in stops { print("Stop:", stop.kind.rawValue, "|", stop.name, "|", Int(stop.offRouteM), "m off route at km", String(format: "%.1f", stop.atKm)) }
            #endif
        }
    }

    // MARK: - Pieces

    // MARK: - Pace plan

    /// The plan for the typed target time (nil while the time cannot be read).
    private var pacePlan: PacePlan? {
        guard let target = PacePlan.seconds(from: targetText.isEmpty ? defaultTargetText : targetText),
              target >= 60 else { return nil }
        let profile = option.elevation?.points.map { (km: $0.km, metres: $0.metres) } ?? []
        return PacePlan(distanceKm: option.distanceKm, profile: profile, targetSeconds: target, strategy: strategy)
    }

    /// Your usual time for this route (from your usual pace, or an easy 6:30 /km), to the half minute.
    private var defaultTargetText: String {
        let pace = usualPace > 0 ? usualPace : 390
        return RunFormat.duration((option.distanceKm * pace / 30).rounded() * 30)
    }

    private var pacePlanSummary: String {
        guard let plan = pacePlan else { return "Type a target time like 25:00" }
        return "Target \(RunFormat.duration(plan.targetSeconds)) · \(RunFormat.pace(plan.averagePace)) average"
    }

    @ViewBuilder
    private var pacePlanContent: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Target time").font(.subheadline.weight(.medium))
            Spacer()
            TextField(defaultTargetText, text: $targetText)
                .font(.title3.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .focused($editingTarget)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
                .frame(maxWidth: 140)
                .accessibilityLabel("Target time, minutes and seconds")
            if editingTarget {
                Button("Done") { editingTarget = false }.font(.subheadline.weight(.semibold))
            }
        }
        PillSwitch(selection: $strategy, options: [(.evenEffort, "Even effort"), (.negativeSplit, "Negative split")])
        CardNote(text: strategy == .evenEffort
                 ? "Slower up the hills, faster down them, so the effort feels the same all the way."
                 : "Start a little easier and finish faster, about 3% each way.")
        if let plan = pacePlan {
            Text("\(RunFormat.pace(plan.averagePace)) average")
                .font(.headline.monospacedDigit())
            paceBars(plan)
            ForEach(plan.splits) { split in
                HStack(spacing: 10) {
                    Text(split.lengthKm < 0.95 ? String(format: "%.1f", Double(split.index - 1) + split.lengthKm) : "\(split.index)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .frame(width: 30, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(RunFormat.pace(split.paceSecondsPerKm)).font(.subheadline.monospacedDigit())
                        Text(split.note).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(RunFormat.duration(split.elapsedAtEnd))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            CardNote(text: "Kilometre, its pace, and the time on your watch at the end of it. Paces follow the route's hills; drag the pointer above to see where you should be.")
        }
    }

    /// One bar per kilometre: taller is slower. Gold when faster than average.
    private func paceBars(_ plan: PacePlan) -> some View {
        // Bars start just below the fastest kilometre (not at zero), so small differences show.
        let paces = plan.splits.map(\.paceSecondsPerKm)
        let low = (paces.min() ?? 0) * 0.96, high = (paces.max() ?? 1) * 1.01
        return Chart(plan.splits) { split in
            BarMark(x: .value("km", "\(split.index)"),
                    yStart: .value("Base", low), yEnd: .value("Pace", split.paceSecondsPerKm))
                .foregroundStyle(split.paceSecondsPerKm <= plan.averagePace ? Theme.star : Theme.ink.opacity(0.35))
                .cornerRadius(3)
        }
        .chartYScale(domain: low...high)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { _ in AxisValueLabel() }
        }
        .frame(height: 70)
        .clipped()
        .accessibilityHidden(true)
    }

    /// "Street by street" as a dropdown: one line when closed, every street when open.
    private var stepsDropdown: some View {
        Dropdown(title: "Street by street", summary: "\(option.steps.count) streets", isOpen: $showingSteps) {
            ForEach(option.steps) { step in stepRow(step) }
            CardNote(text: "Pollution is estimated for each street at your start time.")
        }
    }

    /// "4 medical stores · 2 shops for water · 1 clinic", or a note while looking.
    private var stopsSummary: String {
        guard lookedForStops else { return "Looking for medical stores, water and clinics…" }
        guard !stops.isEmpty else { return "No medical stores, shops or clinics found near this route" }
        let names: [NearbyPlaces.Stop.Kind: (String, String)] = [
            .pharmacy: ("medical store", "medical stores"), .water: ("shop for water", "shops for water"),
            .clinic: ("clinic", "clinics"),
        ]
        return NearbyPlaces.Stop.Kind.allCases.compactMap { kind in
            let count = stops.filter { $0.kind == kind }.count
            guard count > 0, let name = names[kind] else { return nil }
            return "\(count) \(count == 1 ? name.0 : name.1)"
        }.joined(separator: " · ")
    }

    /// "4 places to eat · 2 stations nearby", or a note while looking.
    private var afterRunSummary: String {
        guard lookedAfterRun else { return "Looking for food and stations near the finish…" }
        let food = afterRun.filter { $0.kind == .food }.count
        let stations = afterRun.filter { $0.kind == .station }.count
        guard food + stations > 0 else { return "No places to eat or stations near the finish" }
        var parts: [String] = []
        if food > 0 { parts.append("\(food) place\(food == 1 ? "" : "s") to eat") }
        if stations > 0 { parts.append("\(stations) station\(stations == 1 ? "" : "s")") }
        return parts.joined(separator: " · ") + " nearby"
    }

    /// Places to eat and stations a short walk from the finish. Tap one for walking
    /// directions in Apple Maps.
    @ViewBuilder
    private var afterRunList: some View {
        let food = afterRun.filter { $0.kind == .food }
        let stations = afterRun.filter { $0.kind == .station }
        if !food.isEmpty {
            Text("Food").font(.subheadline.weight(.semibold))
            ForEach(food) { destinationRow($0) }
        }
        if !stations.isEmpty {
            if !food.isEmpty { Divider() }
            Text("Stations").font(.subheadline.weight(.semibold))
            ForEach(stations) { destinationRow($0) }
        }
        if !afterRun.isEmpty {
            CardNote(text: "Walks from the end of the route, from Apple Maps. Tap a place for directions. Check it is open.")
        }
    }

    private func destinationRow(_ place: NearbyPlaces.Destination) -> some View {
        Button {
            if let finish = shape.finish { NearbyPlaces.openWalk(from: finish, to: place) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: place.kind.symbol)
                    .frame(width: 30, height: 30)
                    .background(Theme.ink.opacity(0.07), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text("\(Self.walkDistance(place.walkM)) · \(Self.walkTime(place.walkSeconds)) walk")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.triangle.turn.up.right.circle")
                    .font(.title3)
                    .foregroundStyle(Theme.ink.opacity(0.6))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens walking directions in Apple Maps")
    }

    /// "250 m" or "1.2 km".
    static func walkDistance(_ metres: Double) -> String {
        metres < 1_000 ? "\(Int(metres.rounded(to: 10))) m" : String(format: "%.1f km", metres / 1_000)
    }

    /// "4 min", at least 1.
    static func walkTime(_ seconds: Double) -> String { "\(max(1, Int((seconds / 60).rounded()))) min" }

    /// Drag to move a pointer along the route; shows the distance, street and air there.
    private var pointerControl: some View {
        let step = shape.step(atKm: pointerKm)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.1f", pointerKm)).font(.system(size: 30, weight: .light).monospacedDigit())
                Text("of \(PlannerModel.format(km: option.distanceKm))").foregroundStyle(.secondary)
                Spacer()
                if let step {
                    Circle().fill(step.band.color).frame(width: 9, height: 9)
                    Text("\(step.band.name) · \(Int(step.pm25.rounded()))").font(.subheadline)
                }
            }
            if showingPacePlan, let plan = pacePlan {
                Label("On your plan: \(RunFormat.duration(plan.elapsed(atKm: pointerKm))) here", systemImage: "stopwatch")
                    .font(.subheadline.weight(.medium).monospacedDigit())
            }
            Text(step?.displayName ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Slider(value: $pointerKm, in: 0...max(option.distanceKm, 0.1))
                .tint(Theme.ink)
                .accessibilityLabel("Position along the route")
                .sensoryFeedback(.selection, trigger: step?.kmFrom)
            if let elevation = option.elevation, elevation.points.count > 1 {
                Divider().padding(.vertical, 4)
                elevationChart(elevation)
            }
        }
    }

    /// How the ground rises and falls along the route, with a line that follows
    /// the slider (drag on the graph to move it too) and the climb totals.
    private func elevationChart(_ elevation: RouteOption.Elevation) -> some View {
        // A flat route should look flat: always show at least 30 m of height.
        let low = Double(elevation.minM) - 4
        let high = max(Double(elevation.maxM) + 4, low + 30)
        let here = elevation.metres(atKm: pointerKm) ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Elevation").font(.subheadline.weight(.semibold))
                Text(elevation.feel(distanceKm: option.distanceKm)).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(here.rounded())) m here").font(.subheadline.monospacedDigit())
            }
            Chart {
                ForEach(elevation.points) { point in
                    AreaMark(x: .value("km", point.km), yStart: .value("Base", low), yEnd: .value("Height", point.metres))
                        .foregroundStyle(LinearGradient(colors: [Theme.ink.opacity(0.22), Theme.ink.opacity(0.03)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("km", point.km), y: .value("Height", point.metres))
                        .foregroundStyle(Theme.ink)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                        .interpolationMethod(.monotone)
                }
                RuleMark(x: .value("Here", pointerKm))
                    .foregroundStyle(Theme.ink.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("Here", pointerKm), y: .value("Height", here))
                    .foregroundStyle(Theme.ink)
                    .symbolSize(50)
            }
            .chartXScale(domain: 0...max(option.distanceKm, 0.1))
            .chartYScale(domain: low...high)
            .chartXAxis {
                AxisMarks(values: .stride(by: option.distanceKm > 12 ? 2 : 1)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let km = value.as(Double.self) { Text("\(Int(km)) km") } }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let m = value.as(Double.self) { Text("\(Int(m)) m") } }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                            guard let plot = proxy.plotFrame else { return }
                            let x = drag.location.x - geometry[plot].origin.x
                            if let km: Double = proxy.value(atX: x) {
                                pointerKm = min(max(0, km), option.distanceKm)
                            }
                        })
                }
            }
            .frame(height: 130)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Elevation along the route")
            .accessibilityValue("\(elevation.climbM) metres of climbing, from \(elevation.minM) to \(elevation.maxM) metres. \(Int(here.rounded())) metres at the pointer.")
            HStack(spacing: 14) {
                Label("\(elevation.climbM) m climb", systemImage: "arrow.up.right")
                Label("\(elevation.descentM) m descent", systemImage: "arrow.down.right")
                Spacer()
                Text("\(elevation.minM) to \(elevation.maxM) m").foregroundStyle(.secondary)
            }
            .font(.footnote.monospacedDigit())
            Text("Approximate, from satellite terrain data. Flyovers and bridges are not included.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// The route's PM2.5 for each hour over the next day, best start marked.
    private var hourChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let best = option.bestStart {
                Text("Cleanest start: \(RouteText.time(best.time)) · \(AirBand(pm25: best.pm25).name)")
                    .font(.headline)
            }
            Chart(option.byHour) { hour in
                BarMark(x: .value("Hour", hour.time, unit: .hour), y: .value("PM2.5", hour.pm25))
                    .foregroundStyle(AirBand(pm25: hour.pm25).color.opacity(hour.time == option.bestStart?.time ? 1 : 0.6))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour(), centered: false)
                }
            }
            .chartYAxisLabel("PM2.5")
            .frame(height: 140)
            Text("Estimated average along this route for each start hour.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func stepRow(_ step: RouteStep) -> some View {
        Button {
            withAnimation(.snappy) { pointerKm = step.kmFrom + step.km / 2 }
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(step.band.color).frame(width: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.displayName)
                    Text("\(String(format: "%.2f", step.km)) km · \(step.road) · PM2.5 \(Int(step.pm25.rounded()))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format: "km %.1f", step.kmFrom)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

private extension Double {
    func rounded(to step: Double) -> Double { (self / step).rounded() * step }
}

/// A section that folds away: a title and a one-line summary with a chevron; tap to
/// show the full content. Keeps the route details short, as most people only need
/// the summary.
private struct Dropdown<Content: View>: View {
    let title: String
    let summary: String
    @Binding var isOpen: Bool
    @ViewBuilder let content: Content

    var body: some View {
        Button {
            withAnimation(.snappy) { isOpen.toggle() }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline.weight(.medium))
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(isOpen ? "Hides the details" : "Shows the details")
        if isOpen { content }
    }
}
