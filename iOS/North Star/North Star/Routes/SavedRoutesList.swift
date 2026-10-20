import SwiftData
import SwiftUI

/// How saved routes are named and described.
enum SavedRouteNames {
    /// "Loop", "One way" or "Park laps".
    static func kind(of option: RouteOption) -> String {
        if option.park != nil { return "Park laps" }
        return option.isLoop ? "Loop" : "One way"
    }

    /// A first suggestion for the name: "2 laps of Shivaji Park", "Ends at Khar Road station",
    /// or the route's street mix.
    static func suggested(for option: RouteOption) -> String {
        if option.park != nil { return option.label }
        if let place = option.finishPlace { return "To \(place.name)" }
        let first = option.steps.first?.displayName ?? ""
        return first.isEmpty ? option.label : "From \(first)"
    }
}

/// "Saved routes" on the Plan tab: the routes you kept, newest first. Tap one to open
/// it; swipe or long-press to delete.
struct SavedRoutesCard: View {
    @Query(sort: \SavedRoute.savedAt, order: .reverse) private var saved: [SavedRoute]
    @Environment(\.modelContext) private var context
    @State private var showingAll = false

    var body: some View {
        if !saved.isEmpty {
            JourneyCard(title: "Saved routes") {
                ForEach(showingAll ? saved : Array(saved.prefix(3))) { route in
                    if let option = route.option {
                        NavigationLink {
                            RouteDetailView(shape: RouteShape(option), savedOn: route.savedAt)
                        } label: {
                            row(route)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) { delete(route) }
                        }
                    }
                }
                if saved.count > 3 {
                    Button(showingAll ? "Show fewer" : "Show all \(saved.count)") {
                        withAnimation(.snappy) { showingAll.toggle() }
                    }
                    .font(.subheadline.weight(.medium))
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func row(_ route: SavedRoute) -> some View {
        HStack(spacing: 12) {
            Image(systemName: route.kindLabel == "Park laps" ? "arrow.triangle.2.circlepath" : "bookmark.fill")
                .frame(width: 30, height: 30)
                .background(Theme.ink.opacity(0.07), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(route.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(PlannerModel.format(km: route.distanceKm)) · \(route.kindLabel)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .foregroundStyle(Theme.ink)
        .contentShape(Rectangle())
    }

    private func delete(_ route: SavedRoute) {
        context.delete(route)
        try? context.save()
    }
}
