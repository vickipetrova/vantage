import CoreGraphics

/// The panel's sections, in rail order.
///
/// Each route declares its own size. There is no free-form resizing in v0.2 — the panel is a
/// glance surface anchored to the menu bar, and a user-resizable one would have to remember a size
/// per section and restore it correctly on a display change, which is a lot of state for no gain.
enum PanelRoute: Hashable {
    case overview
    /// The Apple Identifier of the app being shown. Carried in the route rather than in a separate
    /// selection variable so back-navigation can't leave a stale app on screen.
    case appDetail(appleID: String)
    case reviews
    case analytics

    /// The rail's items, in order. `appDetail` is absent on purpose: it's reached by clicking an
    /// app, not by picking a section, and a rail slot for it would be dead until one is chosen.
    static let railOrder: [PanelRoute] = [.overview, .reviews, .analytics]

    /// Which rail item lights up. App detail belongs to Overview — that's where you came from and
    /// where Back goes.
    var railSelection: PanelRoute {
        switch self {
        case .appDetail: return .overview
        default: return self
        }
    }

    /// SF Symbols 4 names only — anything newer doesn't exist on macOS 13.
    var symbol: String {
        switch self {
        case .overview, .appDetail: return "square.grid.2x2"
        case .reviews: return "star.bubble"
        case .analytics: return "chart.line.uptrend.xyaxis"
        }
    }

    var label: String {
        switch self {
        case .overview: return "Overview"
        case .appDetail: return "App"
        case .reviews: return "Reviews"
        case .analytics: return "Analytics"
        }
    }

    /// Compact for the glance, expanded for anything you read or type into.
    var size: CGSize {
        switch self {
        case .overview:
            return CGSize(width: 400, height: 480)
        case .appDetail, .reviews, .analytics:
            return CGSize(width: 680, height: 600)
        }
    }
}
