import CryptoKit
import XCTest
@testable import VantageCore

/// Token minting and request building, with a throwaway key generated here. No network, and
/// nothing in this file resembles a real credential.
final class ASCClientTests: XCTestCase {
    /// A P-256 key created for this test run and discarded with it.
    private static let testKey = P256.Signing.PrivateKey()

    private func credentials() -> Credentials {
        Credentials(issuerID: "00000000-0000-0000-0000-000000000000",
                    keyID: "TESTKEYID1",
                    privateKey: Self.testKey.pemRepresentation,
                    vendorNumber: "12345678")
    }

    private func decode(_ segment: Substring) throws -> [String: Any] {
        var base64 = String(segment)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - The token

    func testTokenHasThreeSegments() throws {
        let token = try ASCClient.token(for: credentials(), path: "/v1/salesReports?x=1")
        XCTAssertEqual(token.split(separator: ".").count, 3)
    }

    func testHeaderMatchesApplesSpec() throws {
        let token = try ASCClient.token(for: credentials(), path: "/v1/salesReports")
        let header = try decode(token.split(separator: ".")[0])
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["typ"] as? String, "JWT")
        XCTAssertEqual(header["kid"] as? String, "TESTKEYID1")
    }

    func testPayloadMatchesApplesSpec() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try ASCClient.token(for: credentials(), path: "/v1/salesReports?a=b", now: now)
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
            ASCClient.token(for: credentials(), path: "/v1/salesReports", now: now)
                .split(separator: ".")[1])
        let issued = try XCTUnwrap(payload["iat"] as? Int)
        let expires = try XCTUnwrap(payload["exp"] as? Int)
        XCTAssertGreaterThan(expires, issued)
        XCTAssertLessThanOrEqual(expires - issued, 20 * 60)
        XCTAssertEqual(expires - issued, Int(ASCClient.tokenLifetime))
    }

    /// ES256 signatures are the raw r‖s pair — 64 bytes. A DER-encoded signature is ~70 bytes,
    /// varies in length, and is silently rejected by every JWT verifier.
    func testSignatureIsRawNotDER() throws {
        let token = try ASCClient.token(for: credentials(), path: "/v1/salesReports")
        let segments = token.split(separator: ".")
        var base64 = String(segments[2])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        XCTAssertEqual(try XCTUnwrap(Data(base64Encoded: base64)).count, 64)
    }

    func testSignatureVerifiesAgainstTheSigningInput() throws {
        let token = try ASCClient.token(for: credentials(), path: "/v1/salesReports")
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
        let token = try ASCClient.token(for: credentials(), path: "/v1/salesReports")
        XCTAssertFalse(token.contains("="))
        XCTAssertFalse(token.contains("+"))
        XCTAssertFalse(token.contains("/"))
    }

    func testRejectsAKeyThatIsntAPrivateKey() {
        let bad = Credentials(issuerID: "x", keyID: "y",
                              privateKey: "not a pem file at all", vendorNumber: "z")
        XCTAssertThrowsError(try ASCClient.token(for: bad, path: "/v1/salesReports"))
    }

    // MARK: - The query

    func testQueryMatchesApplesOneLegalCombination() {
        let query = ASCClient.query(vendorNumber: "12345678",
                                    date: ReportDate(year: 2026, month: 8, day: 1))
        XCTAssertTrue(query.contains("filter[frequency]=DAILY"))
        XCTAssertTrue(query.contains("filter[reportType]=SALES"))
        XCTAssertTrue(query.contains("filter[reportSubType]=SUMMARY"))
        XCTAssertTrue(query.contains("filter[version]=1_0"))
        XCTAssertTrue(query.contains("filter[vendorNumber]=12345678"))
        XCTAssertTrue(query.contains("filter[reportDate]=2026-08-01"))
    }

    /// The scope claim is only worth setting if it matches the request exactly — Apple rejects a
    /// token whose scope doesn't. Building both from one string is what keeps that true.
    func testScopeMatchesTheQueryThatWillBeSent() throws {
        let credentials = credentials()
        let date = ReportDate(year: 2026, month: 8, day: 1)
        let query = ASCClient.query(vendorNumber: credentials.vendorNumber, date: date)
        let payload = try decode(
            ASCClient.token(for: credentials, path: "/v1/salesReports?\(query)")
                .split(separator: ".")[1])
        XCTAssertEqual(payload["scope"] as? [String], ["GET /v1/salesReports?\(query)"])
    }

    func testBracketsAreLeftUnencoded() {
        // Apple's own scope examples are written with unencoded brackets, and the scope has to
        // match the URL byte for byte.
        let query = ASCClient.query(vendorNumber: "1", date: ReportDate(year: 2026, month: 1, day: 1))
        XCTAssertFalse(query.contains("%5B"))
        XCTAssertFalse(query.contains("%5D"))
    }
}
