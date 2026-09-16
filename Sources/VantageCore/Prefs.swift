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
        static let repliesEnabled = "repliesEnabled"
        static let lastRefreshSuccess = "lastRefreshSuccess"
        static let manualRates = "manualRates"
        static let manualRateDates = "manualRateDates"
        static let rememberCredentials = "rememberCredentials"
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

    /// Currencies offered in Settings.
    ///
    /// The ECB's list plus the hard USD pegs in `FXPeg`, because those are exactly the currencies
    /// Vantage can convert. Offering a display currency it can't convert into would be a trap —
    /// which is why this list is derived from the same rule the converter uses rather than
    /// maintained beside it.
    public static let selectableCurrencies: [String] = ([
        "AUD", "BRL", "CAD", "CHF", "CNY", "CZK", "DKK", "EUR", "GBP", "HKD", "HUF", "IDR",
        "ILS", "INR", "ISK", "JPY", "KRW", "MXN", "MYR", "NOK", "NZD", "PHP", "PLN", "RON",
        "SEK", "SGD", "THB", "TRY", "USD", "ZAR",
    ] + FXPeg.unitsPerUSD.keys).sorted()

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

    /// Whether Vantage may publish replies to customer reviews.
    ///
    /// **Off unless explicitly turned on**, and it stays that way: replying needs an Admin key in
    /// practice, which is a far more powerful thing to hand an app than the App Manager key reading
    /// reviews requires. Defaulting this on — or flipping it as a side effect of adding a key —
    /// would mean somebody who only wanted to *see* their reviews ends up with an app that can
    /// publish under their name. See the consent step in Settings and `docs/REVIEWS_API.md`.
    public static var repliesEnabled: Bool {
        get { defaults.bool(forKey: Key.repliesEnabled) }
        set { defaults.set(newValue, forKey: Key.repliesEnabled) }
    }

    /// Whether the credentials read at launch are kept in memory for the life of the process.
    ///
    /// **On by default**, because the alternative is answering the Keychain every time: the sales
    /// client asks for credentials per request, so a thirty-day backfill reads the item thirty
    /// times. macOS only prompts when its ACL grant doesn't cover the app — but a build-from-source
    /// bundle is ad-hoc signed, its designated requirement is the hash of the binary, and every
    /// rebuild therefore invalidates every "Always Allow". That is exactly when re-reading turns
    /// into a wall of password prompts.
    ///
    /// **Off is a real choice, not a token one.** With this off, credentials are read on demand,
    /// handed to one request and dropped, so a key never outlives the request that used it. That
    /// was the behaviour Vantage promised unconditionally before this existed, and for someone who
    /// would rather type a password than have a private key sit in a running process's memory, it
    /// is the right answer. `SECURITY.md` describes both.
    public static var rememberCredentials: Bool {
        get {
            guard defaults.object(forKey: Key.rememberCredentials) != nil else { return true }
            return defaults.bool(forKey: Key.rememberCredentials)
        }
        set { defaults.set(newValue, forKey: Key.rememberCredentials) }
    }

    /// When Vantage last got something out of App Store Connect.
    ///
    /// Persisted so "updated 2 hours ago" survives a relaunch. Without it the panel forgets on every
    /// launch and can only say "just now" about a fetch that hasn't happened yet.
    public static var lastRefreshSuccess: Date? {
        get { defaults.object(forKey: Key.lastRefreshSuccess) as? Date }
        set { defaults.set(newValue, forKey: Key.lastRefreshSuccess) }
    }

    /// Rates the user typed in, for currencies nothing publishes a rate for.
    ///
    /// Units per **US dollar**, matching how these are quoted everywhere. Stored as strings so the
    /// value that comes back is the value that went in — a `Decimal` written through a plist would
    /// be round-tripped as a double, and this app does not put money near binary floating point.
    ///
    /// Only ever used where there is no published rate and no central-bank peg. A currency Vantage
    /// can price properly is never converted at a hand-typed number.
    public static var manualRates: [String: Decimal] {
        get {
            guard let stored = defaults.dictionary(forKey: Key.manualRates) as? [String: String]
            else { return [:] }
            var rates: [String: Decimal] = [:]
            for (code, value) in stored {
                // A zero or negative rate would divide the total into nonsense, so it's dropped
                // rather than trusted.
                if let decimal = Decimal(string: value), decimal > 0 {
                    rates[code.uppercased()] = decimal
                }
            }
            return rates
        }
        set {
            var stored: [String: String] = [:]
            for (code, rate) in newValue where rate > 0 {
                stored[code.uppercased()] = "\(rate)"
            }
            defaults.set(stored, forKey: Key.manualRates)
        }
    }

    /// When each manual rate was last set, so the UI can say how old it is. A hand-typed rate for a
    /// floating currency goes stale silently; the date is the only thing that makes that visible.
    public static var manualRateDates: [String: Date] {
        get { (defaults.dictionary(forKey: Key.manualRateDates) as? [String: Date]) ?? [:] }
        set { defaults.set(newValue, forKey: Key.manualRateDates) }
    }

    public static func setManualRate(_ rate: Decimal?, for currency: String, now: Date = Date()) {
        let code = currency.uppercased()
        var rates = manualRates
        var dates = manualRateDates
        if let rate, rate > 0 {
            rates[code] = rate
            dates[code] = now
        } else {
            rates.removeValue(forKey: code)
            dates.removeValue(forKey: code)
        }
        manualRates = rates
        manualRateDates = dates
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
