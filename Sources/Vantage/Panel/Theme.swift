import SwiftUI

/// The panel's measurements and colours.
///
/// Semantic colours only — `.primary`, `.secondary`, `NSColor.controlAccentColor`, and the system
/// materials. Nothing here names an RGB value, so light mode, dark mode, increased contrast and a
/// user's accent colour all work without a second code path.
enum Theme {
    /// The rail's width. Wide enough for a 20pt symbol with a comfortable hit target, narrow enough
    /// that it reads as a rail rather than a sidebar.
    static let railWidth: CGFloat = 56

    static let cardCorner: CGFloat = 10
    static let panelCorner: CGFloat = 12

    enum Space {
        static let tight: CGFloat = 6
        static let row: CGFloat = 10
        static let card: CGFloat = 14
        static let section: CGFloat = 18
    }

    /// A card's background. `quaternary` over the window material gives a panel that still reads as
    /// vibrant, where an opaque fill would flatten it into a plain window.
    static var cardFill: some ShapeStyle { Color.primary.opacity(0.045) }

    static var cardStroke: some ShapeStyle { Color.primary.opacity(0.07) }
}

extension View {
    /// The standard card: padded, filled, hairline-stroked.
    func card() -> some View {
        self
            .padding(Theme.Space.card)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                    .fill(Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
    }
}
