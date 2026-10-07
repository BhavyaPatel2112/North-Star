import SwiftUI

/// "Why the North Star?": a short interactive story (about a minute) that tells
/// the idea behind the app, with a tiny traveller standing in for the user.
///
/// Seven scenes, each laid out like the Today screen (the picture on top with
/// rounded corners, the words below). Each scene asks for one small action that
/// also teaches the app: turning the sky, tapping the star, holding to walk,
/// dragging through the hours, choosing the cleaner path. "Continue" appears once
/// the action is done (or after 10 seconds, so nobody gets stuck).
struct StoryView: View {
    let onFinish: () -> Void

    @State private var scene: Int
    @State private var ready = false

    static let sceneCount = 7

    init(startAt scene: Int = 0, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _scene = State(initialValue: min(max(0, scene), Self.sceneCount - 1))
    }

    var body: some View {
        ZStack {
            StoryColours.night.ignoresSafeArea()

            Group {
                switch scene {
                case 0: StillStarScene(ready: $ready)
                case 1: YourStarScene(ready: $ready)
                case 2: LongRoadScene(ready: $ready)
                case 3: ThickAirScene(ready: $ready)
                case 4: ChoosePathScene(ready: $ready)
                case 5: ClimbScene(ready: $ready)
                default: SummitScene(ready: $ready)
                }
            }
            .id(scene)
            .transition(.opacity)

            controls
        }
        .sensoryFeedback(.success, trigger: ready) { _, new in new }
        .task(id: scene) {
            // Fallback: if the action has not been done after 10 seconds, show Continue anyway.
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { withAnimation { ready = true } }
        }
        #if os(iOS)
        .statusBarHidden()
        #endif
    }

    private var controls: some View {
        VStack {
            HStack {
                if scene > 0 {
                    Button { go(to: scene - 1) } label: {
                        Image(systemName: "chevron.left").font(.headline)
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .northGlass(in: Circle())
                    .accessibilityLabel("Back")
                } else {
                    Color.clear.frame(width: 38, height: 38)
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<Self.sceneCount, id: \.self) { i in
                        Capsule()
                            .fill(.white.opacity(i == scene ? 0.95 : 0.35))
                            .frame(width: i == scene ? 18 : 6, height: 6)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Part \(scene + 1) of \(Self.sceneCount)")
                Spacer()
                Button("Skip", action: onFinish)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .northGlass(in: Capsule())
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)

            Spacer()

            Button {
                if scene == Self.sceneCount - 1 { onFinish() } else { go(to: scene + 1) }
            } label: {
                Text(scene == Self.sceneCount - 1 ? "Begin your journey" : "Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(.black)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
            .opacity(ready ? 1 : 0)
            .offset(y: ready ? 0 : 10)
            .allowsHitTesting(ready)
            .animation(.easeOut(duration: 0.4), value: ready)
        }
    }

    private func go(to next: Int) {
        ready = false
        withAnimation(.easeInOut(duration: 0.6)) { scene = next }
    }
}

enum StoryColours {
    /// The deep night behind every scene.
    static let night = Color(red: 0.025, green: 0.035, blue: 0.075)
}

/// Every scene's layout: the picture on top (62% of the height, rounded at the
/// bottom like the Today screen), and the words below.
struct StoryStage<Picture: View, Words: View>: View {
    @ViewBuilder let picture: (CGSize) -> Picture
    @ViewBuilder let words: Words

    var body: some View {
        GeometryReader { geometry in
            let stage = CGSize(width: geometry.size.width,
                               height: (geometry.size.height + geometry.safeAreaInsets.top) * 0.62)
            VStack(spacing: 0) {
                picture(stage)
                    .frame(width: stage.width, height: stage.height)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 34, bottomTrailingRadius: 34, style: .continuous))
                words
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                Spacer(minLength: 0)
            }
            .ignoresSafeArea(edges: .top)
        }
    }
}

/// The words of a scene: one larger line, a fainter second line, and an instruction.
struct StoryCaption: View {
    let first: String
    let second: String
    var hint: String?

    var body: some View {
        VStack(spacing: 8) {
            Text(first)
                .font(.system(size: 28, weight: .regular))
            Text(second)
                .font(.system(size: 19, weight: .light))
                .opacity(0.72)
            if let hint {
                Text(hint.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1)
                    .opacity(0.5)
                    .padding(.top, 8)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.white)
        .contentTransition(.opacity)
        .animation(.easeInOut(duration: 0.5), value: first + second)
    }
}

#Preview {
    StoryView(onFinish: {})
}
