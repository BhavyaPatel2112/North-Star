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
        /// Perceived brightness, 0 (black) to 1 (white).
        var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
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
    static let nightGlow = RGB(hex: 0x7A5238)  // sodium-orange city glow seen through haze

    let top: RGB
    let horizon: RGB
    /// 0 in daylight, up to about 0.8 at night.
    let darkness: Double
    /// 0 for clean air, 1 for very polluted air (controls haze, glow and skyline fading).
    let haze: Double

    init(pm25: Double, hourOfDay: Double) {
        let position = AirBand.continuousPosition(pm25: pm25)
        let lower = Int(position.rounded(.down)), upper = min(5, lower + 1), t = position - Double(lower)
        let dayTop = Self.daySkies[lower].0.mixed(with: Self.daySkies[upper].0, t)
        let dayHorizon = Self.daySkies[lower].1.mixed(with: Self.daySkies[upper].1, t)

        // Haze builds from about 12 to 92 µg/m³, rising fastest across the common
        // Satisfactory range, so 32 and 58 look clearly different, not just their word.
        haze = pow(min(1, max(0, (pm25 - 12) / 80)), 0.8)
        darkness = Self.darkness(hourOfDay: hourOfDay)

        // Daytime haze washes the blue out towards a pale, dusty white.
        let washedTop = dayTop.mixed(with: Self.hazeTint, haze * 0.35)
        let washedHorizon = dayHorizon.mixed(with: Self.hazeTint, haze * 0.25)

        // At night, polluted air glows orange-brown: city lights scatter off the
        // particles. Clean nights stay deep blue.
        let nightGlowTop = Self.nightTop.mixed(with: Self.nightGlow, haze * 0.35)
        let nightGlowHorizon = Self.nightHorizon.mixed(with: Self.nightGlow, haze * 0.75)

        top = washedTop.mixed(with: nightGlowTop, darkness)
        horizon = washedHorizon.mixed(with: nightGlowHorizon, darkness * 0.9)
    }

    /// Ink for text on this sky: dark on pale, hazy daytime skies (from about
    /// PM2.5 40), white on clear blue skies and at night. Deciding by haze rather
    /// than brightness keeps the choice stable while dragging through the day,
    /// and the switch itself quietly signals that the air has turned hazy.
    var ink: Color {
        haze >= 0.42 && darkness < 0.3
            ? Color(red: 0.16, green: 0.15, blue: 0.13)
            : .white
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
