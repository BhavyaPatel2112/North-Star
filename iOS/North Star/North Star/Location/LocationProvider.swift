import CoreLocation
import Observation

/// Finds the phone's current location once, asking for permission the first time.
///
/// Only "while using the app" permission is requested, and the location is used
/// to look up the nearest hexagon or to start a run; it is never stored.
///
/// Two levels of accuracy:
/// - neighbourhood (about 100 m), enough for the sky's forecast hexagon;
/// - precise (GPS, usually within 5 to 20 m), for the start of a run, so a run
///   starts at your building gate rather than somewhere down the road.
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
    /// How far off the last location may be, in metres (smaller is better).
    private(set) var accuracyM: Double?
    private let manager = CLLocationManager()

    /// While finding a precise location: the best reading so far, and when to stop waiting.
    private var preciseBest: CLLocation?
    private var preciseUntil: Date?
    /// Good enough to stop listening (GPS rarely does better in a city).
    private static let preciseEnoughM: Double = 20
    private static let preciseWaitSeconds: Double = 10

    /// True when the user turned off "Precise Location" for this app: iOS then gives
    /// only a rough area (often a kilometre or more off), useless for a run start.
    var isReducedAccuracy: Bool { manager.accuracyAuthorization == .reducedAccuracy }

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

    /// Listens to GPS for up to 10 seconds and keeps the most accurate reading,
    /// stopping early once it is within 20 m.
    func locatePrecisely() {
        preciseBest = nil
        preciseUntil = Date.now.addingTimeInterval(Self.preciseWaitSeconds)
        manager.desiredAccuracy = kCLLocationAccuracyBest
        switch manager.authorizationStatus {
        case .notDetermined:
            state = .locating
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            state = .denied
            return
        default:
            state = .locating
            manager.startUpdatingLocation()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.preciseWaitSeconds + 0.5))
            self.finishPrecise()
        }
    }

    /// Stops listening and reports the best reading found.
    private func finishPrecise() {
        guard preciseUntil != nil else { return }
        preciseUntil = nil
        manager.stopUpdatingLocation()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        if let best = preciseBest {
            accuracyM = best.horizontalAccuracy
            state = .found(best.coordinate)
        } else if state == .locating {
            state = .failed
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .denied, .restricted: self.state = .denied
            case .notDetermined: break
            default:
                guard self.state == .locating else { break }
                if self.preciseUntil != nil { manager.startUpdatingLocation() } else { manager.requestLocation() }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            if let until = self.preciseUntil {
                // Precise mode: keep the most accurate reading; stop when good enough or out of time.
                if location.horizontalAccuracy >= 0,
                   self.preciseBest == nil || location.horizontalAccuracy < self.preciseBest!.horizontalAccuracy {
                    self.preciseBest = location
                }
                if location.horizontalAccuracy <= Self.preciseEnoughM || Date.now >= until { self.finishPrecise() }
            } else {
                self.accuracyM = location.horizontalAccuracy
                self.state = .found(location.coordinate)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.state = .failed }
    }
}
