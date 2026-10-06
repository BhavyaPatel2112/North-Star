import CoreLocation
import Observation

/// Finds the phone's current location once, asking for permission the first time.
///
/// Only "while using the app" permission is requested, and the location is used
/// to look up the nearest hexagon; it is never stored.
@Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    enum State: Equatable {
        case idle
        case locating
        case found(CLLocationCoordinate2D)
        case denied
        case failed

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.locating, .locating), (.denied, .denied), (.failed, .failed): true
            case let (.found(a), .found(b)): a.latitude == b.latitude && a.longitude == b.longitude
            default: false
            }
        }
    }

    private(set) var state: State = .idle
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        // Neighbourhood accuracy is enough: hexagons are about 350 m across.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func locate() {
        switch manager.authorizationStatus {
        case .notDetermined:
            state = .locating
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            state = .denied
        default:
            state = .locating
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .denied, .restricted: self.state = .denied
            case .notDetermined: break
            default: if self.state == .locating { manager.requestLocation() }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in self.state = .found(coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.state = .failed }
    }
}
