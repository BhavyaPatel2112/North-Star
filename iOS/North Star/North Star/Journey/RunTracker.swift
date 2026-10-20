import CoreLocation
import Foundation
import HealthKit

/// Reads your runs from Apple Health and moves you along the journey.
///
/// Only running workouts count (from any app or watch that saves them to
/// Apple Health: Apple Watch, Garmin, Strava, Nike Run Club...), and only those
/// since you set your North Star, each run once even if two apps saved it.
/// Their distances are added up into
/// "journeyKm", which the Journey tab shows. North Star writes to Apple Health only
/// when you record a run with "Start this route" (the run, its distance and route).
/// Nothing leaves the phone.
enum RunTracker {
    static let kmKey = "journeyKm"            // kilometres run since the goal was set
    static let runsKey = "journeyRuns"        // how many runs that is
    static let connectedKey = "healthConnected"
    /// Your usual running pace (seconds per km) from recent runs; 0 until known.
    static let usualPaceKey = "usualPaceSecPerKm"

    /// False on Mac and on iPads without Apple Health.
    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    static var isConnected: Bool { UserDefaults.standard.bool(forKey: connectedKey) }

    private static let store = HKHealthStore()
    private static let distance = HKQuantityType(.distanceWalkingRunning)
    private static let heartRate = HKQuantityType(.heartRate)

    /// Everything North Star reads: workouts, running distance, heart rate (for the runs
    /// journal) and the GPS route a watch or phone recorded.
    private static var readTypes: Set<HKObjectType> {
        [HKObjectType.workoutType(), distance, heartRate, HKSeriesType.workoutRoute()]
    }

