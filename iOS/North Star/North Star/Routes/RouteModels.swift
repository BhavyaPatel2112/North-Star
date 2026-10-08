import CoreLocation
import Foundation

/// What the route server sends back for one planning request (POST /v1/routes).
struct RoutePlan: Decodable {
    /// The forecast hour the routes were scored for.
    let forecastHour: Date?
    /// Up to 3 routes, cleanest first. Empty when nothing walkable was found.
    let options: [RouteOption]
    /// A plain-language note from the server when there are no options.
    let message: String?
    /// Where restaurant finishes came from: "google" (rated places), "apple (...)" or nil.
    let foodSource: String?

    enum CodingKeys: String, CodingKey {
        case options, message
        case forecastHour = "forecast_hour"
        case foodSource = "food_source"
    }
}

/// One suggested route.
struct RouteOption: Decodable, Identifiable {
    let id = UUID()
    /// "loop", "out_and_back" or "one_way".
    let kind: String
    /// A short description, for example "Mostly quiet streets".
    let label: String
    let distanceKm: Double
    /// Average PM2.5 along the route at the requested start time (µg/m³).
    let pm25: Double
    /// How much cleaner than the plain shortest route, in percent (nil if not compared).
    let cleanerThanDirectPct: Int?
    /// Share of the route on quiet streets and on main roads (0 to 1).
    let quietShare: Double
    let mainRoadShare: Double
    /// Times the route crosses a highway (at road level, under a flyover or over a bridge).
    let highwayCrossings: Int
    /// Highway crossings in the last few hundred metres, to reach a station (not counted above).
    let finishCrossings: Int
    /// Kilometres along main roads and highways.
    let busyKm: Double
    /// The finish, and the named place there if the run ends at one (for example a cafe).
    let finish: Coordinate
    let finishPlace: FinishPlace?
    /// The route's line on the map, start to finish.
    let line: [CLLocationCoordinate2D]
    /// Street by street directions, in running order.
    let steps: [RouteStep]
    /// The route's average PM2.5 for each of the next 24 hours.
    let byHour: [HourValue]
    /// The cleanest time to start between 5 am and 10 pm.
    let bestStart: HourValue?
    /// How high the ground is along the route (nil from older servers).
    let elevation: Elevation?
    let walkCheck: WalkCheck
    let googleMapsLink: URL?

    struct Coordinate: Decodable {
        let lat, lon: Double
        var location: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    }

    struct FinishPlace: Decodable {
        let name: String
        let lat, lon: Double
        /// Google rating (1 to 5) and number of reviews, when the place came from Google.
        let rating: Double?
        let reviews: Int?
        /// "food" or "station" (nil for a finish the user chose, or from older servers).
        let kind: String?
        /// For stations: "train", "metro" or "monorail".
        let mode: String?

        var isStation: Bool { kind == "station" }
        /// The symbol for this kind of finish on the map and in the route details.
        var symbol: String {
            switch (kind, mode) {
            case ("station", "metro"?), ("station", "monorail"?): "lightrail.fill"
            case ("station", _): "tram.fill"
            case ("food", _): "fork.knife"
            default: "flag.checkered"
            }
        }
    }

    struct HourValue: Decodable, Identifiable {
        let time: Date
        let pm25: Double
        var id: Date { time }
    }

    /// The ground along the route: height (m) at distances from the start (km),
    /// smoothed, with the total climb and descent and the lowest and highest points.
    struct Elevation: Decodable {
        struct Point: Identifiable {
            let km: Double
            let metres: Double
            var id: Double { km }
        }

        let points: [Point]
        let climbM: Int
        let descentM: Int
        let minM: Int
        let maxM: Int

        enum CodingKeys: String, CodingKey {
            case points
            case climbM = "climb_m"
            case descentM = "descent_m"
            case minM = "min_m"
            case maxM = "max_m"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Points arrive as [[km, metres], ...].
            points = try c.decode([[Double]].self, forKey: .points).compactMap { pair in
                pair.count == 2 ? Point(km: pair[0], metres: pair[1]) : nil
            }
            climbM = try c.decode(Int.self, forKey: .climbM)
            descentM = try c.decode(Int.self, forKey: .descentM)
            minM = try c.decode(Int.self, forKey: .minM)
            maxM = try c.decode(Int.self, forKey: .maxM)
        }

