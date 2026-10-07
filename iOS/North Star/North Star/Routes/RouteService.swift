import CoreLocation
import Foundation

/// Talks to the North Star route server, which plans runs on Mumbai's street
/// network (too big to keep on the phone) and checks them against Google's
/// walking directions.
///
/// The server runs on a free plan that sleeps after 15 minutes without use, so
/// the first request can take about a minute. `wake()` sends a tiny request as
/// soon as the planner opens, so the server is usually awake by the time the
/// user has chosen a distance.
struct RouteService {
    /// A place the run may finish at (for example a cafe), sent for one-way runs.
    struct FinishPlace: Encodable {
        let name: String
        let lat: Double
        let lon: Double
    }

    enum Kind: String, Encodable, CaseIterable, Identifiable {
        case loop
        case oneWay = "one_way"
        var id: String { rawValue }
    }

    enum ServiceError: LocalizedError {
        case notConfigured
        case rejected(String)
        case server(status: Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "The route planner is not set up in this copy of the app (missing app key)."
            case .rejected(let reason):
                reason
            case .server(let status):
                "The route planner answered with an error (\(status)). Try again in a minute."
            }
        }
    }

    private struct Request: Encodable {
        let lat: Double
        let lon: Double
        let distance_km: Double
        let kind: Kind
        let start_time: Date?
        let finish_places: [FinishPlace]
    }

    var session: URLSession = .shared

    /// The app key, read from RouteServer.plist (made by Backend/scripts/write_app_config.py
    /// and kept out of Git). Empty if the file is missing.
    static let appKey: String = {
        guard let url = Bundle.main.url(forResource: "RouteServer", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return "" }
        return values["AppKey"] as? String ?? ""
    }()

    /// Pokes the server so it starts waking up. Errors are ignored.
    func wake() async {
        guard let base = AppConfig.routeServerURL else { return }
        var request = URLRequest(url: base.appending(path: "health"))
        request.timeoutInterval = 90
        _ = try? await session.data(for: request)
    }

    /// Plans up to 3 routes from `start`.
    func plan(start: CLLocationCoordinate2D, distanceKm: Double, kind: Kind,
              startTime: Date? = nil, finishPlaces: [FinishPlace] = []) async throws -> RoutePlan {
        guard let base = AppConfig.routeServerURL, !Self.appKey.isEmpty else { throw ServiceError.notConfigured }
        var request = URLRequest(url: base.appending(path: "v1/routes"))
        request.httpMethod = "POST"
        // Generous: a sleeping server takes about a minute to start, then ~10 s to plan.
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.appKey, forHTTPHeaderField: "X-App-Key")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(Request(
            lat: start.latitude, lon: start.longitude, distance_km: distanceKm, kind: kind,
            start_time: startTime, finish_places: finishPlaces))

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            return try ForecastService.decoder.decode(RoutePlan.self, from: data)
        case 401:
            throw ServiceError.notConfigured
        case 422, 503:
            // The server explains these in plain words ("Start is outside the area...").
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"]
            throw ServiceError.rejected(detail ?? "The route planner could not plan from here.")
        default:
            throw ServiceError.server(status: status)
        }
    }
}
