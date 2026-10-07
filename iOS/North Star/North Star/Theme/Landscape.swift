import SwiftUI

/// The journey landscape: the North Star above a snow-capped summit, ranges
/// fading into mist, a dark forested shore, a still frozen lake with the
/// mountains reflected in it, and the snowy plain in front, where a lone
/// traveller stands. Drawn by the app (not a photo) so it can follow the air
/// and the hour; see LandscapePalette for the colours.
///
/// Like the old sky, it is built from layers whose shapes never change: only
/// colours and see-through amounts change while dragging, which stays smooth.
struct Landscape: View {
    let palette: LandscapePalette
    /// Show the small traveller on the shore.
    var showsTraveller = true

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [palette.skyTop.color, palette.skyHorizon.color],
                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: Layout.horizon))

                NorthStarGlint(opacity: palette.starOpacity)
                    .position(x: size.width * Layout.peakX, y: size.height * 0.115)

                // Far range with the summit, snow on its upper slopes, and the slopes
                // facing away from the light in shadow.
                RidgeShape(ridge: .far).fill(palette.farRidge.color)
                SnowCapShape().fill(palette.farSnow.color)
                ShadowSideShape(ridge: .far).fill(palette.midRidge.color.opacity(0.28))
                MistBand(top: 0.30, bottom: Layout.horizon, colour: palette.mist, opacity: palette.mistOpacity)

                // Middle range, heavier on the left.
                RidgeShape(ridge: .mid).fill(palette.midRidge.color)
                ShadowSideShape(ridge: .mid).fill(palette.nearRidge.color.opacity(0.3))
                MistBand(top: 0.42, bottom: Layout.horizon, colour: palette.mist, opacity: palette.mistOpacity * 0.8)

                // Forested spit along the far shore.
                RidgeShape(ridge: .forest).fill(palette.forest.color)

                // The frozen lake, with the ranges reflected in it.
                LinearGradient(colors: [palette.lakeTop.color, palette.lakeBottom.color],
                               startPoint: UnitPoint(x: 0.5, y: Layout.horizon), endPoint: .bottom)
                    .mask(LakeShape())
                // Reflections, fading with depth into the ice.
                ZStack {
                    ReflectionShape(ridge: .far).fill(palette.farRidge.color.opacity(0.22))
                    ReflectionShape(ridge: .mid).fill(palette.midRidge.color.opacity(0.3))
                    ReflectionShape(ridge: .forest).fill(palette.forest.color.opacity(0.5))
                }
                .mask(LinearGradient(stops: [.init(color: .black, location: Layout.horizon),
                                             .init(color: .clear, location: Layout.horizon + 0.2)],
                                     startPoint: .top, endPoint: .bottom))
                IceLines().stroke(palette.mist.color.opacity(0.25), lineWidth: 1).mask(LakeShape())

                // The snowy plain in front, with a few rocks.
                RidgeShape(ridge: .shore).fill(palette.snow.color)
                RocksShape().fill(palette.forest.color.opacity(0.85))

                if showsTraveller {
                    // The lone traveller, small against the land, facing the mountain.
                    Image(systemName: "figure.walk")
                        .font(.system(size: max(11, size.height * 0.028), weight: .semibold))
                        .foregroundStyle(palette.forest.color)
                        .position(x: size.width * 0.27, y: size.height * (Ridge.shore.y(at: 0.27) - 0.012))
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .accessibilityHidden(true)
    }
}

/// The landscape for a forecast at a position (hours from the first forecast hour).
/// Animatable, so when the position changes inside an animation (letting go of a
/// drag) the colours glide through every in-between hour.
struct ForecastLandscape: View, Animatable {
    var position: Double
    let track: SkyTrack?

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        let sample = track?.sample(at: position) ?? (pm25: 20, hourOfDay: SkyModel.hourOfDay(.now))
        Landscape(palette: LandscapePalette(pm25: sample.pm25, hourOfDay: sample.hourOfDay))
    }
}

// MARK: - Layout

/// Positions as fractions of the picture's width and height.
private enum Layout {
    /// Where the far shore meets the lake.
    static let horizon = 0.55
    /// The summit, with the North Star above it.
    static let peakX = 0.64
}

