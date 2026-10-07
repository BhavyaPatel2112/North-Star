import Foundation
import SwiftData

/// A place the user saved, like "Home" or "My Juhu run".
///
/// Stored only on the device with SwiftData (Apple's on-device database);
/// nothing about saved places is sent anywhere except the coordinates used
/// to fetch that place's forecast.
@Model
final class SavedPlace {
    var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    /// Position in the list (and in the swipe order).
    var sortOrder: Int
    var createdAt: Date

    init(name: String, latitude: Double, longitude: Double, sortOrder: Int) {
        self.id = UUID()
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.sortOrder = sortOrder
        self.createdAt = .now
    }

    /// The same place in the form the sky screens use.
    var place: Place {
        Place(id: id.uuidString, name: name, lat: latitude, lon: longitude)
    }
}
