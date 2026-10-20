import MapKit
import SwiftUI

/// The screen while running a planned route: the map with the route and your track,
/// the next turn (or a warning), and the numbers (time, distance, pace, km left).
/// Pause, finish, mute the voice, and share your run with a friend.
struct LiveRunView: View {
    @State private var run: LiveRun
    @State private var camera: MapCameraPosition = .userLocation(followsHeading: false, fallback: .automatic)
    @State private var confirmingFinish = false
    @Environment(\.dismiss) private var dismiss

    init(shape: RouteShape) {
        _run = State(initialValue: LiveRun(shape: shape))
    }

    var body: some View {
        VStack(spacing: 0) {
            map
                .overlay(alignment: .top) { banner.padding(.top, 8).padding(.horizontal, 12) }
            panel
        }
        .background(Theme.mist)
        .task { if run.state == .ready { await run.start() } }
        // Keep the screen on while running, so the numbers are there at a glance.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .confirmationDialog("Finish this run?", isPresented: $confirmingFinish, titleVisibility: .visible) {
            Button("Finish and save") { Task { await run.finish() } }
            Button("Keep running", role: .cancel) {}
        } message: {
            Text("It will be saved to Apple Health and count towards your journey.")
        }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $camera) {
            // The planned route, coloured by air, and your track on top in gold.
            MapPolyline(coordinates: run.shape.option.line)
                .stroke(.black.opacity(0.3), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            ForEach(run.shape.stretches) { stretch in
                MapPolyline(coordinates: stretch.coordinates)
                    .stroke(stretch.band.color.opacity(0.8), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if run.track.count > 1 {
                MapPolyline(coordinates: run.track.map(\.coordinate))
                    .stroke(Theme.star, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let finish = run.shape.finish, !run.shape.option.isLoop {
                Annotation("Finish", coordinate: finish) {
                    Image(systemName: "flag.checkered").font(.caption.weight(.bold))
                        .padding(6).background(Circle().fill(.white))
                }
            }
            UserAnnotation()
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls { MapUserLocationButton() }
    }

    /// The next turn, or a warning (off route, dirtier air ahead), at the top of the map.
    @ViewBuilder
    private var banner: some View {
        if let warning = run.warning {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else if let instruction = run.instruction, run.state != .finished {
            Label(instruction, systemImage: "arrow.turn.up.right")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.ink.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - Numbers and controls

    @ViewBuilder
    private var panel: some View {
        if run.state == .finished { summary } else { live }
    }

    private var live: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(RunFormat.duration(run.elapsed(at: context.date)))
                        .font(.system(size: 48, weight: .light).monospacedDigit())
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.2f km", run.metres / 1000)).font(.title2.monospacedDigit())
                        Text(String(format: "%.1f km left", run.kmLeft)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    stat("Pace now", run.currentPace.map(RunFormat.pace) ?? "–")
                    Spacer()
                    stat("Average", run.averagePace(at: context.date).map(RunFormat.pace) ?? "–")
                    Spacer()
                    if run.state == .paused { Text("Paused").font(.headline).foregroundStyle(.orange) }
                }
                HStack(spacing: 12) {
                    Button { run.voiceOn.toggle() } label: {
                        Image(systemName: run.voiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .frame(width: 48, height: 48)
                            .background(Theme.ink.opacity(0.08), in: Circle())
                    }
                    .accessibilityLabel(run.voiceOn ? "Mute voice" : "Turn voice on")
                    ShareLink(item: ShareRun.message(for: run.shape.option, start: run.startedAt ?? .now)) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 48, height: 48)
                            .background(Theme.ink.opacity(0.08), in: Circle())
                    }
                    .accessibilityLabel("Share my run")
                    Button(run.state == .paused ? "Resume" : "Pause") {
                        run.state == .paused ? run.resume() : run.pause()
                    }
                    .buttonStyle(PillButtonStyle())
                    Button("Finish") { confirmingFinish = true }
                        .font(.headline)
                        .foregroundStyle(.red)
                        .frame(width: 80, height: 48)
                        .background(.red.opacity(0.1), in: Capsule())
                }
                .foregroundStyle(Theme.ink)
            }
            .padding(20)
        }
    }

    private var summary: some View {
        VStack(spacing: 12) {
            Text("Run finished").font(.title2.weight(.semibold))
            HStack {
                stat("Distance", String(format: "%.2f km", run.metres / 1000))
                Spacer()
                stat("Time", RunFormat.duration(run.elapsed()))
                Spacer()
                stat("Average", run.averagePace().map(RunFormat.pace) ?? "–")
            }
            switch run.savedToHealth {
            case true?: CardNote(text: "Saved to Apple Health. It counts towards your journey. Keep going.")
            case false?: CardNote(text: run.metres < 200 ? "Too short to save." : "Could not save to Apple Health. Check that North Star may save workouts in the Health app.")
            case nil: ProgressView("Saving to Apple Health…")
            }
            Button("Done") { dismiss() }
                .buttonStyle(PillButtonStyle())
        }
        .padding(20)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
    }
}
