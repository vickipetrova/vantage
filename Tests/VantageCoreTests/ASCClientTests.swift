import CryptoKit
import XCTest
@testable import VantageCore

/// Request building. Token minting moved to `ASCTokenTests` when the reviews client started
/// sharing it. No network, and nothing in this file resembles a real credential.
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
            ASCToken.mint(key: credentials.key, method: "GET",
                          path: "/v1/salesReports?\(query)")
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
