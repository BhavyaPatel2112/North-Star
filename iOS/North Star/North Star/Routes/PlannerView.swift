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
    /// The distance as typed, kept as text while the user edits it.
    @State private var distanceText = "5"
    @FocusState private var editingDistance: Bool
    /// Your usual pace from Apple Health (seconds per km), 0 until known.
    @AppStorage(RunTracker.usualPaceKey) private var usualPace: Double = 0

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
            ScrollView {
                VStack(spacing: 14) {
                    JourneyHeader(title: "Plan a run.", subtitle: "Today's stretch.", trailing: closeButton)
                        .padding(.bottom, 4)

                    startCard
                    distanceCard
                    runCard
                    lapsCard
                    roadsCard
                    timeCard

                    Button {
                        Task {
                            await model.planRoutes()
                            if case .planned = model.phase { showResults = true }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if model.isPlanning { ProgressView().tint(Theme.mist) }
                            Text(model.isPlanning ? "Finding routes…" : "Find clean routes")
                        }
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(model.isPlanning)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                    status
                        .padding(.horizontal, 28)
                        .padding(.bottom, 24)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .background(Theme.mist)
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
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

    /// Close button in the header, only when the planner is shown as a sheet.
    private var closeButton: AnyView? {
        guard showsClose else { return nil }
        return AnyView(Button { dismiss() } label: {
            Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                .frame(width: 40, height: 40).northGlass(in: Circle())
        }.buttonStyle(.plain))
    }

    // MARK: - Cards

    private var startCard: some View {
        JourneyCard(title: "Starting point") {
            NavigationLink {
                PlacePicker(title: "Start", location: location, allowsCurrent: true) { model.start = $0 }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: model.start == .current ? "location.fill" : "mappin.and.ellipse")
                        .font(.headline)
                        .frame(width: 36, height: 36)
                        .background(Theme.ink.opacity(0.07), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.start.name).font(.headline.weight(.medium))
                        if let address = model.startAddress {
                            Text(address).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .foregroundStyle(Theme.ink)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            startMap
            locationStatus
            popularStarts
        }
        .padding(.horizontal, 16)
    }

    /// Type any distance (1 to 30 km), or tap a common one.
    private var distanceCard: some View {
        JourneyCard(title: "Distance") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The field is exactly as wide as the number in it (an invisible copy of the
                // text sets the width), so "km" sits right after it with no gap.
                Text(distanceText.isEmpty ? "0" : distanceText)
                    .font(.system(size: 46, weight: .light).monospacedDigit())
                    .hidden()
                    .overlay(alignment: .leading) {
                        TextField("5", text: $distanceText)
                            .font(.system(size: 46, weight: .light).monospacedDigit())
                            .focused($editingDistance)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .onSubmit(applyTypedDistance)
                            .accessibilityLabel("Distance in kilometres")
                    }
                Text("km").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                Spacer()
                if editingDistance {
                    Button("Done") { editingDistance = false }
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { editingDistance = true }
            timeEstimate
            if !editingDistance {
                Label("Tap the number to type any distance", systemImage: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(PlannerModel.quickDistances, id: \.self) { km in
                    Chip(title: PlannerModel.format(km: km), selected: model.distanceKm == km) {
                        editingDistance = false
                        withAnimation(.snappy) { model.distanceKm = km }
                    }
                }
            }
            if let note = model.note { CardNote(text: note) }
        }
        .padding(.horizontal, 16)
        // Keep the text and the model in step both ways.
        .onChange(of: editingDistance) { if !editingDistance { applyTypedDistance() } }
        .onChange(of: model.distanceKm, initial: true) {
            if !editingDistance { distanceText = Self.text(km: model.distanceKm) }
        }
    }

    /// "about 18 min", and the pace it assumes: yours from Apple Health, or an easy default.
    private var timeEstimate: some View {
        let pace = usualPace > 0 ? usualPace : 390   // 6:30 per km until we know yours
        let minutes = Int((model.distanceKm * pace / 60).rounded())
        let time = minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min"
        // Sits right under the number, aligned with it, so the two read as one.
        return HStack(spacing: 6) {
            Image(systemName: "clock").foregroundStyle(.secondary)
            Text("about \(time)").fontWeight(.semibold)
                .contentTransition(.numericText(value: model.distanceKm))
            Text("· " + (usualPace > 0 ? "at your usual \(RunFormat.pace(pace))" : "at an easy \(RunFormat.pace(pace))"))
                .foregroundStyle(.secondary)
        }
        .font(.subheadline.monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
    }

    /// Reads the typed distance ("7", "12.5" or "12,5"), keeps it between 1 and 30 km,
    /// rounds it to 0.1 km and shows the result.
    private func applyTypedDistance() {
        let typed = Double(distanceText.replacingOccurrences(of: ",", with: ".")) ?? model.distanceKm
        let range = PlannerModel.distanceRange
        model.distanceKm = (min(range.upperBound, max(range.lowerBound, typed)) * 10).rounded() / 10
        distanceText = Self.text(km: model.distanceKm)
    }

    /// "5" or "21.1" (no unit; the unit is shown beside the field).
    private static func text(km: Double) -> String {
        km == km.rounded() ? "\(Int(km))" : String(format: "%.1f", km)
    }

    private var runCard: some View {
        JourneyCard(title: "Run") {
            PillSwitch(selection: $model.kind, options: [(.loop, "Loop"), (.oneWay, "One way")])
            CardNote(text: model.kind == .loop
                     ? "Start and finish at the same place. If no good loop exists, you get an out-and-back."
                     : "End somewhere else. Leave the finish empty and North Star picks a clean place to end.")
            if model.kind == .oneWay { oneWayOptions }
        }
        .padding(.horizontal, 16)
    }

    /// Laps of a nearby park: none, about half the run, as much as fits, or a chosen
    /// number. Shown only when a park with a runnable loop is close enough for the distance.
    @ViewBuilder
    private var lapsCard: some View {
        if let options = model.lapOptions, model.finish == nil, model.finishNear == .anywhere {
            JourneyCard(title: "Park laps") {
                let where_ = options.park.distanceKm < 0.15 ? "right here"
                    : String(format: "%.1f km away", options.park.distanceKm)
                Text("\(options.park.name) · \(String(format: "%.2f", options.park.loopKm)) km loop · \(where_)")
                    .font(.subheadline.weight(.medium))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Chip(title: "No laps", selected: model.laps == .none) { model.laps = .none }
                        Chip(title: "Half · \(Self.lapText(options.half))", selected: model.laps == .half) { model.laps = .half }
                        Chip(title: "All · \(Self.lapText(options.all))", selected: model.laps == .all) { model.laps = .all }
                        Chip(title: "Custom", selected: model.laps == .custom) { model.laps = .custom }
                    }
                    .padding(.vertical, 2)
                }
                if model.laps == .custom {
                    HStack {
                        Text("Laps").font(.subheadline.weight(.medium))
                        Spacer()
                        ForEach([1, 2, 3, 4, 5, 6], id: \.self) { count in
                            Chip(title: "\(count)", selected: model.customLaps == count) { model.customLaps = count }
                        }
                    }
                }
                CardNote(text: model.laps == .none && model.kind == .oneWay
                         ? "Tip: laps of \(options.park.name) are quieter and cleaner than the roads. Try Half."
                         : "Quieter and cleaner than the roads, no traffic crossings, and easy to stop at any time. Laps never go beyond what fits your distance.")
            }
            .padding(.horizontal, 16)
            .animation(.snappy, value: model.laps)
        }
    }

    /// "2 laps", "0.8 lap".
    private static func lapText(_ laps: Double) -> String {
        let rounded = (laps * 2).rounded() / 2   // to the half lap
        let shown = rounded >= 1 ? (rounded == rounded.rounded() ? "\(Int(rounded))" : String(format: "%.1f", rounded))
                                 : String(format: "%.1f", laps)
        return "\(shown) lap\(laps >= 1.25 ? "s" : "")"
    }

    private var roadsCard: some View {
        JourneyCard {
            Toggle("OK with highways and busy roads", isOn: $model.allowBusyRoads)
                .font(.body.weight(.medium))
                .tint(Theme.ink)
            CardNote(text: model.allowBusyRoads
                     ? "Routes may cross highways and follow main roads with heavy traffic."
                     : "Routes never cross a highway (at a signal, under a flyover or over a bridge) and stay off roads that are mostly main road.")
        }
        .padding(.horizontal, 16)
    }

    private var timeCard: some View {
        JourneyCard {
            Toggle("Start now", isOn: Binding(
                get: { model.startTime == nil },
                set: { model.startTime = $0 ? nil : Self.nextHour }))
                .font(.body.weight(.medium))
                .tint(Theme.ink)
            if let time = model.startTime {
                DatePicker("Starting at", selection: Binding(get: { time }, set: { model.startTime = $0 }),
                           in: Date.now...Date.now.addingTimeInterval(30 * 3600),
                           displayedComponents: [.date, .hourAndMinute])
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Pieces

    /// A small map of the start. Tapping it pins the start to that exact point.
    private var startMap: some View {
        MapReader { proxy in
            Map(position: $startCamera, interactionModes: [.pan, .zoom]) {
                if let c = model.startCoordinate {
                    Marker("Start", systemImage: "figure.walk", coordinate: c).tint(Theme.ink)
                }
            }
            .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
            .onTapGesture { point in
                if let c = proxy.convert(point, from: .local) { model.pinStart(at: c) }
            }
        }
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            Text("Tap the map to set the exact start")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
                .padding(8)
        }
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
                    Chip(title: "Current location", systemImage: "location.fill") { model.start = .current; model.refreshLocation() }
                }
                ForEach(Place.runningSpots) { spot in
                    Chip(title: spot.name, selected: model.start == spot) { model.start = spot }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var oneWayOptions: some View {
        Divider()
        NavigationLink {
            PlacePicker(title: "Finish", location: location, allowsCurrent: false) { model.finish = $0 }
        } label: {
            HStack {
                Text("Finish").font(.body.weight(.medium))
                Spacer()
                Text(model.finish?.name ?? "North Star chooses").foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(Theme.ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if model.finish != nil {
            Button("Let North Star choose the finish") { model.finish = nil }
                .font(.subheadline.weight(.medium))
        } else {
            Text("End near").font(.body.weight(.medium))
            HStack(spacing: 8) {
                ForEach(Self.finishChoices, id: \.choice) { item in
                    Chip(title: item.title, systemImage: item.symbol, selected: model.finishNear == item.choice) {
                        withAnimation(.snappy) { model.finishNear = item.choice }
                    }
                }
            }
            CardNote(text: Self.finishNote(model.finishNear))
        }
    }

    private static let finishChoices: [(choice: PlannerModel.FinishNear, title: String, symbol: String?)] = [
        (.anywhere, "Anywhere", nil), (.food, "Food", "fork.knife"), (.station, "Station", "tram.fill"),
    ]

    private static func finishNote(_ choice: PlannerModel.FinishNear) -> String {
        switch choice {
        case .anywhere: "North Star picks a clean place to end."
        case .food: "Finish at a popular, well-rated restaurant or cafe."
        case .station: "Finish at a local train or metro station and ride home."
        }
    }

    private var status: some View {
        statusText
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var statusText: some View {
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
        if defaults.bool(forKey: "planFood") { model.finishNear = .food }
        if defaults.bool(forKey: "planStation") { model.finishNear = .station }
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
        .scrollContentBackground(.hidden)
        .background(Theme.mist)
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
