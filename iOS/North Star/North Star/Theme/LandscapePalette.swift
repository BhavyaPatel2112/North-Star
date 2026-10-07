import SwiftUI

/// The colours of the journey landscape for a given air quality and time of day.
///
/// The landscape is the app's picture of the journey: snowy plains, a frozen
/// lake, mountains and the North Star above the summit. Its colours tell the
/// story of the air and the hour:
/// - day: misty blue-grey; dawn and dusk: pink alpenglow on the snow; night:
///   deep navy with the star at its brightest;
/// - polluted air: dusty haze thickens with distance, so the far peaks and the
///   star fade first (the journey's visibility is the air's quality).
struct LandscapePalette {
    typealias RGB = SkyPalette.RGB

    let skyTop, skyHorizon: RGB
    let farRidge, midRidge, nearRidge, forest: RGB
    let lakeTop, lakeBottom: RGB
    let snow, farSnow: RGB
    let mist: RGB
    /// How visible the North Star is (0 to 1).
    let starOpacity: Double
    /// How thick the mist between the ridges is (0 to 1).
    let mistOpacity: Double
    /// 0 in daylight, up to 1 at night.
    let night: Double

    init(pm25: Double, hourOfDay: Double) {
        let sky = SkyPalette(pm25: pm25, hourOfDay: hourOfDay)
        let night = sky.darkness / 0.82
        let haze = sky.haze
        // Warm light near sunrise (about 6:15 am) and sunset (about 6:30 pm) in Mumbai.
        let warm = max(0, 1 - abs(hourOfDay - 6.3) / 1.2) + max(0, 1 - abs(hourOfDay - 18.5) / 1.2)
        let glow = min(1, warm) * (1 - night * 0.6)

        // One colour per layer: day, night, and the dawn/dusk version; then haze,
        // which reaches further layers more (distance 1 = the far peaks).
        func colour(day: RGB, night nightColour: RGB, dusk: RGB? = nil, distance: Double) -> RGB {
            var c = day.mixed(with: nightColour, night)
            if let dusk { c = c.mixed(with: dusk, glow) }
            let hazeColour = RGB(0.74, 0.70, 0.64).mixed(with: RGB(0.30, 0.25, 0.22), night)
            return c.mixed(with: hazeColour, haze * 0.8 * distance)
        }

        skyTop = colour(day: RGB(0.56, 0.65, 0.73), night: RGB(0.02, 0.04, 0.09), dusk: RGB(0.50, 0.52, 0.66), distance: 1)
        skyHorizon = colour(day: RGB(0.80, 0.84, 0.87), night: RGB(0.09, 0.13, 0.21), dusk: RGB(0.93, 0.73, 0.63), distance: 1)
        farRidge = colour(day: RGB(0.60, 0.68, 0.76), night: RGB(0.13, 0.17, 0.25), dusk: RGB(0.70, 0.62, 0.70), distance: 1)
        farSnow = colour(day: RGB(0.88, 0.91, 0.94), night: RGB(0.40, 0.45, 0.55), dusk: RGB(0.98, 0.80, 0.78), distance: 0.9)
        midRidge = colour(day: RGB(0.40, 0.51, 0.60), night: RGB(0.08, 0.11, 0.18), dusk: RGB(0.46, 0.44, 0.54), distance: 0.7)
        nearRidge = colour(day: RGB(0.25, 0.34, 0.42), night: RGB(0.05, 0.07, 0.12), distance: 0.45)
        forest = colour(day: RGB(0.15, 0.22, 0.28), night: RGB(0.03, 0.05, 0.09), distance: 0.35)
        lakeTop = colour(day: RGB(0.58, 0.66, 0.73), night: RGB(0.10, 0.14, 0.21), dusk: RGB(0.80, 0.66, 0.62), distance: 0.6)
        lakeBottom = colour(day: RGB(0.19, 0.27, 0.34), night: RGB(0.02, 0.03, 0.07), distance: 0.3)
        snow = colour(day: RGB(0.88, 0.91, 0.94), night: RGB(0.36, 0.41, 0.50), dusk: RGB(0.95, 0.84, 0.82), distance: 0.15)
        mist = colour(day: RGB(0.86, 0.89, 0.91), night: RGB(0.17, 0.21, 0.29), dusk: RGB(0.93, 0.80, 0.74), distance: 0.8)

        starOpacity = (0.3 + 0.7 * night) * (1 - 0.85 * haze)
        mistOpacity = 0.3 + 0.6 * haze
        self.night = night
    }
}
