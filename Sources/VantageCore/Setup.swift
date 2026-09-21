import Foundation

/// One screen of first-run setup.
///
/// The copy lives here rather than in the view for the reason every displayed figure does: a view
/// that composes its own strings is a string nothing can test. The raw values are the order.
public enum SetupStep: Int, CaseIterable, Equatable {
    case createKey = 1
    case issuerID
    case keyID
    case privateKey
    case vendorNumber
    case saveAndTest
    case offerReviews
    case reviewsIssuerID
    case reviewsKeyID
    case reviewsPrivateKey
    case done

    /// The Keychain field this step fills in, if it takes a value at all.
    public var field: KeychainStore.Key? {
        switch self {
        case .issuerID: return .issuerID
        case .keyID: return .keyID
        case .privateKey: return .privateKey
        case .vendorNumber: return .vendorNumber
        case .reviewsIssuerID: return .reviewsIssuerID
        case .reviewsKeyID: return .reviewsKeyID
        case .reviewsPrivateKey: return .reviewsPrivateKey
        case .createKey, .saveAndTest, .offerReviews, .done: return nil
        }
    }

    /// Where the user is, counted only along the path already committed to.
    ///
    /// The whole flow's length isn't known until the offer is answered, and a counter reading
    /// "of 10" to someone about to press "Not now" is counting a path they haven't chosen. The
    /// three outcome screens carry no counter: they're results, not work remaining.
    public var progress: (index: Int, total: Int)? {
        switch self {
        case .createKey, .issuerID, .keyID, .privateKey, .vendorNumber:
            return (rawValue, 5)
        case .reviewsIssuerID, .reviewsKeyID, .reviewsPrivateKey:
            return (rawValue - SetupStep.offerReviews.rawValue, 3)
        case .saveAndTest, .offerReviews, .done:
            return nil
        }
    }

    public var title: String {
        switch self {
        case .createKey: return "Create a read-only key"
        case .issuerID: return "Issuer ID"
        case .keyID: return "Key ID"
        case .privateKey: return "The .p8 file"
        case .vendorNumber: return "Vendor Number"
        case .saveAndTest: return "Checking your key"
        case .offerReviews: return "Reviews and engagement"
        case .reviewsIssuerID: return "Reviews Issuer ID"
        case .reviewsKeyID: return "Reviews Key ID"
        case .reviewsPrivateKey: return "The reviews .p8 file"
        case .done: return "You're set up"
        }
    }

    public var instruction: String {
        switch self {
        case .createKey:
            return """
            Vantage reads your sales through App Store Connect's API, which needs a key you \
            generate yourself.

            Open Users and Access › Integrations › App Store Connect API and press +. Name it \
            anything — "Vantage" works.

            Give it the Sales and Reports role. Not Admin. This is the one choice that decides \
            what the key could do if it ever leaked, and Sales and Reports can do nothing but \
            read the numbers you're about to look at.

            Download the .p8 file when App Store Connect offers it. It downloads once. Apple will \
            not give it to you a second time — if you lose it you revoke the key and start over.
            """
        case .issuerID:
            return """
            At the top of that same page, above the list of keys, labelled Issuer ID. It's a UUID \
            — letters, numbers and dashes. It's the same for every key your team ever makes.
            """
        case .keyID:
            return """
            In your new key's row, under Key ID. Ten characters.

            It's also in the filename of the .p8 you just downloaded — AuthKey_2X9R4HXF34.p8 \
            means the Key ID is 2X9R4HXF34.
            """
        case .privateKey:
            return """
            The AuthKey_….p8 you downloaded a moment ago — probably in your Downloads folder.

            Vantage reads it once, copies the contents into your Keychain, and never opens the \
            file again. You can move it into a password manager afterwards, or delete it, and \
            Vantage will carry on working.
            """
        case .vendorNumber:
            return """
            This one lives somewhere else. Go to Payments and Financial Reports › Reports — the \
            Vendor Number is on that page. Eight digits.

            It identifies who gets paid, which is a different question from who's allowed to ask, \
            so Apple keeps it in a different place.
            """
        case .saveAndTest:
            return """
            Saved to your Keychain. Asking App Store Connect whether it accepts the key…
            """
        case .offerReviews:
            return """
            Also want your reviews, and the impressions and page views on the Overview? Those \
            need a second key — Apple gates them behind a different role, and giving your sales \
            key that role would widen what it could do with your sales data.

            Apple takes 24 to 48 hours to start an analytics report, and it only produces days \
            from the day you ask. Starting now is history you'd otherwise lose.
            """
        case .reviewsIssuerID:
            return """
            Make a second key the same way — Users and Access › Integrations, then +.

            App Manager is enough to read reviews. Analytics needs Admin, because Apple requires \
            an Admin key to start generating a report at all.

            The Issuer ID is the same one as before, at the top of the page.
            """
        case .reviewsKeyID:
            return """
            The Key ID of the second key — ten characters, beside its name in the list.
            """
        case .reviewsPrivateKey:
            return """
            The .p8 you downloaded for the second key. Same as before: read once, copied into \
            your Keychain, never opened again.
            """
        case .done:
            return """
            Vantage lives in the menu bar — the tower icon. Click it for the panel; right-click \
            for Settings.

            It's fetching your history now. That takes a few minutes and happens in the \
            background.
            """
        }
    }

