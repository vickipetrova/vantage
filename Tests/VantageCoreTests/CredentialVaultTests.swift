import XCTest
@testable import VantageCore

/// The one Keychain item's contents.
///
/// `KeychainStore` itself can't be tested — it would need a real Keychain, and on CI a prompt
/// nobody can answer — so everything that could be lifted out of it lives here instead: the shape
/// of what gets stored, and the encoding that has to survive a round trip without dropping a
/// private key.
final class CredentialVaultTests: XCTestCase {
    func testRoundTripsEveryField() {
        var vault = CredentialVault()
        for key in KeychainStore.Key.allCases { vault[key] = "value-for-\(key.rawValue)" }

        let data = try? XCTUnwrap(vault.encoded())
        let decoded = data.flatMap { CredentialVault.decoded($0) }

        XCTAssertEqual(decoded, vault)
        for key in KeychainStore.Key.allCases {
            XCTAssertEqual(decoded?[key], "value-for-\(key.rawValue)")
        }
    }

    /// A `.p8` is multi-line with PEM armour, and JSON is the one encoding here that has to carry
    /// it back byte for byte — a mangled newline is a key that no longer parses.
    func testAPEMPrivateKeySurvivesIntact() {
        let pem = """
        -----BEGIN PRIVATE KEY-----
        MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg+not+a+real+key
        -----END PRIVATE KEY-----
        """
        var vault = CredentialVault()
        vault[.privateKey] = pem

        let decoded = vault.encoded().flatMap { CredentialVault.decoded($0) }
        XCTAssertEqual(decoded?[.privateKey], pem)
    }

    /// Empty and absent are one state. Anything else lets `hasCredentials` be true while a value
    /// is the empty string, which fails later and somewhere less obvious.
    func testAnEmptyValueIsTheSameAsNoValue() {
        var vault = CredentialVault()
        vault[.issuerID] = ""
        XCTAssertNil(vault[.issuerID])
        XCTAssertTrue(vault.isEmpty)

        vault[.issuerID] = "abc"
        vault[.issuerID] = nil
        XCTAssertNil(vault[.issuerID])
        XCTAssertTrue(vault.isEmpty)
    }

    /// Settings can save the sales key without the optional reviews key, so a half-filled vault has
    /// to be an ordinary value rather than an error.
    func testAPartialSetupIsRepresentable() {
        var vault = CredentialVault()
        vault[.issuerID] = "iss"
        vault[.keyID] = "kid"

        XCTAssertFalse(vault.isEmpty)
        XCTAssertNil(vault[.reviewsIssuerID])
        XCTAssertEqual(vault.encoded().flatMap { CredentialVault.decoded($0) }, vault)
    }

    /// A field this version doesn't know about must not take the rest of the vault down with it.
    /// A credential store that refuses to open has lost everything in it, not just the new field.
    func testAnUnknownFieldDoesNotDiscardTheKnownOnes() {
        let json = Data("""
        {"issuerID":"iss","keyID":"kid","somethingAddedLater":"x"}
        """.utf8)

        let decoded = CredentialVault.decoded(json)
        XCTAssertEqual(decoded?[.issuerID], "iss")
        XCTAssertEqual(decoded?[.keyID], "kid")
    }

    func testJunkDecodesToNothingRatherThanAnEmptyVault() {
        XCTAssertNil(CredentialVault.decoded(Data("not json".utf8)))
        XCTAssertNil(CredentialVault.decoded(Data()))
        // A JSON array is well-formed JSON and still not a vault.
        XCTAssertNil(CredentialVault.decoded(Data("[1,2,3]".utf8)))
    }

    /// The migration deletes seven irreplaceable items on the strength of this comparison, so it
    /// has to distinguish a vault that matches from one that merely looks similar.
    func testEqualityIsWhatTheMigrationCanSafelyRelyOn() {
        var written = CredentialVault()
        written[.issuerID] = "iss"
        written[.privateKey] = "pem"

        var readBack = CredentialVault()
        readBack[.issuerID] = "iss"
        XCTAssertNotEqual(written, readBack, "a missing field must not compare equal")

        readBack[.privateKey] = "pem"
        XCTAssertEqual(written, readBack)

        readBack[.privateKey] = "pem "
        XCTAssertNotEqual(written, readBack, "a changed field must not compare equal")
    }

    /// Encoding is sorted, so the same vault produces the same bytes — which is what makes the
    /// migration's read-back comparison meaningful rather than incidentally true.
    func testEncodingIsStable() {
        var vault = CredentialVault()
        vault[.keyID] = "kid"
        vault[.issuerID] = "iss"

        var reordered = CredentialVault()
        reordered[.issuerID] = "iss"
        reordered[.keyID] = "kid"

        XCTAssertEqual(vault.encoded(), reordered.encoded())
    }
}
