import AppKit
import VantageCore

/// Credentials and preferences. Programmatic AppKit — no storyboard, no nib, so the whole window
/// is readable in one file.
///
/// This is the only place credentials are ever entered. Values go straight from these fields into
/// the Keychain; nothing here writes them to a log, a preference, or a file. The `.p8` field shows
/// a status line rather than the key text, so the private key is never rendered on screen and never
/// ends up in a screenshot attached to a bug report.
final class SettingsWindow: NSObject, NSWindowDelegate {
    /// Called after credentials change, so the app can retry a fetch immediately.
    var onCredentialsChanged: (() -> Void)?

    /// Called when a display preference changes — no refetch needed, everything is recomputed
    /// from the cache.
    var onPreferencesChanged: (() -> Void)?

    /// Makes one real request and reports whether it worked. Injected rather than built here so
    /// this window stays a form and knows nothing about App Store Connect.
    var testConnection: ((@escaping (Result<Void, Error>) -> Void) -> Void)?

    private var window: NSWindow?

    private let issuerField = NSTextField()
    private let keyIDField = NSTextField()
    private let vendorField = NSTextField()
    private let saveStatus = NSTextField(labelWithString: "")
    private let chooseKeyButton = NSButton()
    private let currencyPopUp = NSPopUpButton()
    private let notifyCheckbox = NSButton()
    private let launchCheckbox = NSButton()
    private let testButton = NSButton()

    // The optional reviews key. Separate fields, separate Keychain items, separate role — see
    // SECURITY.md. No vendor number: the reviews endpoints don't take one.
    private let reviewsIssuerField = NSTextField()
    private let reviewsKeyIDField = NSTextField()
    private let chooseReviewsKeyButton = NSButton()
    private let reviewsStatus = NSTextField(labelWithString: "")
    private var pendingReviewsPrivateKey: String?

    /// Called when the reviews key is added or removed, so the panel stops showing a stale state.
    var onReviewsKeyChanged: (() -> Void)?

    /// One status label per credential, showing what the Keychain actually holds right now.
    ///
    /// Four separate indicators rather than one summary line, because the summary line was
    /// actively misleading: after saving three of four values it said "Still missing: Vendor
    /// Number" in red, which reads as "nothing saved" when in fact the private key had stored
    /// fine. Per-field state can't lie about the fields it isn't talking about.
    private var indicators: [KeychainStore.Key: NSTextField] = [:]

    /// Held only between choosing the file and pressing Save.
    private var pendingPrivateKey: String?

    func show() {
        if window == nil { build() }
        loadFromKeychain()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 860),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Vantage Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(heading("App Store Connect"))
        stack.addArrangedSubview(caption(
            "All four values are required. Create the key with the Sales and Reports role — "
            + "Vantage never needs an Admin key."))

