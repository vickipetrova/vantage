import AppKit
import Combine
import VantageCore

/// What the Settings window shows and does.
///
/// The view is dumb, as everywhere else in v0.2: it renders these properties and calls these
/// methods. Every Keychain read and write in the app that isn't a network request happens here.
///
/// **Nothing in this file renders a credential.** The `.p8` is read once, held in memory until Save,
/// and never displayed — the private key must never reach a screenshot attached to a bug report.
/// The two text fields that *are* shown hold identifiers, not secrets.
final class SettingsModel: ObservableObject {
    /// What the Keychain holds for one value right now.
    enum FieldState {
        case stored
        /// Chosen but not yet saved. Only the `.p8` fields can be in this state.
        case staged
        case missing
        /// Missing, and that's fine — the reviews key is optional, and calling its empty fields
        /// "Needed" tells people to create a credential they were just told they don't need.
        case optional

        var label: String {
            switch self {
            case .stored: return "Stored"
            case .staged: return "Ready to save"
            case .missing: return "Needed"
            case .optional: return "Optional"
            }
        }
    }

    /// A one-line outcome under a group of buttons.
    struct Status: Equatable {
        var message: String = ""
        var isError = false
        var isEmpty: Bool { message.isEmpty }
    }

    // MARK: - Callbacks

    var onCredentialsChanged: (() -> Void)?
    var onPreferencesChanged: (() -> Void)?
    var onReviewsKeyChanged: (() -> Void)?
    var onHistoryChanged: (() -> Void)?
    /// Makes one real request and reports whether it worked. Injected so this type stays a form and
    /// knows nothing about App Store Connect.
    var testConnection: ((@escaping (Result<Void, Error>) -> Void) -> Void)?

    // MARK: - Fields

    @Published var issuerID = ""
    @Published var keyID = ""
    @Published var vendorNumber = ""

    @Published var reviewsIssuerID = ""
    @Published var reviewsKeyID = ""

    /// Held only between choosing the file and pressing Save.
    private var pendingPrivateKey: String?
    private var pendingReviewsPrivateKey: String?

    @Published private(set) var states: [KeychainStore.Key: FieldState] = [:]
    @Published private(set) var salesStatus = Status()
    @Published private(set) var reviewsStatus = Status()
    @Published private(set) var isTesting = false

    // MARK: - Preferences

    @Published var displayCurrency = Prefs.displayCurrency {
        didSet {
            guard displayCurrency != oldValue else { return }
            Prefs.displayCurrency = displayCurrency
            onPreferencesChanged?()
        }
    }

    @Published var morningNotification = Prefs.morningNotification {
        didSet {
            guard morningNotification != oldValue else { return }
            Prefs.morningNotification = morningNotification
            onPreferencesChanged?()
        }
    }

    @Published var repliesEnabled = Prefs.repliesEnabled {
        didSet {
            guard repliesEnabled != oldValue else { return }
            Prefs.repliesEnabled = repliesEnabled
            onReviewsKeyChanged?()
        }
    }

    /// Whether credentials stay in memory for the life of the process.
    ///
    /// Switching it off drops what is already held rather than only stopping future reads from
    /// being kept — a privacy setting that waits for the next launch isn't one.
    @Published var rememberCredentials = Prefs.rememberCredentials {
        didSet {
            guard rememberCredentials != oldValue else { return }
            Prefs.rememberCredentials = rememberCredentials
            if !rememberCredentials { KeychainStore.forgetCachedCredentials() }
        }
    }

    @Published var launchAtLogin = LaunchAtLogin.isEnabled

    // MARK: - Data

    /// How far back sales are fetched. Raising it fetches the older days on a refresh started
    /// right away; lowering it deletes nothing.
    @Published var historyDays = Prefs.historyDays {
        didSet {
            guard historyDays != oldValue else { return }
            Prefs.historyDays = historyDays
            onHistoryChanged?()
        }
    }

    private let retention = CacheRetention()

    /// "312 days of sales, 3 Jul 2025 – 15 Sep 2026 · 1.3 MB"
    @Published private(set) var cacheSummary = ""

    /// The first day to keep. Defaults to the start of Apple's year, which deletes nothing Apple
    /// couldn't still supply — the least surprising place for a destructive picker to start.
    @Published var deleteBefore = SettingsModel.localDate(
        ReportDate.yesterday().adding(days: -(ReportStore.appleRetentionDays - 1)))

