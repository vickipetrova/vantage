import Foundation

/// What a typed credential looks like, and what to say about it.
///
/// **Every note is advisory.** There is no case meaning "refuse to continue", and
/// `Note.isAdvisory` is `true` for all of them, permanently — the setup wizard must never block on
/// a shape. Apple can rename a value or change its format, and a wizard that hard-blocks on this
/// file's guesses would leave a user unable to set the app up at all. Same rule `ReportParser`
/// follows when it meets a product type it has never seen.
///
/// Nothing here logs or returns the value it was given. The messages describe the *shape* expected,
/// never what was typed.
public enum CredentialShape {
    public enum Note: Equatable {
        /// Looks like what this field wants.
        case ok
        /// Nothing typed yet. Not a complaint.
        case empty
        /// Recognisably a different field's value — almost always the Issuer/Key ID swap.
        case looksLike(KeychainStore.Key)
        /// Doesn't match, and doesn't match anything else either.
        case unexpected(String)

        /// What to show beside the field, or `nil` when there's nothing worth saying.
        public var message: String? {
            switch self {
            case .ok, .empty:
                return nil
            case .looksLike(let other):
                switch other {
                case .keyID, .reviewsKeyID:
                    return "That looks like a Key ID. An Issuer ID is a UUID — 36 characters "
                        + "with dashes."
                case .issuerID, .reviewsIssuerID:
                    return "That looks like an Issuer ID. A Key ID is the ten characters beside "
                        + "your key's name."
                case .privateKey, .reviewsPrivateKey, .vendorNumber:
                    return "That looks like a different value."
                }
            case .unexpected(let message):
                return message
            }
        }

        /// Always `true`. Kept as a property rather than left implicit so the never-block rule is
        /// something a test can assert against, not a convention in a comment.
        public var isAdvisory: Bool { true }
    }

    public static func note(for key: KeychainStore.Key, value: String) -> Note {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        switch key {
        case .privateKey, .reviewsPrivateKey:
            // Checked by reading the file for PEM armour, in the app target's picker. There is no
            // useful shape test for a string the user never types.
            return .ok

        case .issuerID, .reviewsIssuerID:
            if trimmed.isEmpty { return .empty }
            if isUUID(trimmed) { return .ok }
            if isKeyID(trimmed) { return .looksLike(.keyID) }
            return .unexpected("An Issuer ID is a UUID — 36 characters with dashes. It's at the "
                               + "top of Users and Access › Integrations.")

        case .keyID, .reviewsKeyID:
            if trimmed.isEmpty { return .empty }
            if isKeyID(trimmed) { return .ok }
            if isUUID(trimmed) { return .looksLike(.issuerID) }
            return .unexpected("A Key ID is ten characters, letters and numbers — it's beside "
                               + "your key's name, and in the .p8 filename.")

        case .vendorNumber:
            if trimmed.isEmpty { return .empty }
            if isVendorNumber(trimmed) { return .ok }
            return .unexpected("A Vendor Number is digits only, normally eight of them. It's on "
                               + "Payments and Financial Reports › Reports.")
        }
    }

    /// 8-4-4-4-12 hex. Apple's Issuer IDs are lowercase, but a user pasting from a page that
    /// upper-cased it has not made a mistake worth a warning.
    private static func isUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    /// Exactly ten alphanumerics.
    private static func isKeyID(_ value: String) -> Bool {
        value.count == 10 && value.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Digits. Eight in every report seen so far, but the length is Apple's to change and being
    /// wrong about it must not cost more than a missing note.
    private static func isVendorNumber(_ value: String) -> Bool {
        value.allSatisfy(\.isNumber) && (7...12).contains(value.count)
    }
}
