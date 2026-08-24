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
    private var pollTimer: Timer?
    private var isFetching = false

    /// How far back the first run *fetches*. Enough for the 7- and 30-day rows and no further;
    /// Apple keeps daily reports for a year, so a wider net is possible but pointless.
    private static let backfillDays = 30

    /// How far back the panel *reads from disk*. Wider than the backfill on purpose and free —
    /// this is a cache read, not a request.
    ///
    /// Without it the "vs previous 30 days" comparison could never appear: rendering loaded exactly
    /// thirty days, so the thirty days before them were never in hand and the comparison was
    /// structurally dead. Days accumulate as the app runs, so it fills in on its own.
    private static let renderDays = 60

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
        settingsWindow.unpricedCurrencies = { [weak self] in self?.unpricedCurrencies() ?? [] }
        settingsWindow.testConnection = { [weak self] completion in
            self?.testConnection(completion) }

        Notifier.requestAuthorizationIfNeeded()
        // Whatever's on disk, so the first render isn't blank — with the user's own rates for any
        // currency nothing publishes one for.
        rates = fx.cached()?.applying(manualRates: Prefs.manualRates)

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
        render()
    }

    /// Currencies in the cache with no real rate behind them — no ECB rate, no central-bank peg.
    ///
    /// Offered in Settings so the user can supply a rate for exactly the currencies that need one,
    /// rather than being shown a list of every currency in the world.
    private func unpricedCurrencies() -> [String] {
        guard let rates else { return [] }
        var codes: Set<String> = []
        for day in store.loadAll(renderWindow) {
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
    private var fetchWindow: [ReportDate] { ReportDate.yesterday().lastDays(Self.backfillDays) }
    /// The dates to render from cache.
    private var renderWindow: [ReportDate] { ReportDate.yesterday().lastDays(Self.renderDays) }

    /// Renders from disk. Instant, offline, and the reason a relaunch or a metric toggle doesn't
    /// wait on the network.
    private func render(error: Error? = nil) {
        let days = store.loadAll(renderWindow)
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
        guard !isFetching else { return }  // Refresh Now during a backfill shouldn't double it.
        isFetching = true
        panelModel.refreshStarted()

        refreshRates { [weak self] in
            guard let self else { return }
            self.backfill.run(dates: self.fetchWindow, userInitiated: userInitiated,
                              onDay: { day in
                DispatchQueue.main.async {
                    // Days land independently, so the menu fills in as they arrive.
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
        let newest = store.loadAll(renderWindow).map(\.date).max()
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
