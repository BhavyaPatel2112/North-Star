import CoreLocation
import Foundation
import Observation

/// Everything the sky screen shows: which place, its forecast, and which hour
/// the user is looking at.
@Observable
final class SkyModel {
    enum Status: Equatable {
        case loading
        case ready
        case locationOff
        case outsideCoverage
        case failed(String)
    }

    let place: Place
    private(set) var forecast: Forecast?
    private(set) var status: Status = .loading
    /// The hour being shown, as a position in the forecast (fractional while dragging).
    var position: Double = 0

    private let service = ForecastService()
    private var lastLoaded: Date?

    /// How many hours ahead to open at (used by debug screenshots; normally 0 = now).
    private var launchHoursAhead: Int

    init(place: Place, hoursAhead: Int = 0) {
        self.place = place
        self.launchHoursAhead = hoursAhead
    }

    /// The hour index currently shown (rounded).
    var index: Int {
        guard let forecast, !forecast.hours.isEmpty else { return 0 }
        return min(forecast.hours.count - 1, max(0, Int(position.rounded())))
    }

    var nowIndex: Int { forecast?.currentIndex() ?? 0 }

    /// PM2.5 at the exact (possibly fractional) position, so colours glide while dragging.
    var smoothPM25: Double {
        guard let hours = forecast?.hours, !hours.isEmpty else { return 20 }
        let lower = min(hours.count - 1, max(0, Int(position.rounded(.down))))
        let upper = min(hours.count - 1, lower + 1)
        let t = position - Double(lower)
        return hours[lower].pm25Value + (hours[upper].pm25Value - hours[lower].pm25Value) * t
    }

    /// Hour of day on a Mumbai clock at the shown position (fractional while dragging).
    var smoothHourOfDay: Double {
        guard let hours = forecast?.hours, !hours.isEmpty else {
            return Self.hourOfDay(.now)
        }
        let lower = min(hours.count - 1, max(0, Int(position.rounded(.down))))
        return (Self.hourOfDay(hours[lower].start) + (position - Double(lower))).truncatingRemainder(dividingBy: 24)
    }

    var reading: HourReading? { forecast?.hours[safe: index] }

    private var isLoading = false

    /// Loads the forecast for a coordinate. A first load (or a new place) starts at the
    /// current hour; a refresh keeps the user on the same number of hours ahead.
    func load(latitude: Double, longitude: Double, keepPosition: Bool = false) async {
        guard !isLoading else { return }  // the screen can ask twice at start-up; one request is enough
        isLoading = true
        defer { isLoading = false }
        if forecast == nil { status = .loading }
        let hoursAhead = keepPosition && forecast != nil ? index - nowIndex : launchHoursAhead
        do {
            let result = try await service.forecast(latitude: latitude, longitude: longitude)
            forecast = result
            lastLoaded = .now
            position = Double(min(result.hours.count - 1, max(0, result.currentIndex() + hoursAhead)))
            launchHoursAhead = 0
            status = result.isInsideCoverage ? .ready : .outsideCoverage
        } catch {
            status = .failed((error as? LocalizedError)?.errorDescription ?? "Could not load the forecast. Check your connection.")
        }
    }

    func showLocationOff() { status = .locationOff; forecast = nil }

    /// True when the data is old enough to fetch again (the backend updates hourly).
    var needsRefresh: Bool {
        guard let lastLoaded else { return true }
        return Date.now.timeIntervalSince(lastLoaded) > 20 * 60
    }

    static func hourOfDay(_ date: Date) -> Double {
        let parts = Calendar.mumbai.dateComponents([.hour, .minute], from: date)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
