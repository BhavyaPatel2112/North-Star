import SwiftUI

// Building blocks shared by the Journey-themed screens (planner, routes, journey):
// a landscape header, calm rounded cards on the misty background, chips, a dark
// capsule button and a two-option switch. Kept in one place so every screen matches.

extension Theme {
    /// Card surfaces on the mist: translucent white by day, faint white in dark mode.
    static let card = Color("Card")
    /// Text and filled buttons: deep slate in light mode, snow in dark mode.
    static let ink = Color("Ink")
}

/// The top of a themed screen: a strip of the journey landscape (at this hour)
/// with rounded bottom corners, and big light words over it, Ro-style.
struct JourneyHeader: View {
    let title: String
    var subtitle: String?
    var height: CGFloat = 250
    /// The air to show in the landscape (clean by default).
    var pm25: Double = 22
    var trailing: AnyView?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Landscape(palette: LandscapePalette(pm25: pm25, hourOfDay: SkyModel.hourOfDay(.now)), showsTraveller: false)
            LinearGradient(colors: [.clear, .black.opacity(0.32)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                if let subtitle { Text(subtitle).opacity(0.6) }
            }
            .font(.system(size: 36, weight: .regular))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.2), radius: 8, y: 1)
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
        .overlay(alignment: .topTrailing) {
            trailing.padding(.top, 60).padding(.trailing, 18)
        }
        .frame(height: height)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 32, bottomTrailingRadius: 32, style: .continuous))
    }
}

/// A calm rounded card with an optional small title.
struct JourneyCard<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Small explanatory text under a control.
struct CardNote: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// A capsule chip: filled with ink when selected, quiet otherwise.
struct Chip: View {
    let title: String
    var systemImage: String?
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.caption) }
                Text(title)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? Theme.mist : Theme.ink)
            .background(selected ? Theme.ink : Theme.ink.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The main action on a screen: a full-width dark capsule.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(Theme.mist)
            .background(Theme.ink, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// A two-option switch made of pills (for example Loop / One way).
struct PillSwitch<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { value, title in
                Button {
                    withAnimation(.snappy) { selection = value }
                } label: {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(selection == value ? Theme.mist : Theme.ink)
                        .background(selection == value ? Theme.ink : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.ink.opacity(0.06), in: Capsule())
    }
}

/// A round − or + button for steppers.
struct RoundIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline)
                .frame(width: 44, height: 44)
                .foregroundStyle(Theme.ink)
                .background(Theme.ink.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
    }
}
