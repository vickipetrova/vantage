import XCTest
@testable import VantageCore

/// What a typed credential looks like, and the note shown beside it.
///
/// Every case here is advisory. There is deliberately no case a caller could read as "refuse to
/// continue" — see `testNoteNeverBlocks` and the reasoning in CLAUDE.md about Apple changing a
/// format under us.
final class CredentialShapeTests: XCTestCase {
    private let realIssuer = "57246542-96fe-1a63-e053-0824d011072a"
    private let realKeyID = "2X9R4HXF34"

    // MARK: - The values that are right

    func testWellFormedValuesPass() {
        XCTAssertEqual(CredentialShape.note(for: .issuerID, value: realIssuer), .ok)
        XCTAssertEqual(CredentialShape.note(for: .keyID, value: realKeyID), .ok)
        XCTAssertEqual(CredentialShape.note(for: .vendorNumber, value: "85429106"), .ok)
    }

    /// The reviews fields are the same three shapes under different names.
    func testReviewsFieldsShareTheSameShapes() {
        XCTAssertEqual(CredentialShape.note(for: .reviewsIssuerID, value: realIssuer), .ok)
        XCTAssertEqual(CredentialShape.note(for: .reviewsKeyID, value: realKeyID), .ok)
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(CredentialShape.note(for: .keyID, value: "  \(realKeyID)\n"), .ok)
    }

    // MARK: - The swap, which is the whole point

    func testKeyIDPastedIntoIssuerID() {
        XCTAssertEqual(CredentialShape.note(for: .issuerID, value: realKeyID),
                       .looksLike(.keyID))
    }

    func testIssuerIDPastedIntoKeyID() {
        XCTAssertEqual(CredentialShape.note(for: .keyID, value: realIssuer),
                       .looksLike(.issuerID))
    }

    // MARK: - Empty is its own thing, not an error

    func testEmptyIsEmpty() {
        XCTAssertEqual(CredentialShape.note(for: .issuerID, value: ""), .empty)
        XCTAssertEqual(CredentialShape.note(for: .issuerID, value: "   "), .empty)
    }

    /// Empty says nothing. A field you have not filled in yet is a step remaining, and nagging
    /// about it before the user has typed is noise.
    func testEmptyHasNoMessage() {
        XCTAssertNil(CredentialShape.Note.empty.message)
        XCTAssertNil(CredentialShape.Note.ok.message)
    }

    // MARK: - Wrong shapes

    func testTooShortIssuerID() {
        guard case .unexpected = CredentialShape.note(for: .issuerID, value: "abc") else {
            return XCTFail("expected .unexpected")
        }
    }

    func testVendorNumberWithLetters() {
        guard case .unexpected = CredentialShape.note(for: .vendorNumber, value: "12ab5678") else {
            return XCTFail("expected .unexpected")
        }
    }

    /// The `.p8` is checked by reading the file, not by looking at a string — the picker in the
    /// app target already rejects a file with no PEM armour.
    func testPrivateKeyIsNotShapeChecked() {
        XCTAssertEqual(CredentialShape.note(for: .privateKey, value: "anything at all"), .ok)
        XCTAssertEqual(CredentialShape.note(for: .reviewsPrivateKey, value: ""), .ok)
    }

    // MARK: - The rule that must not be reversed

    /// Not a style check. If someone later adds a `.invalid` case and wires Continue to it, this
    /// fails — which is the point. A wizard that hard-blocks on a guess about Apple's format is an
    /// app nobody can set up once Apple changes the format.
    func testNoteNeverBlocks() {
        let adversarial = ["", " ", "x", realIssuer, realKeyID, "85429106",
                           "…", "https://example.com", String(repeating: "9", count: 500)]
        for key in KeychainStore.Key.allCases {
            for value in adversarial {
                let note = CredentialShape.note(for: key, value: value)
                XCTAssertTrue(note.isAdvisory,
                              "\(key) / \(value.prefix(12)) produced a blocking note")
            }
        }
    }
}
