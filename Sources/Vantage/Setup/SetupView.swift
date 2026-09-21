import SwiftUI
import VantageCore

/// One step at a time, with the context for that value beside it.
///
/// Not a `Form`: a grouped form is the right shape for a reference screen you scan, and the wrong
/// one for a sequence you walk through. This is a column — title, instruction, the one control
/// that step needs, and the buttons.
struct SetupView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.step.instruction)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundColor(.secondary)
                    control
                    if let link = model.link {
                        Button {
                            model.open(link)
                        } label: {
                            Label(link.label, systemImage: "arrow.up.forward.square")
                        }
                        .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 460)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress = model.progressLabel {
                Text(progress)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(model.step.title)
                .font(.title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - The one control this step needs

    @ViewBuilder
    private var control: some View {
        switch model.step {
        case .issuerID, .keyID, .vendorNumber, .reviewsIssuerID, .reviewsKeyID:
            VStack(alignment: .leading, spacing: 6) {
                TextField("", text: Binding(get: { model.fieldText },
                                            set: { model.fieldText = $0 }),
                          prompt: model.step.placeholder.map { Text($0) })
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 360)
                    .onSubmit { model.advance() }
                if let message = model.note.message {
                    // A warning, never a block. Continue stays enabled beneath it.
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .privateKey, .reviewsPrivateKey:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button("Choose .p8…") { model.chooseKeyFile() }
                    if model.keyFileLoaded {
                        Label("Loaded", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                if let status = model.keyFileStatus, model.keyFileStatusIsError {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .saveAndTest:
            testStatus

        case .createKey, .offerReviews, .done:
            EmptyView()
        }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch model.testState {
        case .idle, .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking App Store Connect…").foregroundColor(.secondary)
            }
        case .succeeded:
            Label("Connected.", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed(let message, _):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                // "Go back and fix it" only when the failure names a field worth returning to —
                // `canFixFromFailure` mirrors `SalesError.likelyStep`. A network drop, a rate
                // limit, a bad report or an agreement 403 aren't fixed by editing a credential,
                // and offering that button there would be a dead click; "Try again" alone is
                // honest about what retrying can do.
                if model.canFixFromFailure {
                    HStack(spacing: 8) {
                        Button("Go back and fix it") { model.retryFromFailure() }
                        Button("Try again") { model.testAgain() }
                    }
                } else {
                    Button("Try again") { model.testAgain() }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            // Nothing left to skip once setup has worked, and offering it there reads as
            // "undo what you just did".
            if model.step != .done {
                Button("Skip setup") { model.skip() }
                    .buttonStyle(.link)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            if model.canGoBack {
                Button("Back") { model.back() }
            }
            primaryButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch model.step {
        case .offerReviews:
            Button("Not now") { model.chooseReviews(false) }
            Button("Set it up") { model.chooseReviews(true) }
                .keyboardShortcut(.defaultAction)
        case .done:
            Button("Done") { model.finish() }
                .keyboardShortcut(.defaultAction)
        case .saveAndTest:
            EmptyView()  // The status area owns this screen's buttons.
        case .reviewsPrivateKey:
            Button("Save and finish") { model.advance() }
                .keyboardShortcut(.defaultAction)
        case .vendorNumber:
            Button("Save and test") { model.advance() }
                .keyboardShortcut(.defaultAction)
        default:
            Button("Continue") { model.advance() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
