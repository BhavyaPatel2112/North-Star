import CoreLocation
import MapKit

/// Places from Apple Maps used by the run planner, looked up on the phone
/// (free, no key, nothing about the user is sent to our server):
/// - food finishes (fallback): the server normally picks well-rated restaurants
///   from Google; these Apple Maps places are sent along in case Google can't be
///   asked, preferring well-known chains with consistent hygiene standards;
/// - help along the way: medical stores, shops for water and clinics near the route;
/// - after the run: places to eat and stations a short walk from the finish.
///
/// Apple Maps does not always know opening hours, so the app says "check it is open".
enum NearbyPlaces {
    /// Something useful near a route, for example "Medical store, 120 m off route at km 2.3".
    struct Stop: Identifiable {
        enum Kind: String, CaseIterable {
            case pharmacy = "Medical store"
            case water = "Water and snacks"
            case clinic = "Clinic or hospital"

            var symbol: String {
                switch self {
                case .pharmacy: "cross.case"
                case .water: "waterbottle"
                case .clinic: "stethoscope"
                }
            }

            /// How many of each kind to show, at most.
            var limit: Int {
                switch self {
                case .pharmacy: 5
                case .water: 3
                case .clinic: 2
                }
            }
        }

        let id = UUID()
        let kind: Kind
        let name: String
        let coordinate: CLLocationCoordinate2D
        let offRouteM: Double
        let atKm: Double
    }

    /// Somewhere to go once the run is over, with the walk there from the finish.
    struct Destination: Identifiable {
        enum Kind {
            case food, station

            var symbol: String { self == .food ? "fork.knife" : "tram.fill" }
        }

        let id = UUID()
        let kind: Kind
        let name: String
        let item: MKMapItem
        /// Walking distance (metres) and time (seconds) from the finish, from Apple Maps.
        let walkM: Double
        let walkSeconds: Double

        var coordinate: CLLocationCoordinate2D { item.placemark.coordinate }
    }

    // MARK: - After the run

    /// Places to eat and stations close to where the run ends, nearest walk first.
    ///
    /// Food: cafes, restaurants and bakeries within 400 m (well-known chains first,
    /// up to 6). Stations: train, metro and monorail stations within 400 m, or
    /// within 1 km if none is that close (up to 3). Each walk is measured by Apple
    /// Maps along real streets, so "250 m" is what you will actually walk.
    static func afterRun(from finish: CLLocationCoordinate2D) async -> [Destination] {
        async let food = foodNear(finish)
        async let stations = stationsNear(finish)
        let candidates = await food.map { (Destination.Kind.food, $0, $0.name ?? "Restaurant") }
            + stations.map { (Destination.Kind.station, $0, $0.name ?? "Station") }

        // Ask for all the walks at once (Apple allows about 50 a minute; this is at most 9).
        let found = await withTaskGroup(of: Destination?.self) { group in
            for (kind, item, name) in candidates {
                group.addTask {
                    guard let walk = await walk(from: finish, to: item) else { return nil }
                    return Destination(kind: kind, name: name, item: item, walkM: walk.metres, walkSeconds: walk.seconds)
                }
            }
            var results: [Destination] = []
            for await destination in group { if let destination { results.append(destination) } }
            return results
        }
        return found.sorted { $0.walkM < $1.walkM }
    }

