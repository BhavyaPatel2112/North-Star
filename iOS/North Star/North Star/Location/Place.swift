import CoreLocation

/// A place the sky can show: the phone's location or a named spot.
struct Place: Identifiable, Hashable {
    let id: String
    let name: String
    /// Nil means "wherever the phone is".
    let coordinate: CLLocationCoordinate2D?

    static let current = Place(id: "current", name: "Current location", coordinate: nil)

    /// Popular running spots, used until saved places arrive (and when location is off).
    static let runningSpots: [Place] = [
        Place(id: "juhu", name: "Juhu Beach", lat: 19.0980, lon: 72.8260),
        Place(id: "bandstand", name: "Bandra Bandstand", lat: 19.0430, lon: 72.8190),
        Place(id: "worli", name: "Worli Sea Face", lat: 19.0090, lon: 72.8160),
        Place(id: "powai", name: "Powai Lake", lat: 19.1270, lon: 72.9060),
        Place(id: "sgnp", name: "Sanjay Gandhi National Park gate", lat: 19.2290, lon: 72.8640),
        Place(id: "upvan", name: "Upvan Lake, Thane", lat: 19.2223, lon: 72.9580),
        Place(id: "vashi", name: "Vashi, Navi Mumbai", lat: 19.0770, lon: 72.9990),
    ]

    init(id: String, name: String, coordinate: CLLocationCoordinate2D?) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
    }

    init(id: String, name: String, lat: Double, lon: Double) {
        self.init(id: id, name: name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    static func == (lhs: Place, rhs: Place) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
