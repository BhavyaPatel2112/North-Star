import CoreLocation
import MapKit
import SwiftData
import SwiftUI

/// The run planner: choose a start, a distance and a loop or one-way run, then
/// see up to 3 cleaner routes on a map.
struct PlannerView: View {
    @State private var model: PlannerModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showResults = false
    @State private var startCamera: MapCameraPosition = .automatic

    let location: LocationProvider
    /// False when the planner is a tab (nothing to close).
    let showsClose: Bool

    init(start: Place, location: LocationProvider, showsClose: Bool = true) {
        self.location = location
        self.showsClose = showsClose
        _model = State(initialValue: PlannerModel(start: start, location: location))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        PlacePicker(title: "Start", location: location, allowsCurrent: true) { model.start = $0 }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.start.name)
                                if let address = model.startAddress {
                                    Text(address).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: model.start == .current ? "location.fill" : "mappin.and.ellipse")
                        }
                    }
                    startMap
                    locationStatus
                    popularStarts
                } header: {
                    Text("Start")
                } footer: {
                    Text("Tap the map to move the start exactly where you want it.")
                }

                Section {
                    distancePicker
                } header: {
                    Text("Distance")
                } footer: {
                    if let note = model.note { Text(note) }
                }

                Section {
                    Picker("Run", selection: $model.kind) {
                        Text("Loop").tag(RouteService.Kind.loop)
                        Text("One way").tag(RouteService.Kind.oneWay)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text(model.kind == .loop
                         ? "Start and finish at the same place. If no good loop exists, you get an out-and-back."
                         : "End somewhere else. Leave the finish empty and North Star picks a clean place to end.")
                }

                if model.kind == .oneWay {
                    Section { oneWayOptions }
                }

                Section {
                    Toggle("OK with highways and busy roads", isOn: $model.allowBusyRoads)
                } footer: {
                    Text(model.allowBusyRoads
                         ? "Routes may cross highways and follow main roads with heavy traffic."
                         : "Routes never cross a highway (at a signal, under a flyover or over a bridge) and stay off roads that are mostly main road.")
                }

                Section("Start time") {
                    Toggle("Start now", isOn: Binding(
                        get: { model.startTime == nil },
                        set: { model.startTime = $0 ? nil : Self.nextHour }))
                    if let time = model.startTime {
                        DatePicker("Starting at", selection: Binding(get: { time }, set: { model.startTime = $0 }),
                                   in: Date.now...Date.now.addingTimeInterval(30 * 3600),
                                   displayedComponents: [.date, .hourAndMinute])
                    }
                }

                Section {
                    Button {
                        Task {
                            await model.planRoutes()
                            if case .planned = model.phase { showResults = true }
                        }
                    } label: {
                        HStack {
                            Text("Find clean routes").font(.headline)
                            Spacer()
                            if model.isPlanning { ProgressView() }
                        }
                    }
                    .disabled(model.isPlanning)
                } footer: {
                    status
                }
            }
            .navigationTitle("Plan a run")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if showsClose {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
            }
            .navigationDestination(isPresented: $showResults) {
                if case .planned(let plan) = model.phase {
                    RouteResultsView(plan: plan, model: model)
                }
            }
            .onAppear {
                model.prepare()
                #if DEBUG
                applyDebugOptions()
                #endif
            }
        }
    }

    // MARK: - Pieces

    private var distancePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text(PlannerModel.format(km: model.distanceKm))
                    .font(.system(size: 40, weight: .bold).monospacedDigit())
                    .contentTransition(.numericText(value: model.distanceKm))
                Spacer()
                Stepper("Distance", value: $model.distanceKm, in: PlannerModel.distanceRange, step: 0.5)
                    .labelsHidden()
            }
            HStack(spacing: 8) {
                ForEach(PlannerModel.quickDistances, id: \.self) { km in
                    Button(km == 21.1 ? "Half" : PlannerModel.format(km: km)) {
                        withAnimation(.snappy) { model.distanceKm = km }
                    }
                    .buttonStyle(.bordered)
                    .tint(model.distanceKm == km ? .accentColor : .secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// A small map of the start. Tapping it pins the start to that exact point.
    private var startMap: some View {
        MapReader { proxy in
            Map(position: $startCamera, interactionModes: [.pan, .zoom]) {
                if let c = model.startCoordinate {
                    Marker("Start", systemImage: "figure.run", coordinate: c).tint(.black)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .onTapGesture { point in
                if let c = proxy.convert(point, from: .local) { model.pinStart(at: c) }
            }
        }
        .frame(height: 170)
        .listRowInsets(EdgeInsets())
        .onChange(of: model.startCoordinate?.latitude, initial: true) { recentre() }
        .onChange(of: model.startCoordinate?.longitude) { recentre() }
    }

    private func recentre() {
        guard let c = model.startCoordinate else { return }
        startCamera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 600, longitudinalMeters: 600))
    }

    /// How sure we are of "Current location", with a fix for the common problems.
    @ViewBuilder
    private var locationStatus: some View {
        if model.start == .current {
            if model.startIsRough {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Precise Location is off", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Your start could be a kilometre or more off. Turn on Precise Location for North Star in Settings, or tap the map to set the start.")
                        .font(.caption).foregroundStyle(.secondary)
                    #if os(iOS)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    #endif
                }
            } else if model.isLocating {
                HStack {
                    ProgressView()
                    Text("Finding your exact spot…").foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    if let accuracy = model.locationAccuracyM {
                        Text("Accurate to about \(Int(max(5, accuracy).rounded())) m").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Locate again") { model.refreshLocation() }
                }
                .font(.subheadline)
            }
        }
    }

    /// Popular running spots, one tap away.
    private var popularStarts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if model.start != .current {
                    chip("Current location", systemImage: "location.fill") { model.start = .current; model.refreshLocation() }
                }
                ForEach(Place.runningSpots) { spot in
                    chip(spot.name, selected: model.start == spot) { model.start = spot }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(_ title: String, systemImage: String? = nil, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
        }
        .buttonStyle(.bordered)
        .tint(selected ? .accentColor : .secondary)
        .font(.subheadline)
    }

    @ViewBuilder
    private var oneWayOptions: some View {
        NavigationLink {
            PlacePicker(title: "Finish", location: location, allowsCurrent: false) { model.finish = $0 }
        } label: {
            LabeledContent("Finish", value: model.finish?.name ?? "North Star chooses")
        }
        if model.finish != nil {
            Button("Let North Star choose the finish", role: .destructive) { model.finish = nil }
        } else {
            Toggle(isOn: $model.endNearFood) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("End near food")
                    Text("Finish at a popular, well-rated restaurant or cafe")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .planning(let wakingUp):
            Text(wakingUp
                 ? "Waking up the route planner. The first plan after a quiet spell can take up to a minute."
                 : "Planning routes and checking them against walking directions…")
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        default:
            Text("Routes use the forecast for your start time and avoid busy roads where they can.")
        }
    }

    #if DEBUG
    /// Launch options for testing without tapping (see SkyPager).
    private func applyDebugOptions() {
        let defaults = UserDefaults.standard
        if defaults.double(forKey: "planKm") > 0 { model.distanceKm = defaults.double(forKey: "planKm") }
        if defaults.string(forKey: "planKind") == "one_way" { model.kind = .oneWay }
        if defaults.bool(forKey: "planFood") { model.endNearFood = true }
        if defaults.bool(forKey: "planBusy") { model.allowBusyRoads = true }
        if defaults.bool(forKey: "planAuto") {
            Task {
                await model.planRoutes()
                if case .planned = model.phase { showResults = true }
            }
        }
    }
    #endif

    private static var nextHour: Date {
        let calendar = Calendar.mumbai
        let hour = calendar.dateInterval(of: .hour, for: .now)?.start ?? .now
        return hour.addingTimeInterval(3600)
    }
}

/// Choose a place: current location, a saved place, a popular running spot, or
/// search Apple Maps.
struct PlacePicker: View {
    let title: String
    let location: LocationProvider
    let allowsCurrent: Bool
    let onPick: (Place) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedPlace.sortOrder) private var saved: [SavedPlace]
    @State private var search = PlaceSearch()
    @State private var lookingUp = false

    var body: some View {
        List {
            if search.query.isEmpty {
                if allowsCurrent {
                    Section { row(.current, icon: "location.fill") }
                }
                if !saved.isEmpty {
                    Section("Your places") {
                        ForEach(saved) { row($0.place, icon: "mappin") }
                    }
                }
                Section("Running spots") {
                    ForEach(Place.runningSpots) { row($0, icon: "figure.run") }
                }
            } else {
                Section {
                    ForEach(search.suggestions) { suggestion in
                        Button {
                            Task {
                                lookingUp = true
                                if let c = await search.coordinate(of: suggestion) {
                                    pick(Place(id: "search-\(c.latitude),\(c.longitude)", name: suggestion.title, coordinate: c))
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
                }
            }
        }
        .foregroundStyle(.primary)
        .searchable(text: $search.query, prompt: "Search Mumbai")
        .navigationTitle(title)
        .overlay { if lookingUp { ProgressView() } }
    }

    private func row(_ place: Place, icon: String) -> some View {
        Button { pick(place) } label: { Label(place.name, systemImage: icon) }
    }

    private func pick(_ place: Place) {
        onPick(place)
        dismiss()
    }
}