    /// The hint inside the field, when there is one.
    public var placeholder: String? {
        switch self {
        case .issuerID, .reviewsIssuerID: return "57246542-96fe-1a63-e053-0824d011072a"
        case .keyID, .reviewsKeyID: return "2X9R4HXF34"
        case .vendorNumber: return "85429106"
        default: return nil
        }
    }

    /// The App Store Connect page this step is talking about.
    ///
    /// Both URLs are verified by hand against a live account — see the note in
    /// `SetupLinks`. A step whose link can't be confirmed names the page and links nothing:
    /// a button landing on a 404 is worse than no button.
    public var link: SetupLink? {
        switch self {
        case .createKey, .issuerID, .keyID, .reviewsIssuerID, .reviewsKeyID:
            return SetupLinks.integrations
        case .vendorNumber:
            return SetupLinks.payments
        case .privateKey, .reviewsPrivateKey, .saveAndTest, .offerReviews, .done:
            return nil
        }
    }
}

/// A labelled destination, so the view renders a button without knowing where it goes.
public struct SetupLink: Equatable {
    public let label: String
    public let url: URL

    public init(label: String, url: URL) {
        self.label = label
        self.url = url
    }
}

/// The two App Store Connect pages setup sends people to.
///
/// **These must be clicked against a live account before release.** `/access/api` is the older
/// path that redirects to the first of these. If either can't be confirmed, delete it here — the
/// step then names the page in prose and shows no button, which is the honest failure.
public enum SetupLinks {
    public static let integrations = SetupLink(
        label: "Open App Store Connect",
        url: URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!)

    public static let payments = SetupLink(
        label: "Open Payments and Financial Reports",
        url: URL(string: "https://appstoreconnect.apple.com/itc/payments_and_financial_reports")!)
}

/// Where the user is in setup, and what they've typed so far.
///
/// Holds no Keychain, no network and no window. Values live here, unwritten, until the model saves
/// them at `.saveAndTest` — so closing the wizard halfway leaves nothing behind.
public struct SetupFlow: Equatable {
    public private(set) var step: SetupStep = .createKey
    public private(set) var values: [KeychainStore.Key: String] = [:]
    /// Answered at `.offerReviews`. Decides whether the flow has three more steps.
    public private(set) var wantsReviewsKey = false

    public init() {}

    // MARK: - Values

    public func value(for key: KeychainStore.Key) -> String {
        (values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func setValue(_ text: String, for key: KeychainStore.Key) {
        values[key] = text
    }

    /// The four required values, trimmed, ready for the Keychain.
    public var salesValues: [KeychainStore.Key: String] {
        collected { !$0.isReviews }
    }

    /// The three optional ones. Never mixed with the four above — the separation is the point.
    public var reviewsValues: [KeychainStore.Key: String] {
        collected { $0.isReviews }
    }

    private func collected(_ include: (KeychainStore.Key) -> Bool) -> [KeychainStore.Key: String] {
        var result: [KeychainStore.Key: String] = [:]
        for key in KeychainStore.Key.allCases where include(key) {
            let value = self.value(for: key)
            if !value.isEmpty { result[key] = value }
        }
        return result
    }

    /// The shape note for whatever this step is asking for. Steps with no field say nothing.
    public var note: CredentialShape.Note {
        guard let field = step.field else { return .ok }
        return CredentialShape.note(for: field, value: value(for: field))
    }

    // MARK: - Moving

    public var isComplete: Bool { step == .done }

    /// False on the first screen, on the offer — whose previous step already wrote to the Keychain
    /// and made a request — and on the last.
    public var canGoBack: Bool {
        switch step {
        case .createKey, .offerReviews, .done: return false
        default: return true
        }
    }

    public mutating func advance() {
        switch step {
        case .offerReviews:
            step = wantsReviewsKey ? .reviewsIssuerID : .done
        case .reviewsPrivateKey, .done:
            step = .done
        default:
            step = SetupStep(rawValue: step.rawValue + 1) ?? .done
        }
    }

    public mutating func back() {
        guard canGoBack else { return }
        switch step {
        case .reviewsIssuerID:
            step = .offerReviews
        default:
            step = SetupStep(rawValue: step.rawValue - 1) ?? .createKey
        }
    }

    /// Jumps straight to a step. Used by the failure screen, which sends the user to the field
    /// Apple's error implicates rather than back to the beginning.
    public mutating func goTo(_ destination: SetupStep) {
        step = destination
    }

    public mutating func chooseReviews(_ wanted: Bool) {
        wantsReviewsKey = wanted
    }
}
