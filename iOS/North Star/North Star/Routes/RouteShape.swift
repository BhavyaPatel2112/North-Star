import CoreLocation

/// Geometry for drawing one route: where each kilometre falls on the line, the
/// line cut into stretches coloured by how clean they are, and the point and
/// street at any distance (for the pointer you drag along the route).
struct RouteShape {
    /// One coloured piece of the line (one street stretch from the server's steps).
    struct Stretch: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let band: AirBand
    }

    let option: RouteOption
    /// Distance in metres from the start to each point of the line.
    private let cumulative: [Double]
    let stretches: [Stretch]

    init(_ option: RouteOption) {
        self.option = option
        var cumulative: [Double] = [0]
        for (a, b) in zip(option.line, option.line.dropFirst()) {
            cumulative.append(cumulative.last! + Self.metres(a, b))
        }
        self.cumulative = cumulative

        // The server measures steps in km along its own street lengths; the line we
        // draw can differ by a few metres, so match by share of the way round.
        let total = max(cumulative.last ?? 0, 1)
        let serverKm = max(option.distanceKm, 0.001)
        var stretches: [Stretch] = []
        for (index, step) in option.steps.enumerated() {
            let from = step.kmFrom / serverKm * total
            let to = (step.kmFrom + step.km) / serverKm * total
            let points = Self.slice(option.line, cumulative, from: from, to: to)
            if points.count >= 2 { stretches.append(Stretch(id: index, coordinates: points, band: step.band)) }
        }
        self.stretches = stretches
    }

    var start: CLLocationCoordinate2D? { option.line.first }
    var finish: CLLocationCoordinate2D? { option.line.last }

    /// The point on the line `km` from the start.
    func point(atKm km: Double) -> CLLocationCoordinate2D? {
        guard let total = cumulative.last, total > 0, !option.line.isEmpty else { return option.line.first }
        let target = min(total, max(0, km / max(option.distanceKm, 0.001) * total))
        guard let upper = cumulative.firstIndex(where: { $0 >= target }), upper > 0 else { return option.line.first }
        let lower = upper - 1
        let span = cumulative[upper] - cumulative[lower]
        let t = span > 0 ? (target - cumulative[lower]) / span : 0
        return Self.interpolate(option.line[lower], option.line[upper], t)
    }

    /// The street stretch at `km` from the start.
    func step(atKm km: Double) -> RouteStep? {
        option.steps.last { $0.kmFrom <= km + 0.0001 } ?? option.steps.first
    }

    /// For a place near the route: how far it is from the line (metres) and how far
    /// along the route its closest point is (km). Checks every point of the line,
    /// which is plenty fast for a few hundred points.
    func nearest(to place: CLLocationCoordinate2D) -> (offRouteM: Double, atKm: Double) {
        var best = (offRouteM: Double.infinity, atKm: 0.0)
        let total = max(cumulative.last ?? 0, 1)
        for (index, point) in option.line.enumerated() {
            let d = Self.metres(point, place)
            if d < best.offRouteM { best = (d, cumulative[index] / total * option.distanceKm) }
        }
        return best
    }

    // MARK: - Helpers

    static func metres(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private static func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ t: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                               longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// The part of the line between two distances from the start (in metres).
    private static func slice(_ line: [CLLocationCoordinate2D], _ cumulative: [Double],
                              from: Double, to: Double) -> [CLLocationCoordinate2D] {
        guard line.count >= 2, to > from else { return [] }
        func at(_ distance: Double) -> CLLocationCoordinate2D {
            guard let upper = cumulative.firstIndex(where: { $0 >= distance }), upper > 0 else {
                return distance <= 0 ? line[0] : line[line.count - 1]
            }
            let span = cumulative[upper] - cumulative[upper - 1]
            return interpolate(line[upper - 1], line[upper], span > 0 ? (distance - cumulative[upper - 1]) / span : 0)
        }
        var points = [at(from)]
        for (index, distance) in cumulative.enumerated() where distance > from && distance < to {
            points.append(line[index])
        }
        points.append(at(to))
        return points
    }
}
