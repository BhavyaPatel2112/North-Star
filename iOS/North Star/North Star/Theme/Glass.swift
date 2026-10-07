import SwiftUI

extension View {
    /// The translucent "glass" used for cards and buttons over the landscape.
    /// On iOS 26 and macOS 26 and later it is Apple's Liquid Glass; on older
    /// systems, a dark frosted material.
    @ViewBuilder
    func northGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.glassEffect(.regular.tint(.black.opacity(0.12)), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .environment(\.colorScheme, .dark)
        }
    }
}

/// Theme colours that are not part of the landscape.
enum Theme {
    /// The calm, misty area below the landscape.
    static let mist = Color("Mist")
    /// The warm gold of the North Star, used sparingly for highlights.
    static let star = Color(red: 0.98, green: 0.86, blue: 0.62)
}

/// A glass card over the landscape: an icon at the top, a label at the bottom
/// (as on Ro's home screen).
struct GlassCard: View {
    let title: String
    let systemImage: String
    var subtitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .regular))
                Spacer(minLength: 8)
                if let subtitle {
                    Text(subtitle).font(.footnote).opacity(0.75)
                }
                Text(title)
                    .font(.system(size: 19, weight: .regular))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 86)
            .padding(18)
            .contentShape(Rectangle())
            .northGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
