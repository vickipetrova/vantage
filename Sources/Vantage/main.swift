import AppKit
import VantageCore

/// Wiring: a provider, a cache, exchange rates, and a timer that only fires when Apple might
/// actually have something new.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItemController = StatusItemController()
    private let panelModel = PanelModel()
    private lazy var panel = PanelController(model: panelModel)
    private let settingsWindow = SettingsWindow()
    private let store = ReportStore()
    private let fx = FX()
    private let backfill: Backfill

    private var rates: FXRates?
    /// Every cached day, in memory. The panel can step back through the whole history, so it's
    /// handed all of it — read from disk once, then kept current as the backfill lands each day,
    /// rather than re-reading a year of files for every day that arrives.
    private var cache: [ReportDate: DaySales] = [:]
    private var pollTimer: Timer?
    private var isFetching = false

    /// The recent stretch that decides which currencies Settings offers a manual rate for, and
    /// what the scheduler treats as newest. The panel itself gets the whole cache.
    private static let recentDays = 60

    override init() {
        backfill = Backfill(provider: ASCClient(), store: ReportStore())
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // Menu bar only, no dock icon.
        MainMenu.install()  // Without this, ⌘V doesn't work in the Settings fields.

        statusItemController.onRefresh = { [weak self] in self?.refresh(userInitiated: true) }
        statusItemController.onSettings = { [weak self] in self?.settingsWindow.show() }
        statusItemController.onTogglePanel = { [weak self] button in
            self?.panel.toggle(relativeTo: button)
        }
        // A right-click menu on top of an open panel is two overlapping surfaces saying different
        // things about the same data.
        statusItemController.onWillShowMenu = { [weak self] in self?.panel.close() }

        panelModel.onRefresh = { [weak self] in self?.refresh(userInitiated: true) }
        panelModel.onSettings = { [weak self] in self?.settingsWindow.show() }
        panelModel.onMetricsChanged = { [weak self] in self?.render() }
        settingsWindow.onCredentialsChanged = { [weak self] in self?.refresh(userInitiated: true) }
        settingsWindow.onPreferencesChanged = { [weak self] in self?.preferencesChanged() }
        settingsWindow.onReviewsKeyChanged = { [weak self] in self?.panelModel.reviewsKeyChanged() }
        // Not user-initiated: a wider window should fill in, not re-ask about assumed zeros.
        settingsWindow.onHistoryChanged = { [weak self] in self?.refresh(userInitiated: false) }
        settingsWindow.unpricedCurrencies = { [weak self] in self?.unpricedCurrencies() ?? [] }
        settingsWindow.testConnection = { [weak self] completion in
            self?.testConnection(completion) }

        Notifier.requestAuthorizationIfNeeded()
        // Whatever's on disk, so the first render isn't blank — with the user's own rates for any
        // currency nothing publishes one for.
        rates = fx.cached()?.applying(manualRates: Prefs.manualRates)
        reloadCache()

        // Registered before the credentials guard: a first-launch user who sets up credentials in
        // the window this guard opens would otherwise get no wake refresh for the whole session.
        //
        // Timers are unreliable across sleep — a Mac can wake hours later, well past a publication
        // window it slept through. Ask again the moment it wakes.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        guard KeychainStore.hasCredentials else {
            // First launch: nothing to show and nothing to fetch, so open the one window that
            // fixes that rather than sitting there displaying a dash.
            statusItemController.showNoCredentials()
            panelModel.showNoCredentials()
            settingsWindow.show()
            return
        }
        render()
        refresh(userInitiated: false)


        // Timers are unreliable across sleep — a Mac can wake hours later, well past a publication
        // window it slept through. Ask again the moment it wakes.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func didWake() { refresh(userInitiated: false) }

    private func preferencesChanged() {
        Notifier.requestAuthorizationIfNeeded()
        // A changed manual rate re-prices everything on screen without refetching anything.
        rates = rates?.applying(manualRates: Prefs.manualRates)
        // Settings can delete cached days, and that arrives here too.
        reloadCache()
        render()
    }

    /// Currencies in the cache with no real rate behind them — no ECB rate, no central-bank peg.
    ///
    /// Offered in Settings so the user can supply a rate for exactly the currencies that need one,
    /// rather than being shown a list of every currency in the world.
    private func unpricedCurrencies() -> [String] {
        guard let rates else { return [] }
        var codes: Set<String> = []
        for day in recent {
            for (code, amount) in day.proceeds where amount != 0 {
                // `needsUserRate`, not `canConvert`: a built-in estimate makes a currency
                // convertible, and that is precisely when a real rate is most worth asking for.
                if rates.needsUserRate(code) { codes.insert(code.uppercased()) }
            }
        }
        return codes.sorted()
    }

    // MARK: - Rendering

    /// The dates to fetch.
    ///
    /// `Prefs.historyDays`, a year by default. Apple deletes daily reports after that, and the CLI
    /// answers questions about any stretch of the cache — so a day not fetched within the year is
    /// a day no one can ask about, ever. Only missing days are requested, so after the first run
    /// this is one or two requests a day however wide it is.
    private var fetchWindow: [ReportDate] { ReportDate.yesterday().lastDays(Prefs.historyDays) }
    /// Cached days within `recentDays`.
    private var recent: [DaySales] {
        let from = ReportDate.yesterday().adding(days: -(Self.recentDays - 1))
        return cache.values.filter { $0.date >= from }
    }

    private func reloadCache() {
        cache = Dictionary(store.loadAllCached().map { ($0.date, $0) },
                           uniquingKeysWith: { first, _ in first })
    }

    /// Renders from the in-memory cache. Instant, offline, and the reason a relaunch or a metric
    /// toggle doesn't wait on the network.
    private func render(error: Error? = nil) {
        let days = Array(cache.values)
        statusItemController.update(days: days, rates: rates, error: error)
        panelModel.update(days: days, rates: rates, error: error)
    }

    // MARK: - Fetching

    private func refresh(userInitiated: Bool) {
        // Registered before the credentials guard: a first-launch user who sets up credentials in
        // the window this guard opens would otherwise get no wake refresh for the whole session.
        //
        // Timers are unreliable across sleep — a Mac can wake hours later, well past a publication
        // window it slept through. Ask again the moment it wakes.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        guard KeychainStore.hasCredentials else {
            statusItemController.showNoCredentials()
            panelModel.showNoCredentials()
            panelModel.refreshFinished(succeeded: false)
            return
        }
        // Analytics rides **every** refresh, background ones included — so a Mac sitting in the
        // menu bar keeps its history current without anyone opening anything.
        //
        // What makes that affordable is the staleness gate rather than restraint about when to ask.
        // `refresh` is the launch, wake and poll-timer path, and `Schedule.nextPoll` fires hourly
        // only while chasing a report that's due, otherwise once at the next morning window — but
        // `AnalyticsStore.maxAge` is the real limit, so this settles at one to four fetches a day
        // however often the timer fires. Analytics data moves daily; anything tighter would re-pull
        // the same numbers.
        //
        // `force` only when the user asked. Clicking Refresh means now, not "if the six-hour cache
        // agrees"; a timer firing does not get to say that. It sits above the `isFetching` guard
        // because a sales backfill already in flight says nothing about whether analytics is worth
        // fetching, and `days` is populated by the `render()` that precedes the launch refresh, so
        // there is always an app list to work from.
        panelModel.loadAnalytics(force: userInitiated)

        guard !isFetching else { return }  // Refresh Now during a backfill shouldn't double it.
        isFetching = true
        panelModel.refreshStarted()

        refreshRates { [weak self] in
            guard let self else { return }
            self.backfill.run(dates: self.fetchWindow, userInitiated: userInitiated,
                              onDay: { day in
                DispatchQueue.main.async {
                    // Days land independently, so the menu fills in as they arrive.
                    self.cache[day.date] = day
                    self.render()
                    Notifier.announce(day, rates: self.rates)
                }
            }, completion: { error in
                DispatchQueue.main.async {
                    self.isFetching = false
                    // A refresh that reached Apple counts as a success even when it added no days:
                    // "nothing new" is an answer, and the panel needs to say when it last got one.
                    self.panelModel.refreshFinished(succeeded: error == nil)
                    self.render(error: error)
                    self.reschedule()
                }
            })
        }
    }

    private func refreshRates(then next: @escaping () -> Void) {
        fx.rates { [weak self] rates in
            DispatchQueue.main.async {
                // A failed rates fetch is not a failed refresh: sales figures matter more than the
                // currency they're shown in, and the menu says when conversion is unavailable.
                if let rates { self?.rates = rates.applying(manualRates: Prefs.manualRates) }
                next()
            }
        }
    }

    /// One request, reported back — so Settings can say whether the credentials work instead of
    /// leaving the user to read the menu bar and guess.
    private func testConnection(_ completion: @escaping (Result<Void, Error>) -> Void) {
        ASCClient().fetchTSV(ReportDate.yesterday()) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    // A 404 counts as success: it means Apple accepted the key and simply has no
                    // report for that date, which is a schedule fact, not a credential problem.
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Scheduling

    /// Sleeps until Apple's next publication window rather than polling all day. Outside the
    /// window the answer cannot change, so asking is pure noise.
    private func reschedule() {
        pollTimer?.invalidate()
        let newest = cache.keys.max()
        let next = Schedule.nextPoll(newestCached: newest)

        let timer = Timer(fireAt: next, interval: 0, target: self,
                          selector: #selector(scheduledPoll), userInfo: nil, repeats: false)
        // `.common` mode: a timer in the default mode stops firing while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    @objc private func scheduledPoll() {
        refresh(userInitiated: false)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
