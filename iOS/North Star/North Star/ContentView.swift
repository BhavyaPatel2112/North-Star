import SwiftUI

/// The app's root view: the tabs (Today, Plan, Journey), with the opening star
/// on top when the app starts, and the story if the user asks "Why the North Star?".
struct ContentView: View {
    enum Intro { case star, story, none }

    @State private var intro: Intro = {
        #if DEBUG
        // "-skipIntro YES" goes straight to the app; "-story 3" opens the story at scene 4.
        if UserDefaults.standard.object(forKey: "story") != nil { return .story }
        #endif
        return UserDefaults.standard.bool(forKey: "skipIntro") ? .none : .star
    }()

    var body: some View {
        ZStack {
            main
            switch intro {
            case .star:
                LaunchStar(onEnter: { leave(to: .none) }, onStory: { leave(to: .story) })
                    .transition(.opacity)
                    .zIndex(1)
            case .story:
                StoryView(startAt: UserDefaults.standard.integer(forKey: "story")) { leave(to: .none) }
                    .transition(.opacity)
                    .zIndex(2)
            case .none:
                EmptyView()
            }
        }
    }

    private func leave(to next: Intro) {
        withAnimation(.easeInOut(duration: 0.8)) { intro = next }
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
