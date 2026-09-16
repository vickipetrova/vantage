import CryptoKit
import XCTest
@testable import VantageCore

/// The ES256 JWT, minted with a throwaway key generated here.
///
/// Shared by the sales client and the reviews client, which is why it has its own file: one
/// implementation of the `scope` claim, and one set of tests holding it to Apple's spec.
final class ASCTokenTests: XCTestCase {
    /// A P-256 key created for this test run and discarded with it.
    private static let testKey = P256.Signing.PrivateKey()

    private func key() -> ASCKey {
        ASCKey(issuerID: "00000000-0000-0000-0000-000000000000",
               keyID: "TESTKEYID1",
               privateKey: Self.testKey.pemRepresentation)
    }

    private func mint(_ path: String, method: String = "GET",
                      now: Date = Date()) throws -> String {
        try ASCToken.mint(key: key(), method: method, path: path, now: now)
    }

    private func decode(_ segment: Substring) throws -> [String: Any] {
        var base64 = String(segment)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTokenHasThreeSegments() throws {
        let token = try mint("/v1/salesReports?x=1")
        XCTAssertEqual(token.split(separator: ".").count, 3)
    }

    func testHeaderMatchesApplesSpec() throws {
        let token = try mint("/v1/salesReports")
        let header = try decode(token.split(separator: ".")[0])
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["typ"] as? String, "JWT")
        XCTAssertEqual(header["kid"] as? String, "TESTKEYID1")
    }

