import SwiftUI

/// The tiny person who stands for the user on the journey: a small figure with a
/// backpack (carrying what they have) and a scarf blowing in the wind. When
/// walking, the legs and arms swing and the body bobs a little with each step.
struct TinyTraveller: View {
    var walking: Bool = false
    var colour: Color = .white
    var height: CGFloat = 40
    var facingRight = true

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                draw(in: &ctx, size: size, time: t)
            }
        }
        .frame(width: height * 0.9, height: height)
        .scaleEffect(x: facingRight ? 1 : -1, y: 1)
        .accessibilityLabel("The traveller")
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, time t: Double) {
        let h = size.height
        let cx = size.width * 0.5
        let step = walking ? sin(t * 7) : 0
        let bob = walking ? -abs(sin(t * 7)) * h * 0.03 : 0
        let line = StrokeStyle(lineWidth: h * 0.085, lineCap: .round, lineJoin: .round)
        let fill = GraphicsContext.Shading.color(colour)

        // Legs: from the hip, swinging opposite each other.
        let hip = CGPoint(x: cx, y: h * 0.58 + bob)
        for direction in [1.0, -1.0] {
            let angle = step * 0.45 * direction
            let foot = CGPoint(x: hip.x + sin(angle) * h * 0.38, y: hip.y + cos(angle) * h * 0.38)
            var leg = Path(); leg.move(to: hip); leg.addLine(to: foot)
            ctx.stroke(leg, with: fill, style: line)
        }

        // Backpack on the back (left side when facing right).
        let pack = CGRect(x: cx - h * 0.2, y: h * 0.28 + bob, width: h * 0.13, height: h * 0.22)
        ctx.fill(Path(roundedRect: pack, cornerRadius: h * 0.04), with: fill)

        // Body.
        var torso = Path()
        torso.move(to: CGPoint(x: cx, y: h * 0.26 + bob))
        torso.addLine(to: hip)
        ctx.stroke(torso, with: fill, style: StrokeStyle(lineWidth: h * 0.11, lineCap: .round))

        // Arms, swinging against the legs.
        let shoulder = CGPoint(x: cx, y: h * 0.31 + bob)
        for direction in [1.0, -1.0] {
            let angle = -step * 0.5 * direction + 0.08
            let hand = CGPoint(x: shoulder.x + sin(angle) * h * 0.26, y: shoulder.y + cos(angle) * h * 0.26)
            var arm = Path(); arm.move(to: shoulder); arm.addLine(to: hand)
            ctx.stroke(arm, with: fill, style: StrokeStyle(lineWidth: h * 0.065, lineCap: .round))
        }

        // Head.
        let r = h * 0.1
        ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: h * 0.04 + bob, width: r * 2, height: r * 2)), with: fill)

        // Scarf: from the neck, streaming back and fluttering in the wind.
        var scarf = Path()
        let neck = CGPoint(x: cx - h * 0.02, y: h * 0.24 + bob)
        scarf.move(to: neck)
        for i in 1...4 {
            let x = neck.x - Double(i) * h * 0.07
            let y = neck.y + Double(i) * h * 0.012 + sin(t * 9 + Double(i) * 1.3) * h * 0.025
            scarf.addLine(to: CGPoint(x: x, y: y))
        }
        ctx.stroke(scarf, with: .color(Theme.star.opacity(0.95)),
                   style: StrokeStyle(lineWidth: h * 0.05, lineCap: .round, lineJoin: .round))
    }
}

#Preview {
    HStack(spacing: 30) {
        TinyTraveller(walking: false)
        TinyTraveller(walking: true, height: 80)
    }
    .padding()
    .background(.black)
}
