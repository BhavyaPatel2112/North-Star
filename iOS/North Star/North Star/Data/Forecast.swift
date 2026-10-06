import Foundation

/// The forecast for one place, as returned by the backend's app_forecast function.
struct Forecast: Decodable, Equatable {
    /// The map hexagon the place falls in.
    let h3: String
    /// City area the hexagon belongs to, for example "Mumbai Suburban District".
    let area: String?
    /// Distance from the requested point to the hexagon's centre. Large values
    /// mean the point is outside the area North Star covers.
    let distanceM: Double
    /// When the backend made this forecast.
    let madeAt: Date?
    /// One entry per hour, in time order.
    let hours: [HourReading]

    enum CodingKeys: String, CodingKey {
        case h3, area, hours
        case distanceM = "distance_m"
        case madeAt = "made_at"
    }

    /// Points further than this from any hexagon are outside our coverage.
    static let coverageLimitM: Double = 1_500

    var isInsideCoverage: Bool { distanceM <= Self.coverageLimitM }

    /// Index of the hour that contains the current time (or the closest one).
    func currentIndex(now: Date = .now) -> Int {
        hours.lastIndex { $0.start <= now } ?? 0
    }

    /// The cleanest two-hour stretch for a run in the next 24 hours,
    /// between 5 am and 10 pm in Mumbai.
    func bestWindow(now: Date = .now) -> (index: Int, pm25: Double)? {
        let start = currentIndex(now: now)
        let end = min(hours.count - 1, start + 24)
        var best: (index: Int, pm25: Double)?
        guard start < end else { return nil }
        for i in start..<end {
            let hour = Calendar.mumbai.component(.hour, from: hours[i].start)
            guard (5...21).contains(hour) else { continue }
            let average = (hours[i].pm25Value + hours[i + 1].pm25Value) / 2
            if best == nil || average < best!.pm25 - 0.5 { best = (i, average) }
        }
        return best
    }
}

/// Predicted pollution for one hour, in µg/m³.
struct HourReading: Decodable, Equatable {
    /// Start of the hour.
    let start: Date
    let pm25: Double?
    let pm10: Double?
    let no2: Double?
    let o3: Double?

    enum CodingKeys: String, CodingKey {
        case start = "ts", pm25, pm10, no2, o3
    }

    var pm25Value: Double { pm25 ?? 0 }
    var band: AirBand { AirBand(pm25: pm25Value) }
}

extension Calendar {
    /// Calendar in India time, so "hour of day" means the hour on a Mumbai clock.
    static let mumbai: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()
}
