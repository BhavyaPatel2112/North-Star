import Foundation

/// "Share my run": a message for a friend with the route, when you start and when
/// you expect to be back, so someone knows where you are (useful for early or late
/// runs). Sent through any app (WhatsApp, iMessage...); nothing goes through our server.
enum ShareRun {
    /// The usual pace used for the finish time (seconds per km): yours from Apple Health,
    /// or an easy 6:30 /km.
    static var pace: Double {
        let usual = UserDefaults.standard.double(forKey: RunTracker.usualPaceKey)
        return usual > 0 ? usual : 390
    }

    /// "I'm going for a 5 km run (loop) from Shivaji Park, starting 6:30 am and back
    /// around 7:05 am. My route: <link>. — sent from North Star"
    static func message(for option: RouteOption, start: Date, from startName: String? = nil) -> String {
        let finish = start.addingTimeInterval(option.distanceKm * pace)
        let distance = PlannerModel.format(km: option.distanceKm)
        let kind = option.park != nil ? option.label.lowercased()
            : option.isLoop ? "loop" : "one way"
        var text = "I'm going for a \(distance) run (\(kind))"
        if let startName, !startName.isEmpty { text += " from \(startName)" }
        let startText = abs(start.timeIntervalSinceNow) < 120 ? "starting now" : "starting \(SkyScreen.time(start))"
        let endWord = option.isLoop ? "back" : "finishing"
        text += ", \(startText) and \(endWord) around \(SkyScreen.time(finish))."
        if let place = option.finishPlace, !option.isLoop { text += " I'll end at \(place.name)." }
        if let link = option.googleMapsLink { text += "\nMy route: \(link.absoluteString)" }
        text += "\nSent from North Star"
        return text
    }
}
