import MapKit
import Observation

/// Search for places in and around Mumbai with Apple Maps, as the user types.
///
/// Suggestions come from Apple's search completer (no extra service or key
/// needed); choosing one looks up its exact coordinates.
@Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    struct Suggestion: Identifiable, Hashable {
        let id = UUID()
        let title: String
        let subtitle: String
        fileprivate let completion: MKLocalSearchCompletion

        static func == (lhs: Suggestion, rhs: Suggestion) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// The text being searched for; setting it updates the suggestions.
    var query = "" {
        didSet { completer.queryFragment = query }
    }
    private(set) var suggestions: [Suggestion] = []

    private let completer = MKLocalSearchCompleter()

    /// The area North Star covers, so results favour Mumbai.
    static let mumbaiRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 19.10, longitude: 72.92),
        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.4))

    override init() {
        super.init()
        completer.delegate = self
        completer.region = Self.mumbaiRegion
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// The coordinates of a chosen suggestion.
    func coordinate(of suggestion: Suggestion) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request(completion: suggestion.completion)
        request.region = Self.mumbaiRegion
        let response = try? await MKLocalSearch(request: request).start()
        return response?.mapItems.first?.placemark.coordinate
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results.prefix(12).map {
            Suggestion(title: $0.title, subtitle: $0.subtitle, completion: $0)
        }
        Task { @MainActor in self.suggestions = Array(results) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.suggestions = [] }
    }
}
