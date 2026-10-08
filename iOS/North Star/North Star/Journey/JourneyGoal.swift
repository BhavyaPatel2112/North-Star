import Foundation

/// Your North Star: how far you will run in the 365 days from the day you set
/// it, and (optionally) what you are running towards. Stored on the phone only
/// (UserDefaults), never sent anywhere.
///
/// Views read these with @AppStorage using the same keys.
enum JourneyGoal {
    static let kmKey = "goalKm"              // 0 means "not set yet"
    static let startKey = "goalStart"        // seconds since 1970 when the goal was set
    static let whyKey = "goalWhy"            // the optional "what are you running towards?"

    static let range: ClosedRange<Double> = 50...5000
    static let days = 365.0

    /// Quick picks, with what each means in an ordinary week.
    static let presets: [(km: Double, meaning: String)] = [
        (250, "About 5 km a week, one easy run"),
        (500, "About 10 km a week, two 5 km runs"),
        (1000, "About 20 km a week"),
        (2000, "About 40 km a week, serious training"),
    ]

    static var isSet: Bool { UserDefaults.standard.double(forKey: kmKey) > 0 }

    /// Saves a goal. The journey starts today unless one is already running
    /// (changing the distance later keeps the original start date).
    static func save(km: Double, why: String) {
        let defaults = UserDefaults.standard
        defaults.set(min(range.upperBound, max(range.lowerBound, km)), forKey: kmKey)
        defaults.set(why.trimmingCharacters(in: .whitespacesAndNewlines), forKey: whyKey)
        if defaults.double(forKey: startKey) == 0 {
            defaults.set(Date.now.timeIntervalSince1970, forKey: startKey)
        }
    }

    /// About how many kilometres a week a yearly goal means.
    static func perWeek(_ km: Double) -> Double { km / (days / 7) }

    /// Days since the journey started (0 on the first day), and days left.
    static func daysSince(start: Double, now: Date = .now) -> Double {
        guard start > 0 else { return 0 }
        return max(0, now.timeIntervalSince1970 - start) / 86_400
    }

    /// Where you would be today if you ran evenly through the year.
    static func onSchedule(goal: Double, start: Double, now: Date = .now) -> Double {
        goal * min(1, daysSince(start: start, now: now) / days)
    }
}
