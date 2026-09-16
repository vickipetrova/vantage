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
    /// account. Apple enforces it: a scoped token used against any other request is answered
    /// `403 FORBIDDEN.REQUEST_DOES_NOT_MATCH_SCOPE`.
    ///
    /// **Scope is set on GET only, because Apple accepts nothing else there.** A write whose token
    /// carries a scope claim naming its own verb is answered `405 METHOD_NOT_ALLOWED` — the status
    /// for a bad *path*, which is what made this so expensive to find. Verified against the live
    /// API on 2026-09-16: `POST /v1/analyticsReportRequests` returns 405 with
    /// `["POST /v1/analyticsReportRequests"]`, 400 `ENTITY_INVALID` with a verbless entry or an
    /// empty array, 403 with a `GET` entry — and 201 with no scope claim at all. There is no form
    /// that works, so a write token carries none and is limited by `aud` and the five-minute
    /// lifetime instead. See `ASCTokenTests.testWriteTokensCarryNoScopeBecauseAppleRefusesThem`.
    ///
    /// This is not a detail: with scope on writes, `ASCAnalyticsClient` could never create a report
    /// request and analytics never produced a single number.
    public static func mint(key: ASCKey, method: String, path: String,
                            now: Date = Date()) throws -> String {
        let issuedAt = Int(now.timeIntervalSince1970)
        let header: [String: Any] = [
            "alg": "ES256",
            "kid": key.keyID,
            "typ": "JWT",
        ]
        var payload: [String: Any] = [
            "iss": key.issuerID,
            "iat": issuedAt,
            "exp": issuedAt + Int(lifetime),
            "aud": "appstoreconnect-v1",
        ]
        if method.uppercased() == "GET" {
            payload["scope"] = ["\(method) \(path)"]
        }

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
