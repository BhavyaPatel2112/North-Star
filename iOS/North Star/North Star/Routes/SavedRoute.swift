import Foundation
import SwiftData

/// A planned route the user saved to run again ("Saved routes" on the Plan tab).
///
/// Stored only on the device with SwiftData. The route is kept exactly as the route
/// server sent it (its JSON), so it opens again with its map, elevation, steps and
/// pace plan. Air quality and the best start time are from the day it was saved.
@Model
final class SavedRoute {
    var id: UUID
    var name: String
    var savedAt: Date
    var distanceKm: Double
    /// "Loop", "One way" or "Park laps", for the list.
    var kindLabel: String
    /// The route as the server sent it.
    var json: Data

    init(name: String, distanceKm: Double, kindLabel: String, json: Data) {
        self.id = UUID()
        self.name = name
        self.savedAt = .now
        self.distanceKm = distanceKm
        self.kindLabel = kindLabel
        self.json = json
    }

    /// The route, read back from its JSON (nil if it cannot be read).
    var option: RouteOption? {
        guard var option = try? ForecastService.decoder.decode(RouteOption.self, from: json) else { return nil }
        option.rawJSON = json
        return option
    }
}
