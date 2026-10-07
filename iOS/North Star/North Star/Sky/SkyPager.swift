import SwiftData
import SwiftUI

/// All the places as full-screen skies stacked vertically: swipe up or down to
/// move between them. The first is always "Current location", then saved places.
struct SkyPager: View {
    @Query(sort: \SavedPlace.sortOrder) private var saved: [SavedPlace]
    @State private var location = LocationProvider()
    @State private var selection: String? = Place.current.id
    @State private var scrubbing = false
    @State private var showingPlaces = false

    @Environment(\.modelContext) private var context

    /// Debug-only launch options for screenshots without touching the screen:
    /// "-place juhu" shows one running spot, "-hoursAhead 8" opens 8 hours ahead,
    /// "-seedPlaces YES" adds sample places if there are none, "-page 2" opens the
    /// third page, "-showPlaces YES" opens the places list.
    private let debugPlace: Place?
    private let debugHoursAhead: Int

    init() {
        #if DEBUG
        let defaults = UserDefaults.standard
        debugPlace = defaults.string(forKey: "place").flatMap { id in Place.runningSpots.first { $0.id == id } }
        debugHoursAhead = defaults.integer(forKey: "hoursAhead")
        #else
        debugPlace = nil
        debugHoursAhead = 0
        #endif
    }

    private func applyDebugOptions() {
        #if DEBUG
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "seedPlaces"), saved.isEmpty {
            let samples = [("Home", 19.2105, 72.8740), ("Office", 19.0659, 72.8621), ("My Juhu run", 19.0980, 72.8260)]
            for (index, sample) in samples.enumerated() {
                context.insert(SavedPlace(name: sample.0, latitude: sample.1, longitude: sample.2, sortOrder: index))
            }
            try? context.save()
        }
        let page = defaults.integer(forKey: "page")
        if page > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if places.indices.contains(page) { selection = places[page].id }
            }
        }
        if defaults.bool(forKey: "showPlaces") { showingPlaces = true }
        #endif
    }

    private var places: [Place] {
        if let debugPlace { return [debugPlace] }
        return [.current] + saved.map(\.place)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(places) { place in
                        SkyScreen(place: place, location: location, insets: geometry.safeAreaInsets,
                                  scrubbing: $scrubbing, hoursAhead: debugHoursAhead) {
                            showingPlaces = true
                        }
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(place.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $selection)
            .scrollIndicators(.hidden)
            .scrollDisabled(scrubbing)
            .ignoresSafeArea()
            .overlay(alignment: .trailing) { pageDots }
        }
        .onAppear(perform: applyDebugOptions)
        .sheet(isPresented: $showingPlaces) {
            PlacesSheet(selection: $selection, location: location)
        }
    }

    /// Small dots on the right edge showing which place you are on (only with 2 or more).
    @ViewBuilder
    private var pageDots: some View {
        if places.count > 1 {
            VStack(spacing: 7) {
                ForEach(places) { place in
                    // White with a thin dark ring, so the dots show on clear and hazy skies alike.
                    Circle()
                        .fill(.white.opacity(place.id == (selection ?? Place.current.id) ? 0.95 : 0.35))
                        .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 0.75))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.trailing, 10)
            .accessibilityHidden(true)
        }
    }
}