    /// Up to 6 places to eat within 400 m, well-known chains first.
    private static func foodNear(_ point: CLLocationCoordinate2D) async -> [MKMapItem] {
        let request = MKLocalPointsOfInterestRequest(center: point, radius: 400)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.cafe, .restaurant, .bakery])
        let items = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
        let isChain = { (item: MKMapItem) in knownChains.contains(where: (item.name ?? "").lowercased().contains) }
        return Array((items.filter(isChain) + items.filter { !isChain($0) }).prefix(6))
    }

    /// Up to 3 train, metro or monorail stations within 400 m, widening to 1 km if none.
    private static func stationsNear(_ point: CLLocationCoordinate2D) async -> [MKMapItem] {
        for radius in [400.0, 1_000.0] {
            let request = MKLocalPointsOfInterestRequest(center: point, radius: radius)
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.publicTransport])
            let items = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
            // "Public transport" also covers bus stops and depots; keep rail stations only.
            let stations = items.filter { item in
                let name = (item.name ?? "").lowercased()
                return !name.contains("bus") && !name.contains("depot") && !name.contains("taxi")
            }
            if !stations.isEmpty { return Array(stations.prefix(3)) }
        }
        return []
    }

    /// The walk from `start` to a place along streets, or nil if Apple Maps has none.
    private static func walk(from start: CLLocationCoordinate2D, to item: MKMapItem) async -> (metres: Double, seconds: Double)? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = item
        request.transportType = .walking
        guard let eta = try? await MKDirections(request: request).calculateETA() else { return nil }
        return (eta.distance, eta.expectedTravelTime)
    }

    /// Opens Apple Maps with walking directions from the finish to a place.
    static func openWalk(from finish: CLLocationCoordinate2D, to destination: Destination) {
        let start = MKMapItem(placemark: MKPlacemark(coordinate: finish))
        start.name = "End of your run"
        MKMapItem.openMaps(with: [start, destination.item],
                           launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    // MARK: - Food

    /// Chains with consistent kitchens and hygiene, used when Google ratings are unavailable.
    static let knownChains = [
        "mcdonald", "starbucks", "subway", "domino", "kfc", "burger king", "pizza hut", "theobroma",
        "cafe coffee day", "café coffee day", "third wave", "blue tokai", "haldiram", "kailash parbat",
        "chaayos", "barista", "taco bell", "wow! momo", "baskin", "smoke house", "social", "candies",
        "monginis", "naturals", "costa coffee", "tim hortons", "la pino", "faasos", "irani cafe",
    ]

    /// Up to 20 places to eat roughly the right distance away for a one-way run,
    /// spread around the compass. Well-known chains are preferred.
    ///
    /// Apple Maps returns only about 25 places per search, closest first, so one big
    /// search would only find cafes next door. Instead we search the neighbourhood
    /// around the start (the server adds a detour so a run of the full distance can
    /// still end there, like the McDonald's in your own area) plus 8 small circles on
    /// a ring about 65% of the run's distance away (streets wind, so a 5 km run
    /// usually ends 3 to 4 km from the start as the crow flies).
    static func foodFinishes(near start: CLLocationCoordinate2D, distanceKm: Double) async -> [RouteService.FinishPlace] {
        let ringM = distanceKm * 1000 * 0.65
        let circleM = min(1_000, max(300, distanceKm * 1000 * 0.2))
        var chains: [RouteService.FinishPlace] = []
        var others: [RouteService.FinishPlace] = []
        let centres = [(start, 1_200.0)] + (0..<8).map { direction in
            (offset(start, metres: ringM, bearing: Double(direction) / 8 * 2 * .pi), circleM)
        }
        for (centre, radius) in centres {
            let request = MKLocalPointsOfInterestRequest(center: centre, radius: radius)
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.cafe, .restaurant, .bakery])
            guard let items = try? await MKLocalSearch(request: request).start().mapItems else { continue }
            for item in items {
                let c = item.placemark.coordinate
                let place = RouteService.FinishPlace(name: item.name ?? "Restaurant", lat: c.latitude, lon: c.longitude)
                let name = place.name.lowercased()
                if knownChains.contains(where: name.contains) { chains.append(place) } else if others.count < 24 { others.append(place) }
            }
        }
        // Chains first; only fill up with other places if there are too few chains.
        return Array((chains.count >= 3 ? chains : chains + others).prefix(20))
    }

    // MARK: - Along the route

    /// Medical stores, shops and clinics near the route, in running order.
    /// Looks within 400 m first and widens (800 m, then 1.5 km) until at least
    /// 3 medical stores are found, because Apple Maps lists fewer in Mumbai than exist.
    static func stops(along shape: RouteShape) async -> [Stop] {
        var stops: [Stop] = []
        for kind in Stop.Kind.allCases {
            let minimum = kind == .pharmacy ? 3 : 1
            var found: [Stop] = []
            for maxOffRouteM in [400.0, 800.0, 1_500.0] {
                found = await search(kind, along: shape, within: maxOffRouteM)
                if found.count >= minimum { break }
            }
            stops += found.sorted { $0.offRouteM < $1.offRouteM }.prefix(kind.limit)
        }
        return stops.sorted { $0.atKm < $1.atKm }
    }

    /// All places of one kind within `maxOffRouteM` of the route, without duplicates.
    private static func search(_ kind: Stop.Kind, along shape: RouteShape, within maxOffRouteM: Double) async -> [Stop] {
        guard let region = region(around: shape.option.line, paddingM: maxOffRouteM) else { return [] }
        var items: [MKMapItem] = []

        // 1. Apple's own categories.
        let categories: [MKPointOfInterestCategory] = switch kind {
        case .pharmacy: [.pharmacy]
        case .water: [.foodMarket, .store]
        case .clinic: [.hospital]
        }
        let request = MKLocalPointsOfInterestRequest(coordinateRegion: region)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: categories)
        items += (try? await MKLocalSearch(request: request).start().mapItems) ?? []

        // 2. Medical stores in Mumbai are often listed as shops, so also search by the
        //    words people use ("medical store", "chemist") and keep those that look right.
        if kind == .pharmacy {
            for words in ["medical store", "chemist", "pharmacy"] {
                let text = MKLocalSearch.Request()
                text.naturalLanguageQuery = words
                text.region = region
                text.resultTypes = .pointOfInterest
                let results = (try? await MKLocalSearch(request: text).start().mapItems) ?? []
                items += results.filter { item in
                    item.pointOfInterestCategory == .pharmacy
                        || ["medical", "chemist", "pharma", "medico", "drug", "wellness forever", "apollo", "noble plus"]
                            .contains { (item.name ?? "").lowercased().contains($0) }
                }
            }
        }

        // "Store" covers every kind of shop; for water keep grocery-like shops only.
        if kind == .water {
            let words = ["general", "kirana", "provision", "mart", "dairy", "supermarket", "super market", "grocery",
                         "store", "stores", "bazaar", "dmart", "24", "fresh", "juice", "chemist"]
            let notWater = ["flower", "jewel", "cloth", "fashion", "salon", "mobile", "hardware", "furniture", "optic", "garment"]
            items = items.filter { item in
                let name = (item.name ?? "").lowercased()
                if notWater.contains(where: name.contains) { return false }
                return item.pointOfInterestCategory == .foodMarket || words.contains(where: name.contains)
            }
        }

        var stops: [Stop] = []
        for item in items {
            let c = item.placemark.coordinate
            // Skip the same shop found by two searches (same name within 50 m).
            if stops.contains(where: { $0.name == item.name && RouteShape.metres($0.coordinate, c) < 50 }) { continue }
            let nearest = shape.nearest(to: c)
            guard nearest.offRouteM <= maxOffRouteM else { continue }
            stops.append(Stop(kind: kind, name: item.name ?? kind.rawValue, coordinate: c,
                              offRouteM: nearest.offRouteM, atKm: nearest.atKm))
        }
        return stops
    }

    // MARK: - Geometry helpers

    /// The point `metres` from `start` in compass direction `bearing` (radians, 0 = north).
    private static func offset(_ start: CLLocationCoordinate2D, metres: Double, bearing: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: start.latitude + metres * cos(bearing) / 111_000,
            longitude: start.longitude + metres * sin(bearing) / (111_000 * cos(start.latitude * .pi / 180)))
    }

    /// A map region covering a line, with some padding in metres.
    private static func region(around line: [CLLocationCoordinate2D], paddingM: Double) -> MKCoordinateRegion? {
        guard let first = line.first else { return nil }
        var (south, north, west, east) = (first.latitude, first.latitude, first.longitude, first.longitude)
        for p in line {
            south = min(south, p.latitude); north = max(north, p.latitude)
            west = min(west, p.longitude); east = max(east, p.longitude)
        }
        let padLat = paddingM / 111_000
        let padLon = paddingM / (111_000 * cos(first.latitude * .pi / 180))
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (south + north) / 2, longitude: (west + east) / 2),
            span: MKCoordinateSpan(latitudeDelta: north - south + 2 * padLat, longitudeDelta: east - west + 2 * padLon))
    }
}
