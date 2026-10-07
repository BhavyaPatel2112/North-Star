import SwiftUI

/// The app's root view: the tabs (Today, Plan, Journey), with the opening star
/// animation on top when the app starts.
struct ContentView: View {
    @State private var showIntro = !UserDefaults.standard.bool(forKey: "skipIntro")  // "-skipIntro YES" for tests

    var body: some View {
        ZStack {
            main
            if showIntro {
                LaunchStar { showIntro = false }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
    }

    @ViewBuilder
    private var main: some View {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "previewPM25") != nil {
            LandscapeDesignPreview(pm25: UserDefaults.standard.double(forKey: "previewPM25"),
                                   hourOfDay: UserDefaults.standard.double(forKey: "previewHour"))
        } else {
            RootTabs()
        }
        #else
        RootTabs()
        #endif
    }
}

/// The three tabs. Today: the air for your places. Plan: cleaner runs.
/// Journey: the long road to your North Star.
struct RootTabs: View {
    enum Section: Hashable { case today, plan, journey }

    @State private var section: Section = .today
    @State private var location = LocationProvider()
    /// The planner's start; changing the token starts a fresh plan from that place.
    @State private var plannerStart: Place = .current
    @State private var plannerToken = UUID()

    var body: some View {
        TabView(selection: $section) {
            Tab("Today", systemImage: "mountain.2", value: .today) {
                SkyPager(location: location, onPlanRun: plan(from:), onShowJourney: { section = .journey })
            }
            Tab("Plan", systemImage: "figure.run", value: .plan) {
                PlannerView(start: plannerStart, location: location, showsClose: false)
                    .id(plannerToken)
            }
            Tab("Journey", systemImage: "star", value: .journey) {
                JourneyView()
            }
        }
        .tint(.primary)
        #if DEBUG
        .onAppear {
            // "-tab plan" or "-tab journey" opens that tab (for screenshots).
            switch UserDefaults.standard.string(forKey: "tab") {
            case "plan": section = .plan
            case "journey": section = .journey
            default: break
            }
        }
        #endif
    }

    private func plan(from place: Place) {
        plannerStart = place
        plannerToken = UUID()
        section = .plan
    }
}

#if DEBUG
/// Test-only: the landscape at a chosen pollution level and hour, for comparing designs
/// (launch with -previewPM25 58 -previewHour 13).
private struct LandscapeDesignPreview: View {
    let pm25: Double
    let hourOfDay: Double

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Landscape(palette: LandscapePalette(pm25: pm25, hourOfDay: hourOfDay)).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 6) {
                Text("\(AirBand(pm25: pm25).skyWord).").font(.system(size: 42))
                Text("PM2.5 \(Int(pm25)) · \(String(format: "%02d:00", Int(hourOfDay)))")
                    .font(.title3.monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(26)
        }
    }
}
#endif

#Preview {
    ContentView()
}
