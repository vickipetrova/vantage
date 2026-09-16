import Foundation

/// What the status item can show: the figures, the tower icon, or both.
public enum MenuBarStyle: String, CaseIterable, Sendable {
    case numbers
    case icon
    case iconAndNumbers

    public var label: String {
        switch self {
        case .numbers: return "Numbers"
        case .icon: return "Icon"
        case .iconAndNumbers: return "Icon and numbers"
        }
    }
}

/// The status item's content for a state and a style.
///
/// Here rather than in `StatusItemController` so the rule the icon styles have to keep is tested:
/// **turning the numbers off must never hide a problem.** An icon-only menu bar that looks exactly
/// the same with a revoked key as with a working one is worse than no icon.
public struct MenuBarTitle: Equatable, Sendable {
    public let showsIcon: Bool
    public let text: String
    /// The whole item drawn inactive — loading, or nothing set up yet.
    public let isDimmed: Bool

    public init(showsIcon: Bool, text: String, isDimmed: Bool) {
        self.showsIcon = showsIcon
        self.text = text
        self.isDimmed = isDimmed
    }

    public enum State: Equatable, Sendable {
        case loading
        case failed
        case noCredentials
        /// `behind`: the figures are older than what Apple has published — `Freshness.marksMenuBar`.
        case figures(String, behind: Bool)
    }

    public static func make(_ state: State, style: MenuBarStyle) -> MenuBarTitle {
        // Numbers is exactly the title Vantage always had, symbols included.
        guard style != .numbers else {
            switch state {
            case .loading: return MenuBarTitle(showsIcon: false, text: "…", isDimmed: false)
            case .failed: return MenuBarTitle(showsIcon: false, text: "!", isDimmed: false)
            case .noCredentials: return MenuBarTitle(showsIcon: false, text: "–", isDimmed: false)
            case .figures(let figures, let behind):
                return MenuBarTitle(showsIcon: false, text: behind ? "⚠︎ " + figures : figures,
                                    isDimmed: false)
            }
        }

        switch state {
        // Beside an icon, "…" reads as a truncated label. A dimmed icon says the same thing.
        case .loading:
            return MenuBarTitle(showsIcon: true, text: "", isDimmed: true)
        case .failed:
            return MenuBarTitle(showsIcon: true, text: "!", isDimmed: false)
        // "–" beside an icon means nothing; "!" is what gets someone to open Settings.
        case .noCredentials:
            return MenuBarTitle(showsIcon: true, text: "!", isDimmed: true)
        case .figures(let figures, let behind):
            if style == .icon {
                return MenuBarTitle(showsIcon: true, text: behind ? "⚠︎" : "", isDimmed: false)
            }
            return MenuBarTitle(showsIcon: true, text: behind ? "⚠︎ " + figures : figures,
                                isDimmed: false)
        }
    }
}