        /// Height at a distance along the route (straight line between points).
        func metres(atKm km: Double) -> Double? {
            guard let first = points.first else { return nil }
            guard km > first.km else { return first.metres }
            for (a, b) in zip(points, points.dropFirst()) where km <= b.km {
                let t = b.km > a.km ? (km - a.km) / (b.km - a.km) : 0
                return a.metres + (b.metres - a.metres) * t
            }
            return points.last?.metres
        }

        /// "Mostly flat", "Gently rolling", "Some climbing" or "Hilly", from metres climbed per km.
        func feel(distanceKm: Double) -> String {
            let perKm = Double(climbM) / max(distanceKm, 0.1)
            switch perKm {
            case ..<4: return "Mostly flat"
            case ..<10: return "Gently rolling"
            case ..<20: return "Some climbing"
            default: return "Hilly"
            }
        }
    }

    /// Whether Google's walking directions agreed the route can be walked as drawn.
    struct WalkCheck: Decodable {
        let checked: Bool
        let walkable: Bool
    }

    enum CodingKeys: String, CodingKey {
        case kind, label, pm25, finish, line, steps
        case distanceKm = "distance_km"
        case cleanerThanDirectPct = "cleaner_than_direct_pct"
        case quietShare = "quiet_share"
        case mainRoadShare = "main_road_share"
        case highwayCrossings = "highway_crossings"
        case finishCrossings = "finish_crossings"
        case busyKm = "busy_km"
        case finishPlace = "finish_place"
        case byHour = "by_hour"
        case bestStart = "best_start"
        case elevation
        case walkCheck = "walk_check"
        case googleMapsLink = "google_maps_link"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        label = try c.decode(String.self, forKey: .label)
        distanceKm = try c.decode(Double.self, forKey: .distanceKm)
        pm25 = try c.decode(Double.self, forKey: .pm25)
        cleanerThanDirectPct = try c.decodeIfPresent(Int.self, forKey: .cleanerThanDirectPct)
        quietShare = try c.decode(Double.self, forKey: .quietShare)
        mainRoadShare = try c.decode(Double.self, forKey: .mainRoadShare)
        // Older servers do not send these.
        highwayCrossings = try c.decodeIfPresent(Int.self, forKey: .highwayCrossings) ?? 0
        finishCrossings = try c.decodeIfPresent(Int.self, forKey: .finishCrossings) ?? 0
        busyKm = try c.decodeIfPresent(Double.self, forKey: .busyKm) ?? 0
        finish = try c.decode(Coordinate.self, forKey: .finish)
        finishPlace = try c.decodeIfPresent(FinishPlace.self, forKey: .finishPlace)
        // The line arrives as [[latitude, longitude], ...].
        line = try c.decode([[Double]].self, forKey: .line).compactMap { pair in
            pair.count == 2 ? CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1]) : nil
        }
        steps = try c.decode([RouteStep].self, forKey: .steps)
        byHour = try c.decode([HourValue].self, forKey: .byHour)
        bestStart = try c.decodeIfPresent(HourValue.self, forKey: .bestStart)
        elevation = try c.decodeIfPresent(Elevation.self, forKey: .elevation)
        walkCheck = try c.decode(WalkCheck.self, forKey: .walkCheck)
        googleMapsLink = try c.decodeIfPresent(String.self, forKey: .googleMapsLink).flatMap(URL.init(string:))
    }

    var isLoop: Bool { kind != "one_way" }
    var band: AirBand { AirBand(pm25: pm25) }
}

/// One named stretch of the route, for example 0.24 km along Keluskar Road.
struct RouteStep: Decodable, Identifiable {
    let name: String
    /// Where the stretch starts, in km from the start, and its length in km.
    let kmFrom: Double
    let km: Double
    let pm25: Double
    /// "quiet street", "medium road", "main road" or "highway".
    let road: String

    var id: Double { kmFrom }
    var band: AirBand { AirBand(pm25: pm25) }
    /// A friendlier name for lanes OpenStreetMap has no name for.
    var displayName: String { name == "unnamed lane" ? "Unnamed lane" : name }

    enum CodingKeys: String, CodingKey {
        case name, km, pm25, road
        case kmFrom = "km_from"
    }
}
