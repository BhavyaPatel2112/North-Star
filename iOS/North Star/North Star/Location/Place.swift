import CoreLocation

/// A place the sky can show: the phone's location or a named spot.
struct Place: Identifiable, Hashable {
    let id: String
    let name: String
    /// Nil means "wherever the phone is".
    let coordinate: CLLocationCoordinate2D?

    static let current = Place(id: "current", name: "Current location", coordinate: nil)

    /// Popular running spots: always offered as starts. Each point sits on the
    /// spot's own promenade or road, and each was checked to give real 5 km loops
    /// on the street network (Oct 2026). Juhu Beach and the National Park gate are
    /// left out: routes from there failed the walking check or could only go out and back.
    static let runningSpots: [Place] = [
        Place(id: "bandstand", name: "Bandra Bandstand", lat: 19.0429, lon: 72.8186),
        Place(id: "carter", name: "Carter Road", lat: 19.0656, lon: 72.8232),
        Place(id: "worli", name: "Worli Sea Face", lat: 19.0088, lon: 72.8149),
        Place(id: "marine", name: "Marine Drive", lat: 18.9439, lon: 72.8234),
        Place(id: "shivaji", name: "Shivaji Park", lat: 19.0259, lon: 72.8394),
        Place(id: "powai", name: "Powai Lake", lat: 19.1239, lon: 72.9101),
        Place(id: "oval", name: "Oval Maidan", lat: 18.9290, lon: 72.8266),
        Place(id: "upvan", name: "Upvan Lake, Thane", lat: 19.2244, lon: 72.9585),
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
