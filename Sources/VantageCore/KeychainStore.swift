import Foundation
import Security

/// The values Vantage needs to talk to App Store Connect, held in the macOS Keychain.
///
/// **One Keychain item, holding every value**, because a Keychain ACL is granted *per item*: macOS
/// asks for permission once per item and "Always Allow" adds the app to that one item's trusted
/// list and no other. Vantage used to store one item per value — seven of them — so every launch
/// asked seven times, and clicking Always Allow on all seven only ever answered the seven it was
/// asked about. One item is one question.
///
/// **What that costs, stated plainly.** The two keys are no longer separated *in storage*. A read
/// returns the vault, so `reviewsKey()` touches the same item `credentials()` does, and the promise
/// this file used to make — "two disjoint sets of account names" — is no longer true. What remains
/// is separation in *shape* and in *injection*: `credentials()` and `reviewsKey()` return different
/// types built from disjoint fields, and each client's default argument reads only its own. That is
/// code discipline, not storage isolation, and `SECURITY.md` now says so rather than claiming more.
/// Anything relying on the old guarantee must be re-read before it is trusted.
///
/// Nothing in this file logs, prints, or returns a credential in an error message. See the
/// guardrails in CLAUDE.md, and `SECURITY.md` for the promises made to users about this file.
public enum KeychainStore {
    /// Service name for every item Vantage owns. Matches the bundle identifier so a user browsing
    /// Keychain Access can see exactly what this app stored and delete it by hand.
    public static let service = "com.vickipetrova.vantage"

    /// The single account every value now lives under.
    ///
    /// One legible row in Keychain Access rather than seven. Seven rows were the better answer to
    /// "what did this app store?" and the much worse answer to "how many times must I type my
    /// password?", and only one of those is a question users actually ask.
    static let account = "credentials"

    /// The names of the values Vantage holds. These are no longer Keychain accounts — they are
    /// fields inside the one item — but they remain the vocabulary Settings uses per field, and
    /// the accounts the legacy items were stored under, which is how migration finds them.
    public enum Key: String, CaseIterable {
        case issuerID
        case keyID
        /// The full text of the `.p8` file, PEM armour included.
        case privateKey
        case vendorNumber

        // The optional reviews key. Distinct fields, never mixed with the four above.
        case reviewsIssuerID
        case reviewsKeyID
        case reviewsPrivateKey

        /// Which key a field belongs to, so Settings can forget one without touching the other and
        /// can present the reviews fields as optional rather than missing.
        public var isReviews: Bool {
            switch self {
            case .reviewsIssuerID, .reviewsKeyID, .reviewsPrivateKey: return true
            case .issuerID, .keyID, .privateKey, .vendorNumber: return false
            }
        }
    }

    // MARK: - In-memory copy

    /// Serialises every access. `credentials()` is called from network completion handlers on
    /// arbitrary queues while Settings writes on the main one, so the cache is shared mutable
    /// state and needs a lock whether or not the user has caching switched on.
    private static let lock = NSLock()
    private static var cached: CredentialVault?

    private static func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Drops the in-memory copy. Called when the preference is switched off, so turning it off
    /// takes effect now rather than at the next launch.
    public static func forgetCachedCredentials() {
        withLock { cached = nil }
    }

    // MARK: - Reading

    private static func loadLocked() -> CredentialVault {
        if Prefs.rememberCredentials {
            if let cached { return cached }
        } else {
            // Switching the preference off must drop what is already held, not merely stop adding
            // to it — otherwise the setting appears to do nothing until the next launch.
            cached = nil
        }

        let vault = absorbLegacyItems(into: readVault() ?? CredentialVault())
        // Only remember something worth remembering. Caching an empty vault would make a first
        // launch that hasn't been set up yet answer "no credentials" for the whole session, even
        // after Settings saves some.
        if Prefs.rememberCredentials, !vault.isEmpty { cached = vault }
        return vault
    }

    public static func value(for key: Key) -> String? {
        withLock { loadLocked()[key] }
    }

    /// All four values, or nil if any is missing. Vantage can't do anything useful with three.
    public static func credentials() -> Credentials? {
        withLock {
            let vault = loadLocked()
            guard let issuerID = vault[.issuerID],
                  let keyID = vault[.keyID],
                  let privateKey = vault[.privateKey],
                  let vendorNumber = vault[.vendorNumber]
            else { return nil }
            return Credentials(issuerID: issuerID, keyID: keyID,
                               privateKey: privateKey, vendorNumber: vendorNumber)
        }
    }

    public static var hasCredentials: Bool { credentials() != nil }

    /// The optional reviews key, or nil when it isn't configured.
    ///
    /// Deliberately **not** a fallback to the sales key. A sales key can't read reviews, so falling
    /// back would turn "you haven't added a reviews key" into an opaque 403 — and if it ever could,
    /// silently using a key for something the user didn't grant it for is worse than an empty state.
    public static func reviewsKey() -> ASCKey? {
        withLock {
            let vault = loadLocked()
            guard let issuerID = vault[.reviewsIssuerID],
                  let keyID = vault[.reviewsKeyID],
                  let privateKey = vault[.reviewsPrivateKey]
            else { return nil }
            return ASCKey(issuerID: issuerID, keyID: keyID, privateKey: privateKey)
        }
    }

    public static var hasReviewsKey: Bool { reviewsKey() != nil }

    // MARK: - Writing

