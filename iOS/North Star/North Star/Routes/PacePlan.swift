import Foundation

/// A pacing plan for one route and a target time: how fast to run each kilometre so the
/// whole run takes exactly the target, with hills taken into account.
///
/// How it works:
/// 1. The route's elevation profile (a point every 25 m) gives the slope of each piece.
/// 2. Each piece gets an effort cost: running uphill costs about 3.3% more time per 1%
///    of slope; downhill gives back about 1.8% per 1%, but never more than 12% (steep
///    descents have to be run with care). This is the "grade-adjusted pace" idea that
///    running coaches and watches use.
/// 3. The target time is shared out in proportion to those costs, so a climb gets more
///    time (a slower pace) and a descent less, for an even effort all the way.
/// 4. "Negative split" also runs the first half about 3% slower and the second half
///    about 3% faster (still adding up to the target).
struct PacePlan {
    enum Strategy: Hashable {
        /// Same effort throughout: slower up hills, faster down them.
        case evenEffort
        /// Start a little easier and finish faster.
        case negativeSplit
    }

    /// One kilometre of the plan (the last one may be shorter).
    struct Split: Identifiable {
        let index: Int              // 1, 2, 3...
        let lengthKm: Double
        let seconds: Double
        let elapsedAtEnd: Double    // clock time when you finish this kilometre
        let climbM: Double
        let descentM: Double
        var id: Int { index }
        var paceSecondsPerKm: Double { seconds / max(lengthKm, 0.01) }

        /// Why this kilometre is faster or slower than average.
        var note: String {
            if climbM >= 8 && climbM > descentM * 1.5 { return "climbs \(Int(climbM.rounded())) m, ease off" }
            if descentM >= 8 && descentM > climbM * 1.5 { return "downhill, let it flow" }
            if climbM >= 8 { return "up and down" }
            return "flat"
        }
    }

    let distanceKm: Double
    let targetSeconds: Double
    let splits: [Split]
    /// Clock time at every elevation point along the route: (km, seconds).
    private let clock: [(km: Double, seconds: Double)]

    var averagePace: Double { targetSeconds / max(distanceKm, 0.01) }

    init(distanceKm: Double, profile: [(km: Double, metres: Double)], targetSeconds: Double, strategy: Strategy) {
        self.distanceKm = distanceKm
        self.targetSeconds = targetSeconds

        // The route as short pieces with their slope. Without elevation data, one flat piece.
        var points = profile.sorted { $0.km < $1.km }
        if points.count < 2 { points = [(0, 0), (distanceKm, 0)] }
        // Stretch the profile to the route's exact length (it is resampled on the server).
        let scale = distanceKm / max(points.last!.km, 0.01)

        var pieces: [(fromKm: Double, toKm: Double, rise: Double, weight: Double)] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let from = a.km * scale, to = b.km * scale
            let length = to - from
            guard length > 0 else { continue }
            let rise = b.metres - a.metres
            let gradePercent = rise / (length * 1000) * 100
            let effort = gradePercent >= 0 ? 1 + 0.033 * gradePercent : max(0.88, 1 + 0.018 * gradePercent)
            let half = strategy == .negativeSplit ? ((from + to) / 2 < distanceKm / 2 ? 1.03 : 0.97) : 1.0
            pieces.append((from, to, rise, length * effort * half))
        }

        // Share the target time out in proportion to each piece's weight.
        let totalWeight = pieces.reduce(0) { $0 + $1.weight }
        let secondsPerWeight = targetSeconds / max(totalWeight, 0.0001)

        var clock: [(km: Double, seconds: Double)] = [(0, 0)]
        var splits: [Split] = []
        var elapsed = 0.0
        var kmStart = 0.0, kmSeconds = 0.0, kmClimb = 0.0, kmDescent = 0.0
        for piece in pieces {
            let seconds = piece.weight * secondsPerWeight
            elapsed += seconds
            clock.append((piece.toKm, elapsed))
            kmSeconds += seconds
            if piece.rise > 0 { kmClimb += piece.rise } else { kmDescent -= piece.rise }
            // Close a kilometre when this piece reaches the next whole km (or the finish).
            let isLast = piece.toKm >= distanceKm - 0.0001
            if piece.toKm >= floor(kmStart) + 1 - 0.0001 || isLast {
                splits.append(Split(index: splits.count + 1, lengthKm: piece.toKm - kmStart, seconds: kmSeconds,
                                    elapsedAtEnd: elapsed, climbM: kmClimb, descentM: kmDescent))
                kmStart = piece.toKm; kmSeconds = 0; kmClimb = 0; kmDescent = 0
            }
        }
        self.splits = splits
        self.clock = clock
    }

    /// The clock time you should see at a distance along the route.
    func elapsed(atKm km: Double) -> Double {
        guard let next = clock.firstIndex(where: { $0.km >= km }), next > 0 else { return 0 }
        let a = clock[next - 1], b = clock[next]
        let t = b.km > a.km ? (km - a.km) / (b.km - a.km) : 0
        return a.seconds + (b.seconds - a.seconds) * t
    }

    /// Reads a typed time: "25" (minutes), "25:30", or "1:52:00". Nil if it cannot.
    static func seconds(from text: String) -> Double? {
        let parts = text.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.compactMap { $0 }
        switch values.count {
        case 1: return values[0] * 60
        case 2: return values[0] * 60 + values[1]
        case 3: return values[0] * 3600 + values[1] * 60 + values[2]
        default: return nil
        }
    }
}
