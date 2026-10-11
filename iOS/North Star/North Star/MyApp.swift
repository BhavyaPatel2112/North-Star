import SwiftData
import SwiftUI

/// North Star: plan the best run in Mumbai, in any weather.
@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // The route server sleeps when nobody uses it (free hosting) and takes
                // about a minute to wake. Poke it as soon as the app opens, so it is
                // usually awake by the time someone plans a run.
                .task { await RouteService().wake() }
        }
        // Saved places live in an on-device SwiftData store.
        .modelContainer(for: SavedPlace.self)
    }
}