/// One ridge line: fixed, made-up heights (the same every time).
struct Ridge {
    /// Heights from 0 to 1 at evenly spaced points across the width.
    let heights: [Double]
    /// Lowest line (fraction of the height from the top) and how high peaks rise above it.
    let base: Double
    let amplitude: Double

    /// Height of the ridge line at x (0 to 1), as a fraction of the picture's height from the top.
    func y(at x: Double) -> Double {
        let position = min(1, max(0, x)) * Double(heights.count - 1)
        let i = min(heights.count - 2, Int(position))
        let t = position - Double(i)
        let h = heights[i] + (heights[i + 1] - heights[i]) * t
        return base - amplitude * h
    }

    static let far = Ridge(seed: 11, roughness: 0.62, base: Layout.horizon - 0.02, amplitude: 0.36,
                           peaks: [(Layout.peakX, 0.9, 0.17), (Layout.peakX + 0.09, 0.35, 0.06),
                                   (0.22, 0.45, 0.14), (0.95, 0.35, 0.10)])
    static let mid = Ridge(seed: 29, roughness: 0.6, base: Layout.horizon - 0.005, amplitude: 0.22,
                           peaks: [(0.06, 0.8, 0.16), (0.30, 0.35, 0.10), (0.86, 0.25, 0.12)])
    static let forest = Ridge(seed: 53, roughness: 0.85, base: Layout.horizon + 0.006, amplitude: 0.035,
                              peaks: [(0.20, 0.8, 0.22)], fade: 0.62)
    static let shore = Ridge(seed: 71, roughness: 0.45, base: 0.95, amplitude: 0.07,
                             peaks: [(0.05, 0.9, 0.2), (0.75, 0.5, 0.25)])

    /// Builds a ridge by "midpoint displacement": start flat, then repeatedly push
    /// each midpoint up or down by a random amount that shrinks at every level,
    /// which gives natural-looking, jagged mountain lines. Named peaks are added on top.
    /// fade: beyond this x the ridge sinks into the lake (for the forested spit).
    init(seed: UInt64, roughness: Double, base: Double, amplitude: Double,
         peaks: [(x: Double, height: Double, width: Double)], fade: Double? = nil) {
        var state = seed
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 33) / Double(1 << 31)
        }
        let count = 129
        var h = [Double](repeating: 0.3, count: count)
        var step = count - 1
        var spread = 1.0
        while step > 1 {
            for i in stride(from: 0, to: count - 1, by: step) {
                h[i + step / 2] = (h[i] + h[i + step]) / 2 + (random() - 0.5) * spread
            }
            spread *= roughness
            step /= 2
        }
        for i in 0..<count {
            let x = Double(i) / Double(count - 1)
            for peak in peaks { h[i] += peak.height * exp(-pow((x - peak.x) / peak.width, 2)) }
            if let fade, x > fade { h[i] -= (x - fade) * 6 }
        }
        let low = h.min()!, high = h.max()!
        heights = h.map { max(0, ($0 - low) / (high - low)) }
        self.base = base
        self.amplitude = amplitude
    }
}

// MARK: - Shapes

/// A ridge filled down to the bottom of the picture.
private struct RidgeShape: Shape {
    let ridge: Ridge

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for (i, _) in ridge.heights.enumerated() {
            let x = Double(i) / Double(ridge.heights.count - 1)
            path.addLine(to: CGPoint(x: rect.minX + x * rect.width, y: rect.minY + ridge.y(at: x) * rect.height))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Snow on the far range: the ridge above a ragged snow line.
private struct SnowCapShape: Shape {
    func path(in rect: CGRect) -> Path {
        let ridge = RidgeShape(ridge: .far).path(in: rect)
        let line = Ridge(seed: 97, roughness: 0.8, base: 0.335, amplitude: 0.07, peaks: [])
        var above = Path()
        above.move(to: CGPoint(x: rect.minX, y: rect.minY))
        above.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        for i in stride(from: line.heights.count - 1, through: 0, by: -1) {
            let x = Double(i) / Double(line.heights.count - 1)
            above.addLine(to: CGPoint(x: rect.minX + x * rect.width, y: rect.minY + line.y(at: x) * rect.height))
        }
        above.closeSubpath()
        return ridge.intersection(above)
    }
}

/// The slopes facing away from the light (it comes from the left): the part of the
/// ridge not covered by a copy of itself shifted a little to the left.
private struct ShadowSideShape: Shape {
    let ridge: Ridge

    func path(in rect: CGRect) -> Path {
        let shape = RidgeShape(ridge: ridge).path(in: rect)
        let shifted = shape.offsetBy(dx: -rect.width * 0.035, dy: rect.height * 0.004)
        return shape.subtracting(shifted)
    }
}

/// A ridge mirrored in the lake, a little squashed, as still water shows it.
private struct ReflectionShape: Shape {
    let ridge: Ridge

    func path(in rect: CGRect) -> Path {
        let horizon = rect.minY + Layout.horizon * rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: horizon))
        for (i, _) in ridge.heights.enumerated() {
            let x = Double(i) / Double(ridge.heights.count - 1)
            let y = rect.minY + ridge.y(at: x) * rect.height
            path.addLine(to: CGPoint(x: rect.minX + x * rect.width, y: horizon + (horizon - y) * 0.45))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: horizon))
        path.closeSubpath()
        return path
    }
}

