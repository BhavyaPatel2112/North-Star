import AVFoundation
import CoreLocation
import Foundation
import HealthKit
import Observation

/// One run being recorded on a planned route ("Start this route").
///
/// What it does while you run:
/// - follows your GPS position (also with the phone locked in a pocket, using
///   background location) and adds up the distance and time, minus pauses;
/// - works out where you are along the planned route (looking only a little ahead
///   of where you were, so loops and out-and-backs do not jump), the next turn, and
///   whether you have left the route or a dirtier stretch is coming;
/// - speaks short updates (each kilometre, turns, off route), which can be muted;
/// - at the end, saves the run to Apple Health as a running workout with its distance
///   and GPS route, so it counts towards your journey like any other run.
@Observable
final class LiveRun: NSObject, CLLocationManagerDelegate {
    enum State: Equatable { case ready, running, paused, finished }

    let shape: RouteShape
    private(set) var state: State = .ready
    /// Your GPS track while running (accurate fixes only).
    private(set) var track: [CLLocation] = []
    private(set) var metres: Double = 0
    private(set) var startedAt: Date?
    /// Where you are along the planned route (km) and how far from it (m).
    private(set) var routeKm: Double = 0
    private(set) var offRouteM: Double = 0
    /// The next instruction ("In 120 m, turn left onto Keluskar Road"), if any.
    private(set) var instruction: String?
    /// A warning to show above everything else (off route, dirtier air ahead).
    private(set) var warning: String?
    var voiceOn = true
    /// After finishing: whether the run was saved to Apple Health.
    private(set) var savedToHealth: Bool?

    private let manager = CLLocationManager()
    private let speech = AVSpeechSynthesizer()
    private var pausedSeconds: TimeInterval = 0
    private var pausedAt: Date?
    private var spokenKm = 0
    private var announcedStep = -1
    private var announcedSoonStep = -1
    private var warnedOffRoute = false
    private var warnedAirStep = -1

    static let offRouteLimitM = 50.0
    private static let healthStore = HKHealthStore()

    init(shape: RouteShape) {
        self.shape = shape
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
    }

    // MARK: - Time and pace

    /// Running time so far, without pauses.
    func elapsed(at now: Date = .now) -> TimeInterval {
        guard let startedAt else { return 0 }
        let end = state == .paused ? (pausedAt ?? now) : now
        return max(0, end.timeIntervalSince(startedAt) - pausedSeconds)
    }

    /// Average pace so far (seconds per km).
    func averagePace(at now: Date = .now) -> Double? {
        metres > 50 ? elapsed(at: now) / (metres / 1000) : nil
    }

    /// Pace over the last 30 seconds or so (seconds per km).
    var currentPace: Double? {
        guard let last = track.last,
              let earlier = track.last(where: { last.timestamp.timeIntervalSince($0.timestamp) >= 30 }) else { return nil }
        let distance = last.distance(from: earlier)
        let seconds = last.timestamp.timeIntervalSince(earlier.timestamp)
        return distance > 20 ? seconds / (distance / 1000) : nil
    }

    var kmLeft: Double { max(0, shape.option.distanceKm - routeKm) }

    // MARK: - Controls

