import Foundation

/// Preferences, backed by UserDefaults.
///
/// No credential ever comes near this file — those live in the Keychain. This is display currency,
/// which metrics to count, and whether to send the morning notification.
public enum Prefs {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let displayCurrency = "displayCurrency"
        static let metrics = "enabledMetrics"
        static let morningNotification = "morningNotification"
        static let trendSeries = "trendSeries"
        static let overviewRange = "overviewRange"
    }

    /// What the menu bar renders money in. Defaults to the currency of the user's region, which is
    /// right often enough to skip a setup question, and is overridable for the many developers
    /// whose region and payment currency differ.
    public static var displayCurrency: String {
        get {
            if let stored = defaults.string(forKey: Key.displayCurrency), stored.count == 3 {
                return stored.uppercased()
            }
            return Locale.current.currency?.identifier.uppercased() ?? "USD"
        }
        set { defaults.set(newValue.uppercased(), forKey: Key.displayCurrency) }
    }

    /// Currencies offered in Settings. The ECB's list, since anything outside it can't be converted
    /// into anyway — offering a display currency Vantage can't convert to would be a trap.
    public static let selectableCurrencies = [
        "AUD", "BRL", "CAD", "CHF", "CNY", "CZK", "DKK", "EUR", "GBP", "HKD", "HUF", "IDR",
        "ILS", "INR", "ISK", "JPY", "KRW", "MXN", "MYR", "NOK", "NZD", "PHP", "PLN", "RON",
        "SEK", "SGD", "THB", "TRY", "USD", "ZAR",
    ]

    /// Which unit metrics the `↓` figure counts.
    ///
    /// Stored rather than derived so switching one on doesn't refetch anything — every metric is
    /// computed from the per-product-type tally already in the cache.
    public static var metrics: Set<Metric> {
        get {
            guard let raw = defaults.array(forKey: Key.metrics) as? [String] else {
                return Metric.defaultEnabled
            }
            let stored = Set(raw.compactMap(Metric.init(rawValue:)))
            // An empty selection would render a permanent zero that looks like a bug rather than a
            // choice, so it falls back instead.
            return stored.isEmpty ? Metric.defaultEnabled : stored
        }
        set {
            defaults.set(newValue.map(\.rawValue).sorted(), forKey: Key.metrics)
        }
    }

    public static func toggle(_ metric: Metric) {
        var current = metrics
        if current.contains(metric) { current.remove(metric) } else { current.insert(metric) }
        metrics = current
    }

    /// Which single series the Overview chart draws.
    ///
    /// Separate from `metrics`, which is a *set* governing what the `↓` figure counts everywhere.
    /// One line on a chart is a different question from which units are downloads, and conflating
    /// them meant either an unreadable chart or a crippled toggle.
    public static var trendSeries: TrendSeries {
        get {
            guard let raw = defaults.string(forKey: Key.trendSeries),
                  let series = TrendSeries(rawValue: raw)
            else { return .metric(.installs) }
            return series
        }
        set { defaults.set(newValue.rawValue, forKey: Key.trendSeries) }
    }

    /// How much of the cache the Overview summarises. Remembered, because it's a way of working
    /// rather than a per-session choice — someone who thinks in weeks thinks in weeks tomorrow too.
    public static var overviewRange: OverviewRange {
        get {
            guard let raw = defaults.string(forKey: Key.overviewRange),
                  let range = OverviewRange(rawValue: raw)
            else { return .yesterday }
            return range
        }
        set { defaults.set(newValue.rawValue, forKey: Key.overviewRange) }
    }

    public static var morningNotification: Bool {
        get {
            guard defaults.object(forKey: Key.morningNotification) != nil else { return true }
            return defaults.bool(forKey: Key.morningNotification)
        }
        set { defaults.set(newValue, forKey: Key.morningNotification) }
    }

    /// The report date the morning notification has already fired for, so relaunching doesn't
    /// re-announce a day the user has seen.
    public static func hasNotified(about date: ReportDate) -> Bool {
        defaults.string(forKey: "notified") == date.apiString
    }

    public static func markNotified(about date: ReportDate) {
        defaults.set(date.apiString, forKey: "notified")
    }
}
