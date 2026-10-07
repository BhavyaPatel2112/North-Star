import SwiftUI

/// Draws the sky: a gradient, a distant Mumbai skyline that fades as the haze
/// thickens (you see less of the city on a bad day), lit windows at night, a
/// warm haze near the horizon and fine grain like dust in the air.
///
/// Built as stacked layers rather than one big drawing, so it stays smooth while
/// dragging: the skyline, windows and grain have fixed shapes, and only their
/// colour or see-through amount changes each frame, which the graphics chip
/// handles cheaply. Nothing full-screen is repainted pixel by pixel.
struct SkyCanvas: View {
    let palette: SkyPalette

    init(palette: SkyPalette) { self.palette = palette }

    /// PM2.5 in µg/m³ and hour of day on a Mumbai clock (for example 18.5 for 6:30 pm).
    init(pm25: Double, hourOfDay: Double) {
        self.init(palette: SkyPalette(pm25: pm25, hourOfDay: hourOfDay))
    }

    var body: some View {
        let night = palette.darkness > 0.4
        let towerColor = night
            ? SkyPalette.RGB(hex: 0x0B1222)
            : palette.horizon.mixed(with: SkyPalette.RGB(0.16, 0.18, 0.22), 0.55)
        let wash = palette.horizon.mixed(with: SkyPalette.hazeTint, 0.4).color

        ZStack {
            // 1. Sky gradient.
            LinearGradient(colors: [palette.top.color, palette.horizon.color],
                           startPoint: .top, endPoint: .bottom)

            // 2. Skyline: towers along the bottom, fading with haze.
            SkylineShape()
                .fill(towerColor.color)
                .opacity(0.42 * (1 - palette.haze * 0.9))

            // 3. Lit windows at night (always present, just invisible by day, so
            //    nothing is added or removed mid-drag).
            WindowsShape()
                .fill(Color(red: 1, green: 0.85, blue: 0.54))
                .opacity(night ? 0.5 * (1 - palette.haze) : 0)

            // 4. Haze: a warm wash rising from the horizon.
            LinearGradient(stops: [
                .init(color: wash.opacity(0), location: 0.35),
                .init(color: wash.opacity(0.15 + palette.haze * 0.55), location: 1),
            ], startPoint: .top, endPoint: .bottom)

            // 5. Grain: particles in the air, stronger when the air is dirtier.
            Grain.image
                .resizable()
                .interpolation(.none)
                .opacity(0.04 + palette.haze * 0.22)
        }
        .accessibilityHidden(true)
    }
}

/// The sky for a forecast at a position (hours from the first forecast hour).
///
/// "Animatable" means that when the position is changed inside an animation
/// (letting go of a drag, or tapping "Cleanest around"), SwiftUI redraws this
/// view at every in-between position, so the colours glide instead of jumping.
struct ForecastSky: View, Animatable {
    var position: Double
    let track: SkyTrack?

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        let sample = track?.sample(at: position) ?? (pm25: 20, hourOfDay: SkyModel.hourOfDay(.now))
        SkyCanvas(pm25: sample.pm25, hourOfDay: sample.hourOfDay)
    }
}

/// Horizon height, as a fraction of the screen from the top (a distant horizon near the bottom edge).
private let horizonLine = 0.9

/// The skyline as one shape: a fixed, made-up row of towers (same every time).
private struct SkylineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let base = rect.height * horizonLine
        for tower in Skyline.towers {
            path.addRect(CGRect(x: tower.x * rect.width, y: base - tower.height * rect.height,
                                width: tower.width * rect.width,
                                height: tower.height * rect.height + rect.height * 0.2))
        }
        return path
    }
}

/// Small lit windows on the towers (a fixed pattern, so they never flicker).
private struct WindowsShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let base = rect.height * horizonLine
        for (index, tower) in Skyline.towers.enumerated() {
            var y = base - tower.height * rect.height + 6
            while y < base - 4 {
                if (index * 31 + Int(y)) % 5 == 0 {
                    path.addRect(CGRect(x: (tower.x + tower.width * 0.4) * rect.width, y: y, width: 2, height: 3))
                }
                y += 7
            }
        }
        return path
    }
}

/// A fixed, made-up skyline (same every time), as fractions of the screen size.
private enum Skyline {
    struct Tower { let x, width, height: Double }

    static let towers: [Tower] = {
        var towers: [Tower] = []
        var seed: UInt64 = 7
        func random() -> Double {  // small repeatable random generator
            seed = (seed &* 6364136223846793005 &+ 1442695040888963407)
            return Double(seed >> 33) / Double(1 << 31)
        }
        var x = 0.0
        while x < 1 {
            let width = 0.02 + random() * 0.04
            let tall = x > 0.55 && x < 0.8  // a cluster of taller towers, like Lower Parel
            let height = 0.02 + random() * (tall ? 0.1 : 0.05)
            towers.append(Tower(x: x, width: width, height: height))
            x += width + random() * 0.01
        }
        return towers
    }()
}

/// Random speckles drawn once and reused, like dust caught in light.
private enum Grain {
    static let image: Image = {
        let width = 256, height = 512
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var generator = SystemRandomNumberGenerator()
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let shade = UInt8.random(in: 200...255, using: &generator)
            let alpha = UInt8.random(in: 0...255, using: &generator)
            // Premultiplied alpha: colour channels are scaled by alpha.
            pixels[i] = UInt8(Int(shade) * Int(alpha) / 255)
            pixels[i + 1] = UInt8(Int(shade) * 97 / 100 * Int(alpha) / 255)
            pixels[i + 2] = UInt8(Int(shade) * 90 / 100 * Int(alpha) / 255)
            pixels[i + 3] = alpha
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cgImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return Image(decorative: cgImage, scale: 1)
    }()
}
