import CoreLocation
import SwiftUI

/// One page of the Today tab: the journey landscape for one place (its mist and
/// light follow the air and the hour), the air in a few words, two glass cards,
/// and below, the timeline and advice.
/// Drag sideways anywhere to move through the next 36 hours; the pager around
/// it moves between places when you swipe up or down.
struct SkyScreen: View {
    let location: LocationProvider
    /// Safe-area space at the top and bottom of the screen (the pager draws edge to edge).
    let insets: EdgeInsets
    /// True while the user drags through time, so the pager pauses vertical scrolling.
    @Binding var scrubbing: Bool
    let onShowPlaces: () -> Void
    let onPlanRun: (Place) -> Void
    let onShowJourney: () -> Void

    @State private var model: SkyModel
    @State private var dragStart: Double?
    @Environment(\.scenePhase) private var scenePhase

    init(place: Place, location: LocationProvider, insets: EdgeInsets, scrubbing: Binding<Bool>,
         hoursAhead: Int = 0, onShowPlaces: @escaping () -> Void, onPlanRun: @escaping (Place) -> Void,
         onShowJourney: @escaping () -> Void) {
        self.location = location
        self.insets = insets
        self._scrubbing = scrubbing
        self.onShowPlaces = onShowPlaces
        self.onPlanRun = onPlanRun
        self.onShowJourney = onShowJourney
        self._model = State(initialValue: SkyModel(place: place, hoursAhead: hoursAhead))
    }

