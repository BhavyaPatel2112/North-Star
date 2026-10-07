import SwiftData
import SwiftUI

/// North Star: air quality for Mumbai, shown as the sky.
@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Saved places live in an on-device SwiftData store.
        .modelContainer(for: SavedPlace.self)
    }
}
