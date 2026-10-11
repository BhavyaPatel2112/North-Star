import Foundation
import HealthKit

/// Reads your runs from Apple Health and moves you along the journey.
///
/// Only running workouts count (from any app or watch that saves them to
/// Apple Health: Apple Watch, Garmin, Strava, Nike Run Club...), and only those
/// since you set your North Star. Their distances are added up into
/// "journeyKm", which the Journey tab shows. North Star only reads: it never
/// writes to Apple Health, and nothing leaves the phone.
enum RunTracker {
    static let kmKey = "journeyKm"            // kilometres run since the goal was set
    static let runsKey = "journeyRuns"        // how many runs that is
    static let connectedKey = "healthConnected"

    /// False on Mac and on iPads without Apple Health.
    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    static var isConnected: Bool { UserDefaults.standard.bool(forKey: connectedKey) }

    private static let store = HKHealthStore()
    private static let distance = HKQuantityType(.distanceWalkingRunning)

    /// Shows Apple's permission sheet (read workouts and running distance), then reads the runs.
    /// iOS never tells an app whether reading was allowed, so if it was not, the total stays 0.
    static func connect() async {
        guard isAvailable else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: [HKObjectType.workoutType(), distance])
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
        guard let runs = try? await query.result(for: store) else { return }

        let km = runs.reduce(0.0) { total, run in total + kilometres(of: run) }
        defaults.set(km, forKey: kmKey)
        defaults.set(runs.count, forKey: runsKey)
    }

    /// A run's distance in kilometres (the workout's running distance, or its total).
    private static func kilometres(of run: HKWorkout) -> Double {
        let km = HKUnit.meterUnit(with: .kilo)
        if let sum = run.statistics(for: distance)?.sumQuantity() { return sum.doubleValue(for: km) }
        return run.totalDistance?.doubleValue(for: km) ?? 0
    }
}
