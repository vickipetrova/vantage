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
                .tabItem { Label("Reviews", systemImage: "star.bubble") }
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        // A modest minimum, not the natural height: a grouped Form scrolls on its own, so the
        // window can be shrunk to fit a small display without any control becoming unreachable.
        .frame(minWidth: 500, minHeight: 380)
    }
}

// MARK: - Connection

private struct ConnectionTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                CredentialField(title: "Issuer ID", text: $model.issuerID,
                                placeholder: "00000000-0000-0000-0000-000000000000",
                                state: model.state(.issuerID))
                CredentialField(title: "Key ID", text: $model.keyID,
                                placeholder: "10 characters",
                                state: model.state(.keyID))
                LabeledContent("Private key") {
                    HStack(spacing: 8) {
                        Button("Choose .p8…") { model.choosePrivateKey() }
                        StateBadge(state: model.state(.privateKey))
                        Spacer(minLength: 0)
                    }
                }
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
                LabeledContent("Private key") {
                    HStack(spacing: 8) {
                        Button("Choose .p8…") { model.chooseReviewsPrivateKey() }
                        StateBadge(state: model.state(.reviewsPrivateKey))
                        Spacer(minLength: 0)
                    }
                }
                HStack(spacing: 8) {
                    Button("Save reviews key") { model.saveReviewsKey() }
                    Spacer(minLength: 0)
                    Button("Remove reviews key") { model.forgetReviewsKey() }
                        .disabled(!model.hasReviewsKey)
                }
                StatusLine(status: model.reviewsStatus)
            } header: {
                Text("Reviews key — optional")
            } footer: {
                Text("Reviews need a second key. The Sales and Reports key can't read them — Apple "
                     + "gates reviews behind a different role — and giving that key a bigger role "
                     + "would widen what it could do with your sales data. Create a separate key "
                     + "with the App Manager role, or leave this blank if you only want sales.")
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
            } footer: {
                Text("Proceeds are converted at the European Central Bank's daily rates and marked "
                     + "≈. Currencies the ECB doesn't publish are listed separately rather than "
                     + "dropped.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
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

/// One identifier field, with what the Keychain currently holds beside it.
private struct CredentialField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let state: SettingsModel.FieldState

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                StateBadge(state: state)
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
