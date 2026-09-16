import SwiftUI
import VantageCore

/// Settings, as three tabs of grouped forms.
///
/// The old window was one 860pt column of fields and paragraphs with no grouping, which meant the
/// four values that are *required* sat in the same undifferentiated run as an optional second key
/// and three display preferences. Splitting it means each tab answers one question, and
/// `.formStyle(.grouped)` gives the same rounded-group look as System Settings without hand-drawing
/// any of it.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            ConnectionTab(model: model)
                .tabItem { Label("App Store Connect", systemImage: "key") }
            ReviewsTab(model: model)
                .tabItem { Label("Reviews & Analytics", systemImage: "star.bubble") }
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        // A modest minimum, not the natural height: a grouped Form scrolls on its own, so the
        // window can be shrunk to fit a small display without any control becoming unreachable.
        // The width is not modest: below it the credential rows' fixed columns no longer fit beside
        // "Vendor Number", and the field drops onto a line of its own.
        .frame(minWidth: 580, minHeight: 380)
    }
}

// MARK: - Connection

private struct ConnectionTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                CredentialField(title: "Issuer ID", text: $model.issuerID,
                                placeholder: "UUID",
                                state: model.state(.issuerID))
                CredentialField(title: "Key ID", text: $model.keyID,
                                placeholder: "10 characters",
                                state: model.state(.keyID))
                KeyFileRow(state: model.state(.privateKey)) { model.choosePrivateKey() }
                CredentialField(title: "Vendor Number", text: $model.vendorNumber,
                                placeholder: "8-digit number",
                                state: model.state(.vendorNumber))
            } header: {
                Text("Credentials")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The Issuer ID and Key ID are both on Users and Access › Integrations — "
                         + "the Issuer ID at the top, the Key ID beside your key's name. The "
                         + "Vendor Number is under Payments and Financial Reports › Reports.")
                    Link("How to create an API key…",
                         destination: URL(string: "https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api")!)
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack(spacing: 8) {
                    Button("Save") { model.save() }
                        .keyboardShortcut(.defaultAction)
                    Button(model.isTesting ? "Testing…" : "Test connection") { model.runTest() }
                        .disabled(model.isTesting)
                    Spacer(minLength: 0)
                    Button("Forget credentials") { model.forget() }
                }
                StatusLine(status: model.salesStatus)
            } footer: {
                Text("Vantage needs a key with read-only access to Sales and Trends. Don't reuse "
                     + "an Admin key — this is the one decision that determines what the key could "
                     + "do if it leaked.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Belongs here rather than in General: it is a question about the credentials above,
            // and this is the pane that opens by itself on first launch, so it's the closest thing
            // to an onboarding step until the first-run walkthrough in CLAUDE.md exists.
            Section {
                Toggle("Stay unlocked while Vantage is running", isOn: $model.rememberCredentials)
            } header: {
                Text("Keychain")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("On, macOS asks for your password once per launch and Vantage keeps the "
                         + "credentials in memory until you quit. Off, every request reads the "
                         + "Keychain again, so a key never outlives the request that used it — "
                         + "more private, and more prompts.")
                    Text("Either way your credentials live in one Keychain item, so it is one "
                         + "prompt rather than one per value. Choosing Always Allow stops the "
                         + "prompts entirely — though not for a build from source, whose signature "
                         + "changes every time it is rebuilt.")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Reviews

private struct ReviewsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                CredentialField(title: "Issuer ID", text: $model.reviewsIssuerID,
                                placeholder: "Usually the same as above",
                                state: model.state(.reviewsIssuerID))
                CredentialField(title: "Key ID", text: $model.reviewsKeyID,
                                placeholder: "10 characters",
                                state: model.state(.reviewsKeyID))
                KeyFileRow(state: model.state(.reviewsPrivateKey)) {
                    model.chooseReviewsPrivateKey()
                }
                HStack(spacing: 8) {
                    Button("Save reviews key") { model.saveReviewsKey() }
                    Spacer(minLength: 0)
                    Button("Remove reviews key") { model.forgetReviewsKey() }
                        .disabled(!model.hasReviewsKey)
                }
                StatusLine(status: model.reviewsStatus)
            } header: {
                Text("Reviews & Analytics key — optional")
            } footer: {
                Text("One key powers both the Reviews and Analytics sections. The Sales and "
                     + "Reports key above can't read either — Apple gates them behind different "
                     + "roles — and giving that key a bigger role would widen what it could do "
                     + "with your sales data.\n\n"
                     + "App Manager is enough to read reviews. Analytics needs Admin, because "
                     + "Apple requires an Admin key to start generating a report — and its first "
                     + "report arrives 24 to 48 hours later. Leave this blank if you only want "
                     + "sales.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Enable replying to reviews", isOn: $model.repliesEnabled)
            } header: {
                Text("Replying")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Requires an Admin key, not the App Manager key above. An Admin key can "
                         + "change pricing, submit and remove builds, manage users, and read your "
                         + "financial reports.")
                    Text("There is one reviews key, so switching this on means putting an Admin "
                         + "key in the field above — and every routine review fetch will then "
                         + "carry it too, not just the replies.")
                    Text("Nothing is ever published without you confirming the exact text first.")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Display currency", selection: $model.displayCurrency) {
                    ForEach(Prefs.selectableCurrencies, id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text("Currency")
            } footer: {
                Text("Proceeds are converted at the European Central Bank's daily rates and marked "
                     + "≈. Currencies the ECB doesn't publish are listed separately rather than "
                     + "dropped.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.rateRows.isEmpty {
                Section {
                    ForEach(model.rateRows) { row in
                        ManualRateRow(model: model, row: row)
                    }
                } header: {
                    Text("Currencies with no published rate")
                } footer: {
                    Text("Apple pays in about 45 currencies; the European Central Bank publishes "
                         + "rates for 30 of them. AED, SAR and QAR are fixed by their central banks "
                         + "and convert exactly. The rest float, so Vantage starts from a rough "
                         + "estimate (\(FXSeed.asOf)) to keep the money in your totals — but an "
                         + "estimate drifts. Set a real one here and it's used instead, and every "
                         + "figure it touches says whose number it is.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            DataSection(model: model)

            Section {
                Picker("Menu bar shows", selection: $model.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Notify me when a new report lands", isOn: $model.morningNotification)
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                StatusLine(status: model.launchStatus)
            } header: {
                Text("Behaviour")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Pieces

/// How far back to fetch, what's on disk, and deleting the older part of it.
private struct DataSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section {
            Picker("History to fetch", selection: $model.historyDays) {
                ForEach(Prefs.historyChoices, id: \.self) { days in
                    Text(Self.label(days)).tag(days)
                }
            }
            LabeledContent("Cached") {
                Text(model.cacheSummary)
                    .foregroundColor(.secondary)
            }
            LabeledContent("Delete data older than") {
                HStack(spacing: 8) {
                    DatePicker("", selection: $model.deleteBefore, displayedComponents: .date)
                        .labelsHidden()
                    Button("Delete…") { model.requestDelete() }
                }
            }
            StatusLine(status: model.dataStatus)
        } header: {
            Text("Data")
        } footer: {
            Text("Vantage keeps everything it fetches. Apple deletes sales reports after a year and "
                 + "analytics after 35 days, so past that Vantage's copy is the only one — and it's "
                 + "what vantage-cli and AI agents read. A year of history is about 2 MB.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert("Delete cached data?", isPresented: Binding(
            get: { model.pendingDeletion != nil },
            set: { if !$0 { model.pendingDeletion = nil } })) {
            Button("Delete", role: .destructive) { model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.pendingDeletion = nil }
        } message: {
            Text(model.pendingDeletion ?? "")
        }
    }

    private static func label(_ days: Int) -> String {
        switch days {
        case ReportStore.appleRetentionDays: return "1 year (Apple's maximum)"
        case 180: return "6 months"
        default: return "\(days) days"
        }
    }
}

/// A rate the user supplies for a currency nothing publishes one for.
///
/// Whose number it is goes under the code, as the row's subtitle, so the controls on the right keep
/// one width and line up down the section whatever the note says.
private struct ManualRateRow: View {
    @ObservedObject var model: SettingsModel
    let row: SettingsModel.RateRow

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                // Title empty and the hint as a prompt: in a grouped form a text field's title is
                // drawn as a label beside it, which is what used to wrap "per US dollar" onto two
                // lines and push every field to a different x.
                TextField("", text: Binding(
                    get: { row.text },
                    set: { model.updateRate(row.code, text: $0) }),
                    prompt: Text("Rate"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: SettingsColumn.rate)
                    // Committed on Return and on losing focus, so a typed rate can't sit
                    // uncommitted while the panel shows the old figure.
                    .onSubmit { model.commitRate(row.code) }
                Text("per USD")
                    .foregroundColor(.secondary)
                    .fixedSize()
                Button("Set") { model.commitRate(row.code) }
            }
        } label: {
            Text(row.code)
            // A hand-typed rate for a floating currency drifts silently. The date is the only thing
            // that makes that visible.
            if let setAt = row.setAt {
                Text("Set \(Fmt.relative(setAt))")
            } else if row.isEstimate {
                Text("Vantage's estimate").foregroundColor(.orange)
            } else {
                Text("Not set")
            }
        }
    }
}

/// Fixed widths for the right-hand controls, so fields, buttons and badges line up from row to row
/// and from tab to tab instead of each row sizing itself.
private enum SettingsColumn {
    /// Wide enough for a whole Issuer ID — a UUID cut off at the end can't be checked by eye.
    static let field: CGFloat = 280
    static let badge: CGFloat = 80
    static let rate: CGFloat = 90
}

/// The `.p8` row, laid out on the same columns as the text fields above and below it.
private struct KeyFileRow: View {
    let state: SettingsModel.FieldState
    let choose: () -> Void

    var body: some View {
        LabeledContent("Private key") {
            HStack(spacing: 8) {
                Button("Choose .p8…", action: choose)
                    .frame(width: SettingsColumn.field, alignment: .leading)
                StateBadge(state: state)
                    .frame(width: SettingsColumn.badge, alignment: .leading)
            }
        }
    }
}

/// One identifier field, with what the Keychain currently holds beside it.
private struct CredentialField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let state: SettingsModel.FieldState

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                // Hint as a prompt, not a title — a title is drawn beside the field in a grouped
                // form, and a long one wrapped and shoved the field onto its own line.
                TextField("", text: $text, prompt: Text(placeholder))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    // A grouped form right-aligns fields by default; an identifier reads, and is
                    // compared against App Store Connect, from its start.
                    .multilineTextAlignment(.leading)
                    .frame(width: SettingsColumn.field)
                StateBadge(state: state)
                    .frame(width: SettingsColumn.badge, alignment: .leading)
            }
        }
    }
}

/// A small capsule saying what's stored, rather than a word floating beside a field.
private struct StateBadge: View {
    let state: SettingsModel.FieldState

    var body: some View {
        Text(state.label)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .fixedSize()
            .accessibilityLabel("\(state.label)")
    }

    private var color: Color {
        switch state {
        case .stored: return .green
        case .staged: return .accentColor
        // Not red. A value you haven't entered yet is a step remaining, not an error — and the
        // reviews fields are legitimately empty for most people.
        case .missing, .optional: return .secondary
        }
    }
}

private struct StatusLine: View {
    let status: SettingsModel.Status

    var body: some View {
        if !status.isEmpty {
            Text(status.message)
                .font(.caption)
                .foregroundColor(status.isError ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