/// The lake: from the far shore down to the snowy plain.
private struct LakeShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY + Layout.horizon * rect.height,
                    width: rect.width, height: rect.height * (1 - Layout.horizon)))
    }
}

/// Faint lines across the ice, like cracks and wind-polished streaks.
private struct IceLines: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let lines: [(x: Double, y: Double, length: Double)] = [
            (0.12, 0.62, 0.30), (0.55, 0.64, 0.22), (0.30, 0.70, 0.42), (0.70, 0.74, 0.25),
            (0.05, 0.79, 0.35), (0.48, 0.83, 0.40),
        ]
        for line in lines {
            path.move(to: CGPoint(x: rect.minX + line.x * rect.width, y: rect.minY + line.y * rect.height))
            path.addLine(to: CGPoint(x: rect.minX + (line.x + line.length) * rect.width, y: rect.minY + line.y * rect.height))
        }
        return path
    }
}

/// A few dark rocks half buried in the snow.
private struct RocksShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let rocks: [(x: Double, width: Double, height: Double)] = [(0.08, 0.10, 0.018), (0.16, 0.05, 0.010), (0.82, 0.12, 0.016), (0.62, 0.04, 0.008)]
        for rock in rocks {
            let y = Ridge.shore.y(at: rock.x + rock.width / 2)
            path.addEllipse(in: CGRect(x: rect.minX + rock.x * rect.width, y: rect.minY + (y - rock.height * 0.4) * rect.height,
                                       width: rock.width * rect.width, height: rock.height * rect.height))
        }
        return path
    }
}

/// A soft band of mist lying in a valley, thicker when the air is dirtier.
private struct MistBand: View {
    let top: Double
    let bottom: Double
    let colour: SkyPalette.RGB
    let opacity: Double

    var body: some View {
        LinearGradient(stops: [
            .init(color: colour.color.opacity(0), location: top),
            .init(color: colour.color.opacity(opacity), location: bottom - 0.02),
            .init(color: colour.color.opacity(0), location: bottom + 0.02),
        ], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
    }
}

/// The North Star as a small glint: a soft glow and four fine rays.
struct NorthStarGlint: View {
    let opacity: Double
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(red: 1, green: 0.96, blue: 0.88).opacity(0.9), .clear],
                                     center: .center, startRadius: 0, endRadius: size * 0.35))
            StarRays()
                .fill(Color(red: 1, green: 0.97, blue: 0.9))
            Circle()
                .fill(.white)
                .frame(width: size * 0.07, height: size * 0.07)
        }
        .frame(width: size, height: size)
        .opacity(opacity)
    }
}

/// Four thin rays tapering to points (long up and down, a little shorter sideways).
private struct StarRays: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let w = rect.width * 0.035
        var path = Path()
        for (dx, dy, length) in [(0.0, -1.0, 0.5), (0.0, 1.0, 0.42), (-1.0, 0.0, 0.36), (1.0, 0.0, 0.36)] {
            let tip = CGPoint(x: c.x + dx * length * rect.width, y: c.y + dy * length * rect.height)
            path.move(to: CGPoint(x: c.x - dy * w, y: c.y + dx * w))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(x: c.x + dy * w, y: c.y - dx * w))
            path.closeSubpath()
        }
        return path
    }
}

#Preview {
    Landscape(palette: LandscapePalette(pm25: 25, hourOfDay: 10))
        .frame(height: 560)
        .ignoresSafeArea()
}
