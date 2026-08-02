import AppKit
import VantageCore

/// Wiring: a provider, a cache, exchange rates, and a timer that only fires when Apple might
/// actually have something new.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuController = MenuController()
    private let settingsWindow = SettingsWindow()
    private let store = ReportStore()
    private let fx = FX()
    private let backfill: Backfill

    private var rates: FXRates?
    private var pollTimer: Timer?
    private var isFetching = false

    /// How far back the first run reaches. Enough for the 7- and 30-day rows and no further; Apple
    /// keeps daily reports for a year, so a wider net is possible but pointless.
    private static let backfillDays = 30

    override init() {
        backfill = Backfill(provider: ASCClient(), store: ReportStore())
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // Menu bar only, no dock icon.
        MainMenu.install()  // Without this, ⌘V doesn't work in the Settings fields.

        menuController.onRefresh = { [weak self] in self?.refresh(userInitiated: true) }
        menuController.onSettings = { [weak self] in self?.settingsWindow.show() }
        menuController.onMetricsChanged = { [weak self] in self?.render() }
        settingsWindow.onCredentialsChanged = { [weak self] in self?.refresh(userInitiated: true) }
        settingsWindow.onPreferencesChanged = { [weak self] in self?.preferencesChanged() }
        settingsWindow.testConnection = { [weak self] completion in
            self?.testConnection(completion) }

        Notifier.requestAuthorizationIfNeeded()
        rates = fx.cached()  // Whatever's on disk, so the first render isn't blank.

        guard KeychainStore.hasCredentials else {
            // First launch: nothing to show and nothing to fetch, so open the one window that
            // fixes that rather than sitting there displaying a dash.
            menuController.showNoCredentials()
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
        render()
    }

    // MARK: - Rendering

    private var window: [ReportDate] { ReportDate.yesterday().lastDays(Self.backfillDays) }

    /// Renders from disk. Instant, offline, and the reason a relaunch or a metric toggle doesn't
    /// wait on the network.
    private func render(error: Error? = nil) {
        menuController.update(days: store.loadAll(window), rates: rates, error: error)
    }

    // MARK: - Fetching

    private func refresh(userInitiated: Bool) {
        guard KeychainStore.hasCredentials else {
            menuController.showNoCredentials()
            return
        }
        guard !isFetching else { return }  // Refresh Now during a backfill shouldn't double it.
        isFetching = true

        refreshRates { [weak self] in
            guard let self else { return }
            self.backfill.run(dates: self.window, userInitiated: userInitiated, onDay: { day in
                DispatchQueue.main.async {
                    // Days land independently, so the menu fills in as they arrive.
                    self.render()
                    Notifier.announce(day, rates: self.rates)
                }
            }, completion: { error in
                DispatchQueue.main.async {
                    self.isFetching = false
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
                if let rates { self?.rates = rates }
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
        let newest = store.loadAll(window).map(\.date).max()
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