    /// Asks for location (and Apple Health permission to save runs), then starts.
    func start() async {
        await RunTracker.requestSavePermission()
        manager.requestWhenInUseAuthorization()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt,
                                                         options: [.mixWithOthers, .duckOthers])
        startedAt = .now
        state = .running
        manager.startUpdatingLocation()
        say("Starting your \(PlannerModel.format(km: shape.option.distanceKm)) run. Keep going.")
    }

    func pause() {
        guard state == .running else { return }
        pausedAt = .now
        state = .paused
        say("Paused.")
    }

    func resume() {
        guard state == .paused, let pausedAt else { return }
        pausedSeconds += Date.now.timeIntervalSince(pausedAt)
        self.pausedAt = nil
        state = .running
        say("Resumed.")
    }

    /// Stops recording and saves the run to Apple Health (if it is long enough to count).
    func finish() async {
        if state == .paused, let pausedAt { pausedSeconds += Date.now.timeIntervalSince(pausedAt) }
        let end = Date.now
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        state = .finished
        say("Run finished. \(Self.spokenDistance(metres)) in \(Self.spokenTime(elapsed(at: end))).")
        if metres >= 200, let startedAt {
            savedToHealth = await RunTracker.saveRun(start: startedAt, end: end, metres: metres, track: track)
            await RunTracker.refresh()
        } else {
            savedToHealth = false
        }
    }

    // MARK: - Location updates

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations where location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 30 {
            guard state == .running else { continue }
            if let last = track.last {
                let step = location.distance(from: last)
                // Ignore GPS jitter while standing and impossible jumps.
                let seconds = max(location.timestamp.timeIntervalSince(last.timestamp), 0.5)
                if step < 2 || step / seconds > 12 { continue }
                metres += step
            }
            track.append(location)
            update(at: location.coordinate)
        }
    }

    /// Progress along the route, the next instruction, warnings and spoken updates.
    private func update(at position: CLLocationCoordinate2D) {
        let progress = shape.progress(of: position, lastKm: routeKm)
        offRouteM = progress.offRouteM
        if progress.offRouteM < Self.offRouteLimitM { routeKm = max(routeKm, progress.atKm) }

        // Off route.
        if progress.offRouteM > Self.offRouteLimitM {
            warning = "You're off the route (\(Int(progress.offRouteM)) m). Head back to the line on the map."
            if !warnedOffRoute { say("You're off the route."); warnedOffRoute = true }
        } else {
            warning = nil
            warnedOffRoute = false
        }

        // The next street, and the turn onto it.
        let steps = shape.option.steps
        if let next = steps.firstIndex(where: { $0.kmFrom > routeKm + 0.005 }) {
            let toTurn = (steps[next].kmFrom - routeKm) * 1000
            let turn = turnWord(atKm: steps[next].kmFrom)
            instruction = "In \(Self.roundedMetres(toTurn)), \(turn) onto \(steps[next].displayName)"
            if toTurn < 120 && announcedSoonStep != next {
                announcedSoonStep = next
                say("In \(Self.roundedMetres(toTurn)), \(turn) onto \(steps[next].displayName).")
            }
            // Dirtier air on the coming stretch (worse than now and at least Moderate).
            let current = steps[max(0, next - 1)]
            if steps[next].band > current.band && steps[next].band >= .moderate && toTurn < 200 {
                warning = warning ?? "Dirtier air ahead on \(steps[next].displayName) for \(Self.roundedMetres(steps[next].km * 1000)). Ease off a little."
                if warnedAirStep != next {
                    warnedAirStep = next
                    say("Dirtier air ahead for \(Self.roundedMetres(steps[next].km * 1000)). Ease off a little.")
                }
            }
        } else {
            instruction = shape.option.isLoop ? "Last stretch back to the start" : "Last stretch to the finish"
        }

        // Each kilometre run.
        let whole = Int(metres / 1000)
        if whole > spokenKm {
            spokenKm = whole
            var line = "\(whole) kilometre\(whole == 1 ? "" : "s"), \(Self.spokenTime(elapsed()))."
            if let pace = averagePace() { line += " Average pace \(Self.spokenPace(pace))." }
            say(line)
        }
    }

    /// "turn left", "turn right", "bear left", "continue" from the route's direction
    /// just before and just after a point.
    private func turnWord(atKm km: Double) -> String {
        guard let before = shape.bearing(atKm: max(0, km - 0.03)), let after = shape.bearing(atKm: km) else { return "continue" }
        let change = (after - before + 540).truncatingRemainder(dividingBy: 360) - 180   // -180...180, + is right
        switch change {
        case 45...: return "turn right"
        case 20..<45: return "bear right"
        case ...(-45): return "turn left"
        case -45..<(-20): return "bear left"
        default: return "continue"
        }
    }

    // MARK: - Speech

    private func say(_ text: String) {
        guard voiceOn else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-IN") ?? AVSpeechSynthesisVoice(language: "en-GB")
        speech.speak(utterance)
    }

    static func roundedMetres(_ metres: Double) -> String {
        metres >= 1000 ? String(format: "%.1f km", metres / 1000) : "\(max(10, Int((metres / 10).rounded()) * 10)) m"
    }

    private static func spokenDistance(_ metres: Double) -> String {
        String(format: "%.2f kilometres", metres / 1000)
    }

    private static func spokenTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if hours == 0 { parts.append("\(secs) second\(secs == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }

    private static func spokenPace(_ secondsPerKm: Double) -> String {
        let total = Int(secondsPerKm.rounded())
        return "\(total / 60) \(String(format: "%02d", total % 60)) per kilometre"
    }
}
