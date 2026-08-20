import Foundation
import Security

/// The values Vantage needs to talk to App Store Connect, held in the macOS Keychain.
///
/// **Two independent keys.** The sales key needs only the Sales and Reports role and is required.
/// The reviews key is optional, needs a far more powerful role, and is stored as its own separate
/// items so that adding one never widens what the sales key can do. Nothing reads across the two.
///
/// Nothing in this file logs, prints, or returns a credential in an error message. Values are read
/// on demand, handed to one request, and dropped. Keep it that way — see the guardrails in
/// CLAUDE.md, and `SECURITY.md` for the promises made to users about this file specifically.
public enum KeychainStore {
    /// Service name for every item Vantage owns. Matches the bundle identifier so a user browsing
    /// Keychain Access can see exactly what this app stored and delete it by hand.
    public static let service = "com.vickipetrova.vantage"

    /// One Keychain item per value, rather than one JSON blob, so Keychain Access shows a person
    /// legible rows and so a partial setup is representable.
    public enum Key: String, CaseIterable {
        case issuerID
        case keyID
        /// The full text of the `.p8` file, PEM armour included.
        case privateKey
        case vendorNumber

        // The optional reviews key. Separate items, separate values, never mixed with the four
        // above — see `reviewsKey()`.
        case reviewsIssuerID
        case reviewsKeyID
        case reviewsPrivateKey

        /// Which key an item belongs to, so Settings can forget one without touching the other.
        var isReviews: Bool {
            switch self {
            case .reviewsIssuerID, .reviewsKeyID, .reviewsPrivateKey: return true
            case .issuerID, .keyID, .privateKey, .vendorNumber: return false
            }
        }
    }

    // MARK: - Reading

    public static func value(for key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty
        else { return nil }
        return string
    }

    /// All four values, or nil if any is missing. Vantage can't do anything useful with three.
    public static func credentials() -> Credentials? {
        guard let issuerID = value(for: .issuerID),
              let keyID = value(for: .keyID),
              let privateKey = value(for: .privateKey),
              let vendorNumber = value(for: .vendorNumber)
        else { return nil }
        return Credentials(issuerID: issuerID, keyID: keyID,
                           privateKey: privateKey, vendorNumber: vendorNumber)
    }

    public static var hasCredentials: Bool { credentials() != nil }

    /// The optional reviews key, or nil when it isn't configured.
    ///
    /// Deliberately **not** a fallback to the sales key. A sales key can't read reviews, so falling
    /// back would turn "you haven't added a reviews key" into an opaque 403 — and if it ever could,
    /// silently using a key for something the user didn't grant it for is worse than an empty state.
    public static func reviewsKey() -> ASCKey? {
        guard let issuerID = value(for: .reviewsIssuerID),
              let keyID = value(for: .reviewsKeyID),
              let privateKey = value(for: .reviewsPrivateKey)
        else { return nil }
        return ASCKey(issuerID: issuerID, keyID: keyID, privateKey: privateKey)
    }

    public static var hasReviewsKey: Bool { reviewsKey() != nil }

    // MARK: - Writing

    /// Stores a value, replacing any existing one. An empty string deletes instead — a blanked
    /// field in Settings means "remove this", not "store nothing under this name".
    @discardableResult
    public static func set(_ value: String, for key: Key) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete(key) }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let data = Data(trimmed.utf8)

        // Update first, then add: SecItemAdd on an existing account returns errSecDuplicateItem,
        // and deleting-then-adding leaves a window where the credential is gone if the add fails.
        let updated = SecItemUpdate(base as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }

        var item = base
        item[kSecValueData as String] = data
        // The app is ad-hoc signed and carries no entitlements, so this is a login-keychain item.
        // The data-protection keychain (kSecUseDataProtectionKeychain) would let us ask for
        // "this device only" and non-syncing explicitly, but it requires a keychain-access-group
        // entitlement that a build-from-source bundle can't have. Login keychain items aren't
        // synced to iCloud either, so the practical outcome is the same.
        item[kSecAttrDescription as String] = "App Store Connect credential"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Deleting

    @discardableResult
    public static func delete(_ key: Key) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// "Forget credentials" in Settings. Removes every value Vantage stored, both keys.
    public static func forgetAll() {
        for key in Key.allCases { delete(key) }
    }

    /// Removes only the reviews key, leaving sales working.
    ///
    /// The point of a separate optional key is being able to take it back without losing the app,
    /// so this has to exist and has to be the thing the reviews section's own button calls.
    public static func forgetReviewsKey() {
        for key in Key.allCases where key.isReviews { delete(key) }
    }
}

/// The four values the sales key needs, in memory, for the lifetime of one request batch.
public struct Credentials {
    public let key: ASCKey
    /// Sales reports only. The reviews endpoints take no vendor number, which is one more reason
    /// the two keys don't share a type.
    public let vendorNumber: String

    public var issuerID: String { key.issuerID }
    public var keyID: String { key.keyID }
    public var privateKey: String { key.privateKey }

    public init(key: ASCKey, vendorNumber: String) {
        self.key = key
        self.vendorNumber = vendorNumber
    }

    public init(issuerID: String, keyID: String, privateKey: String, vendorNumber: String) {
        self.init(key: ASCKey(issuerID: issuerID, keyID: keyID, privateKey: privateKey),
                  vendorNumber: vendorNumber)
    }
}

// Deliberately opaque. `Credentials` must never be interpolated into a log line, an error message,
// or a crash report, and the compiler can enforce that better than a code review can.
extension Credentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "Credentials(redacted)" }
    public var debugDescription: String { "Credentials(redacted)" }
}
