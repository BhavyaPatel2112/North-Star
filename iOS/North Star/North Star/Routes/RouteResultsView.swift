import MapKit
import SwiftUI

/// Up to 3 route options on one map. The selected route is coloured stretch by
/// stretch (green = cleaner, orange and red = dirtier); the others are grey.
struct RouteResultsView: View {
    let plan: RoutePlan
    let model: PlannerModel

    @State private var selectedID: UUID?
    /// Debug only: opens the first route's details straight away ("-planDetail YES").
    @State private var debugDetail = false

    init(plan: RoutePlan, model: PlannerModel) {
        self.plan = plan
        self.model = model
        _selectedID = State(initialValue: plan.options.first?.id)
    }

    var body: some View {
        // Cheap to rebuild (a few hundred points), so worked out on each update.
        let shapes = plan.options.map { RouteShape($0) }
        let selected = shapes.first { $0.option.id == selectedID } ?? shapes.first
        return GeometryReader { geometry in
            VStack(spacing: 0) {
                // The map as the landscape: full width, rounded at the bottom, under the bar.
                RouteMap(shapes: shapes, selectedID: selected?.option.id)
                    .frame(height: geometry.size.height * 0.48 + geometry.safeAreaInsets.top)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 32, bottomTrailingRadius: 32, style: .continuous))

                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(Array(shapes.enumerated()), id: \.element.option.id) { index, shape in
                            optionCard(shape.option, number: index + 1, isSelected: shape.option.id == selected?.option.id)
                        }
                        VStack(spacing: 4) {
                            CardNote(text: "Pollution is estimated for your start time. Colours on the map show cleaner and dirtier stretches.")
                            if plan.foodSource == "google" { CardNote(text: "Restaurant ratings from Google.") }
                        }
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                    }
                    .padding(16)
                }
                .scrollIndicators(.hidden)
            }
            .ignoresSafeArea(edges: .top)
        }
        .background(Theme.mist)
        .navigationTitle("\(shapes.count) route\(shapes.count == 1 ? "" : "s")")
        #if os(iOS)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        #if DEBUG
        .navigationDestination(isPresented: $debugDetail) {
            if let first = plan.options.first { RouteDetailView(shape: RouteShape(first)) }
        }
        .onAppear { if UserDefaults.standard.bool(forKey: "planDetail") { debugDetail = true } }
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// One option as a card: tap to show it on the map, "Details" to open it.
    private func optionCard(_ option: RouteOption, number: Int, isSelected: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                withAnimation(.snappy) { selectedID = option.id }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? Theme.ink : .secondary)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(PlannerModel.format(km: option.distanceKm))
                                .font(.system(size: 26, weight: .light).monospacedDigit())
                            Text(option.band.skyWord).font(.headline.weight(.regular))
                            Circle().fill(option.band.color).frame(width: 9, height: 9)
                        }
                        if let finish = RouteText.finish(option) {
                            Text(finish).font(.subheadline)
                        }
                        Text(RouteText.summary(option)).font(.subheadline).foregroundStyle(.secondary)
                        if let warning = RouteText.busyWarning(option) {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.subheadline).foregroundStyle(.orange)
                        }
                        if let best = option.bestStart {
                            Text("Cleanest start \(RouteText.time(best.time)) (PM2.5 \(Int(best.pm25.rounded())))")
                                .font(.subheadline)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            NavigationLink { RouteDetailView(shape: RouteShape(option)) } label: {
                HStack(spacing: 3) {
                    Text("Details")
                    Image(systemName: "chevron.right").font(.caption.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.ink.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(isSelected ? Theme.ink.opacity(0.35) : .clear, lineWidth: 1.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Option \(number)")
    }
}

/// The map used by both route screens.
struct RouteMap: View {
    let shapes: [RouteShape]
    var selectedID: UUID?
    /// Optional pointer (the place you are looking at along the route).
    var pointer: CLLocationCoordinate2D?
    var stops: [NearbyPlaces.Stop] = []

    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera) {
            // Unselected routes first (underneath), in grey.
            ForEach(shapes.filter { $0.option.id != selectedID }, id: \.option.id) { shape in
                MapPolyline(coordinates: shape.option.line)
                    .stroke(.gray.opacity(0.55), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if let shape = shapes.first(where: { $0.option.id == selectedID }) {
                // A dark outline under the coloured stretches keeps pale colours visible.
                MapPolyline(coordinates: shape.option.line)
                    .stroke(.black.opacity(0.35), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                ForEach(shape.stretches) { stretch in
                    MapPolyline(coordinates: stretch.coordinates)
                        .stroke(stretch.band.color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                if let start = shape.start {
                    Annotation("Start", coordinate: start) { marker("figure.walk", .white, Theme.ink) }
                }
                if let finish = shape.finish, !shape.option.isLoop {
                    Annotation(shape.option.finishPlace?.name ?? "Finish", coordinate: finish) {
                        marker("flag.checkered", .black, .white)
                    }
                }
            }
            ForEach(stops) { stop in
                Annotation(stop.name, coordinate: stop.coordinate) {
                    marker(stop.kind.symbol, .white, Color(red: 0.2, green: 0.45, blue: 0.52))
                }
            }
            if let pointer {
                Annotation("", coordinate: pointer) {
                    Circle().fill(.white).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(.black, lineWidth: 3))
                        .shadow(radius: 2)
                }
            }
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .onChange(of: selectedID) { camera = .automatic }
    }

    private func marker(_ symbol: String, _ foreground: Color, _ background: Color) -> some View {
        Image(systemName: symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(foreground)
            .padding(6)
            .background(Circle().fill(background))
    }
}

/// Small shared text helpers for the route screens.
enum RouteText {
    static func summary(_ option: RouteOption) -> String {
        var parts = [option.label]
        if let pct = option.cleanerThanDirectPct, pct >= 2 {
            parts.append("\(pct)% cleaner than the plain route")
        }
        if !option.walkCheck.checked { parts.append("not checked against walking directions") }
        return parts.joined(separator: " · ")
    }

    /// "Ends at McDonald's · 4.3★ (2,140 reviews)".
    static func finish(_ option: RouteOption) -> String? {
        guard let place = option.finishPlace else { return nil }
        var text = "Ends at \(place.name)"
        if let rating = place.rating {
            text += String(format: " · %.1f★", rating)
            if let reviews = place.reviews { text += " (\(reviews.formatted()) reviews)" }
        }
        return text
    }

    /// A warning when the route crosses a highway or uses main roads (only when the user allowed it).
    static func busyWarning(_ option: RouteOption) -> String? {
        var parts: [String] = []
        if option.highwayCrossings == 1 { parts.append("Crosses a highway") }
        if option.highwayCrossings > 1 { parts.append("Crosses highways \(option.highwayCrossings) times") }
        if option.busyKm >= 0.3 { parts.append(String(format: "%.1f km on main roads", option.busyKm)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func time(_ date: Date) -> String { SkyScreen.time(date) }
}
