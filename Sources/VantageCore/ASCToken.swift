import CryptoKit
import Foundation

/// The three values that identify one App Store Connect API key.
///
/// Split out from `Credentials` in v0.2 because Vantage can hold **two** keys: the sales key, which
/// only needs the Sales and Reports role, and an optional reviews key, which needs a much more
/// powerful one. Sharing a type means neither can be built with three-quarters of the other's
/// values, and both inherit the same opacity to string interpolation.
public struct ASCKey: Equatable {
    public let issuerID: String
    public let keyID: String
    /// The `.p8` file's contents. Never written anywhere but the Keychain.
    public let privateKey: String

    public init(issuerID: String, keyID: String, privateKey: String) {
        self.issuerID = issuerID
        self.keyID = keyID
        self.privateKey = privateKey
    }
}

// Deliberately opaque, exactly like `Credentials`. An `ASCKey` must never be interpolated into a
// log line, an error message, or a crash report, and the compiler enforces that better than a code
// review can.
extension ASCKey: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "ASCKey(redacted)" }
    public var debugDescription: String { "ASCKey(redacted)" }
}

/// Mints the ES256 JWT App Store Connect wants.
///
/// Extracted from `ASCClient` so the reviews client shares one implementation rather than growing a
/// second one that drifts — particularly around `scope`, which is the claim that limits the damage
/// a leaked token could do and is easy to get subtly wrong.
public enum ASCToken {
    /// How long a minted token stays valid. Apple rejects anything over 20 minutes; five is plenty
    /// for a batch of at most thirty requests and limits what a leaked token is worth.
    public static let lifetime: TimeInterval = 5 * 60

    /// Mints a token for exactly one request.
    ///
    /// `method` and `path` are the method and the exact path-plus-query the token will be used
    /// against, so the `scope` claim matches. Scope is optional in Apple's spec; setting it means a
    /// token that escapes somehow can make one request and nothing else — not, say, read the whole
    /// account, and (once reviews can be answered) certainly not publish anything.
    public static func mint(key: ASCKey, method: String, path: String,
                            now: Date = Date()) throws -> String {
        let issuedAt = Int(now.timeIntervalSince1970)
        let header: [String: Any] = [
            "alg": "ES256",
            "kid": key.keyID,
            "typ": "JWT",
        ]
        let payload: [String: Any] = [
            "iss": key.issuerID,
            "iat": issuedAt,
            "exp": issuedAt + Int(lifetime),
            "aud": "appstoreconnect-v1",
            "scope": ["\(method) \(path)"],
        ]

        let signingInput = try base64URL(json: header) + "." + base64URL(json: payload)
        let signingKey = try P256.Signing.PrivateKey(pemRepresentation: key.privateKey)
        // JWS wants the raw r‖s pair, 64 bytes. `derRepresentation` is the other encoding and is
        // silently accepted by nothing.
        let signature = try signingKey.signature(for: Data(signingInput.utf8)).rawRepresentation
        return signingInput + "." + base64URL(signature)
    }

    private static func base64URL(json object: [String: Any]) throws -> String {
        // `.sortedKeys` only so the same input produces the same token, which makes the signing
        // path testable. Apple doesn't care about key order.
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return base64URL(data)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