    /// Points of horizontal drag per hour.
    private let pointsPerHour: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                hero
                    .frame(height: max(440, geometry.size.height * 0.63))
                lower
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(Theme.mist)
        .contentShape(Rectangle())
        .simultaneousGesture(scrub)
        .sensoryFeedback(.selection, trigger: model.reading?.band)
        .task { refresh() }
        .onChange(of: location.state) { handleLocation() }
        .onChange(of: scenePhase) { if scenePhase == .active, model.needsRefresh { refresh(keepPosition: true) } }
    }

    // MARK: - The landscape and what sits on it

    private var hero: some View {
        ZStack {
            ForecastLandscape(position: model.position, track: model.track)
            // A gentle shade low down, so the white words and cards stay readable on pale snow.
            LinearGradient(colors: [.clear, .black.opacity(0.3)],
                           startPoint: UnitPoint(x: 0.5, y: 0.4), endPoint: .bottom)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack {
                    placeButton
                    Spacer()
                }
                .padding(.top, insets.top + 6)
                Spacer(minLength: 12)
                headline
                Spacer().frame(height: 26)
                cards
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 36, bottomTrailingRadius: 36, style: .continuous))
        .ignoresSafeArea(edges: .top)
    }

    private var placeButton: some View {
        Button(action: onShowPlaces) {
            HStack(spacing: 6) {
                Image(systemName: model.place == .current ? "location.fill" : "mappin.and.ellipse")
                    .font(.footnote)
                Text(model.place.name).font(.subheadline.weight(.medium))
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .northGlass(in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Place: \(model.place.name). Opens your places.")
    }

    /// The air in a few words, Ro-style: one line, then a fainter second line.
    @ViewBuilder
    private var headline: some View {
        VStack(spacing: 10) {
            switch model.status {
            case .loading:
                bigWords("Reading", "the sky…")
            case .locationOff:
                bigWords("Where to?", "Choose a place.")
            case .outsideCoverage:
                bigWords("Out of range.", "Choose a Mumbai place.")
            case .failed(let text):
                bigWords("No reading.", "Try again.")
                Text(text).font(.footnote).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
            case .ready:
                if let reading = model.reading {
                    bigWords("\(reading.band.skyWord).", reading.band.shortLine)
                    caption(reading)
                }
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.2), radius: 10, y: 1)
        .frame(maxWidth: .infinity)
    }

    private func bigWords(_ first: String, _ second: String) -> some View {
        VStack(spacing: 0) {
            Text(first)
            Text(second).opacity(0.6)
        }
        .font(.system(size: 42, weight: .regular))
        .multilineTextAlignment(.center)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .contentTransition(.opacity)
    }

    /// "Now · Satisfactory · PM2.5 48 · Estimated", and the Moderate warning when it applies.
    private func caption(_ reading: HourReading) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 7) {
                Circle().fill(reading.band.color).frame(width: 8, height: 8)
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                Text("\(timeLabel) · \(reading.band.name) · PM2.5 \(Int(reading.pm25Value.rounded()))")
                Text("ESTIMATED")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.6), lineWidth: 1))
            }
            if AirBand.mayReachModerate(pm25: reading.pm25Value) {
                Text("May reach Moderate")
            }
        }
        .font(.footnote.weight(.medium))
        .monospacedDigit()
    }

    /// Two glass cards: plan a run from here, and the most useful time action.
    @ViewBuilder
    private var cards: some View {
        HStack(spacing: 12) {
            switch model.status {
            case .ready:
                GlassCard(title: "Plan a run", systemImage: "figure.run") { onPlanRun(model.place) }
                timeCard
            case .failed:
                GlassCard(title: "Try again", systemImage: "arrow.clockwise") { refresh() }
                GlassCard(title: "Your places", systemImage: "mappin.and.ellipse", action: onShowPlaces)
            case .locationOff, .outsideCoverage:
                GlassCard(title: "Choose a place", systemImage: "mappin.and.ellipse", action: onShowPlaces)
                GlassCard(title: "Your journey", systemImage: "star", action: onShowJourney)
            case .loading:
                GlassCard(title: "Plan a run", systemImage: "figure.run") { onPlanRun(model.place) }
                GlassCard(title: "Your journey", systemImage: "star", action: onShowJourney)
            }
        }
    }

    /// Back to now when looking ahead; otherwise the cleanest time today, if clearly
    /// cleaner than now; otherwise the journey.
    @ViewBuilder
    private var timeCard: some View {
        if model.index != model.nowIndex {
            GlassCard(title: "Back to now", systemImage: "arrow.uturn.backward") {
                withAnimation(.smooth(duration: 0.9)) { model.position = Double(model.nowIndex) }
            }
        } else if let reading = model.reading, let best = bestWindowSuggestion(currentPM25: reading.pm25Value),
                  let start = model.forecast?.hours[best.index].start {
            GlassCard(title: "Cleanest at \(Self.time(start))", systemImage: "sun.horizon") {
                withAnimation(.smooth(duration: 0.9)) { model.position = Double(best.index) }
            }
        } else {
            GlassCard(title: "Your journey", systemImage: "star", action: onShowJourney)
        }
    }

    // MARK: - Below the landscape

    private var lower: some View {
        VStack(spacing: 16) {
            if model.status == .ready { timeline }
            if let reading = model.reading, model.status == .ready {
                Text(reading.band.runningAdvice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            VStack(spacing: 3) {
                Text("North Star")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Keep going.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 26)
        .padding(.top, 18)
        .padding(.bottom, insets.bottom + 10)
    }

    private var timeline: some View {
        let count = model.forecast?.hours.count ?? 1
        let fraction = count > 1 ? model.position / Double(count - 1) : 0
        let ahead = model.index - model.nowIndex
        return VStack(spacing: 8) {
            HStack {
                Text(timeLabel).font(.subheadline.weight(.semibold))
                Spacer()
                Text(ahead > 0 ? "in \(ahead) h" : ahead < 0 ? "\(-ahead) h ago" : "next 36 hours")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.15)).frame(height: 3)
                    Capsule().fill(.primary.opacity(0.55)).frame(width: max(0, geometry.size.width * fraction), height: 3)
                    Circle().fill(.primary).frame(width: 14, height: 14)
                        .offset(x: geometry.size.width * fraction - 7)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 16)
            Text("Drag the landscape to look ahead")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let madeAt = model.forecast?.madeAt, Date.now.timeIntervalSince(madeAt) > 3 * 3600 {
                Text("Forecast from \(Int(Date.now.timeIntervalSince(madeAt) / 3600)) hours ago")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Showing \(timeLabel)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.position = Double(min(model.index + 1, (model.forecast?.hours.count ?? 1) - 1))
            case .decrement: model.position = Double(max(model.index - 1, 0))
            @unknown default: break
            }
        }
    }

    // MARK: - Behaviour

    /// Sideways drag moves through time. A drag that starts mostly up or down is
    /// left to the pager (to change place); once a sideways drag starts, the pager
    /// pauses so the two never fight.
    private var scrub: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard model.status == .ready, let count = model.forecast?.hours.count else { return }
                if dragStart == nil {
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    dragStart = model.position
                    scrubbing = true
                }
                let target = dragStart! + Double(value.translation.width / pointsPerHour)
                model.position = min(Double(count - 1), max(0, target))
            }
            .onEnded { value in
                guard let start = dragStart, let count = model.forecast?.hours.count else { return }
                dragStart = nil
                scrubbing = false
                // A quick flick carries on a little (up to 4 hours), like flicking a
                // list, then settles on a whole hour with a soft spring.
                let flick = (value.predictedEndTranslation.width - value.translation.width) / pointsPerHour
                let target = start + Double(value.translation.width / pointsPerHour) + min(4, max(-4, Double(flick)))
                withAnimation(.smooth(duration: 0.45)) {
                    model.position = min(Double(count - 1), max(0, target.rounded()))
                }
            }
    }

    private func refresh(keepPosition: Bool = false) {
        if let coordinate = model.place.coordinate {
            Task { await model.load(latitude: coordinate.latitude, longitude: coordinate.longitude, keepPosition: keepPosition) }
        } else {
            location.locate()
        }
    }

    private func handleLocation() {
        guard model.place == .current else { return }
        switch location.state {
        case .found(let coordinate):
            Task { await model.load(latitude: coordinate.latitude, longitude: coordinate.longitude) }
        case .denied, .failed:
            model.showLocationOff()
        default:
            break
        }
    }

    // MARK: - Text

    /// Suggest the best window only if it is clearly cleaner than now.
    private func bestWindowSuggestion(currentPM25: Double) -> (index: Int, pm25: Double)? {
        guard let best = model.forecast?.bestWindow(), best.pm25 + 5 < currentPM25 else { return nil }
        return best
    }

    private var timeLabel: String {
        guard let start = model.reading?.start else { return "" }
        if model.index == model.nowIndex { return "Now" }
        let sameDay = Calendar.mumbai.isDate(start, inSameDayAs: .now)
        return sameDay ? Self.time(start) : "\(Self.weekday(start)) \(Self.time(start))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Kolkata")
        formatter.locale = Locale(identifier: "en_IN")
        formatter.dateFormat = "h:mm a"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Kolkata")
        formatter.locale = Locale(identifier: "en_IN")
        formatter.dateFormat = "EEE"
        return formatter
    }()

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }
    static func weekday(_ date: Date) -> String { weekdayFormatter.string(from: date) }
}

#Preview {
    SkyScreen(place: Place.runningSpots[0], location: LocationProvider(), insets: EdgeInsets(),
              scrubbing: .constant(false), onShowPlaces: {}, onPlanRun: { _ in }, onShowJourney: {})
}
