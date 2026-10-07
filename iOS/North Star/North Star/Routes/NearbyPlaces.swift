import CoreLocation
import MapKit

/// Places from Apple Maps used by the run planner, looked up on the phone
/// (free, no key, nothing about the user is sent to our server):
/// - food finishes: cafes, restaurants and bakeries a one-way run could end at;
/// - help along the way: pharmacies, shops for water and clinics near the route.
///
/// Apple Maps does not always know opening hours, so the app says "check it is open".
enum NearbyPlaces {
    /// Something useful near a route, for example "Pharmacy, 120 m off route at km 2.3".
    struct Stop: Identifiable {
        enum Kind: String, CaseIterable {
            case pharmacy = "Pharmacy"
            case water = "Water and snacks"
            case clinic = "Clinic or hospital"

            var categories: [MKPointOfInterestCategory] {
                switch self {
                case .pharmacy: [.pharmacy]
                case .water: [.foodMarket, .store]
                case .clinic: [.hospital]
                }
            }

            var symbol: String {
                switch self {
                case .pharmacy: "cross.case"
                case .water: "waterbottle"
                case .clinic: "stethoscope"
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

    /// Up to 20 cafes, restaurants and bakeries roughly the right distance away
    /// for a one-way run, spread around the compass so the server has real choices.
    /// The server then plans the cleanest run of the chosen length that ends at one.
    ///
    /// Apple Maps returns only about 25 places per search, closest first, so one big
    /// search around the start would only find cafes next door. Instead we search 8
    /// small circles on a ring about 65% of the run's distance away (streets wind,
    /// so a 5 km run usually ends 3 to 4 km from the start as the crow flies).
    static func foodFinishes(near start: CLLocationCoordinate2D, distanceKm: Double) async -> [RouteService.FinishPlace] {
        let ringM = distanceKm * 1000 * 0.65
        let circleM = min(1_000, max(300, distanceKm * 1000 * 0.2))
        var picked: [RouteService.FinishPlace] = []
        for direction in 0..<8 {
            let bearing = Double(direction) / 8 * 2 * .pi
            let centre = CLLocationCoordinate2D(
                latitude: start.latitude + ringM * cos(bearing) / 111_000,
                longitude: start.longitude + ringM * sin(bearing) / (111_000 * cos(start.latitude * .pi / 180)))
            let request = MKLocalPointsOfInterestRequest(center: centre, radius: circleM)
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.cafe, .restaurant, .bakery])
            guard let items = try? await MKLocalSearch(request: request).start().mapItems else { continue }
            // Up to 3 per direction (20 at most in all; the server's limit).
            for item in items.prefix(3) where picked.count < 20 {
                let c = item.placemark.coordinate
                picked.append(.init(name: item.name ?? "Cafe", lat: c.latitude, lon: c.longitude))
            }
        }
        return picked
    }

    /// Pharmacies, shops and clinics within 400 m of the route: the nearest few of
    /// each kind, in running order.
    static func stops(along shape: RouteShape, within maxOffRouteM: Double = 400) async -> [Stop] {
        guard let region = region(around: shape.option.line, paddingM: maxOffRouteM) else { return [] }
        var stops: [Stop] = []
        for kind in Stop.Kind.allCases {
            let request = MKLocalPointsOfInterestRequest(coordinateRegion: region)
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: kind.categories)
            guard let items = try? await MKLocalSearch(request: request).start().mapItems else { continue }
            let near = items.compactMap { item -> Stop? in
                let c = item.placemark.coordinate
                let where_ = shape.nearest(to: c)
                guard where_.offRouteM <= maxOffRouteM else { return nil }
                return Stop(kind: kind, name: item.name ?? kind.rawValue, coordinate: c,
                            offRouteM: where_.offRouteM, atKm: where_.atKm)
            }
            stops += near.sorted { $0.offRouteM < $1.offRouteM }.prefix(3)
        }
        return stops.sorted { $0.atKm < $1.atKm }
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
