import AppKit
import SwiftUI

/// A transparent layer over the chart that turns a drag or a sideways swipe into whole days.
///
/// AppKit rather than a SwiftUI `DragGesture`, because the gesture people reach for on a Mac is a
/// two-finger swipe, and SwiftUI on macOS 13 has no way to read a horizontal scroll. Handling both
/// in one view also keeps one idea of how many points a day is.
///
/// **Content follows the pointer**: dragging or swiping right reveals what's to the left, which is
/// the past. Vertical scrolling is passed on untouched, so the panel still scrolls over the chart.
struct ChartPanSurface: NSViewRepresentable {
    /// Days drawn across the chart's width, which fixes how far one day is.
    let pointCount: Int
    /// Called with a whole number of days to move — negative is back in time.
    let onPan: (Int) -> Void

    func makeNSView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.pointCount = pointCount
        view.onPan = onPan
        return view
    }

    func updateNSView(_ view: SurfaceView, context: Context) {
        view.pointCount = pointCount
        view.onPan = onPan
    }

    final class SurfaceView: NSView {
        var pointCount = 2
        var onPan: ((Int) -> Void)?

        /// Travel not yet converted into a whole day, so slow movement still adds up.
        private var carried: CGFloat = 0
        private var lastDragX: CGFloat?

        /// Width of one day, in points.
        private var step: CGFloat {
            bounds.width / CGFloat(max(pointCount - 1, 1))
        }

        // The panel is non-activating; the first click must act, not just focus.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        // MARK: Drag

        override func mouseDown(with event: NSEvent) {
            lastDragX = convert(event.locationInWindow, from: nil).x
            carried = 0
            NSCursor.closedHand.push()
        }

        override func mouseDragged(with event: NSEvent) {
            let x = convert(event.locationInWindow, from: nil).x
            guard let last = lastDragX else { return }
            lastDragX = x
            travel(x - last)
        }

        override func mouseUp(with event: NSEvent) {
            lastDragX = nil
            carried = 0
            NSCursor.pop()
        }

        // MARK: Swipe

        override func scrollWheel(with event: NSEvent) {
            // Mostly vertical is the panel scrolling, not a request to move through time.
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
                super.scrollWheel(with: event)
                return
            }
            // A trackpad reports points; a mouse wheel tilted sideways reports lines, and one line
            // reads best as one day.
            let delta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaX
                : event.scrollingDeltaX * step
            travel(delta)
            if event.phase == .ended || event.momentumPhase == .ended { carried = 0 }
        }

        /// Rightward travel is back in time.
        private func travel(_ points: CGFloat) {
            guard step > 0 else { return }
            carried += points
            let days = Int((carried / step).rounded(.towardZero))
            guard days != 0 else { return }
            carried -= CGFloat(days) * step
            onPan?(-days)
        }
    }
}
