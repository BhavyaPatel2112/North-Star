import Charts
import MapKit
import SwiftUI

/// One route in detail: drag the pointer along it to see each street and how
/// clean it is, the cleanest time to start, street-by-street steps, and
/// pharmacies, water and clinics near the route.
struct RouteDetailView: View {
    let shape: RouteShape

    @State private var pointerKm: Double = 0
    @State private var stops: [NearbyPlaces.Stop] = []
    @State private var lookedForStops = false
    @Environment(\.openURL) private var openURL

    private var option: RouteOption { shape.option }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 14) {
                    RouteMap(shapes: [shape], selectedID: option.id, pointer: shape.point(atKm: pointerKm), stops: stops)
                        .frame(height: geometry.size.height * 0.42 + geometry.safeAreaInsets.top)
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 32, bottomTrailingRadius: 32, style: .continuous))

                    JourneyCard { pointerControl }.padding(.horizontal, 16)

                    if RouteText.finish(option) != nil || RouteText.busyWarning(option) != nil {
                        JourneyCard {
                            if let finish = RouteText.finish(option) { Label(finish, systemImage: "fork.knife") }
                            if let warning = RouteText.busyWarning(option) {
                                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                            if option.finishPlace?.rating != nil { CardNote(text: "Rating from Google.") }
                        }
                        .padding(.horizontal, 16)
                    }

                    JourneyCard(title: "When to go") { hourChart }.padding(.horizontal, 16)

                    JourneyCard(title: "Along the way") {
                        if stops.isEmpty {
                            CardNote(text: lookedForStops ? "Apple Maps shows no medical stores, shops or clinics near this route."
                                                          : "Looking for medical stores, water and clinics near the route…")
                        } else {
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
                        }
                        CardNote(text: "From Apple Maps. Opening hours are not always known, so check before you rely on a stop.")
                    }
                    .padding(.horizontal, 16)

                    JourneyCard(title: "Steps") {
                        ForEach(option.steps) { step in stepRow(step) }
                        CardNote(text: "Pollution is estimated for each street at your start time.")
                    }
                    .padding(.horizontal, 16)

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
        }
        .background(Theme.mist)
        .navigationTitle("\(PlannerModel.format(km: option.distanceKm)) \(option.isLoop ? "loop" : "one way")")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .task {
            stops = await NearbyPlaces.stops(along: shape)
            lookedForStops = true
            #if DEBUG
            for stop in stops { print("Stop:", stop.kind.rawValue, "|", stop.name, "|", Int(stop.offRouteM), "m off route at km", String(format: "%.1f", stop.atKm)) }
            #endif
        }
    }

    // MARK: - Pieces

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