    func testPayloadMatchesApplesSpec() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try mint("/v1/salesReports?a=b", now: now)
        let payload = try decode(token.split(separator: ".")[1])
        XCTAssertEqual(payload["iss"] as? String, "00000000-0000-0000-0000-000000000000")
        XCTAssertEqual(payload["aud"] as? String, "appstoreconnect-v1")
        XCTAssertEqual(payload["iat"] as? Int, 1_800_000_000)
        XCTAssertEqual(payload["scope"] as? [String], ["GET /v1/salesReports?a=b"])
    }

    /// Apple rejects any token for this endpoint whose lifetime exceeds 20 minutes. Being under it
    /// isn't a preference — it's the difference between working and a blanket 401.
    func testTokenLifetimeIsWellUnderApplesTwentyMinuteCeiling() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = try decode(
            mint("/v1/salesReports", now: now)
                .split(separator: ".")[1])
        let issued = try XCTUnwrap(payload["iat"] as? Int)
        let expires = try XCTUnwrap(payload["exp"] as? Int)
        XCTAssertGreaterThan(expires, issued)
        XCTAssertLessThanOrEqual(expires - issued, 20 * 60)
        XCTAssertEqual(expires - issued, Int(ASCToken.lifetime))
    }

    /// ES256 signatures are the raw r‖s pair — 64 bytes. A DER-encoded signature is ~70 bytes,
    /// varies in length, and is silently rejected by every JWT verifier.
    func testSignatureIsRawNotDER() throws {
        let token = try mint("/v1/salesReports")
        let segments = token.split(separator: ".")
        var base64 = String(segments[2])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        XCTAssertEqual(try XCTUnwrap(Data(base64Encoded: base64)).count, 64)
    }

    func testSignatureVerifiesAgainstTheSigningInput() throws {
        let token = try mint("/v1/salesReports")
        let segments = token.split(separator: ".")
        let signingInput = "\(segments[0]).\(segments[1])"

        var base64 = String(segments[2])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        let signature = try P256.Signing.ECDSASignature(
            rawRepresentation: try XCTUnwrap(Data(base64Encoded: base64)))

        XCTAssertTrue(Self.testKey.publicKey.isValidSignature(
            signature, for: Data(signingInput.utf8)))
    }

    func testBase64URLHasNoPaddingOrURLUnsafeCharacters() throws {
        let token = try mint("/v1/salesReports")
        XCTAssertFalse(token.contains("="))
        XCTAssertFalse(token.contains("+"))
        XCTAssertFalse(token.contains("/"))
    }

    func testRejectsAKeyThatIsntAPrivateKey() {
        let bad = ASCKey(issuerID: "x", keyID: "y", privateKey: "not a pem file at all")
        XCTAssertThrowsError(try ASCToken.mint(key: bad, method: "GET", path: "/v1/salesReports"))
    }

    /// The reason the scope claim is worth setting at all: a token minted to read one path cannot
    /// be replayed against another. Apple enforces this — a token scoped to
    /// `GET /v1/analyticsReportRequests` used on a different request comes back
    /// `403 FORBIDDEN.REQUEST_DOES_NOT_MATCH_SCOPE`.
    func testScopeCarriesTheMethodAndPathOnReads() throws {
        let read = try decode(mint("/v1/customerReviewResponses").split(separator: ".")[1])
        XCTAssertEqual(read["scope"] as? [String], ["GET /v1/customerReviewResponses"])
    }

    /// **Apple's `scope` claim only accepts GET entries**, so a write token must carry none.
    ///
    /// Verified against the live API on 2026-09-16. A `POST /v1/analyticsReportRequests` is
    /// answered `405 METHOD_NOT_ALLOWED` — not 401, not 403 — when, and only when, its token
    /// carries a scope claim naming the verb. The identical request with no scope claim returns
    /// `201 Created`. Every other form is refused too:
    ///
    /// | scope on a POST        | answer                                   |
    /// |------------------------|------------------------------------------|
    /// | `["POST /v1/…"]`       | 405 METHOD_NOT_ALLOWED                   |
    /// | `["/v1/…"]` (no verb)  | 400 ENTITY_INVALID                       |
    /// | `["GET /v1/…"]`        | 403 FORBIDDEN.REQUEST_DOES_NOT_MATCH_SCOPE |
    /// | `[]`                   | 400 ENTITY_INVALID                       |
    /// | omitted                | 201 Created                              |
    ///
    /// This cost a month of analytics: the create-report-request POST 405'd on every refresh, and
    /// the panel read that non-fatal error as "Apple is preparing your first report."
    func testWriteTokensCarryNoScopeBecauseAppleRefusesThem() throws {
        for method in ["POST", "PATCH", "DELETE"] {
            let write = try decode(
                mint("/v1/customerReviewResponses", method: method).split(separator: ".")[1])
            XCTAssertNil(write["scope"],
                         "a \(method) token with a scope claim is answered 405 by Apple")
        }
    }

    /// The claims that limit a write token, now that scope can't.
    func testAWriteTokenIsStillNarrowedByAudienceAndLifetime() throws {
        let write = try decode(
            mint("/v1/customerReviewResponses", method: "POST").split(separator: ".")[1])
        XCTAssertEqual(write["aud"] as? String, "appstoreconnect-v1")
        let issued = try XCTUnwrap(write["iat"] as? Int)
        let expires = try XCTUnwrap(write["exp"] as? Int)
        XCTAssertEqual(expires - issued, Int(ASCToken.lifetime))
    }

    /// Pinned as a literal. The other lifetime test asserts only Apple's 20-minute ceiling and
    /// compares against the constant itself, so raising it to 19 minutes kept the suite green —
    /// while SECURITY.md promises **five**.
    func testLifetimeIsTheFiveMinutesSecurityMdPromises() {
        XCTAssertEqual(ASCToken.lifetime, 5 * 60)
    }

    /// An `ASCKey` in a log line, an error message or a crash report must produce nothing useful.
    func testKeyIsOpaqueToInterpolation() {
        let key = key()
        XCTAssertEqual("\(key)", "ASCKey(redacted)")
        XCTAssertEqual(String(describing: key), "ASCKey(redacted)")
        XCTAssertEqual(String(reflecting: key), "ASCKey(redacted)")
        XCTAssertFalse("\(key)".contains("TESTKEYID1"))
    }
}
