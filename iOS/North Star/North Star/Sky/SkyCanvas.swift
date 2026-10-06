import SwiftUI

/// Draws the sky: a gradient, a distant Mumbai skyline that fades as the haze
/// thickens (you see less of the city on a bad day), lit windows at night, a
/// warm haze near the horizon and fine grain like dust in the air.
struct SkyCanvas: View {
    /// PM2.5 in µg/m³ (can be between hours while dragging).
    let pm25: Double
    /// Hour of day on a Mumbai clock, for example 18.5 for 6:30 pm.
    let hourOfDay: Double

    var body: some View {
        let palette = SkyPalette(pm25: pm25, hourOfDay: hourOfDay)
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)

            // 1. Sky gradient.
            context.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [palette.top.color, palette.horizon.color]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            // 2. Skyline: towers along the bottom, fading with haze.
            let base = size.height * 0.9  // a distant horizon near the bottom edge
            let towerColor = palette.darkness > 0.4
                ? SkyPalette.RGB(hex: 0x0B1222)
                : palette.horizon.mixed(with: SkyPalette.RGB(0.16, 0.18, 0.22), 0.55)
            var skyline = context
            skyline.opacity = 0.42 * (1 - palette.haze * 0.85)
            for tower in Skyline.towers {
                let towerRect = CGRect(x: tower.x * size.width, y: base - tower.height * size.height,
                                       width: tower.width * size.width, height: tower.height * size.height + size.height * 0.2)
                skyline.fill(Path(towerRect), with: .color(towerColor.color))
            }

            // 3. Lit windows at night.
            if palette.darkness > 0.4 {
                var windows = context
                windows.opacity = 0.5 * (1 - palette.haze)
                for (index, tower) in Skyline.towers.enumerated() {
                    var y = base - tower.height * size.height + 6
                    while y < base - 4 {
                        if (index * 31 + Int(y)) % 5 == 0 {
                            windows.fill(Path(CGRect(x: (tower.x + tower.width * 0.4) * size.width, y: y, width: 2, height: 3)),
                                         with: .color(Color(red: 1, green: 0.85, blue: 0.54)))
                        }
                        y += 7
                    }
                }
            }

            // 4. Haze: a warm wash rising from the horizon.
            let wash = palette.horizon.mixed(with: SkyPalette.hazeTint, 0.4).color
            context.fill(Path(rect), with: .linearGradient(
                Gradient(stops: [
                    .init(color: wash.opacity(0), location: 0.35),
                    .init(color: wash.opacity(0.15 + palette.haze * 0.55), location: 1),
                ]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            // 5. Grain: particles in the air, stronger when the air is dirtier.
            var grain = context
            grain.opacity = 0.04 + palette.haze * 0.22
            grain.draw(Grain.image, in: rect)
        }
        .accessibilityHidden(true)
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
