import CoreLocation
import SwiftData
import SwiftUI

/// Add a place: search Apple Maps, pick a running spot, or save where you are now,
/// then give it a short name like "Home" or "My Juhu run".
struct AddPlaceView: View {
    let location: LocationProvider
    /// Called with the new place after it is saved.
    let onAdded: (SavedPlace) -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: \SavedPlace.sortOrder) private var saved: [SavedPlace]
    @State private var search = PlaceSearch()
    @State private var pending: PendingPlace?
    @State private var name = ""
    @State private var lookingUp = false

    /// A chosen place waiting for its name.
    private struct PendingPlace {
        let suggestedName: String
        let coordinate: CLLocationCoordinate2D
    }

    var body: some View {
        List {
            if search.query.isEmpty {
                Section("Where you are") {
                    Button {
                        if case .found(let coordinate) = location.state {
                            choose(name: "Home", coordinate: coordinate)
                        } else {
                            location.locate()
                        }
                    } label: {
                        Label(currentLocationLabel, systemImage: "location")
                    }
                }
                Section("Running spots") {
                    ForEach(Place.runningSpots) { spot in
                        Button(spot.name) {
                            if let coordinate = spot.coordinate { choose(name: spot.name, coordinate: coordinate) }
                        }
                    }
                }
            } else {
                Section {
                    ForEach(search.suggestions) { suggestion in
                        Button {
                            Task {
                                lookingUp = true
                                if let coordinate = await search.coordinate(of: suggestion) {
                                    choose(name: suggestion.title, coordinate: coordinate)
                                }
                                lookingUp = false
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } footer: {
                    if search.suggestions.isEmpty { Text("No matches yet. Try an area, a street or a landmark.") }
                }
            }
        }
        .foregroundStyle(.primary)
        .searchable(text: $search.query, prompt: "Search Mumbai")
        .navigationTitle("Add a place")
        .overlay { if lookingUp { ProgressView() } }
        .alert("Name this place", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            TextField("Name", text: $name)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("A short name you will recognise, like Home or My Juhu run.")
        }
    }

    private var currentLocationLabel: String {
        switch location.state {
        case .found: "Save where I am now"
        case .locating: "Finding you…"
        case .denied: "Location is off (allow it in Settings)"
        default: "Use my current location"
        }
    }

    private func choose(name suggested: String, coordinate: CLLocationCoordinate2D) {
        name = suggested
        pending = PendingPlace(suggestedName: suggested, coordinate: coordinate)
    }

    private func save() {
        guard let pending else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let place = SavedPlace(name: trimmed.isEmpty ? pending.suggestedName : trimmed,
                               latitude: pending.coordinate.latitude,
                               longitude: pending.coordinate.longitude,
                               sortOrder: (saved.map(\.sortOrder).max() ?? -1) + 1)
        context.insert(place)
        self.pending = nil
        onAdded(place)
    }
}
