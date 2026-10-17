import CoreLocation
import Foundation

/// How a run will feel: "feels like" temperature, a score that balances air and heat,
/// and sunrise and sunset. The same rules as the route server (northstar/routing/comfort.py).
enum Comfort {
    /// Up to here, heat does not count against a time.
    static let comfortableC = 27.0
    /// 3 °C of "feels like" costs as much as one air band (about 30 µg/m³ of PM2.5).
    static let degreesPerBand = 3.0
    static let pm25PerBand = 30.0

    /// Heat index in °C (how hot it feels once humidity is counted), using the US National
    /// Weather Service formula. Below about 27 °C humidity matters little.
    static func feelsLike(temperatureC: Double, humidity rh: Double) -> Double {
        let t = temperatureC * 9 / 5 + 32
        let simple = 0.5 * (t + 61 + (t - 68) * 1.2 + rh * 0.094)
        var f: Double
        if (simple + t) / 2 < 80 {
            f = simple
        } else {
            f = -42.379 + 2.04901523 * t + 10.14333127 * rh - 0.22475541 * t * rh - 0.00683783 * t * t
                - 0.05481717 * rh * rh + 0.00122874 * t * t * rh + 0.00085282 * t * rh * rh
                - 0.00000199 * t * t * rh * rh
            if rh < 13 && (80...112).contains(t) {
                f -= (13 - rh) / 4 * ((17 - abs(t - 95)) / 17).squareRoot()
            } else if rh > 85 && (80...87).contains(t) {
                f += (rh - 85) / 10 * (87 - t) / 5
            }
        }
        return (f - 32) * 5 / 9
    }

    /// Lower is better: air bands plus heat bands above a comfortable 27 °C.
    static func runScore(pm25: Double, feelsLike: Double?) -> Double {
        let heat = feelsLike.map { max(0, $0 - comfortableC) / degreesPerBand } ?? 0
        return pm25 / pm25PerBand + heat
    }

    /// "Feels like 33°C · 78% humidity", or nil without weather.
    static func line(feelsLike: Double?, humidity: Double?) -> String? {
        guard let feelsLike else { return nil }
        var text = "Feels like \(Int(feelsLike.rounded()))°C"
        if let humidity { text += " · \(Int(humidity.rounded()))% humidity" }
        return text
    }

    // MARK: - Sunrise and sunset

    /// Sunrise and sunset on the day of `date` at a place (NOAA's solar calculation;
    /// accurate to a minute or two, which is plenty for planning a run).
    static func sunTimes(on date: Date, at place: CLLocationCoordinate2D = Mumbai.centre) -> (rise: Date, set: Date)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.startOfDay(for: date)
        let n = Double(calendar.ordinality(of: .day, in: .year, for: day) ?? 1)
        let lat = place.latitude * .pi / 180
        // Fractional year (radians), equation of time (minutes) and solar declination.
        let g = 2 * Double.pi / 365 * (n - 1 + 0.5)
        let eqTime = 229.18 * (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g) - 0.014615 * cos(2 * g) - 0.040849 * sin(2 * g))
        let decl = 0.006918 - 0.399912 * cos(g) + 0.070257 * sin(g) - 0.006758 * cos(2 * g)
            + 0.000907 * sin(2 * g) - 0.002697 * cos(3 * g) + 0.00148 * sin(3 * g)
        // The sun's centre 0.833° below the horizon (refraction and the sun's size).
        let cosHA = (cos(90.833 * .pi / 180) / (cos(lat) * cos(decl))) - tan(lat) * tan(decl)
        guard (-1...1).contains(cosHA) else { return nil }
        let ha = acos(cosHA) * 180 / .pi
        let noonMinutes = 720 - 4 * place.longitude - eqTime          // minutes after midnight UTC
        let rise = day.addingTimeInterval((noonMinutes - 4 * ha) * 60)
        let set = day.addingTimeInterval((noonMinutes + 4 * ha) * 60)
        return (rise, set)
    }
}

enum Mumbai {
    static let centre = CLLocationCoordinate2D(latitude: 19.07, longitude: 72.87)
}
