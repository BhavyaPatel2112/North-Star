import SwiftUI

/// "Your North Star": choose how far you will run in the next 365 days, and
/// (optionally) what you are running towards. Required the first time; after
/// that, opened from the Journey tab to change it.
struct GoalSetupView: View {
    /// True when changing an existing goal (shows Cancel; keeps the start date).
    var isEditing = false
    let onDone: () -> Void

    @State private var km: Double
    @State private var why: String
    @FocusState private var typing: Bool

    init(isEditing: Bool = false, onDone: @escaping () -> Void) {
        self.isEditing = isEditing
        self.onDone = onDone
        let saved = UserDefaults.standard.double(forKey: JourneyGoal.kmKey)
        _km = State(initialValue: saved > 0 ? saved : 500)
        _why = State(initialValue: UserDefaults.standard.string(forKey: JourneyGoal.whyKey) ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                JourneyHeader(title: "Your North Star.", subtitle: "How far will you go?", height: 260, pm25: 10,
                              trailing: isEditing ? AnyView(cancelButton) : nil)
                    .padding(.bottom, 4)

                JourneyCard(title: "The next 365 days") {
                    Text("How many kilometres will you run?")
                        .font(.title3)
                    HStack(alignment: .center) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Int(km).formatted())
                                .font(.system(size: 56, weight: .light).monospacedDigit())
                                .contentTransition(.numericText(value: km))
                            Text("km").font(.title3).foregroundStyle(.secondary)
                        }
                        Spacer()
                        RoundIconButton(systemImage: "minus") { step(-1) }
                        RoundIconButton(systemImage: "plus") { step(1) }
                    }
                    Slider(value: $km, in: JourneyGoal.range, step: 10)
                        .tint(Theme.ink)
                        .accessibilityLabel("Kilometres in the next year")
                    CardNote(text: weekLine)
                }
                .padding(.horizontal, 16)

                JourneyCard(title: "Or pick one") {
                    ForEach(JourneyGoal.presets, id: \.km) { preset in
                        Button {
                            withAnimation(.snappy) { km = preset.km }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(Int(preset.km)) km").font(.headline.weight(.medium))
                                    Text(preset.meaning).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: km == preset.km ? "largecircle.fill.circle" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(km == preset.km ? Theme.ink : .secondary)
                            }
                            .foregroundStyle(Theme.ink)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)

                JourneyCard(title: "What are you running towards?") {
                    TextField("For example, my first half marathon", text: $why)
                        .font(.title3)
                        .focused($typing)
                        .submitLabel(.done)
                        .onChange(of: why) { _, new in if new.count > 60 { why = String(new.prefix(60)) } }
                    CardNote(text: "Optional. It shows at the summit of your journey.")
                }
                .padding(.horizontal, 16)

                Button(isEditing ? "Save my North Star" : "Set my North Star") {
                    JourneyGoal.save(km: km, why: why)
                    onDone()
                }
                .buttonStyle(PillButtonStyle())
                .padding(.horizontal, 16)
                .padding(.top, 4)

                CardNote(text: isEditing
                         ? "Your journey keeps its start date. The stages move to fit the new distance."
                         : "Your journey starts today. Only runs count.")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
            }
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .ignoresSafeArea(edges: .top)
        .background(Theme.mist)
    }

    private var cancelButton: some View {
        Button { onDone() } label: {
            Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                .frame(width: 40, height: 40).northGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel")
    }

    /// "About 10 km a week · two 5 km runs" style help for the chosen distance.
    private var weekLine: String {
        let weekly = JourneyGoal.perWeek(km)
        let runs = weekly <= 6 ? "one run" : weekly <= 12 ? "two runs" : weekly <= 25 ? "three or four runs" : "most days"
        return "About \(Int(weekly.rounded())) km a week, \(runs)."
    }

    /// Bigger steps for bigger goals: 25 km up to 500, 50 up to 2,000, then 100.
    private func step(_ direction: Double) {
        let size: Double = km < 500 ? 25 : km < 2000 ? 50 : 100
        withAnimation(.snappy) {
            km = min(JourneyGoal.range.upperBound, max(JourneyGoal.range.lowerBound, (km / size).rounded() * size + direction * size))
        }
    }
}

#Preview {
    GoalSetupView(onDone: {})
}
