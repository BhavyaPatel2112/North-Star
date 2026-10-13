import MapKit
import SwiftUI

/// "Your runs": every run in Apple Health from the last 12 months, newest first,
/// grouped by month. Each row shows the date, distance, time, pace and average heart
/// rate; tap one for its route and details. Everything is read on the phone from
/// Apple Health (any app or watch that saves runs there); nothing leaves the phone.
struct RunsJournalView: View {
    let onClose: () -> Void

    @AppStorage(JourneyGoal.startKey) private var goalStart: Double = 0
    @State private var runs: [RunTracker.Run] = []
    @State private var loaded = false
    @State private var needsPermission = false

    var body: some View {
        NavigationStack {
            List {
                if needsPermission {
                    Section {
                        Button {
                            Task {
                                await RunTracker.connect()
                                await load()
                            }
                        } label: {
                            Label("Allow heart rate and routes from Apple Health", systemImage: "heart.text.square")
                        }
                    } footer: {
                        Text("North Star only reads. Your health data stays on your phone.")
                    }
                }
                if loaded && runs.isEmpty {
                    ContentUnavailableView("No runs yet", systemImage: "figure.run",
                                           description: Text("Runs recorded by your Apple Watch, the Workout app, Strava or any app that saves to Apple Health will appear here."))
                }
                ForEach(months, id: \.self) { month in
                    Section(Self.monthTitle(month)) {
                        ForEach(runs(in: month)) { run in
                            NavigationLink { RunDetailView(run: run, counted: counts(run)) } label: { row(run) }
                        }
                    }
                }
            }
            .overlay { if !loaded { ProgressView() } }
            .scrollContentBackground(.hidden)
            .background(Theme.mist)
            .navigationTitle("Your runs")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        needsPermission = await RunTracker.needsMorePermission()
        runs = await RunTracker.recentRuns()
        loaded = true
    }

    /// One run: "Sat 12 Oct · 7:05 am", then "6.2 km · 34:10 · 5:30 /km · ♥ 152".
    private func row(_ run: RunTracker.Run) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(run.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.headline.weight(.medium))
                Text(run.start.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if !counts(run) {
                    Text("Before your North Star").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Text(RunFormat.km(run.km)).font(.subheadline.weight(.semibold))
                Text(RunFormat.duration(run.seconds))
                if let pace = run.paceSecondsPerKm { Text(RunFormat.pace(pace)) }
                if let heart = run.averageHeartRate { Label("\(Int(heart.rounded()))", systemImage: "heart.fill") }
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// True when the run counts towards your North Star (on or after the day you set it).
    private func counts(_ run: RunTracker.Run) -> Bool {
        goalStart <= 0 || run.start >= Date(timeIntervalSince1970: goalStart)
    }

    private var months: [Date] {
        Array(Set(runs.map { Self.monthStart($0.start) })).sorted(by: >)
    }

    private func runs(in month: Date) -> [RunTracker.Run] {
        runs.filter { Self.monthStart($0.start) == month }
    }

    private static func monthStart(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
    }

    private static func monthTitle(_ month: Date) -> String {
        month.formatted(.dateTime.month(.wide).year())
    }
}

/// One run in detail: its route on a map and the numbers.
struct RunDetailView: View {
    let run: RunTracker.Run
    /// Whether it counts towards your North Star.
    let counted: Bool

    @State private var route: [CLLocationCoordinate2D] = []
    @State private var lookedForRoute = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                map
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, 16)

                JourneyCard {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) {
                        stat("Distance", RunFormat.km(run.km))
                        stat("Time", RunFormat.duration(run.seconds))
                        if let pace = run.paceSecondsPerKm { stat("Average pace", RunFormat.pace(pace)) }
                        if let heart = run.averageHeartRate { stat("Average heart rate", "\(Int(heart.rounded())) bpm") }
                        if let heart = run.maxHeartRate { stat("Highest heart rate", "\(Int(heart.rounded())) bpm") }
                        if let climb = run.climbM { stat("Climb", "\(Int(climb.rounded())) m") }
                    }
                }
                .padding(.horizontal, 16)

                VStack(spacing: 4) {
                    CardNote(text: "Recorded by \(run.source), from Apple Health.")
                    CardNote(text: counted ? "Counts towards your North Star." : "From before you set your North Star, so it does not count towards it.")
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            .padding(.top, 8)
        }
        .background(Theme.mist)
        .navigationTitle(run.start.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            route = await RunTracker.route(of: run)
            lookedForRoute = true
        }
    }

    @ViewBuilder
    private var map: some View {
        if route.count > 1 {
            Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
                MapPolyline(coordinates: route)
                    .stroke(Theme.star, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                if let first = route.first { Annotation("Start", coordinate: first) { dot(.white) } }
                if let last = route.last { Annotation("Finish", coordinate: last) { dot(Theme.star) } }
            }
            .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(Theme.ink.opacity(0.06))
                if lookedForRoute {
                    VStack(spacing: 6) {
                        Image(systemName: "map").font(.title2)
                        Text("No route was saved for this run").font(.subheadline)
                        Text("Treadmill runs and some apps do not save GPS routes to Apple Health.")
                            .font(.caption).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .padding()
                } else {
                    ProgressView()
                }
            }
        }
    }

    private func dot(_ colour: Color) -> some View {
        Circle().fill(colour).frame(width: 14, height: 14).overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 2))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
    }
}

/// How run numbers are written: "6.2 km", "34:10" or "1:05:20", "5:30 /km".
enum RunFormat {
    static func km(_ km: Double) -> String { String(format: km < 10 ? "%.2f km" : "%.1f km", km) }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    static func pace(_ secondsPerKm: Double) -> String {
        let total = Int(secondsPerKm.rounded())
        return String(format: "%d:%02d /km", total / 60, total % 60)
    }
}
