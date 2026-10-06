import Foundation

/// Fetches forecasts from the backend.
///
/// The app talks to one read-only database function (app_forecast) through
/// Supabase's web API, using the project's publishable key. That key is meant
/// to be built into apps: it can call that one function and nothing else,
/// because every table is protected by row level security.
struct ForecastService {
    enum ServiceError: LocalizedError {
        case notConfigured
        case server(status: Int)
        case noData

        var errorDescription: String? {
            switch self {
            case .notConfigured: "The app is missing its server address or key."
            case .server(let status): "The forecast server answered with an error (\(status)). Try again in a minute."
            case .noData: "No forecast is available for this place yet."
            }
        }
    }

    var session: URLSession = .shared

    func forecast(latitude: Double, longitude: Double) async throws -> Forecast {
        guard let base = AppConfig.supabaseURL, !AppConfig.supabasePublishableKey.isEmpty else {
            throw ServiceError.notConfigured
        }
        var request = URLRequest(url: base.appending(path: "rest/v1/rpc/app_forecast"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConfig.supabasePublishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(["lat": latitude, "lon": longitude])

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ServiceError.server(status: status) }
        let forecast = try Self.decoder.decode(Forecast.self, from: data)
        guard !forecast.hours.isEmpty else { throw ServiceError.noData }
        return forecast
    }

    /// Dates arrive as "2026-10-06T14:00:00+00:00", sometimes with fractions of a second.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = plain.date(from: text) ?? fractional.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unreadable date \(text)"))
        }
        return decoder
    }()
}
