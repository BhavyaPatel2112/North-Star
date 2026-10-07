import CoreLocation
import SwiftData
import SwiftUI

/// The list of places: jump to one, rename, reorder or delete, or add a new one.
struct PlacesSheet: View {
    /// The id of the place currently shown; setting it jumps to that place's sky.
    @Binding var selection: String?
    let location: LocationProvider

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedPlace.sortOrder) private var saved: [SavedPlace]
    @State private var renaming: SavedPlace?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(name: Place.current.name, icon: "location.fill", id: Place.current.id)
                    ForEach(saved) { place in
                        row(name: place.name, icon: "mappin", id: place.id.uuidString)
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") { startRenaming(place) }
                                Button("Delete", systemImage: "trash", role: .destructive) { delete(place) }
                            }
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { delete(place) }
                                Button("Rename", systemImage: "pencil") { startRenaming(place) }
                            }
                    }
                    .onMove(perform: move)
                } footer: {
                    Text("Swipe up and down on the sky to move between places. Places are saved only on this device.")
                }

                Section {
                    NavigationLink {
                        AddPlaceView(location: location) { added in
                            selection = added.id.uuidString
                            dismiss()
                        }
                    } label: {
                        Label("Add a place", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Places")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) { if !saved.isEmpty { EditButton() } }
                #endif
            }
            .alert("Rename place", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") {
                    let trimmed = newName.trimmingCharacters(in: .whitespaces)
                    if let place = renaming, !trimmed.isEmpty { place.name = trimmed }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    private func row(name: String, icon: String, id: String) -> some View {
        Button {
            selection = id
            dismiss()
        } label: {
            HStack {
                Label(name, systemImage: icon)
                Spacer()
                if selection == id { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
        .foregroundStyle(.primary)
    }

    private func startRenaming(_ place: SavedPlace) {
        newName = place.name
        renaming = place
    }

    private func delete(_ place: SavedPlace) {
        if selection == place.id.uuidString { selection = Place.current.id }
        context.delete(place)
    }

    /// Reorder: renumber every saved place in its new order.
    private func move(from source: IndexSet, to destination: Int) {
        var ordered = saved
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, place) in ordered.enumerated() { place.sortOrder = index }
    }
}