    /// Stores a value, replacing any existing one. An empty string deletes instead — a blanked
    /// field in Settings means "remove this", not "store nothing under this name".
    @discardableResult
    public static func set(_ value: String, for key: Key) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return withLock {
            var vault = loadLocked()
            vault[key] = trimmed.isEmpty ? nil : trimmed
            return storeLocked(vault)
        }
    }

    // MARK: - Deleting

    @discardableResult
    public static func delete(_ key: Key) -> Bool {
        withLock {
            var vault = loadLocked()
            vault[key] = nil
            return storeLocked(vault)
        }
    }

    /// "Forget credentials" in Settings. Removes every value Vantage stored, both keys.
    public static func forgetAll() {
        withLock {
            cached = nil
            deleteItem(account: account)
            // Legacy per-value items too. A migration that couldn't verify its write leaves them
            // in place on purpose, and "forget everything" has to mean everything.
            for key in Key.allCases { deleteItem(account: key.rawValue) }
        }
    }

    /// Removes only the reviews key, leaving sales working.
    ///
    /// The point of a separate optional key is being able to take it back without losing the app,
    /// so this has to exist and has to be the thing the reviews section's own button calls.
    public static func forgetReviewsKey() {
        withLock {
            var vault = loadLocked()
            for key in Key.allCases where key.isReviews { vault[key] = nil }
            _ = storeLocked(vault)
        }
    }

    // MARK: - The one item

    private static func readVault() -> CredentialVault? {
        guard let data = readItem(account: account) else { return nil }
        return CredentialVault.decoded(data)
    }

    private static func storeLocked(_ vault: CredentialVault) -> Bool {
        // An empty vault is no item at all rather than an item holding `{}` — otherwise "forget
        // credentials" leaves a row in Keychain Access that looks like a credential.
        guard !vault.isEmpty else {
            cached = nil
            return deleteItem(account: account)
        }
        guard let data = vault.encoded() else { return false }
        let written = writeItem(data, account: account)
        // Only mirror what actually reached the Keychain. Caching a failed write would report
        // success for the rest of the session and lose the value at the next launch.
        cached = written ? vault : nil
        return written
    }

    /// Folds any surviving per-value items into the vault, and removes only the ones it could
    /// actually read.
    ///
    /// This is the launch that still asks seven times — there is no way to read seven items with
    /// fewer than seven authorisations, which is the whole problem being fixed. Every launch after
    /// it asks once.
    ///
    /// Two failure modes this has to survive, both of which end in a lost private key if handled
    /// casually:
    ///
    /// - **A cancelled prompt.** Someone who dismisses three of the seven leaves a vault holding
    ///   four values. Deleting all seven then would destroy the three that were never read, so only
    ///   the keys actually absorbed are deleted, and the rest are picked up on a later launch.
    /// - **A failed or unverified write.** The legacy items stay exactly where they are; the app
    ///   runs from what it read this session and tries again next time.
    ///
    /// It runs on every load rather than once, because that is what makes the first case recover.
    /// Once the legacy items are gone the sweep costs seven lookups that miss, and a Keychain item
    /// that does not exist is answered without consulting an ACL — so it prompts for nothing.
    private static func absorbLegacyItems(into vault: CredentialVault) -> CredentialVault {
        var merged = vault
        var absorbed: [Key] = []

        for key in Key.allCases {
            guard let data = readItem(account: key.rawValue),
                  let string = String(data: data, encoding: .utf8),
                  !string.isEmpty
            else { continue }
            // The vault wins where both hold a value: it is what Settings has written to since the
            // migration, so the per-value item is the stale copy by definition.
            if merged[key] == nil { merged[key] = string }
            absorbed.append(key)
        }

        guard !absorbed.isEmpty else { return vault }
        guard let data = merged.encoded(), writeItem(data, account: account),
              readVault() == merged
        else { return merged }

        for key in absorbed { deleteItem(account: key.rawValue) }
        return merged
    }

    // MARK: - Raw Keychain access

    private static func readItem(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return data
    }

    private static func writeItem(_ data: Data, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
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
        item[kSecAttrDescription as String] = "App Store Connect credentials"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    private static func deleteItem(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Every value Vantage holds, as one JSON object.
///
/// A dictionary keyed by `KeychainStore.Key.rawValue` rather than named properties, so a field
/// added or removed in a later version decodes rather than throwing — a credential store that
/// refuses to open because it has one unfamiliar key in it is a credential store that has lost
/// everything else in it too.
///
/// Pure and `Equatable` so the migration can verify its own write, and so the encoding is covered
/// by `swift test` without a Keychain anywhere near it.
public struct CredentialVault: Equatable {
    private var values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public subscript(key: KeychainStore.Key) -> String? {
        get { values[key.rawValue] }
        set {
            // Empty and absent are the same state. Anything else means `hasCredentials` can be
            // true while a value is "".
            guard let newValue, !newValue.isEmpty else {
                values.removeValue(forKey: key.rawValue)
                return
            }
            values[key.rawValue] = newValue
        }
    }

    public var isEmpty: Bool { values.isEmpty }

    public func encoded() -> Data? {
        try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    }

    public static func decoded(_ data: Data) -> CredentialVault? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var values: [String: String] = [:]
        for (name, value) in object {
            if let string = value as? String, !string.isEmpty { values[name] = string }
        }
        return CredentialVault(values: values)
    }
}

/// The four values the sales key needs, in memory, for the lifetime of one request batch.
public struct Credentials {
    /// Internal rather than public: only `ASCClient`, in this module, has business unwrapping the
    /// sales key back out of its credentials.
    let key: ASCKey
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
