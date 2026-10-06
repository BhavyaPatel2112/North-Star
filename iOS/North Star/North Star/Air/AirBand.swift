import SwiftUI

/// India's National Air Quality Index bands for PM2.5 (fine particles), in µg/m³.
///
/// The official index uses 24-hour averages; the app applies the same edges to
/// hourly forecasts as an approximation, which is the usual practice in apps.
enum AirBand: Int, CaseIterable, Comparable {
    case good, satisfactory, moderate, poor, veryPoor, severe

    /// Upper edge of each band for PM2.5 (the last band has no upper edge).
    static let pm25Edges: [Double] = [30, 60, 90, 120, 250]

    /// From this PM2.5 value the app warns "may reach Moderate". Tested on past
    /// data: it caught 83% of bad-air hours while warning on 3.7% of clean hours.
    static let warnFrom: Double = 45

    init(pm25: Double) {
        let index = Self.pm25Edges.firstIndex { pm25 <= $0 } ?? Self.pm25Edges.count
        self = AirBand(rawValue: index) ?? .severe
    }

    static func < (lhs: AirBand, rhs: AirBand) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The official band name.
    var name: String {
        switch self {
        case .good: "Good"
        case .satisfactory: "Satisfactory"
        case .moderate: "Moderate"
        case .poor: "Poor"
        case .veryPoor: "Very poor"
        case .severe: "Severe"
        }
    }

    /// The one big word on the sky.
    var skyWord: String {
        switch self {
        case .good: "Clear"
        case .satisfactory: "Fair"
        case .moderate: "Hazy"
        case .poor: "Thick"
        case .veryPoor: "Heavy"
        case .severe: "Severe"
        }
    }

    /// One line of advice for someone thinking about a run.
    var runningAdvice: String {
        switch self {
        case .good: "Great air for a run. Go whenever suits you."
        case .satisfactory: "Fine for a run. Sensitive lungs: keep it easy."
        case .moderate: "Short, easy runs only. Carry your inhaler if you have asthma."
        case .poor: "Skip the outdoor run today or go indoors."
        case .veryPoor: "Stay in. Keep windows closed."
        case .severe: "Stay indoors. Avoid any exertion."
        }
    }

    /// Band colour (close to the official index colours, slightly softened).
    var color: Color {
        switch self {
        case .good: Color(red: 0.23, green: 0.62, blue: 0.36)
        case .satisfactory: Color(red: 0.61, green: 0.76, blue: 0.31)
        case .moderate: Color(red: 0.89, green: 0.74, blue: 0.20)
        case .poor: Color(red: 0.93, green: 0.55, blue: 0.21)
        case .veryPoor: Color(red: 0.84, green: 0.27, blue: 0.23)
        case .severe: Color(red: 0.56, green: 0.13, blue: 0.21)
        }
    }

    /// True when a Good or Satisfactory reading is close enough to Moderate to warn about.
    static func mayReachModerate(pm25: Double) -> Bool {
        pm25 >= warnFrom && AirBand(pm25: pm25) < .moderate
    }

    /// A smooth position from 0 (middle of Good) to 5 (Severe), used to blend sky colours
    /// so the sky changes gradually instead of jumping at band edges.
    static func continuousPosition(pm25: Double) -> Double {
        let edges = [0.0] + pm25Edges + [400]
        for i in 0..<(edges.count - 1) where pm25 <= edges[i + 1] {
            let fraction = (pm25 - edges[i]) / (edges[i + 1] - edges[i])
            return min(5, max(0, Double(i) + fraction - 0.5))
        }
        return 5
    }
}
