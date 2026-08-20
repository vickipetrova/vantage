import XCTest
@testable import VantageCore

/// The lookup response is third-party JSON that Vantage doesn't control, so every shape it can
/// arrive in has to fail into "no icon" rather than into a crash or a wrong image.
final class AppIconTests: XCTestCase {
    private func json(_ string: String) -> Data { Data(string.utf8) }

    func testPrefersTheHundredPointArtwork() {
        let data = json("""
        {"resultCount":1,"results":[{
          "artworkUrl60":"https://is1-ssl.mzstatic.com/image/60x60bb.jpg",
          "artworkUrl100":"https://is1-ssl.mzstatic.com/image/100x100bb.jpg",
          "artworkUrl512":"https://is1-ssl.mzstatic.com/image/512x512bb.jpg"
        }]}
        """)
        XCTAssertEqual(ITunesLookup.artworkURL(from: data)?.absoluteString,
                       "https://is1-ssl.mzstatic.com/image/100x100bb.jpg")
    }

    func testFallsBackThroughTheOtherRenditions() {
        let data = json("""
        {"resultCount":1,"results":[
          {"artworkUrl512":"https://is1-ssl.mzstatic.com/image/512x512bb.jpg"}]}
        """)
        XCTAssertEqual(ITunesLookup.artworkURL(from: data)?.absoluteString,
                       "https://is1-ssl.mzstatic.com/image/512x512bb.jpg")
    }

    /// An empty `results` array is the normal answer for an app that isn't on the store — a
    /// TestFlight-only build, or one removed from sale. Not an error.
    func testNoResultsMeansNoIcon() {
        XCTAssertNil(ITunesLookup.artworkURL(from: json(#"{"resultCount":0,"results":[]}"#)))
    }

    func testMalformedJSONMeansNoIcon() {
        XCTAssertNil(ITunesLookup.artworkURL(from: json("not json at all")))
        XCTAssertNil(ITunesLookup.artworkURL(from: Data()))
        XCTAssertNil(ITunesLookup.artworkURL(from: json("[]")))
    }

    func testResultWithoutArtworkMeansNoIcon() {
        XCTAssertNil(ITunesLookup.artworkURL(from: json(#"{"results":[{"trackId":123}]}"#)))
    }

    /// The URL comes from a response body, so it decides where the *next* request goes. A non-HTTPS
    /// one is refused rather than followed — App Transport Security would block it anyway, but not
    /// making the request at all is the better failure.
    func testNonHTTPSArtworkIsRefused() {
        let data = json(#"{"results":[{"artworkUrl100":"http://example.com/icon.png"}]}"#)
        XCTAssertNil(ITunesLookup.artworkURL(from: data))
    }

    func testLookupURLIsScopedToApps() {
        let url = ITunesLookup.lookupURL(appleID: "6478")
        XCTAssertEqual(url?.host, "itunes.apple.com")
        XCTAssertTrue(url?.absoluteString.contains("id=6478") == true)
        // Without entity=software a bare id can match a different kind of store item, which would
        // put an album cover on a sales row.
        XCTAssertTrue(url?.absoluteString.contains("entity=software") == true)
    }

    // MARK: - Cache

    /// The Apple ID reaches this from a parsed TSV, so it is untrusted input that becomes a
    /// filename. A traversal attempt must not write outside the cache directory.
    func testCachePathRejectsAnythingThatIsNotDigits() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vantage-icon-tests-\(UUID().uuidString)")
        let store = AppIconStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertFalse(store.save(Data([1, 2, 3]), for: "../../etc/passwd"))
        XCTAssertFalse(store.save(Data([1, 2, 3]), for: ""))
        XCTAssertNil(store.load("../../etc/passwd"))

        // Validated, not sanitized. Stripping non-digits from this would leave "123" — traversal
        // defeated, but now reading and writing another app's icon under its own name.
        XCTAssertFalse(store.save(Data([1, 2, 3]), for: "../../123/passwd"))
        XCTAssertNil(store.load("../../123/passwd"))
    }

    func testRoundTripsThroughTheCache() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vantage-icon-tests-\(UUID().uuidString)")
        let store = AppIconStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertTrue(store.save(payload, for: "6478"))
        XCTAssertEqual(store.load("6478"), payload)
        XCTAssertNil(store.load("9999"), "An uncached app must read as absent, not as empty data")
    }
}
