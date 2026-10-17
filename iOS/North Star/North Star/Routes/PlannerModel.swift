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

    var start: Place {
        didSet {
            if start != oldValue {
                startAddress = nil
                lookUpStartAddress()
                Task { await lookUpParks() }
            }
        }
    }
    /// A readable address for the start, like "Gundecha Trillium, Thakur Village".
    private(set) var startAddress: String?
    /// False (the default) keeps routes off highways and mostly-main-road streets.
    var allowBusyRoads = false
    var distanceKm: Double = 5
    var kind: RouteService.Kind = .loop
    /// One way only: where to finish. Nil lets North Star choose a clean finish.
    var finish: Place? {
        didSet { raiseDistanceToReachFinish() }
    }
    /// One way, no finish chosen: what kind of place to end at.
    enum FinishNear: Hashable {
        /// North Star picks a clean place to end.
        case anywhere
        /// A popular, well-rated restaurant or cafe.
        case food
        /// A local train or metro station, to ride home.
        case station
    }
    var finishNear: FinishNear = .anywhere

    /// How much of the run to spend on laps of a nearby park.
    enum Laps: Hashable {
        case none, half, all, custom
    }
    var laps: Laps = .none
    /// The number of laps for "Custom".
    var customLaps = 2
    /// Parks with a loop near the start (from the server), nearest first.
    private(set) var nearbyParks: [RouteService.NearbyPark] = []
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

    /// True while the phone is still pinning down a precise location for the start.
    var isLocating: Bool { start.coordinate == nil && location.state == .locating }
    /// True when "Precise Location" is off for this app, so the start could be far off.
    var startIsRough: Bool { start.coordinate == nil && location.isReducedAccuracy }
    /// How far off the current location may be, in metres.
    var locationAccuracyM: Double? { start.coordinate == nil ? location.accuracyM : nil }

    /// Starts waking the server as soon as the planner opens, and pins down the start.
    func prepare() {
        if start.coordinate == nil { refreshLocation() } else { lookUpStartAddress() }
        Task {
            await service.wake()
            await lookUpParks()
        }
    }

    /// Asks the server which parks with a loop are near the start (for "Park laps").
    func lookUpParks() async {
        guard let point = startCoordinate else { nearbyParks = []; return }
        let found = await service.nearbyParks(at: point)
        nearbyParks = found
        if found.isEmpty { laps = .none }
    }

    /// The nearest park, and the laps each choice would give at the current distance:
    /// (park, laps for half, laps for all), or nil when no park is near or none fit.
    var lapOptions: (park: RouteService.NearbyPark, half: Double, all: Double)? {
        guard let park = nearbyParks.first, park.loopKm > 0 else { return nil }
        let approach = park.distanceKm * 1.3   // streets wind
        let room = distanceKm - approach * (kind == .loop ? 2 : 1)
        let all = room / park.loopKm
        guard all >= 0.5 else { return nil }
        return (park, min(distanceKm / 2, room) / park.loopKm, all)
    }

    /// Asks GPS for a precise fix (up to 10 seconds), then looks up its address.
    func refreshLocation() {
        location.locatePrecisely()
        Task { @MainActor in
            while location.state == .locating { try? await Task.sleep(for: .milliseconds(300)) }
            lookUpStartAddress()
            await lookUpParks()
        }
    }

    /// Moves the start to a point the user tapped on the map.
    func pinStart(at coordinate: CLLocationCoordinate2D) {
        start = Place(id: "pin-\(coordinate.latitude),\(coordinate.longitude)", name: "Pinned start", coordinate: coordinate)
    }

    /// Looks up the start's address with Apple Maps (on the phone, free).
    private func lookUpStartAddress() {
        guard let coordinate = startCoordinate else { return }
        let looking = start
        Task { @MainActor in
            let placemark = try? await CLGeocoder()
                .reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
                .first
            guard start == looking, let placemark else { return }
            // Building or street name, then the neighbourhood: "Gundecha Trillium, Thakur Village".
            let parts = [placemark.name, placemark.subLocality ?? placemark.locality].compactMap { $0 }
            startAddress = Array(NSOrderedSet(array: parts)).compactMap { $0 as? String }.joined(separator: ", ")
        }
    }

    func planRoutes() async {
        // If GPS is still pinning down "Current location", wait for it (it gives up after 10 s).
        if isLocating {
            phase = .planning(wakingUp: false)
            for _ in 0..<40 where isLocating { try? await Task.sleep(for: .milliseconds(300)) }
        }
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
        let wantsFood = kind == .oneWay && finish == nil && finishNear == .food
        let wantsStation = kind == .oneWay && finish == nil && finishNear == .station
        if kind == .oneWay {
            if let finish, let c = finish.coordinate {
                finishes = [.init(name: finish.name, lat: c.latitude, lon: c.longitude)]
            } else if wantsFood {
                // The server picks well-rated places from Google; these are its fallback.
                finishes = await NearbyPlaces.foodFinishes(near: origin, distanceKm: distanceKm)
                #if DEBUG
                print("Food fallback from Apple Maps:", finishes.count)
                #endif
            }
        }

        do {
            let plan = try await service.plan(start: origin, distanceKm: distanceKm, kind: kind,
                                              startTime: startTime, finishPlaces: finishes,
                                              endNearFood: wantsFood, endNearStation: wantsStation,
                                              allowBusyRoads: allowBusyRoads,
                                              laps: lapsRequest, lapCount: laps == .custom ? customLaps : nil)
            phase = plan.options.isEmpty ? .failed(Self.noRouteMessage(plan, finish: finish)) : .planned(plan)
        } catch let error as URLError where error.code == .timedOut {
            phase = .failed("The route planner took too long to answer. It may still be waking up; try again.")
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Could not reach the route planner. Check your connection.")
        }
    }

    func reset() { phase = .choosing }

    /// What to send the server for laps ("none" when no park fits or a finish was chosen).
    private var lapsRequest: String {
        guard lapOptions != nil, finish == nil, finishNear == .anywhere else { return "none" }
        switch laps {
        case .none: return "none"
        case .half: return "half"
        case .all: return "all"
        case .custom: return "count"
        }
    }

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
