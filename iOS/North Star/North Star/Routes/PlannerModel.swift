import CoreLocation
import Foundation
import Observation

/// Everything the run planner needs: the user's choices (start, distance, loop
/// or one way, finish, start time) and the state of the request to the server.
@Observable
final class PlannerModel {
    enum Phase {
        case choosing
        /// Waiting for the server. `wakingUp` turns true after a few seconds, when
        /// the server is probably starting up from sleep.
        case planning(wakingUp: Bool)
        case planned(RoutePlan)
        case failed(String)
    }

    var start: Place
    var distanceKm: Double = 5
    var kind: RouteService.Kind = .loop
    /// One way only: where to finish. Nil lets North Star choose a clean finish.
    var finish: Place? {
        didSet { raiseDistanceToReachFinish() }
    }
    /// One way, no finish chosen: end at a cafe, restaurant or bakery.
    var endNearFood = false
    /// Nil means "now".
    var startTime: Date?

    private(set) var phase: Phase = .choosing {
        didSet {
            #if DEBUG
            if case .failed(let message) = phase { print("Planner failed:", message) }
            if case .planned(let plan) = phase { print("Planner found \(plan.options.count) routes") }
            #endif
        }
    }
    /// A short note about an automatic change (for example the distance raised to reach the finish).
    private(set) var note: String?

    private let service = RouteService()
    private let location: LocationProvider

    static let distanceRange: ClosedRange<Double> = 1...30
    static let quickDistances: [Double] = [3, 5, 10, 21.1]

    init(start: Place, location: LocationProvider) {
        self.start = start
        self.location = location
    }

    var isPlanning: Bool { if case .planning = phase { true } else { false } }

    /// The start's coordinates, using the phone's location for "Current location".
    var startCoordinate: CLLocationCoordinate2D? {
        if let coordinate = start.coordinate { return coordinate }
        if case .found(let coordinate) = location.state { return coordinate }
        return nil
    }

    /// Starts waking the server as soon as the planner opens.
    func prepare() {
        if start.coordinate == nil { location.locate() }
        Task { await service.wake() }
    }

    func planRoutes() async {
        guard let origin = startCoordinate else {
            phase = .failed(location.state == .denied
                ? "Location is off. Choose a start place, or allow location in Settings."
                : "Still finding your location. Try again in a moment, or choose a start place.")
            return
        }
        phase = .planning(wakingUp: false)
        // If nothing has come back after 4 seconds, the server is probably waking up.
        let slowNotice = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if case .planning = phase { phase = .planning(wakingUp: true) }
        }
        defer { slowNotice.cancel() }

        var finishes: [RouteService.FinishPlace] = []
        if kind == .oneWay {
            if let finish, let c = finish.coordinate {
                finishes = [.init(name: finish.name, lat: c.latitude, lon: c.longitude)]
            } else if endNearFood {
                finishes = await NearbyPlaces.foodFinishes(near: origin, distanceKm: distanceKm)
                #if DEBUG
                print("Food finishes from Apple Maps:", finishes.count)
                #endif
                if finishes.isEmpty {
                    phase = .failed("Apple Maps found no cafes or restaurants about \(Self.format(km: distanceKm)) away. Try another distance, or turn off \"End near food\".")
                    return
                }
            }
        }

        do {
            let plan = try await service.plan(start: origin, distanceKm: distanceKm, kind: kind,
                                              startTime: startTime, finishPlaces: finishes)
            phase = plan.options.isEmpty ? .failed(Self.noRouteMessage(plan, finish: finish)) : .planned(plan)
        } catch let error as URLError where error.code == .timedOut {
            phase = .failed("The route planner took too long to answer. It may still be waking up; try again.")
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Could not reach the route planner. Check your connection.")
        }
    }

    func reset() { phase = .choosing }

    /// A finish point further away than the chosen distance can't be reached; raise
    /// the distance to the straight-line distance plus 30% (streets are not straight).
    private func raiseDistanceToReachFinish() {
        note = nil
        guard kind == .oneWay, let from = startCoordinate, let to = finish?.coordinate else { return }
        let needed = (RouteShape.metres(from, to) / 1000 * 1.3 * 2).rounded(.up) / 2
        if needed > distanceKm {
            distanceKm = min(Self.distanceRange.upperBound, needed)
            note = "Distance raised to \(Self.format(km: distanceKm)) so the run can reach \(finish?.name ?? "the finish")."
        }
    }

    private static func noRouteMessage(_ plan: RoutePlan, finish: Place?) -> String {
        if finish != nil {
            return "No walkable route of that distance reaches \(finish!.name). Try a longer distance."
        }
        return plan.message ?? "No walkable route of that distance found here. Try a slightly different start or distance."
    }

    static func format(km: Double) -> String {
        km == km.rounded() ? "\(Int(km)) km" : String(format: "%.1f km", km)
    }
}