    /// True when Apple has not yet asked about some of these (for example heart rate and
    /// routes, added after someone first connected), so the journal can offer to ask.
    static func needsMorePermission() async -> Bool {
        guard isAvailable else { return false }
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: readTypes)
        return status == .shouldRequest
    }

    /// Shows Apple's permission sheet, then reads the runs.
    /// iOS never tells an app whether reading was allowed, so if it was not, the total stays 0.
    static func connect() async {
        guard isAvailable else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            UserDefaults.standard.set(true, forKey: connectedKey)
            await refresh()
        } catch {
            #if DEBUG
            print("Apple Health permission failed:", error.localizedDescription)
            #endif
        }
    }

    /// Adds up every running workout since the goal was set (no-op until connected).
    static func refresh() async {
        guard isAvailable, isConnected else { return }
        let defaults = UserDefaults.standard
        let goalStart = defaults.double(forKey: JourneyGoal.startKey)
        let since = goalStart > 0 ? Date(timeIntervalSince1970: goalStart) : .distantPast

        let running = HKQuery.predicateForWorkouts(with: .running)
        let recent = HKQuery.predicateForSamples(withStart: since, end: nil)
        let query = HKSampleQueryDescriptor(
            predicates: [.workout(NSCompoundPredicate(andPredicateWithSubpredicates: [running, recent]))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)])
        guard let found = try? await query.result(for: store) else { return }
        let runs = uniqueRuns(found)

        let km = runs.reduce(0.0) { total, run in total + kilometres(of: run) }
        defaults.set(km, forKey: kmKey)
        defaults.set(runs.count, forKey: runsKey)
        await updateUsualPace()
    }

    /// One copy of each run. Apps that sync to Apple Health (Strava, Garmin, Nike Run Club)
    /// often save a second copy of a run your watch already saved, so the same run would
    /// show twice and count twice. Two runs are the same when they start within 3 minutes
    /// of each other and their durations differ by less than 10%; the copy with the most
    /// information is kept (heart rate, then a GPS route, then Apple's own recording).
    static func uniqueRuns(_ workouts: [HKWorkout]) -> [HKWorkout] {
        var kept: [HKWorkout] = []
        for workout in workouts.sorted(by: { $0.startDate < $1.startDate }) {
            if let index = kept.firstIndex(where: { isSameRun($0, workout) }) {
                if richness(of: workout) > richness(of: kept[index]) { kept[index] = workout }
            } else {
                kept.append(workout)
            }
        }
        return kept
    }

    private static func isSameRun(_ a: HKWorkout, _ b: HKWorkout) -> Bool {
        abs(a.startDate.timeIntervalSince(b.startDate)) < 180
            && abs(a.duration - b.duration) < max(a.duration, b.duration) * 0.1
    }

    /// How much a copy of a run tells us: heart rate counts most, then a route, then
    /// whether Apple recorded it (Apple Watch or iPhone) rather than a syncing app.
    private static func richness(of workout: HKWorkout) -> Int {
        var score = 0
        if workout.statistics(for: heartRate)?.averageQuantity() != nil { score += 4 }
        if workout.metadata?[HKMetadataKeyElevationAscended] != nil { score += 1 }
        if workout.sourceRevision.source.bundleIdentifier.hasPrefix("com.apple") { score += 2 }
        return score
    }

    /// A run's distance in kilometres (the workout's running distance, or its total).
    private static func kilometres(of run: HKWorkout) -> Double {
        let km = HKUnit.meterUnit(with: .kilo)
        if let sum = run.statistics(for: distance)?.sumQuantity() { return sum.doubleValue(for: km) }
        return run.totalDistance?.doubleValue(for: km) ?? 0
    }

    /// Your usual pace: the middle (median) pace of your last 10 runs of at least 1 km,
    /// so one very fast or very slow run does not throw it off. The planner uses it to
    /// say how long a run will take.
    static func updateUsualPace() async {
        let paces = await recentRuns()
            .filter { $0.km >= 1 }
            .prefix(10)
            .compactMap(\.paceSecondsPerKm)
            .filter { (150...900).contains($0) }   // 2:30 to 15:00 per km: ignore odd recordings
            .sorted()
        guard !paces.isEmpty else { return }
        UserDefaults.standard.set(paces[paces.count / 2], forKey: usualPaceKey)
    }

    // MARK: - Saving runs recorded in North Star

    /// What North Star saves: running workouts, their distance and their GPS route.
    private static var saveTypes: Set<HKSampleType> {
        [HKObjectType.workoutType(), distance, HKSeriesType.workoutRoute()]
    }

    /// Asks once for permission to save runs (shown when someone first starts a route).
    static func requestSavePermission() async {
        guard isAvailable else { return }
        try? await store.requestAuthorization(toShare: saveTypes, read: readTypes)
        UserDefaults.standard.set(true, forKey: connectedKey)
    }

    /// Saves a run recorded in North Star to Apple Health: a running workout with its
    /// distance and GPS route. Returns false if Apple Health refused (no permission).
    static func saveRun(start: Date, end: Date, metres: Double, track: [CLLocation]) async -> Bool {
        guard isAvailable else { return false }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .outdoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        do {
            try await builder.beginCollection(at: start)
            let sample = HKQuantitySample(type: distance, quantity: HKQuantity(unit: .meter(), doubleValue: metres),
                                          start: start, end: end)
            try await builder.addSamples([sample])
            try await builder.endCollection(at: end)
            guard let workout = try await builder.finishWorkout() else { return false }
            if track.count > 1 {
                let route = HKWorkoutRouteBuilder(healthStore: store, device: .local())
                try await route.insertRouteData(track)
                _ = try await route.finishRoute(with: workout, metadata: nil)
            }
            return true
        } catch {
            #if DEBUG
            print("Saving the run to Apple Health failed:", error.localizedDescription)
            #endif
            return false
        }
    }

    // MARK: - The runs journal

    /// One run from Apple Health, as the journal shows it.
    struct Run: Identifiable {
        let id: UUID
        let workout: HKWorkout
        let start: Date
        let seconds: TimeInterval
        let km: Double
        let averageHeartRate: Double?
        let maxHeartRate: Double?
        /// Metres climbed, when the recording app saved it.
        let climbM: Double?
        /// The app or watch that recorded it ("Workout", "Strava"...).
        let source: String

        /// Minutes per kilometre, when there is a distance.
        var paceSecondsPerKm: Double? { km > 0.05 ? seconds / km : nil }
    }

    /// Running workouts from the last 12 months, newest first.
    static func recentRuns() async -> [Run] {
        guard isAvailable, isConnected else { return [] }
        let since = Calendar.current.date(byAdding: .month, value: -12, to: .now) ?? .distantPast
        let query = HKSampleQueryDescriptor(
            predicates: [.workout(NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForWorkouts(with: .running), HKQuery.predicateForSamples(withStart: since, end: nil),
            ]))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)])
        guard let found = try? await query.result(for: store) else { return [] }
        let workouts = uniqueRuns(found).sorted { $0.startDate > $1.startDate }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        return workouts.map { workout in
            let heart = workout.statistics(for: heartRate)
            let climb = (workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter())
            return Run(id: workout.uuid, workout: workout, start: workout.startDate, seconds: workout.duration,
                       km: kilometres(of: workout),
                       averageHeartRate: heart?.averageQuantity()?.doubleValue(for: bpm),
                       maxHeartRate: heart?.maximumQuantity()?.doubleValue(for: bpm),
                       climbM: climb, source: workout.sourceRevision.source.name)
        }
    }

    /// The GPS track of a run, if the recording app saved one (empty otherwise).
    static func route(of run: Run) async -> [CLLocationCoordinate2D] {
        let routes = HKSampleQueryDescriptor(
            predicates: [.workoutRoute(HKQuery.predicateForObjects(from: run.workout))], sortDescriptors: [])
        guard let route = try? await routes.result(for: store).first else { return [] }
        var points: [CLLocationCoordinate2D] = []
        let locations = HKWorkoutRouteQueryDescriptor(route)
        do {
            for try await location in locations.results(for: store) { points.append(location.coordinate) }
        } catch {
            return points
        }
        return points
    }
}
