import SwiftUI
import VantageCore

/// The Overview chart: one series over the cached window.
///
/// Drawn with `Path` rather than Swift Charts. Charts would do this in a dozen lines, but it's
/// macOS 13-only at the API level we'd want and it brings a framework's worth of behaviour for one
/// line — and the one thing this chart must get right, not joining across a gap, is the thing a
/// general-purpose charting library makes hardest to control.
struct TrendChart: View {
    let data: TrendData
    /// How many trailing days the figures above the chart cover, shaded so the two can be read
    /// together. Ignored when it covers the whole window — shading everything says nothing.
    var highlightLast: Int = 0

    /// Tall enough to read a shape in, short enough that the app rows stay above the fold.
    private static let height: CGFloat = 78

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                if let range = highlightRect(in: size) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: range.width, height: size.height)
                        .position(x: range.midX, y: size.height / 2)
                }

                if let zero = data.zeroUnit {
                    // Only drawn when the series goes negative. Without it a chart running below
                    // zero looks like an ordinary one with a low patch.
                    Path { path in
                        let y = size.height - CGFloat(zero) * size.height
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundColor(.secondary.opacity(0.4))
                }

                ForEach(Array(segments().enumerated()), id: \.offset) { _, segment in
                    let points = segment.map { point(for: $0, in: size) }
                    ZStack {
                        area(points, in: size)
                            .fill(LinearGradient(
                                colors: [Color.accentColor.opacity(0.28),
                                         Color.accentColor.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom))
                        line(points)
                            .stroke(Color.accentColor,
                                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round,
                                                       lineJoin: .round))
                    }
                }

                axisLabels

                if let last = lastPoint(in: size) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .position(last)
                }
            }
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }

    /// The top of the drawn range, and the bottom when it isn't zero.
    ///
    /// Enough to read magnitude off the shape without turning a sparkline into a full chart with
    /// gridlines — the exact figures are already printed above it.
    private var axisLabels: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(data.upperLabel)
            Spacer(minLength: 0)
            // A floor of zero is what the eye already assumes, so printing it adds nothing. A
            // negative floor is the opposite: it changes how the whole shape reads.
            if data.lower != 0 {
                Text(data.lowerLabel)
            }
        }
        .font(.system(size: 9))
        .foregroundColor(.secondary)
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .trailing)
        .allowsHitTesting(false)
    }

    // MARK: - Geometry

    /// The shaded band covering the selected range, in view coordinates.
    private func highlightRect(in size: CGSize) -> (midX: CGFloat, width: CGFloat)? {
        let count = data.points.count
        guard highlightLast > 0, count > 1, highlightLast < count else { return nil }
        let step = size.width / CGFloat(count - 1)
        // Half a step of padding on the leading edge so a single highlighted day is a visible band
        // rather than a hairline at the very edge.
        let leading = size.width - CGFloat(highlightLast - 1) * step - step / 2
        let clamped = max(0, leading)
        let width = size.width - clamped
        return (clamped + width / 2, width)
    }

    /// Runs of consecutive plotted days.
    ///
    /// A gap ends a segment instead of being interpolated across, so a week Vantage never fetched
    /// reads as absent rather than as a straight line down and back up.
    private func segments() -> [[(index: Int, unit: Double)]] {
        var result: [[(index: Int, unit: Double)]] = []
        var current: [(index: Int, unit: Double)] = []
        for (index, point) in data.points.enumerated() {
            if let unit = point.unit {
                current.append((index, unit))
            } else if !current.isEmpty {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func x(_ index: Int, in size: CGSize) -> CGFloat {
        guard data.points.count > 1 else { return size.width / 2 }
        return size.width * CGFloat(index) / CGFloat(data.points.count - 1)
    }

    private func point(for entry: (index: Int, unit: Double), in size: CGSize) -> CGPoint {
        // Inset vertically so a value at the very top isn't clipped by the stroke's own width.
        let inset: CGFloat = 3
        let usable = size.height - inset * 2
        return CGPoint(x: x(entry.index, in: size),
                       y: inset + usable - CGFloat(entry.unit) * usable)
    }

    private func line(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            // A single plotted day has no line to draw, so give it a stub wide enough to see.
            if points.count == 1 {
                path.addLine(to: CGPoint(x: first.x + 0.5, y: first.y))
            }
        }
    }

    private func area(_ points: [CGPoint], in size: CGSize) -> Path {
        Path { path in
            guard let first = points.first, let last = points.last, points.count > 1 else { return }
            path.move(to: CGPoint(x: first.x, y: size.height))
            for point in points { path.addLine(to: point) }
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.closeSubpath()
        }
    }

    private func lastPoint(in size: CGSize) -> CGPoint? {
        guard let index = data.points.lastIndex(where: { $0.unit != nil }),
              let unit = data.points[index].unit
        else { return nil }
        return point(for: (index, unit), in: size)
    }
}
