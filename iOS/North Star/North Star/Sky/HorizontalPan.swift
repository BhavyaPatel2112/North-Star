import SwiftUI
import UIKit

/// A sideways-only drag for the Today screen (dragging through the hours).
///
/// Why not SwiftUI's DragGesture: on recent iOS versions, a DragGesture on content
/// inside a scroll view also captures vertical swipes, so the pages of places stopped
/// scrolling on real phones (the simulator did not show it). This uses UIKit's pan
/// gesture and only lets it start when the finger moves more sideways than up or down,
/// so vertical swipes go straight to the page scroll (changing place, pulling down
/// for your places).
struct HorizontalPan: UIGestureRecognizerRepresentable {
    /// One moment of the drag, in the given coordinate space.
    struct Value {
        let startLocation: CGPoint
        let location: CGPoint
        let translation: CGFloat
        /// Points per second, sideways.
        let velocity: CGFloat
    }

    let coordinateSpace: NamedCoordinateSpace
    let onChanged: (Value) -> Void
    let onEnded: (Value) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var startLocation: CGPoint = .zero

        /// Only start when the movement is mostly sideways.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }

        /// Let buttons and the page scroll keep working alongside it.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let converter = context.converter
        let location = converter.location(in: coordinateSpace)
        if recognizer.state == .began {
            context.coordinator.startLocation = location
        }
        let value = Value(startLocation: context.coordinator.startLocation, location: location,
                          translation: converter.translation(in: coordinateSpace)?.x ?? 0,
                          velocity: converter.velocity(in: coordinateSpace)?.x ?? 0)
        switch recognizer.state {
        case .began, .changed: onChanged(value)
        case .ended, .cancelled, .failed: onEnded(value)
        default: break
        }
    }
}
