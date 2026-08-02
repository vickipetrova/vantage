import Foundation

/// The ways a report's units can be counted.
///
/// "Downloads" sounds like one number and isn't. A day's report mixes first-time installs, in-app
/// purchases, subscription renewals, re-downloads and updates, and App Store Connect's own
/// dashboard adds some of those together in ways that aren't obvious — which is why Vantage's
/// figure and the dashboard's can differ by exactly one and take an afternoon to explain.
///
/// So the choice is explicit and the user makes it. Installs are on by default, because that's what
/// a `↓` means and it matches Apple's own "App and Bundle Units" definition. Everything else can be
/// switched on in the menu.
///
/// Every metric is computed from `DaySales.unitsByProductType`, so toggling one re-reads the cache
/// rather than re-fetching a month of reports.
public enum Metric: String, CaseIterable, Codable, Sendable {
    /// Apple: "the number of first-time purchases of your app or bundle. […] App updates,
    /// downloads from the same Apple Account onto other devices, and redownloads to the same
    /// device aren't counted."
    case installs
    /// Consumables, non-consumables and non-renewing subscriptions. Restored purchases are
    /// excluded, per Apple's own metric definition.
    case inAppPurchases
    /// Auto-renewable subscriptions: purchases, renewals and reactivations.
    case subscriptions
    /// A customer installing again something they already own.
    case redownloads
    case updates
    /// Product type identifiers that match nothing above.
    ///
    /// Not a rounding error — Apple's own sample report uses `1AY`, which appears nowhere in
    /// Apple's own product type table. This bucket is how a code Apple adds tomorrow stays visible
    /// instead of silently vanishing from every total.
    case other

    public var productTypes: Set<String> {
        switch self {
        case .installs:       return ["1", "1-B", "1E", "1EP", "1EU", "1F", "1T", "F1", "F1-B"]
        case .inAppPurchases: return ["IA1", "IA1-M", "FI1", "IA9", "IA9-M"]
        case .subscriptions:  return ["IAY", "IAY-M"]
        case .redownloads:    return ["3", "3F"]
        case .updates:        return ["7", "7F", "7T", "F7"]
        case .other:          return []
        }
    }

    /// Label for the menu's toggle list.
    public var label: String {
        switch self {
        case .installs:       return "First-time downloads"
        case .inAppPurchases: return "In-app purchases"
        case .subscriptions:  return "Subscriptions"
        case .redownloads:    return "Re-downloads"
        case .updates:        return "Updates"
        case .other:          return "Other / unrecognized"
        }
    }

    /// Only installs is on by default: adding anything else makes the arrow mean something other
    /// than a download.
    public static let defaultEnabled: Set<Metric> = [.installs]

    /// Order shown in the menu — commonest first, diagnostics last.
    public static let displayOrder: [Metric] =
        [.installs, .inAppPurchases, .subscriptions, .redownloads, .updates, .other]

    /// Every code claimed by a named metric, so `.other` can be defined as the remainder.
    private static let claimed: Set<String> = {
        var all: Set<String> = []
        for metric in Metric.allCases where metric != .other { all.formUnion(metric.productTypes) }
        return all
    }()

    // MARK: - Counting

    /// Net units of this metric in one day.
    public func units(in day: DaySales) -> Decimal {
        Metric.units(in: day, metrics: [self])
    }

    public func contains(_ productType: String) -> Bool {
        let code = productType.trimmingCharacters(in: .whitespaces).uppercased()
        if self == .other { return !Metric.claimed.contains(code) }
        return productTypes.contains(code)
    }

    /// Net units across a set of metrics, which is what the menu bar's arrow counts.
    public static func units(in day: DaySales, metrics: Set<Metric>) -> Decimal {
        guard !day.unitsByProductType.isEmpty else {
            // Cached by a build from before the per-type tally existed. Such a day knows one
            // number and it's the install count, so that's the only metric it can answer for —
            // reporting zero instead would turn a month of real history into a flat line.
            return metrics.contains(.installs) ? day.downloads : 0
        }
        return day.unitsByProductType.reduce(Decimal(0)) { total, entry in
            metrics.contains(where: { $0.contains(entry.key) }) ? total + entry.value : total
        }
    }

    public static func units(in days: [DaySales], metrics: Set<Metric>) -> Decimal {
        days.reduce(Decimal(0)) { $0 + units(in: $1, metrics: metrics) }
    }

    /// The same question for one app's row, so a breakdown always sums to the total above it.
    public static func units(in app: AppSales, metrics: Set<Metric>) -> Decimal {
        guard !app.unitsByProductType.isEmpty else {
            return metrics.contains(.installs) ? app.downloads : 0
        }
        return app.unitsByProductType.reduce(Decimal(0)) { total, entry in
            metrics.contains(where: { $0.contains(entry.key) }) ? total + entry.value : total
        }
    }
}
