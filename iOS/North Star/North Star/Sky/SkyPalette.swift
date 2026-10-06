import SwiftUI

/// The colours of the sky for a given pollution level and time of day.
///
/// Each band has a daytime sky (top colour and horizon colour). Between bands
/// the colours blend smoothly, and towards night they mix into deep blue, so
/// the sky reads like the real sky over Mumbai at that hour.
struct SkyPalette {
    /// Red, green, blue in 0...1.
    struct RGB {
        var r, g, b: Double
        init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
        init(hex: UInt32) {
            self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
        }
        func mixed(with other: RGB, _ t: Double) -> RGB {
            RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
        }
        var color: Color { Color(red: r, green: g, blue: b) }
    }

    /// Daytime sky per band: (top, horizon). Clear blue through haze to brown.
    static let daySkies: [(RGB, RGB)] = [
        (RGB(hex: 0x3F8FD2), RGB(hex: 0xBFE0F4)),  // Good
        (RGB(hex: 0x6F9FBF), RGB(hex: 0xD9E2D6)),  // Satisfactory
        (RGB(hex: 0xA7A184), RGB(hex: 0xE6D7B4)),  // Moderate
        (RGB(hex: 0x9A8068), RGB(hex: 0xD8BD98)),  // Poor
        (RGB(hex: 0x76604F), RGB(hex: 0xB39579)),  // Very poor
        (RGB(hex: 0x54413A), RGB(hex: 0x8A6F61)),  // Severe
    ]
    static let nightTop = RGB(hex: 0x0E1A33)
    static let nightHorizon = RGB(hex: 0x2A3550)
    static let hazeTint = RGB(hex: 0xEBDCBE)

    let top: RGB
    let horizon: RGB
    /// 0 in daylight, up to about 0.8 at night.
    let darkness: Double
    /// 0 for clean air, 1 for very polluted air (controls haze and skyline fading).
    let haze: Double

    init(pm25: Double, hourOfDay: Double) {
        let position = AirBand.continuousPosition(pm25: pm25)
        let lower = Int(position.rounded(.down)), upper = min(5, lower + 1), t = position - Double(lower)
        let dayTop = Self.daySkies[lower].0.mixed(with: Self.daySkies[upper].0, t)
        let dayHorizon = Self.daySkies[lower].1.mixed(with: Self.daySkies[upper].1, t)

        darkness = Self.darkness(hourOfDay: hourOfDay)
        top = dayTop.mixed(with: Self.nightTop, darkness)
        horizon = dayHorizon.mixed(with: Self.nightHorizon, darkness * 0.9)
        haze = min(1, max(0, (pm25 - 15) / 110))
    }

    /// Full night from 8 pm to 5 am, with dusk (6:30 to 8 pm) and dawn (5 to 6:30 am) in between.
    static func darkness(hourOfDay h: Double) -> Double {
        let night = 0.82
        if h >= 20 || h < 5 { return night }
        if h >= 18.5 { return (h - 18.5) / 1.5 * night }
        if h < 6.5 { return (6.5 - h) / 1.5 * night }
        return 0
    }
}
