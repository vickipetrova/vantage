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

    private var window: NSWindow?

    private let issuerField = NSTextField()
    private let keyIDField = NSTextField()
    private let vendorField = NSTextField()
    private let saveStatus = NSTextField(labelWithString: "")
    private let chooseKeyButton = NSButton()

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
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
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
        buttons.addArrangedSubview(save)
        buttons.addArrangedSubview(forget)
        buttons.addArrangedSubview(saveStatus)
        saveStatus.font = .systemFont(ofSize: 11)
        saveStatus.textColor = .secondaryLabelColor
        stack.addArrangedSubview(buttons)

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
                          _ key: KeychainStore.Key) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let indicator = NSTextField(labelWithString: "")
        indicator.font = .systemFont(ofSize: 11)
        indicator.lineBreakMode = .byTruncatingTail
        indicators[key] = indicator

        row.addArrangedSubview(label)
        row.addArrangedSubview(control)
        row.addArrangedSubview(indicator)
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
        vendorField.stringValue = KeychainStore.value(for: .vendorNumber) ?? ""
        saveStatus.stringValue = ""
        pendingPrivateKey = nil
        refreshIndicators()
    }

    @objc private func choosePrivateKey() {
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
            return
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            // Never silent. macOS can refuse a read of ~/Downloads or ~/Desktop, and a picker that
            // appears to do nothing is indistinguishable from a broken button.
            report("Couldn't read that file. Try moving it somewhere else and choosing again.",
                   isError: true)
            return
        }

        // Read once, here, and keep only the contents. The path is deliberately not retained: the
        // file can be deleted or moved back into a password manager afterwards, and Vantage should
        // never reach for it again.
        guard contents.contains("PRIVATE KEY") else {
            report("That file isn't a private key — look for AuthKey_XXXXXXXXXX.p8.", isError: true)
            return
        }
        pendingPrivateKey = contents
        refreshIndicators()
        report("Key loaded. Press Save to store it in your Keychain.")
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

    private func label(_ key: KeychainStore.Key) -> String {
        switch key {
        case .issuerID: return "Issuer ID"
        case .keyID: return "Key ID"
        case .privateKey: return ".p8 key"
        case .vendorNumber: return "Vendor Number"
        }
    }

    @objc private func openAppleHelp() {
        guard let url = URL(string:
            "https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