    /// Set while the confirmation is showing; the text is built in `CacheRetention`.
    @Published var pendingDeletion: String?
    @Published private(set) var dataStatus = Status()

    func refreshCacheSummary() {
        cacheSummary = retention.summary().text
    }

    func requestDelete() {
        let cutoff = Self.reportDate(deleteBefore)
        let deletion = retention.preview(before: cutoff)
        guard !deletion.isEmpty else {
            dataStatus = Status(message: "Nothing is cached from before \(Fmt.reportDate(cutoff)).")
            return
        }
        dataStatus = Status()
        pendingDeletion = CacheRetention.confirmation(for: deletion, before: cutoff,
                                                      historyDays: Prefs.historyDays)
    }

    func confirmDelete() {
        pendingDeletion = nil
        let cutoff = Self.reportDate(deleteBefore)
        let deleted = retention.delete(before: cutoff)
        dataStatus = Status(message: "Deleted \(deleted.salesDays) days of sales and "
                            + "\(deleted.analyticsDays) days of analytics.")
        refreshCacheSummary()
        onPreferencesChanged?()  // Re-renders from what's left.
    }

    /// The date picker speaks the user's calendar; a report day is a calendar date with no zone.
    /// Converted by components, never by instant — an instant would shift the day for anyone far
    /// from Pacific.
    private static func reportDate(_ date: Date) -> ReportDate {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return ReportDate(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    private static func localDate(_ date: ReportDate) -> Date {
        Calendar.current.date(from: DateComponents(year: date.year, month: date.month,
                                                   day: date.day)) ?? Date()
    }

    // MARK: - Manual rates

    /// Currencies in the cache with no published rate and no peg. Supplied by the app, which is the
    /// half that knows what's in the cache.
    var unpricedCurrencies: (() -> [String])?

    /// One row per currency needing a rate, as typed.
    @Published private(set) var rateRows: [RateRow] = []

    struct RateRow: Identifiable, Equatable {
        let code: String
        var text: String
        var setAt: Date?
        /// The shown value is Vantage's built-in estimate, not something the user chose.
        var isEstimate: Bool
        var id: String { code }
    }

    private func loadRates() {
        let stored = Prefs.manualRates
        let dates = Prefs.manualRateDates
        // Every currency that needs a rate, plus any the user has already set — so removing an app
        // doesn't strand a rate somewhere it can't be edited.
        let needed = Set(unpricedCurrencies?() ?? []).union(stored.keys)
        rateRows = needed.sorted().map { code in
            // Pre-filled with the built-in estimate when the user hasn't set one, so the field
            // shows the number actually in use rather than being blank while a figure depends on it.
            let value = stored[code] ?? FXSeed.estimate(for: code)
            return RateRow(code: code,
                           text: value.map { "\($0)" } ?? "",
                           setAt: dates[code],
                           isEstimate: stored[code] == nil && FXSeed.estimate(for: code) != nil)
        }
    }

    func updateRate(_ code: String, text: String) {
        guard let index = rateRows.firstIndex(where: { $0.code == code }) else { return }
        rateRows[index].text = text
    }

    /// Commits one row. An empty or unparseable value clears the rate rather than storing zero —
    /// dividing by zero would turn a total into nonsense.
    func commitRate(_ code: String) {
        guard let index = rateRows.firstIndex(where: { $0.code == code }) else { return }
        let trimmed = rateRows[index].text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "")
        let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
        Prefs.setManualRate(value.flatMap { $0 > 0 ? $0 : nil }, for: code)
        rateRows[index].setAt = Prefs.manualRateDates[code]
        rateRows[index].isEstimate = Prefs.manualRates[code] == nil
            && FXSeed.estimate(for: code) != nil
        if value == nil || value! <= 0 {
            // Cleared. Falls back to the estimate, so the field shows what's actually in use.
            rateRows[index].text = FXSeed.estimate(for: code).map { "\($0)" } ?? ""
        }
        onPreferencesChanged?()
    }
    @Published private(set) var launchStatus = Status()

    // MARK: - Loading

    func load() {
        issuerID = KeychainStore.value(for: .issuerID) ?? ""
        keyID = KeychainStore.value(for: .keyID) ?? ""
        vendorNumber = KeychainStore.value(for: .vendorNumber) ?? ""
        reviewsIssuerID = KeychainStore.value(for: .reviewsIssuerID) ?? ""
        reviewsKeyID = KeychainStore.value(for: .reviewsKeyID) ?? ""
        displayCurrency = Prefs.displayCurrency
        morningNotification = Prefs.morningNotification
        repliesEnabled = Prefs.repliesEnabled
        rememberCredentials = Prefs.rememberCredentials
        launchAtLogin = LaunchAtLogin.isEnabled
        historyDays = Prefs.historyDays
        refreshCacheSummary()
        loadRates()
        refreshStates()
    }

    /// Per-field state, never a single summary line.
    ///
    /// A summary was actively misleading: after saving three of four values it said "Still missing:
    /// Vendor Number", which reads as "nothing saved" when the private key had stored fine.
    /// Per-field state can't lie about the fields it isn't talking about.
    private func refreshStates() {
        var next: [KeychainStore.Key: FieldState] = [:]
        for key in KeychainStore.Key.allCases {
            if KeychainStore.value(for: key) != nil {
                next[key] = .stored
            } else if (key == .privateKey && pendingPrivateKey != nil)
                || (key == .reviewsPrivateKey && pendingReviewsPrivateKey != nil) {
                next[key] = .staged
            } else {
                next[key] = key.isReviews ? .optional : .missing
            }
        }
        states = next
    }

    func state(_ key: KeychainStore.Key) -> FieldState { states[key] ?? .missing }

    var hasCredentials: Bool { KeychainStore.hasCredentials }
    var hasReviewsKey: Bool { KeychainStore.hasReviewsKey }

    // MARK: - The sales key

    func save() {
        KeychainStore.set(issuerID, for: .issuerID)
        KeychainStore.set(keyID, for: .keyID)
        KeychainStore.set(vendorNumber, for: .vendorNumber)
        if let pendingPrivateKey { KeychainStore.set(pendingPrivateKey, for: .privateKey) }
        pendingPrivateKey = nil
        refreshStates()

        // Whatever was entered is now saved — say so first. The old copy led with what was still
        // missing, which read as though the save itself had failed.
        //
        // Only the sales key's four values are required; `Key.allCases` also holds the three
        // optional reviews ones, and counting those told a perfect setup it was incomplete.
        let missing = KeychainStore.Key.allCases
            .filter { !$0.isReviews && KeychainStore.value(for: $0) == nil }
        if missing.isEmpty {
            salesStatus = Status(message: "Saved. Fetching your report…")
        } else {
            // Names the empty fields, never the filled ones' values.
            salesStatus = Status(message: "Saved what you entered. Still need: "
                                 + missing.map(Self.label).joined(separator: ", "))
        }
        onCredentialsChanged?()
    }

    func forget() {
        // Also clears the reviews key and, through the panel, the cached review text it made
        // readable. This is the button SECURITY.md advertises as removing everything.
        defer { onReviewsKeyChanged?() }
        KeychainStore.forgetAll()
        issuerID = ""
        keyID = ""
        vendorNumber = ""
        reviewsIssuerID = ""
        reviewsKeyID = ""
        pendingPrivateKey = nil
        pendingReviewsPrivateKey = nil
        refreshStates()
        salesStatus = Status(message: "Removed from Keychain.")
        reviewsStatus = Status()
        onCredentialsChanged?()
    }

    func choosePrivateKey() {
        guard let contents = readPrivateKey(into: &salesStatus) else { return }
        pendingPrivateKey = contents
        refreshStates()
        salesStatus = Status(message: "Key loaded. Press Save to store it in your Keychain.")
    }

    // MARK: - The reviews key

    func saveReviewsKey() {
        KeychainStore.set(reviewsIssuerID, for: .reviewsIssuerID)
        KeychainStore.set(reviewsKeyID, for: .reviewsKeyID)
        if let pendingReviewsPrivateKey {
            KeychainStore.set(pendingReviewsPrivateKey, for: .reviewsPrivateKey)
        }
        pendingReviewsPrivateKey = nil
        refreshStates()

        if KeychainStore.hasReviewsKey {
            reviewsStatus = Status(message: "Reviews key saved.")
        } else {
            let missing: [KeychainStore.Key] = [.reviewsIssuerID, .reviewsKeyID, .reviewsPrivateKey]
                .filter { KeychainStore.value(for: $0) == nil }
            reviewsStatus = Status(message: "Saved. Still needed: "
                                   + missing.map(Self.label).joined(separator: ", "))
        }
        onReviewsKeyChanged?()
    }

    func forgetReviewsKey() {
        KeychainStore.forgetReviewsKey()
        reviewsIssuerID = ""
        reviewsKeyID = ""
        pendingReviewsPrivateKey = nil
        refreshStates()
        reviewsStatus = Status(message: "Reviews key removed. Sales are unaffected.")
        onReviewsKeyChanged?()
    }

    func chooseReviewsPrivateKey() {
        guard let contents = readPrivateKey(into: &reviewsStatus) else { return }
        pendingReviewsPrivateKey = contents
        refreshStates()
        reviewsStatus = Status(message: "Key loaded. Press Save reviews key to store it.")
    }

    // MARK: - Test connection

    /// One real request, so setup ends with an answer instead of a guess. A 404 counts as working:
    /// it means Apple accepted the key and simply has no report for that date yet.
    func runTest() {
        guard hasCredentials else {
            salesStatus = Status(message: "Enter and save all four values first.", isError: true)
            return
        }
        isTesting = true
        salesStatus = Status(message: "Asking App Store Connect…")
        testConnection? { [weak self] result in
            guard let self else { return }
            self.isTesting = false
            switch result {
            case .success:
                self.salesStatus = Status(message: "Connected. App Store Connect accepted the key.")
            case .failure(let error):
                self.salesStatus = Status(
                    message: (error as? SalesError)?.errorDescription
                        ?? "Couldn't reach App Store Connect.",
                    isError: true)
            }
        }
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ wanted: Bool) {
        LaunchAtLogin.isEnabled = wanted
        // Read the real status back rather than trusting the click. Registration fails when the app
        // runs from a temporary or quarantined location — straight out of `build/`, typically — and
        // a switch that snaps back with no explanation looks like a bug.
        launchAtLogin = LaunchAtLogin.isEnabled
        if wanted, !launchAtLogin {
            launchStatus = Status(
                message: "macOS refused to register a login item. Move Vantage to /Applications "
                    + "and try again.",
                isError: true)
        } else {
            launchStatus = Status()
        }
    }

    // MARK: - Reading a .p8

    /// Picks and reads a `.p8`, reporting every way it can go wrong.
    ///
    /// Shared by both keys deliberately: the reviews picker must fail exactly as informatively as
    /// the sales one, and a second copy is a second copy to forget to fix.
    private func readPrivateKey(into status: inout Status) -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose your App Store Connect private key"
        panel.message = "The AuthKey_XXXXXXXXXX.p8 file you downloaded from App Store Connect."
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Deliberately no `allowedContentTypes`: `.p8` has no registered UTI, and constraining the
        // panel is a good way to grey out the one file the user came here to pick.

        guard panel.runModal() == .OK, let url = panel.url else {
            status = Status()  // Cancelled. Not a failure, and not worth a message.
            return nil
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            // Never silent. macOS can refuse a read of ~/Downloads or ~/Desktop, and a picker that
            // appears to do nothing is indistinguishable from a broken button.
            status = Status(message: "Couldn't read that file. Try moving it somewhere else and "
                            + "choosing again.", isError: true)
            return nil
        }
        // Read once, here, and keep only the contents. The path is deliberately not retained: the
        // file can be deleted or moved back into a password manager afterwards, and Vantage should
        // never reach for it again.
        guard contents.contains("PRIVATE KEY") else {
            status = Status(message: "That file isn't a private key — look for "
                            + "AuthKey_XXXXXXXXXX.p8.", isError: true)
            return nil
        }
        return contents
    }

    static func label(_ key: KeychainStore.Key) -> String {
        switch key {
        case .issuerID, .reviewsIssuerID: return "Issuer ID"
        case .keyID, .reviewsKeyID: return "Key ID"
        case .privateKey, .reviewsPrivateKey: return ".p8 key"
        case .vendorNumber: return "Vendor Number"
        }
    }
}