        // A borderless link rather than a button: an inline-bezel button on the window background
        // reads as disabled, and this is a pointer to Apple's docs, not an action of the app's.
        let help = NSButton(title: "", target: self, action: #selector(openAppleHelp))
        help.isBordered = false
        help.attributedTitle = NSAttributedString(
            string: "How to create an API key…",
            attributes: [
                .foregroundColor: NSColor.linkColor,
                .font: NSFont.systemFont(ofSize: 11),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
        stack.addArrangedSubview(help)

        stack.addArrangedSubview(field("Issuer ID", issuerField, .issuerID,
                                       placeholder: "57246542-96fe-1a63-e053-0824d011072a"))
        stack.addArrangedSubview(field("Key ID", keyIDField, .keyID, placeholder: "2X9R4HXF34"))
        stack.addArrangedSubview(caption(
            "Both are on the Users and Access › Integrations page. The Issuer ID is at the top of "
            + "that page; the Key ID is the column next to your key's name."))

        chooseKeyButton.title = "Choose .p8 file…"
        chooseKeyButton.target = self
        chooseKeyButton.action = #selector(choosePrivateKey)
        chooseKeyButton.bezelStyle = .rounded
        stack.addArrangedSubview(labelled("Private key", chooseKeyButton, .privateKey))

        stack.addArrangedSubview(field("Vendor Number", vendorField, .vendorNumber,
                                       placeholder: "8-digit number"))
        stack.addArrangedSubview(caption(
            "App Store Connect › Payments and Financial Reports › Reports — top left, under your "
            + "Legal Entity Name."))

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let forget = NSButton(title: "Forget credentials", target: self, action: #selector(forget))
        forget.bezelStyle = .rounded
        testButton.title = "Test connection"
        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(runTest)
        buttons.addArrangedSubview(save)
        buttons.addArrangedSubview(testButton)
        buttons.addArrangedSubview(forget)
        stack.addArrangedSubview(buttons)

        saveStatus.font = .systemFont(ofSize: 11)
        saveStatus.textColor = .secondaryLabelColor
        saveStatus.lineBreakMode = .byWordWrapping
        saveStatus.maximumNumberOfLines = 3
        saveStatus.preferredMaxLayoutWidth = 400
        stack.addArrangedSubview(saveStatus)

        // MARK: Reviews key

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Reviews key (optional)"))
        stack.addArrangedSubview(caption(
            "Reviews need a second App Store Connect key. The Sales and Reports key above can't "
            + "read them — Apple gates reviews behind a different role — and giving that key a "
            + "bigger role would widen what it could do with your sales data. Create a separate "
            + "key with the App Manager role. Leave this blank if you only want sales."))

        stack.addArrangedSubview(field("Issuer ID", reviewsIssuerField, .reviewsIssuerID,
                                       placeholder: "Same Issuer ID as above"))
        stack.addArrangedSubview(field("Key ID", reviewsKeyIDField, .reviewsKeyID,
                                       placeholder: "10 characters"))
        chooseReviewsKeyButton.title = "Choose .p8…"
        chooseReviewsKeyButton.target = self
        chooseReviewsKeyButton.action = #selector(chooseReviewsPrivateKey)
        chooseReviewsKeyButton.bezelStyle = .rounded
        stack.addArrangedSubview(labelled("Private key", chooseReviewsKeyButton,
                                          .reviewsPrivateKey))

        let reviewsButtons = NSStackView()
        reviewsButtons.orientation = .horizontal
        reviewsButtons.spacing = 10
        let saveReviews = NSButton(title: "Save reviews key", target: self,
                                   action: #selector(saveReviewsKey))
        saveReviews.bezelStyle = .rounded
        let forgetReviews = NSButton(title: "Remove reviews key", target: self,
                                     action: #selector(forgetReviewsKey))
        forgetReviews.bezelStyle = .rounded
        reviewsButtons.addArrangedSubview(saveReviews)
        reviewsButtons.addArrangedSubview(forgetReviews)
        stack.addArrangedSubview(reviewsButtons)

        reviewsStatus.font = .systemFont(ofSize: 11)
        reviewsStatus.textColor = .secondaryLabelColor
        reviewsStatus.lineBreakMode = .byWordWrapping
        reviewsStatus.maximumNumberOfLines = 3
        reviewsStatus.preferredMaxLayoutWidth = 400
        stack.addArrangedSubview(reviewsStatus)

        // MARK: Display

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Display"))

        currencyPopUp.addItems(withTitles: Prefs.selectableCurrencies)
        currencyPopUp.target = self
        currencyPopUp.action = #selector(currencyChanged)
        stack.addArrangedSubview(labelled("Currency", currencyPopUp, nil))
        stack.addArrangedSubview(caption(
            "Proceeds are converted at the European Central Bank's daily rates and marked ≈. "
            + "Currencies the ECB doesn't publish are listed separately rather than dropped."))

        notifyCheckbox.setButtonType(.switch)
        notifyCheckbox.title = "Notify me when a new report lands"
        notifyCheckbox.target = self
        notifyCheckbox.action = #selector(notifyToggled)
        stack.addArrangedSubview(notifyCheckbox)

        launchCheckbox.setButtonType(.switch)
        launchCheckbox.title = "Launch at login"
        launchCheckbox.target = self
        launchCheckbox.action = #selector(launchToggled)
        stack.addArrangedSubview(launchCheckbox)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        window.contentView = content
        self.window = window
    }

    private func heading(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func caption(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 400
        return label
    }

    private func field(_ title: String, _ input: NSTextField, _ key: KeychainStore.Key,
                       placeholder: String) -> NSView {
        input.placeholderString = placeholder
        input.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        input.widthAnchor.constraint(equalToConstant: 250).isActive = true
        return labelled(title, input, key)
    }

    private func labelled(_ title: String, _ control: NSView,
                          _ key: KeychainStore.Key?) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 96).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(control)

        if let key {
            let indicator = NSTextField(labelWithString: "")
            indicator.font = .systemFont(ofSize: 11)
            indicator.lineBreakMode = .byTruncatingTail
            indicators[key] = indicator
            row.addArrangedSubview(indicator)
        }
        return row
    }

    /// Repaints all four indicators from the Keychain, plus whatever is staged but unsaved.
    private func refreshIndicators() {
        for key in KeychainStore.Key.allCases {
            guard let indicator = indicators[key] else { continue }
            if key == .privateKey, pendingPrivateKey != nil,
               KeychainStore.value(for: key) == nil {
                indicator.stringValue = "Ready to save"
                indicator.textColor = .secondaryLabelColor
            } else if KeychainStore.value(for: key) != nil {
                indicator.stringValue = "✓ Stored"
                indicator.textColor = .systemGreen
            } else {
                indicator.stringValue = "Needed"
                indicator.textColor = .secondaryLabelColor
            }
        }
        chooseKeyButton.title = KeychainStore.value(for: .privateKey) == nil
            ? "Choose .p8 file…" : "Replace .p8 file…"
    }

    // MARK: - Loading and saving

    /// Reads back what's stored, so an open window reflects reality. The private key is reported as
    /// present or absent — never displayed.
    private func loadFromKeychain() {
        issuerField.stringValue = KeychainStore.value(for: .issuerID) ?? ""
        keyIDField.stringValue = KeychainStore.value(for: .keyID) ?? ""
        reviewsIssuerField.stringValue = KeychainStore.value(for: .reviewsIssuerID) ?? ""
        reviewsKeyIDField.stringValue = KeychainStore.value(for: .reviewsKeyID) ?? ""
        vendorField.stringValue = KeychainStore.value(for: .vendorNumber) ?? ""
        saveStatus.stringValue = ""
        pendingPrivateKey = nil
        refreshIndicators()

        currencyPopUp.selectItem(withTitle: Prefs.displayCurrency)
        if currencyPopUp.indexOfSelectedItem < 0 {
            // A display currency the ECB doesn't publish can't be converted into, so it isn't
            // offered — fall back visibly rather than showing a blank menu.
            currencyPopUp.selectItem(withTitle: "USD")
            Prefs.displayCurrency = "USD"
        }
        notifyCheckbox.state = Prefs.morningNotification ? .on : .off
        launchCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    @objc private func choosePrivateKey() {
        guard let contents = readPrivateKey() else { return }
        pendingPrivateKey = contents
        refreshIndicators()
        report("Key loaded. Press Save to store it in your Keychain.")
    }

    /// Picks and reads a `.p8`, reporting every way it can go wrong.
    ///
    /// Shared by both keys deliberately: the reviews picker must fail exactly as informatively as
    /// the sales one, and a second copy is a second copy to forget to fix.
    private func readPrivateKey() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose your App Store Connect private key"
        panel.message = "The AuthKey_XXXXXXXXXX.p8 file you downloaded from App Store Connect."
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Deliberately no `allowedContentTypes`: `.p8` has no registered UTI, and constraining the
        // panel is a good way to grey out the one file the user came here to pick.

        guard panel.runModal() == .OK, let url = panel.url else {
            report("")  // Cancelled. Not a failure, and not worth a message.
            return nil
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            // Never silent. macOS can refuse a read of ~/Downloads or ~/Desktop, and a picker that
            // appears to do nothing is indistinguishable from a broken button.
            report("Couldn't read that file. Try moving it somewhere else and choosing again.",
                   isError: true)
            return nil
        }

        // Read once, here, and keep only the contents. The path is deliberately not retained: the
        // file can be deleted or moved back into a password manager afterwards, and Vantage should
        // never reach for it again.
        guard contents.contains("PRIVATE KEY") else {
            report("That file isn't a private key — look for AuthKey_XXXXXXXXXX.p8.", isError: true)
            return nil
        }
        return contents
    }

    // MARK: - The reviews key

    @objc private func chooseReviewsPrivateKey() {
        guard let contents = readPrivateKey() else { return }
        pendingReviewsPrivateKey = contents
        refreshIndicators()
        reviewsStatus.stringValue = "Key loaded. Press Save reviews key to store it."
        reviewsStatus.textColor = .secondaryLabelColor
    }

    @objc private func saveReviewsKey() {
        KeychainStore.set(reviewsIssuerField.stringValue, for: .reviewsIssuerID)
        KeychainStore.set(reviewsKeyIDField.stringValue, for: .reviewsKeyID)
        if let pendingReviewsPrivateKey {
            KeychainStore.set(pendingReviewsPrivateKey, for: .reviewsPrivateKey)
        }
        pendingReviewsPrivateKey = nil
        refreshIndicators()

        if KeychainStore.hasReviewsKey {
            reviewsStatus.stringValue = "Reviews key saved."
            reviewsStatus.textColor = .secondaryLabelColor
        } else {
            let missing = [KeychainStore.Key.reviewsIssuerID, .reviewsKeyID, .reviewsPrivateKey]
                .filter { KeychainStore.value(for: $0) == nil }
                .map(label)
            reviewsStatus.stringValue = "Saved. Still needed: \(missing.joined(separator: ", "))."
            reviewsStatus.textColor = .secondaryLabelColor
        }
        onReviewsKeyChanged?()
    }

    @objc private func forgetReviewsKey() {
        KeychainStore.forgetReviewsKey()
        reviewsIssuerField.stringValue = ""
        reviewsKeyIDField.stringValue = ""
        pendingReviewsPrivateKey = nil
        refreshIndicators()
        // Cached review text goes with the key that made it readable — see PanelModel.
        reviewsStatus.stringValue = "Reviews key removed. Sales are unaffected."
        reviewsStatus.textColor = .secondaryLabelColor
        onReviewsKeyChanged?()
    }

    @objc private func save() {
        KeychainStore.set(issuerField.stringValue, for: .issuerID)
        KeychainStore.set(keyIDField.stringValue, for: .keyID)
        KeychainStore.set(vendorField.stringValue, for: .vendorNumber)
        if let pendingPrivateKey {
            KeychainStore.set(pendingPrivateKey, for: .privateKey)
        }
        pendingPrivateKey = nil
        refreshIndicators()

        // Whatever was entered is now saved — say so first. The old copy led with what was still
        // missing, which read as though the save itself had failed.
        let missing = KeychainStore.Key.allCases.filter { KeychainStore.value(for: $0) == nil }
        if missing.isEmpty {
            report("Saved. Fetching your report…")
        } else {
            // Names the empty fields, never the filled ones' values.
            report("Saved what you entered. Still need: "
                   + missing.map(label).joined(separator: ", "))
        }
        onCredentialsChanged?()
    }

    @objc private func forget() {
        KeychainStore.forgetAll()
        issuerField.stringValue = ""
        keyIDField.stringValue = ""
        vendorField.stringValue = ""
        pendingPrivateKey = nil
        refreshIndicators()
        report("Removed from Keychain.")
        onCredentialsChanged?()
    }

    private func report(_ message: String, isError: Bool = false) {
        saveStatus.stringValue = message
        saveStatus.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    // MARK: - Test connection

    /// One real request, so setup ends with an answer instead of a guess. A 404 counts as working:
    /// it means Apple accepted the key and simply has no report for that date yet.
    @objc private func runTest() {
        guard KeychainStore.hasCredentials else {
            report("Enter and save all four values first.", isError: true)
            return
        }
        testButton.isEnabled = false
        report("Asking App Store Connect…")
        testConnection? { [weak self] result in
            guard let self else { return }
            self.testButton.isEnabled = true
            switch result {
            case .success:
                self.report("Connected. App Store Connect accepted the key.")
            case .failure(let error):
                self.report((error as? SalesError)?.errorDescription
                            ?? "Couldn't reach App Store Connect.", isError: true)
            }
        }
    }

    // MARK: - Display preferences

    @objc private func currencyChanged() {
        guard let selected = currencyPopUp.titleOfSelectedItem else { return }
        Prefs.displayCurrency = selected
        onPreferencesChanged?()
    }

    @objc private func notifyToggled() {
        Prefs.morningNotification = notifyCheckbox.state == .on
        onPreferencesChanged?()
    }

    @objc private func launchToggled() {
        let wanted = launchCheckbox.state == .on
        LaunchAtLogin.isEnabled = wanted
        // Read the real status back rather than trusting the click. Registration fails when the app
        // runs from a temporary or quarantined location — straight out of `build/`, typically — and
        // a checkbox that snaps back with no explanation looks like a bug.
        launchCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
        if wanted, launchCheckbox.state == .off {
            report("macOS refused to register a login item. Move Vantage to /Applications and "
                   + "try again.", isError: true)
        }
    }

    private func label(_ key: KeychainStore.Key) -> String {
        switch key {
        case .issuerID, .reviewsIssuerID: return "Issuer ID"
        case .keyID, .reviewsKeyID: return "Key ID"
        case .privateKey, .reviewsPrivateKey: return ".p8 key"
        case .vendorNumber: return "Vendor Number"
        }
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 400).isActive = true
        return box
    }

    @objc private func openAppleHelp() {
        guard let url = URL(string:
            "https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
