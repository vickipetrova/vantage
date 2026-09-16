import AppKit

/// The watchtower, for the menu bar.
///
/// Drawn from the geometry of `menubar-glyph.svg` (a 24pt grid) rather than shipped as a file: the
/// package has no resource bundle, and seven primitives don't justify adding one. A **template**
/// image, so AppKit colours it — black or white with the menu bar, highlighted when the panel is
/// open, and dimmed when the button is.
enum TowerGlyph {
    static let image: NSImage = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            // The SVG's y axis points down, hence `flipped: true` above.
            let scale = side / 24
            let transform = NSAffineTransform()
            transform.scale(by: scale)
            transform.concat()
            NSColor.black.set()

            // Roof: filled, and stroked with round joins so its corners are soft like the icon's.
            let roof = NSBezierPath()
            roof.move(to: NSPoint(x: 12, y: 3.2))
            roof.line(to: NSPoint(x: 16.2, y: 6.2))
            roof.line(to: NSPoint(x: 7.8, y: 6.2))
            roof.close()
            roof.lineJoinStyle = .round
            roof.lineWidth = 1.2
            roof.fill()
            roof.stroke()

            // Cabin, with its window cut out.
            let cabin = NSBezierPath(rect: NSRect(x: 8.9, y: 6.9, width: 6.2, height: 3.5))
            cabin.append(NSBezierPath(rect: NSRect(x: 9.9, y: 7.9, width: 4.2, height: 1.5)))
            cabin.windingRule = .evenOdd
            cabin.fill()

            // Deck.
            NSBezierPath(roundedRect: NSRect(x: 7.7, y: 10.9, width: 8.6, height: 1.1),
                         xRadius: 0.55, yRadius: 0.55).fill()

            // Legs, then the cross-brace.
            func line(_ from: NSPoint, _ to: NSPoint, width: CGFloat) {
                let path = NSBezierPath()
                path.move(to: from)
                path.line(to: to)
                path.lineWidth = width
                path.lineCapStyle = .round
                path.stroke()
            }
            line(NSPoint(x: 9.9, y: 12.7), NSPoint(x: 7.5, y: 20.2), width: 1.6)
            line(NSPoint(x: 14.1, y: 12.7), NSPoint(x: 16.5, y: 20.2), width: 1.6)
            line(NSPoint(x: 9.3, y: 14.6), NSPoint(x: 15.6, y: 18.3), width: 1.0)
            line(NSPoint(x: 14.7, y: 14.6), NSPoint(x: 8.4, y: 18.3), width: 1.0)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Vantage"
        return image
    }()
}
