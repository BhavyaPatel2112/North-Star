import CoreLocation
import SwiftUI

/// The main screen: the sky for one place, one big word, one tip.
/// Drag sideways anywhere to move through the next 36 hours.
struct SkyScreen: View {
    @State private var model = SkyModel()
    @State private var location = LocationProvider()
    @State private var dragStart: Double?
    @Environment(\.scenePhase) private var scenePhase

    /// Points of horizontal drag per hour.
    private let pointsPerHour: CGFloat = 14

    var body: some View {
        ZStack {
            SkyCanvas(pm25: model.smoothPM25, hourOfDay: model.smoothHourOfDay)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                placeMenu
                Spacer(minLength: 24)
                centre
                Spacer(minLength: 24)
                if model.status == .ready { timeline }
            }
            .frame(maxWidth: .infinity, alignment: .leading)  // keep everything left-aligned in every state
            .padding(.horizontal, 26)
            .padding(.top, 8)
            .padding(.bottom, 18)
            .foregroundStyle(ink)
            .tint(ink)
            .shadow(color: .black.opacity(ink == .white ? 0.15 : 0), radius: 10, y: 1)
            .animation(.easeInOut(duration: 0.4), value: ink == .white)
        }
        .contentShape(Rectangle())
        .gesture(scrub)
        .sensoryFeedback(.selection, trigger: model.reading?.band)
        .task { refresh() }
        .onChange(of: model.place) { refresh() }
        .onChange(of: location.state) { handleLocation() }
        .onChange(of: scenePhase) { if scenePhase == .active, model.needsRefresh { refresh(keepPosition: true) } }
    }

    /// Text colour that stays readable on the current sky.
    private var ink: Color {
        SkyPalette(pm25: model.smoothPM25, hourOfDay: model.smoothHourOfDay).ink
    }

    // MARK: - Pieces

    private var placeMenu: some View {
        Menu {
            Picker("Place", selection: $model.place) {
                ForEach(model.places) { place in
                    Label(place.name, systemImage: place == .current ? "location.fill" : "mappin")
                        .tag(place)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.place == .current ? "location.fill" : "mappin.and.ellipse")
                    .font(.footnote)
                Text(model.place.name).font(.body.weight(.medium))
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
        }
        .accessibilityLabel("Place: \(model.place.name)")
    }

    @ViewBuilder
    private var centre: some View {
        switch model.status {
        case .loading:
            message(title: "…", text: "Reading the sky")
        case .locationOff:
            message(title: "Where to?", text: "Location is off. Pick a place above to see its sky, or allow location in Settings.")
        case .outsideCoverage:
            message(title: "Out of range", text: "North Star covers Mumbai, Thane, Navi Mumbai and Mira-Bhayandar. Pick a place above.")
        case .failed(let text):
            VStack(alignment: .leading, spacing: 14) {
                message(title: "No sky", text: text)
                Button("Try again") { refresh() }
                    .buttonStyle(.bordered)
            }
        case .ready:
            if let reading = model.reading {
                readingView(reading)
            }
        }
    }

    private func readingView(_ reading: HourReading) -> some View {
        let band = reading.band
        let pm25 = reading.pm25Value
        return VStack(alignment: .leading, spacing: 12) {
            Text(band.skyWord)
                .font(.system(size: 96, weight: .heavy))
                .fontWidth(.condensed)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .contentTransition(.opacity)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(band.color).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(ink.opacity(0.85), lineWidth: 2))
                    Text("\(band.name) · PM2.5 \(Int(pm25.rounded()))")
                }
                .font(.callout.weight(.medium))
                if AirBand.mayReachModerate(pm25: pm25) {
                    Text("May reach Moderate")
                        .font(.callout)
                        .padding(.leading, 18)
                        .opacity(0.9)
                }
            }
            Text(band.runningAdvice)
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
            if model.index == model.nowIndex, let best = bestWindowSuggestion(currentPM25: pm25) {
                Button {
                    withAnimation(.easeInOut(duration: 0.8)) { model.position = Double(best.index) }
                } label: {
                    Text("Cleanest around \(Self.time(model.forecast!.hours[best.index].start)) →")
                        .font(.callout.weight(.semibold))
                        .underline()
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.position = Double(min(model.index + 1, (model.forecast?.hours.count ?? 1) - 1))
            case .decrement: model.position = Double(max(model.index - 1, 0))
            @unknown default: break
            }
        }
    }

    private var timeline: some View {
        let count = model.forecast?.hours.count ?? 1
        let fraction = count > 1 ? model.position / Double(count - 1) : 0
        let ahead = model.index - model.nowIndex
        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(timeLabel).font(.callout.weight(.semibold))
                Text("Estimated")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(ink.opacity(0.6), lineWidth: 1))
                Spacer()
                Text(ahead > 0 ? "in \(ahead) h" : ahead < 0 ? "\(-ahead) h ago" : "")
                    .font(.footnote.monospacedDigit())
                    .opacity(0.8)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.opacity(0.35)).frame(height: 2)
                    Circle().fill(ink).frame(width: 16, height: 16)
                        .offset(x: geometry.size.width * fraction - 8)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 20)
            Text("Drag anywhere to look ahead")
                .font(.caption.monospaced())
                .opacity(0.75)
                .frame(maxWidth: .infinity)
            if let madeAt = model.forecast?.madeAt, Date.now.timeIntervalSince(madeAt) > 3 * 3600 {
                Text("Forecast from \(Int(Date.now.timeIntervalSince(madeAt) / 3600)) hours ago")
                    .font(.caption).opacity(0.8)
            }
        }
    }

    private func message(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 64, weight: .heavy)).fontWidth(.condensed)
            Text(text).font(.title3).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Behaviour

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard model.status == .ready, let count = model.forecast?.hours.count else { return }
                if dragStart == nil { dragStart = model.position }
                let target = dragStart! + Double(value.translation.width / pointsPerHour)
                model.position = min(Double(count - 1), max(0, target))
            }
            .onEnded { _ in
                dragStart = nil
                withAnimation(.easeOut(duration: 0.2)) { model.position = model.position.rounded() }
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
    SkyScreen()
}
