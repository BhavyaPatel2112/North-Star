import SwiftUI

/// The app's root view: the skies of your places, one per page.
struct ContentView: View {
    var body: some View {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "previewPM25") != nil {
            SkyDesignPreview(pm25: UserDefaults.standard.double(forKey: "previewPM25"),
                             hourOfDay: UserDefaults.standard.double(forKey: "previewHour"))
        } else {
            SkyPager()
        }
        #else
        SkyPager()
        #endif
    }
}

#if DEBUG
/// Test-only: the sky at a chosen pollution level and hour, for comparing designs
/// (launch with -previewPM25 58 -previewHour 13).
private struct SkyDesignPreview: View {
    let pm25: Double
    let hourOfDay: Double

    var body: some View {
        ZStack(alignment: .leading) {
            SkyCanvas(pm25: pm25, hourOfDay: hourOfDay).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 10) {
                Text(AirBand(pm25: pm25).skyWord)
                    .font(.system(size: 96, weight: .heavy)).fontWidth(.condensed)
                Text("PM2.5 \(Int(pm25)) · \(String(format: "%02d:00", Int(hourOfDay)))")
                    .font(.title3.monospacedDigit())
            }
            .foregroundStyle(SkyPalette(pm25: pm25, hourOfDay: hourOfDay).ink)
            .padding(26)
        }
    }
}
#endif

#Preview {
    ContentView()
}
